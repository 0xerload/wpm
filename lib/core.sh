#!/usr/bin/env bash
#
# lib/core.sh — WPM core utilities.
#
# Provides: ANSI colors, logging, guard/util helpers, interactive prompts,
# a global lock, random password generation, input validation, the app
# registry I/O primitives, numeric-suffix allocation, and the MySQL
# administrative helpers used by clone.sh / the delete-app path.
#
# This file is SOURCED by every other WPM script (wpm, install.sh,
# monitor.sh, bot.sh, and all of lib/*.sh). It must never be executed
# directly, and it must never `set -e`/`set -u` globally — that would leak
# into whichever script sources it.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/core.sh is a library — source it, don't execute it directly." >&2
  exit 1
fi

[[ -n "${WPM_LIB_CORE_LOADED:-}" ]] && return
readonly WPM_LIB_CORE_LOADED=1

# ---------------------------------------------------------------------------
# Path constants (defined ONCE here, used everywhere else — never hardcode
# these paths again in any other file).
# ---------------------------------------------------------------------------

WPM_HOME="${WPM_HOME:-/usr/local/share/wpm}"      # lib/ + templates/ + monitor.sh + bot.sh live here when installed
WPM_ETC="/etc/wpm"
WPM_APPS_DIR="$WPM_ETC/apps"                       # <app>.conf + <app>.vhconf.snap
WPM_SECRETS="$WPM_ETC/.secrets"                    # MYSQL_ROOT_USER / MYSQL_ROOT_PASS
WPM_TELEGRAM_CONF="$WPM_ETC/telegram.conf"
WPM_VAR="/var/lib/wpm"
WPM_STATE_FILE="$WPM_VAR/monitor.state"
WPM_STAGE_DIR="$WPM_VAR/stag"                      # staging sources: $WPM_STAGE_DIR/<name>/{data,db}
WPM_STAGING_CONF="$WPM_ETC/staging.conf"           # DEFAULT_PHP_HANDLER for clone-from-staging
WPM_LOG_DIR="/var/log/wpm"
WPM_LOG_FILE="$WPM_LOG_DIR/wpm.log"
WPM_LOCK_FILE="/run/wpm.lock"
OLS_HOME="/usr/local/lsws"
OLS_CONF="$OLS_HOME/conf/httpd_config.conf"
OLS_VHOST_DIR="$OLS_HOME/conf/vhosts"              # $OLS_VHOST_DIR/<app>/vhconf.conf
OLS_CTRL="$OLS_HOME/bin/lswsctrl"                  # lswsctrl restart == graceful
REDIS_ACL_FILE="/etc/redis/users.acl"
WPM_VERSION="1.0"

# ---------------------------------------------------------------------------
# ANSI colors — names are final, used across the whole codebase.
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_CYAN=$'\033[0;36m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_BOLD=""
  C_DIM=""
  C_RESET=""
fi

# ---------------------------------------------------------------------------
# Timestamp
# ---------------------------------------------------------------------------

# now_iso — echoes current UTC time as ISO-8601 (Z suffix).
now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------------------
# Logging — all lines are appended to $WPM_LOG_FILE with a timestamp.
# log_info/log_warn echo to stdout (colored); log_error echoes to stderr
# (colored); log_action is silent — log file only, used for the audit trail
# of state-changing steps (NFR-07).
# ---------------------------------------------------------------------------

# _wpm_log_rotate_if_needed — best-effort safety net: if wpm.log has grown
# past 10 MB (e.g. logrotate isn't installed/enabled yet), roll it once.
# install.sh is expected to install a proper logrotate policy; this is just
# a defensive fallback so the log can never grow unbounded.
_wpm_log_rotate_if_needed() {
  local max_bytes=$((10 * 1024 * 1024))
  local size
  [[ -f "$WPM_LOG_FILE" ]] || return 0
  size=$(wc -c <"$WPM_LOG_FILE" 2>/dev/null) || size=0
  if (( size > max_bytes )); then
    mv -f "$WPM_LOG_FILE" "${WPM_LOG_FILE}.1" 2>/dev/null
  fi
}

