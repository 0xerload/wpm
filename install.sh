#!/usr/bin/env bash
#
# install.sh — WPM one-click installer (PRD §4.2 / WPM-CONTRACT.md).
#
# Usage — from a full repo checkout (recommended):
#   git clone <url-repo-wpm-anda>.git wpm && cd wpm && sudo ./install.sh
#
# Usage — single-file curl (PRD §4.2 example):
#   bash <(curl -sL https://raw.githubusercontent.com/<user>/wpm/main/install.sh)
#   NOTE: this MUST be `bash <(curl ...)` (process substitution), not a
#   `curl ... | bash` pipe — process substitution keeps this script's own
#   interactive prompts attached to your terminal. As a second line of
#   defense, this script also re-attaches stdin to /dev/tty itself below if
#   it detects stdin is not already a terminal, so a plain pipe still works
#   whenever a controlling terminal is reachable.
#
#   When run this way there is no local repo checkout sitting next to
#   install.sh, so this script downloads the full WPM source tarball itself
#   before it can proceed (it needs lib/, templates/, monitor.sh, bot.sh,
#   wpm — not just this file). Point it at the right place with:
#     WPM_REPO_SLUG=<owner>/<repo>          (e.g. "someuser/wpm")
#     WPM_REPO_REF=<branch-or-tag>          (default: main)
#     WPM_TARBALL_URL=<direct .tar.gz URL>  (overrides the two above entirely)
#
# Every interactive prompt below has a sensible default (press Enter to
# accept it) — if stdin is ever exhausted/non-interactive, the underlying
# core.sh prompt helpers fall back to those same defaults automatically, so
# this script can also complete unattended.
#
# Optional non-interactive credential override (CI/automation convenience,
# not part of the interactive flow): set WPM_MYSQL_ROOT_USER/WPM_MYSQL_ROOT_PASS
# in the environment to skip the interactive MySQL credential prompt (still
# verified by an actual connection before being trusted/saved).

set -uo pipefail

# ============================================================================
# Bootstrap helpers usable BEFORE lib/core.sh is sourced (root/OS gate, and
# resolving where the rest of the WPM source tree lives).
# ============================================================================

_wpm_plain_die() {
  printf '[ERROR] %s\n' "$1" >&2
  exit 1
}

# Re-attach stdin to the controlling terminal if it isn't one already, so
# this script's `read` prompts still work even if invoked as `curl | bash`
# instead of the documented `bash <(curl ...)` form.
if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
  exec < /dev/tty
fi

# --- Gate 1: must run as root ----------------------------------------------
if [[ "${EUID:-$(id -u)}" != "0" ]]; then
  _wpm_plain_die "install.sh harus dijalankan sebagai root. Coba: sudo bash install.sh"
fi

# --- Gate 2: must be Ubuntu 24.04 LTS (§2.1 target platform) ---------------
if [[ ! -r /etc/os-release ]]; then
  _wpm_plain_die "Tidak dapat mendeteksi distribusi OS (/etc/os-release tidak ditemukan). WPM hanya didukung di Ubuntu 24.04 LTS."
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  _wpm_plain_die "WPM hanya didukung di Ubuntu 24.04 LTS (terdeteksi: ${PRETTY_NAME:-${ID:-tidak diketahui}}). Instalasi dibatalkan."
fi
if [[ "${VERSION_ID:-}" != "24.04" ]]; then
  _wpm_plain_die "WPM menargetkan Ubuntu 24.04 LTS persis (terdeteksi: ${PRETTY_NAME:-$VERSION_ID}). Instalasi dibatalkan untuk menghindari konfigurasi yang tidak terduga."
fi

# --- Resolve where the WPM source tree (lib/, templates/, monitor.sh, ------
# --- bot.sh, wpm) lives: either right next to this file (repo checkout),  -
# --- or downloaded fresh (single-file curl usage). ------------------------

# resolve_src_dir — echoes a directory that already contains a full WPM
# checkout (lib/core.sh + wpm present), 1 if none is found locally.
resolve_src_dir() {
  local candidate=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  fi
  if [[ -n "$candidate" && -f "$candidate/lib/core.sh" && -f "$candidate/wpm" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ -f "$PWD/lib/core.sh" && -f "$PWD/wpm" ]]; then
    printf '%s\n' "$PWD"
    return 0
  fi
  return 1
}

