#!/usr/bin/env bash
#
# lib/php.sh — Per-app PHP settings for WPM (PRD §F-3a / §5.4 `php.sh`).
#
# Responsibilities:
#   - Read/write the 5 tunable phpIniOverride{} directives inside an app's
#     vhconf.conf: memory_limit, upload_max_filesize, post_max_size,
#     max_execution_time, max_input_vars.
#   - Apply the Low/Normal/High presets from §F-3a.
#   - Detect installed lsphp versions under $OLS_HOME.
#   - Switch an app's PHP version (scripthandler + extprocessor + registry).
#
# The phpIniOverride{} block is rewritten using the SAME marker-based
# ("# BEGIN WPM:<tag> ... # END WPM:<tag>") idempotent-replace convention as
# lib/ols.sh (see _ols_upsert_marker_block). It cannot reuse that helper
# verbatim because phpIniOverride lives *nested* inside a vhconf `context {}`
# block rather than at file top-level like httpd_config.conf's virtualhost{}
# blocks — so this file implements its own nesting-aware upsert, following
# the same string-equality-marker + mktemp-then-replace technique. Backup and
# restart are NOT duplicated here: ols_backup_config and ols_graceful_restart
# (both from lib/ols.sh) are reused directly, plus ols_snapshot_vhconf to keep
# the F-4 "last known good" snapshot current after a successful change.
#
# This file is a lib — it must be *sourced*, never executed directly, and
# must never `set -e`/`set -u` globally (that would leak into the sourcing
# shell). Each public function below does its own defensive error checking.

[[ -n "${WPM_LIB_PHP_LOADED:-}" ]] && return
readonly WPM_LIB_PHP_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/php.sh harus di-source, bukan dieksekusi langsung." >&2
  exit 1
fi

# Resolve this file's directory so dependent libs load correctly regardless
# of whether WPM is running from the repo checkout or from its installed
# location ($WPM_HOME). Include-guards in each dependency make re-sourcing
# harmless if the caller already sourced them.
_WPM_PHP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./core.sh
source "$_WPM_PHP_LIB_DIR/core.sh"
# shellcheck source=./ols.sh
source "$_WPM_PHP_LIB_DIR/ols.sh"

unset _WPM_PHP_LIB_DIR

# ─────────────────────────────────────────────────────────────────────────
# Internal helpers (not part of the public contract)
# ─────────────────────────────────────────────────────────────────────────

# The 5 tunable phpIniOverride keys (§F-3a / FR-13). Single source of truth
# so php_ini_get / php_ini_set_all can't drift out of sync with each other.
_PHP_INI_KEYS=(memory_limit upload_max_filesize post_max_size max_execution_time max_input_vars)