# _wpm_log_write LEVEL MSG — internal: append one timestamped line to the
# log file. Never raises even if the log dir/file is not writable (a lib
# file must not abort the caller for a logging failure).
_wpm_log_write() {
  local level="$1" msg="$2"
  if [[ ! -d "$WPM_LOG_DIR" ]]; then
    mkdir -p "$WPM_LOG_DIR" 2>/dev/null
    chmod 750 "$WPM_LOG_DIR" 2>/dev/null
  fi
  _wpm_log_rotate_if_needed
  printf '%s [%s] %s\n' "$(now_iso)" "$level" "$msg" >>"$WPM_LOG_FILE" 2>/dev/null
}

log_info() {
  local msg="$1"
  printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$msg"
  _wpm_log_write "INFO" "$msg"
}

log_warn() {
  local msg="$1"
  printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$msg"
  _wpm_log_write "WARN" "$msg"
}

log_error() {
  local msg="$1"
  printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$msg" >&2
  _wpm_log_write "ERROR" "$msg"
}

# log_action MSG — silent audit-trail entry (log file only, no stdout).
log_action() {
  local msg="$1"
  _wpm_log_write "ACTION" "$msg"
}

# die MSG — log the error and exit 1. Use for any unrecoverable condition.
die() {
  local msg="$1"
  log_error "$msg"
  exit 1
}

# ---------------------------------------------------------------------------
# Guard / util
# ---------------------------------------------------------------------------

# require_root — every entry point must call this first.
require_root() {
  local uid="${EUID:-$(id -u)}"
  if [[ "$uid" != "0" ]]; then
    die "Perintah ini harus dijalankan sebagai root (coba: sudo $0)."
  fi
}

# require_cmd NAME — die with an install hint if NAME isn't on PATH.
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Dependensi '$cmd' tidak ditemukan. Pasang dulu, contoh: apt-get install -y $cmd"
  fi
}

# mask_secret STR — echoes a masked version of STR, safe to log. Never
# reveals the real length or full content.
mask_secret() {
  local secret="${1:-}"
  local len=${#secret}
  if (( len == 0 )); then
    printf '\n'
    return 0
  fi
  if (( len <= 4 )); then
    printf '******\n'
    return 0
  fi
  printf '%s******%s\n' "${secret:0:2}" "${secret: -2}"
}

# ---------------------------------------------------------------------------
# Interactive prompts. Prompt text is written to stderr so callers can
# safely do `x=$(prompt_default ...)` and only capture the answer on stdout.
# ---------------------------------------------------------------------------

# confirm "question" [default_y|default_n] → 0 = yes, 1 = no
confirm() {
  local question="$1"
  local default="${2:-default_n}"
  local suffix="[y/N]"
  local def_char="n"
  if [[ "$default" == "default_y" ]]; then
    suffix="[Y/n]"
    def_char="y"
  fi
  local reply
  while true; do
    printf '%s %s: ' "$question" "$suffix" >&2
    if ! read -r reply; then
      reply="$def_char"
    fi
    reply="${reply,,}"
    [[ -z "$reply" ]] && reply="$def_char"
    case "$reply" in
      y | yes | ya) return 0 ;;
      n | no | tidak) return 1 ;;
      *) printf 'Jawab dengan y atau n.\n' >&2 ;;
    esac
  done
}

# confirm_typed "expected" → 0 only if the user types back the exact string.
confirm_typed() {
  local expected="$1"
  local reply
  printf 'Ketik ulang "%s" untuk konfirmasi: ' "$expected" >&2
  read -r reply || reply=""
  [[ "$reply" == "$expected" ]]
}

# prompt_default "Label" "default" → echoes the chosen value on stdout.
prompt_default() {
  local label="$1"
  local default="${2:-}"
  local reply
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$label" "$default" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  read -r reply || reply=""
  [[ -z "$reply" ]] && reply="$default"
  printf '%s\n' "$reply"
}

# pause_enter — generic "press enter to continue".
pause_enter() {
  printf 'Tekan Enter untuk lanjut...' >&2
  read -r _dummy || true
}

# ---------------------------------------------------------------------------
# Global lock — flock on fd 9 against $WPM_LOCK_FILE, non-blocking.
# ---------------------------------------------------------------------------

_WPM_LOCK_ACQUIRED=0

