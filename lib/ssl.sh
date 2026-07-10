#!/usr/bin/env bash
#
# lib/ssl.sh — Let's Encrypt SSL/TLS lifecycle for WPM.
#
# Implements PRD §F-3d (Retry SSL), §7.2 (SSL platform constraints), §9
# (risk mitigation for DNS-not-pointing / LE rate limit), and the SSL leg
# (step 8) of the F-2 clone pipeline. Responsibilities:
#   - Detect the VPS's own public IPv4 address.
#   - Verify a domain's A record actually points here BEFORE ever calling
#     certbot — this is the mandatory rate-limit-saving gate required by
#     §7.2/§9 ("cek DNS sebelum memanggil certbot (hemat kuota rate
#     limit)"; "kegagalan tidak boleh memicu retry otomatis beruntun").
#   - Issue a certificate via certbot's webroot (HTTP-01) plugin only — no
#     wildcard/DNS-01 in v1 (§7.2).
#   - Render templates/vhssl.tpl into the app's vhconf.conf as a marked,
#     idempotent block, map the SSL (:443) listener, and restart gracefully.
#   - Retry SSL for apps stuck at SSL_STATUS none/failed (§F-3d).
#
# Design rule for this whole file: NEVER `die`. Every public function here
# reports failure via return code + log_error/log_warn only. A single
# app's SSL trouble must never abort a clone queue, the Retry SSL menu, or
# the rest of `wpm` — the app stays live on HTTP and can be retried later
# (§F-2 step 8 / §F-3d / §9: "app tetap live di HTTP; menu Retry SSL").
#
# This file is a sourced library — no `set -e`/`set -u` at file scope, no
# direct execution. Every function does its own explicit error checking.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/ssl.sh harus di-source, bukan dieksekusi langsung." >&2
  exit 1
fi

[[ -n "${WPM_LIB_SSL_LOADED:-}" ]] && return
readonly WPM_LIB_SSL_LOADED=1

# --- Load dependencies (each has its own include-guard, safe to re-source) -
_WPM_SSL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./core.sh
source "$_WPM_SSL_LIB_DIR/core.sh"
# shellcheck source=./ols.sh
source "$_WPM_SSL_LIB_DIR/ols.sh"
unset _WPM_SSL_LIB_DIR

# ============================================================================
# Private helpers
# ============================================================================

# _ssl_template_path — echoes the path to templates/vhssl.tpl. Prefers the
# installed layout ($WPM_HOME/templates/vhssl.tpl per §5.3); falls back to
# the path relative to this file (../templates/vhssl.tpl) so ssl.sh also
# works when run straight out of a repo checkout where $WPM_HOME hasn't
# been pointed at that checkout. Echoes empty (and returns 1) if neither
# exists.
_ssl_template_path() {
  local candidate="${WPM_HOME}/templates/vhssl.tpl"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  local script_dir repo_candidate
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  repo_candidate="$(cd "${script_dir}/.." >/dev/null 2>&1 && pwd)/templates/vhssl.tpl"
  if [[ -f "$repo_candidate" ]]; then
    printf '%s\n' "$repo_candidate"
    return 0
  fi

  printf '\n'
  return 1
}

# _ssl_resolve_a_records DOMAIN — echoes every IPv4 A record found for
# DOMAIN, one per line (empty if none/unresolvable). Uses `getent` first
# (glibc resolver, always present on Ubuntu — no extra dependency per
# NFR-06), then falls back to dig/host/nslookup if one of those happens to
# be installed. Pure lookup helper: no logging, no side effects — its
# stdout is meant to be captured.
_ssl_resolve_a_records() {
  local domain="$1"
  local out=""

  if command -v getent >/dev/null 2>&1; then
    out="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)"
  fi

  if [[ -z "$out" ]] && command -v dig >/dev/null 2>&1; then
    out="$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$')"
  fi

  if [[ -z "$out" ]] && command -v host >/dev/null 2>&1; then
    out="$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF}')"
  fi

  if [[ -z "$out" ]] && command -v nslookup >/dev/null 2>&1; then
    out="$(nslookup -type=A "$domain" 2>/dev/null | awk '/^Address: /{print $2}')"
  fi

  printf '%s\n' "$out"
}

