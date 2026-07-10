#!/usr/bin/env bash
#
# monitor.sh — WPM resource & service monitor (PRD §F-6a / §4.5 / §6.4).
#
# One-shot metric check + alert pass. This is NOT a daemon: it reads the
# current system metrics, compares them against the thresholds configured in
# $WPM_TELEGRAM_CONF, updates the anti-spam state machine, sends any
# required Telegram notification, and exits. Cron (installed by install.sh
# into /etc/cron.d/wpm-monitor) fires this script every 60 seconds; RAM
# usage while idle between ticks is zero (§7.1/G-2).
#
# Metrics checked:
#   LOAD    — 5-minute load average (§F-6a table) vs. nproc * TH_LOAD_MULT
#   RAM     — % used, derived from MemAvailable in /proc/meminfo, vs TH_RAM
#             (recovers below TH_RAM_RECOVER — hysteresis)
#   SWAP    — % used from /proc/meminfo vs TH_SWAP (recovers below
#             TH_SWAP_RECOVER — hysteresis)
#   DISK    — % used on / (via `df`) vs TH_DISK
#   OLS / MariaDB / Redis — `systemctl is-active` against a short list of
#             likely unit names per service (never hardcode a single unit
#             name that might not exist on this box), with a pgrep fallback.
#
# Anti-spam state machine (§4.5/§F-6a), per metric:
#   NORMAL --threshold crossed--> ALERT (send 🚨)
#   ALERT  --still bad, every REALERT_MIN minutes--> re-alert (send 🚨)
#   ALERT  --below the recovery threshold (hysteresis)--> RECOVERED
#           (send ✅ + incident duration) --> NORMAL
#
# State is kept in $WPM_STATE_FILE as flat STATE_<METRIC>/LAST_SENT_<METRIC>/
# SINCE_<METRIC> keys (§6.4), written atomically (temp file + mv) via
# core.sh's existing private conf-file writer — the same primitive
# app_set_all/telegram_conf_set_all already use.
#
# Delivery-failure handling (§9 risk table: "Telegram API tidak terjangkau
# -> alert tidak terkirim -> state insiden tetap tersimpan; pengiriman
# diulang pada siklus cron berikutnya"): a metric only advances its
# LAST_SENT_<METRIC> timestamp when tg_send actually succeeds. STATE_/SINCE_
# always reflect the real, observed condition regardless of delivery
# success, so a failed send is retried on the very next 60-second tick
# instead of waiting a full REALERT_MIN interval.
#
# AUTO_RESTART (§F-6a, default off): when a monitored service is newly
# detected as down (NORMAL -> ALERT transition only, not on every re-alert,
# to avoid a restart-loop against a genuinely broken service), attempts
# `systemctl restart` on whichever unit name was actually detected.
#
# Sources core.sh + telegram.sh only. Must be run as root (reads
# root-owned 600 config, and may issue `systemctl restart`).

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve our own directory so lib/core.sh + lib/telegram.sh are found
# whether this script is run from the repo checkout or from its installed
# location ($WPM_HOME/monitor.sh with $WPM_HOME/lib/ as a sibling) — the same
# self-locating approach telegram.sh itself uses, so we don't depend on
# $WPM_HOME being exported in the cron environment.
# ---------------------------------------------------------------------------

_WPM_MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [[ ! -f "$_WPM_MONITOR_DIR/lib/core.sh" ]]; then
  echo "monitor.sh: tidak menemukan lib/core.sh di ${_WPM_MONITOR_DIR}/lib — instalasi rusak?" >&2
  exit 1
fi

# shellcheck source=./lib/core.sh
source "$_WPM_MONITOR_DIR/lib/core.sh"
# shellcheck source=./lib/telegram.sh
source "$_WPM_MONITOR_DIR/lib/telegram.sh"

unset _WPM_MONITOR_DIR

require_root

# ---------------------------------------------------------------------------
# Service unit candidates (§ contract: "try a short list of likely unit
# names per service rather than hardcoding one that might not exist").
# Kept identical to the candidate lists telegram.sh's tg_format_stats uses,
# so /stats and the alert monitor always agree on what "OLS"/"MariaDB"/
# "Redis" means on this box.
# ---------------------------------------------------------------------------

MON_OLS_UNITS=(lsws openlitespeed litespeed)
MON_DB_UNITS=(mariadb mysql mysqld)
MON_REDIS_UNITS=(redis-server redis)