# _php_key_is_allowed KEY — 0 if KEY is one of the 5 tunable directives.
_php_key_is_allowed() {
  local key="$1" k
  for k in "${_PHP_INI_KEYS[@]}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

# _php_require_app APP FN_NAME — shared "app must be named and registered"
# guard used by every public function below. Logs and returns 1 (does NOT
# die) so a bad menu selection can't tear down the whole wpm session.
_php_require_app() {
  local app="$1" fn="$2"
  if [[ -z "$app" ]]; then
    log_error "${fn}: nama app tidak boleh kosong"
    return 1
  fi
  if ! app_exists "$app"; then
    log_error "${fn}: app '${app}' tidak ditemukan di registry"
    return 1
  fi
  return 0
}

# _php_backup_vhconf APP VHCONF — timestamped safety copy of the app's own
# vhconf.conf before we rewrite it in place, mirroring ols_backup_config's
# exact "cp with timestamp, keep last 10, prune older" pattern (§5.5: "file
# selalu di-backup sebelum diubah") — scoped per-app so rotation only counts
# that app's own backups, not every app's.
_php_backup_vhconf() {
  local app="$1" vhconf="$2"

  if [[ ! -f "$vhconf" ]]; then
    log_warn "_php_backup_vhconf: vhconf tidak ditemukan untuk app '${app}', backup dilewati"
    return 1
  fi

  local ts backup_path dir base
  ts="$(date -u +%Y%m%d%H%M%S%N 2>/dev/null)"
  [[ -z "$ts" ]] && ts="$(date -u +%Y%m%d%H%M%S)-$$"
  backup_path="${vhconf}.bak-${ts}"

  if ! cp -p "$vhconf" "$backup_path"; then
    log_error "_php_backup_vhconf: gagal menyalin ${vhconf} ke ${backup_path}"
    return 1
  fi
  log_action "vhconf app '${app}' dibackup ke ${backup_path}"

  dir="$(dirname "$vhconf")"
  base="$(basename "$vhconf")"
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
    log_action "_php_backup_vhconf: menghapus ${excess} backup lama vhconf app '${app}' (menyisakan 10 terbaru)"
  fi

  return 0
}

# _php_upsert_ini_block VHCONF TAG BLOCK_FILE
# Idempotently writes BLOCK_FILE's content (a fully-rendered, marker-wrapped
# phpIniOverride{} block) into VHCONF:
#   1. If a previous "# BEGIN WPM:<TAG> ... # END WPM:<TAG>" region already
#      exists (a prior php_ini_set_all call) → replace it in place.
#   2. Else if a raw/unmarked `phpIniOverride { ... }` block already exists
#      (e.g. carried over from the site's original hand-written vhconf) →
#      replace that whole block in place, adopting its exact original
#      position (nesting preserved automatically since we operate line by
#      line without needing to know depth ourselves in this branch).
#   3. Else (no phpIniOverride anywhere yet) → insert BLOCK_FILE right
#      before the closing brace of the FIRST top-level `context ... {`
#      block found (tracked via brace-depth counting, same idiom as
#      ols_detect_web_user / ols_write_listener_map). Fails loudly (returns
#      1) if no context block exists at all — silently appending at file
#      end would produce an invalid, unparseable vhconf.
_php_upsert_ini_block() {
  local vhconf="$1" tag="$2" block_file="$3"
  local begin="# BEGIN WPM:${tag}"
  local end="# END WPM:${tag}"
  local tmp errfile
  tmp="$(mktemp)" || { log_error "_php_upsert_ini_block: mktemp gagal"; return 1; }
  errfile="$(mktemp)" || { rm -f "$tmp"; log_error "_php_upsert_ini_block: mktemp gagal"; return 1; }

  awk -v begin="$begin" -v end="$end" -v blockfile="$block_file" '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    BEGIN {
      replaced = 0; in_marked = 0; in_raw = 0
      ctx_active = 0; ctx_depth = 0; ctx_done = 0
    }
    {
      orig = $0
      t = trim(orig)

      if (in_marked) {
        if (t == end) in_marked = 0
        next
      }
      if (t == begin) {
        in_marked = 1
        while ((getline line < blockfile) > 0) print line
        close(blockfile)
        replaced = 1
        next
      }

      if (in_raw) {
        if (t == "}") in_raw = 0
        next
      }

      n = split(t, w, /[ \t]+/)
      if (!replaced && n >= 1 && w[1] == "phpIniOverride") {
        while ((getline line < blockfile) > 0) print line
        close(blockfile)
        replaced = 1
        in_raw = 1
        next
      }

      if (!replaced && !ctx_done) {
        if (!ctx_active) {
          if (n >= 1 && w[1] == "context" && w[n] == "{") {
            ctx_active = 1
            ctx_depth = 1
            print orig
            next
          }
        } else {
          o = gsub(/\{/, "{", orig)
          c = gsub(/\}/, "}", orig)
          ctx_depth += (o - c)
          if (ctx_depth <= 0) {
            while ((getline line < blockfile) > 0) print line
            close(blockfile)
            replaced = 1
            ctx_active = 0
            ctx_done = 1
            print orig
            next
          }
          print orig
          next
        }
      }

      print orig
    }
    END {
      if (!replaced) {
        print "no-context-block-found" > "/dev/stderr"
        exit 3
      }
    }
  ' "$vhconf" > "$tmp" 2> "$errfile"
  local rc=$?

  if (( rc != 0 )); then
    rm -f "$tmp" "$errfile"
    return 1
  fi

  cat "$tmp" > "$vhconf"
  rm -f "$tmp" "$errfile"
  return 0
}