# _ssl_upsert_marker_block FILE TAG BLOCK_FILE — idempotently
# inserts/replaces a "# BEGIN WPM:<TAG> ... # END WPM:<TAG>" region in FILE
# with the contents of BLOCK_FILE (which must itself contain the BEGIN/END
# marker lines). Mirrors ols.sh's private _ols_upsert_marker_block exactly
# (same marker convention, same pure-string-compare awk — no regex, so TAG
# can never break out of its match). Duplicated here rather than reused
# because ols.sh does not export that helper, and this file targets a
# different file (the app's vhconf.conf) than ols.sh's own callers (which
# only ever target httpd_config.conf).
_ssl_upsert_marker_block() {
  local file="$1" tag="$2" block_file="$3"
  local begin="# BEGIN WPM:${tag}"
  local end="# END WPM:${tag}"
  local tmp

  tmp="$(mktemp)" || { log_error "_ssl_upsert_marker_block: mktemp gagal"; return 1; }

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
  else
    cp "$file" "$tmp"
    printf '\n' >> "$tmp"
    cat "$block_file" >> "$tmp"
  fi

  cat "$tmp" > "$file"
  rm -f "$tmp"
  return 0
}

# _ssl_persist_ssl_status APP STATUS ISSUED_AT — rewrites APP's whole
# registry record. app_set_all always OVERWRITES the entire conf file (it
# does not merge — see lib/core.sh's app_set_all/_wpm_conf_write_file), so
# this helper first reads back every existing field via app_get and
# rewrites them unchanged, only replacing SSL_STATUS/SSL_ISSUED_AT.
# Centralizing this read-all-then-rewrite-all pattern here means
# ssl_retry/ssl_run_for_new_app can never accidentally drop an app's
# DB_*/REDIS_*/etc. fields when updating just its SSL state.
_ssl_persist_ssl_status() {
  local app="$1" status="$2" issued_at="$3"

  app_set_all "$app" \
    APP_NAME="$(app_get "$app" APP_NAME)" \
    SOURCE_APP="$(app_get "$app" SOURCE_APP)" \
    DOMAIN="$(app_get "$app" DOMAIN)" \
    VH_ROOT="$(app_get "$app" VH_ROOT)" \
    DOCROOT="$(app_get "$app" DOCROOT)" \
    DB_NAME="$(app_get "$app" DB_NAME)" \
    DB_USER="$(app_get "$app" DB_USER)" \
    DB_PASS="$(app_get "$app" DB_PASS)" \
    PHP_HANDLER="$(app_get "$app" PHP_HANDLER)" \
    REDIS_DB_ID="$(app_get "$app" REDIS_DB_ID)" \
    REDIS_USER="$(app_get "$app" REDIS_USER)" \
    REDIS_PASS="$(app_get "$app" REDIS_PASS)" \
    SSL_STATUS="$status" \
    SSL_ISSUED_AT="$issued_at" \
    CREATED_AT="$(app_get "$app" CREATED_AT)" \
    WPM_VERSION="$(app_get "$app" WPM_VERSION)"

  log_action "Registry app '${app}': SSL_STATUS -> '${status}' (SSL_ISSUED_AT='${issued_at}')"
}

# ============================================================================
# Public API (per WPM-CONTRACT.md §lib/ssl.sh)
# ============================================================================

# ssl_get_public_ip — echoes the VPS's public IPv4 address. Tries an
# outbound HTTP lookup first (api.ipify.org, short timeout; ifconfig.me as
# a second provider if the first is unreachable), then falls back to the
# address of the interface used for the default route if the VPS has no
# outbound internet at the moment. Pure value helper (no logging) since
# its stdout is meant to be captured with $(...).
ssl_get_public_ip() {
  local ip=""

  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null)"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || ip=""
  fi

  if [[ -z "$ip" ]] && command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null)"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || ip=""
  fi

  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1) }' \
      | head -n1)"
  fi

  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  printf '%s\n' "$ip"
}

