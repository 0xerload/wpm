#!/usr/bin/env bash
#
# lib/clone.sh — WPM clone engine.
#
# Implements PRD §F-2 (Clone Web App), §4.3 (flow), §F-3e (Delete Web App)
# and the rollback/purge machinery referenced in §9 (risks/mitigation).
#
# Responsibilities (§5.4):
#   - clone_wizard      : interactive wizard (source, N copies, per-copy
#                          name/db/domain with smart defaults, summary,
#                          confirm, sequential execution, final report).
#   - clone_execute_one  : the 8-step pipeline for a single planned clone.
#   - clone_rollback     : best-effort cleanup of a half-finished clone.
#   - app_delete         : F-3e delete flow (confirm x2, optional backup).
#   - _app_purge         : private removal primitive shared by the two
#                          above (per contract — do not duplicate).
#
# This file is a lib — it must be *sourced*, never executed directly, and
# must never `set -e`/`set -u` globally (that would leak into the sourcing
# shell). Every public function below does its own explicit error checking
# and never assumes a prior step succeeded without checking its exit code.
#
# Calling convention note (specific to this file): clone_execute_one prints
# real-time, human-readable progress via log_info/log_warn (which — per
# core.sh — *also* echo to stdout). Because of that, this file does NOT use
# "echo the result on stdout, capture via $(...)" for clone_execute_one's
# final outcome (that would mix the status word into the progress output).
# Instead clone_execute_one communicates its outcome through two globals,
# set right before it returns:
#   CLONE_LAST_STATUS  — "https" | "http" | "failed"
#   CLONE_LAST_REASON  — short human-readable reason (mainly set on failure)
# Its numeric return code (0/1) reflects whether the app is left live
# (0 — steps 1-7 succeeded, regardless of step 8/SSL outcome) or was rolled
# back (1 — failure in steps 1-7). clone_wizard reads the globals
# immediately after each call, before invoking the next one.

[[ -n "${WPM_LIB_CLONE_LOADED:-}" ]] && return
readonly WPM_LIB_CLONE_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/clone.sh harus di-source, bukan dieksekusi langsung." >&2
  exit 1
fi

# Resolve this file's directory so dependent libs load correctly regardless
# of whether WPM is running from the repo checkout or from $WPM_HOME.
# Include-guards in each dependency make re-sourcing harmless.
_WPM_CLONE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./core.sh
source "$_WPM_CLONE_LIB_DIR/core.sh"
# shellcheck source=./ols.sh
source "$_WPM_CLONE_LIB_DIR/ols.sh"
# shellcheck source=./redis.sh
source "$_WPM_CLONE_LIB_DIR/redis.sh"
# shellcheck source=./ssl.sh
source "$_WPM_CLONE_LIB_DIR/ssl.sh"
# shellcheck source=./php.sh
source "$_WPM_CLONE_LIB_DIR/php.sh"
# shellcheck source=./tools.sh
source "$_WPM_CLONE_LIB_DIR/tools.sh"

unset _WPM_CLONE_LIB_DIR

# Outcome globals for clone_execute_one — see calling-convention note above.
CLONE_LAST_STATUS=""
CLONE_LAST_REASON=""

# ============================================================================
# Private helpers
# ============================================================================

