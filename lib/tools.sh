#!/usr/bin/env bash
#
# lib/tools.sh — WPM Tools: Fix Ownership, Rebuild Web App Config, Clear Web App Cache
#
# Implements PRD §F-4 (Tools). Responsibilities per §5.4:
#   - Fix ownership   : chown rekursif ke user OLS + normalisasi permission.
#   - Rebuild config  : bangun ulang vhconf dari snapshot / registry (via ols.sh).
#   - Clear cache     : hapus cache file WordPress/LSCWP + flush Redis DB app itu saja.
#
# This file is a lib — it must be *sourced*, never executed directly, and must
# never `set -e`/`set -u` globally (that would leak into the sourcing shell).
# Each public function below does its own defensive error checking instead.

[[ -n "${WPM_LIB_TOOLS_LOADED:-}" ]] && return
readonly WPM_LIB_TOOLS_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/tools.sh harus di-source, bukan dieksekusi langsung." >&2
  exit 1
fi

# Resolve this file's directory so dependent libs load correctly regardless
# of whether WPM is running from the repo checkout or from its installed
# location ($WPM_HOME). Include-guards in each dependency make re-sourcing
# harmless if the caller already sourced them.
_WPM_TOOLS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./core.sh
source "$_WPM_TOOLS_LIB_DIR/core.sh"
# shellcheck source=./ols.sh
source "$_WPM_TOOLS_LIB_DIR/ols.sh"
# shellcheck source=./redis.sh
source "$_WPM_TOOLS_LIB_DIR/redis.sh"

unset _WPM_TOOLS_LIB_DIR

# ---------------------------------------------------------------------------
# tools_fix_ownership APP
#
# PRD §F-4: chown rekursif ke user OLS (dideteksi dari httpd_config, default
# nobody:nogroup); direktori 755, file 644, wp-config.php 640.
# ---------------------------------------------------------------------------
tools_fix_ownership() {
  local app="$1"

  if [[ -z "$app" ]]; then
    log_error "tools_fix_ownership: nama app tidak boleh kosong."
    return 1
  fi

  if ! app_exists "$app"; then
    log_error "tools_fix_ownership: app '$app' tidak ditemukan di registry."
    return 1
  fi

  local vh_root docroot web_owner
  vh_root="$(app_get "$app" VH_ROOT)"
  docroot="$(app_get "$app" DOCROOT)"

  if [[ -z "$vh_root" ]]; then
    log_error "tools_fix_ownership: VH_ROOT untuk app '$app' kosong di registry."
    return 1
  fi

  if [[ ! -d "$vh_root" ]]; then
    log_error "tools_fix_ownership: direktori VH_ROOT '$vh_root' untuk app '$app' tidak ditemukan."
    return 1
  fi

  web_owner="$(ols_detect_web_user)"
  if [[ -z "$web_owner" || "$web_owner" != *:* ]]; then
    web_owner="nobody:nogroup"
  fi

  log_info "Memperbaiki ownership '$app' → ${web_owner} (${vh_root})"
  log_action "tools_fix_ownership: mulai app=$app vh_root=$vh_root owner=$web_owner"

  if ! chown -R -- "$web_owner" "$vh_root"; then
    log_error "tools_fix_ownership: gagal 'chown -R $web_owner $vh_root'."
    log_action "tools_fix_ownership: gagal chown app=$app"
    return 1
  fi

  if ! find "$vh_root" -type d -exec chmod 755 {} +; then
    log_error "tools_fix_ownership: gagal menormalkan permission direktori di '$vh_root'."
    log_action "tools_fix_ownership: gagal chmod direktori app=$app"
    return 1
  fi

  if ! find "$vh_root" -type f -exec chmod 644 {} +; then
    log_error "tools_fix_ownership: gagal menormalkan permission file di '$vh_root'."
    log_action "tools_fix_ownership: gagal chmod file app=$app"
    return 1
  fi

  # wp-config.php selalu 640 (lebih ketat) — override permission blanket 644
  # di atas. Cari di lokasi kanonik dulu (DOCROOT, lalu VH_ROOT), baru
  # fallback ke pencarian terbatas bila keduanya tidak ada (mis. struktur
  # docroot custom).
  local wp_config_found=0
  local candidate
  for candidate in "$docroot/wp-config.php" "$vh_root/wp-config.php"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      chmod 640 -- "$candidate"
      wp_config_found=1
    fi
  done

  if [[ "$wp_config_found" -eq 0 ]]; then
    local wp_config
    while IFS= read -r wp_config; do
      chmod 640 -- "$wp_config"
      wp_config_found=1
    done < <(find "$vh_root" -maxdepth 4 -type f -name "wp-config.php" 2>/dev/null)
  fi

  if [[ "$wp_config_found" -eq 0 ]]; then
    log_warn "tools_fix_ownership: wp-config.php tidak ditemukan untuk app '$app' — permission 640 dilewati."
  fi

  log_action "tools_fix_ownership: selesai app=$app vh_root=$vh_root owner=$web_owner wp_config=$wp_config_found"
  log_info "Ownership & permission '$app' selesai diperbaiki."
  return 0
}