# _php_patch_scripthandler_version VHCONF OLD NEW
# Rewrites the `add lsapi:<OLD> php` line inside `scripthandler {}` to
# reference NEW, and — if a per-vhost `extprocessor <OLD> { ... }` block
# exists — renames it to NEW and repoints its `path`/`address` lines
# (which embed the handler name) at NEW. Returns:
#   0 — both the scripthandler reference and a matching extprocessor block
#       were updated.
#   2 — the scripthandler reference was updated but no per-vhost
#       extprocessor block named OLD was found (caller should warn: this is
#       fine if HANDLER is defined server-wide in httpd_config.conf instead).
#   1 — hard failure (couldn't write the file at all).
_php_patch_scripthandler_version() {
  local vhconf="$1" old="$2" new="$3"
  local tmp errfile
  tmp="$(mktemp)" || { log_error "_php_patch_scripthandler_version: mktemp gagal"; return 1; }
  errfile="$(mktemp)" || { rm -f "$tmp"; log_error "_php_patch_scripthandler_version: mktemp gagal"; return 1; }

  awk -v old="$old" -v new="$new" '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    # literal_replace: index()/substr()-based first-occurrence replacement.
    # Used instead of sub()/gsub() here because old/new are caller-supplied
    # handler names — sub() would treat them as a dynamic ERE, not literal
    # text.
    function literal_replace(str, needle, repl,    pos) {
      pos = index(str, needle)
      if (pos == 0) return str
      return substr(str, 1, pos - 1) repl substr(str, pos + length(needle))
    }
    BEGIN { in_extproc = 0; extproc_done = 0 }
    {
      orig = $0
      t = trim(orig)
      n = split(t, w, /[ \t]+/)

      if (in_extproc) {
        if (t == "}") { in_extproc = 0; print orig; next }
        if (n >= 2 && w[1] == "path" && index(orig, "/" old "/bin/lsphp") > 0) {
          print literal_replace(orig, "/" old "/bin/lsphp", "/" new "/bin/lsphp")
          next
        }
        if (n >= 2 && w[1] == "address" && index(orig, "/" old ".sock") > 0) {
          print literal_replace(orig, "/" old ".sock", "/" new ".sock")
          next
        }
        print orig
        next
      }

      if (n >= 2 && w[1] == "add" && w[2] == "lsapi:" old) {
        print literal_replace(orig, "lsapi:" old, "lsapi:" new)
        next
      }

      if (!extproc_done && n >= 3 && w[1] == "extprocessor" && w[2] == old && w[n] == "{") {
        line = literal_replace(orig, old, new)
        in_extproc = 1
        extproc_done = 1
        print line
        next
      }

      print orig
    }
    END {
      if (!extproc_done) print "no-extprocessor-block" > "/dev/stderr"
    }
  ' "$vhconf" > "$tmp" 2> "$errfile"
  local rc=$?

  if (( rc != 0 )); then
    rm -f "$tmp" "$errfile"
    return 1
  fi

  cat "$tmp" > "$vhconf"
  rm -f "$tmp"

  if [[ -s "$errfile" ]]; then
    rm -f "$errfile"
    return 2
  fi
  rm -f "$errfile"
  return 0
}