# ssl_check_dns DOMAIN — resolves DOMAIN's A record(s) and compares them
# against ssl_get_public_ip. Returns 0 if any A record matches this VPS's
# public IP, 1 otherwise (including "couldn't determine" cases — this
# fails closed on purpose: never call certbot on an inconclusive check).
# This is the mandatory gate every other function in this file runs BEFORE
# ever invoking certbot (§7.2/§9).
ssl_check_dns() {
  local domain="$1"

  if [[ -z "$domain" ]]; then
    log_error "ssl_check_dns: domain wajib diisi"
    return 1
  fi

  local public_ip
  public_ip="$(ssl_get_public_ip)"
  if [[ -z "$public_ip" ]]; then
    log_warn "ssl_check_dns: gagal mendeteksi IP publik VPS ini, tidak dapat memverifikasi DNS domain '${domain}'"
    return 1
  fi

  local records
  records="$(_ssl_resolve_a_records "$domain")"
  if [[ -z "$records" ]]; then
    log_warn "ssl_check_dns: domain '${domain}' tidak memiliki A record yang bisa di-resolve saat ini"
    return 1
  fi

  local rec matched=1
  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    if [[ "$rec" == "$public_ip" ]]; then
      matched=0
      break
    fi
  done <<< "$records"

  if [[ "$matched" -eq 0 ]]; then
    log_action "ssl_check_dns: domain '${domain}' menunjuk ke IP VPS ini (${public_ip})"
    return 0
  fi

  log_warn "ssl_check_dns: domain '${domain}' BELUM menunjuk ke IP VPS ini (IP VPS=${public_ip}; A record ditemukan: $(printf '%s' "$records" | tr '\n' ' '))"
  return 1
}

# ssl_issue APP DOMAIN DOCROOT — requests a certificate from Let's Encrypt
# via certbot's webroot (HTTP-01) plugin ONLY (§7.2 — no wildcard/DNS-01 in
# v1). Returns certbot's own exit code. Callers MUST have already gated on
# ssl_check_dns before calling this — this function does not re-check DNS
# itself, keeping it a thin, single-purpose wrapper around certbot.
ssl_issue() {
  local app="$1" domain="$2" docroot="$3"

  if [[ -z "$app" || -z "$domain" || -z "$docroot" ]]; then
    log_error "ssl_issue: APP, DOMAIN, dan DOCROOT wajib diisi"
    return 1
  fi
  if ! is_valid_domain "$domain"; then
    log_error "ssl_issue: domain tidak valid: '${domain}'"
    return 1
  fi
  if [[ ! -d "$docroot" ]]; then
    log_error "ssl_issue: docroot '${docroot}' untuk app '${app}' tidak ditemukan"
    return 1
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    log_error "ssl_issue: certbot tidak ditemukan di PATH. Pasang dulu: apt-get install -y certbot"
    return 1
  fi

  # ACME HTTP-01 challenge dir certbot's webroot plugin writes its token
  # into — pre-create it defensively. OLS must already be serving DOCROOT
  # on :80 for this domain by the time this is called (done earlier in the
  # clone pipeline / already true for an existing app on Retry SSL).
  mkdir -p "${docroot}/.well-known/acme-challenge" 2>/dev/null

  local cmd=(certbot certonly --webroot -w "$docroot" -d "$domain" --non-interactive --agree-tos)
  if [[ -n "${WPM_SSL_EMAIL:-}" ]]; then
    # v1's registry schema (§6.1) has no admin-email field. Support an
    # optional operator-set WPM_SSL_EMAIL env var for renewal notices;
    # fall back to --register-unsafely-without-email otherwise.
    cmd+=(-m "$WPM_SSL_EMAIL")
  else
    cmd+=(--register-unsafely-without-email)
  fi

  log_action "ssl_issue: menjalankan '${cmd[*]}' untuk app '${app}'"
  "${cmd[@]}" >>"$WPM_LOG_FILE" 2>&1
  local rc=$?

  if (( rc == 0 )); then
    log_action "ssl_issue: certbot berhasil menerbitkan/memperbarui sertifikat untuk '${domain}'"
  else
    log_error "ssl_issue: certbot gagal untuk domain '${domain}' (exit ${rc}) — detail di ${WPM_LOG_FILE}"
  fi
  return "$rc"
}