# fetch_src_dir — downloads+extracts the WPM source tarball into a temp
# dir and echoes that directory. Dies with clear, actionable instructions
# if it cannot figure out where to download from, or if the download fails.
fetch_src_dir() {
  local slug="${WPM_REPO_SLUG:-}"
  local ref="${WPM_REPO_REF:-main}"
  local url="${WPM_TARBALL_URL:-}"

  echo "[INFO] Tidak ditemukan checkout WPM lengkap di sebelah install.sh — akan mengunduh source WPM." >&2

  if [[ -z "$url" ]]; then
    if [[ -z "$slug" ]]; then
      _wpm_plain_die "Tidak tahu dari mana mengunduh source WPM (lib/, templates/, monitor.sh, bot.sh, wpm tidak ditemukan di sebelah install.sh, dan variabel WPM_REPO_SLUG/WPM_TARBALL_URL tidak diset).
Pilih salah satu cara menjalankan install.sh:
  1) git clone <url-repo-wpm-anda> wpm && cd wpm && sudo ./install.sh
  2) WPM_REPO_SLUG=<owner>/<repo> [WPM_REPO_REF=<branch>] bash <(curl -sL <url-raw-install.sh>)
  3) WPM_TARBALL_URL=<tautan-arsip-.tar.gz-langsung> bash <(curl -sL <url-raw-install.sh>)"
    fi
    url="https://github.com/${slug}/archive/refs/heads/${ref}.tar.gz"
  fi

  command -v curl >/dev/null 2>&1 || _wpm_plain_die "curl tidak ditemukan — tidak dapat mengunduh source WPM."
  command -v tar >/dev/null 2>&1 || _wpm_plain_die "tar tidak ditemukan — tidak dapat mengekstrak source WPM."

  local tmp
  tmp="$(mktemp -d /tmp/wpm-src.XXXXXX)" || _wpm_plain_die "Gagal membuat direktori sementara untuk source WPM."

  echo "[INFO] Mengunduh: ${url}" >&2
  if ! curl -fsSL "$url" -o "${tmp}/wpm-src.tar.gz"; then
    _wpm_plain_die "Gagal mengunduh source WPM dari ${url}.
Jalankan install.sh dari dalam clone repository WPM (git clone <repo> wpm && cd wpm && sudo ./install.sh),
atau set WPM_TARBALL_URL / WPM_REPO_SLUG (+ WPM_REPO_REF) ke sumber yang benar sebelum menjalankan install.sh."
  fi

  if ! tar -xzf "${tmp}/wpm-src.tar.gz" -C "$tmp"; then
    _wpm_plain_die "Gagal mengekstrak arsip source WPM yang diunduh (${tmp}/wpm-src.tar.gz)."
  fi

  local extracted
  extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [[ -z "$extracted" || ! -f "${extracted}/lib/core.sh" || ! -f "${extracted}/wpm" ]]; then
    _wpm_plain_die "Arsip WPM yang diunduh tidak berisi struktur repo yang diharapkan (lib/core.sh & wpm tidak ditemukan)."
  fi

  printf '%s\n' "$extracted"
}

# ============================================================================
# Component detection helpers (§2.1 prerequisites — OLS/MariaDB-MySQL/lsphp/
# Redis are ALL manual-install prerequisites WPM never installs itself; only
# certbot/rsync/wp-cli/curl/jq/cron are auto-installed via apt-get below).
# ============================================================================

_wpm_detect_db_server() {
  if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
    return 1
  fi
  local svc
  for svc in mariadb mysql mysqld; do
    systemctl is-active --quiet "$svc" 2>/dev/null && return 0
  done
  [[ -S /var/run/mysqld/mysqld.sock || -S /run/mysqld/mysqld.sock ]] && return 0
  pgrep -x mysqld >/dev/null 2>&1 && return 0
  pgrep -x mariadbd >/dev/null 2>&1 && return 0
  return 1
}

