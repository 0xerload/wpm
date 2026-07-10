#!/usr/bin/env bash
#
# lib/telegram.sh — Telegram integration for WPM.
#
# Implements PRD §F-6 (Telegram & Monitoring): the low-level Bot API
# transport (sendMessage / getUpdates), the telegram.conf reader/writer
# (§6.3), MarkdownV2 escaping, message formatters for /stats, alert and
# recovery notifications (§F-6a/§F-6b, exact layouts), and the interactive
# setup wizard (§F-6c).
#
# Consumers: monitor.sh (cron alert checker) and bot.sh (long-poll
# interactive bot) both source this file for every Telegram interaction —
# neither talks to the Bot API directly.
#
# Security (NFR-04 / §7.3): BOT_TOKEN is never written to stdout or to
# $WPM_LOG_FILE in the clear. Every log line that could contain it passes
# the value through mask_secret first; every function that could echo curl
# error text redirects stderr away from the log/console instead of letting
# it leak a token-bearing URL.
#
# This file is a lib — it must be *sourced*, never executed directly, and
# must never `set -e`/`set -u` globally (that would leak into the sourcing
# shell). Each public function below does its own defensive error checking.

[[ -n "${WPM_LIB_TELEGRAM_LOADED:-}" ]] && return
readonly WPM_LIB_TELEGRAM_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/telegram.sh harus di-source, bukan dieksekusi langsung." >&2
  exit 1
fi

# Resolve this file's directory so dependent libs load correctly regardless
# of whether WPM is running from the repo checkout or from its installed
# location ($WPM_HOME). core.sh's own include-guard makes re-sourcing
# harmless if the caller already loaded it.
_WPM_TELEGRAM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./core.sh
source "$_WPM_TELEGRAM_LIB_DIR/core.sh"

unset _WPM_TELEGRAM_LIB_DIR

# ============================================================================
# telegram.conf I/O — /etc/wpm/telegram.conf (mode 600), per PRD §6.3.
# Mirrors app_get/app_set_all's "safe reader / atomic overwrite" pattern,
# reusing core.sh's private flat-file helpers (_wpm_conf_get_file /
# _wpm_conf_write_file) rather than ever `source`-ing the conf file.
# ============================================================================

# telegram_conf_get KEY — echoes the value of KEY in $WPM_TELEGRAM_CONF.
# Falls back to the §6.3 documented default for keys that have one; BOT_TOKEN
# and CHAT_ID have no default and echo empty when unset.
telegram_conf_get() {
  local key="$1"
  local val
  val="$(_wpm_conf_get_file "$WPM_TELEGRAM_CONF" "$key")"

  if [[ -z "$val" ]]; then
    case "$key" in
      ALERTS_ENABLED)   val="1" ;;
      TH_LOAD_MULT)     val="2.0" ;;
      TH_RAM)           val="90" ;;
      TH_RAM_RECOVER)   val="78" ;;
      TH_SWAP)          val="60" ;;
      TH_SWAP_RECOVER)  val="45" ;;
      TH_DISK)          val="85" ;;
      REALERT_MIN)      val="30" ;;
      AUTO_RESTART)     val="0" ;;
      LABEL)
        val="$(hostname -s 2>/dev/null)"
        [[ -z "$val" ]] && val="$(hostname 2>/dev/null)"
        [[ -z "$val" ]] && val="wpm-server"
        ;;
      *) : ;; # BOT_TOKEN / CHAT_ID — no default, empty means "not configured".
    esac
  fi

  printf '%s\n' "$val"
}