# ssl_install_vhssl APP DOMAIN — renders templates/vhssl.tpl (substituting
# {{DOMAIN}}/{{KEY_FILE}}/{{CERT_FILE}} for the cert paths under
# /etc/letsencrypt/live/DOMAIN/) into the app's vhconf.conf as a marked,
# idempotent "vhssl {}" block (same BEGIN/END marker convention as
# ols.sh), maps the SSL (:443) listener, and restarts OLS gracefully.
# Assumes ssl_issue has already succeeded for DOMAIN.
ssl_install_vhssl() {
  local app="$1" domain="$2"

  if [[ -z "$app" ]] || ! is_valid_app_name "$app"; then
    log_error "ssl_install_vhssl: nama app tidak valid: '${app}'"
    return 1
  fi
  if [[ -z "$domain" ]] || ! is_valid_domain "$domain"; then
    log_error "ssl_install_vhssl: domain tidak valid: '${domain}'"
    return 1
  fi

  local vhconf
  vhconf="$(ols_vhconf_path "$app")"
  if [[ ! -f "$vhconf" ]]; then
    log_error "ssl_install_vhssl: vhconf tidak ditemukan untuk app '${app}' (${vhconf})"
    return 1
  fi

  local live_dir key_file cert_file
  live_dir="/etc/letsencrypt/live/${domain}"
  key_file="${live_dir}/privkey.pem"
  cert_file="${live_dir}/fullchain.pem"
  if [[ ! -f "$key_file" || ! -f "$cert_file" ]]; then
    log_error "ssl_install_vhssl: sertifikat Let's Encrypt untuk '${domain}' tidak ditemukan di ${live_dir} (jalankan ssl_issue lebih dulu)"
    return 1
  fi

  local tpl_path
  tpl_path="$(_ssl_template_path)"
  if [[ -z "$tpl_path" ]]; then
    log_error "ssl_install_vhssl: templates/vhssl.tpl tidak ditemukan (dicari di \$WPM_HOME/templates dan relatif ke lib/ssl.sh)"
    return 1
  fi

  local tpl_content
  if ! tpl_content="$(cat "$tpl_path")"; then
    log_error "ssl_install_vhssl: gagal membaca template ${tpl_path}"
    return 1
  fi
  # Plain bash substring replacement (no sed) — safe against '/' in the
  # cert paths without any delimiter-escaping gymnastics.
  tpl_content="${tpl_content//\{\{DOMAIN\}\}/$domain}"
  tpl_content="${tpl_content//\{\{KEY_FILE\}\}/$key_file}"
  tpl_content="${tpl_content//\{\{CERT_FILE\}\}/$cert_file}"

  local tag="${app}-ssl"
  local block_file
  block_file="$(mktemp)" || { log_error "ssl_install_vhssl: mktemp gagal"; return 1; }
  {
    printf '# BEGIN WPM:%s\n' "$tag"
    printf '%s\n' "$tpl_content"
    printf '# END WPM:%s\n' "$tag"
  } > "$block_file"

  if ! _ssl_upsert_marker_block "$vhconf" "$tag" "$block_file"; then
    rm -f "$block_file"
    log_error "ssl_install_vhssl: gagal menulis blok vhssl ke ${vhconf}"
    return 1
  fi
  rm -f "$block_file"
  log_action "ssl_install_vhssl: blok vhssl dipasang di vhconf app '${app}' (domain=${domain})"

  if ! ols_write_listener_map "$(ols_https_listener_name)" "$app" "$domain"; then
    log_error "ssl_install_vhssl: gagal memetakan listener HTTPS (:443) untuk app '${app}'"
    return 1
  fi

  if ! ols_graceful_restart; then
    log_error "ssl_install_vhssl: blok vhssl & listener SSL terpasang, tapi restart graceful OLS gagal untuk app '${app}'"
    return 1
  fi

  # Re-snapshot so "last known good" (§5.5) includes the new vhssl block —
  # otherwise a later Tools > Rebuild Web App Config would silently drop
  # SSL for this app. Best-effort: a snapshot failure here is logged but
  # does not undo the SSL that's already live.
  if ! ols_snapshot_vhconf "$app"; then
    log_warn "ssl_install_vhssl: gagal memperbarui snapshot vhconf untuk app '${app}' setelah memasang SSL (non-fatal)"
  fi

  log_action "ssl_install_vhssl: selesai untuk app '${app}' (domain=${domain})"
  return 0
}