# _php_update_registry_handler APP HANDLER — persists PHP_HANDLER to the
# app's registry conf. app_set_all overwrites the WHOLE conf file with
# exactly the keys given (no merge — see core.sh), so every other field is
# read back via app_get first and re-written unchanged; only PHP_HANDLER
# actually changes.
_php_update_registry_handler() {
  local app="$1" handler="$2"

  app_set_all "$app" \
    APP_NAME="$(app_get "$app" APP_NAME)" \
    SOURCE_APP="$(app_get "$app" SOURCE_APP)" \
    DOMAIN="$(app_get "$app" DOMAIN)" \
    VH_ROOT="$(app_get "$app" VH_ROOT)" \
    DOCROOT="$(app_get "$app" DOCROOT)" \
    DB_NAME="$(app_get "$app" DB_NAME)" \
    DB_USER="$(app_get "$app" DB_USER)" \
    DB_PASS="$(app_get "$app" DB_PASS)" \
    PHP_HANDLER="$handler" \
    REDIS_DB_ID="$(app_get "$app" REDIS_DB_ID)" \
    REDIS_USER="$(app_get "$app" REDIS_USER)" \
    REDIS_PASS="$(app_get "$app" REDIS_PASS)" \
    SSL_STATUS="$(app_get "$app" SSL_STATUS)" \
    SSL_ISSUED_AT="$(app_get "$app" SSL_ISSUED_AT)" \
    CREATED_AT="$(app_get "$app" CREATED_AT)" \
    WPM_VERSION="$(app_get "$app" WPM_VERSION)"
}

# ─────────────────────────────────────────────────────────────────────────
# Public contract — lib/php.sh MUST export
# ─────────────────────────────────────────────────────────────────────────

# php_ini_get APP KEY — echoes the current value of KEY (one of
# memory_limit, upload_max_filesize, post_max_size, max_execution_time,
# max_input_vars) from the app's vhconf phpIniOverride{} block. Echoes
# nothing (empty) if the app has no override for KEY yet.
php_ini_get() {
  local app="$1" key="$2"

  _php_require_app "$app" "php_ini_get" || return 1

  if [[ -z "$key" ]] || ! _php_key_is_allowed "$key"; then
    log_error "php_ini_get: parameter PHP tidak dikenal: '${key}' (harus salah satu dari: ${_PHP_INI_KEYS[*]})"
    return 1
  fi

  local vhconf
  vhconf="$(ols_vhconf_path "$app")"
  if [[ ! -f "$vhconf" ]]; then
    log_error "php_ini_get: vhconf tidak ditemukan untuk app '${app}' (${vhconf})"
    return 1
  fi

  awk -v key="$key" '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    BEGIN { in_block = 0 }
    {
      t = trim($0)
      n = split(t, w, /[ \t]+/)
      if (!in_block) {
        if (n >= 1 && w[1] == "phpIniOverride") in_block = 1
        next
      }
      if (t == "}") { in_block = 0; next }
      if (n >= 2 && w[1] == key) {
        val = t
        sub(/^[^ \t]+[ \t]+/, "", val)
        print val
        exit
      }
    }
  ' "$vhconf"
  return 0
}