# telegram_conf_set_all key1=val1 key2=val2 ... — atomically overwrites the
# whole telegram.conf with exactly the given keys (mode 600). Like
# app_set_all, this does NOT merge with the existing file — callers editing
# a single field (e.g. the threshold editor in menu 6) must read the current
# full set with telegram_conf_get first and pass all of it back.
#
# This is the single choke point through which BOT_TOKEN is ever persisted,
# so the audit-trail log line masks it unconditionally (NFR-04) regardless
# of which caller invoked this function.
telegram_conf_set_all() {
  mkdir -p "$WPM_ETC" 2>/dev/null
  chmod 700 "$WPM_ETC" 2>/dev/null

  _wpm_conf_write_file "$WPM_TELEGRAM_CONF" 600 "$@"

  if [[ ! -f "$WPM_TELEGRAM_CONF" ]]; then
    log_error "telegram_conf_set_all: gagal menulis $WPM_TELEGRAM_CONF"
    return 1
  fi

  local kv k v logline="telegram_conf_set_all: memperbarui ${WPM_TELEGRAM_CONF} —"
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ -z "$k" ]] && continue
    [[ "$k" == "BOT_TOKEN" ]] && v="$(mask_secret "$v")"
    logline+=" ${k}=${v}"
  done
  log_action "$logline"
  return 0
}

# ============================================================================
# MarkdownV2 escaping (Telegram Bot API spec).
# ============================================================================

# tg_escape_markdown_v2 TEXT — echoes TEXT with every MarkdownV2 special
# character ( _ * [ ] ( ) ~ ` > # + - = | { } . ! and backslash itself)
# escaped with a preceding backslash, safe to embed as `text` in a
# sendMessage call using parse_mode=MarkdownV2. Backslash is escaped FIRST
# so none of the backslashes this function inserts for the other characters
# get double-escaped by a later rule.
tg_escape_markdown_v2() {
  local text="${1:-}"
  printf '%s' "$text" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/_/\\_/g' \
    -e 's/\*/\\*/g' \
    -e 's/\[/\\[/g' \
    -e 's/]/\\]/g' \
    -e 's/(/\\(/g' \
    -e 's/)/\\)/g' \
    -e 's/~/\\~/g' \
    -e 's/`/\\`/g' \
    -e 's/>/\\>/g' \
    -e 's/#/\\#/g' \
    -e 's/+/\\+/g' \
    -e 's/-/\\-/g' \
    -e 's/=/\\=/g' \
    -e 's/|/\\|/g' \
    -e 's/{/\\{/g' \
    -e 's/}/\\}/g' \
    -e 's/\./\\./g' \
    -e 's/!/\\!/g'
}

# ============================================================================
# Private — raw Bot API transport. Public tg_send/tg_get_updates read
# BOT_TOKEN/CHAT_ID from telegram.conf and delegate here; tg_setup_wizard
# calls these directly with an in-memory token/chat_id BEFORE anything is
# persisted (so a cancelled wizard never leaves a half-written conf file).
# Neither helper ever prints the token: curl's own stderr is discarded so a
# transport-level error can never echo a token-bearing URL to the log.
# ============================================================================

# _tg_api_send_message TOKEN CHAT_ID TEXT — TEXT must already be
# MarkdownV2-escaped by the caller. Returns 0 on a Telegram "ok":true
# response, 1 otherwise (details logged, token never included).
_tg_api_send_message() {
  local token="$1" chat_id="$2" text="$3"
  local url="https://api.telegram.org/bot${token}/sendMessage"
  local response rc

  response="$(curl -s -m 15 -X POST "$url" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "parse_mode=MarkdownV2" \
    --data-urlencode "text=${text}" 2>/dev/null)"
  rc=$?

  if (( rc != 0 )); then
    log_error "Telegram sendMessage: curl gagal (exit ${rc})."
    return 1
  fi

  if [[ "$response" != *'"ok":true'* ]]; then
    local desc=""
    if command -v jq >/dev/null 2>&1; then
      desc="$(printf '%s' "$response" | jq -r '.description // empty' 2>/dev/null)"
    fi
    if [[ -n "$desc" ]]; then
      log_error "Telegram sendMessage ditolak API: ${desc}"
    else
      log_error "Telegram sendMessage ditolak API (respons tidak dikenali)."
    fi
    return 1
  fi

  return 0
}

