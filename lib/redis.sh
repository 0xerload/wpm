#!/usr/bin/env bash
#
# lib/redis.sh — Redis ACL & object-cache integration for WPM.
#
# Covers PRD §F-3b (Redis ACL per app), §6.5 (users.acl schema/design note),
# §7.2 (LSCWP credential sync via wp-cli), §7.4 (~60 app cap / DB ID 1-63).
#
# Design note (per §6.5/§7.2): Redis ACL cannot restrict `SELECT` across
# logical databases, so per-app isolation is enforced primarily via a
# key-prefix pattern (`~<app>:*`) on each app's dedicated ACL user. A
# distinct REDIS_DB_ID (1-63, 0 reserved) is still allocated per app purely
# for organizational purposes and so an admin connection can FLUSHDB just
# that app's data (used by Clear Cache / app deletion) without touching
# other apps' keys.
#
# This file is a sourced library — no `set -e`/`set -u` at file scope, no
# direct execution. Every function does its own explicit error checking.

[[ -n "${WPM_LIB_REDIS_LOADED:-}" ]] && return
readonly WPM_LIB_REDIS_LOADED=1

# --- Load lib/core.sh (path constants, logging, prompts, registry I/O) ----
_WPM_REDIS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [[ -z "${WPM_LIB_CORE_LOADED:-}" ]]; then
  # shellcheck source=./core.sh
  source "${_WPM_REDIS_LIB_DIR}/core.sh"
fi
unset _WPM_REDIS_LIB_DIR

# ============================================================================
# Private helpers
# ============================================================================

# _redis_acl_ensure_file — make sure $REDIS_ACL_FILE (and its directory)
# exists with 600 perms before any read/write. Returns 1 on failure.
_redis_acl_ensure_file() {
  local dir
  dir="$(dirname -- "$REDIS_ACL_FILE")"

  if [[ ! -d "$dir" ]] && ! mkdir -p "$dir" 2>/dev/null; then
    log_error "Gagal membuat direktori '${dir}' untuk Redis ACL file"
    return 1
  fi

  if [[ ! -f "$REDIS_ACL_FILE" ]] && ! : > "$REDIS_ACL_FILE" 2>/dev/null; then
    log_error "Gagal membuat file Redis ACL '${REDIS_ACL_FILE}'"
    return 1
  fi

  chmod 600 "$REDIS_ACL_FILE" 2>/dev/null
  return 0
}

# _redis_acl_get_user_line USER — echoes the current ACL line for USER
# (empty if not present). Fields: 1=user 2=NAME 3=on|off 4=>PASS 5=~prefix ...
_redis_acl_get_user_line() {
  local user="$1"
  [[ -f "$REDIS_ACL_FILE" ]] || return 0
  awk -v u="$user" '$1=="user" && $2==u { print; exit }' "$REDIS_ACL_FILE"
}

# _redis_acl_remove_user_line USER — removes USER's line (if any) from
# $REDIS_ACL_FILE atomically (temp file + mv). Best-effort: does not fail
# the caller if the user simply wasn't present.
_redis_acl_remove_user_line() {
  local user="$1"
  local tmp

  [[ -f "$REDIS_ACL_FILE" ]] || return 0

  tmp="$(mktemp "${REDIS_ACL_FILE}.tmp.XXXXXX" 2>/dev/null)" || return 1
  if ! awk -v u="$user" '$1=="user" && $2==u { next } { print }' "$REDIS_ACL_FILE" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$REDIS_ACL_FILE"
}