# _clone_in_array NEEDLE arr... — 0 if NEEDLE is one of the remaining args.
_clone_in_array() {
  local needle="$1"
  shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

# _clone_domain_taken DOMAIN — 0 if DOMAIN is already used by any registered
# app (checked against the registry only — filesystem/DB have no notion of
# "domain").
_clone_domain_taken() {
  local domain="$1" a
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    [[ "$(app_get "$a" DOMAIN)" == "$domain" ]] && return 0
  done < <(list_apps)
  return 1
}

# _clone_db_name_taken NAME — 0 if NAME collides with a registered app's
# DB_NAME or with an actual MySQL database already on the server (covers
# unmanaged/manually-created databases too).
_clone_db_name_taken() {
  local name="$1" a
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    [[ "$(app_get "$a" DB_NAME)" == "$name" ]] && return 0
  done < <(list_apps)
  while IFS= read -r a; do
    [[ "$a" == "$name" ]] && return 0
  done < <(db_list_databases 2>/dev/null)
  return 1
}

# _clone_wp_run DOCROOT args... — runs `wp` against DOCROOT as the
# file-owning web user when possible (sudo -u), else falls back to running
# directly as root with --allow-root. Mirrors lib/redis.sh's
# `_redis_wp_run` convention exactly so wp-cli is always invoked the same
# way across this codebase. Never dies on a missing `wp` binary — returns 1
# so callers can treat it as a normal (recoverable) step failure.
_clone_wp_run() {
  local docroot="$1"
  shift

  if ! command -v wp >/dev/null 2>&1; then
    log_error "_clone_wp_run: perintah 'wp' (wp-cli) tidak ditemukan di PATH"
    return 1
  fi

  local web_user
  web_user="$(ols_detect_web_user)"
  web_user="${web_user%%:*}"
  [[ -z "$web_user" ]] && web_user="nobody"

  if [[ "$web_user" != "root" ]] \
     && command -v sudo >/dev/null 2>&1 \
     && id "$web_user" >/dev/null 2>&1; then
    sudo -u "$web_user" -- wp --path="$docroot" "$@"
  else
    wp --path="$docroot" --allow-root "$@"
  fi
}

# _clone_wp_config_set_define FILE KEY VALUE — rewrites (or, if absent,
# inserts) a `define( 'KEY', 'VALUE' );` line in a wp-config.php-style FILE.
# KEY is always one of our own fixed literal constant names (never
# user-controlled) so embedding it directly in the grep/sed patterns below
# is safe; VALUE is always alnum-only (rand_password / validated DB
# identifiers) so it never needs delimiter escaping either.
_clone_wp_config_set_define() {
  local file="$1" key="$2" value="$3"
  local line_no

  line_no="$(grep -nE "define\([[:space:]]*['\"]${key}['\"][[:space:]]*," "$file" 2>/dev/null \
    | head -n1 | cut -d: -f1)"

  if [[ -n "$line_no" ]]; then
    if ! sed -i "${line_no}s#.*#define( '${key}', '${value}' );#" "$file"; then
      log_error "_clone_wp_config_set_define: gagal mengganti baris ${key} di ${file}"
      return 1
    fi
  else
    local insert_line="define( '${key}', '${value}' );"
    if grep -qF "That's all, stop editing" "$file" 2>/dev/null; then
      sed -i "/That's all, stop editing/i ${insert_line}" "$file"
    else
      sed -i "1a ${insert_line}" "$file"
    fi
  fi
  return 0
}

# _clone_wp_config_upsert_block FILE TAG BLOCK_FILE — idempotently
# inserts/replaces a "// BEGIN WPM:<TAG> ... // END WPM:<TAG>" region in
# FILE with BLOCK_FILE's contents (which must itself contain the marker
# lines). Same marker-block idempotency convention used across the
# codebase for httpd_config.conf edits, applied here to wp-config.php.
_clone_wp_config_upsert_block() {
  local file="$1" tag="$2" block_file="$3"
  local begin="// BEGIN WPM:${tag}"
  local end="// END WPM:${tag}"
  local tmp
  tmp="$(mktemp)" || { log_error "_clone_wp_config_upsert_block: mktemp gagal"; return 1; }

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
  elif grep -qF "That's all, stop editing" "$file" 2>/dev/null; then
    awk -v blockfile="$block_file" '
      /That.?s all, stop editing/ && !ins {
        while ((getline line < blockfile) > 0) print line
        close(blockfile)
        ins = 1
      }
      { print }
    ' "$file" > "$tmp"
  else
    { head -n1 "$file"; cat "$block_file"; tail -n +2 "$file"; } > "$tmp"
  fi

  cat "$tmp" > "$file"
  rm -f "$tmp"
  return 0
}

# _patch_wp_config DOCROOT DB_NAME DB_USER DB_PASS REDIS_USER REDIS_PASS
#                   REDIS_DB_ID
# §F-2 step 4: patches the newly-copied wp-config.php in place with the new
# DB credentials, fresh salts (regenerated on every clone so sessions never
# collide between source and clone — §7.2), and the new app's Redis
# credentials (kept as WPM_REDIS_* constants for reference/drop-ins; the
# authoritative sync into LSCWP itself happens later, at step 8, via
# redis_sync_lscwp — see §7.2/§9 on why Redis wiring is deferred).
_patch_wp_config() {
  local docroot="$1" db_name="$2" db_user="$3" db_pass="$4"
  local redis_user="$5" redis_pass="$6" redis_db_id="$7"
  local wp_config="${docroot}/wp-config.php"

  if [[ ! -f "$wp_config" ]]; then
    log_error "_patch_wp_config: wp-config.php tidak ditemukan di ${docroot}"
    return 1
  fi
  chmod u+w "$wp_config" 2>/dev/null

  _clone_wp_config_set_define "$wp_config" "DB_NAME" "$db_name" || return 1
  _clone_wp_config_set_define "$wp_config" "DB_USER" "$db_user" || return 1
  _clone_wp_config_set_define "$wp_config" "DB_PASSWORD" "$db_pass" || return 1

  local salt_keys=(
    AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY
    AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT
  )
  local k salt
  for k in "${salt_keys[@]}"; do
    salt="$(rand_password 64)"
    _clone_wp_config_set_define "$wp_config" "$k" "$salt" || return 1
  done

  local block
  block="$(mktemp)" || { log_error "_patch_wp_config: mktemp gagal"; return 1; }
  {
    printf '// BEGIN WPM:REDIS\n'
    printf "define( 'WPM_REDIS_HOST', '127.0.0.1' );\n"
    printf "define( 'WPM_REDIS_PORT', '6379' );\n"
    printf "define( 'WPM_REDIS_USER', '%s' );\n" "$redis_user"
    printf "define( 'WPM_REDIS_PASSWORD', '%s' );\n" "$redis_pass"
    printf "define( 'WPM_REDIS_DATABASE', '%s' );\n" "$redis_db_id"
    printf '// END WPM:REDIS\n'
  } > "$block"
  _clone_wp_config_upsert_block "$wp_config" "REDIS" "$block"
  rm -f "$block"

  log_action "_patch_wp_config: wp-config.php dipatch (DB=${db_name}, redis_user=${redis_user}, redis_db=${redis_db_id})"
  return 0
}

# _clone_validation_failed NEW_APP STEP_LABEL MSG — failure path for [0/8]
# pre-flight validation, i.e. everything checked *before* app_set_all
# pre-registers NEW_APP's planned state. Nothing has been created yet at
# this point (not even a registry entry), so there is nothing to roll back
# — and in the specific "app already registered" collision case, NEW_APP
# may in fact be a pre-existing, unrelated, live app, so calling rollback
# on it would destroy that app instead of merely aborting. This only logs
# the failure and records the outcome; it never calls clone_rollback. Does
# NOT itself `return` — the call site is responsible for `return 1` right
# after calling this.
_clone_validation_failed() {
  local new_app="$1" step_label="$2" msg="$3"
  log_error "Clone '${new_app}': ${step_label} gagal — ${msg}"
  log_action "clone_execute_one: app=${new_app} GAGAL pada ${step_label} (${msg}) — dibatalkan tanpa rollback (belum ada yang dibuat)"
  CLONE_LAST_STATUS="failed"
  CLONE_LAST_REASON="${step_label}: ${msg}"
}

# _clone_step_failed NEW_APP STEP_LABEL MSG — shared failure path for
# steps 1-7 (i.e. only AFTER app_set_all has pre-registered NEW_APP's
# planned state): logs the failure (audit trail + visible error), triggers
# a best-effort rollback of NEW_APP, and records the outcome in the
# CLONE_LAST_STATUS/CLONE_LAST_REASON globals. Does NOT itself `return` —
# the call site is responsible for `return 1` right after calling this.
# Must NOT be used for [0/8] pre-flight validation — use
# _clone_validation_failed for that instead (see its comment for why).
_clone_step_failed() {
  local new_app="$1" step_label="$2" msg="$3"
  log_error "Clone '${new_app}': ${step_label} gagal — ${msg}"
  log_action "clone_execute_one: app=${new_app} GAGAL pada ${step_label} (${msg}) — menjalankan rollback"
  clone_rollback "$new_app"
  CLONE_LAST_STATUS="failed"
  CLONE_LAST_REASON="${step_label}: ${msg}"
}

# _app_purge APP — shared removal primitive used by BOTH clone_rollback
# (partial-state cleanup on clone failure) and app_delete (full F-3e
# delete). Never fails loudly: every sub-step is best-effort, logs whatever
# it could not clean, and always continues to the next sub-step. Always
# ends with a graceful OLS restart so removed vhost/listener edits take
# effect immediately.
_app_purge() {
  local app="$1"
  if [[ -z "$app" ]]; then
    log_error "_app_purge: nama app wajib diisi"
    return 1
  fi

  local vh_root domain db_name db_user redis_user
  vh_root="$(app_get "$app" VH_ROOT)"
  domain="$(app_get "$app" DOMAIN)"
  db_name="$(app_get "$app" DB_NAME)"
  db_user="$(app_get "$app" DB_USER)"
  redis_user="$(app_get "$app" REDIS_USER)"

  log_action "_app_purge: mulai app=${app} vh_root=${vh_root} domain=${domain} db=${db_name} redis_user=${redis_user}"

  # 1. OLS virtualhost block + listener maps (both listeners, best-effort —
  #    a half-finished clone may only have one of these, or neither).
  ols_remove_vhost_block "$app" \
    || log_warn "_app_purge: tidak ada blok virtualhost untuk dihapus (app=${app})"
  ols_remove_listener_map "$(ols_https_listener_name)" "$app" \
    || log_warn "_app_purge: tidak ada map listener HTTPS untuk dihapus (app=${app})"
  ols_remove_listener_map "$(ols_http_listener_name)" "$app" \
    || log_warn "_app_purge: tidak ada map listener HTTP untuk dihapus (app=${app})"
  [[ -n "$domain" ]] && ols_hosts_remove_loopback "$domain"

  # 2. vhost config directory
  if [[ -n "$app" && -d "${OLS_VHOST_DIR}/${app}" ]]; then
    if rm -rf -- "${OLS_VHOST_DIR:?}/${app}"; then
      log_action "_app_purge: direktori vhost ${OLS_VHOST_DIR}/${app} dihapus"
    else
      log_warn "_app_purge: gagal menghapus direktori vhost ${OLS_VHOST_DIR}/${app}"
    fi
  fi

  # 3. site files (whole VH_ROOT — docroot + logs + anything else it holds)
  #    Defense-in-depth: VH_ROOT is always safely derived for apps created
  #    via clone_execute_one, but it can also be populated by
  #    ols_import_vhost straight from a hand-edited httpd_config.conf
  #    `vhRoot` directive with no depth/sanity check of its own. Refuse to
  #    rm -rf anything that resolves to "/" or another dangerously shallow
  #    path — a real site root is always at least two levels deep.
  if [[ -n "$vh_root" && -d "$vh_root" ]]; then
    local vh_root_real
    vh_root_real="$(cd "$vh_root" 2>/dev/null && pwd -P)"
    if [[ -z "$vh_root_real" || "$vh_root_real" == "/" \
          || "$(tr -dc '/' <<<"$vh_root_real" | wc -c)" -lt 2 ]]; then
      log_error "_app_purge: VH_ROOT '${vh_root}' (resolved: '${vh_root_real:-?}') tidak aman untuk dihapus (path terlalu dangkal) — dilewati demi keamanan"
    elif rm -rf -- "$vh_root"; then
      log_action "_app_purge: direktori situs ${vh_root} dihapus"
    else
      log_warn "_app_purge: gagal menghapus direktori situs ${vh_root}"
    fi
  fi

  # 4. TLS certificate (optional per §F-3e — only present if SSL ever
  #    succeeded for this app; harmless/no-op otherwise).
  if [[ -n "$domain" && -d "/etc/letsencrypt/live/${domain}" ]] \
     && command -v certbot >/dev/null 2>&1; then
    if certbot delete --cert-name "$domain" --non-interactive >>"$WPM_LOG_FILE" 2>&1; then
      log_action "_app_purge: sertifikat Let's Encrypt untuk ${domain} dihapus"
    else
      log_warn "_app_purge: gagal menghapus sertifikat Let's Encrypt untuk ${domain}"
    fi
  fi

  # 5. database + user
  if [[ -n "$db_name" ]]; then
    db_drop_database "$db_name" || log_warn "_app_purge: gagal menghapus database '${db_name}'"
  fi
  if [[ -n "$db_user" ]]; then
    db_drop_user "$db_user" || log_warn "_app_purge: gagal menghapus user database '${db_user}'"
  fi

  # 6. Redis ACL user (+ flush its DB ID to reclaim it)
  if [[ -n "$redis_user" ]]; then
    redis_remove_acl_user "$app" "$redis_user" \
      || log_warn "_app_purge: gagal membersihkan Redis ACL user '${redis_user}'"
  fi

  # 7. registry entry (conf + vhconf snapshot)
  app_delete_conf "$app"
  log_action "_app_purge: entry registry app=${app} dihapus"

  # 8. graceful restart so the removed vhost/listener changes take effect
  ols_graceful_restart \
    || log_warn "_app_purge: restart graceful OLS gagal setelah membersihkan app=${app}"

  log_action "_app_purge: selesai app=${app}"
  return 0
}

# ============================================================================
# Public contract — lib/clone.sh MUST export
# ============================================================================

# clone_rollback NEW_APP — best-effort cleanup of whatever partial state
# exists for NEW_APP after a failed clone_execute_one (steps 1-7). Never
# fails loudly: logs whatever it could not clean and always returns 0.
clone_rollback() {
  local app="$1"
  if [[ -z "$app" ]]; then
    log_error "clone_rollback: nama app wajib diisi"
    return 1
  fi

  log_warn "Rollback: membersihkan artefak setengah-jadi untuk app '${app}'..."
  log_action "clone_rollback: mulai app=${app}"
  _app_purge "$app"
  log_action "clone_rollback: selesai app=${app}"
  return 0
}

# clone_execute_one SRC_APP NEW_APP NEW_DOMAIN NEW_DB
#
# Runs the §F-2 8-step pipeline for a single planned clone, in exact order:
#   [1/8] rsync source VH_ROOT -> new VH_ROOT (exclude wp-content/cache,
#         wp-content/litespeed, and the old app's logs/)
#   [2/8] CREATE DATABASE + user (random 24-char password)
#   [3/8] streaming mysqldump | mysql import (db_dump_import)
#   [4/8] patch wp-config.php: new DB creds, fresh salts, new Redis creds
#   [5/8] wp search-replace old domain -> new domain (safe for serialized
#         data — never sed)
#   [6/8] copy+patch vhconf, write virtualhost block + :80 listener map,
#         graceful restart
#   [7/8] fix ownership
#   [8/8] DNS check -> certbot -> vhssl + :443 map -> restart -> Redis ACL
#         user -> LSCWP credential sync + purge (non-blocking)
#
# Failure in steps 1-7 rolls back and returns 1 (CLONE_LAST_STATUS=failed).
# Failure in step 8 never rolls back; the app stays live on HTTP and this
# still returns 0 (CLONE_LAST_STATUS is "https" or "http" depending on
# whether SSL actually got issued). See the calling-convention note at the
# top of this file for how the outcome is communicated.
clone_execute_one() {
  local src_app="$1" new_app="$2" new_domain="$3" new_db="$4"
  CLONE_LAST_STATUS=""
  CLONE_LAST_REASON=""

  # --- Pre-flight validation (nothing created yet if any of this fails —
  #     use _clone_validation_failed, NEVER _clone_step_failed, here: no
  #     rollback must be triggered before app_set_all pre-registers
  #     new_app below, since in the collision case new_app may already be
  #     a pre-existing, unrelated, live app) ---
  if [[ -z "$src_app" || -z "$new_app" || -z "$new_domain" || -z "$new_db" ]]; then
    _clone_validation_failed "${new_app:-?}" "[0/8] validasi" "argumen wajib tidak lengkap"
    return 1
  fi
  if ! app_exists "$src_app"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "app sumber '${src_app}' tidak ditemukan"
    return 1
  fi
  if [[ "$src_app" == "$new_app" ]]; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "nama app baru tidak boleh sama dengan sumber"
    return 1
  fi
  if ! is_valid_app_name "$new_app"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "nama app tidak valid: '${new_app}'"
    return 1
  fi
  if app_exists "$new_app"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "app '${new_app}' sudah terdaftar"
    return 1
  fi
  if ! is_valid_domain "$new_domain"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "domain tidak valid: '${new_domain}'"
    return 1
  fi
  if _clone_domain_taken "$new_domain"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "domain '${new_domain}' sudah dipakai app lain"
    return 1
  fi
  if ! is_valid_db_name "$new_db"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "nama database tidak valid: '${new_db}'"
    return 1
  fi
  if _clone_db_name_taken "$new_db"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "database '${new_db}' sudah dipakai"
    return 1
  fi

  local src_vh_root src_docroot src_db_name src_php_handler
  src_vh_root="$(app_get "$src_app" VH_ROOT)"
  src_docroot="$(app_get "$src_app" DOCROOT)"
  src_db_name="$(app_get "$src_app" DB_NAME)"
  src_php_handler="$(app_get "$src_app" PHP_HANDLER)"

  if [[ -z "$src_vh_root" || -z "$src_docroot" || -z "$src_db_name" ]]; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "data registry app sumber '${src_app}' tidak lengkap"
    return 1
  fi
  if [[ ! -d "$src_vh_root" ]]; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "direktori sumber '${src_vh_root}' tidak ditemukan"
    return 1
  fi

  # --- Compute derived paths + fresh credentials ---
  local parent_dir rel_docroot new_vh_root new_docroot
  parent_dir="$(dirname "$src_vh_root")"
  new_vh_root="${parent_dir}/${new_app}"
  rel_docroot="${src_docroot#"$src_vh_root"}"
  rel_docroot="${rel_docroot#/}"
  if [[ -n "$rel_docroot" ]]; then
    new_docroot="${new_vh_root}/${rel_docroot}"
  else
    new_docroot="$new_vh_root"
  fi

  local db_pass redis_user redis_pass redis_db_id
  db_pass="$(rand_password)"
  redis_user="app_${new_app}"
  redis_pass="$(rand_password)"
  redis_db_id="$(redis_alloc_db_id)"
  if [[ -z "$redis_db_id" || ! "$redis_db_id" =~ ^[0-9]+$ ]]; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "gagal mengalokasikan Redis DB ID (kapasitas ~60 app mungkin sudah tercapai — §7.4)"
    return 1
  fi

  # --- Pre-register the planned state so rollback always has something to
  #     look up, even if step 1 fails immediately. ---
  app_set_all "$new_app" \
    APP_NAME="$new_app" \
    SOURCE_APP="$src_app" \
    DOMAIN="$new_domain" \
    VH_ROOT="$new_vh_root" \
    DOCROOT="$new_docroot" \
    DB_NAME="$new_db" \
    DB_USER="$new_db" \
    DB_PASS="$db_pass" \
    PHP_HANDLER="$src_php_handler" \
    REDIS_DB_ID="$redis_db_id" \
    REDIS_USER="$redis_user" \
    REDIS_PASS="$redis_pass" \
    SSL_STATUS="none" \
    SSL_ISSUED_AT="" \
    CREATED_AT="$(now_iso)" \
    WPM_VERSION="$WPM_VERSION"

  log_info "${C_BOLD}Clone '${src_app}' -> '${new_app}' (domain: ${new_domain})${C_RESET}"
  log_action "clone_execute_one: mulai src=${src_app} new=${new_app} domain=${new_domain} db=${new_db}"

  # --- [1/8] rsync file sumber -> VH_ROOT baru --------------------------
  log_info "[1/8] Menyalin file situs..."
  mkdir -p "$new_vh_root" 2>/dev/null
  if ! run_nice rsync -a \
        --exclude 'logs/' \
        --exclude 'wp-content/cache/' \
        --exclude 'wp-content/litespeed/' \
        --exclude '*/wp-content/cache/' \
        --exclude '*/wp-content/litespeed/' \
        --exclude '**/wp-content/cache/' \
        --exclude '**/wp-content/litespeed/' \
        --exclude 'wp-content/object-cache.php' \
        --exclude '*/wp-content/object-cache.php' \
        --exclude '**/wp-content/object-cache.php' \
        -- "${src_vh_root%/}/" "${new_vh_root%/}/" >>"$WPM_LOG_FILE" 2>&1; then
    _clone_step_failed "$new_app" "[1/8] rsync" "gagal menyalin file dari '${src_vh_root}'"
    return 1
  fi
  mkdir -p "${new_vh_root}/logs" 2>/dev/null
  if [[ ! -d "$new_docroot" ]]; then
    _clone_step_failed "$new_app" "[1/8] rsync" "docroot hasil salin '${new_docroot}' tidak ditemukan"
    return 1
  fi
  log_action "clone_execute_one[${new_app}]: [1/8] rsync selesai"

  # --- [2/8] CREATE DATABASE + user -------------------------------------
  log_info "[2/8] Membuat database & user MySQL..."
  if ! db_create_database "$new_db"; then
    _clone_step_failed "$new_app" "[2/8] database" "CREATE DATABASE gagal"
    return 1
  fi
  if ! db_create_user "$new_db" "$db_pass"; then
    _clone_step_failed "$new_app" "[2/8] database" "CREATE USER gagal"
    return 1
  fi
  if ! db_grant_all "$new_db" "$new_db"; then
    _clone_step_failed "$new_app" "[2/8] database" "GRANT gagal"
    return 1
  fi
  log_action "clone_execute_one[${new_app}]: [2/8] database & user dibuat"

  # --- [3/8] streaming dump | import ------------------------------------
  log_info "[3/8] Streaming dump & import database (mysqldump | mysql)..."
  if ! db_dump_import "$src_db_name" "$new_db"; then
    _clone_step_failed "$new_app" "[3/8] dump/import" "streaming dump+import '${src_db_name}' -> '${new_db}' gagal"
    return 1
  fi
  log_action "clone_execute_one[${new_app}]: [3/8] dump+import selesai"

  # --- [4/8] patch wp-config.php ----------------------------------------
  log_info "[4/8] Mem-patch wp-config.php (kredensial DB, salts, kredensial Redis)..."
  if ! _patch_wp_config "$new_docroot" "$new_db" "$new_db" "$db_pass" \
        "$redis_user" "$redis_pass" "$redis_db_id"; then
    _clone_step_failed "$new_app" "[4/8] wp-config" "patch wp-config.php gagal"
    return 1
  fi
  log_action "clone_execute_one[${new_app}]: [4/8] wp-config.php dipatch"

  # Defensive: kalau app sumber punya drop-in object-cache.php (LiteSpeed
  # Cache atau plugin cache lain) yang somehow ikut tersalin meski sudah
  # di-exclude di [1/8], pastikan tidak ada nilai yang di-cache dari
  # sebelum clone yang ikut terbawa — non-fatal, murni pencegahan.
  _clone_wp_run "$new_docroot" cache flush >>"$WPM_LOG_FILE" 2>&1 \
    || log_warn "clone_execute_one[${new_app}]: 'wp cache flush' gagal (non-fatal)"

  # --- [5/8] wp search-replace domain lama -> domain baru ----------------
  log_info "[5/8] wp search-replace domain lama -> domain baru (aman untuk data serialized)..."
  local src_domain
  src_domain="$(app_get "$src_app" DOMAIN)"
  if [[ -z "$src_domain" ]]; then
    _clone_step_failed "$new_app" "[5/8] search-replace" "domain app sumber tidak diketahui"
    return 1
  fi
  if ! _clone_wp_run "$new_docroot" search-replace "$src_domain" "$new_domain" \
        --all-tables --skip-columns=guid >>"$WPM_LOG_FILE" 2>&1; then
    _clone_step_failed "$new_app" "[5/8] search-replace" "wp search-replace gagal"
    return 1
  fi
  log_action "clone_execute_one[${new_app}]: [5/8] search-replace ${src_domain} -> ${new_domain} selesai"

  # --- [6/8] vhconf copy+patch + virtualhost block + listener map + restart
  log_info "[6/8] Menyalin & mem-patch vhconf, menambah virtualhost + listener, restart graceful..."
  local new_vhconf
  new_vhconf="$(ols_copy_and_patch_vhconf "$src_app" "$new_app" "$new_domain")"
  if [[ -z "$new_vhconf" || ! -f "$new_vhconf" ]]; then
    _clone_step_failed "$new_app" "[6/8] vhconf" "gagal menyalin/mem-patch vhconf dari '${src_app}'"
    return 1
  fi
  ols_set_access_log "$new_app" \
    || log_warn "clone_execute_one[${new_app}]: normalisasi access log gagal (non-fatal, bisa diperbaiki via Rebuild Config)"
  if ! ols_write_vhost_block "$new_app" "$new_vh_root" "$new_vhconf"; then
    _clone_step_failed "$new_app" "[6/8] vhconf" "gagal menulis blok virtualhost"
    return 1
  fi
  # NOTE: ols_write_listener_map returns 1 (does not die/exit) if no
  # listener is bound to port :80 under any name — ols_http_listener_name
  # auto-detects whichever listener is actually bound there (real
  # OpenLiteSpeed installs commonly name it something other than
  # "Default", e.g. the stock "Example" listener), falling back to the
  # literal "Default" only if nothing is bound to :80 at all.
  if ! ols_write_listener_map "$(ols_http_listener_name)" "$new_app" "$new_domain"; then
    _clone_step_failed "$new_app" "[6/8] vhconf" "gagal memetakan listener HTTP (:80)"
    return 1
  fi
  ols_snapshot_vhconf "$new_app" \
    || log_warn "clone_execute_one[${new_app}]: snapshot vhconf gagal (non-fatal)"
  if ! ols_graceful_restart; then
    _clone_step_failed "$new_app" "[6/8] vhconf" "restart graceful OLS gagal"
    return 1
  fi
  log_action "clone_execute_one[${new_app}]: [6/8] vhconf+virtualhost+listener+restart selesai"

  # --- [7/8] fix ownership -------------------------------------------------
  log_info "[7/8] Memperbaiki ownership file..."
  if ! tools_fix_ownership "$new_app"; then
    _clone_step_failed "$new_app" "[7/8] ownership" "tools_fix_ownership gagal"
    return 1
  fi
  log_action "clone_execute_one[${new_app}]: [7/8] ownership diperbaiki"

  # ======================================================================
  # Steps 1-7 all succeeded — the app is live on HTTP from this point on.
  # Everything below (step 8) is non-blocking per §F-2/§9: a failure here
  # never rolls back, it only affects SSL_STATUS.
  # ======================================================================
  log_info "[8/8] Cek DNS, terbitkan SSL, siapkan Redis ACL, sinkron LSCWP (non-blocking)..."
  # ssl_run_for_new_app also calls log_info/log_warn internally (which, per
  # core.sh, echo to stdout too, not just the log file), so its captured
  # output here is multi-line; the actual "active"/"failed"/"none" status
  # word is always the LAST line it prints (every code path in ssl.sh ends
  # with exactly one such printf right before returning). It also already
  # persists SSL_STATUS/SSL_ISSUED_AT to the registry itself once the app
  # is registered (true here, since we pre-registered above) — so no
  # separate registry update is needed on our side.
  local ssl_raw ssl_result
  ssl_raw="$(ssl_run_for_new_app "$new_app" "$new_domain" "$new_docroot")"
  ssl_result="$(tail -n1 <<<"$ssl_raw")"
  case "$ssl_result" in
    active | failed | none) ;;
    *) ssl_result="none" ;;
  esac

  if ! redis_create_acl_user "$new_app" "$redis_user" "$redis_pass" "$redis_db_id"; then
    log_warn "clone_execute_one[${new_app}]: gagal membuat Redis ACL user (non-blocking — object cache fallback tanpa Redis, §9)"
  elif ! redis_sync_lscwp "$new_app"; then
    log_warn "clone_execute_one[${new_app}]: gagal sinkron kredensial Redis ke LSCWP (non-blocking)"
  fi

  log_action "clone_execute_one[${new_app}]: [8/8] selesai (ssl=${ssl_result})"

  if [[ "$ssl_result" == "active" ]]; then
    CLONE_LAST_STATUS="https"
    log_info "${C_GREEN}Clone '${new_app}' selesai — live di https://${new_domain}${C_RESET}"
  else
    CLONE_LAST_STATUS="http"
    CLONE_LAST_REASON="SSL ${ssl_result} (retry via menu Retry SSL)"
    log_info "${C_YELLOW}Clone '${new_app}' selesai — live di http://${new_domain} (SSL ${ssl_result}, retry via menu)${C_RESET}"
  fi

  log_action "clone_execute_one: SELESAI src=${src_app} new=${new_app} status=${CLONE_LAST_STATUS}"
  return 0
}