# _tg_api_get_updates TOKEN OFFSET — long-polls getUpdates (timeout=30s
# server-side); OFFSET may be empty to omit the parameter entirely (used by
# the setup wizard's first, offset-less poll). Echoes the raw JSON body.
_tg_api_get_updates() {
  local token="$1" offset="$2"
  local url="https://api.telegram.org/bot${token}/getUpdates"
  local args=(-s -m 40 --get "$url" --data-urlencode "timeout=30")
  [[ -n "$offset" ]] && args+=(--data-urlencode "offset=${offset}")

  local out rc
  out="$(curl "${args[@]}" 2>/dev/null)"
  rc=$?

  if (( rc != 0 )); then
    log_warn "tg_get_updates: curl gagal (exit ${rc}) saat polling getUpdates."
  fi
  printf '%s' "$out"
  return $rc
}

# ============================================================================
# Public transport wrappers.
# ============================================================================

# tg_send TEXT — escapes TEXT (MarkdownV2) and POSTs it via sendMessage to
# the configured BOT_TOKEN/CHAT_ID. Returns 0/1; never echoes the token.
tg_send() {
  local text="${1:-}"
  local token chat_id escaped

  token="$(telegram_conf_get BOT_TOKEN)"
  chat_id="$(telegram_conf_get CHAT_ID)"

  if [[ -z "$token" || -z "$chat_id" ]]; then
    log_error "tg_send: BOT_TOKEN/CHAT_ID belum dikonfigurasi — jalankan setup wizard Telegram (menu 6)."
    return 1
  fi

  require_cmd curl
  escaped="$(tg_escape_markdown_v2 "$text")"

  if _tg_api_send_message "$token" "$chat_id" "$escaped"; then
    log_action "tg_send: pesan Telegram terkirim (chat_id=${chat_id})"
    return 0
  fi

  log_error "tg_send: gagal mengirim pesan Telegram (chat_id=${chat_id})."
  return 1
}

# tg_get_updates OFFSET — long-polls getUpdates using the configured
# BOT_TOKEN; echoes raw JSON for the caller (bot.sh) to parse with jq.
tg_get_updates() {
  local offset="${1:-}"
  local token
  token="$(telegram_conf_get BOT_TOKEN)"

  if [[ -z "$token" ]]; then
    log_error "tg_get_updates: BOT_TOKEN belum dikonfigurasi."
    return 1
  fi

  require_cmd curl
  _tg_api_get_updates "$token" "$offset"
}

# ============================================================================
# Private — system metric gathering shared by tg_format_stats,
# tg_format_alert and tg_format_recovered. Kept self-contained in
# telegram.sh (rather than depending on monitor.sh) so any consumer that
# only sources core.sh + telegram.sh (e.g. bot.sh) can format a full
# snapshot on its own. All numeric formatting forces LC_ALL=C so decimal
# points are never rendered as a locale-dependent comma.
# ============================================================================

# _tg_uptime_seconds — echoes system uptime in whole seconds (0 if unknown).
_tg_uptime_seconds() {
  local up=""
  if [[ -r /proc/uptime ]]; then
    up="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)"
  fi
  [[ -z "$up" ]] && up=0
  printf '%s\n' "$up"
}

# _tg_uptime_human — echoes "D hari H jam" (matches §F-6b's example), or a
# shorter "H jam M menit" / "M menit" form once the server has been up for
# well under a day.
_tg_uptime_human() {
  local secs d h m
  secs="$(_tg_uptime_seconds)"
  d=$(( secs / 86400 ))
  h=$(( (secs % 86400) / 3600 ))
  m=$(( (secs % 3600) / 60 ))

  if (( d > 0 )); then
    printf '%d hari %d jam\n' "$d" "$h"
  elif (( h > 0 )); then
    printf '%d jam %d menit\n' "$h" "$m"
  else
    printf '%d menit\n' "$m"
  fi
}

