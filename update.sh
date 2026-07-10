#!/usr/bin/env bash
#
# update.sh — perbarui instalasi WPM yang sudah ada ke versi source terbaru.
#
# BUKAN installer awal — pakai install.sh untuk pemasangan pertama kali.
# Script ini HANYA menyinkronkan ulang berkas kode (lib/, templates/,
# monitor.sh, bot.sh, wpm) ke lokasi terpasang ($WPM_HOME,
# /usr/local/bin/wpm). Registry app, database, kredensial
# (/etc/wpm/.secrets, telegram.conf), cron, dan unit systemd TIDAK disentuh.
#
# Usage:
#   cd wpm && git pull && sudo ./update.sh   (checkout git yang sudah ada — direkomendasikan)
#   sudo ./update.sh                          (pakai isi direktori saat ini apa adanya, tanpa git pull)
#   bash <(curl -sL https://raw.githubusercontent.com/<user>/<repo>/main/update.sh)
#                                              (unduh source terbaru langsung, tanpa checkout lokal)
#
# Aman diulang: setiap update di-backup dulu (tar.gz) sebelum ditimpa, dan
# seluruh berkas sumber di-cek sintaksnya (bash -n) SEBELUM disalin ke lokasi
# terpasang — kalau ada yang gagal, instalasi lama tidak disentuh sama sekali.
#
# Env overrides opsional:
#   WPM_REPO_SLUG=<owner>/<repo>       Sumber unduhan bila tidak ada checkout lokal (contoh: someuser/wpm)
#   WPM_REPO_REF=<branch-atau-tag>     Default: main
#   WPM_TARBALL_URL=<url-.tar.gz>      Override total, kalau bukan GitHub
#   WPM_SKIP_GIT_PULL=1                Jangan git pull walau direktori ini git repo (pakai isi lokal apa adanya)
#   WPM_ASSUME_YES=1                   Lewati konfirmasi (untuk otomatisasi/cron)
#
set -uo pipefail

_wpm_plain_die() {
  printf '[ERROR] %s\n' "$1" >&2
  exit 1
}

# Re-attach stdin to the controlling terminal if it isn't one already, so
# `bash <(curl ...)` still lets the confirm() prompt below work interactively.
if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
  exec < /dev/tty
fi

if [[ "${EUID:-$(id -u)}" != "0" ]]; then
  _wpm_plain_die "update.sh harus dijalankan sebagai root. Coba: sudo bash update.sh"
fi

# ============================================================================
# Resolve where the updated WPM source tree lives — sama persis dengan
# install.sh: checkout di sebelah script ini, atau unduh tarball kalau tidak
# ada (lihat WPM_REPO_SLUG/WPM_REPO_REF/WPM_TARBALL_URL di header).
# ============================================================================

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

fetch_src_dir() {
  local slug="${WPM_REPO_SLUG:-}"
  local ref="${WPM_REPO_REF:-main}"
  local url="${WPM_TARBALL_URL:-}"

  echo "[INFO] Tidak ditemukan checkout WPM lengkap di sebelah update.sh — akan mengunduh source WPM terbaru." >&2

  if [[ -z "$url" ]]; then
    if [[ -z "$slug" ]]; then
      _wpm_plain_die "Tidak tahu dari mana mengunduh source WPM (lib/, templates/, monitor.sh, bot.sh, wpm tidak ditemukan di sebelah update.sh, dan variabel WPM_REPO_SLUG/WPM_TARBALL_URL tidak diset).
Pilih salah satu cara menjalankan update.sh:
  1) cd wpm (checkout yang sudah ada) && git pull && sudo ./update.sh
  2) WPM_REPO_SLUG=<owner>/<repo> [WPM_REPO_REF=<branch>] bash <(curl -sL <url-raw-update.sh>)
  3) WPM_TARBALL_URL=<tautan-arsip-.tar.gz-langsung> bash <(curl -sL <url-raw-update.sh>)"
    fi
    url="https://github.com/${slug}/archive/refs/heads/${ref}.tar.gz"
  fi

  command -v curl >/dev/null 2>&1 || _wpm_plain_die "curl tidak ditemukan — tidak dapat mengunduh source WPM."
  command -v tar >/dev/null 2>&1 || _wpm_plain_die "tar tidak ditemukan — tidak dapat mengekstrak source WPM."

  local tmp
  tmp="$(mktemp -d /tmp/wpm-update-src.XXXXXX)" || _wpm_plain_die "Gagal membuat direktori sementara untuk source WPM."

  echo "[INFO] Mengunduh: ${url}" >&2
  if ! curl -fsSL "$url" -o "${tmp}/wpm-src.tar.gz"; then
    _wpm_plain_die "Gagal mengunduh source WPM dari ${url}.