# php_ini_set_all APP memory_limit=.. upload_max_filesize=.. post_max_size=..
#   max_execution_time=.. max_input_vars=..
# Rewrites the app's vhconf phpIniOverride{} block (marker-delimited,
# idempotent — see _php_upsert_ini_block), then ols_graceful_restart.
# Mirrors app_set_all's "complete set, no merge" semantics: ALL 5 keys are
# required on every call — callers that want to change only one setting
# must first read the other 4 via php_ini_get and pass them through
# unchanged.
php_ini_set_all() {
  local app="$1"
  shift

  _php_require_app "$app" "php_ini_set_all" || return 1

  local -A vals=()
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    if ! _php_key_is_allowed "$k"; then
      log_error "php_ini_set_all: parameter tidak dikenal: '${k}' (harus salah satu dari: ${_PHP_INI_KEYS[*]})"
      return 1
    fi
    if [[ -z "$v" || ! "$v" =~ ^[A-Za-z0-9_.+-]+$ ]]; then
      log_error "php_ini_set_all: nilai untuk '${k}' tidak valid: '${v}'"
      return 1
    fi
    vals["$k"]="$v"
  done

  local key
  for key in "${_PHP_INI_KEYS[@]}"; do
    if [[ -z "${vals[$key]:-}" ]]; then
      log_error "php_ini_set_all: parameter wajib '${key}' tidak diberikan untuk app '${app}'"
      return 1
    fi
  done

  local vhconf
  vhconf="$(ols_vhconf_path "$app")"
  if [[ ! -f "$vhconf" ]]; then
    log_error "php_ini_set_all: vhconf tidak ditemukan untuk app '${app}' (${vhconf})"
    return 1
  fi

  # Safety copies before mutating: ols_backup_config for the shared
  # httpd_config.conf checkpoint (best-effort, reused as-is from ols.sh —
  # not duplicated here) and _php_backup_vhconf for the file we actually
  # change.
  ols_backup_config || log_warn "php_ini_set_all: ols_backup_config gagal (dilanjutkan)"
  _php_backup_vhconf "$app" "$vhconf" || return 1

  local tag="${app}:php"
  local block_file
  block_file="$(mktemp)" || { log_error "php_ini_set_all: mktemp gagal"; return 1; }
  {
    printf '  # BEGIN WPM:%s\n' "$tag"
    printf '  phpIniOverride  {\n'
    printf '    memory_limit            %s\n' "${vals[memory_limit]}"
    printf '    upload_max_filesize     %s\n' "${vals[upload_max_filesize]}"
    printf '    post_max_size           %s\n' "${vals[post_max_size]}"
    printf '    max_execution_time      %s\n' "${vals[max_execution_time]}"
    printf '    max_input_vars          %s\n' "${vals[max_input_vars]}"
    printf '  }\n'
    printf '  # END WPM:%s\n' "$tag"
  } > "$block_file"

  if ! _php_upsert_ini_block "$vhconf" "$tag" "$block_file"; then
    rm -f "$block_file"
    log_error "php_ini_set_all: gagal menulis blok phpIniOverride untuk app '${app}' (tidak ditemukan blok phpIniOverride maupun blok context untuk disisipi — periksa vhconf secara manual)"
    return 1
  fi
  rm -f "$block_file"

  log_action "php_ini_set_all: phpIniOverride app '${app}' diperbarui (memory_limit=${vals[memory_limit]}, upload_max_filesize=${vals[upload_max_filesize]}, post_max_size=${vals[post_max_size]}, max_execution_time=${vals[max_execution_time]}, max_input_vars=${vals[max_input_vars]})"

  if ! ols_graceful_restart; then
    log_error "php_ini_set_all: phpIniOverride app '${app}' ditulis, namun restart graceful OLS gagal"
    return 1
  fi

  ols_snapshot_vhconf "$app" || log_warn "php_ini_set_all: gagal memperbarui snapshot vhconf untuk app '${app}' setelah perubahan PHP settings"

  log_info "Pengaturan PHP app '${app}' berhasil diperbarui."
  return 0
}

# php_apply_preset APP low|normal|high — looks up the §F-3a table and calls
# php_ini_set_all. max_input_vars isn't part of that table (only memory /
# upload+post / max_execution_time are specified there); it's scaled
# alongside the other tiers using common WordPress-admin guidance (plain
# sites rarely need more than ~1000, larger option/menu-heavy sites and
# builder plugins want more headroom).
php_apply_preset() {
  local app="$1" preset="$2"

  _php_require_app "$app" "php_apply_preset" || return 1

  local memory upload post exec_time input_vars
  case "$preset" in
    low)
      memory="128M"; upload="32M"; post="34M"; exec_time="60"; input_vars="1000"
      ;;
    normal)
      memory="256M"; upload="64M"; post="68M"; exec_time="120"; input_vars="2000"
      ;;
    high)
      memory="512M"; upload="128M"; post="136M"; exec_time="300"; input_vars="5000"
      ;;
    *)
      log_error "php_apply_preset: preset tidak dikenal: '${preset}' (harus low|normal|high)"
      return 1
      ;;
  esac

  log_info "Menerapkan preset PHP '${preset}' untuk app '${app}'..."
  php_ini_set_all "$app" \
    memory_limit="$memory" \
    upload_max_filesize="$upload" \
    post_max_size="$post" \
    max_execution_time="$exec_time" \
    max_input_vars="$input_vars"
}

