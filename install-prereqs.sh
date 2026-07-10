#!/usr/bin/env bash
#
# install-prereqs.sh — One-click installer for WPM's SERVER PREREQUISITES
# (README.txt §1 / PRD-WPM.md §2.1):
#
#   - OpenLiteSpeed, terpasang di /usr/local/lsws
#   - MariaDB atau MySQL (berjalan)
#   - Minimal satu versi lsphp (default: lsphp82)
#   - Redis >= 6.0 (wajib — fitur ACL per app)
#
# This is a SEPARATE, standalone script from install.sh. install.sh installs
# and configures the WPM TOOL ITSELF and assumes the four components above
# are already installed and running (WPM never installs a web/DB/cache
# stack on its own, by design — see PRD-WPM.md §1.4 Non-Goals). This script
# exists to get a bare Ubuntu 24.04 VPS to that starting point.
#
#   Run this FIRST on a fresh server, then run install.sh.
#
# It works standalone (no WPM checkout required) — it does not source any
# lib/*.sh — so it can be fetched and run as a true single-file one-click
# command:
#
#   sudo ./install-prereqs.sh
#   bash <(curl -sL https://raw.githubusercontent.com/<user>/<repo>/main/install-prereqs.sh)
#
# It uses OpenLiteSpeed's own official one-click installer (ols1clk.sh,
# https://github.com/litespeedtech/ols1clk) to install OpenLiteSpeed + lsphp
# (+ MariaDB/MySQL when needed), and apt for Redis. Every already-present
# component is detected and skipped — safe to re-run.
#
# Optional environment overrides (all have sensible defaults; safe to leave
# unset for a true "one click" run):
#
#   WPM_LSPHP_VERSION   Versi lsphp yang dipasang (default: 82). Pilihan resmi
#                       ols1clk saat ini: 74 80 81 82 83 84 85.
#   WPM_DB_ENGINE       "mariadb" (default) atau "mysql" — hanya dipakai bila
#                       belum ada MariaDB/MySQL yang terdeteksi berjalan.
#   WPM_DB_ROOT_PASS    Password root database yang akan diterapkan (bila
#                       WPM yang memasang DB-nya). Default: acak 24 karakter,
#                       otomatis disimpan ke /etc/wpm/.secrets (600) supaya
#                       install.sh nanti tidak perlu tanya ulang.
#   WPM_OLS_ADMIN_PASS  Password WebAdmin console OpenLiteSpeed (port 7080).
#                       Default: acak 24 karakter, dicetak sekali di akhir.
#   WPM_SKIP_OLS=1      Lewati instalasi OpenLiteSpeed + lsphp sepenuhnya.
#   WPM_SKIP_DB=1       Lewati instalasi database sepenuhnya (pakai bila
#                       Anda akan memasang/mengelola sendiri).
#   WPM_SKIP_REDIS=1    Lewati instalasi Redis.
#   WPM_ASSUME_YES=1    Lewati konfirmasi awal (jalan sepenuhnya tanpa
#                       interaksi — otomatis aktif bila stdin bukan TTY dan
#                       /dev/tty tidak tersedia).
#
set -uo pipefail

# ============================================================================
# Minimal standalone UI/logging (sengaja TIDAK sourcing lib/core.sh — lihat
# catatan di header: script ini harus bisa jalan tanpa checkout WPM sama
# sekali).
# ============================================================================

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

_LOG_DIR="/var/log/wpm"
_LOG_FILE="${_LOG_DIR}/install-prereqs.log"
mkdir -p "$_LOG_DIR" 2>/dev/null && chmod 750 "$_LOG_DIR" 2>/dev/null || true
: >>"$_LOG_FILE" 2>/dev/null || _LOG_FILE="/dev/null"