# ssl_retry APP — §F-3d: re-reads the registry for APP, gates on
# ssl_check_dns (no certbot call unless DNS actually points here — this is
# the rate-limit-saving behavior required by §7.2/§9), and on success
# issues + installs the certificate and marks SSL_STATUS=active with a
# fresh SSL_ISSUED_AT. If DNS isn't pointing yet, SSL_STATUS is left
# untouched and the reason is reported — no certbot call is made at all.
ssl_retry() {
  local app="$1"

  if [[ -z "$app" ]]; then
    log_error "ssl_retry: APP wajib diisi"
    return 1
  fi
  if ! app_exists "$app"; then
    log_error "ssl_retry: app '${app}' tidak ditemukan di registry"
    return 1
  fi

  local domain docroot cur_status
  domain="$(app_get "$app" DOMAIN)"
  docroot="$(app_get "$app" DOCROOT)"
  cur_status="$(app_get "$app" SSL_STATUS)"

  if [[ -z "$domain" ]]; then
    log_error "ssl_retry: app '${app}' tidak memiliki DOMAIN terdaftar di registry"
    return 1
  fi
  if [[ -z "$docroot" || ! -d "$docroot" ]]; then
    log_error "ssl_retry: DOCROOT app '${app}' tidak ditemukan ('${docroot}')"
    return 1
  fi

  log_info "Retry SSL untuk '${app}' (domain: ${domain}, status saat ini: ${cur_status:-none})..."
  log_action "ssl_retry: mulai app=${app} domain=${domain} status_lama=${cur_status:-none}"

  if ! ssl_check_dns "$domain"; then
    log_warn "Retry SSL '${app}': domain '${domain}' belum menunjuk ke IP VPS ini — certbot TIDAK dipanggil (hemat kuota rate limit Let's Encrypt, §7.2/§9). Status SSL tidak diubah, coba lagi setelah DNS pointing dengan benar."
    log_action "ssl_retry: dibatalkan app=${app} alasan=dns_belum_pointing status_tidak_diubah=${cur_status:-none}"
    return 1
  fi

  if ! confirm "Domain '${domain}' sudah menunjuk ke IP VPS ini. Lanjutkan penerbitan sertifikat Let's Encrypt sekarang? (kuota terbatas, ±5 sertifikat/minggu per set domain — hindari percobaan berulang)" "default_y"; then
    log_info "Retry SSL untuk '${app}' dibatalkan oleh pengguna."
    log_action "ssl_retry: dibatalkan oleh pengguna app=${app}"
    return 1
  fi

  if ! ssl_issue "$app" "$domain" "$docroot"; then
    log_error "Retry SSL '${app}': certbot gagal menerbitkan sertifikat untuk '${domain}'."
    _ssl_persist_ssl_status "$app" "failed" ""
    log_action "ssl_retry: gagal app=${app} tahap=certbot status=failed"
    return 1
  fi

  if ! ssl_install_vhssl "$app" "$domain"; then
    log_error "Retry SSL '${app}': sertifikat terbit, tapi pemasangan blok vhssl/listener SSL gagal."
    _ssl_persist_ssl_status "$app" "failed" ""
    log_action "ssl_retry: gagal app=${app} tahap=install_vhssl status=failed"
    return 1
  fi

  local issued_at
  issued_at="$(now_iso)"
  _ssl_persist_ssl_status "$app" "active" "$issued_at"
  log_action "ssl_retry: berhasil app=${app} status=active issued_at=${issued_at}"
  log_info "SSL untuk '${app}' berhasil aktif (HTTPS)."
  return 0
}