# _tg_nproc — echoes the CPU core count (>= 1).
_tg_nproc() {
  local n=""
  if command -v nproc >/dev/null 2>&1; then
    n="$(nproc 2>/dev/null)"
  fi
  if [[ -z "$n" || "$n" -le 0 ]] 2>/dev/null; then
    n="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
  fi
  [[ -z "$n" || "$n" -le 0 ]] 2>/dev/null && n=1
  printf '%s\n' "$n"
}

# _tg_load_avg — echoes "load1 load5 load15" from /proc/loadavg.
_tg_load_avg() {
  if [[ -r /proc/loadavg ]]; then
    awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null
  else
    printf '0.00 0.00 0.00\n'
  fi
}

# _tg_load1 — echoes just the 1-minute load average.
_tg_load1() {
  _tg_load_avg | awk '{print $1}'
}

# _tg_ram_stats — echoes "used_mb total_mb pct" using MemAvailable (falls
# back to MemFree+Buffers+Cached on kernels too old to report it).
_tg_ram_stats() {
  local total_kb avail_kb used_kb used_mb total_mb pct

  total_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  avail_kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
  [[ -z "$total_kb" ]] && total_kb=0

  if [[ -z "$avail_kb" ]]; then
    local free_kb buf_kb cached_kb
    free_kb="$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null)"
    buf_kb="$(awk '/^Buffers:/{print $2}' /proc/meminfo 2>/dev/null)"
    cached_kb="$(awk '/^Cached:/{print $2}' /proc/meminfo 2>/dev/null)"
    avail_kb=$(( ${free_kb:-0} + ${buf_kb:-0} + ${cached_kb:-0} ))
  fi

  used_kb=$(( total_kb - avail_kb ))
  (( used_kb < 0 )) && used_kb=0

  pct="$(LC_ALL=C awk -v u="$used_kb" -v t="$total_kb" \
    'BEGIN{ p=(t>0)?(u*100/t):0; if(p<0)p=0; if(p>100)p=100; printf "%.0f", p }')"
  used_mb=$(( used_kb / 1024 ))
  total_mb=$(( total_kb / 1024 ))

  printf '%s %s %s\n' "$used_mb" "$total_mb" "$pct"
}

# _tg_swap_stats — echoes "used_kb total_kb pct".
_tg_swap_stats() {
  local total_kb free_kb used_kb pct

  total_kb="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  free_kb="$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null)"
  [[ -z "$total_kb" ]] && total_kb=0
  [[ -z "$free_kb" ]] && free_kb=0

  used_kb=$(( total_kb - free_kb ))
  (( used_kb < 0 )) && used_kb=0

  pct="$(LC_ALL=C awk -v u="$used_kb" -v t="$total_kb" \
    'BEGIN{ p=(t>0)?(u*100/t):0; if(p<0)p=0; if(p>100)p=100; printf "%.0f", p }')"

  printf '%s %s %s\n' "$used_kb" "$total_kb" "$pct"
}

# _tg_disk_stats — echoes "used_kb total_kb pct" for the root filesystem.
_tg_disk_stats() {
  local line total_kb used_kb pct

  line="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $2, $3, $5}')"
  total_kb="$(awk '{print $1}' <<<"$line")"
  used_kb="$(awk '{print $2}' <<<"$line")"
  pct="$(awk '{gsub("%",""); print $3}' <<<"$line")"

  [[ -z "$total_kb" ]] && total_kb=0
  [[ -z "$used_kb" ]] && used_kb=0
  [[ -z "$pct" ]] && pct=0

  printf '%s %s %s\n' "$used_kb" "$total_kb" "$pct"
}

# _tg_kb_to_mb_int KB — echoes KB converted to whole megabytes.
_tg_kb_to_mb_int() {
  LC_ALL=C awk -v kb="${1:-0}" 'BEGIN{printf "%.0f", kb/1024}'
}