# acquire_lock — die immediately (no blocking) if another wpm process holds
# the lock. Registers a trap so the lock is always released on exit.
acquire_lock() {
  if [[ "$_WPM_LOCK_ACQUIRED" == "1" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$WPM_LOCK_FILE")" 2>/dev/null
  # shellcheck disable=SC2093
  exec 9>"$WPM_LOCK_FILE" || die "Tidak dapat membuka lock file: $WPM_LOCK_FILE"
  if ! flock -n 9; then
    die "WPM sedang dipakai oleh proses lain (lock: $WPM_LOCK_FILE). Coba lagi sebentar."
  fi
  _WPM_LOCK_ACQUIRED=1
  trap release_lock EXIT
}

# release_lock — safe to call multiple times.
release_lock() {
  if [[ "$_WPM_LOCK_ACQUIRED" == "1" ]]; then
    flock -u 9 2>/dev/null
    exec 9>&- 2>/dev/null
    _WPM_LOCK_ACQUIRED=0
  fi
}

# ---------------------------------------------------------------------------
# Random password
# ---------------------------------------------------------------------------

# rand_password [len=24] — alnum-only password from /dev/urandom (NFR-04).
rand_password() {
  local len="${1:-24}"
  local pass=""
  local chunk
  while (( ${#pass} < len )); do
    chunk="$(head -c 256 /dev/urandom | base64 2>/dev/null | tr -dc 'A-Za-z0-9')"
    pass+="$chunk"
  done
  printf '%s\n' "${pass:0:len}"
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

# is_valid_app_name STR — [a-z0-9-]+, no leading/trailing/double hyphen,
# 1-32 chars (kept short: gets reused as DB name / Redis user suffix / dir).
is_valid_app_name() {
  local name="${1:-}"
  (( ${#name} >= 1 && ${#name} <= 32 )) || return 1
  [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# is_valid_domain STR — basic FQDN validation (labels + TLD, no trailing dot).
is_valid_domain() {
  local domain="${1:-}"
  (( ${#domain} >= 1 && ${#domain} <= 253 )) || return 1
  [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

# is_valid_db_name STR — MySQL identifier: [A-Za-z0-9_]+, 1-32 chars (kept
# to 32 so the same string is always valid as both DB_NAME and DB_USER).
is_valid_db_name() {
  local name="${1:-}"
  (( ${#name} >= 1 && ${#name} <= 32 )) || return 1
  [[ "$name" =~ ^[A-Za-z0-9_]+$ ]]
}

# ---------------------------------------------------------------------------
# Private helpers — safe flat-file KEY="value" reader. Never `source`s a
# conf file; an app conf can never inject code into the caller's shell.
# ---------------------------------------------------------------------------

# _wpm_conf_get_file FILE KEY — echoes the value of KEY (last occurrence
# wins), empty string if absent or file missing.
_wpm_conf_get_file() {
  local file="$1" key="$2"
  local line k v value=""
  [[ -f "$file" ]] || { printf '%s\n' ""; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=\"(.*)\"[[:space:]]*$ ]]; then
      k="${BASH_REMATCH[1]}"
      v="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      k="${BASH_REMATCH[1]}"
      v="${BASH_REMATCH[2]}"
    else
      continue
    fi
    [[ "$k" == "$key" ]] && value="$v"
  done <"$file"
  printf '%s\n' "$value"
}

# _wpm_conf_write_file FILE MODE key1=val1 key2=val2 ... — atomically
# (re)writes FILE as a flat KEY="value" list in the given order, then
# chmod MODE. Used by app_set_all / telegram_conf_set_all-style writers.
_wpm_conf_write_file() {
  local file="$1" mode="$2"
  shift 2
  local dir tmp kv k v
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null
  tmp="${file}.tmp.$$"
  ( umask 077; : >"$tmp" )
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ -z "$k" ]] && continue
    printf '%s="%s"\n' "$k" "$v" >>"$tmp"
  done
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$file"
}

# _wpm_sql_escape STR — escapes backslashes and doubles single quotes, for
# safe embedding inside a single-quoted SQL string literal (MySQL treats
# backslash as the string-escape character by default, so it must be
# escaped first or a trailing backslash can consume the closing quote).
_wpm_sql_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  printf '%s' "${s//\'/\'\'}"
}

# ---------------------------------------------------------------------------
# Registry I/O — /etc/wpm/apps/<APP>.conf (mode 600)
# ---------------------------------------------------------------------------

# app_conf_path APP — echoes the conf path for APP.
app_conf_path() {
  local app="$1"
  printf '%s\n' "$WPM_APPS_DIR/${app}.conf"
}

# app_exists APP — 0 if the app's conf file exists, else 1.
app_exists() {
  local app="$1"
  [[ -f "$(app_conf_path "$app")" ]]
}

# list_apps — echoes registered app names, one per line, sorted.
list_apps() {
  local f base
  [[ -d "$WPM_APPS_DIR" ]] || return 0
  for f in "$WPM_APPS_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    base="${base%.conf}"
    printf '%s\n' "$base"
  done | sort
}

# app_get APP KEY — echoes the value of KEY in APP's conf, empty if absent.
app_get() {
  local app="$1" key="$2"
  _wpm_conf_get_file "$(app_conf_path "$app")" "$key"
}

# app_set_all APP key1=val1 key2=val2 ... — atomically overwrites the whole
# conf file for APP with exactly the given keys (order preserved), mode 600.
# Callers are responsible for passing the complete set of fields they want
# persisted (this does NOT merge with the existing file).
app_set_all() {
  local app="$1"
  shift
  is_valid_app_name "$app" || die "Nama app tidak valid: $app"
  mkdir -p "$WPM_APPS_DIR" 2>/dev/null
  _wpm_conf_write_file "$(app_conf_path "$app")" 600 "$@"
}

# app_delete_conf APP — removes the conf + vhconf snapshot for APP.
app_delete_conf() {
  local app="$1"
  local conf snap
  conf="$(app_conf_path "$app")"
  snap="$WPM_APPS_DIR/${app}.vhconf.snap"
  rm -f "$conf" "$snap"
}

# ---------------------------------------------------------------------------
# Naming convention (§6.7)
# ---------------------------------------------------------------------------

# next_numeric_suffix BASE — smallest unused integer >= 2 such that
# "${BASE}<n>" doesn't collide with a registered app, an on-disk vhost dir,
# or an existing MySQL database. Echoes the bare integer.
next_numeric_suffix() {
  local base="$1"
  local -A used=()
  local name num

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$name" =~ ^${base}([0-9]+)$ ]]; then
      used["${BASH_REMATCH[1]}"]=1
    fi
  done < <(list_apps)

  if [[ -d "$OLS_VHOST_DIR" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if [[ "$name" =~ ^${base}([0-9]+)$ ]]; then
        used["${BASH_REMATCH[1]}"]=1
      fi
    done < <(ls -1 "$OLS_VHOST_DIR" 2>/dev/null)
  fi

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$name" =~ ^${base}([0-9]+)$ ]]; then
      used["${BASH_REMATCH[1]}"]=1
    fi
  done < <(db_list_databases 2>/dev/null)

  num=2
  while [[ -n "${used[$num]:-}" ]]; do
    ((num++))
  done
  printf '%s\n' "$num"
}

# ---------------------------------------------------------------------------
# Process priority (§7.1 / NFR-01)
# ---------------------------------------------------------------------------

# run_nice cmd... — runs cmd under nice -n19 + ionice -c3 (best-effort;
# falls back to nice alone if ionice isn't available).
run_nice() {
  if command -v ionice >/dev/null 2>&1; then
    nice -n 19 ionice -c3 "$@"
  else
    nice -n 19 "$@"
  fi
}

# ---------------------------------------------------------------------------
# MySQL administrative helpers (root-credential operations)
# ---------------------------------------------------------------------------

# db_defaults_file — creates a mode-600 mktemp file with a [client] section
# built from $WPM_SECRETS' MYSQL_ROOT_USER/MYSQL_ROOT_PASS, and echoes its
# path. Echoes an EMPTY string (creates nothing) when /root/.my.cnf exists —
# callers must check for an empty return and omit --defaults-extra-file so
# the mysql client falls back to /root/.my.cnf. Caller must `rm -f` the
# returned path when non-empty.
db_defaults_file() {
  if [[ -f /root/.my.cnf ]]; then
    printf '%s\n' ""
    return 0
  fi
  local user pass tmp
  user="$(_wpm_conf_get_file "$WPM_SECRETS" "MYSQL_ROOT_USER")"
  pass="$(_wpm_conf_get_file "$WPM_SECRETS" "MYSQL_ROOT_PASS")"
  if [[ -z "$user" ]]; then
    die "Kredensial MySQL root tidak ditemukan di $WPM_SECRETS. Jalankan ulang install.sh atau isi manual."
  fi
  tmp="$(mktemp /tmp/wpm-mycnf.XXXXXX)" || die "Gagal membuat file defaults MySQL sementara."
  chmod 600 "$tmp"
  {
    printf '[client]\n'
    printf 'user=%s\n' "$user"
    printf 'password=%s\n' "$pass"
    printf 'host=localhost\n'
  } >"$tmp"
  printf '%s\n' "$tmp"
}

# _wpm_mysql_bin / _wpm_mysqldump_bin — echo the preferred client binary
# name. Modern MariaDB (10.6+) ships `mariadb`/`mariadb-dump` as the
# primary binaries and keeps `mysql`/`mysqldump` only as deprecated
# compatibility symlinks that print a noisy "Deprecated program name..."
# warning to stderr on every single invocation. Prefer the non-deprecated
# name when it exists; fall back to the classic name otherwise (still
# required for plain MySQL servers, which have no `mariadb`/`mariadb-dump`
# binary at all).
_wpm_mysql_bin() {
  command -v mariadb >/dev/null 2>&1 && { printf '%s\n' "mariadb"; return 0; }
  printf '%s\n' "mysql"
}

_wpm_mysqldump_bin() {
  command -v mariadb-dump >/dev/null 2>&1 && { printf '%s\n' "mariadb-dump"; return 0; }
  printf '%s\n' "mysqldump"
}

# db_exec SQL — runs one statement via mysql using the defaults-file
# pattern; cleans up its own temp file. Returns mysql's exit status.
# SQL is fed via stdin (not -e) so it never appears as a process argv
# element — some callers (e.g. db_create_user) embed a plaintext secret
# in SQL, and argv is readable by any local user via ps/proc.
db_exec() {
  local sql="$1"
  local defaults rc
  defaults="$(db_defaults_file)"
  local cmd=("$(_wpm_mysql_bin)")
  [[ -n "$defaults" ]] && cmd+=(--defaults-extra-file="$defaults")
  printf '%s' "$sql" | "${cmd[@]}"
  rc=$?
  [[ -n "$defaults" ]] && rm -f "$defaults"
  return $rc
}

# db_create_database NAME
db_create_database() {
  local name="$1"
  is_valid_db_name "$name" || die "Nama database tidak valid: $name"
  db_exec "CREATE DATABASE IF NOT EXISTS \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
    && log_action "db_create_database: dibuat database '${name}'"
}

# db_create_user USER PASS
db_create_user() {
  local user="$1" pass="$2"
  local esc_pass
  is_valid_db_name "$user" || die "Nama user database tidak valid: $user"
  esc_pass="$(_wpm_sql_escape "$pass")"
  db_exec "CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${esc_pass}';" \
    && log_action "db_create_user: dibuat user DB '${user}'@'localhost'"
}

# db_grant_all DB USER
db_grant_all() {
  local db="$1" user="$2"
  is_valid_db_name "$db" || die "Nama database tidak valid: $db"
  is_valid_db_name "$user" || die "Nama user database tidak valid: $user"
  db_exec "GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost'; FLUSH PRIVILEGES;" \
    && log_action "db_grant_all: user '${user}' diberi hak penuh atas '${db}'"
}

# db_drop_database NAME
db_drop_database() {
  local name="$1"
  is_valid_db_name "$name" || die "Nama database tidak valid: $name"
  db_exec "DROP DATABASE IF EXISTS \`${name}\`;" \
    && log_action "db_drop_database: database '${name}' dihapus"
}

# db_drop_user USER
db_drop_user() {
  local user="$1"
  is_valid_db_name "$user" || die "Nama user database tidak valid: $user"
  db_exec "DROP USER IF EXISTS '${user}'@'localhost';" \
    && log_action "db_drop_user: user DB '${user}' dihapus"
}

# db_list_databases — echoes non-system database names, one per line.
db_list_databases() {
  local defaults rc out
  defaults="$(db_defaults_file)"
  local cmd=("$(_wpm_mysql_bin)")
  [[ -n "$defaults" ]] && cmd+=(--defaults-extra-file="$defaults")
  cmd+=(-N -B -e "SHOW DATABASES;")
  out="$("${cmd[@]}" 2>/dev/null)"
  rc=$?
  [[ -n "$defaults" ]] && rm -f "$defaults"
  (( rc != 0 )) && return 1
  printf '%s\n' "$out" | grep -Ev '^(information_schema|performance_schema|mysql|sys)$'
}

# db_dump_import SRC_DB DST_DB — streaming dump+import (NFR-02/§7.1): pipes
# mysqldump directly into mysql, no SQL file ever touches disk. Both halves
# of the pipeline run under run_nice. Returns 0 only if both stages of the
# pipeline succeeded (checked via PIPESTATUS).
db_dump_import() {
  local src_db="$1" dst_db="$2"
  is_valid_db_name "$src_db" || die "Nama database sumber tidak valid: $src_db"
  is_valid_db_name "$dst_db" || die "Nama database tujuan tidak valid: $dst_db"

  local defaults
  defaults="$(db_defaults_file)"

  local dump_cmd=("$(_wpm_mysqldump_bin)" --single-transaction --quick)
  local imp_cmd=("$(_wpm_mysql_bin)")
  if [[ -n "$defaults" ]]; then
    dump_cmd+=(--defaults-extra-file="$defaults")
    imp_cmd+=(--defaults-extra-file="$defaults")
  fi
  dump_cmd+=("$src_db")
  imp_cmd+=("$dst_db")

  log_action "db_dump_import: mulai streaming dump '${src_db}' -> '${dst_db}'"

  run_nice "${dump_cmd[@]}" | run_nice "${imp_cmd[@]}"
  local pipestatus_arr=("${PIPESTATUS[@]}")

  [[ -n "$defaults" ]] && rm -f "$defaults"

  if (( pipestatus_arr[0] != 0 )); then
    log_error "mysqldump gagal (exit ${pipestatus_arr[0]}) saat dump database '${src_db}'."
    return 1
  fi
  if (( pipestatus_arr[1] != 0 )); then
    log_error "Import ke database '${dst_db}' gagal (exit ${pipestatus_arr[1]})."
    return 1
  fi

  log_action "db_dump_import: selesai '${src_db}' -> '${dst_db}'"
  return 0
}

# db_import_sql_file DST_DB FILE [FILE...] — imports one or more raw
# .sql/.sql.gz dump files into DST_DB as ONE continuous mysql session, so
# multi-file dumps (e.g. a schema file followed by a data file) land
# together in the same database. Files are streamed in the order given —
# no SQL file is ever decompressed to disk. Only the mysql side of the
# pipeline runs under run_nice (NFR-01); the readers (zcat/cat) are cheap.
# Returns 0 only if BOTH sides of the pipeline succeeded (checked via
# PIPESTATUS — the reader loop is a single brace-group pipeline stage, so
# PIPESTATUS always has exactly 2 elements regardless of file count; the
# brace group itself exits non-zero if any single file's zcat/cat failed).
db_import_sql_file() {
  local dst_db="$1"
  shift
  local files=("$@")

  if ! is_valid_db_name "$dst_db"; then
    log_error "db_import_sql_file: nama database tujuan tidak valid: $dst_db"
    return 1
  fi

  local f
  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      log_error "db_import_sql_file: file dump tidak ditemukan: $f"
      return 1
    fi
  done

  local defaults
  defaults="$(db_defaults_file)"

  local imp_cmd=("$(_wpm_mysql_bin)")
  [[ -n "$defaults" ]] && imp_cmd+=(--defaults-extra-file="$defaults")
  imp_cmd+=("$dst_db")

  log_action "db_import_sql_file: mulai impor ${#files[@]} berkas ke database '${dst_db}'"

  {
    local f rc=0
    for f in "${files[@]}"; do
      if [[ "$f" == *.gz ]]; then
        zcat -- "$f" || rc=1
      else
        cat -- "$f" || rc=1
      fi
    done
    exit "$rc"
  } | run_nice "${imp_cmd[@]}"
  local pipestatus_arr=("${PIPESTATUS[@]}")

  [[ -n "$defaults" ]] && rm -f "$defaults"

  if (( pipestatus_arr[0] != 0 )); then
    log_error "db_import_sql_file: gagal membaca salah satu berkas dump untuk database '${dst_db}' (berkas: ${files[*]})."
    return 1
  fi

  if (( pipestatus_arr[1] != 0 )); then
    log_error "db_import_sql_file: import ke database '${dst_db}' gagal (exit ${pipestatus_arr[1]}) saat mengimpor berkas: ${files[*]}"
    return 1
  fi

  log_action "db_import_sql_file: selesai impor ${#files[@]} berkas ke database '${dst_db}'"
  return 0
}