# _redis_web_user — echoes the OLS web-server user (e.g. "nobody"), used to
# invoke wp-cli as the file-owning user instead of root. Prefers ols.sh's
# ols_detect_web_user (available once wpm/clone.sh have sourced lib/ols.sh
# into the same shell); falls back to a direct, minimal parse of
# $OLS_CONF so this file has no hard load-order dependency on ols.sh.
_redis_web_user() {
  local spec="" user=""

  if declare -F ols_detect_web_user >/dev/null 2>&1; then
    spec="$(ols_detect_web_user 2>/dev/null)"
  elif [[ -n "${OLS_CONF:-}" && -f "${OLS_CONF}" ]]; then
    local u g
    u="$(grep -Em1 '^[[:space:]]*user[[:space:]]+' "$OLS_CONF" 2>/dev/null | awk '{print $2}')"
    g="$(grep -Em1 '^[[:space:]]*group[[:space:]]+' "$OLS_CONF" 2>/dev/null | awk '{print $2}')"
    spec="${u:-nobody}:${g:-nogroup}"
  fi

  [[ -z "$spec" ]] && spec="nobody:nogroup"
  user="${spec%%:*}"
  [[ -z "$user" ]] && user="nobody"
  printf '%s\n' "$user"
}

# _redis_wp_run DOCROOT args... — runs `wp` against DOCROOT as the
# file-owning web user when possible (sudo -u), otherwise falls back to
# running directly as root with --allow-root. This is the canonical wp-cli
# invocation convention for this codebase — other files (clone.sh's
# `wp search-replace` step) should mirror it.
_redis_wp_run() {
  local docroot="$1"; shift
  local web_user

  require_cmd wp
  web_user="$(_redis_web_user)"

  if [[ -n "$web_user" && "$web_user" != "root" ]] \
     && command -v sudo >/dev/null 2>&1 \
     && id "$web_user" >/dev/null 2>&1; then
    local cmd=(sudo -u "$web_user" -- wp --path="$docroot")
    cmd+=("$@")
    "${cmd[@]}"
  else
    local cmd=(wp --path="$docroot" --allow-root)
    cmd+=("$@")
    "${cmd[@]}"
  fi
}

# _redis_registry_update APP FIELD VALUE — safely updates a single field in
# APP's registry conf. `app_set_all` (core.sh) always OVERWRITES the whole
# conf with exactly the keys it's given — it does not merge with what's on
# disk. So to change just one field (e.g. REDIS_PASS after a regen) we must
# read every documented registry key first (via app_get), override the one
# field, and write the complete set back — otherwise every other field
# (APP_NAME, DOMAIN, DB_*, VH_ROOT, ...) would be silently lost.
_redis_registry_update() {
  local app="$1" field="$2" value="$3"
  local -a keys=(
    APP_NAME SOURCE_APP DOMAIN VH_ROOT DOCROOT DB_NAME DB_USER DB_PASS
    PHP_HANDLER REDIS_DB_ID REDIS_USER REDIS_PASS SSL_STATUS SSL_ISSUED_AT
    CREATED_AT WPM_VERSION
  )
  local -a kv=()
  local k v
  for k in "${keys[@]}"; do
    if [[ "$k" == "$field" ]]; then
      v="$value"
    else
      v="$(app_get "$app" "$k")"
    fi
    kv+=("${k}=${v}")
  done
  app_set_all "$app" "${kv[@]}"
}

# ============================================================================
# Public API (per WPM-CONTRACT.md §lib/redis.sh)
# ============================================================================

# redis_alloc_db_id — scans every app conf's REDIS_DB_ID and returns the
# smallest unused integer in 1-63 (0 is reserved). Dies if the range is
# exhausted (§7.4: practical cap of ~60 apps per server).
redis_alloc_db_id() {
  local -a used=()
  local app id

  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    id="$(app_get "$app" REDIS_DB_ID)"
    [[ -n "$id" ]] && used+=("$id")
  done < <(list_apps)

  local candidate taken u
  for ((candidate = 1; candidate <= 63; candidate++)); do
    taken=0
    for u in "${used[@]:-}"; do
      [[ -z "$u" ]] && continue
      if [[ "$u" -eq "$candidate" ]]; then
        taken=1
        break
      fi
    done
    if [[ "$taken" -eq 0 ]]; then
      echo "$candidate"
      return 0
    fi
  done

  die "redis_alloc_db_id: seluruh Redis DB ID (1-63) sudah terpakai — kapasitas praktis ~60 app per server (§7.4) telah tercapai."
}