# _tg_kb_to_gb_str KB — echoes KB converted to gigabytes with 1 decimal,
# trimming a trailing ".0" (e.g. 2097152 -> "2", 14889763 -> "14.2").
_tg_kb_to_gb_str() {
  local kb="${1:-0}" s
  s="$(LC_ALL=C awk -v kb="$kb" 'BEGIN{printf "%.1f", kb/1024/1024}')"
  if [[ "$s" =~ ^([0-9]+)\.0$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$s"
  fi
}

# _tg_metric_ram_full — echoes "PCT% (USED/TOTAL MB)", e.g. "62% (612/987 MB)".
_tg_metric_ram_full() {
  local used_mb total_mb pct
  read -r used_mb total_mb pct < <(_tg_ram_stats)
  printf '%s%% (%s/%s MB)\n' "$pct" "$used_mb" "$total_mb"
}

# _tg_metric_ram_pct — echoes just the RAM percentage (bare integer).
_tg_metric_ram_pct() {
  local used_mb total_mb pct
  read -r used_mb total_mb pct < <(_tg_ram_stats)
  printf '%s\n' "$pct"
}

# _tg_metric_swap_pct — echoes just the swap percentage (bare integer).
_tg_metric_swap_pct() {
  local used_kb total_kb pct
  read -r used_kb total_kb pct < <(_tg_swap_stats)
  printf '%s\n' "$pct"
}

# _tg_metric_disk_pct — echoes just the disk percentage (bare integer).
_tg_metric_disk_pct() {
  local used_kb total_kb pct
  read -r used_kb total_kb pct < <(_tg_disk_stats)
  printf '%s\n' "$pct"
}

# _tg_metric_load1 — echoes the 1-minute load average.
_tg_metric_load1() {
  _tg_load1
}

# _tg_top_procs [N=3] — echoes the top N processes by %CPU as
# "name PCT% · name2 PCT2% · ..." (or "n/a" if `ps` is unavailable / empty).
_tg_top_procs() {
  local n="${1:-3}"
  local -a parts=()
  local name cpu cpu_int

  if ! command -v ps >/dev/null 2>&1; then
    printf 'n/a\n'
    return 0
  fi

  while read -r name cpu; do
    [[ -z "$name" ]] && continue
    cpu_int="$(LC_ALL=C awk -v c="${cpu:-0}" 'BEGIN{printf "%.0f", c}')"
    parts+=("${name} ${cpu_int}%")
  done < <(ps -eo comm,pcpu --no-headers 2>/dev/null | awk '{print $1, $2}' | sort -k2,2 -rn | head -n "$n")

  if (( ${#parts[@]} == 0 )); then
    printf 'n/a\n'
    return 0
  fi

  local joined="" p first=1
  for p in "${parts[@]}"; do
    if (( first )); then
      joined="$p"
      first=0
    else
      joined="${joined} · ${p}"
    fi
  done
  printf '%s\n' "$joined"
}

# _tg_detect_unit CANDIDATE... — echoes the first candidate that exists as
# an installed systemd unit ("<candidate>.service"); empty (exit 1) if
# systemd is unavailable or none of the candidates are installed.
_tg_detect_unit() {
  local cand
  command -v systemctl >/dev/null 2>&1 || return 1
  for cand in "$@"; do
    if systemctl list-unit-files --no-legend --type=service "${cand}.service" 2>/dev/null \
         | grep -q "^${cand}\.service"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# _tg_service_glyph CANDIDATE... — echoes ✓/✗ for whichever CANDIDATE unit
# is installed and active. Falls back to a `pgrep` process-name check when
# systemd is unavailable or no matching unit file is found, so the glyph is
# never a false negative just because the unit name differs from guess.
_tg_service_glyph() {
  local unit
  unit="$(_tg_detect_unit "$@")"
  if [[ -n "$unit" ]]; then
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      printf '✓\n'
    else
      printf '✗\n'
    fi
    return 0
  fi

  local cand
  for cand in "$@"; do
    if pgrep -x "$cand" >/dev/null 2>&1; then
      printf '✓\n'
      return 0
    fi
  done
  printf '✗\n'
}

# ============================================================================
# Public — message formatters (§F-6a / §F-6b, exact layouts).
# ============================================================================

# tg_format_stats — echoes the full /stats snapshot body, exactly per the
# §F-6b example (emoji, label alignment, field order):
#
#   📊 vps-jkt1 — 09 Jul 14:02 WIB
#   ⏱ Uptime : 12 hari 4 jam
#   🔥 Load   : 0.42 / 0.38 / 0.35 (1 core)
#   🧠 RAM    : 612 / 987 MB (62%)
#   💾 Swap   : 180 MB / 2 GB (9%)
#   🗄 Disk   : 14.2 / 25 GB (57%)
#   ⚙️ OLS ✓ · MariaDB ✓ · Redis ✓
tg_format_stats() {
  local label now_str tz uptime_h
  local l1 l2 l3 nproc_n
  local ram_used_mb ram_total_mb ram_pct
  local swap_used_kb swap_total_kb swap_pct swap_used_mb swap_total_gb
  local disk_used_kb disk_total_kb disk_pct disk_used_gb disk_total_gb
  local ols_glyph db_glyph redis_glyph

  label="$(telegram_conf_get LABEL)"
  now_str="$(LC_TIME=C date '+%d %b %H:%M' 2>/dev/null)"
  tz="$(date '+%Z' 2>/dev/null)"
  uptime_h="$(_tg_uptime_human)"

  read -r l1 l2 l3 < <(_tg_load_avg)
  nproc_n="$(_tg_nproc)"

  read -r ram_used_mb ram_total_mb ram_pct < <(_tg_ram_stats)

  read -r swap_used_kb swap_total_kb swap_pct < <(_tg_swap_stats)
  swap_used_mb="$(_tg_kb_to_mb_int "$swap_used_kb")"
  swap_total_gb="$(_tg_kb_to_gb_str "$swap_total_kb")"

  read -r disk_used_kb disk_total_kb disk_pct < <(_tg_disk_stats)
  disk_used_gb="$(_tg_kb_to_gb_str "$disk_used_kb")"
  disk_total_gb="$(_tg_kb_to_gb_str "$disk_total_kb")"

  ols_glyph="$(_tg_service_glyph lsws openlitespeed litespeed)"
  db_glyph="$(_tg_service_glyph mariadb mysql mysqld)"
  redis_glyph="$(_tg_service_glyph redis-server redis)"

  printf '📊 %s — %s%s\n' "$label" "$now_str" "${tz:+ $tz}"
  printf '⏱ %-7s: %s\n' "Uptime" "$uptime_h"
  printf '🔥 %-7s: %s / %s / %s (%s core)\n' "Load" "$l1" "$l2" "$l3" "$nproc_n"
  printf '🧠 %-7s: %s / %s MB (%s%%)\n' "RAM" "$ram_used_mb" "$ram_total_mb" "$ram_pct"
  printf '💾 %-7s: %s MB / %s GB (%s%%)\n' "Swap" "$swap_used_mb" "$swap_total_gb" "$swap_pct"
  printf '🗄 %-7s: %s / %s GB (%s%%)\n' "Disk" "$disk_used_gb" "$disk_total_gb" "$disk_pct"
  printf '⚙️ OLS %s · MariaDB %s · Redis %s\n' "$ols_glyph" "$db_glyph" "$redis_glyph"
}

# tg_format_alert METRIC VALUE_TEXT — echoes an ALERT message body per the
# §F-6a example. METRIC is one of RAM/SWAP/LOAD/DISK (case-insensitive) —
# VALUE_TEXT is the exact, already-decided reading that crossed the
# threshold (monitor.sh's own computed value, so the number the admin sees
# always matches the number that triggered the alert); the OTHER three
# resource lines are filled in with a fresh live read for context, e.g.
# for METRIC=RAM:
#
#   🚨 WPM ALERT — vps-jkt1
#   RAM 93% (918/987 MB) · Swap 71%
#   Top proses: lsphp 34% · mariadbd 26% · redis 4%
#   Load: 1.8 · Disk: 61%
#
# Any other METRIC (e.g. a downed service name like OLS/MariaDB/Redis) uses
# a distinct, shorter template — §6.3's threshold table only covers the
# four resource metrics above, so no verbatim example exists for that case.
tg_format_alert() {
  local metric="${1:-}" value_text="${2:-}"
  local metric_upper="${metric^^}"
  local label
  label="$(telegram_conf_get LABEL)"

  case "$metric_upper" in
    RAM | SWAP | LOAD | DISK)
      local ram_part swap_part load_part disk_part top_procs

      if [[ "$metric_upper" == "RAM" ]]; then
        ram_part="$value_text"
      else
        ram_part="$(_tg_metric_ram_full)"
      fi

      if [[ "$metric_upper" == "SWAP" ]]; then
        swap_part="$value_text"
      else
        swap_part="$(_tg_metric_swap_pct)%"
      fi

      if [[ "$metric_upper" == "LOAD" ]]; then
        load_part="$value_text"
      else
        load_part="$(_tg_metric_load1)"
      fi

      if [[ "$metric_upper" == "DISK" ]]; then
        disk_part="$value_text"
      else
        disk_part="$(_tg_metric_disk_pct)%"
      fi

      top_procs="$(_tg_top_procs 3)"

      printf '🚨 WPM ALERT — %s\nRAM %s · Swap %s\nTop proses: %s\nLoad: %s · Disk: %s\n' \
        "$label" "$ram_part" "$swap_part" "$top_procs" "$load_part" "$disk_part"
      ;;
    *)
      printf '🚨 WPM ALERT — %s\nService %s bermasalah: %s\n' "$label" "$metric" "$value_text"
      ;;
  esac
}

# tg_format_recovered METRIC DURATION_TEXT — echoes a RECOVERED message body
# per the §F-6a example, e.g. for METRIC=RAM:
#
#   ✅ RECOVERED — vps-jkt1
#   RAM kembali normal: 64%
#   Durasi insiden: 14 menit
#
# The current (post-recovery) value is read live via the same metric
# helpers used by tg_format_alert; DURATION_TEXT is passed in verbatim
# (monitor.sh computes it from its own SINCE_<METRIC> state).
tg_format_recovered() {
  local metric="${1:-}" duration_text="${2:-}"
  local metric_upper="${metric^^}"
  local label display value line2

  label="$(telegram_conf_get LABEL)"

  case "$metric_upper" in
    RAM)  display="RAM";  value="$(_tg_metric_ram_pct)%" ;;
    SWAP) display="Swap"; value="$(_tg_metric_swap_pct)%" ;;
    LOAD) display="Load"; value="$(_tg_metric_load1)" ;;
    DISK) display="Disk"; value="$(_tg_metric_disk_pct)%" ;;
    *)    display="$metric"; value="" ;;
  esac

  if [[ -n "$value" ]]; then
    line2="${display} kembali normal: ${value}"
  else
    line2="${display} kembali aktif"
  fi

  printf '✅ RECOVERED — %s\n%s\nDurasi insiden: %s\n' "$label" "$line2" "$duration_text"
}

