#!/usr/bin/env bash
#
# bot.sh — WPM interactive Telegram bot (§F-6b, §4.6, §7.5).
#
# Optional long-poll listener, installed by install.sh as the
# /etc/systemd/system/wpm-bot.service unit (enabled/disabled from the
# "Telegram & Monitoring" menu in `wpm`). Completely independent of the cron
# alert checker (monitor.sh) — this process can be stopped at any time
# without affecting alerting.
#
# Behaviour (per contract):
#   - Long-polls Bot API getUpdates via lib/telegram.sh's tg_get_updates,
#     with an offset persisted at $WPM_VAR/bot.offset so restarts never
#     replay already-seen updates.
#   - Any update whose chat_id does not match the whitelisted CHAT_ID
#     (telegram.conf) is dropped silently — no reply of any kind (NFR-04).
#   - Routes /uptime /stats /apps /status /help to small formatter
#     functions; reuses tg_format_stats verbatim for /stats.
#   - Strictly READ-ONLY in v1 (§7.5) — there is no code path here that
#     mutates OLS config, the registry, the database, or Redis. It only
#     reads metrics/registry and calls tg_send.
#   - On any curl/API error, backs off with increasing sleep instead of
#     busy-looping (NFR-02: idle bot must stay near-zero CPU).
#
# This file is an executable entry point (not a lib) — sourced libs only.
set -uo pipefail

# -----------------------------------------------------------------------
# Resolve our own directory so `lib/` is found whether we're running from
# the installed location ($WPM_HOME/bot.sh) or straight out of a repo
# checkout — same resolution pattern lib/telegram.sh uses for lib/core.sh.
# -----------------------------------------------------------------------
_BOT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# shellcheck source=lib/core.sh
source "$_BOT_SCRIPT_DIR/lib/core.sh"
# shellcheck source=lib/telegram.sh
source "$_BOT_SCRIPT_DIR/lib/telegram.sh"

unset _BOT_SCRIPT_DIR

require_root
require_cmd curl
require_cmd jq

# -----------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------

readonly _BOT_OFFSET_FILE="$WPM_VAR/bot.offset"
readonly _BOT_LOCK_FILE="$WPM_VAR/bot.lock"
readonly _BOT_BACKOFF_INIT=5
readonly _BOT_BACKOFF_MAX=60

# Signal-driven stop flag — checked at the top of every loop iteration.
# Under systemd's default KillMode=control-group, SIGTERM also reaches the
# curl child of an in-flight tg_get_updates call, so a blocking long-poll
# does not meaningfully delay shutdown.
_BOT_STOP=0
_bot_on_term() {
  _BOT_STOP=1
}
trap _bot_on_term TERM INT

# -----------------------------------------------------------------------
# Single-instance guard. Deliberately a lock file OF ITS OWN — not the
# global $WPM_LOCK_FILE that `wpm` uses for state-mutating menu actions.
# Sharing that lock would let a running bot starve every config-mutating
# `wpm` invocation for as long as the bot is up.
# -----------------------------------------------------------------------
_bot_acquire_instance_lock() {
  mkdir -p "$WPM_VAR" 2>/dev/null
  # shellcheck disable=SC2093
  exec 8>"$_BOT_LOCK_FILE" || die "Tidak dapat membuka lock file bot: $_BOT_LOCK_FILE"
  if ! flock -n 8; then
    die "bot.sh sudah berjalan (lock: $_BOT_LOCK_FILE). Hentikan instance lain terlebih dahulu."
  fi
}

# -----------------------------------------------------------------------
# Offset persistence — $WPM_VAR/bot.offset. Holds the NEXT offset to
# request (i.e. highest processed update_id + 1), written atomically
# (temp file + mv) so a crash mid-write never corrupts it.
# -----------------------------------------------------------------------

_bot_read_offset() {
  local f="$_BOT_OFFSET_FILE" raw=""
  if [[ -f "$f" ]]; then
    raw="$(<"$f")"
    raw="${raw//[^0-9]/}"
  fi
  printf '%s\n' "$raw"
}

_bot_save_offset() {
  local off="$1" tmp
  mkdir -p "$WPM_VAR" 2>/dev/null
  tmp="${_BOT_OFFSET_FILE}.tmp.$$"
  printf '%s\n' "$off" >"$tmp" && mv -f "$tmp" "$_BOT_OFFSET_FILE"
}

# -----------------------------------------------------------------------
# Small read-only formatters (§F-6b). tg_format_stats (lib/telegram.sh) is
# reused verbatim for /stats; the rest are defined here since they are
# bot.sh-specific (not part of the monitor.sh alert vocabulary).
# -----------------------------------------------------------------------