# Metric keys tracked in $WPM_STATE_FILE (used as STATE_<key>/LAST_SENT_<key>/
# SINCE_<key>). Resource metrics are already uppercase; service metrics use
# the uppercased form of the display name passed to tg_format_alert/
# tg_format_recovered (e.g. display "MariaDB" -> state key "MARIADB").
MON_METRICS=(LOAD RAM SWAP DISK OLS MARIADB REDIS)

# In-memory mirror of the state file, keyed "STATE_<M>" / "LAST_SENT_<M>" /
# "SINCE_<M>". Populated by _mon_load_state, persisted by _mon_save_state.
declare -A ST=()

# ---------------------------------------------------------------------------
# Small numeric helpers (bash has no float arithmetic; delegate to awk,
# forcing the C locale so a decimal point is never read/printed as a
# locale-dependent comma — same convention telegram.sh uses throughout).
# ---------------------------------------------------------------------------

# _mon_ge VALUE THRESH — 0 (true) if VALUE >= THRESH numerically.
_mon_ge() {
  LC_ALL=C awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ exit ((a+0) >= (b+0)) ? 0 : 1 }'
}

# _mon_lt VALUE THRESH — 0 (true) if VALUE < THRESH numerically.
_mon_lt() {
  LC_ALL=C awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ exit ((a+0) < (b+0)) ? 0 : 1 }'
}

# _mon_duration_text SINCE_EPOCH NOW_EPOCH — echoes an Indonesian duration
# string matching §F-6a's "Durasi insiden: 14 menit" style: "D hari H jam" /
# "H jam M menit" / "M menit" (mirrors telegram.sh's _tg_uptime_human style).
_mon_duration_text() {
  local since="${1:-0}" now="${2:-0}" secs d h m
  if [[ -z "$since" || "$since" == "0" ]]; then
    printf 'tidak diketahui\n'
    return 0
  fi
  secs=$(( now - since ))
  (( secs < 0 )) && secs=0
  d=$(( secs / 86400 ))
  h=$(( (secs % 86400) / 3600 ))
  m=$(( (secs % 3600) / 60 ))
  if (( d > 0 )); then
    printf '%d hari %d jam\n' "$d" "$h"
  elif (( h > 0 )); then
    printf '%d jam %d menit\n' "$h" "$m"
  else
    (( m < 1 )) && m=1
    printf '%d menit\n' "$m"
  fi
}

# ---------------------------------------------------------------------------
# State file I/O — reuses core.sh's private atomic flat-file helpers
# (_wpm_conf_get_file / _wpm_conf_write_file), the exact same primitives
# app_set_all and telegram_conf_set_all are built on, so $WPM_STATE_FILE is
# written "temp file + mv" just like every other WPM config file (§6.4).
# ---------------------------------------------------------------------------

# _mon_load_state — populates the ST[] associative array with every
# metric's STATE_/LAST_SENT_/SINCE_ keys, defaulting absent ones to a fresh
# "ok" incident-free state. Must run before any _mon_process_* call.
_mon_load_state() {
  local m
  for m in "${MON_METRICS[@]}"; do
    ST["STATE_${m}"]="$(_wpm_conf_get_file "$WPM_STATE_FILE" "STATE_${m}")"
    [[ -z "${ST[STATE_${m}]}" ]] && ST["STATE_${m}"]="ok"
    ST["LAST_SENT_${m}"]="$(_wpm_conf_get_file "$WPM_STATE_FILE" "LAST_SENT_${m}")"
    [[ -z "${ST[LAST_SENT_${m}]}" ]] && ST["LAST_SENT_${m}"]="0"
    ST["SINCE_${m}"]="$(_wpm_conf_get_file "$WPM_STATE_FILE" "SINCE_${m}")"
    [[ -z "${ST[SINCE_${m}]}" ]] && ST["SINCE_${m}"]="0"
  done
}

# _mon_save_state — writes the full ST[] snapshot back to $WPM_STATE_FILE in
# one atomic pass (single temp-file + mv for the whole run, not per-metric).
_mon_save_state() {
  local -a kv=()
  local m
  for m in "${MON_METRICS[@]}"; do
    kv+=("STATE_${m}=${ST[STATE_${m}]}")
    kv+=("LAST_SENT_${m}=${ST[LAST_SENT_${m}]}")
    kv+=("SINCE_${m}=${ST[SINCE_${m}]}")
  done
  mkdir -p "$WPM_VAR" 2>/dev/null
  _wpm_conf_write_file "$WPM_STATE_FILE" 600 "${kv[@]}"
}