# ============================================================================
# Setup wizard (§F-6c).
# ============================================================================

# _tg_extract_chat_id_from_updates JSON — echoes the chat id of the most
# recent message/edited_message found in a getUpdates JSON payload (empty
# if none found). jq is a guaranteed dependency (§2.1).
_tg_extract_chat_id_from_updates() {
  local json="$1"
  require_cmd jq
  printf '%s' "$json" \
    | jq -r '[.result[]? | (.message // .edited_message // empty) | .chat.id] | last // empty' 2>/dev/null
}

# tg_setup_wizard — §F-6c: prompt for the bot token (hidden input), have the
# user /start the bot, auto-detect chat_id via getUpdates, send a test
# message, and only then persist everything with telegram_conf_set_all.
# Nothing is written to telegram.conf unless the whole flow succeeds, so a
# cancelled/failed wizard never leaves a half-configured bot behind.
tg_setup_wizard() {
  require_cmd curl
  require_cmd jq

  printf '\n%s=== Setup Telegram Bot & Alert (WPM) ===%s\n\n' "$C_BOLD" "$C_RESET"

  local existing_token
  existing_token="$(telegram_conf_get BOT_TOKEN)"
  if [[ -n "$existing_token" ]]; then
    log_warn "Konfigurasi Telegram sudah ada sebelumnya; melanjutkan akan menggantinya."
    if ! confirm "Lanjutkan setup ulang Telegram?" "default_y"; then
      log_info "Setup Telegram dibatalkan."
      return 1
    fi
  fi

  printf '%sLangkah 1%s: Buat bot baru lewat @BotFather di Telegram, lalu salin token yang diberikan.\n\n' \
    "$C_BOLD" "$C_RESET"

  local token=""
  while true; do
    printf 'Masukkan Bot Token (input tersembunyi; ketik "batal" untuk keluar): ' >&2
    read -rs token
    printf '\n' >&2
    if [[ "$token" == "batal" || "$token" == "cancel" ]]; then
      log_info "Setup Telegram dibatalkan oleh pengguna."
      return 1
    fi
    [[ -n "$token" ]] && break
    log_warn "Token tidak boleh kosong."
  done
  log_info "Token diterima (${C_DIM}$(mask_secret "$token")${C_RESET})."

  printf '\n%sLangkah 2%s: Buka percakapan dengan bot Anda di Telegram, lalu kirim perintah /start.\n' \
    "$C_BOLD" "$C_RESET"
  pause_enter

  log_info "Mendeteksi chat ID (polling getUpdates)..."
  local updates chat_id="" attempt=1
  updates="$(_tg_api_get_updates "$token" "")"
  chat_id="$(_tg_extract_chat_id_from_updates "$updates")"

  while [[ -z "$chat_id" && "$attempt" -le 3 ]]; do
    log_warn "Chat ID belum terdeteksi. Pastikan sudah mengirim /start ke bot. Mencoba lagi (${attempt}/3)..."
    sleep 2
    updates="$(_tg_api_get_updates "$token" "")"
    chat_id="$(_tg_extract_chat_id_from_updates "$updates")"
    ((attempt++))
  done

  if [[ -z "$chat_id" ]]; then
    log_error "Gagal mendeteksi chat ID secara otomatis. Pastikan token benar dan Anda sudah kirim /start ke bot, lalu ulangi wizard ini."
    return 1
  fi
  log_info "Chat ID terdeteksi: ${chat_id}"

  log_info "Mengirim pesan tes..."
  local test_msg
  test_msg="$(tg_escape_markdown_v2 "✅ WPM berhasil terhubung ke bot Telegram ini.")"
  if ! _tg_api_send_message "$token" "$chat_id" "$test_msg"; then
    log_error "Gagal mengirim pesan tes. Periksa kembali token bot Anda, lalu ulangi wizard ini."
    return 1
  fi

  telegram_conf_set_all \
    BOT_TOKEN="$token" \
    CHAT_ID="$chat_id" \
    ALERTS_ENABLED="$(telegram_conf_get ALERTS_ENABLED)" \
    TH_LOAD_MULT="$(telegram_conf_get TH_LOAD_MULT)" \
    TH_RAM="$(telegram_conf_get TH_RAM)" \
    TH_RAM_RECOVER="$(telegram_conf_get TH_RAM_RECOVER)" \
    TH_SWAP="$(telegram_conf_get TH_SWAP)" \
    TH_SWAP_RECOVER="$(telegram_conf_get TH_SWAP_RECOVER)" \
    TH_DISK="$(telegram_conf_get TH_DISK)" \
    REALERT_MIN="$(telegram_conf_get REALERT_MIN)" \
    AUTO_RESTART="$(telegram_conf_get AUTO_RESTART)" \
    LABEL="$(telegram_conf_get LABEL)"

  log_info "Setup Telegram selesai. Notifikasi & bot interaktif siap digunakan (token: $(mask_secret "$token"))."
  return 0
}