# ssl_run_for_new_app APP DOMAIN DOCROOT — the step-8 SSL wrapper
# clone_execute_one calls right after a freshly-cloned app goes live on
# HTTP. Gates on ssl_check_dns first (no certbot call if DNS isn't
# pointing yet — expected right after a fresh clone, and per §F-2/§9 this
# is explicitly NOT treated as a clone failure). Never dies and never
# rolls back anything — the caller keeps the app live on HTTP regardless
# of the outcome here.
#
# Echoes exactly one of "active" | "failed" | "none" on stdout (callers
# capture it with `status=$(ssl_run_for_new_app ...)`); clone.sh maps that
# to its own "https"/"failed"/"http" wizard report line.
#
# Also updates the registry's SSL_STATUS/SSL_ISSUED_AT itself, but only
# when APP is already registered (app_exists) — defensive, since
# clone_execute_one may call this either just before or just after
# writing APP's initial registry record; when the record doesn't exist
# yet, the registry update is skipped here and left to the caller to
# persist alongside the rest of the app's newly-generated fields.
ssl_run_for_new_app() {
  local app="$1" domain="$2" docroot="$3"

  if [[ -z "$app" || -z "$domain" || -z "$docroot" ]]; then
    log_error "ssl_run_for_new_app: APP, DOMAIN, dan DOCROOT wajib diisi"
    printf '%s\n' "failed"
    return 1
  fi

  log_info "Menyiapkan SSL untuk '${app}' (domain: ${domain})..."
  log_action "ssl_run_for_new_app: mulai app=${app} domain=${domain}"

  if ! ssl_check_dns "$domain"; then
    log_warn "SSL '${app}': domain '${domain}' belum menunjuk ke IP VPS ini. App tetap live di HTTP; ulangi lewat menu Retry SSL (§F-3d) setelah DNS pointing."
    log_action "ssl_run_for_new_app: dilewati app=${app} alasan=dns_belum_pointing status=none"
    if app_exists "$app"; then
      _ssl_persist_ssl_status "$app" "none" ""
    fi
    printf '%s\n' "none"
    return 0
  fi

  if ! ssl_issue "$app" "$domain" "$docroot"; then
    log_error "SSL '${app}': certbot gagal menerbitkan sertifikat untuk '${domain}'. App tetap live di HTTP; coba lagi lewat Retry SSL."
    log_action "ssl_run_for_new_app: gagal app=${app} tahap=certbot status=failed"
    if app_exists "$app"; then
      _ssl_persist_ssl_status "$app" "failed" ""
    fi
    printf '%s\n' "failed"
    return 1
  fi

  if ! ssl_install_vhssl "$app" "$domain"; then
    log_error "SSL '${app}': sertifikat terbit, tapi pemasangan blok vhssl/listener SSL gagal. App tetap live di HTTP; coba lagi lewat Retry SSL."
    log_action "ssl_run_for_new_app: gagal app=${app} tahap=install_vhssl status=failed"
    if app_exists "$app"; then
      _ssl_persist_ssl_status "$app" "failed" ""
    fi
    printf '%s\n' "failed"
    return 1
  fi

  local issued_at
  issued_at="$(now_iso)"
  if app_exists "$app"; then
    _ssl_persist_ssl_status "$app" "active" "$issued_at"
  fi
  log_action "ssl_run_for_new_app: selesai app=${app} domain=${domain} status=active issued_at=${issued_at}"
  log_info "SSL untuk '${app}' berhasil aktif (HTTPS)."
  printf '%s\n' "active"
  return 0
}