# ============================================================================
# Clone dari sumber staging (folder file WP + dump SQL mentah) — sumber
# tambahan selain app terdaftar. Lihat WPM_STAGE_DIR (lib/core.sh) untuk
# struktur folder yang diharapkan:
#   $WPM_STAGE_DIR/<nama>/data/   isi docroot WordPress (termasuk
#                                 wp-config.php)
#   $WPM_STAGE_DIR/<nama>/db/     satu/lebih file .sql atau .sql.gz
# Fungsi-fungsi di bawah ini adalah helper + satu pipeline paralel
# (clone_execute_one_from_staging) untuk sumber ini. clone_wizard memanggil
# clone_execute_one ATAU clone_execute_one_from_staging (tergantung sumber
# yang dipilih pengguna) lewat jalur eksekusi & pelaporan akhir yang sama
# persis — lihat perubahan pada clone_wizard di bawah.
# ============================================================================

# _clone_valid_stage_name NAME — defense-in-depth gate untuk nama subfolder
# staging sebelum bisa dipilih sebagai sumber clone. Prinsip sama dengan
# is_valid_app_name (panjang dibatasi + kelas karakter aman yang tetap),
# tapi juga mengizinkan underscore karena nama folder staging biasanya
# ditentukan bebas oleh siapa pun yang menaruh snapshot di sana (mis.
# "mei_26" untuk dump bulan Mei 2026) dan tidak pernah dipakai langsung
# sebagai nama app/db/domain.
_clone_valid_stage_name() {
  local name="${1:-}"
  (( ${#name} >= 1 && ${#name} <= 32 )) || return 1
  [[ "$name" =~ ^[a-z0-9_-]+$ ]]
}

# _clone_list_staging_sources — echo (satu per baris) setiap nama subfolder
# di bawah $WPM_STAGE_DIR yang merupakan sumber clone staging yang valid
# dan siap pakai: nama aman (_clone_valid_stage_name), punya data/wp-config.php
# yang bisa dibaca, dan punya minimal satu berkas db/*.sql atau db/*.sql.gz.
# Menyaring diam-diam — folder yang tidak aman/tidak lengkap cukup tidak
# muncul di daftar, bukan error.
_clone_list_staging_sources() {
  mkdir -p "$WPM_STAGE_DIR" 2>/dev/null

  local d name
  shopt -s nullglob
  for d in "$WPM_STAGE_DIR"/*/; do
    name="$(basename "$d")"
    _clone_valid_stage_name "$name" || continue
    [[ -r "$WPM_STAGE_DIR/$name/data/wp-config.php" ]] || continue

    local -a sql_files=("$WPM_STAGE_DIR/$name/db/"*.sql "$WPM_STAGE_DIR/$name/db/"*.sql.gz)
    (( ${#sql_files[@]} == 0 )) && continue

    printf '%s\n' "$name"
  done
  shopt -u nullglob
}

# _clone_staging_sql_files STAGE_NAME — echo path lengkap setiap berkas
# *.sql/*.sql.gz langsung di bawah $WPM_STAGE_DIR/STAGE_NAME/db/, terurut
# nama berkas supaya dump multi-bagian dengan prefix angka (01-schema.sql,
# 02-data.sql, dst.) diimpor sesuai urutan yang benar.
_clone_staging_sql_files() {
  local stage_name="$1"
  local dir="$WPM_STAGE_DIR/$stage_name/db"

  local -a files=()
  shopt -s nullglob
  files=("$dir"/*.sql "$dir"/*.sql.gz)
  shopt -u nullglob

  (( ${#files[@]} == 0 )) && return 0
  printf '%s\n' "${files[@]}" | sort
}

# _clone_db_get_option DB_NAME OPTION_NAME — echoes OPTION_NAME's value
# directly from DB_NAME.wp_options via a raw SQL query (mysql/mariadb
# client, -N -B for clean unadorned output — same db_defaults_file/
# _wpm_mysql_bin pattern as db_list_databases in lib/core.sh), completely
# bypassing WordPress/PHP/wp-cli. Deliberately NOT done via `wp option
# get`, which fully bootstraps WordPress — loading every plugin — before
# it ever prints anything: on a site with old/misbehaving plugins, that
# bootstrap can emit a PHP deprecation/warning/notice line to STDOUT ahead
# of the real value, silently corrupting whatever's captured. OPTION_NAME
# is always one of our own fixed literal strings ("siteurl"/"home"),
# never external input, so it's safe to embed directly in the SQL.
# Assumes the standard `wp_options` table name — a non-default
# $table_prefix isn't supported by this helper (falls through to the
# wp-cli fallback in _clone_detect_old_domain below instead).
_clone_db_get_option() {
  local db_name="$1" option_name="$2"
  is_valid_db_name "$db_name" || return 1

  local defaults out rc
  defaults="$(db_defaults_file)"
  local cmd=("$(_wpm_mysql_bin)")
  [[ -n "$defaults" ]] && cmd+=(--defaults-extra-file="$defaults")
  cmd+=(-N -B "$db_name")

  out="$(printf '%s' "SELECT option_value FROM wp_options WHERE option_name='${option_name}' LIMIT 1;" | "${cmd[@]}" 2>/dev/null)"
  rc=$?
  [[ -n "$defaults" ]] && rm -f "$defaults"
  (( rc != 0 )) && return 1

  printf '%s\n' "$out"
}

# _clone_detect_old_domain DOCROOT [DB_NAME] — echo bare host (tanpa skema,
# tanpa path, tanpa trailing slash) dari url LAMA situs yang baru saja
# diimpor. Dipakai clone_execute_one_from_staging's [5/8] karena sumber
# staging tidak punya registry DOMAIN untuk dibaca (berbeda dari clone
# app-ke-app, yang membaca DOMAIN app sumber langsung dari registry). Echo
# kosong + return 1 kalau semua cara gagal/kosong.
_clone_detect_old_domain() {
  local docroot="$1" db_name="${2:-}"
  local raw url=""

  # Cara utama: query wp_options langsung lewat mysql/mariadb client
  # (_clone_db_get_option), tanpa bootstrap WordPress sama sekali — jadi
  # tidak mungkin tercemar output PHP warning/notice dari plugin apa pun.
  if [[ -n "$db_name" ]]; then
    raw="$(_clone_db_get_option "$db_name" siteurl)"
    if [[ ! "$raw" =~ https?://([^/[:space:]\"\']+) ]]; then
      raw="$(_clone_db_get_option "$db_name" home)"
    fi
  fi

  # Fallback: wp-cli (hanya kalau query langsung di atas tidak berhasil —
  # mis. $table_prefix bukan "wp_" default). Tetap pakai ekstraksi regex
  # di bawah sebagai lapisan pengaman kedua terhadap kontaminasi output.
  if [[ ! "$raw" =~ https?://([^/[:space:]\"\']+) ]]; then
    raw="$(_clone_wp_run "$docroot" option get siteurl 2>/dev/null)"
  fi
  if [[ ! "$raw" =~ https?://([^/[:space:]\"\']+) ]]; then
    raw="$(_clone_wp_run "$docroot" option get home 2>/dev/null)"
  fi
  if [[ "$raw" =~ https?://([^/[:space:]\"\']+) ]]; then
    url="${BASH_REMATCH[1]}"
  fi

  if [[ -z "$url" ]]; then
    return 1
  fi

  printf '%s\n' "$url"
  return 0
}

# ============================================================================
# staging.conf I/O — /etc/wpm/staging.conf (mode 600). Mirrors
# lib/telegram.sh's telegram_conf_get/telegram_conf_set_all exactly (sama
# persis primitif _wpm_conf_get_file/_wpm_conf_write_file, sama mkdir+chmod
# sebelum menulis), hanya menyasar $WPM_STAGING_CONF dengan satu key:
# DEFAULT_PHP_HANDLER.
# ============================================================================

# staging_conf_get KEY — echo nilai KEY di $WPM_STAGING_CONF. Hanya
# DEFAULT_PHP_HANDLER yang punya fallback: baris pertama
# php_list_installed_versions kalau belum diset, kalau itu juga kosong
# fallback ke literal "lsphp82" (sama seperti fallback terakhir yang
# dipakai ols_rebuild_vhconf sendiri).
staging_conf_get() {
  local key="$1"
  local val
  val="$(_wpm_conf_get_file "$WPM_STAGING_CONF" "$key")"

  if [[ -z "$val" ]]; then
    case "$key" in
      DEFAULT_PHP_HANDLER)
        val="$(php_list_installed_versions | head -n1)"
        [[ -z "$val" ]] && val="lsphp82"
        ;;
      *) : ;;
    esac
  fi

  printf '%s\n' "$val"
}

# staging_conf_set_all key1=val1 key2=val2 ... — atomically overwrites the
# whole staging.conf dengan persis key yang diberikan (mode 600), kontrak
# non-merge yang sama seperti app_set_all/telegram_conf_set_all.
staging_conf_set_all() {
  mkdir -p "$WPM_ETC" 2>/dev/null
  chmod 700 "$WPM_ETC" 2>/dev/null

  _wpm_conf_write_file "$WPM_STAGING_CONF" 600 "$@"

  if [[ ! -f "$WPM_STAGING_CONF" ]]; then
    log_error "staging_conf_set_all: gagal menulis $WPM_STAGING_CONF"
    return 1
  fi

  local kv k v logline="staging_conf_set_all: memperbarui ${WPM_STAGING_CONF} —"
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ -z "$k" ]] && continue
    logline+=" ${k}=${v}"
  done
  log_action "$logline"
  return 0
}

# clone_execute_one_from_staging STAGE_NAME NEW_APP NEW_DOMAIN NEW_DB
#
# Staging-source equivalent of clone_execute_one — same 8-step shape, same
# outcome-reporting contract (CLONE_LAST_STATUS/CLONE_LAST_REASON,
# _clone_validation_failed for [0/8], _clone_step_failed for steps 1-7), so
# clone_wizard can render its final report identically regardless of which
# of the two functions it called. Steps [2/8], [4/8], [7/8], [8/8] are
# byte-for-byte the same calls clone_execute_one makes (db_create_database/
# db_create_user/db_grant_all, _patch_wp_config, tools_fix_ownership,
# ssl_run_for_new_app + redis_create_acl_user + redis_sync_lscwp); steps
# [1/8], [3/8], [5/8], [6/8] are staging-specific because there is no live
# source app to rsync/dump/read a domain or vhconf from:
#   [1/8] rsync $WPM_STAGE_DIR/STAGE_NAME/data/ -> docroot baru (bukan
#         VH_ROOT app sumber)
#   [2/8] CREATE DATABASE + user (identik dengan clone_execute_one)
#   [3/8] impor berkas .sql/.sql.gz mentah lewat db_import_sql_file (bukan
#         streaming mysqldump | mysql dari DB live)
#   [4/8] patch wp-config.php (identik dengan clone_execute_one)
#   [5/8] deteksi domain LAMA dari database yang baru diimpor sendiri
#         (_clone_detect_old_domain), baru wp search-replace lama -> baru
#         (tidak ada DOMAIN app sumber di registry untuk dibaca)
#   [6/8] ols_rebuild_vhconf (men-generate vhconf minimal, karena tidak ada
#         vhconf sumber untuk disalin+dipatch) + blok virtualhost + listener
#         map + restart graceful
#   [7/8] fix ownership (identik dengan clone_execute_one)
#   [8/8] SSL + Redis ACL + sinkron LSCWP, non-blocking (identik dengan
#         clone_execute_one)
clone_execute_one_from_staging() {
  local stage_name="$1" new_app="$2" new_domain="$3" new_db="$4"
  CLONE_LAST_STATUS=""
  CLONE_LAST_REASON=""

  # --- Pre-flight validation (nothing created yet if any of this fails —
  #     use _clone_validation_failed, NEVER _clone_step_failed, here: lihat
  #     komentar identik di clone_execute_one untuk alasannya) ---
  if [[ -z "$stage_name" || -z "$new_app" || -z "$new_domain" || -z "$new_db" ]]; then
    _clone_validation_failed "${new_app:-?}" "[0/8] validasi" "argumen wajib tidak lengkap"
    return 1
  fi
  local -a stage_list=()
  mapfile -t stage_list < <(_clone_list_staging_sources)
  if ! _clone_in_array "$stage_name" "${stage_list[@]:-}"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "sumber staging '${stage_name}' tidak ditemukan"
    return 1
  fi
  if ! is_valid_app_name "$new_app"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "nama app tidak valid: '${new_app}'"
    return 1
  fi
  if app_exists "$new_app"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "app '${new_app}' sudah terdaftar"
    return 1
  fi
  if ! is_valid_domain "$new_domain"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "domain tidak valid: '${new_domain}'"
    return 1
  fi
  if _clone_domain_taken "$new_domain"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "domain '${new_domain}' sudah dipakai app lain"
    return 1
  fi
  if ! is_valid_db_name "$new_db"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "nama database tidak valid: '${new_db}'"
    return 1
  fi
  if _clone_db_name_taken "$new_db"; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "database '${new_db}' sudah dipakai"
    return 1
  fi

  # --- Compute derived paths + fresh credentials ---
  local new_vh_root new_docroot
  new_vh_root="/var/www/${new_app}"
  new_docroot="${new_vh_root}/html"

  local db_pass redis_user redis_pass redis_db_id
  db_pass="$(rand_password)"
  redis_user="app_${new_app}"
  redis_pass="$(rand_password)"
  redis_db_id="$(redis_alloc_db_id)"
  if [[ -z "$redis_db_id" || ! "$redis_db_id" =~ ^[0-9]+$ ]]; then
    _clone_validation_failed "$new_app" "[0/8] validasi" "gagal mengalokasikan Redis DB ID (kapasitas ~60 app mungkin sudah tercapai — §7.4)"
    return 1
  fi

  # --- Pre-register the planned state so rollback always has something to
  #     look up, even if step 1 fails immediately. ---
  app_set_all "$new_app" \
    APP_NAME="$new_app" \
    SOURCE_APP="stag:${stage_name}" \
    DOMAIN="$new_domain" \
    VH_ROOT="$new_vh_root" \
    DOCROOT="$new_docroot" \
    DB_NAME="$new_db" \
    DB_USER="$new_db" \
    DB_PASS="$db_pass" \
    PHP_HANDLER="$(staging_conf_get DEFAULT_PHP_HANDLER)" \
    REDIS_DB_ID="$redis_db_id" \
    REDIS_USER="$redis_user" \
    REDIS_PASS="$redis_pass" \
    SSL_STATUS="none" \
    SSL_ISSUED_AT="" \
    CREATED_AT="$(now_iso)" \
    WPM_VERSION="$WPM_VERSION"

  log_info "${C_BOLD}Clone staging '${stage_name}' -> '${new_app}' (domain: ${new_domain})${C_RESET}"
  log_action "clone_execute_one_from_staging: mulai stage=${stage_name} new=${new_app} domain=${new_domain} db=${new_db}"

  # --- [1/8] salin file dari folder staging -> VH_ROOT baru --------------
  log_info "[1/8] Menyalin file situs dari folder staging..."
  mkdir -p "$new_vh_root" 2>/dev/null
  if ! run_nice rsync -a \
        --exclude 'wp-content/cache/' \
        --exclude 'wp-content/litespeed/' \
        --exclude '*/wp-content/cache/' \
        --exclude '*/wp-content/litespeed/' \
        --exclude '**/wp-content/cache/' \
        --exclude '**/wp-content/litespeed/' \
        --exclude 'wp-content/object-cache.php' \
        --exclude '*/wp-content/object-cache.php' \
        --exclude '**/wp-content/object-cache.php' \
        -- "${WPM_STAGE_DIR}/${stage_name}/data/" "${new_docroot}/" >>"$WPM_LOG_FILE" 2>&1; then
    _clone_step_failed "$new_app" "[1/8] rsync" "gagal menyalin file dari '${WPM_STAGE_DIR}/${stage_name}/data'"
    return 1
  fi
  mkdir -p "${new_vh_root}/logs" 2>/dev/null
  if [[ ! -d "$new_docroot" ]]; then
    _clone_step_failed "$new_app" "[1/8] rsync" "docroot hasil salin '${new_docroot}' tidak ditemukan"
    return 1
  fi
  log_action "clone_execute_one_from_staging[${new_app}]: [1/8] rsync selesai"

  # --- [2/8] CREATE DATABASE + user (identik dengan clone_execute_one) ---
  log_info "[2/8] Membuat database & user MySQL..."
  if ! db_create_database "$new_db"; then
    _clone_step_failed "$new_app" "[2/8] database" "CREATE DATABASE gagal"
    return 1
  fi
  if ! db_create_user "$new_db" "$db_pass"; then
    _clone_step_failed "$new_app" "[2/8] database" "CREATE USER gagal"
    return 1
  fi
  if ! db_grant_all "$new_db" "$new_db"; then
    _clone_step_failed "$new_app" "[2/8] database" "GRANT gagal"
    return 1
  fi
  log_action "clone_execute_one_from_staging[${new_app}]: [2/8] database & user dibuat"

  # --- [3/8] impor dump .sql/.sql.gz mentah dari folder staging ----------
  log_info "[3/8] Mengimpor dump SQL dari folder staging..."
  local -a sql_files=()
  mapfile -t sql_files < <(_clone_staging_sql_files "$stage_name")
  if (( ${#sql_files[@]} == 0 )); then
    _clone_step_failed "$new_app" "[3/8] import" "tidak ada file .sql/.sql.gz ditemukan"
    return 1
  fi
  if ! db_import_sql_file "$new_db" "${sql_files[@]}"; then
    _clone_step_failed "$new_app" "[3/8] import" "impor dump SQL ke '${new_db}' gagal"
    return 1
  fi
  log_action "clone_execute_one_from_staging[${new_app}]: [3/8] import selesai (${#sql_files[@]} berkas)"

  # --- [4/8] patch wp-config.php (identik dengan clone_execute_one) ------
  log_info "[4/8] Mem-patch wp-config.php (kredensial DB, salts, kredensial Redis)..."
  if ! _patch_wp_config "$new_docroot" "$new_db" "$new_db" "$db_pass" \
        "$redis_user" "$redis_pass" "$redis_db_id"; then
    _clone_step_failed "$new_app" "[4/8] wp-config" "patch wp-config.php gagal"
    return 1
  fi
  log_action "clone_execute_one_from_staging[${new_app}]: [4/8] wp-config.php dipatch"

  # Defensif — dan PENTING di jalur staging ini secara khusus: sumber
  # staging sering kali sudah punya plugin cache (mis. LiteSpeed Cache)
  # aktif lengkap dengan drop-in object-cache.php. Meski drop-in itu sudah
  # di-exclude di [1/8] supaya tidak ikut tersalin (drop-in itu berisi
  # konfigurasi cache milik environment SUMBER, bukan app baru ini), flush
  # di sini tetap dilakukan sebagai lapisan pencegahan kedua — kalau
  # sampai ada nilai ter-cache dari sebelum clone (mis. karena drop-in lain
  # yang tidak ter-exclude), deteksi domain lama di [5/8] di bawah ini bisa
  # salah baca nilai siteurl/home yang stale sehingga wp search-replace
  # mencari string yang salah dan tidak mengganti apa pun (search-replace
  # tetap exit 0 walau 0 baris diganti, jadi kegagalan seperti ini tidak
  # akan pernah muncul sebagai [ERROR] — situs baru hanya akan diam-diam
  # tetap redirect/menunjuk ke domain lama).
  _clone_wp_run "$new_docroot" cache flush >>"$WPM_LOG_FILE" 2>&1 \
    || log_warn "clone_execute_one_from_staging[${new_app}]: 'wp cache flush' gagal (non-fatal)"

  # --- [5/8] deteksi domain lama dari data staging + search-replace ------
  log_info "[5/8] Mendeteksi domain lama dari data staging & wp search-replace..."
  local old_domain
  old_domain="$(_clone_detect_old_domain "$new_docroot" "$new_db")"
  if [[ -z "$old_domain" ]]; then
    _clone_step_failed "$new_app" "[5/8] search-replace" "domain lama tidak terdeteksi dari data staging (periksa wp_options/siteurl di dump SQL)"
    return 1
  fi
  if ! _clone_wp_run "$new_docroot" search-replace "$old_domain" "$new_domain" \
        --all-tables --skip-columns=guid >>"$WPM_LOG_FILE" 2>&1; then
    _clone_step_failed "$new_app" "[5/8] search-replace" "wp search-replace gagal"
    return 1
  fi
  log_action "clone_execute_one_from_staging[${new_app}]: [5/8] search-replace ${old_domain} -> ${new_domain} selesai"

  # --- [6/8] vhconf minimal + blok virtualhost + listener map + restart --
  log_info "[6/8] Membuat vhconf, menambah virtualhost + listener, restart graceful..."
  if ! ols_rebuild_vhconf "$new_app"; then
    _clone_step_failed "$new_app" "[6/8] vhconf" "gagal membuat vhconf untuk app baru '${new_app}'"
    return 1
  fi
  if ! ols_write_vhost_block "$new_app" "$new_vh_root" "$(ols_vhconf_path "$new_app")"; then
    _clone_step_failed "$new_app" "[6/8] vhconf" "gagal menulis blok virtualhost"
    return 1
  fi
  # NOTE: sama seperti clone_execute_one, ols_write_listener_map mengembalikan
  # 1 (bukan die/exit) bila tidak ada listener di port :80 dengan nama apa
  # pun — ols_http_listener_name mendeteksi otomatis listener yang benar-benar
  # terpasang di port itu (banyak instalasi OpenLiteSpeed nyata tidak
  # menamakannya "Default", mis. listener bawaan "Example"), baru jatuh ke
  # literal "Default" bila memang tidak ada apa pun di port :80.
  if ! ols_write_listener_map "$(ols_http_listener_name)" "$new_app" "$new_domain"; then
    _clone_step_failed "$new_app" "[6/8] vhconf" "gagal memetakan listener HTTP (:80)"
    return 1
  fi
  if ! ols_graceful_restart; then
    _clone_step_failed "$new_app" "[6/8] vhconf" "restart graceful OLS gagal"
    return 1
  fi
  log_action "clone_execute_one_from_staging[${new_app}]: [6/8] vhconf+virtualhost+listener+restart selesai"

  # --- [7/8] fix ownership (identik dengan clone_execute_one) ------------
  log_info "[7/8] Memperbaiki ownership file..."
  if ! tools_fix_ownership "$new_app"; then
    _clone_step_failed "$new_app" "[7/8] ownership" "tools_fix_ownership gagal"
    return 1
  fi
  log_action "clone_execute_one_from_staging[${new_app}]: [7/8] ownership diperbaiki"

  # ======================================================================
  # Steps 1-7 all succeeded — the app is live on HTTP from this point on.
  # Everything below (step 8) is non-blocking, identik dengan step [8/8]
  # milik clone_execute_one (lihat komentarnya untuk detail).
  # ======================================================================
  log_info "[8/8] Cek DNS, terbitkan SSL, siapkan Redis ACL, sinkron LSCWP (non-blocking)..."
  local ssl_raw ssl_result
  ssl_raw="$(ssl_run_for_new_app "$new_app" "$new_domain" "$new_docroot")"
  ssl_result="$(tail -n1 <<<"$ssl_raw")"
  case "$ssl_result" in
    active | failed | none) ;;
    *) ssl_result="none" ;;
  esac

  if ! redis_create_acl_user "$new_app" "$redis_user" "$redis_pass" "$redis_db_id"; then
    log_warn "clone_execute_one_from_staging[${new_app}]: gagal membuat Redis ACL user (non-blocking — object cache fallback tanpa Redis, §9)"
  elif ! redis_sync_lscwp "$new_app"; then
    log_warn "clone_execute_one_from_staging[${new_app}]: gagal sinkron kredensial Redis ke LSCWP (non-blocking)"
  fi

  log_action "clone_execute_one_from_staging[${new_app}]: [8/8] selesai (ssl=${ssl_result})"

  if [[ "$ssl_result" == "active" ]]; then
    CLONE_LAST_STATUS="https"
    log_info "${C_GREEN}Clone '${new_app}' selesai — live di https://${new_domain}${C_RESET}"
  else
    CLONE_LAST_STATUS="http"
    CLONE_LAST_REASON="SSL ${ssl_result} (retry via menu Retry SSL)"
    log_info "${C_YELLOW}Clone '${new_app}' selesai — live di http://${new_domain} (SSL ${ssl_result}, retry via menu)${C_RESET}"
  fi

  log_action "clone_execute_one_from_staging: SELESAI stage=${stage_name} new=${new_app} status=${CLONE_LAST_STATUS}"
  return 0
}

# clone_wizard — interactive flow per §4.3: pick a clone source — either a
# registered app (flow lama) atau folder staging di bawah $WPM_STAGE_DIR
# (folder file WP mentah + dump .sql/.sql.gz, tanpa app yang hidup) — ask
# N, loop asking app name/db name (defaults via next_numeric_suffix)/domain
# (validated unique) for each of the N copies, show a summary table,
# confirm, then execute clone_execute_one (sumber app) atau
# clone_execute_one_from_staging (sumber staging) for each planned app in
# order, sequentially, printing a final ✓/◐/✗ report line per app. Never
# aborts the loop early because one app failed — always proceeds to the
# next planned app.
clone_wizard() {
  local source_is_staging=0

  printf '\n%sSumber clone:%s\n' "$C_BOLD" "$C_RESET"
  printf '  1) App terdaftar\n'
  printf '  2) Folder staging\n'
  local source_choice
  source_choice="$(prompt_default "Pilih sumber clone" "1")"
  [[ "$source_choice" == "2" ]] && source_is_staging=1

  local -a app_list=() stage_list=()
  local src_idx src_app src_db_name
  local stage_idx stage_name source_label
  local i

  if (( source_is_staging )); then
    mapfile -t stage_list < <(_clone_list_staging_sources)
    if (( ${#stage_list[@]} == 0 )); then
      log_error "Tidak ada sumber staging ditemukan di ${WPM_STAGE_DIR}/<nama>/{data,db}"
      return 1
    fi

    printf '\n%sPilih sumber staging untuk di-clone:%s\n' "$C_BOLD" "$C_RESET"
    for i in "${!stage_list[@]}"; do
      printf '  %2d) %s\n' "$((i + 1))" "${stage_list[$i]}"
    done

    while true; do
      stage_idx="$(prompt_default "Nomor sumber staging" "")"
      if [[ "$stage_idx" =~ ^[0-9]+$ ]] && (( stage_idx >= 1 && stage_idx <= ${#stage_list[@]} )); then
        stage_name="${stage_list[$((stage_idx - 1))]}"
        break
      fi
      printf '%sPilihan tidak valid.%s\n' "$C_RED" "$C_RESET" >&2
    done
    source_label="stag:${stage_name}"
  else
    mapfile -t app_list < <(list_apps)
    if (( ${#app_list[@]} == 0 )); then
      log_error "Belum ada web app terdaftar untuk dijadikan sumber clone."
      return 1
    fi

    printf '\n%sPilih app sumber untuk di-clone:%s\n' "$C_BOLD" "$C_RESET"
    for i in "${!app_list[@]}"; do
      printf '  %2d) %-24s %s\n' "$((i + 1))" "${app_list[$i]}" "$(app_get "${app_list[$i]}" DOMAIN)"
    done

    while true; do
      src_idx="$(prompt_default "Nomor app sumber" "")"
      if [[ "$src_idx" =~ ^[0-9]+$ ]] && (( src_idx >= 1 && src_idx <= ${#app_list[@]} )); then
        src_app="${app_list[$((src_idx - 1))]}"
        break
      fi
      printf '%sPilihan tidak valid.%s\n' "$C_RED" "$C_RESET" >&2
    done
    source_label="$src_app"
  fi

  local n
  while true; do
    n="$(prompt_default "Jumlah salinan (N)" "1")"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )); then
      break
    fi
    printf '%sMasukkan angka bulat >= 1.%s\n' "$C_RED" "$C_RESET" >&2
  done

  local candidate default_app_base default_db_base
  if (( source_is_staging )); then
    candidate="$(next_numeric_suffix "$stage_name")"
    default_app_base="$stage_name"
    default_db_base="${stage_name}_db"
  else
    src_db_name="$(app_get "$src_app" DB_NAME)"
    candidate="$(next_numeric_suffix "$src_app")"
    default_app_base="$src_app"
    default_db_base="$src_db_name"
  fi
  [[ "$candidate" =~ ^[0-9]+$ ]] || candidate=2

  local -a planned_apps=() planned_dbs=() planned_domains=()
  local idx default_app default_db app_name db_name domain

  for ((idx = 1; idx <= n; idx++)); do
    printf '\n%s-- Salinan #%d dari %d --%s\n' "$C_BOLD" "$idx" "$n" "$C_RESET"

    default_app="${default_app_base}${candidate}"
    while true; do
      app_name="$(prompt_default "  Nama app" "$default_app")"
      if ! is_valid_app_name "$app_name"; then
        printf '%s  Nama app tidak valid (pola: [a-z0-9-]+, maks 32 karakter).%s\n' "$C_RED" "$C_RESET" >&2
        continue
      fi
      if app_exists "$app_name" || _clone_in_array "$app_name" "${planned_apps[@]:-}"; then
        printf '%s  Nama app "%s" sudah dipakai.%s\n' "$C_RED" "$app_name" "$C_RESET" >&2
        continue
      fi
      break
    done

    default_db="${default_db_base}${candidate}"
    while true; do
      db_name="$(prompt_default "  Nama database" "$default_db")"
      if ! is_valid_db_name "$db_name"; then
        printf '%s  Nama database tidak valid (pola: [A-Za-z0-9_]+, maks 32 karakter).%s\n' "$C_RED" "$C_RESET" >&2
        continue
      fi
      if _clone_db_name_taken "$db_name" || _clone_in_array "$db_name" "${planned_dbs[@]:-}"; then
        printf '%s  Nama database "%s" sudah dipakai.%s\n' "$C_RED" "$db_name" "$C_RESET" >&2
        continue
      fi
      break
    done

    while true; do
      domain="$(prompt_default "  Domain (wajib diisi)" "")"
      if [[ -z "$domain" ]] || ! is_valid_domain "$domain"; then
        printf '%s  Domain wajib diisi dan harus berformat FQDN yang valid.%s\n' "$C_RED" "$C_RESET" >&2
        continue
      fi
      if _clone_domain_taken "$domain" || _clone_in_array "$domain" "${planned_domains[@]:-}"; then
        printf '%s  Domain "%s" sudah dipakai app lain.%s\n' "$C_RED" "$domain" "$C_RESET" >&2
        continue
      fi
      break
    done

    planned_apps+=("$app_name")
    planned_dbs+=("$db_name")
    planned_domains+=("$domain")
    ((candidate++))
  done

  printf '\n%sRingkasan rencana clone dari "%s" (%d salinan):%s\n' "$C_BOLD" "$source_label" "$n" "$C_RESET"
  printf '  %-4s %-24s %-30s %s\n' "No" "Nama App" "Domain" "Database"
  for idx in "${!planned_apps[@]}"; do
    printf '  %-4s %-24s %-30s %s\n' "$((idx + 1))" "${planned_apps[$idx]}" "${planned_domains[$idx]}" "${planned_dbs[$idx]}"
  done
  printf '\n'

  if ! confirm "Lanjutkan eksekusi clone untuk ${n} app di atas?" "default_n"; then
    log_info "Clone dibatalkan."
    return 0
  fi

  local -a report_glyph=() report_color=() report_desc=()
  for idx in "${!planned_apps[@]}"; do
    printf '\n%s=== App %d/%d: %s ===%s\n' "$C_BOLD" "$((idx + 1))" "${#planned_apps[@]}" "${planned_apps[$idx]}" "$C_RESET"

    if (( source_is_staging )); then
      clone_execute_one_from_staging "$stage_name" "${planned_apps[$idx]}" "${planned_domains[$idx]}" "${planned_dbs[$idx]}"
    else
      clone_execute_one "$src_app" "${planned_apps[$idx]}" "${planned_domains[$idx]}" "${planned_dbs[$idx]}"
    fi

    case "$CLONE_LAST_STATUS" in
      https)
        report_glyph+=("✓"); report_color+=("$C_GREEN")
        report_desc+=("sukses (HTTPS)")
        ;;
      http)
        report_glyph+=("◐"); report_color+=("$C_YELLOW")
        report_desc+=("live HTTP, SSL pending — ${CLONE_LAST_REASON}")
        ;;
      *)
        report_glyph+=("✗"); report_color+=("$C_RED")
        report_desc+=("gagal — ${CLONE_LAST_REASON:-lihat log} (${WPM_LOG_FILE})")
        ;;
    esac
  done

  printf '\n%sLaporan akhir clone:%s\n' "$C_BOLD" "$C_RESET"
  for idx in "${!planned_apps[@]}"; do
    printf ' %s%s%s %-24s %-30s %s\n' \
      "${report_color[$idx]}" "${report_glyph[$idx]}" "$C_RESET" \
      "${planned_apps[$idx]}" "${planned_domains[$idx]}" "${report_desc[$idx]}"
  done
  printf '\n'

  log_action "clone_wizard: selesai sumber=${source_label} n=${n}"
  return 0
}

# app_delete APP [--backup] — §F-3e: shows what will be removed, requires
# confirm + confirm_typed APP, optional .tar.gz backup of VH_ROOT before
# deleting, then reuses _app_purge (the same removal primitive
# clone_rollback uses). Ends with a graceful restart (done inside
# _app_purge). Pass "--backup" to skip the interactive backup prompt and
# always back up; without it, the user is asked interactively.
app_delete() {
  local app="$1"
  shift 2>/dev/null || true

  local backup_flag=0 arg
  for arg in "$@"; do
    [[ "$arg" == "--backup" ]] && backup_flag=1
  done

  if [[ -z "$app" ]]; then
    log_error "app_delete: nama app wajib diisi"
    return 1
  fi
  if ! app_exists "$app"; then
    log_error "app_delete: app '${app}' tidak ditemukan di registry"
    return 1
  fi

  local domain vh_root db_name db_user redis_user ssl_status disk_size
  domain="$(app_get "$app" DOMAIN)"
  vh_root="$(app_get "$app" VH_ROOT)"
  db_name="$(app_get "$app" DB_NAME)"
  db_user="$(app_get "$app" DB_USER)"
  redis_user="$(app_get "$app" REDIS_USER)"
  ssl_status="$(app_get "$app" SSL_STATUS)"
  disk_size="-"
  [[ -n "$vh_root" && -d "$vh_root" ]] && disk_size="$(du -sh -- "$vh_root" 2>/dev/null | cut -f1)"

  printf '\n%sBerikut yang akan DIHAPUS untuk app "%s":%s\n' "$C_BOLD" "$app" "$C_RESET"
  printf '  Domain          : %s\n' "${domain:--}"
  printf '  Direktori situs : %s (%s)\n' "${vh_root:--}" "${disk_size:--}"
  printf '  Database        : %s (user: %s)\n' "${db_name:--}" "${db_user:--}"
  printf '  Redis ACL user  : %s\n' "${redis_user:--}"
  printf '  Status SSL      : %s\n' "${ssl_status:-none}"
  printf '  Config vhost    : %s\n' "$(ols_vhconf_path "$app")"
  printf '  Registry        : %s\n\n' "$(app_conf_path "$app")"

  if ! confirm "Yakin ingin menghapus app '${app}'? Tindakan ini TIDAK dapat dibatalkan" "default_n"; then
    log_info "Penghapusan app '${app}' dibatalkan."
    return 1
  fi
  if ! confirm_typed "$app"; then
    log_warn "Konfirmasi nama app tidak cocok. Penghapusan '${app}' dibatalkan."
    return 1
  fi

  if [[ "$backup_flag" -eq 0 ]]; then
    if confirm "Buat backup .tar.gz situs sebelum menghapus?" "default_y"; then
      backup_flag=1
    fi
  fi

  if [[ "$backup_flag" -eq 1 ]]; then
    if [[ -z "$vh_root" || ! -d "$vh_root" ]]; then
      log_warn "app_delete: VH_ROOT tidak ditemukan, backup dilewati untuk '${app}'"
    else
      local backup_dir backup_file parent base
      backup_dir="${WPM_VAR}/backups"
      mkdir -p "$backup_dir" 2>/dev/null
      backup_file="${backup_dir}/${app}-$(date -u +%Y%m%d%H%M%S).tar.gz"
      parent="$(dirname "$vh_root")"
      base="$(basename "$vh_root")"

      log_info "Membuat backup ke ${backup_file} ..."
      log_action "app_delete: membuat backup app=${app} -> ${backup_file}"

      if run_nice tar -czf "$backup_file" -C "$parent" "$base" 2>>"$WPM_LOG_FILE"; then
        chmod 600 "$backup_file" 2>/dev/null
        log_info "Backup selesai: ${backup_file}"
        log_action "app_delete: backup berhasil app=${app} file=${backup_file}"
      else
        rm -f "$backup_file" 2>/dev/null
        log_error "app_delete: gagal membuat backup untuk '${app}'"
        log_action "app_delete: backup gagal app=${app}"
        if ! confirm "Backup gagal dibuat. Lanjutkan hapus TANPA backup?" "default_n"; then
          log_info "Penghapusan app '${app}' dibatalkan karena backup gagal."
          return 1
        fi
      fi
    fi
  fi

  log_info "Menghapus app '${app}'..."
  log_action "app_delete: mulai penghapusan app=${app}"
  _app_purge "$app"
  log_action "app_delete: selesai penghapusan app=${app}"
  log_info "${C_GREEN}App '${app}' berhasil dihapus.${C_RESET}"
  return 0
}