# php_list_installed_versions — echoes handler names found under
# $OLS_HOME/lsphp* (e.g. lsphp82), one per line, sorted. Only directories
# that actually contain a bin/lsphp executable are counted, so a stray
# empty/partial directory doesn't show up as a usable version.
php_list_installed_versions() {
  local d base
  [[ -d "$OLS_HOME" ]] || return 0

  shopt -s nullglob
  for d in "$OLS_HOME"/lsphp*; do
    [[ -d "$d" ]] || continue
    [[ -x "$d/bin/lsphp" ]] || continue
    base="$(basename "$d")"
    printf '%s\n' "$base"
  done | sort
  shopt -u nullglob
}

# php_set_version APP HANDLER — rewrites the vhconf's scripthandler/
# extprocessor reference to HANDLER, updates registry PHP_HANDLER, then
# ols_graceful_restart.
php_set_version() {
  local app="$1" handler="$2"

  _php_require_app "$app" "php_set_version" || return 1

  if [[ -z "$handler" || ! "$handler" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "php_set_version: nama handler PHP tidak valid: '${handler}'"
    return 1
  fi

  local found=0 v
  while IFS= read -r v; do
    [[ "$v" == "$handler" ]] && found=1
  done < <(php_list_installed_versions)
  if [[ "$found" -eq 0 ]]; then
    log_error "php_set_version: versi PHP '${handler}' tidak ditemukan terpasang di ${OLS_HOME} (lihat php_list_installed_versions untuk daftar yang tersedia)"
    return 1
  fi

  local vhconf
  vhconf="$(ols_vhconf_path "$app")"
  if [[ ! -f "$vhconf" ]]; then
    log_error "php_set_version: vhconf tidak ditemukan untuk app '${app}' (${vhconf})"
    return 1
  fi

  local old_handler
  old_handler="$(awk '
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
  ' "$vhconf")"

  if [[ -z "$old_handler" ]]; then
    log_error "php_set_version: tidak menemukan blok scripthandler (add lsapi:...) di vhconf app '${app}', tidak dapat menentukan handler PHP saat ini dengan aman"
    return 1
  fi
  if [[ ! "$old_handler" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "php_set_version: handler PHP saat ini pada vhconf app '${app}' tidak valid: '${old_handler}'"
    return 1
  fi

  if [[ "$old_handler" == "$handler" ]]; then
    log_info "php_set_version: app '${app}' sudah memakai handler '${handler}', tidak ada perubahan"
    return 0
  fi

  ols_backup_config || log_warn "php_set_version: ols_backup_config gagal (dilanjutkan)"
  _php_backup_vhconf "$app" "$vhconf" || return 1

  _php_patch_scripthandler_version "$vhconf" "$old_handler" "$handler"
  local patch_rc=$?
  if (( patch_rc == 1 )); then
    log_error "php_set_version: gagal menulis handler baru ke vhconf app '${app}'"
    return 1
  elif (( patch_rc == 2 )); then
    log_warn "php_set_version: blok extprocessor '${old_handler}' tidak ditemukan di vhconf app '${app}' — hanya referensi scripthandler yang diperbarui ke '${handler}'. Pastikan extprocessor untuk '${handler}' sudah didefinisikan (per-vhost atau di httpd_config.conf) sebelum restart."
  fi

  log_action "php_set_version: app '${app}' handler PHP diubah ${old_handler} -> ${handler}"

  if ! _php_update_registry_handler "$app" "$handler"; then
    log_error "php_set_version: vhconf berhasil diubah tapi gagal memperbarui registry PHP_HANDLER untuk app '${app}'"
    return 1
  fi

  if ! ols_graceful_restart; then
    log_error "php_set_version: handler PHP app '${app}' diubah, namun restart graceful OLS gagal"
    return 1
  fi

  ols_snapshot_vhconf "$app" || log_warn "php_set_version: gagal memperbarui snapshot vhconf app '${app}' setelah ganti versi PHP"

  log_info "Versi PHP app '${app}' berhasil diubah ke ${handler}."
  return 0
}