# _bot_format_uptime — "/uptime": uptime + load average only.
_bot_format_uptime() {
  local uptime_h l1 l2 l3 nproc_n
  uptime_h="$(_tg_uptime_human)"
  read -r l1 l2 l3 < <(_tg_load_avg)
  nproc_n="$(_tg_nproc)"
  printf '⏱ Uptime : %s\n🔥 Load   : %s / %s / %s (%s core)\n' \
    "$uptime_h" "$l1" "$l2" "$l3" "$nproc_n"
}

# _bot_ssl_glyph STATUS — maps registry SSL_STATUS to a report glyph,
# consistent with the ✓/◐/✗ vocabulary used by the clone wizard's report
# line (§4.3): active=✓, failed=✗, none/empty=◐ (live on HTTP, pending).
_bot_ssl_glyph() {
  case "${1:-}" in
    active) printf '✓\n' ;;
    failed) printf '✗\n' ;;
    *) printf '◐\n' ;;
  esac
}

# _bot_format_apps — "/apps": list_apps + registry fields + disk usage
# (du -sh) + SSL status glyph, one line per app. Soft-capped so the
# message can never exceed Telegram's ~4096 char limit even near the
# practical ~60-app ceiling (§7.4).
_bot_format_apps() {
  local app domain vh_root ssl_status glyph size
  local -a lines=()
  local count=0
  local -i max_lines=50

  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    ((count++))
    (( count > max_lines )) && continue

    domain="$(app_get "$app" DOMAIN)"
    vh_root="$(app_get "$app" VH_ROOT)"
    ssl_status="$(app_get "$app" SSL_STATUS)"
    glyph="$(_bot_ssl_glyph "$ssl_status")"

    size="-"
    if [[ -n "$vh_root" && -d "$vh_root" ]]; then
      size="$(du -sh -- "$vh_root" 2>/dev/null | awk '{print $1}')"
      [[ -z "$size" ]] && size="-"
    fi

    lines+=("• ${app} — ${domain:-(tanpa domain)} — ${size} — SSL ${glyph}")
  done < <(list_apps)

  if (( count == 0 )); then
    printf '🌐 Belum ada web app terdaftar.\n'
    return 0
  fi

  printf '🌐 Web Apps (%s)\n\n' "$count"
  local line
  for line in "${lines[@]}"; do
    printf '%s\n' "$line"
  done
  if (( count > max_lines )); then
    printf '\n… dan %s app lainnya (jalankan perintah wpm untuk daftar lengkap).\n' "$(( count - max_lines ))"
  fi
}

# _bot_format_status — "/status": OLS / MariaDB / Redis via systemctl
# (falls back to a pgrep check inside _tg_service_glyph if no unit file
# matches — same detection helper tg_format_stats itself uses).
_bot_format_status() {
  local ols_glyph db_glyph redis_glyph
  ols_glyph="$(_tg_service_glyph lsws openlitespeed litespeed)"
  db_glyph="$(_tg_service_glyph mariadb mysql mysqld)"
  redis_glyph="$(_tg_service_glyph redis-server redis)"

  printf '⚙️ Status Layanan\n\n'
  printf 'OLS      : %s\n' "$ols_glyph"
  printf 'MariaDB  : %s\n' "$db_glyph"
  printf 'Redis    : %s\n' "$redis_glyph"
}

# _bot_format_help — "/help": command list.
_bot_format_help() {
  printf '🤖 Perintah WPM Bot\n\n'
  printf '/uptime — Uptime server + load average\n'
  printf '/stats  — Snapshot lengkap: uptime, load, RAM, swap, disk, service\n'
  printf '/apps   — Daftar web app + ukuran disk + status SSL\n'
  printf '/status — Status service OLS / MariaDB / Redis\n'
  printf '/help   — Daftar perintah ini\n\n'
  printf 'Bot ini bersifat read-only — tidak ada perintah aksi di v1.\n'
}

# _bot_format_unknown CMD — anything not in the whitelist above.
_bot_format_unknown() {
  local cmd_str="${1:-}"
  printf 'Perintah tidak dikenal: %s\n\nKetik /help untuk daftar perintah.\n' "$cmd_str"
}

# -----------------------------------------------------------------------
# Command routing
# -----------------------------------------------------------------------

# _bot_normalize_command TEXT — first whitespace token, with any
# "@BotUsername" mention suffix (group-chat convention) stripped, e.g.
# "/stats@my_wpm_bot extra args" -> "/stats".
_bot_normalize_command() {
  local text="$1" cmd_str
  cmd_str="${text%%[[:space:]]*}"
  cmd_str="${cmd_str%%@*}"
  printf '%s\n' "${cmd_str,,}"
}

