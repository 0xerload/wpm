#!/usr/bin/env bash
# lib/ols.sh — OpenLiteSpeed config parser/writer for WPM.
#
# Responsibilities (PRD §5.4/§5.5):
#   - Parse/patch `httpd_config.conf` virtualhost{}/listener{} blocks using
#     idempotent "# BEGIN WPM:<app> ... # END WPM:<app>" marker blocks.
#   - Copy+patch per-app `vhconf.conf` (mirror strategy, §F-2 step 6).
#   - Enforce the per-app accesslog{} shape (§F-3c).
#   - Snapshot/rebuild vhconf as "last known good" (§F-4).
#   - Import manually-created vhosts into the registry (FR-02).
#   - Graceful restart wrapper (§7.2 — every OLS write ends in graceful
#     restart, done by callers after they finish their multi-step edits).
#
# This file is SOURCED, never executed. It must not set -e/-u globally.
# It assumes lib/core.sh has already defined (or will be sourced here to
# define): colors, log_info/log_warn/log_error/log_action/die,
# is_valid_app_name, app_conf_path/app_exists/app_get/app_set_all,
# now_iso, and the path constants WPM_APPS_DIR / OLS_CONF / OLS_VHOST_DIR /
# OLS_CTRL / OLS_HOME / WPM_LOG_FILE / WPM_VERSION.

[[ -n "${WPM_LIB_OLS_LOADED:-}" ]] && return
readonly WPM_LIB_OLS_LOADED=1

_wpm_ols_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [[ -z "${WPM_LIB_CORE_LOADED:-}" ]]; then
  # shellcheck source=./core.sh
  source "${_wpm_ols_dir}/core.sh"
fi
unset _wpm_ols_dir

# ─────────────────────────────────────────────────────────────────────────
# Internal helpers (not part of the public contract, no `ols_` prefix
# collisions are exported outside this file)
# ─────────────────────────────────────────────────────────────────────────

# _ols_require_valid_app APP — dies if APP does not look like a safe app
# name. Defensive check; callers (wpm/clone.sh) are expected to already
# have validated via is_valid_app_name, but ols.sh writes into shared OLS
# config files so a second check here is cheap insurance.
_ols_require_valid_app() {
  local app="$1"
  if [[ -z "$app" ]] || ! is_valid_app_name "$app"; then
    die "ols.sh: nama app tidak valid: '${app}'"
  fi
}

# _ols_sed_escape STR — escapes BRE metacharacters + the '/' delimiter so
# STR is safe to embed literally inside a sed pattern.
_ols_sed_escape() {
  printf '%s' "$1" | sed -e 's/[.[\*^$/]/\\&/g'
}

# _ols_upsert_marker_block FILE TAG BLOCK_FILE
# Idempotently inserts/replaces a "# BEGIN WPM:<TAG> ... # END WPM:<TAG>"
# region in FILE with the contents of BLOCK_FILE (which must itself
# contain the BEGIN/END marker lines). Pure string (==) comparison in awk
# — no regex, so TAG can never break out of its match.
_ols_upsert_marker_block() {
  local file="$1" tag="$2" block_file="$3"
  local begin="# BEGIN WPM:${tag}"
  local end="# END WPM:${tag}"
  local tmp
  tmp="$(mktemp)" || { log_error "_ols_upsert_marker_block: mktemp gagal"; return 1; }

  if grep -qF "$begin" "$file" 2>/dev/null; then
    awk -v begin="$begin" -v end="$end" -v blockfile="$block_file" '
      $0 == begin {
        skip = 1
        while ((getline line < blockfile) > 0) print line
        close(blockfile)
        next
      }
      $0 == end && skip == 1 { skip = 0; next }
      skip == 1 { next }
      { print }
    ' "$file" > "$tmp"
  else
    cp "$file" "$tmp"
    printf '\n' >> "$tmp"
    cat "$block_file" >> "$tmp"
  fi

  cat "$tmp" > "$file"
  rm -f "$tmp"
  return 0
}