# redis_admin_cli args... — thin wrapper around `redis-cli` talking to the
# default/admin user on localhost with no ACL restriction. Centralizes how
# WPM talks to Redis as admin so this is the single place to change if a
# deployment ever adds a `requirepass` for the default user.
redis_admin_cli() {
  require_cmd redis-cli
  local cmd=(redis-cli -h 127.0.0.1 -p 6379)
  cmd+=("$@")
  "${cmd[@]}"
}

# redis_create_acl_user APP USER PASS DB_ID — appends (idempotently replaces)
# a line in $REDIS_ACL_FILE isolating APP's keys under `~<APP>:*` and
# blocking dangerous commands, then reloads the ACL. DB_ID is not part of
# the ACL line itself (ACL cannot restrict SELECT) — it is only used here
# for the audit log entry; callers persist it to the registry separately.
redis_create_acl_user() {
  local app="$1" user="$2" pass="$3" db_id="$4"

  if [[ -z "$app" || -z "$user" || -z "$pass" || -z "$db_id" ]]; then
    log_error "redis_create_acl_user: argumen tidak lengkap (APP USER PASS DB_ID wajib diisi)"
    return 1
  fi
  if ! is_valid_app_name "$app"; then
    log_error "redis_create_acl_user: nama app tidak valid: '${app}'"
    return 1
  fi
  if [[ ! "$user" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "redis_create_acl_user: nama user Redis tidak valid: '${user}'"
    return 1
  fi
  if [[ ! "$db_id" =~ ^[0-9]+$ ]] || (( db_id < 1 || db_id > 63 )); then
    log_error "redis_create_acl_user: DB_ID '${db_id}' tidak valid (harus 1-63)"
    return 1
  fi
  if [[ "$pass" =~ [[:space:]] ]]; then
    log_error "redis_create_acl_user: password mengandung whitespace, ditolak"
    return 1
  fi

  _redis_acl_ensure_file || return 1
  _redis_acl_remove_user_line "$user"

  local line="user ${user} on >${pass} ~${app}:* +@all -@dangerous -flushall -flushdb -config"
  if ! printf '%s\n' "$line" >> "$REDIS_ACL_FILE"; then
    log_error "redis_create_acl_user: gagal menulis ke ${REDIS_ACL_FILE}"
    return 1
  fi
  chmod 600 "$REDIS_ACL_FILE" 2>/dev/null

  if ! redis_admin_cli ACL LOAD >/dev/null 2>&1; then
    log_error "redis_create_acl_user: 'ACL LOAD' gagal setelah membuat user '${user}' — periksa ${REDIS_ACL_FILE}"
    return 1
  fi

  log_action "Redis ACL user '${user}' dibuat untuk app '${app}' (prefix ${app}:*, DB ${db_id}, blocked: @dangerous/flushall/flushdb/config)"
  return 0
}

# redis_remove_acl_user APP USER — removes USER's ACL line, reloads ACL,
# then FLUSHDBs the app's REDIS_DB_ID (read from the registry) to reclaim
# it. Best-effort/never-die: used by clone_rollback (partial-state cleanup)
# and app_delete's purge helper, both of which must continue even if a
# sub-step here fails.
redis_remove_acl_user() {
  local app="$1" user="$2"

  if [[ -z "$app" || -z "$user" ]]; then
    log_error "redis_remove_acl_user: APP dan USER wajib diisi"
    return 1
  fi

  _redis_acl_ensure_file || return 1

  local db_id=""
  if declare -F app_get >/dev/null 2>&1; then
    db_id="$(app_get "$app" REDIS_DB_ID 2>/dev/null)"
  fi

  _redis_acl_remove_user_line "$user"

  if ! redis_admin_cli ACL LOAD >/dev/null 2>&1; then
    log_warn "redis_remove_acl_user: 'ACL LOAD' gagal setelah menghapus user '${user}' — periksa ${REDIS_ACL_FILE}"
  fi

  if [[ -n "$db_id" && "$db_id" =~ ^[0-9]+$ ]] && (( db_id >= 1 && db_id <= 63 )); then
    if redis_admin_cli -n "$db_id" FLUSHDB >/dev/null 2>&1; then
      log_action "Redis ACL user '${user}' dihapus & DB ${db_id} di-flush untuk app '${app}'"
    else
      log_warn "redis_remove_acl_user: gagal FLUSHDB Redis DB ${db_id} milik app '${app}'"
    fi
  elif [[ -n "$db_id" ]]; then
    log_warn "redis_remove_acl_user: REDIS_DB_ID '${db_id}' milik app '${app}' tidak valid (harus 1-63), flush dilewati"
  else
    log_action "Redis ACL user '${user}' dihapus untuk app '${app}' (REDIS_DB_ID tidak diketahui, flush dilewati)"
  fi

  return 0
}

# redis_regen_password APP — generates a new random password for APP's
# Redis ACL user, rewrites the ACL line (preserving its on/off state),
# reloads the ACL, persists REDIS_PASS to the registry, then re-syncs the
# new credential into LSCWP (which also stores the password).
redis_regen_password() {
  local app="$1"

  if [[ -z "$app" ]]; then
    log_error "redis_regen_password: APP wajib diisi"
    return 1
  fi
  if ! app_exists "$app"; then
    log_error "redis_regen_password: app '${app}' tidak ditemukan di registry"
    return 1
  fi

  local user db_id
  user="$(app_get "$app" REDIS_USER)"
  db_id="$(app_get "$app" REDIS_DB_ID)"

  if [[ -z "$user" || -z "$db_id" ]]; then
    log_error "redis_regen_password: app '${app}' belum memiliki kredensial Redis (REDIS_USER/REDIS_DB_ID kosong)"
    return 1
  fi

  if ! confirm "Regenerate password Redis untuk app '${app}' (user ${user})? Kredensial lama langsung tidak berlaku." "default_n"; then
    log_info "Regenerate password Redis app '${app}' dibatalkan."
    return 1
  fi

  _redis_acl_ensure_file || return 1

  local new_pass enabled_flag="on" cur_line
  new_pass="$(rand_password)"
  cur_line="$(_redis_acl_get_user_line "$user")"
  if [[ -n "$cur_line" ]]; then
    enabled_flag="$(awk '{print $3}' <<<"$cur_line")"
    [[ "$enabled_flag" != "on" && "$enabled_flag" != "off" ]] && enabled_flag="on"
  fi

  _redis_acl_remove_user_line "$user"
  if ! printf '%s\n' "user ${user} ${enabled_flag} >${new_pass} ~${app}:* +@all -@dangerous -flushall -flushdb -config" >> "$REDIS_ACL_FILE"; then
    log_error "redis_regen_password: gagal menulis ACL baru untuk user '${user}'"
    return 1
  fi
  chmod 600 "$REDIS_ACL_FILE" 2>/dev/null

  if ! redis_admin_cli ACL LOAD >/dev/null 2>&1; then
    log_error "redis_regen_password: 'ACL LOAD' gagal setelah regenerate password app '${app}'"
    return 1
  fi

  if ! _redis_registry_update "$app" REDIS_PASS "$new_pass"; then
    log_error "redis_regen_password: gagal menyimpan password baru ke registry app '${app}'"
    return 1
  fi
  log_action "Password Redis app '${app}' (user ${user}) berhasil di-regenerate"

  if ! redis_sync_lscwp "$app"; then
    log_warn "redis_regen_password: password baru tersimpan, namun sinkronisasi ke LSCWP untuk app '${app}' gagal — coba sinkron ulang secara manual"
    return 1
  fi

  return 0
}

# redis_set_enabled APP on|off — toggles the app's ACL user's on/off flag
# in $REDIS_ACL_FILE and reloads the ACL. Disabling is confirmed (it breaks
# the app's object cache until re-enabled); enabling is not.
redis_set_enabled() {
  local app="$1" state="$2"

  if [[ -z "$app" ]]; then
    log_error "redis_set_enabled: APP wajib diisi"
    return 1
  fi
  if [[ "$state" != "on" && "$state" != "off" ]]; then
    log_error "redis_set_enabled: state harus 'on' atau 'off' (diterima: '${state}')"
    return 1
  fi

  local user
  user="$(app_get "$app" REDIS_USER)"
  if [[ -z "$user" ]]; then
    log_error "redis_set_enabled: app '${app}' tidak memiliki REDIS_USER terdaftar"
    return 1
  fi

  _redis_acl_ensure_file || return 1

  local cur_line
  cur_line="$(_redis_acl_get_user_line "$user")"
  if [[ -z "$cur_line" ]]; then
    log_error "redis_set_enabled: user Redis '${user}' tidak ditemukan di ${REDIS_ACL_FILE}"
    return 1
  fi

  if [[ "$state" == "off" ]]; then
    if ! confirm "Nonaktifkan user Redis '${user}' untuk app '${app}'? Object cache app ini akan berhenti bekerja sampai diaktifkan kembali." "default_n"; then
      log_info "Menonaktifkan user Redis app '${app}' dibatalkan."
      return 1
    fi
  fi

  local tmp
  tmp="$(mktemp "${REDIS_ACL_FILE}.tmp.XXXXXX" 2>/dev/null)" || {
    log_error "redis_set_enabled: gagal membuat file sementara"
    return 1
  }
  if ! awk -v u="$user" -v st="$state" '
        $1=="user" && $2==u { $3=st }
        { print }
      ' "$REDIS_ACL_FILE" > "$tmp"; then
    log_error "redis_set_enabled: gagal menulis ulang ${REDIS_ACL_FILE}"
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  if ! mv -f "$tmp" "$REDIS_ACL_FILE"; then
    log_error "redis_set_enabled: gagal mengganti ${REDIS_ACL_FILE}"
    rm -f "$tmp"
    return 1
  fi

  if ! redis_admin_cli ACL LOAD >/dev/null 2>&1; then
    log_error "redis_set_enabled: 'ACL LOAD' gagal setelah mengubah status user '${user}' ke '${state}'"
    return 1
  fi

  log_action "Redis ACL user '${user}' (app '${app}') diset ke status '${state}'"
  return 0
}

# redis_sync_lscwp APP — pushes the app's current Redis credentials/DB ID
# into LiteSpeed Cache's object-cache settings via `wp litespeed-option`,
# then purges all LSCWP cache. Exact LSCWP option keys are collected in a
# single local associative array so they're easy to adjust if a plugin
# version renames them.
redis_sync_lscwp() {
  local app="$1"

  if [[ -z "$app" ]]; then
    log_error "redis_sync_lscwp: APP wajib diisi"
    return 1
  fi
  if ! app_exists "$app"; then
    log_error "redis_sync_lscwp: app '${app}' tidak ditemukan di registry"
    return 1
  fi

  local docroot redis_user redis_pass redis_db_id
  docroot="$(app_get "$app" DOCROOT)"
  redis_user="$(app_get "$app" REDIS_USER)"
  redis_pass="$(app_get "$app" REDIS_PASS)"
  redis_db_id="$(app_get "$app" REDIS_DB_ID)"

  if [[ -z "$docroot" || ! -d "$docroot" ]]; then
    log_error "redis_sync_lscwp: DOCROOT app '${app}' tidak ditemukan ('${docroot}')"
    return 1
  fi
  if [[ -z "$redis_user" || -z "$redis_pass" || -z "$redis_db_id" ]]; then
    log_warn "redis_sync_lscwp: app '${app}' belum memiliki kredensial Redis lengkap, sinkronisasi LSCWP dilewati"
    return 1
  fi

  require_cmd wp

  # Cek dulu apakah plugin LiteSpeed Cache benar-benar aktif di situs ini
  # SEBELUM mencoba set opsi apa pun. Tanpa cek ini, situs yang sumber
  # staging/clone-nya kebetulan tidak menyertakan/mengaktifkan LSCWP akan
  # gagal di SEMUA 6 opsi + purge dengan pesan yang membingungkan (satu
  # per satu, tanpa penjelasan akar masalah) — padahal akar masalahnya
  # cuma satu: perintah `wp litespeed-option`/`wp litespeed-purge` memang
  # disediakan OLEH plugin itu sendiri, jadi tidak ada sama sekali kalau
  # plugin-nya tidak aktif. Satu pesan jelas di sini lebih berguna daripada
  # tujuh pesan generik.
  if ! _redis_wp_run "$docroot" plugin is-active litespeed-cache >/dev/null 2>>"$WPM_LOG_FILE"; then
    log_warn "redis_sync_lscwp: plugin LiteSpeed Cache tidak terpasang/tidak aktif di app '${app}' — sinkronisasi kredensial Redis ke LSCWP dilewati (situs tetap berjalan, hanya tanpa object cache Redis). Pasang & aktifkan plugin 'litespeed-cache' di app ini (atau di sumber staging-nya untuk clone berikutnya) lalu jalankan ulang dari menu Redis ACL bila diinginkan."
    return 1
  fi

  # LSCWP object-cache option keys — single array, easy to retune per
  # plugin version without touching the sync logic below.
  local -A lscwp_opts=(
    [object_cache]="1"
    [object--cache_host]="127.0.0.1"
    [object--cache_port]="6379"
    [object--cache_user]="${redis_user}"
    [object--cache_pswd]="${redis_pass}"
    [object--cache_db]="${redis_db_id}"
  )

  local key ok=0 fail=0
  for key in "${!lscwp_opts[@]}"; do
    if _redis_wp_run "$docroot" litespeed-option set "$key" "${lscwp_opts[$key]}" >/dev/null 2>>"$WPM_LOG_FILE"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      log_warn "redis_sync_lscwp: gagal set opsi LSCWP '${key}' untuk app '${app}' (detail: ${WPM_LOG_FILE})"
    fi
  done

  if ! _redis_wp_run "$docroot" litespeed-purge all >/dev/null 2>>"$WPM_LOG_FILE"; then
    log_warn "redis_sync_lscwp: 'wp litespeed-purge all' gagal untuk app '${app}' (detail: ${WPM_LOG_FILE})"
  fi

  if [[ "$fail" -gt 0 ]]; then
    log_action "Sinkron kredensial Redis ke LSCWP app '${app}': ${ok} opsi berhasil, ${fail} gagal"
    return 1
  fi

  log_action "Kredensial Redis app '${app}' (user ${redis_user}, DB ${redis_db_id}) disinkronkan ke LSCWP"
  return 0
}

# redis_flush_app_db APP — FLUSHDBs only the app's own REDIS_DB_ID via the
# admin connection. Used by tools.sh's Clear Web App Cache action; never
# touches other apps' data (isolation per §6.5/§F-4).
redis_flush_app_db() {
  local app="$1"

  if [[ -z "$app" ]]; then
    log_error "redis_flush_app_db: APP wajib diisi"
    return 1
  fi

  local db_id
  db_id="$(app_get "$app" REDIS_DB_ID)"
  if [[ -z "$db_id" ]]; then
    log_warn "redis_flush_app_db: app '${app}' tidak memiliki REDIS_DB_ID, dilewati"
    return 1
  fi
  if [[ ! "$db_id" =~ ^[0-9]+$ ]] || (( db_id < 1 || db_id > 63 )); then
    log_error "redis_flush_app_db: REDIS_DB_ID '${db_id}' milik app '${app}' tidak valid (harus 1-63), FLUSHDB dibatalkan"
    return 1
  fi

  if redis_admin_cli -n "$db_id" FLUSHDB >/dev/null 2>&1; then
    log_action "Redis DB ${db_id} (app '${app}') di-flush"
    return 0
  fi

  log_error "redis_flush_app_db: gagal FLUSHDB Redis DB ${db_id} untuk app '${app}'"
  return 1
}