# _bot_handle_message TEXT — routes a single whitelisted message's text to
# the matching formatter and sends the reply. Non-command text (doesn't
# start with "/") is ignored silently — v1 has no free-text interaction.
_bot_handle_message() {
  local text="$1"
  [[ "$text" == /* ]] || return 0

  local cmd_str response
  cmd_str="$(_bot_normalize_command "$text")"

  case "$cmd_str" in
    /uptime) response="$(_bot_format_uptime)" ;;
    /stats) response="$(tg_format_stats)" ;;
    /apps) response="$(_bot_format_apps)" ;;
    /status) response="$(_bot_format_status)" ;;
    /help) response="$(_bot_format_help)" ;;
    *) response="$(_bot_format_unknown "$cmd_str")" ;;
  esac

  tg_send "$response"
  log_action "bot.sh: menjawab perintah '${cmd_str}'"
}

# -----------------------------------------------------------------------
# One getUpdates cycle: parse the JSON, drop anything not from the
# whitelisted chat_id (no reply — NFR-04/§7.3), route the rest, and
# advance the offset past EVERY update_id seen (including ones this bot
# ignores) so a non-whitelisted chat or non-message update type can never
# cause the same update_id to be redelivered forever.
# -----------------------------------------------------------------------
_bot_process_updates() {
  local json="$1"
  local configured_chat_id
  configured_chat_id="$(telegram_conf_get CHAT_ID)"

  local update_id chat_id text_b64 text last_update_id=""

  while IFS=$'\t' read -r update_id chat_id text_b64; do
    [[ -z "$update_id" ]] && continue
    last_update_id="$update_id"

    if [[ -z "$configured_chat_id" || -z "$chat_id" || "$chat_id" != "$configured_chat_id" ]]; then
      log_warn "bot.sh: mengabaikan update dari chat_id tak dikenal (update_id=${update_id})."
      continue
    fi

    text=""
    if [[ -n "$text_b64" ]]; then
      text="$(printf '%s' "$text_b64" | base64 -d 2>/dev/null)"
    fi
    [[ -z "$text" ]] && continue

    _bot_handle_message "$text"
  done < <(printf '%s' "$json" | jq -r '
      .result[]? as $u
      | ($u.message // $u.edited_message // {}) as $m
      | [$u.update_id, ($m.chat.id // ""), ($m.text // "" | @base64)]
      | @tsv
    ' 2>/dev/null)

  if [[ -n "$last_update_id" ]]; then
    _bot_save_offset "$(( last_update_id + 1 ))"
  fi
}

# -----------------------------------------------------------------------
# Main long-poll loop
# -----------------------------------------------------------------------
_bot_main() {
  _bot_acquire_instance_lock

  local token chat_id
  token="$(telegram_conf_get BOT_TOKEN)"
  chat_id="$(telegram_conf_get CHAT_ID)"
  if [[ -z "$token" || -z "$chat_id" ]]; then
    die "Telegram belum dikonfigurasi (BOT_TOKEN/CHAT_ID kosong di $WPM_TELEGRAM_CONF). Jalankan setup wizard Telegram dari menu wpm terlebih dahulu."
  fi

  log_info "bot.sh: mulai long-poll getUpdates (chat_id whitelist=${chat_id})."

  local offset json rc ok desc
  local backoff=$_BOT_BACKOFF_INIT

  while (( ! _BOT_STOP )); do
    offset="$(_bot_read_offset)"

    json="$(tg_get_updates "$offset")"
    rc=$?

    (( _BOT_STOP )) && break

    if (( rc != 0 )) || [[ -z "$json" ]]; then
      log_warn "bot.sh: getUpdates gagal/kosong, mundur ${backoff}s sebelum mencoba lagi."
      sleep "$backoff"
      backoff=$(( backoff * 2 ))
      (( backoff > _BOT_BACKOFF_MAX )) && backoff=$_BOT_BACKOFF_MAX
      continue
    fi

    ok="$(printf '%s' "$json" | jq -r '.ok // false' 2>/dev/null)"
    if [[ "$ok" != "true" ]]; then
      desc="$(printf '%s' "$json" | jq -r '.description // empty' 2>/dev/null)"
      log_warn "bot.sh: getUpdates ditolak API${desc:+ (${desc})}, mundur ${backoff}s."
      sleep "$backoff"
      backoff=$(( backoff * 2 ))
      (( backoff > _BOT_BACKOFF_MAX )) && backoff=$_BOT_BACKOFF_MAX
      continue
    fi

    backoff=$_BOT_BACKOFF_INIT
    _bot_process_updates "$json"
  done

  log_info "bot.sh: berhenti (sinyal diterima)."
  # fd 8 (our own instance lock) closes automatically on exit — nothing to
  # release explicitly. We never touch the global $WPM_LOCK_FILE (fd 9)
  # used by `wpm`'s state-mutating menu paths.
  exit 0
}

_bot_main