_ts() { date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true; }
log_info()  { printf '%s[INFO]%s %s\n'  "$C_GREEN"  "$C_RESET" "$1"; printf '%s [INFO] %s\n'  "$(_ts)" "$1" >>"$_LOG_FILE"; }
log_warn()  { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$1" >&2; printf '%s [WARN] %s\n'  "$(_ts)" "$1" >>"$_LOG_FILE"; }
log_error() { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$1" >&2; printf '%s [ERROR] %s\n' "$(_ts)" "$1" >>"$_LOG_FILE"; }
die() { log_error "$1"; exit 1; }

# confirm PROMPT [default_y|default_n] — dipakai sekali di awal saja.
confirm() {
  local prompt="$1" default="${2:-default_y}" suffix ans
  [[ "$default" == "default_y" ]] && suffix="[Y/n]" || suffix="[y/N]"
  printf '%s %s ' "$prompt" "$suffix"
  read -r ans || ans=""
  ans="${ans,,}"
  if [[ -z "$ans" ]]; then
    [[ "$default" == "default_y" ]] && return 0 || return 1
  fi
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

rand_password() {
  local len="${1:-24}"
  tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len"
}

# Re-attach stdin to the controlling terminal if it isn't one already, so
# `bash <(curl ...)` still lets the one confirm() below work interactively;
# if no terminal is reachable at all, fall back to fully unattended.
_WPM_NONINTERACTIVE=0
if [[ ! -t 0 ]]; then
  if [[ -r /dev/tty ]]; then
    exec < /dev/tty
  else
    _WPM_NONINTERACTIVE=1
  fi
fi

# ============================================================================
# Gate 1/2: root + Ubuntu 24.04 (sama seperti install.sh)
# ============================================================================

if [[ "${EUID:-$(id -u)}" != "0" ]]; then
  die "install-prereqs.sh harus dijalankan sebagai root. Coba: sudo bash install-prereqs.sh"
fi

if [[ ! -r /etc/os-release ]]; then
  die "Tidak dapat mendeteksi distribusi OS (/etc/os-release tidak ditemukan). Script ini hanya diuji di Ubuntu 24.04 LTS."
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  die "Script ini menargetkan Ubuntu 24.04 LTS persis (terdeteksi: ${PRETTY_NAME:-${ID:-tidak diketahui} ${VERSION_ID:-}}). Dibatalkan untuk menghindari konfigurasi yang tidak terduga."
fi

readonly OLS_HOME="/usr/local/lsws"
readonly OLS_CTRL="${OLS_HOME}/bin/lswsctrl"
readonly WPM_ETC="/etc/wpm"
readonly WPM_SECRETS="${WPM_ETC}/.secrets"

readonly LSPHP_VERSION="${WPM_LSPHP_VERSION:-82}"
readonly DB_ENGINE="${WPM_DB_ENGINE:-mariadb}"

# ============================================================================
# Deteksi komponen yang sudah ada (idempotent — aman dijalankan ulang)
# ============================================================================

_detect_ols() { [[ -x "$OLS_CTRL" ]]; }

_detect_lsphp_any() {
  local d
  shopt -s nullglob
  for d in "${OLS_HOME}"/lsphp*; do
    [[ -x "${d}/bin/lsphp" ]] && { shopt -u nullglob; return 0; }
  done
  shopt -u nullglob
  return 1
}

_detect_db() {
  command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1 || return 1
  local svc
  for svc in mariadb mysql mysqld; do
    systemctl is-active --quiet "$svc" 2>/dev/null && return 0
  done
  [[ -S /var/run/mysqld/mysqld.sock || -S /run/mysqld/mysqld.sock ]] && return 0
  pgrep -x mysqld >/dev/null 2>&1 && return 0
  pgrep -x mariadbd >/dev/null 2>&1
}

_detect_redis() {
  command -v redis-server >/dev/null 2>&1 || return 1
  systemctl is-active --quiet redis-server 2>/dev/null && return 0
  systemctl is-active --quiet redis 2>/dev/null && return 0
  pgrep -x redis-server >/dev/null 2>&1
}

_redis_version_ge6() {
  local ver=""
  if command -v redis-cli >/dev/null 2>&1; then
    ver="$(redis-cli -h 127.0.0.1 -p 6379 INFO server 2>/dev/null | awk -F: '/^redis_version:/{print $2}' | tr -d '\r')"
  fi
  if [[ -z "$ver" ]] && command -v redis-server >/dev/null 2>&1; then
    ver="$(redis-server --version 2>/dev/null | grep -oE 'v=[0-9]+\.[0-9]+' | head -n1 | cut -d= -f2)"
  fi
  [[ -z "$ver" ]] && return 1
  local major="${ver%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  (( major >= 6 ))
}

# ============================================================================
# Langkah 1 — OpenLiteSpeed + lsphp (+ database bila belum ada) via ols1clk
# ============================================================================
#
# ols1clk.sh (https://github.com/litespeedtech/ols1clk) adalah installer
# resmi LiteSpeed Technologies. Opsi yang dipakai di sini:
#   --lsphp VERSION           versi lsphp yang dipasang (independen dari WP)
#   --pure-mariadb/--pure-mysql   pasang MariaDB/MySQL TANPA sample WordPress
#                                  (WPM tidak butuh WP contoh — lihat Non-Goals)
#   -R/--dbrootpassword PASS  password root database yang dipasang
#   -A/--adminpassword PASS   password WebAdmin console OLS
#   -Q/--quiet                mode non-interaktif (auto-yes)
# Sengaja TIDAK memakai -W/--wordpress atau --wordpressplus — WPM mengelola
# WordPress lewat clone dari app sumber, bukan lewat instalasi WP contoh.

install_ols_and_lsphp() {
  if [[ "${WPM_SKIP_OLS:-0}" == "1" ]]; then
    log_info "WPM_SKIP_OLS=1 — melewati instalasi OpenLiteSpeed/lsphp."
    return 0
  fi

  if _detect_ols; then
    log_info "OpenLiteSpeed sudah terpasang di ${OLS_HOME} — melewati instalasi OLS."
    if ! _detect_lsphp_any; then
      log_warn "Tidak ada lsphp terdeteksi di ${OLS_HOME}/lsphp*. OpenLiteSpeed sudah ada jadi ols1clk tidak dijalankan ulang (berisiko mengganggu instalasi yang ada) — pasang lsphp${LSPHP_VERSION} secara manual, lihat https://openlitespeed.org/kb/how-to-install-lsphp-from-litespeed-repository/"
    fi
    return 0
  fi

  command -v curl >/dev/null 2>&1 || { apt-get update -y >>"$_LOG_FILE" 2>&1; apt-get install -y curl ca-certificates >>"$_LOG_FILE" 2>&1; }
  command -v curl >/dev/null 2>&1 || die "curl tidak tersedia dan gagal dipasang — tidak dapat mengunduh ols1clk.sh."

  local db_engine_detected=0
  _detect_db && db_engine_detected=1

  local tmp_script
  tmp_script="$(mktemp /tmp/ols1clk.XXXXXX.sh)" || die "Gagal membuat file sementara untuk ols1clk.sh."
  log_info "Mengunduh installer resmi OpenLiteSpeed (ols1clk.sh)..."
  if ! curl -fsSL "https://raw.githubusercontent.com/litespeedtech/ols1clk/master/ols1clk.sh" -o "$tmp_script"; then
    rm -f "$tmp_script"
    die "Gagal mengunduh ols1clk.sh. Pasang OpenLiteSpeed secara manual: https://openlitespeed.org/kb/install/"
  fi
  chmod +x "$tmp_script"

  local -a args=(--lsphp "$LSPHP_VERSION" -Q)
  local ols_admin_pass="${WPM_OLS_ADMIN_PASS:-$(rand_password 24)}"
  args+=(-A "$ols_admin_pass")

  local db_root_pass=""
  if (( ! db_engine_detected )) && [[ "${WPM_SKIP_DB:-0}" != "1" ]]; then
    db_root_pass="${WPM_DB_ROOT_PASS:-$(rand_password 24)}"
    case "$DB_ENGINE" in
      mysql) args+=(--pure-mysql) ;;
      *)     args+=(--pure-mariadb) ;;
    esac
    args+=(-R "$db_root_pass")
    log_info "Database belum terdeteksi — ols1clk akan memasang ${DB_ENGINE} sekalian (tanpa contoh WordPress)."
  else
    log_info "Database sudah terdeteksi berjalan (atau WPM_SKIP_DB=1) — ols1clk hanya memasang OpenLiteSpeed + lsphp${LSPHP_VERSION}."
  fi

  log_info "Menjalankan ols1clk.sh (lsphp${LSPHP_VERSION}${db_root_pass:+, ${DB_ENGINE}})... ini bisa memakan waktu beberapa menit."
  printf '=== ols1clk.sh output ===\n' >>"$_LOG_FILE"
  if ! bash "$tmp_script" "${args[@]}" >>"$_LOG_FILE" 2>&1; then
    rm -f "$tmp_script"
    die "ols1clk.sh gagal (exit non-nol) — lihat detail di ${_LOG_FILE}. Pasang manual: https://openlitespeed.org/kb/install/"
  fi
  rm -f "$tmp_script"

  if ! _detect_ols; then
    die "ols1clk.sh selesai tapi ${OLS_CTRL} tidak ditemukan — instalasi OpenLiteSpeed kemungkinan gagal. Lihat ${_LOG_FILE}."
  fi
  log_info "OpenLiteSpeed berhasil terpasang di ${OLS_HOME}."

  if _detect_lsphp_any; then
    log_info "lsphp${LSPHP_VERSION} (atau versi lsphp lain) berhasil terpasang."
  else
    log_warn "OpenLiteSpeed terpasang tapi tidak ada lsphp terdeteksi di ${OLS_HOME}/lsphp* — periksa ${_LOG_FILE}."
  fi

  if [[ -n "$db_root_pass" ]]; then
    mkdir -p "$WPM_ETC" && chmod 700 "$WPM_ETC"
    local tmp_secrets
    tmp_secrets="$(mktemp)"; (umask 077; : >"$tmp_secrets")
    printf 'MYSQL_ROOT_USER="root"\nMYSQL_ROOT_PASS="%s"\n' "$db_root_pass" >"$tmp_secrets"
    chmod 600 "$tmp_secrets"
    mv "$tmp_secrets" "$WPM_SECRETS"
    log_info "Password root ${DB_ENGINE} disimpan otomatis di ${WPM_SECRETS} (600) — install.sh nanti tidak akan menanyakannya lagi."
  fi

  printf '\n%s=== OpenLiteSpeed WebAdmin ===%s\n' "$C_BOLD" "$C_RESET"
  printf '  URL      : https://<ip-vps>:7080\n'
  printf '  User     : admin\n'
  printf '  Password : %s\n' "$ols_admin_pass"
  printf '%sCatat sekarang — password ini tidak dicetak ulang (bisa direset lewat: wpm > 5 > Ganti Port & Password WebAdmin).%s\n\n' "$C_YELLOW" "$C_RESET"
}

# ============================================================================
# Langkah 2 — Database fallback (hanya dipakai bila OpenLiteSpeed SUDAH ada
# sebelumnya, sehingga ols1clk di atas dilewati sepenuhnya dan tidak sempat
# memasang database).
# ============================================================================

install_db_fallback() {
  [[ "${WPM_SKIP_DB:-0}" == "1" ]] && { log_info "WPM_SKIP_DB=1 — melewati instalasi database."; return 0; }
  _detect_db && { log_info "Database (MariaDB/MySQL) sudah terdeteksi berjalan — dilewati."; return 0; }
  ! _detect_ols && return 0   # sudah/akan ditangani oleh ols1clk di install_ols_and_lsphp
  [[ "${WPM_SKIP_OLS:-0}" != "1" ]] && return 0  # ols1clk baru saja berjalan & seharusnya sudah menangani ini

  log_info "OpenLiteSpeed sudah ada sebelumnya (WPM_SKIP_OLS=1) dan belum ada database — memasang ${DB_ENGINE} langsung via apt."
  apt-get update -y >>"$_LOG_FILE" 2>&1
  local pkg="mariadb-server"
  [[ "$DB_ENGINE" == "mysql" ]] && pkg="mysql-server"
  if ! apt-get install -y "$pkg" >>"$_LOG_FILE" 2>&1; then
    die "Gagal memasang ${pkg} via apt — lihat ${_LOG_FILE}. Pasang manual, lalu jalankan ulang script ini."
  fi
  systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysql 2>/dev/null || true
  log_info "${pkg} berhasil dipasang & diaktifkan. Root MySQL/MariaDB memakai auth_socket (tanpa password) secara default — saat menjalankan install.sh nanti, cukup tekan Enter pada prompt user (root) dan password (kosongkan)."
}

# ============================================================================
# Langkah 3 — Redis >= 6.0
# ============================================================================

install_redis() {
  if [[ "${WPM_SKIP_REDIS:-0}" == "1" ]]; then
    log_info "WPM_SKIP_REDIS=1 — melewati instalasi Redis."
    return 0
  fi

  if _detect_redis; then
    if _redis_version_ge6; then
      log_info "Redis sudah terpasang & berjalan dengan versi >= 6.0 — dilewati."
      return 0
    fi
    log_warn "Redis terpasang tapi versinya < 6.0 (fitur ACL WPM butuh >= 6.0). Tambahkan repo APT resmi Redis (https://redis.io/docs/latest/operate/oss_and_stack/install/install-redis/install-redis-on-linux/) lalu upgrade manual."
    return 1
  fi

  log_info "Memasang redis-server via apt..."
  apt-get update -y >>"$_LOG_FILE" 2>&1
  if ! apt-get install -y redis-server >>"$_LOG_FILE" 2>&1; then
    die "Gagal memasang redis-server via apt — lihat ${_LOG_FILE}."
  fi
  systemctl enable --now redis-server >/dev/null 2>&1 || systemctl enable --now redis >/dev/null 2>&1 || true

  if _redis_version_ge6; then
    log_info "Redis berhasil dipasang (versi >= 6.0, memenuhi syarat fitur ACL)."
  else
    log_warn "Redis terpasang tapi versi terdeteksi < 6.0 atau tidak dapat diperiksa. WPM membutuhkan Redis >= 6.0 untuk fitur ACL (§F-3b) — periksa manual: redis-cli INFO server | grep redis_version"
  fi
}

# ============================================================================
# main
# ============================================================================

main() {
  printf '\n%s%s=== WPM — Instalasi Prasyarat Server (README.txt §1) ===%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf 'Script ini akan memasang komponen yang BELUM ada di server ini:\n'
  printf '  - OpenLiteSpeed (via installer resmi ols1clk.sh)\n'
  printf '  - lsphp%s\n' "$LSPHP_VERSION"
  printf '  - %s (hanya bila belum ada database yang berjalan)\n' "$DB_ENGINE"
  printf '  - Redis >= 6.0\n\n'
  printf 'Setiap komponen yang sudah terpasang akan otomatis dilewati (aman dijalankan ulang).\n'
  printf 'Log lengkap: %s\n\n' "$_LOG_FILE"

  if (( ! _WPM_NONINTERACTIVE )) && [[ "${WPM_ASSUME_YES:-0}" != "1" ]]; then
    confirm "Lanjutkan instalasi sekarang?" "default_y" || die "Dibatalkan oleh pengguna."
  else
    log_info "Mode non-interaktif — melanjutkan otomatis tanpa konfirmasi."
  fi

  install_ols_and_lsphp
  install_db_fallback
  install_redis

  printf '\n%s========================================%s\n' "$C_GREEN" "$C_RESET"
  printf '%s Prasyarat server WPM selesai disiapkan.%s\n' "$C_GREEN" "$C_RESET"
  printf '%s========================================%s\n\n' "$C_GREEN" "$C_RESET"
  printf 'Langkah berikutnya — pasang WPM itu sendiri:\n\n'
  printf '    git clone <url-repo-wpm-anda>.git wpm && cd wpm && sudo ./install.sh\n\n'
  log_info "install-prereqs.sh selesai."
}

main "$@"