Jalankan update.sh dari dalam checkout repository WPM yang sudah ada (cd wpm && git pull && sudo ./update.sh),
atau set WPM_TARBALL_URL / WPM_REPO_SLUG (+ WPM_REPO_REF) ke sumber yang benar sebelum menjalankan update.sh."
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

# git_pull_if_repo SRC_DIR — bila SRC_DIR adalah checkout git (dan
# WPM_SKIP_GIT_PULL bukan 1), tarik perubahan terbaru terlebih dahulu supaya
# "update otomatis" benar-benar mengambil kode terbaru, bukan cuma
# menyalin ulang checkout lokal yang sudah basi. Non-fatal bila gagal (mis.
# tidak ada koneksi internet) — lanjut memakai isi lokal apa adanya, dengan
# peringatan.
git_pull_if_repo() {
  local dir="$1"
  [[ "${WPM_SKIP_GIT_PULL:-0}" == "1" ]] && return 0
  [[ -d "${dir}/.git" ]] || return 0
  command -v git >/dev/null 2>&1 || { log_warn "git tidak ditemukan — melewati git pull, memakai checkout lokal apa adanya."; return 0; }

  log_info "Checkout git terdeteksi di ${dir} — menarik perubahan terbaru (git pull --ff-only)..."
  if ( cd "$dir" && git pull --ff-only ) >>"$WPM_LOG_FILE" 2>&1; then
    log_info "git pull berhasil."
  else
    log_warn "git pull gagal atau bukan fast-forward — melanjutkan dengan isi checkout lokal apa adanya. Selesaikan dulu (git status/git pull manual) bila Anda mengharapkan perubahan terbaru dari remote."
  fi
}

# ============================================================================
# main
# ============================================================================