# ---------------------------------------------------------------------------
# tools_rebuild_config APP
#
# PRD §F-4: menulis ulang vhconf dari snapshot "last known good" + data
# registry (delegated to ols_rebuild_vhconf), lalu restart graceful. Data
# situs tidak disentuh.
# ---------------------------------------------------------------------------
tools_rebuild_config() {
  local app="$1"

  if [[ -z "$app" ]]; then
    log_error "tools_rebuild_config: nama app tidak boleh kosong."
    return 1
  fi

  if ! app_exists "$app"; then
    log_error "tools_rebuild_config: app '$app' tidak ditemukan di registry."
    return 1
  fi

  log_info "Membangun ulang konfigurasi vhost untuk '$app'..."
  log_action "tools_rebuild_config: mulai app=$app"

  if ! ols_rebuild_vhconf "$app"; then
    log_error "tools_rebuild_config: gagal membangun ulang vhconf untuk '$app'."
    log_action "tools_rebuild_config: gagal ols_rebuild_vhconf app=$app"
    return 1
  fi

  if ! ols_graceful_restart; then
    log_error "tools_rebuild_config: rebuild vhconf '$app' selesai, tapi restart graceful OLS gagal."
    log_action "tools_rebuild_config: gagal restart setelah rebuild app=$app"
    return 1
  fi

  log_action "tools_rebuild_config: selesai app=$app"
  log_info "Konfigurasi vhost '$app' berhasil dibangun ulang."
  return 0
}

# ---------------------------------------------------------------------------
# tools_clear_cache APP
#
# PRD §F-4: menghapus wp-content/cache/ dan folder LiteSpeed, lalu FLUSHDB
# hanya pada Redis DB ID milik app tersebut (via redis_flush_app_db) — app
# lain tidak terpengaruh.
# ---------------------------------------------------------------------------
tools_clear_cache() {
  local app="$1"

  if [[ -z "$app" ]]; then
    log_error "tools_clear_cache: nama app tidak boleh kosong."
    return 1
  fi

  if ! app_exists "$app"; then
    log_error "tools_clear_cache: app '$app' tidak ditemukan di registry."
    return 1
  fi

  local docroot
  docroot="$(app_get "$app" DOCROOT)"

  if [[ -z "$docroot" ]]; then
    log_error "tools_clear_cache: DOCROOT untuk app '$app' kosong di registry."
    return 1
  fi

  if [[ ! -d "$docroot" ]]; then
    log_error "tools_clear_cache: direktori DOCROOT '$docroot' untuk app '$app' tidak ditemukan."
    return 1
  fi

  local cache_dir="$docroot/wp-content/cache"
  local litespeed_dir="$docroot/wp-content/litespeed"
  local had_error=0

  log_info "Membersihkan cache file untuk '$app'..."
  log_action "tools_clear_cache: mulai app=$app cache_dir=$cache_dir litespeed_dir=$litespeed_dir"

  if [[ -d "$cache_dir" ]]; then
    if rm -rf -- "$cache_dir"; then
      log_action "tools_clear_cache: dihapus app=$app path=$cache_dir"
    else
      log_error "tools_clear_cache: gagal menghapus '$cache_dir'."
      log_action "tools_clear_cache: gagal hapus app=$app path=$cache_dir"
      had_error=1
    fi
  fi

  if [[ -d "$litespeed_dir" ]]; then
    if rm -rf -- "$litespeed_dir"; then
      log_action "tools_clear_cache: dihapus app=$app path=$litespeed_dir"
    else
      log_error "tools_clear_cache: gagal menghapus '$litespeed_dir'."
      log_action "tools_clear_cache: gagal hapus app=$app path=$litespeed_dir"
      had_error=1
    fi
  fi

  log_info "Mem-flush Redis DB milik '$app'..."

  if redis_flush_app_db "$app"; then
    log_action "tools_clear_cache: redis flush ok app=$app"
  else
    log_error "tools_clear_cache: gagal FLUSHDB Redis untuk '$app'."
    log_action "tools_clear_cache: redis flush gagal app=$app"
    had_error=1
  fi

  if [[ "$had_error" -eq 0 ]]; then
    log_action "tools_clear_cache: selesai app=$app status=ok"
    log_info "Cache '$app' berhasil dibersihkan (file + Redis)."
    return 0
  fi

  log_action "tools_clear_cache: selesai app=$app status=partial_failure"
  log_error "tools_clear_cache: pembersihan cache '$app' selesai dengan beberapa kegagalan."
  return 1
}