# _ols_listener_block_exists LISTENER_NAME — 0 if a top-level
# `listener LISTENER_NAME { ... }` block exists in $OLS_CONF, 1 otherwise.
_ols_listener_block_exists() {
  local lname="$1"
  [[ -f "$OLS_CONF" ]] || return 1
  awk -v lname="$lname" '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    {
      t = trim($0)
      n = split(t, w, /[ \t]+/)
      if (n >= 3 && w[1] == "listener" && w[2] == lname && w[n] == "{") { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$OLS_CONF"
}

# _ols_listener_name_for_port PORT — echoes the name of the first top-level
# `listener NAME { ... address ...:PORT ... }` block in $OLS_CONF whose
# `address` directive is bound to PORT (matches "*:PORT", "0.0.0.0:PORT",
# "<ip>:PORT" — anything ending in ":PORT"). Echoes nothing (and the caller
# sees an empty string) if none found.
_ols_listener_name_for_port() {
  local port="$1"
  [[ -f "$OLS_CONF" ]] || return 1
  awk -v port="$port" '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    BEGIN { in_l = 0; lname = "" }
    {
      t = trim($0)
      n = split(t, w, /[ \t]+/)
      if (!in_l) {
        if (n >= 3 && w[1] == "listener" && w[n] == "{") { in_l = 1; lname = w[2] }
        next
      }
      if (t == "}") { in_l = 0; next }
      if (n >= 2 && w[1] == "address" && w[2] ~ (":" port "$")) { print lname; exit }
    }
  ' "$OLS_CONF"
}

# _ols_create_listener NAME PORT [KEYFILE CERTFILE] — appends a new,
# minimal `listener NAME { address *:PORT ... }` block to $OLS_CONF
# (plain/secure 0 if KEYFILE/CERTFILE are omitted, secure 1 with those cert
# paths otherwise). Backs up config first (ols_backup_config). Refuses to
# run if NAME already exists (never overwrites/duplicates) or if $OLS_CONF
# is missing. Does NOT restart OLS itself — the caller's own pipeline step
# already does a graceful restart right after mapping the vhost, which
# picks this up in that same restart.
#
# IMPORTANT: this function's only permitted stdout is via log_error (which
# writes to stderr, not stdout) — it is called from ols_http_listener_name/
# ols_https_listener_name, which are themselves always invoked via a
# subshelled `$(...)` at every call site in lib/clone.sh and lib/ssl.sh.
# Anything this function (or anything it calls) prints to stdout would
# silently get appended into the "listener name" string those callers
# capture, corrupting it. Never call log_info/log_warn from here or from
# anything reachable from here — only log_error (stderr) and log_action
# (log-file only) are safe.
_ols_create_listener() {
  local name="$1" port="$2" keyfile="${3:-}" certfile="${4:-}"

  if [[ -z "$name" || -z "$port" ]]; then
    log_error "_ols_create_listener: NAME dan PORT wajib diisi"
    return 1
  fi
  if [[ ! -f "$OLS_CONF" ]]; then
    log_error "_ols_create_listener: $OLS_CONF tidak ditemukan"
    return 1
  fi
  if _ols_listener_block_exists "$name"; then
    log_error "_ols_create_listener: listener '${name}' sudah ada, tidak membuat duplikat"
    return 1
  fi

  ols_backup_config >/dev/null 2>&1

  {
    printf '\nlistener %s {\n' "$name"
    printf '  address                 *:%s\n' "$port"
    if [[ -n "$keyfile" && -n "$certfile" ]]; then
      printf '  secure                  1\n'
      printf '  keyFile                 %s\n' "$keyfile"
      printf '  certFile                %s\n' "$certfile"
      printf '  certChain               1\n'
    else
      printf '  secure                  0\n'
    fi
    printf '}\n'
  } >> "$OLS_CONF"

  log_action "_ols_create_listener: listener '${name}' (*:${port}) ditambahkan ke ${OLS_CONF}"
  return 0
}

# _ols_ensure_selfsigned_cert — echoes "KEYFILE CERTFILE" for a WPM-managed
# self-signed certificate at $WPM_ETC/wpm-selfsigned.{key,crt}, generating
# one (via openssl) if it doesn't exist yet. This is ONLY a bootstrap
# fallback so a freshly-created HTTPS listener has something to bind
# with — it is never used for a real app's actual certificate (those come
# from Let's Encrypt per-vhost via the vhssl{} block + SNI, same as
# ssl_install_vhssl already does). Returns 1 (prints nothing) if openssl
# is unavailable or generation fails.
_ols_ensure_selfsigned_cert() {
  local key="${WPM_ETC}/wpm-selfsigned.key" crt="${WPM_ETC}/wpm-selfsigned.crt"

  if [[ -f "$key" && -f "$crt" ]]; then
    printf '%s %s\n' "$key" "$crt"
    return 0
  fi

  command -v openssl >/dev/null 2>&1 || return 1
  mkdir -p "$WPM_ETC" 2>/dev/null

  if openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$key" -out "$crt" -subj "/CN=localhost" >/dev/null 2>&1; then
    chmod 600 "$key" 2>/dev/null
    chmod 644 "$crt" 2>/dev/null
    log_action "_ols_ensure_selfsigned_cert: sertifikat self-signed sementara dibuat (${key}, ${crt})"
    printf '%s %s\n' "$key" "$crt"
    return 0
  fi

  return 1
}

# ols_http_listener_name / ols_https_listener_name — echo the ACTUAL name of
# whichever listener in $OLS_CONF is bound to port 80 / port 443,
# regardless of what it's called. Real-world OpenLiteSpeed installs
# commonly ship a listener that is NOT literally named "Default"/"SSL"
# (the stock config's listener is named "Example", and one-click
# installers/admins may name it anything) — hardcoding those two literal
# names here caused ols_write_listener_map to die with "blok listener
# 'Default' tidak ditemukan" on any server whose port-80 listener has a
# different name, even though a perfectly usable one exists.
#
# If NO listener at all is bound to that port (common on a freshly
# provisioned OpenLiteSpeed — e.g. the stock/ols1clk default listener is
# often only on :8088/:7080, not :80/:443), WPM cannot map any vhost
# without one, so a minimal one is created automatically (via
# _ols_create_listener) rather than requiring a manual one-time
# httpd_config.conf edit: "Default" (or "WPM_HTTP"/"WPM_HTTPS" if that
# literal name is already taken by something on a different port) for
# HTTP, and the same idea for HTTPS using a temporary self-signed
# certificate (real per-app certs still come from Let's Encrypt via the
# per-vhost vhssl{} block, same as always — this is only so the base
# HTTPS listener has something to bind with). If creation itself fails for
# any reason (e.g. openssl missing, permission issue), the literal
# fallback name is still returned so ols_write_listener_map's own
# "listener tidak ditemukan" error (now a graceful return 1, not a die)
# fires with a clear message instead of silently doing nothing.
ols_http_listener_name() {
  local n
  n="$(_ols_listener_name_for_port 80)"
  if [[ -n "$n" ]]; then
    printf '%s\n' "$n"
    return 0
  fi

  local target_name="Default"
  _ols_listener_block_exists "$target_name" && target_name="WPM_HTTP"
  # NOTE: only stdout is suppressed here (defense in depth — this function
  # is itself always called via `$(...)`, and stdout is what gets
  # captured/corrupted; stderr is NOT captured by `$(...)` and must be left
  # alone so a real log_error from a failed auto-create is still visible to
  # whoever is running `wpm` interactively, instead of being silently
  # swallowed with no explanation).
  if ! _ols_create_listener "$target_name" 80 >/dev/null; then
    log_error "ols_http_listener_name: gagal membuat listener HTTP otomatis untuk port :80 (lihat pesan di atas dan ${WPM_LOG_FILE} untuk detail — periksa permission tulis pada ${OLS_CONF})"
  fi
  printf '%s\n' "$target_name"
}

ols_https_listener_name() {
  local n
  n="$(_ols_listener_name_for_port 443)"
  if [[ -n "$n" ]]; then
    printf '%s\n' "$n"
    return 0
  fi

  local target_name="SSL"
  _ols_listener_block_exists "$target_name" && target_name="WPM_HTTPS"

  local certinfo key crt
  if certinfo="$(_ols_ensure_selfsigned_cert)"; then
    read -r key crt <<<"$certinfo"
    if ! _ols_create_listener "$target_name" 443 "$key" "$crt" >/dev/null; then
      log_error "ols_https_listener_name: gagal membuat listener HTTPS otomatis untuk port :443 (lihat pesan di atas dan ${WPM_LOG_FILE} untuk detail — periksa permission tulis pada ${OLS_CONF})"
    fi
  else
    log_error "ols_https_listener_name: gagal menyiapkan sertifikat self-signed sementara (openssl tidak ditemukan, atau gagal generate) — listener HTTPS tidak dibuat otomatis"
  fi
  printf '%s\n' "$target_name"
}

# _ols_patch_vhconf_domain_and_logs VHCONF NEW_DOMAIN
# In-place patch of a copied vhconf.conf: rewrites vhDomain/vhAliases
# values to NEW_DOMAIN, and rewrites accesslog/errorlog header paths to
# the $VH_ROOT-relative form if they still hold a literal absolute path.
_ols_patch_vhconf_domain_and_logs() {
  local vhconf="$1" domain="$2"
  local tmp
  tmp="$(mktemp)" || { log_error "_ols_patch_vhconf_domain_and_logs: mktemp gagal"; return 1; }

  awk -v domain="$domain" '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    {
      line = $0
      t = trim(line)
      n = split(t, w, /[ \t]+/)

      if (n >= 2 && (w[1] == "vhDomain" || w[1] == "vhAliases")) {
        match(line, /^[ \t]*/); indent = substr(line, RSTART, RLENGTH)
        printf("%s%-24s%s\n", indent, w[1], domain)
        next
      }

      if (n >= 2 && (w[1] == "accesslog" || w[1] == "errorlog")) {
        path = w[2]
        hasBrace = (t ~ /\{[ \t]*$/) ? 1 : 0
        gsub(/\{$/, "", path)
        if (index(path, "$VH_ROOT") == 0) {
          newpath = (w[1] == "accesslog") ? "$VH_ROOT/logs/access.log" : "$VH_ROOT/logs/error.log"
          match(line, /^[ \t]*/); indent = substr(line, RSTART, RLENGTH)
          if (hasBrace) printf("%s%-24s%s {\n", indent, w[1], newpath)
          else printf("%s%-24s%s\n", indent, w[1], newpath)
          next
        }
      }

      print line
    }
  ' "$vhconf" > "$tmp" && cat "$tmp" > "$vhconf"
  rm -f "$tmp"
  return 0
}

# _ols_write_minimal_vhconf VHCONF DOMAIN DOCROOT_REL PHP_HANDLER WEB_USER WEB_GROUP
# Generates a minimal-but-correct vhconf.conf from scratch (used only by
# ols_rebuild_vhconf when no snapshot exists).
_ols_write_minimal_vhconf() {
  local vhconf="$1" domain="$2" docroot_rel="$3" php_handler="$4" web_user="$5" web_group="$6"
  mkdir -p "$(dirname "$vhconf")"
  cat > "$vhconf" <<VHEOF
docRoot                   \$VH_ROOT/${docroot_rel}
vhDomain                  ${domain}
vhAliases                 www.${domain}
adminEmails               root@localhost
enableGzip                1
enableIComp               1

errorlog \$VH_ROOT/logs/error.log {
  useServer               0
  logLevel                WARN
  rollingSize             10M
}

accesslog \$VH_ROOT/logs/access.log {
  useServer               0
  rollingSize             10M
  keepDays                7
  compressArchive         1
}

index  {
  useServer               0
  indexFiles              index.php, index.html
}

scripthandler  {
  add                     lsapi:${php_handler} php
}

extprocessor ${php_handler} {
  type                    lsapi
  address                 uds://tmp/lshttpd/${php_handler}.sock
  maxConns                10
  env                     PHP_LSAPI_CHILDREN=10
  initTimeout             60
  retryTimeout            0
  persistConn             1
  respBuffer              0
  autoStart               1
  path                    ${OLS_HOME}/${php_handler}/bin/lsphp
  extUser                 ${web_user}
  extGroup                ${web_group}
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           400
  procHardLimit           500
}

rewrite  {
  enable                  1
  autoLoadHtaccess        1
}

context / {
  allowBrowse             1
  rewrite  {
    enable                1
    inherit               0
  }
  addDefaultCharset       off
  phpIniOverride  {
  }
}
VHEOF
}

# ─────────────────────────────────────────────────────────────────────────
# Public contract — lib/ols.sh MUST export
# ─────────────────────────────────────────────────────────────────────────

# ols_detect_web_user — echoes "user:group" parsed from top-level
# `user`/`group` directives in $OLS_CONF (brace-depth 0 only, so we don't
# accidentally pick up a per-vhost override). Defaults nobody:nogroup.
ols_detect_web_user() {
  local user="" group="" parsed=""

  if [[ -f "$OLS_CONF" ]]; then
    parsed="$(awk '
      function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
      BEGIN { depth = 0; u = ""; g = "" }
      {
        t = trim($0)
        n = split(t, w, /[ \t]+/)
        if (depth == 0 && n >= 2) {
          if (w[1] == "user" && u == "") u = w[2]
          else if (w[1] == "group" && g == "") g = w[2]
        }
        o = gsub(/\{/, "{", $0); c = gsub(/\}/, "}", $0)
        depth += o - c
      }
      END { printf("%s|%s\n", u, g) }
    ' "$OLS_CONF")"
    IFS='|' read -r user group <<< "$parsed"
  fi

  [[ -z "$user" ]] && user="nobody"
  [[ -z "$group" ]] && group="nogroup"
  echo "${user}:${group}"
}

# ols_backup_config — cp $OLS_CONF to ${OLS_CONF}.bak-<timestamp> before
# any write; keeps the last 10 backups, prunes older ones. Always call
# this before mutating $OLS_CONF (§5.5: "file selalu di-backup sebelum
# diubah").
ols_backup_config() {
  if [[ ! -f "$OLS_CONF" ]]; then
    log_warn "ols_backup_config: $OLS_CONF tidak ditemukan, backup dilewati"
    return 1
  fi

  local ts backup_path dir base
  ts="$(date -u +%Y%m%d%H%M%S%N 2>/dev/null)"
  [[ -z "$ts" ]] && ts="$(date -u +%Y%m%d%H%M%S)-$$"
  backup_path="${OLS_CONF}.bak-${ts}"

  if ! cp -p "$OLS_CONF" "$backup_path"; then
    log_error "ols_backup_config: gagal menyalin $OLS_CONF ke $backup_path"
    return 1
  fi
  log_action "OLS config dibackup ke $backup_path"

  dir="$(dirname "$OLS_CONF")"
  base="$(basename "$OLS_CONF")"
  local backups=()
  shopt -s nullglob
  mapfile -t backups < <(printf '%s\n' "$dir/$base".bak-* | sort)
  shopt -u nullglob

  local count=${#backups[@]}
  if (( count > 10 )); then
    local excess=$(( count - 10 ))
    local i
    for ((i = 0; i < excess; i++)); do
      rm -f "${backups[$i]}"
    done
    log_action "ols_backup_config: menghapus ${excess} backup lama (menyisakan 10 terbaru)"
  fi

  return 0
}

# ols_graceful_restart — $OLS_CTRL restart (graceful reload). Logs via
# log_action, returns the underlying exit code.
ols_graceful_restart() {
  if [[ ! -x "$OLS_CTRL" ]]; then
    log_error "ols_graceful_restart: $OLS_CTRL tidak ditemukan/tidak dapat dieksekusi"
    return 1
  fi

  log_action "Menjalankan graceful restart OLS: $OLS_CTRL restart"
  "$OLS_CTRL" restart >>"$WPM_LOG_FILE" 2>&1
  local rc=$?

  if (( rc == 0 )); then
    log_action "Graceful restart OLS berhasil"
  else
    log_error "Graceful restart OLS gagal (exit code ${rc})"
  fi
  return "$rc"
}

# ols_vhconf_path APP — echoes $OLS_VHOST_DIR/$APP/vhconf.conf. Pure path
# construction, no validation/side effects (used for read-only lookups
# too, e.g. cross-referencing unmanaged vhosts).
ols_vhconf_path() {
  local app="$1"
  echo "${OLS_VHOST_DIR}/${app}/vhconf.conf"
}

# ols_write_vhost_block APP VH_ROOT CONFIG_FILE
# Inserts/replaces the "# BEGIN WPM:<APP> ... # END WPM:<APP>" virtualhost
# block in $OLS_CONF. Idempotent (replaces in place if already present).
# Always backs up first.
ols_write_vhost_block() {
  local app="$1" vh_root="$2" config_file="$3"
  _ols_require_valid_app "$app"

  if [[ -z "$vh_root" || -z "$config_file" ]]; then
    die "ols_write_vhost_block: VH_ROOT dan CONFIG_FILE wajib diisi untuk app '${app}'"
  fi
  if [[ ! -f "$OLS_CONF" ]]; then
    die "ols_write_vhost_block: $OLS_CONF tidak ditemukan"
  fi

  ols_backup_config

  local vh_root_clean="${vh_root%/}"
  local block_file
  block_file="$(mktemp)" || die "ols_write_vhost_block: mktemp gagal"

  {
    printf '# BEGIN WPM:%s\n' "$app"
    printf 'virtualhost %s {\n' "$app"
    printf '  vhRoot                  %s/\n' "$vh_root_clean"
    printf '  configFile              %s\n' "$config_file"
    printf '  allowSymbolLink         1\n'
    printf '  enableScript            1\n'
    printf '  restrained              1\n'
    printf '}\n'
    printf '# END WPM:%s\n' "$app"
  } > "$block_file"

  _ols_upsert_marker_block "$OLS_CONF" "$app" "$block_file"
  rm -f "$block_file"

  log_action "Blok virtualhost WPM:${app} ditulis (vhRoot=${vh_root_clean}, configFile=${config_file})"
  return 0
}

# ols_remove_vhost_block APP — deletes the "# BEGIN WPM:<APP> ... # END
# WPM:<APP>" range via sed (APP escaped for sed). Backs up first.
ols_remove_vhost_block() {
  local app="$1"
  _ols_require_valid_app "$app"

  if [[ ! -f "$OLS_CONF" ]]; then
    log_warn "ols_remove_vhost_block: $OLS_CONF tidak ditemukan, dilewati"
    return 1
  fi
  if ! grep -qF "# BEGIN WPM:${app}" "$OLS_CONF"; then
    log_warn "ols_remove_vhost_block: blok WPM:${app} tidak ditemukan, tidak ada yang dihapus"
    return 0
  fi

  ols_backup_config

  local esc_app
  esc_app="$(_ols_sed_escape "$app")"
  sed -i "/^# BEGIN WPM:${esc_app}\$/,/^# END WPM:${esc_app}\$/d" "$OLS_CONF"

  log_action "Blok virtualhost WPM:${app} dihapus dari $OLS_CONF"
  return 0
}

# ols_write_listener_map LISTENER_NAME APP DOMAIN
# Appends/replaces "  map   <APP> <DOMAIN>" inside the named listener{}
# block. Idempotent per APP. Returns 1 (does NOT die/exit) if the listener
# block doesn't exist — this function is called directly (not via a
# subshelled `$(...)`) from clone_execute_one/clone_execute_one_from_staging,
# so a die() here would `exit` the whole interactive wpm process instead of
# just failing this one step, skipping the caller's own
# _clone_step_failed/rollback handling entirely and leaving a half-created
# app (files + database already made) stuck in the registry with no way to
# clean itself up. Missing args / missing OLS_CONF still die() since those
# indicate a programming error in the caller, not a normal first-run
# server-config condition (unlike a missing listener block, which real
# servers commonly hit — see ols_http_listener_name/ols_https_listener_name).
ols_write_listener_map() {
  local lname="$1" app="$2" domain="$3"
  _ols_require_valid_app "$app"

  if [[ -z "$lname" || -z "$domain" ]]; then
    die "ols_write_listener_map: LISTENER_NAME dan DOMAIN wajib diisi"
  fi
  if [[ ! -f "$OLS_CONF" ]]; then
    die "ols_write_listener_map: $OLS_CONF tidak ditemukan"
  fi
  if ! _ols_listener_block_exists "$lname"; then
    log_error "ols_write_listener_map: blok listener '${lname}' tidak ditemukan di $OLS_CONF. Periksa §7.2 — listener untuk port :80 (HTTP) dan :443 (HTTPS) harus sudah ada pada httpd_config dasar sebelum WPM dapat memetakan vhost."
    return 1
  fi

  ols_backup_config

  local tmp
  tmp="$(mktemp)" || die "ols_write_listener_map: mktemp gagal"

  awk -v lname="$lname" -v app="$app" -v domain="$domain" '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    BEGIN { in_target = 0; inserted = 0 }
    {
      orig = $0
      t = trim(orig)

      if (!in_target) {
        n = split(t, w, /[ \t]+/)
        if (n >= 3 && w[1] == "listener" && w[2] == lname && w[n] == "{") {
          in_target = 1
          print orig
          next
        }
        print orig
        next
      }

      if (t == "}") {
        if (!inserted) {
          printf("  map                    %s %s\n", app, domain)
          inserted = 1
        }
        in_target = 0
        print orig
        next
      }

      n2 = split(t, w2, /[ \t]+/)
      if (n2 == 3 && w2[1] == "map" && w2[2] == app) {
        if (!inserted) {
          printf("  map                    %s %s\n", app, domain)
          inserted = 1
        }
        next
      }

      print orig
    }
  ' "$OLS_CONF" > "$tmp" && cat "$tmp" > "$OLS_CONF"
  rm -f "$tmp"

  log_action "Listener ${lname}: dipetakan ${app} -> ${domain}"
  return 0
}

# ols_remove_listener_map LISTENER_NAME APP — removes that map line from
# the named listener{} block. No-op (with a warning) if the listener
# block doesn't exist; silently no-op if the map line isn't present.
ols_remove_listener_map() {
  local lname="$1" app="$2"
  _ols_require_valid_app "$app"

  if [[ -z "$lname" ]]; then
    die "ols_remove_listener_map: LISTENER_NAME wajib diisi"
  fi
  if [[ ! -f "$OLS_CONF" ]]; then
    log_warn "ols_remove_listener_map: $OLS_CONF tidak ditemukan, dilewati"
    return 1
  fi
  if ! _ols_listener_block_exists "$lname"; then
    log_warn "ols_remove_listener_map: blok listener '${lname}' tidak ditemukan, dilewati"
    return 0
  fi

  ols_backup_config

  local tmp
  tmp="$(mktemp)" || die "ols_remove_listener_map: mktemp gagal"

  awk -v lname="$lname" -v app="$app" '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    BEGIN { in_target = 0 }
    {
      orig = $0
      t = trim(orig)

      if (!in_target) {
        n = split(t, w, /[ \t]+/)
        if (n >= 3 && w[1] == "listener" && w[2] == lname && w[n] == "{") {
          in_target = 1
          print orig
          next
        }
        print orig
        next
      }

      if (t == "}") { in_target = 0; print orig; next }

      n2 = split(t, w2, /[ \t]+/)
      if (n2 == 3 && w2[1] == "map" && w2[2] == app) { next }

      print orig
    }
  ' "$OLS_CONF" > "$tmp" && cat "$tmp" > "$OLS_CONF"
  rm -f "$tmp"

  log_action "Listener ${lname}: map untuk ${app} dihapus"
  return 0
}

# ols_parse_vhosts — echoes TSV "name\tvhRoot\tconfigFile" for every
# top-level `virtualhost NAME { ... }` block in $OLS_CONF. Used by F-1 to
# detect vhosts with no matching file in $WPM_APPS_DIR.
ols_parse_vhosts() {
  [[ -f "$OLS_CONF" ]] || return 0

  awk '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    BEGIN { in_vh = 0 }
    {
      t = trim($0)
      if (!in_vh) {
        n = split(t, w, /[ \t]+/)
        if (n >= 3 && w[1] == "virtualhost" && w[n] == "{") {
          name = w[2]; vhroot = ""; conf = ""; in_vh = 1
        }
        next
      }
      if (t == "}") {
        printf("%s\t%s\t%s\n", name, vhroot, conf)
        in_vh = 0
        next
      }
      n2 = split(t, w2, /[ \t]+/)
      if (n2 >= 2) {
        if (w2[1] == "vhRoot") vhroot = w2[2]
        else if (w2[1] == "configFile") conf = w2[2]
      }
    }
  ' "$OLS_CONF"
}

# ols_copy_and_patch_vhconf SRC_APP NEW_APP NEW_DOMAIN
# Mirrors the source vhconf verbatim (it already uses $VH_ROOT/$DOC_ROOT
# macros, so paths need no patching), patching only vhDomain/vhAliases and
# any literal accesslog/errorlog path. Echoes the new vhconf path.
ols_copy_and_patch_vhconf() {
  local src_app="$1" new_app="$2" new_domain="$3"
  _ols_require_valid_app "$src_app"
  _ols_require_valid_app "$new_app"

  if [[ -z "$new_domain" ]]; then
    log_error "ols_copy_and_patch_vhconf: domain wajib diisi"
    return 1
  fi

  local src_vhconf new_dir new_vhconf
  src_vhconf="$(ols_vhconf_path "$src_app")"
  if [[ ! -f "$src_vhconf" ]]; then
    log_error "ols_copy_and_patch_vhconf: vhconf sumber tidak ditemukan: ${src_vhconf}"
    return 1
  fi

  new_dir="${OLS_VHOST_DIR}/${new_app}"
  if ! mkdir -p "$new_dir"; then
    log_error "ols_copy_and_patch_vhconf: gagal membuat direktori ${new_dir}"
    return 1
  fi

  new_vhconf="${new_dir}/vhconf.conf"
  if ! cp "$src_vhconf" "$new_vhconf"; then
    log_error "ols_copy_and_patch_vhconf: gagal menyalin ${src_vhconf} ke ${new_vhconf}"
    return 1
  fi

  _ols_patch_vhconf_domain_and_logs "$new_vhconf" "$new_domain"

  log_action "vhconf disalin+dipatch: ${src_app} -> ${new_app} (domain=${new_domain})"
  echo "$new_vhconf"
  return 0
}

# ols_set_access_log APP — ensures the vhconf's accesslog{} block matches
# §F-3c exactly: $VH_ROOT/logs/access.log, rollingSize 10M, keepDays 7,
# compressArchive 1. Replaces an existing block in place, or appends one
# if none exists.
ols_set_access_log() {
  local app="$1"
  _ols_require_valid_app "$app"

  local vhconf
  vhconf="$(ols_vhconf_path "$app")"
  if [[ ! -f "$vhconf" ]]; then
    log_error "ols_set_access_log: vhconf tidak ditemukan untuk app '${app}' (${vhconf})"
    return 1
  fi

  local tmp
  tmp="$(mktemp)" || { log_error "ols_set_access_log: mktemp gagal"; return 1; }

  awk '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    BEGIN { in_block = 0; found = 0 }
    {
      t = trim($0)
      if (!in_block) {
        n = split(t, w, /[ \t]+/)
        if (n >= 2 && w[1] == "accesslog") {
          found = 1
          print "  accesslog               $VH_ROOT/logs/access.log {"
          print "    rollingSize             10M"
          print "    keepDays                7"
          print "    compressArchive         1"
          print "  }"
          in_block = 1
          next
        }
        print
        next
      }
      if (t == "}") { in_block = 0 }
      next
    }
    END {
      if (!found) {
        print "  accesslog               $VH_ROOT/logs/access.log {"
        print "    rollingSize             10M"
        print "    keepDays                7"
        print "    compressArchive         1"
        print "  }"
      }
    }
  ' "$vhconf" > "$tmp" && cat "$tmp" > "$vhconf"
  rm -f "$tmp"

  log_action "Access log dinormalisasi untuk app '${app}' sesuai §F-3c"
  return 0
}

# ols_snapshot_vhconf APP — copies the current vhconf.conf to
# $WPM_APPS_DIR/<APP>.vhconf.snap ("last known good" per §5.5).
ols_snapshot_vhconf() {
  local app="$1"
  _ols_require_valid_app "$app"

  local vhconf snap
  vhconf="$(ols_vhconf_path "$app")"
  snap="${WPM_APPS_DIR}/${app}.vhconf.snap"

  if [[ ! -f "$vhconf" ]]; then
    log_error "ols_snapshot_vhconf: vhconf tidak ditemukan untuk app '${app}' (${vhconf})"
    return 1
  fi

  mkdir -p "$WPM_APPS_DIR"
  if ! cp "$vhconf" "$snap"; then
    log_error "ols_snapshot_vhconf: gagal membuat snapshot untuk app '${app}'"
    return 1
  fi
  chmod 600 "$snap" 2>/dev/null

  log_action "Snapshot vhconf disimpan untuk app '${app}' -> ${snap}"
  return 0
}

# ols_rebuild_vhconf APP — F-4 Rebuild: restores from snapshot if one
# exists; otherwise regenerates a minimal-but-correct vhconf from the
# registry (DOCROOT, PHP_HANDLER, DOMAIN) + a fresh ols_set_access_log.
# Always re-snapshots after rebuilding. Never touches site data.
ols_rebuild_vhconf() {
  local app="$1"
  _ols_require_valid_app "$app"

  local vhconf snap domain docroot vh_root php_handler webuser_group web_user web_group rel
  vhconf="$(ols_vhconf_path "$app")"
  snap="${WPM_APPS_DIR}/${app}.vhconf.snap"

  mkdir -p "$(dirname "$vhconf")"

  if [[ -f "$snap" ]]; then
    if cp "$snap" "$vhconf"; then
      log_action "Rebuild: vhconf app '${app}' dipulihkan dari snapshot"
    else
      log_error "Rebuild: gagal menyalin snapshot untuk app '${app}'"
      return 1
    fi
  else
    domain="$(app_get "$app" DOMAIN)"
    docroot="$(app_get "$app" DOCROOT)"
    vh_root="$(app_get "$app" VH_ROOT)"
    php_handler="$(app_get "$app" PHP_HANDLER)"
    [[ -z "$php_handler" ]] && php_handler="lsphp82"
    [[ -z "$domain" ]] && domain="${app}.localhost"

    webuser_group="$(ols_detect_web_user)"
    web_user="${webuser_group%%:*}"
    web_group="${webuser_group##*:}"

    rel="${docroot#"$vh_root"}"
    rel="${rel#/}"
    [[ -z "$rel" ]] && rel="html"

    _ols_write_minimal_vhconf "$vhconf" "$domain" "$rel" "$php_handler" "$web_user" "$web_group"
    log_action "Rebuild: vhconf minimal digenerate untuk app '${app}' (tidak ada snapshot)"
  fi

  ols_set_access_log "$app"
  ols_snapshot_vhconf "$app"
  return 0
}

# ols_import_vhost NAME VH_ROOT CONFIG_FILE
# FR-02: creates a registry conf for a manually-made vhost discovered by
# ols_parse_vhosts. Infers what it can from the vhconf; leaves DB_*/
# REDIS_* empty and SOURCE_APP empty; SSL_STATUS inferred from whether a
# vhssl{} block exists.
ols_import_vhost() {
  local name="$1" vh_root="$2" config_file="$3"

  if [[ -z "$name" ]] || ! is_valid_app_name "$name"; then
    log_error "ols_import_vhost: nama vhost tidak valid untuk import: '${name}'"
    return 1
  fi
  if app_exists "$name"; then
    log_warn "ols_import_vhost: app '${name}' sudah terdaftar di registry, import dilewati"
    return 1
  fi
  if [[ -z "$config_file" || ! -f "$config_file" ]]; then
    log_error "ols_import_vhost: config file vhost tidak ditemukan: '${config_file}'"
    return 1
  fi
  if [[ -z "$vh_root" ]]; then
    log_error "ols_import_vhost: VH_ROOT wajib diisi untuk app '${name}'"
    return 1
  fi

  local vh_root_clean="${vh_root%/}"

  local domain
  domain="$(awk '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    { t = trim($0); n = split(t, w, /[ \t]+/); if (n >= 2 && w[1] == "vhDomain") { print w[2]; exit } }
  ' "$config_file")"

  local docroot_val rel docroot
  docroot_val="$(awk '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    { t = trim($0); n = split(t, w, /[ \t]+/); if (n >= 2 && w[1] == "docRoot") { print w[2]; exit } }
  ' "$config_file")"

  rel="${docroot_val/\$VH_ROOT/}"
  rel="${rel#/}"
  if [[ -n "$rel" ]]; then
    docroot="${vh_root_clean}/${rel}"
  else
    docroot="$vh_root_clean"
  fi

  local php_handler
  php_handler="$(awk '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    {
      t = trim($0)
      n = split(t, w, /[ \t]+/)
      if (n >= 2 && w[1] == "add" && index(w[2], "lsapi:") == 1) {
        val = w[2]
        sub(/^lsapi:/, "", val)
        print val
        exit
      }
    }
  ' "$config_file")"

  local ssl_status
  if grep -qE '^[[:space:]]*vhssl[[:space:]]*\{' "$config_file"; then
    ssl_status="active"
  else
    ssl_status="none"
  fi

  if ! app_set_all "$name" \
      APP_NAME="$name" \
      SOURCE_APP="" \
      DOMAIN="$domain" \
      VH_ROOT="$vh_root_clean" \
      DOCROOT="$docroot" \
      DB_NAME="" \
      DB_USER="" \
      DB_PASS="" \
      PHP_HANDLER="$php_handler" \
      REDIS_DB_ID="" \
      REDIS_USER="" \
      REDIS_PASS="" \
      SSL_STATUS="$ssl_status" \
      SSL_ISSUED_AT="" \
      CREATED_AT="$(now_iso)" \
      WPM_VERSION="$WPM_VERSION"; then
    log_error "ols_import_vhost: gagal menulis registry untuk '${name}'"
    return 1
  fi

  log_action "Vhost tak terkelola '${name}' diimpor ke registry (domain=${domain}, docroot=${docroot}, ssl=${ssl_status})"

  local expected_vhconf
  expected_vhconf="$(ols_vhconf_path "$name")"
  if [[ "$config_file" == "$expected_vhconf" ]]; then
    ols_snapshot_vhconf "$name" || true
  else
    log_warn "ols_import_vhost: path vhconf '${name}' tidak standar (${config_file} != ${expected_vhconf}), snapshot dilewati"
  fi

  return 0
}

# ols_hosts_add_loopback DOMAIN — idempotently adds a "127.0.0.1 DOMAIN #
# WPM" line to /etc/hosts, so any process running ON THIS SERVER that
# requests http(s)://DOMAIN/... resolves straight to the local
# OpenLiteSpeed listener instead of round-tripping out through a reverse
# proxy/CDN (e.g. Cloudflare) and back to itself.
#
# This matters because some plugin functionality makes exactly that kind
# of self-referential request — e.g. LiteSpeed Cache's own
# `wp litespeed-purge all` calls admin_url('admin-ajax.php') via an
# outbound HTTP request to the site's own public URL (confirmed directly
# from litespeedtech/lscache_wp's cli/purge.cls.php source). On a
# CDN-proxied domain, that "hairpin" pattern (origin -> CDN -> back to the
# same origin) is a well-known source of intermittent failures — Cloudflare
# returns 521/522 when it can't immediately re-establish the connection
# back to the origin, especially moments after a vhost/SSL config change
# and graceful restart. Bypassing the CDN entirely for locally-originated
# requests avoids that whole failure class. This has zero effect on how
# anyone else on the internet resolves DOMAIN — /etc/hosts only overrides
# resolution for this one machine.
ols_hosts_add_loopback() {
  local domain="$1"
  [[ -z "$domain" ]] && return 1
  [[ -f /etc/hosts ]] || return 1

  grep -qF " ${domain} # WPM" /etc/hosts 2>/dev/null && return 0

  printf '127.0.0.1 %s # WPM\n' "$domain" >> /etc/hosts \
    || { log_error "ols_hosts_add_loopback: gagal menulis ke /etc/hosts untuk '${domain}'"; return 1; }

  log_action "ols_hosts_add_loopback: entri /etc/hosts ditambahkan untuk ${domain} -> 127.0.0.1"
  return 0
}

# ols_hosts_remove_loopback DOMAIN — removes the marked entry added by
# ols_hosts_add_loopback above. Used by _app_purge (lib/clone.sh) when an
# app is deleted/rolled back, so /etc/hosts doesn't accumulate stale
# entries over time.
ols_hosts_remove_loopback() {
  local domain="$1"
  [[ -z "$domain" ]] && return 1
  [[ -f /etc/hosts ]] || return 0

  grep -qF " ${domain} # WPM" /etc/hosts 2>/dev/null || return 0

  local tmp
  tmp="$(mktemp)" || { log_error "ols_hosts_remove_loopback: mktemp gagal"; return 1; }
  grep -vF " ${domain} # WPM" /etc/hosts > "$tmp" && cat "$tmp" > /etc/hosts
  rm -f "$tmp"

  log_action "ols_hosts_remove_loopback: entri /etc/hosts dihapus untuk ${domain}"
  return 0
}