main() {
  SRC_DIR="$(resolve_src_dir)" || SRC_DIR="$(fetch_src_dir)"
  [[ -n "${SRC_DIR:-}" ]] || _wpm_plain_die "Tidak dapat menentukan lokasi source WPM."

  # shellcheck source=/dev/null
  source "${SRC_DIR}/lib/core.sh"

  require_root
  acquire_lock

  [[ -x /usr/local/bin/wpm ]] || die "WPM belum terpasang (/usr/local/bin/wpm tidak ditemukan). Jalankan install.sh dulu untuk pemasangan pertama kali — update.sh hanya untuk memperbarui instalasi yang sudah ada."

  git_pull_if_repo "$SRC_DIR"

  # Re-source in case git_pull_if_repo just changed lib/core.sh's own
  # content (WPM_VERSION, path constants, etc.) — cheap, and guarantees
  # every constant/function used below reflects the just-pulled source.
  # shellcheck source=/dev/null
  source "${SRC_DIR}/lib/core.sh"

  local old_version new_version
  old_version="$(/usr/local/bin/wpm --version 2>/dev/null | awk '{print $2}')"
  [[ -z "$old_version" ]] && old_version="?"
  new_version="$WPM_VERSION"

  log_info "${C_BOLD}Update WPM: v${old_version} (terpasang) -> v${new_version} (source di ${SRC_DIR})${C_RESET}"

  # --- Pre-flight: syntax-check EVERY source file before touching the ------
  # --- currently-installed copy. Kalau ada yang gagal, batalkan seluruhnya --
  # --- tanpa mengubah apa pun yang sudah terpasang. -------------------------
  log_info "Memeriksa sintaks seluruh berkas sumber sebelum menyalin..."
  local f
  for f in "${SRC_DIR}"/lib/*.sh "${SRC_DIR}/wpm" "${SRC_DIR}/monitor.sh" "${SRC_DIR}/bot.sh"; do
    [[ -f "$f" ]] || continue
    if ! bash -n "$f" 2>>"$WPM_LOG_FILE"; then
      die "Berkas sumber '${f}' punya syntax error — pembaruan DIBATALKAN, instalasi lama tidak diubah sama sekali. Lihat ${WPM_LOG_FILE}."
    fi
  done
  log_info "Semua berkas sumber lolos pemeriksaan sintaks."

  if [[ "${WPM_ASSUME_YES:-0}" != "1" ]]; then
    confirm "Update WPM dari v${old_version} ke v${new_version} sekarang? (instalasi lama akan di-backup dulu)" "default_y" \
      || { log_info "Update dibatalkan."; exit 0; }
  else
    log_info "WPM_ASSUME_YES=1 — melanjutkan otomatis tanpa konfirmasi."
  fi

  # --- Backup instalasi lama sebelum ditimpa --------------------------------
  local backup_dir="/var/backups/wpm"
  mkdir -p "$backup_dir"
  local ts backup_file
  ts="$(date -u +%Y%m%d%H%M%S)"
  backup_file="${backup_dir}/wpm-pre-update-${ts}.tar.gz"
  if tar -czf "$backup_file" -C / \
        "${WPM_HOME#/}" \
        "usr/local/bin/wpm" 2>>"$WPM_LOG_FILE"; then
    log_info "Instalasi lama di-backup ke ${backup_file}."
  else
    log_warn "Backup instalasi lama gagal dibuat — melanjutkan tanpa backup (periksa ${WPM_LOG_FILE})."
  fi

  # --- Salin berkas baru (persis seperti install.sh's install_files) -------
  log_info "[1/2] Menyalin berkas WPM terbaru ke ${WPM_HOME} ..."
  local required
  for required in lib templates monitor.sh bot.sh wpm; do
    [[ -e "${SRC_DIR}/${required}" ]] || die "Berkas/direktori sumber '${required}' tidak ditemukan di ${SRC_DIR} — checkout WPM tidak lengkap. Instalasi lama TIDAK diubah (backup ada di ${backup_file})."
  done

  mkdir -p "$WPM_HOME" || die "Gagal membuat ${WPM_HOME}"
  rsync -a --delete "${SRC_DIR}/lib/" "${WPM_HOME}/lib/" || die "Gagal menyalin lib/ ke ${WPM_HOME}/lib/ — pulihkan dari ${backup_file} bila perlu."
  rsync -a --delete "${SRC_DIR}/templates/" "${WPM_HOME}/templates/" || die "Gagal menyalin templates/ ke ${WPM_HOME}/templates/ — pulihkan dari ${backup_file} bila perlu."
  cp -f "${SRC_DIR}/monitor.sh" "${WPM_HOME}/monitor.sh" || die "Gagal menyalin monitor.sh — pulihkan dari ${backup_file} bila perlu."
  cp -f "${SRC_DIR}/bot.sh" "${WPM_HOME}/bot.sh" || die "Gagal menyalin bot.sh — pulihkan dari ${backup_file} bila perlu."
  cp -f "${SRC_DIR}/wpm" /usr/local/bin/wpm || die "Gagal menyalin wpm ke /usr/local/bin/wpm — pulihkan dari ${backup_file} bila perlu."

  find "${WPM_HOME}/lib" -maxdepth 1 -name '*.sh' -exec chmod 644 {} \;
  chmod -R a+rX "${WPM_HOME}/templates"
  chmod 755 "${WPM_HOME}/monitor.sh" "${WPM_HOME}/bot.sh"
  chmod 755 /usr/local/bin/wpm
  chown -R root:root "$WPM_HOME"
  chown root:root /usr/local/bin/wpm

  log_action "update.sh: berkas WPM diperbarui v${old_version} -> v${new_version} (src=${SRC_DIR}, backup=${backup_file})"

  # --- Verifikasi pasca-salin ------------------------------------------------
  log_info "[2/2] Memverifikasi hasil pembaruan..."
  if ! bash -n /usr/local/bin/wpm; then
    log_error "wpm yang baru disalin gagal lolos bash -n — ini seharusnya tidak terjadi karena sudah dicek di awal. Pulihkan segera dari ${backup_file}:"
    log_error "  tar -xzf ${backup_file} -C /"
    die "Update gagal diverifikasi."
  fi
  new_version="$(/usr/local/bin/wpm --version 2>/dev/null | awk '{print $2}')"
  log_info "${C_GREEN}wpm sekarang melaporkan versi: ${new_version:-?}${C_RESET}"

  # --- Restart bot Telegram (opsional) kalau sedang aktif, supaya memakai --
  # --- kode bot.sh yang baru. Alert monitor (cron) tidak perlu direstart — --
  # --- setiap invocation cron sudah membaca monitor.sh dari disk. ----------
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet wpm-bot.service 2>/dev/null; then
    if [[ "${WPM_ASSUME_YES:-0}" == "1" ]] || confirm "Bot Telegram (wpm-bot.service) sedang aktif — restart sekarang supaya memakai kode terbaru?" "default_y"; then
      if systemctl restart wpm-bot.service 2>>"$WPM_LOG_FILE"; then
        log_info "wpm-bot.service berhasil direstart."
      else
        log_warn "Gagal restart wpm-bot.service — restart manual: systemctl restart wpm-bot.service"
      fi
    fi
  fi

  printf '\n%s========================================%s\n' "$C_GREEN" "$C_RESET"
  printf '%s WPM berhasil diperbarui: v%s -> v%s%s\n' "$C_GREEN" "$old_version" "${new_version:-?}" "$C_RESET"
  printf '%s========================================%s\n\n' "$C_GREEN" "$C_RESET"
  printf 'Backup instalasi sebelumnya : %s\n' "$backup_file"
  printf 'Registry app, database, kredensial, cron, dan unit systemd tidak diubah.\n\n'
}

main "$@"