_wpm_detect_lsphp() {
  local d
  shopt -s nullglob
  for d in "$OLS_HOME"/lsphp*; do
    if [[ -x "$d/bin/lsphp" ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

_wpm_detect_redis() {
  if ! command -v redis-cli >/dev/null 2>&1 && ! command -v redis-server >/dev/null 2>&1; then
    return 1
  fi
  local svc
  for svc in redis-server redis; do
    systemctl is-active --quiet "$svc" 2>/dev/null && return 0
  done
  pgrep -x redis-server >/dev/null 2>&1
}

_wpm_redis_version_ge6() {
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

# check_prerequisites — §4.2: detect OLS/MariaDB-or-MySQL/lsphp/Redis and
# die with one combined, clear message listing everything missing.
check_prerequisites() {
  log_info "Memeriksa komponen wajib (OpenLiteSpeed, MariaDB/MySQL, lsphp, Redis)..."
  local -a missing=()

  if [[ ! -d "$OLS_HOME" || ! -x "$OLS_CTRL" || ! -f "$OLS_CONF" ]]; then
    missing+=("OpenLiteSpeed tidak terdeteksi lengkap di ${OLS_HOME} (perlu ${OLS_CTRL} dan ${OLS_CONF}). Pasang OpenLiteSpeed secara manual lebih dulu (https://openlitespeed.org/kb/install/).")
  fi

  if ! _wpm_detect_db_server; then
    missing+=("MariaDB/MySQL tidak terdeteksi berjalan. Pasang & aktifkan MariaDB atau MySQL server secara manual lebih dulu.")
  fi

  if ! _wpm_detect_lsphp; then
    missing+=("Tidak ada lsphp (PHP handler OpenLiteSpeed) yang terdeteksi di ${OLS_HOME}/lsphp*. Pasang minimal satu versi lsphp (mis. lsphp82) lebih dulu.")
  fi

  if ! _wpm_detect_redis; then
    missing+=("Redis server tidak terdeteksi berjalan. WPM membutuhkan Redis >= 6.0 (fitur ACL, §F-3b). Pasang & aktifkan redis-server lebih dulu.")
  elif ! _wpm_redis_version_ge6; then
    missing+=("Versi Redis yang terpasang lebih lama dari 6.0 — fitur ACL per app (§F-3b) membutuhkan Redis >= 6.0. Perbarui Redis lebih dulu.")
  fi

  if (( ${#missing[@]} > 0 )); then
    log_error "Instalasi dihentikan — komponen wajib berikut belum siap:"
    local i=1 m
    for m in "${missing[@]}"; do
      printf '  %d. %s\n' "$i" "$m" >&2
      ((i++))
    done
    die "Lengkapi komponen di atas (WPM hanya mendukung OLS instalasi manual + MariaDB/MySQL + lsphp + Redis >=6, semuanya sudah berjalan), lalu jalankan ulang install.sh."
  fi

  log_info "Semua komponen wajib terdeteksi dengan baik."
}

# ============================================================================
# Missing-dependency install (§2.1: certbot, rsync, wp-cli, curl, jq, cron)
# ============================================================================

install_missing_packages() {
  log_info "Memeriksa dependensi tambahan (certbot, rsync, wp-cli, curl, jq, cron)..."
  local -a essential_missing=()
  local -a missing_pkgs=()
  local pkg need_wp_cli_pkg=0

  # "certbot", "rsync", "curl", "jq", "cron" are core Ubuntu archive
  # packages and MUST install successfully. "wp-cli" is treated separately
  # below: its exact package availability/name has varied across Ubuntu
  # releases/mirrors, and there is a working phar fallback further down —
  # so a failure to apt-install *just* wp-cli must never abort the whole
  # one-click install (it would otherwise also take certbot/rsync/etc. down
  # with it, since `apt-get install pkg1 pkg2 ...` fails atomically if any
  # single package name in the list is unknown to the configured repos).
  for pkg in certbot rsync curl jq; do
    command -v "$pkg" >/dev/null 2>&1 || essential_missing+=("$pkg")
  done
  command -v wp >/dev/null 2>&1 || need_wp_cli_pkg=1
  if ! command -v crontab >/dev/null 2>&1 && ! dpkg -s cron >/dev/null 2>&1; then
    essential_missing+=("cron")
  fi

  missing_pkgs=("${essential_missing[@]}")
  (( need_wp_cli_pkg )) && missing_pkgs+=("wp-cli")

  if (( ${#missing_pkgs[@]} > 0 )); then
    log_info "Memasang paket yang belum ada: ${missing_pkgs[*]}"
    log_action "install_missing_packages: apt-get install -y ${missing_pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update >>"$WPM_LOG_FILE" 2>&1; then
      log_warn "apt-get update mengembalikan status non-nol — melanjutkan dengan cache paket yang ada."
    fi
    if ! apt-get install -y "${missing_pkgs[@]}" >>"$WPM_LOG_FILE" 2>&1; then
      log_warn "Gagal memasang sekaligus: ${missing_pkgs[*]}. Mencoba lagi tanpa wp-cli (bisa jadi nama paket tsb tidak tersedia di repo ini) — fallback wp-cli.phar akan dipakai di bawah."
      if (( ${#essential_missing[@]} > 0 )); then
        if ! apt-get install -y "${essential_missing[@]}" >>"$WPM_LOG_FILE" 2>&1; then
          die "Gagal memasang paket wajib: ${essential_missing[*]}. Lihat ${WPM_LOG_FILE} untuk detail, perbaiki, lalu jalankan ulang install.sh."
        fi
        log_info "Paket wajib berhasil dipasang: ${essential_missing[*]}"
      fi
    else
      log_info "Paket tambahan berhasil dipasang: ${missing_pkgs[*]}"
    fi
  else
    log_info "Semua dependensi tambahan sudah terpasang."
  fi

  # wp-cli's apt package doesn't always land a `wp` binary on PATH on every
  # Ubuntu point release — fall back to the official phar so require_cmd wp
  # (used by clone.sh/redis.sh later) never blocks on this.
  if ! command -v wp >/dev/null 2>&1; then
    log_warn "Perintah 'wp' belum tersedia setelah instalasi paket wp-cli — mencoba fallback unduh wp-cli.phar..."
    if curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar 2>>"$WPM_LOG_FILE"; then
      chmod +x /usr/local/bin/wp
      log_action "wp-cli dipasang manual via phar ke /usr/local/bin/wp"
    else
      log_warn "Gagal memasang wp-cli lewat fallback phar. Fitur clone & sinkron Redis ke LSCWP membutuhkan 'wp' — pasang manual sebelum memakai fitur tsb."
    fi
  fi

  systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
}

# ============================================================================
# MySQL root credentials (§4.2 / §6.2): skip entirely if /root/.my.cnf
# exists; otherwise collect into $WPM_SECRETS (600), verifying the
# connection actually works before ever persisting it.
# ============================================================================

setup_mysql_credentials() {
  if [[ -f /root/.my.cnf ]]; then
    log_info "/root/.my.cnf ditemukan — kredensial root MySQL akan dipakai langsung (WPM tidak perlu menyimpan salinannya)."
    return 0
  fi

  if [[ -f "$WPM_SECRETS" ]] && grep -q '^MYSQL_ROOT_USER=' "$WPM_SECRETS" 2>/dev/null; then
    if db_exec "SELECT 1;" >/dev/null 2>&1; then
      log_info "Kredensial root MySQL sudah tersimpan di $WPM_SECRETS dan berhasil diverifikasi — dilewati."
      return 0
    fi
    log_warn "Kredensial root MySQL tersimpan di $WPM_SECRETS tapi gagal diverifikasi — akan diminta ulang."
  fi

  log_info "Tidak ditemukan /root/.my.cnf — masukkan kredensial root database untuk disimpan di $WPM_SECRETS (600)."

  local db_user db_pass tmp attempt
  db_user="${WPM_MYSQL_ROOT_USER:-}"
  db_pass="${WPM_MYSQL_ROOT_PASS:-}"

  if [[ -n "$db_user" ]]; then
    log_info "Memakai WPM_MYSQL_ROOT_USER/WPM_MYSQL_ROOT_PASS dari environment (non-interaktif)."
    tmp="$(mktemp)"; chmod 600 "$tmp"
    printf '[client]\nuser=%s\npassword=%s\nhost=localhost\n' "$db_user" "$db_pass" >"$tmp"
    if mysql --defaults-extra-file="$tmp" -e 'SELECT 1;' >/dev/null 2>&1; then
      rm -f "$tmp"
      mkdir -p "$WPM_ETC"; chmod 700 "$WPM_ETC"
      _wpm_conf_write_file "$WPM_SECRETS" 600 MYSQL_ROOT_USER="$db_user" MYSQL_ROOT_PASS="$db_pass"
      log_action "Kredensial root MySQL (dari environment) disimpan di $WPM_SECRETS"
      log_info "Kredensial database tersimpan aman di $WPM_SECRETS (600)."
      if db_exec "SELECT 1;" >/dev/null 2>&1; then
        log_info "Verifikasi akhir koneksi database (via db_exec) berhasil."
      else
        log_warn "Verifikasi lanjutan db_exec gagal walau tes awal berhasil — periksa kembali $WPM_SECRETS bila WPM nanti gagal mengakses database."
      fi
      return 0
    fi
    rm -f "$tmp"
    log_warn "Kredensial dari WPM_MYSQL_ROOT_USER/WPM_MYSQL_ROOT_PASS gagal diverifikasi — lanjut ke input interaktif."
  fi

  for attempt in 1 2 3; do
    db_user="$(prompt_default "User root database" "root")"
    printf 'Password untuk user %s (input tersembunyi, boleh kosong jika memang tanpa password): ' "$db_user" >&2
    read -rs db_pass || db_pass=""
    printf '\n' >&2

    tmp="$(mktemp)"; chmod 600 "$tmp"
    printf '[client]\nuser=%s\npassword=%s\nhost=localhost\n' "$db_user" "$db_pass" >"$tmp"
    if mysql --defaults-extra-file="$tmp" -e 'SELECT 1;' >/dev/null 2>&1; then
      rm -f "$tmp"
      mkdir -p "$WPM_ETC"; chmod 700 "$WPM_ETC"
      _wpm_conf_write_file "$WPM_SECRETS" 600 MYSQL_ROOT_USER="$db_user" MYSQL_ROOT_PASS="$db_pass"
      log_action "Kredensial root MySQL disimpan di $WPM_SECRETS (user=${db_user})"
      log_info "Kredensial database tersimpan aman di $WPM_SECRETS (600)."
      if db_exec "SELECT 1;" >/dev/null 2>&1; then
        log_info "Verifikasi akhir koneksi database (via db_exec) berhasil."
      else
        log_warn "Verifikasi lanjutan db_exec gagal walau tes awal berhasil — periksa kembali $WPM_SECRETS bila WPM nanti gagal mengakses database."
      fi
      return 0
    fi
    rm -f "$tmp"
    log_warn "Gagal konek ke database dengan kredensial tersebut (percobaan ${attempt}/3)."
  done

  die "Tidak dapat memverifikasi kredensial root database setelah 3 percobaan. Periksa kembali user/password, lalu jalankan ulang install.sh."
}

# ============================================================================
# Optional low-end-first tuning (§7.1) — all skippable, sensible defaults.
# ============================================================================

offer_swap() {
  if swapon --show 2>/dev/null | grep -q . ; then
    log_info "Swap sudah aktif — pembuatan swap 2GB dilewati."
    return 0
  fi

  if ! confirm "Buat swap 2GB (disarankan untuk VPS RAM terbatas, §7.1 — mencegah OOM saat clone)?" "default_y"; then
    log_info "Pembuatan swap dilewati atas pilihan pengguna."
    return 0
  fi

  local swapfile="/swapfile"
  if [[ -e "$swapfile" ]]; then
    log_warn "${swapfile} sudah ada — dilewati pembuatan ulang. Pastikan sudah aktif (swapon --show)."
    return 0
  fi

  log_info "Membuat swap 2GB di ${swapfile} ..."
  if ! { command -v fallocate >/dev/null 2>&1 && fallocate -l 2G "$swapfile" 2>/dev/null; }; then
    dd if=/dev/zero of="$swapfile" bs=1M count=2048 status=none
  fi
  chmod 600 "$swapfile"
  if ! mkswap "$swapfile" >/dev/null 2>>"$WPM_LOG_FILE" || ! swapon "$swapfile" 2>>"$WPM_LOG_FILE"; then
    log_warn "Gagal mengaktifkan swap di ${swapfile} — periksa manual (mkswap/swapon)."
    return 1
  fi
  if ! grep -qF "$swapfile" /etc/fstab 2>/dev/null; then
    printf '%s none swap sw 0 0\n' "$swapfile" >>/etc/fstab
  fi
  log_action "Swap 2GB dibuat & diaktifkan (${swapfile})"
  log_info "Swap 2GB berhasil dibuat dan diaktifkan."
}

offer_mariadb_tuning() {
  if ! confirm "Terapkan tuning MariaDB untuk VPS RAM rendah (innodb_buffer_pool_size=128M, performance_schema=OFF, §7.1)?" "default_y"; then
    log_info "Tuning MariaDB dilewati atas pilihan pengguna."
    return 0
  fi

  local conf_dir=""
  if [[ -d /etc/mysql/mariadb.conf.d ]]; then
    conf_dir="/etc/mysql/mariadb.conf.d"
  elif [[ -d /etc/mysql/mysql.conf.d ]]; then
    conf_dir="/etc/mysql/mysql.conf.d"
  elif [[ -d /etc/mysql/conf.d ]]; then
    conf_dir="/etc/mysql/conf.d"
  else
    log_warn "Direktori conf.d MariaDB/MySQL tidak ditemukan — tuning dilewati (terapkan manual bila perlu)."
    return 1
  fi

  local tuning_file="${conf_dir}/99-wpm-tuning.cnf"
  {
    printf '# BEGIN WPM tuning (§7.1 low-end-first) — dikelola oleh install.sh, aman ditimpa ulang\n'
    printf '[mysqld]\n'
    printf 'innodb_buffer_pool_size = 128M\n'
    printf 'performance_schema = OFF\n'
    printf '# END WPM tuning\n'
  } >"$tuning_file"
  chmod 644 "$tuning_file"
  log_action "Tuning MariaDB ditulis ke ${tuning_file}"

  local svc
  for svc in mariadb mysql mysqld; do
    if systemctl list-unit-files --no-legend --type=service "${svc}.service" 2>/dev/null | grep -q "^${svc}\.service"; then
      log_info "Me-restart service ${svc} agar tuning MariaDB berlaku..."
      if systemctl restart "$svc" 2>>"$WPM_LOG_FILE"; then
        log_action "Service ${svc} berhasil direstart setelah tuning MariaDB"
      else
        log_warn "Gagal restart service ${svc} — terapkan manual: systemctl restart ${svc}"
      fi
      return 0
    fi
  done
  log_warn "Tidak menemukan service mariadb/mysql/mysqld untuk direstart — restart manual diperlukan agar tuning berlaku."
}

# setup_redis_acl_infra — mandatory plumbing (NOT skippable: without it
# WPM's whole Redis ACL feature, §F-3b, cannot function) that wires
# $REDIS_ACL_FILE as redis.conf's aclfile, plus the skippable "databases 64"
# bump from §6.7/§7.1.
setup_redis_acl_infra() {
  local redis_conf="/etc/redis/redis.conf"

  mkdir -p "$(dirname "$REDIS_ACL_FILE")" 2>/dev/null
  [[ -f "$REDIS_ACL_FILE" ]] || : >"$REDIS_ACL_FILE"
  chmod 600 "$REDIS_ACL_FILE"
  if id redis >/dev/null 2>&1; then
    chown redis:redis "$REDIS_ACL_FILE" 2>/dev/null || true
  fi

  if [[ ! -f "$redis_conf" ]]; then
    log_warn "File ${redis_conf} tidak ditemukan — lewati konfigurasi aclfile Redis (atur manual: aclfile ${REDIS_ACL_FILE})."
    return 1
  fi

  if grep -qE '^[[:space:]]*aclfile[[:space:]]+' "$redis_conf"; then
    sed -i -E "s|^[[:space:]]*aclfile[[:space:]]+.*|aclfile ${REDIS_ACL_FILE}|" "$redis_conf"
  else
    printf '\naclfile %s\n' "$REDIS_ACL_FILE" >>"$redis_conf"
  fi
  log_action "Redis dikonfigurasi memakai aclfile ${REDIS_ACL_FILE}"

  if confirm "Naikkan batas 'databases' Redis ke 64 (mendukung hingga ~60 web app, §6.7)?" "default_y"; then
    if grep -qE '^[[:space:]]*databases[[:space:]]+' "$redis_conf"; then
      sed -i -E 's/^[[:space:]]*databases[[:space:]]+.*/databases 64/' "$redis_conf"
    else
      printf '\ndatabases 64\n' >>"$redis_conf"
    fi
    log_action "Redis 'databases' dinaikkan ke 64"
  else
    log_info "Peningkatan Redis 'databases' ke 64 dilewati atas pilihan pengguna."
  fi

  local svc restarted=0
  for svc in redis-server redis; do
    if systemctl list-unit-files --no-legend --type=service "${svc}.service" 2>/dev/null | grep -q "^${svc}\.service"; then
      if systemctl restart "$svc" 2>>"$WPM_LOG_FILE"; then
        log_action "Service ${svc} direstart setelah konfigurasi Redis"
      else
        log_warn "Gagal restart ${svc} — restart manual: systemctl restart ${svc}"
      fi
      restarted=1
      break
    fi
  done
  if (( ! restarted )); then
    log_warn "Tidak menemukan service redis-server/redis untuk direstart — restart manual diperlukan agar konfigurasi berlaku."
  fi
}

# ============================================================================
# Copy repo files into their installed locations (§5.3).
# ============================================================================

install_files() {
  log_info "Menyalin berkas WPM ke ${WPM_HOME} ..."

  local required
  for required in lib templates monitor.sh bot.sh wpm; do
    [[ -e "${SRC_DIR}/${required}" ]] || die "Berkas/direktori sumber '${required}' tidak ditemukan di ${SRC_DIR} — checkout WPM tidak lengkap."
  done

  mkdir -p "$WPM_HOME" || die "Gagal membuat ${WPM_HOME}"

  rsync -a --delete "${SRC_DIR}/lib/" "${WPM_HOME}/lib/" || die "Gagal menyalin lib/ ke ${WPM_HOME}/lib/"
  rsync -a --delete "${SRC_DIR}/templates/" "${WPM_HOME}/templates/" || die "Gagal menyalin templates/ ke ${WPM_HOME}/templates/"
  cp -f "${SRC_DIR}/monitor.sh" "${WPM_HOME}/monitor.sh" || die "Gagal menyalin monitor.sh"
  cp -f "${SRC_DIR}/bot.sh" "${WPM_HOME}/bot.sh" || die "Gagal menyalin bot.sh"
  cp -f "${SRC_DIR}/wpm" /usr/local/bin/wpm || die "Gagal menyalin wpm ke /usr/local/bin/wpm"

  find "${WPM_HOME}/lib" -maxdepth 1 -name '*.sh' -exec chmod 644 {} \;
  chmod -R a+rX "${WPM_HOME}/templates"
  chmod 755 "${WPM_HOME}/monitor.sh" "${WPM_HOME}/bot.sh"
  chmod 755 /usr/local/bin/wpm
  chown -R root:root "$WPM_HOME"
  chown root:root /usr/local/bin/wpm

  log_action "Berkas WPM disalin ke ${WPM_HOME}; entry point dipasang di /usr/local/bin/wpm"
  log_info "wpm v${WPM_VERSION} terpasang di /usr/local/bin/wpm."
}

create_dirs() {
  mkdir -p "$WPM_ETC" "$WPM_APPS_DIR" "$WPM_VAR" "$WPM_LOG_DIR" "$WPM_STAGE_DIR"
  chmod 700 "$WPM_ETC" "$WPM_APPS_DIR"
  chmod 750 "$WPM_VAR" "$WPM_LOG_DIR" "$WPM_STAGE_DIR"
  chown root:root "$WPM_ETC" "$WPM_APPS_DIR" "$WPM_VAR" "$WPM_LOG_DIR" "$WPM_STAGE_DIR"
  touch "$WPM_LOG_FILE"
  chmod 640 "$WPM_LOG_FILE"
  chown root:root "$WPM_LOG_FILE"
  log_action "Direktori WPM disiapkan: ${WPM_ETC}, ${WPM_APPS_DIR}, ${WPM_VAR}, ${WPM_LOG_DIR}, ${WPM_STAGE_DIR}"
}

install_cron() {
  local cron_file="/etc/cron.d/wpm-monitor"
  {
    printf 'SHELL=/bin/bash\n'
    printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    printf '# WPM alert monitor (§F-6a) — dijalankan tiap 60 detik, tanpa daemon\n'
    printf '* * * * * root %s/monitor.sh >/dev/null 2>&1\n' "$WPM_HOME"
  } >"$cron_file"
  chmod 644 "$cron_file"
  chown root:root "$cron_file"
  log_action "Cron wpm-monitor dipasang di ${cron_file} (tiap menit)"
  systemctl restart cron >/dev/null 2>&1 || systemctl restart crond >/dev/null 2>&1 || true
  log_info "Monitor alert terjadwal via cron: ${cron_file}"
}

install_bot_service() {
  local unit_file="/etc/systemd/system/wpm-bot.service"
  cat >"$unit_file" <<UNITEOF
[Unit]
Description=WPM Telegram Bot interaktif (opsional, read-only v1, §F-6b)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WPM_HOME}/bot.sh
Restart=on-failure
RestartSec=5
User=root
Nice=19
IOSchedulingClass=best-effort
IOSchedulingPriority=7
MemoryMax=64M
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNITEOF
  chmod 644 "$unit_file"
  systemctl daemon-reload
  log_action "Unit systemd wpm-bot.service ditulis di ${unit_file} (belum diaktifkan)"
  log_info "Unit systemd wpm-bot.service disiapkan tapi TIDAK diaktifkan otomatis — nyalakan lewat: wpm > 6) Telegram & Monitoring, bila ingin memakai bot interaktif."
}

install_logrotate() {
  cat >/etc/logrotate.d/wpm <<EOF
${WPM_LOG_FILE} {
  weekly
  rotate 8
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
}
EOF
  log_action "Kebijakan logrotate untuk ${WPM_LOG_FILE} dipasang di /etc/logrotate.d/wpm"
}

# ============================================================================
# Scan existing (manually-created) vhosts and offer to import them (FR-02).
# ============================================================================

scan_and_import_vhosts() {
  printf '\n%s=== Scan vhost OpenLiteSpeed yang sudah ada ===%s\n' "$C_BOLD" "$C_RESET"

  local -a unmanaged=()
  local name vhroot conf
  while IFS=$'\t' read -r name vhroot conf; do
    [[ -z "$name" ]] && continue
    if ! app_exists "$name"; then
      unmanaged+=("$(printf '%s\t%s\t%s' "$name" "$vhroot" "$conf")")
    fi
  done < <(ols_parse_vhosts)

  if (( ${#unmanaged[@]} == 0 )); then
    log_info "Tidak ada vhost tak terkelola yang ditemukan (atau memang belum ada vhost sama sekali)."
    return 0
  fi

  printf 'Ditemukan %d vhost yang belum terdaftar di registry WPM:\n' "${#unmanaged[@]}"
  local row n v c
  for row in "${unmanaged[@]}"; do
    IFS=$'\t' read -r n v c <<<"$row"
    printf '  - %-20s vhRoot=%-30s configFile=%s\n' "$n" "$v" "$c"
  done
  printf '\n'

  if confirm "Import semua vhost di atas ke registry WPM sekarang?" "default_y"; then
    for row in "${unmanaged[@]}"; do
      IFS=$'\t' read -r n v c <<<"$row"
      if ols_import_vhost "$n" "$v" "$c"; then
        log_info "Vhost '${n}' berhasil diimpor ke registry."
      else
        log_warn "Vhost '${n}' gagal diimpor — cek ${WPM_LOG_FILE}."
      fi
    done
    return 0
  fi

  for row in "${unmanaged[@]}"; do
    IFS=$'\t' read -r n v c <<<"$row"
    if confirm "Import vhost '${n}' ke registry?" "default_n"; then
      if ols_import_vhost "$n" "$v" "$c"; then
        log_info "Vhost '${n}' berhasil diimpor ke registry."
      else
        log_warn "Vhost '${n}' gagal diimpor — cek ${WPM_LOG_FILE}."
      fi
    fi
  done
}

# ============================================================================
# Telegram setup wizard (§F-6c) — skippable, can be run later from menu 6.
# ============================================================================

offer_telegram_setup() {
  printf '\n%s=== Setup Telegram Bot & Monitoring (opsional) ===%s\n' "$C_BOLD" "$C_RESET"
  if confirm "Konfigurasi Telegram sekarang (token bot, deteksi chat ID, pesan tes)? Bisa dilewati dan disetel nanti lewat menu 6." "default_n"; then
    tg_setup_wizard || log_warn "Setup Telegram tidak selesai — dapat diulang kapan saja lewat: wpm > 6) Telegram & Monitoring."
  else
    log_info "Setup Telegram dilewati. Jalankan 'wpm' lalu pilih menu 6 kapan saja untuk mengaturnya."
  fi
}

print_final_message() {
  printf '\n%s========================================%s\n' "$C_GREEN" "$C_RESET"
  printf '%s Instalasi WPM v%s selesai!%s\n' "$C_GREEN" "$WPM_VERSION" "$C_RESET"
  printf '%s========================================%s\n\n' "$C_GREEN" "$C_RESET"
  printf 'Ringkasan lokasi:\n'
  printf '  - Entry point   : /usr/local/bin/wpm\n'
  printf '  - Berkas WPM    : %s\n' "$WPM_HOME"
  printf '  - Registry app  : %s\n' "$WPM_APPS_DIR"
  printf '  - Log aktivitas : %s (rotasi mingguan via logrotate)\n' "$WPM_LOG_FILE"
  printf '  - Sumber staging: %s/<nama>/{data,db} (opsional, untuk Clone Web App)\n' "$WPM_STAGE_DIR"
  printf '  - Monitor alert : /etc/cron.d/wpm-monitor (cron, tiap 60 detik)\n'
  printf '  - Bot Telegram  : /etc/systemd/system/wpm-bot.service (belum aktif — kelola via menu 6)\n\n'
  printf 'Jalankan dengan perintah:\n\n'
  printf '    %swpm%s\n\n' "$C_BOLD" "$C_RESET"
  log_action "install.sh selesai — WPM v${WPM_VERSION} terpasang."
}

# ============================================================================
# main
# ============================================================================

main() {
  SRC_DIR="$(resolve_src_dir)" || SRC_DIR="$(fetch_src_dir)"
  [[ -n "${SRC_DIR:-}" ]] || _wpm_plain_die "Tidak dapat menentukan lokasi source WPM."

  # shellcheck source=/dev/null
  source "${SRC_DIR}/lib/core.sh"
  # shellcheck source=/dev/null
  source "${SRC_DIR}/lib/ols.sh"
  # shellcheck source=/dev/null
  source "${SRC_DIR}/lib/telegram.sh"

  require_root
  acquire_lock

  log_info "=== WPM v${WPM_VERSION} — Instalasi (§4.2) ==="
  log_action "install.sh dimulai (SRC_DIR=${SRC_DIR})"

  check_prerequisites
  install_missing_packages
  setup_mysql_credentials

  printf '\n%s=== Tuning opsional untuk VPS low-end (§7.1) ===%s\n' "$C_BOLD" "$C_RESET"
  offer_swap
  offer_mariadb_tuning
  setup_redis_acl_infra

  install_files
  create_dirs
  install_cron
  install_bot_service
  install_logrotate

  scan_and_import_vhosts
  offer_telegram_setup

  print_final_message
}

main "$@"