# ---------------------------------------------------------------------------
# Concurrency guard — a dedicated lock (NOT the shared $WPM_LOCK_FILE the
# `wpm` CLI uses for config-mutating menu paths, which can legitimately stay
# held for minutes during a clone; monitor.sh must never block on that). If
# a previous monitor.sh invocation is still in flight (e.g. a slow Telegram
# API call), skip this tick entirely rather than overlap.
# ---------------------------------------------------------------------------

_mon_acquire_lock() {
  local lock_file="$WPM_VAR/monitor.lock"
  mkdir -p "$WPM_VAR" 2>/dev/null
  if ! exec 8>"$lock_file" 2>/dev/null; then
    log_warn "monitor: tidak dapat membuka lock file ${lock_file}; melanjutkan tanpa lock."
    return 0
  fi
  if ! flock -n 8; then
    log_action "monitor: instance monitor.sh sebelumnya masih berjalan — lewati siklus ini."
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Service detection — mirrors telegram.sh's _tg_service_glyph logic (reuses
# its _tg_detect_unit helper) but returns a plain boolean instead of a
# glyph, since monitor.sh needs the raw active/inactive fact to drive the
# state machine.
# ---------------------------------------------------------------------------

# _mon_service_active CANDIDATE... — 0 (true) if any candidate resolves to
# an installed systemd unit that is active, or (systemd unavailable / no
# matching unit file) a running process of that name is found via pgrep.
_mon_service_active() {
  local unit cand
  unit="$(_tg_detect_unit "$@")"
  if [[ -n "$unit" ]]; then
    systemctl is-active --quiet "$unit" 2>/dev/null
    return $?
  fi
  for cand in "$@"; do
    if pgrep -x "$cand" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# _mon_try_auto_restart METRIC CANDIDATE... — best-effort `systemctl
# restart` on whichever CANDIDATE resolves to an installed unit. Never
# fatal: logs and returns non-zero on any failure to detect/restart.
_mon_try_auto_restart() {
  local metric="$1"
  shift
  local unit
  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "monitor: AUTO_RESTART aktif tapi systemctl tidak tersedia; restart ${metric} dilewati."
    return 1
  fi
  unit="$(_tg_detect_unit "$@")"
  if [[ -z "$unit" ]]; then
    log_warn "monitor: AUTO_RESTART aktif tapi unit systemd untuk layanan ${metric} tidak terdeteksi; restart dilewati."
    return 1
  fi
  log_action "monitor: AUTO_RESTART — menjalankan 'systemctl restart ${unit}' untuk layanan ${metric} yang down."
  if systemctl restart "$unit" 2>/dev/null; then
    log_action "monitor: AUTO_RESTART berhasil me-restart '${unit}' (${metric})."
    return 0
  fi
  log_warn "monitor: AUTO_RESTART gagal me-restart '${unit}' (${metric})."
  return 1
}

# ---------------------------------------------------------------------------
# The state machine itself (§4.5/§F-6a), one implementation shared by all
# four numeric resource metrics; services use the dedicated variant below
# since their "value" is a boolean, not a threshold-comparable number.
# ---------------------------------------------------------------------------

# _mon_process_metric METRIC VALUE ALERT_THRESH RECOVER_THRESH VALUE_TEXT
#   METRIC         — display name AND state-key source (RAM/SWAP/LOAD/DISK).
#   VALUE          — current numeric reading (compared against thresholds).
#   ALERT_THRESH   — crossing this (VALUE >= ALERT_THRESH) while ok enters
#                    ALERT.
#   RECOVER_THRESH — dropping below this (VALUE < RECOVER_THRESH) while in
#                    ALERT sends RECOVERED. Equal to ALERT_THRESH for
#                    metrics with no configured hysteresis (LOAD/DISK — §6.3
#                    defines no TH_LOAD_RECOVER/TH_DISK_RECOVER key).
#   VALUE_TEXT     — the exact, already-formatted reading to hand to
#                    tg_format_alert so the number the admin sees always
#                    matches the number that triggered the alert.
_mon_process_metric() {
  local metric="$1" value="$2" alert_thresh="$3" recover_thresh="$4" value_text="$5"
  local key now st last since body duration
  key="${metric^^}"
  now="$(date +%s)"
  st="${ST[STATE_${key}]:-ok}"
  last="${ST[LAST_SENT_${key}]:-0}"
  since="${ST[SINCE_${key}]:-0}"

  if [[ "$st" == "alert" ]]; then
    if _mon_lt "$value" "$recover_thresh"; then
      duration="$(_mon_duration_text "$since" "$now")"
      body="$(tg_format_recovered "$metric" "$duration")"
      if tg_send "$body"; then
        log_action "monitor: ${metric} RECOVERED (durasi insiden ${duration})."
        ST["STATE_${key}"]="ok"
        ST["SINCE_${key}"]="0"
        ST["LAST_SENT_${key}"]="0"
      else
        log_warn "monitor: gagal mengirim notifikasi RECOVERED untuk ${metric}; akan dicoba lagi siklus berikutnya."
      fi
    else
      if (( now - last >= REALERT_SECS )); then
        body="$(tg_format_alert "$metric" "$value_text")"
        if tg_send "$body"; then
          log_action "monitor: re-alert ${metric} (nilai ${value_text})."
          ST["LAST_SENT_${key}"]="$now"
        else
          log_warn "monitor: gagal mengirim re-alert ${metric}; akan dicoba lagi siklus berikutnya."
        fi
      fi
    fi
  else
    if _mon_ge "$value" "$alert_thresh"; then
      ST["STATE_${key}"]="alert"
      ST["SINCE_${key}"]="$now"
      body="$(tg_format_alert "$metric" "$value_text")"
      if tg_send "$body"; then
        log_action "monitor: ALERT ${metric} melewati ambang (nilai ${value_text})."
        ST["LAST_SENT_${key}"]="$now"
      else
        log_warn "monitor: gagal mengirim ALERT ${metric}; akan dicoba lagi siklus berikutnya."
        ST["LAST_SENT_${key}"]="0"
      fi
    fi
  fi
}

# _mon_process_service METRIC ACTIVE CANDIDATE... — same crossing/re-alert/
# recovery machine as _mon_process_metric, specialised for a boolean
# service-up/down fact instead of a threshold-comparable number. ACTIVE is
# 1 (up) or 0 (down). CANDIDATE... is forwarded to AUTO_RESTART so it can
# retry via `systemctl restart` against whichever unit is actually installed.
_mon_process_service() {
  local metric="$1" active="$2"
  shift 2
  local -a candidates=("$@")
  local key now st last since body duration

  key="${metric^^}"
  now="$(date +%s)"
  st="${ST[STATE_${key}]:-ok}"
  last="${ST[LAST_SENT_${key}]:-0}"
  since="${ST[SINCE_${key}]:-0}"

  if [[ "$st" == "alert" ]]; then
    if (( active == 1 )); then
      duration="$(_mon_duration_text "$since" "$now")"
      body="$(tg_format_recovered "$metric" "$duration")"
      if tg_send "$body"; then
        log_action "monitor: layanan ${metric} RECOVERED (durasi insiden ${duration})."
        ST["STATE_${key}"]="ok"
        ST["SINCE_${key}"]="0"
        ST["LAST_SENT_${key}"]="0"
      else
        log_warn "monitor: gagal mengirim notifikasi RECOVERED untuk layanan ${metric}; akan dicoba lagi siklus berikutnya."
      fi
    else
      if (( now - last >= REALERT_SECS )); then
        body="$(tg_format_alert "$metric" "tidak aktif")"
        if tg_send "$body"; then
          log_action "monitor: re-alert layanan ${metric} masih down."
          ST["LAST_SENT_${key}"]="$now"
        else
          log_warn "monitor: gagal mengirim re-alert layanan ${metric}; akan dicoba lagi siklus berikutnya."
        fi
      fi
    fi
  else
    if (( active == 0 )); then
      ST["STATE_${key}"]="alert"
      ST["SINCE_${key}"]="$now"

      if [[ "$AUTO_RESTART" == "1" ]]; then
        _mon_try_auto_restart "$metric" "${candidates[@]}"
      fi

      body="$(tg_format_alert "$metric" "tidak aktif")"
      if tg_send "$body"; then
        log_action "monitor: ALERT layanan ${metric} down."
        ST["LAST_SENT_${key}"]="$now"
      else
        log_warn "monitor: gagal mengirim ALERT layanan ${metric}; akan dicoba lagi siklus berikutnya."
        ST["LAST_SENT_${key}"]="0"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main — a single check+alert pass. No loop: cron re-invokes the whole
# script every 60 seconds (§F-6a).
# ---------------------------------------------------------------------------

main() {
  _mon_acquire_lock

  local alerts_enabled bot_token chat_id
  alerts_enabled="$(telegram_conf_get ALERTS_ENABLED)"
  if [[ "$alerts_enabled" != "1" ]]; then
    log_action "monitor: ALERTS_ENABLED=${alerts_enabled} — alert monitor dimatikan, lewati siklus."
    return 0
  fi

  bot_token="$(telegram_conf_get BOT_TOKEN)"
  chat_id="$(telegram_conf_get CHAT_ID)"
  if [[ -z "$bot_token" || -z "$chat_id" ]]; then
    log_action "monitor: Telegram belum dikonfigurasi (BOT_TOKEN/CHAT_ID kosong) — lewati siklus."
    return 0
  fi

  # Thresholds/config for this run (globals — read by the _mon_process_*
  # helpers above).
  TH_LOAD_MULT="$(telegram_conf_get TH_LOAD_MULT)"
  TH_RAM="$(telegram_conf_get TH_RAM)"
  TH_RAM_RECOVER="$(telegram_conf_get TH_RAM_RECOVER)"
  TH_SWAP="$(telegram_conf_get TH_SWAP)"
  TH_SWAP_RECOVER="$(telegram_conf_get TH_SWAP_RECOVER)"
  TH_DISK="$(telegram_conf_get TH_DISK)"

  REALERT_MIN="$(telegram_conf_get REALERT_MIN)"
  [[ "$REALERT_MIN" =~ ^[0-9]+$ ]] || REALERT_MIN=30
  REALERT_SECS=$(( REALERT_MIN * 60 ))

  AUTO_RESTART="$(telegram_conf_get AUTO_RESTART)"
  [[ "$AUTO_RESTART" == "1" ]] || AUTO_RESTART="0"

  _mon_load_state

  # --- LOAD (5-minute average, §F-6a: > nproc * TH_LOAD_MULT) -------------
  local load1 load5 load15 nproc_n load_threshold
  read -r load1 load5 load15 < <(_tg_load_avg)
  nproc_n="$(_tg_nproc)"
  load_threshold="$(LC_ALL=C awk -v n="$nproc_n" -v m="$TH_LOAD_MULT" 'BEGIN{printf "%.4f", (n+0)*(m+0)}')"
  # No TH_LOAD_RECOVER is defined in §6.3 — recovers as soon as it drops
  # back under the same threshold (alert_thresh == recover_thresh).
  _mon_process_metric "LOAD" "$load5" "$load_threshold" "$load_threshold" "$load5"

  # --- RAM (MemAvailable-derived %, hysteresis via TH_RAM_RECOVER) -------
  local ram_used_mb ram_total_mb ram_pct ram_value_text
  read -r ram_used_mb ram_total_mb ram_pct < <(_tg_ram_stats)
  ram_value_text="$(printf '%s%% (%s/%s MB)' "$ram_pct" "$ram_used_mb" "$ram_total_mb")"
  _mon_process_metric "RAM" "$ram_pct" "$TH_RAM" "$TH_RAM_RECOVER" "$ram_value_text"

  # --- SWAP (%, hysteresis via TH_SWAP_RECOVER) ---------------------------
  local swap_used_kb swap_total_kb swap_pct
  read -r swap_used_kb swap_total_kb swap_pct < <(_tg_swap_stats)
  _mon_process_metric "SWAP" "$swap_pct" "$TH_SWAP" "$TH_SWAP_RECOVER" "${swap_pct}%"

  # --- DISK (df /, no configured hysteresis) ------------------------------
  local disk_used_kb disk_total_kb disk_pct
  read -r disk_used_kb disk_total_kb disk_pct < <(_tg_disk_stats)
  _mon_process_metric "DISK" "$disk_pct" "$TH_DISK" "$TH_DISK" "${disk_pct}%"

  # --- Services: OLS / MariaDB / Redis (systemctl is-active, unit-name
  #     candidates detected rather than hardcoded; pgrep fallback) --------
  local ols_active=0 db_active=0 redis_active=0
  _mon_service_active "${MON_OLS_UNITS[@]}" && ols_active=1
  _mon_service_active "${MON_DB_UNITS[@]}" && db_active=1
  _mon_service_active "${MON_REDIS_UNITS[@]}" && redis_active=1

  _mon_process_service "OLS" "$ols_active" "${MON_OLS_UNITS[@]}"
  _mon_process_service "MariaDB" "$db_active" "${MON_DB_UNITS[@]}"
  _mon_process_service "Redis" "$redis_active" "${MON_REDIS_UNITS[@]}"

  _mon_save_state
  return 0
}

main
exit $?
