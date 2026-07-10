# PRD — WPM (WordPress Manager untuk OpenLiteSpeed)

| | |
|---|---|
| **Dokumen** | Project Requirements Document (PRD) |
| **Produk** | WPM — WordPress Manager |
| **Versi dokumen** | 1.0 |
| **Tanggal** | 9 Juli 2026 |
| **Status** | Final — siap masuk fase pengembangan |
| **Target platform** | Ubuntu 24.04 LTS + OpenLiteSpeed (instalasi manual) |

---

## 1. Overview

### 1.1 Latar Belakang

Pengelolaan banyak website WordPress pada satu VPS OpenLiteSpeed saat ini dilakukan serba manual. Meng-clone satu situs membutuhkan lebih dari sepuluh langkah: menyalin file, dump dan import database, menyunting `wp-config.php`, membuat virtual host, memetakan listener, menerbitkan SSL, hingga membersihkan cache. Proses ini lambat, rawan human error, dan sulit diulang secara konsisten.

Panel manajemen yang ada (CyberPanel, aaPanel, RunCloud, dsb.) menyelesaikan masalah tersebut, tetapi terlalu berat untuk VPS kelas bawah — panel web beserta daemon pendampingnya memakan RAM ratusan MB, porsi besar dari total 1 GB yang tersedia.

### 1.2 Deskripsi Produk

**WPM** adalah tool manajemen WordPress berbasis terminal untuk server OpenLiteSpeed. Fungsi intinya adalah **meng-clone web app WordPress secara massal** — file, database, konfigurasi vhost, SSL, dan cache — melalui wizard bermenu, ditambah perkakas perawatan harian (fix ownership, rebuild config, clear cache, PHP settings, Redis ACL) serta **monitoring resource dengan notifikasi bot Telegram**.

WPM ditulis 100% Bash, dipasang dengan satu perintah (one-click install), dan dijalankan dari terminal dengan perintah `wpm`. Tidak ada panel web dan tidak ada daemon wajib — konsumsi RAM saat idle adalah nol.

### 1.3 Tujuan Produk (Goals)

| Kode | Tujuan |
|---|---|
| G-1 | Meng-clone 1 web app menjadi N salinan identik dengan sumbernya melalui wizard interaktif |
| G-2 | Konsumsi resource mendekati nol saat idle; aman dijalankan di VPS 1 vCPU / 1 GB RAM |
| G-3 | Instalasi satu perintah (one-click install) langsung dari terminal |
| G-4 | Seluruh operasi harian dapat dilakukan lewat menu, tanpa menghafal perintah |
| G-5 | Admin mengetahui kondisi server secara proaktif (alert) dan on-demand (`/stats`) via Telegram |

### 1.4 Di Luar Cakupan (Non-Goals)

- Bukan pengganti panel penuh: tidak ada manajemen email, DNS, FTP, atau multi-user.
- Tidak membuat instalasi WordPress baru dari nol — fokus pada cloning dari app sumber yang sudah ada.
- Tidak mendukung lingkungan CyberPanel/aaPanel (struktur konfigurasi berbeda total).
- Tidak ada backup terjadwal (backup hanya ditawarkan saat delete app).
- Tidak multi-server; satu instalasi WPM mengelola satu VPS.

### 1.5 Target Pengguna

Sysadmin/developer tunggal dengan akses root yang mengelola banyak situs WordPress sejenis (contoh: jaringan situs layanan jasa dengan struktur serupa di banyak domain) pada VPS low-end.

### 1.6 Metrik Keberhasilan

| Metrik | Target |
|---|---|
| Durasi clone situs ±500 MB pada VPS 1 core / 1 GB | < 5 menit, tanpa membuat situs live lag |
| RAM idle | 0 MB (tanpa bot) / ≤ 8 MB (bot aktif) |
| Durasi instalasi one-click | < 3 menit |
| Latensi alert sejak threshold terlampaui | < 90 detik |
| Keberhasilan SSL otomatis (saat DNS sudah pointing) | ≥ 95% |

---

## 2. Requirements

### 2.1 Prasyarat Lingkungan

| Komponen | Ketentuan |
|---|---|
| OS | Ubuntu 24.04 LTS |
| Web server | OpenLiteSpeed, instalasi manual di `/usr/local/lsws` |
| Database | MariaDB / MySQL (mengikuti yang terpasang) |
| PHP | lsphp 8.x (versi per app mengikuti sumber clone) |
| Redis | ≥ 6.0 (wajib — fitur ACL) |
| Plugin cache WP | LiteSpeed Cache (LSCWP) |
| Akses | root |
| Spesifikasi minimum | 1 vCPU, 1 GB RAM |
| Dipasang installer bila belum ada | certbot, rsync, wp-cli, curl, jq, cron |

### 2.2 Functional Requirements

Prioritas memakai skema MoSCoW: **M**ust / **S**hould / **W**on't (v1).

| ID | Kebutuhan | Prioritas |
|---|---|---|
| FR-01 | Menampilkan daftar seluruh web app: nama, domain, docroot, database, versi PHP, status SSL, ukuran disk | M |
| FR-02 | Import vhost lama (dibuat manual) ke registry agar dapat dikelola WPM | S |
| FR-03 | Clone: memilih app sumber dari daftar | M |
| FR-04 | Clone: memilih jumlah salinan (N ≥ 1) | M |
| FR-05 | Clone: nama app & nama database dapat dikustom per salinan, dengan **default akhiran numerik** yang increment otomatis | M |
| FR-06 | Clone: input domain per salinan (wajib, tervalidasi unik) | M |
| FR-07 | Clone: ringkasan rencana + konfirmasi sebelum eksekusi | M |
| FR-08 | Clone: eksekusi **sekuensial satu per satu** (data web + database, lalu SSL) | M |
| FR-09 | Clone: hasil identik dengan sumber (file, DB, konfigurasi vhost, versi PHP, setting LSCWP) | M |
| FR-10 | SSL/TLS Let's Encrypt otomatis untuk tiap app pasca-clone | M |
| FR-11 | Kegagalan SSL tidak membatalkan antrian; app tetap live di HTTP dan dapat di-retry | M |
| FR-12 | Access log LSWS **terpisah per web app** + viewer (tail live, top IP, top URL, status code) | M |
| FR-13 | PHP Settings per app: memory_limit, upload_max_filesize, post_max_size, max_execution_time, max_input_vars, versi lsphp + preset | M |
| FR-14 | Redis ACL per app: user + password sendiri, pembatasan prefix key, blokir perintah berbahaya, sinkron otomatis ke LSCWP | M |
| FR-15 | Retry SSL untuk app yang penerbitannya gagal/tertunda | M |
| FR-16 | Delete web app: config, file, database, ACL, sertifikat, registry — konfirmasi ganda + opsi backup | M |
| FR-17 | Tools — Fix Ownership: perbaiki kepemilikan file & folder | M |
| FR-18 | Tools — Rebuild Web App Config: bangun ulang konfigurasi vhost app | M |
| FR-19 | Tools — Clear Web App Cache: hapus cache file + Redis milik app tsb saja | M |
| FR-20 | Web Server Settings: restart/reload graceful, port & password WebAdmin, preset tuning low-end, edit `httpd_config.conf` | M |
| FR-21 | Telegram alert: load tinggi, memory tinggi, disk penuh, service down | M |
| FR-22 | Telegram alert: anti-spam (alert saat crossing, re-alert berkala, notifikasi recovery + hysteresis) | M |
| FR-23 | Telegram bot: `/uptime`, `/stats`, `/apps`, `/status`, `/help` | M |
| FR-24 | Setup wizard Telegram: token, auto-deteksi chat ID, pesan tes | M |
| FR-25 | Seluruh threshold & interval alert dapat dikonfigurasi dari menu | S |
| FR-26 | Auto-restart service yang mati (toggle, default off) | S |
| FR-27 | Instalasi one-click via `curl` dari repositori | M |
| FR-28 | Perintah aksi via Telegram (`/restart_ols`, `/clearcache`) | W — backlog v1.1 |

### 2.3 Non-Functional Requirements

| ID | Kategori | Kebutuhan |
|---|---|---|
| NFR-01 | Performa | Proses berat dibungkus `nice -n 19` + `ionice -c3`; situs live tetap responsif selama cloning |
| NFR-02 | Memori | Dump database di-streaming (pipe), tanpa file SQL besar di disk; tanpa daemon wajib; bot opsional ≤ 8 MB |
| NFR-03 | Keandalan | Lock file mencegah proses ganda; rollback artefak setengah jadi bila clone gagal; operasi destruktif berkonfirmasi ganda |
| NFR-04 | Keamanan | File kredensial `chmod 600`; token/password tidak pernah tercetak di log; bot hanya merespons chat ID whitelist; password acak ≥ 24 karakter |
| NFR-05 | Usabilitas | Menu angka + warna ANSI; default cerdas (tinggal Enter); berjalan di semua SSH client |
| NFR-06 | Portabilitas | Bash ≥ 5 + coreutils standar Ubuntu; tanpa Python/Node/runtime tambahan |
| NFR-07 | Auditabilitas | Semua aksi tercatat di `/var/log/wpm/` dengan rotasi |
| NFR-08 | Maintainability | Kode modular per file `lib/`; target total 2.000–2.500 baris |

---

## 3. Core Features

### F-1 — List Web Apps

Menampilkan tabel gabungan dari blok `virtualhost` di `httpd_config.conf` dan registry `/etc/wpm/apps/`. Kolom: Nama, Domain, Docroot, Database, PHP, SSL (✓/✗), Ukuran disk. Vhost yang dibuat manual (belum terdaftar) ditandai dan dapat di-**import** ke registry agar bisa dikelola dan dijadikan sumber clone.

**Kriteria selesai:** seluruh app tampil ≤ 2 detik untuk 30 app; app hasil import dapat langsung dipakai sebagai sumber clone.

### F-2 — Clone Web App (fitur inti)

**Wizard input:**

1. Pilih app sumber dari daftar.
2. Masukkan jumlah salinan (N).
3. Untuk tiap salinan — tekan Enter untuk memakai default:
   - Nama app → default: `<sumber><angka berikutnya>` (mis. `zahra2`, `zahra3`, …)
   - Nama database → default: `<db-sumber><angka yang sama>` (mis. `zahra_db2`, …)
   - Domain → wajib diisi, divalidasi unik
4. Ringkasan seluruh rencana (tabel N baris) → konfirmasi.

Angka default dihitung dari angka terpakai terakhir (registry + filesystem + daftar database), sehingga tidak pernah bentrok.

**Strategi mirror:** vhconf milik sumber **disalin lalu di-patch**, bukan digenerate dari template kosong. Seluruh kustomisasi sumber — rewrite rules, context block, header, modul cache, `phpIniOverride`, versi lsphp — otomatis terbawa 100%. Yang diganti hanya: nama, domain, docroot, path log, dan path SSL.

**Pipeline eksekusi (sekuensial, satu app selesai baru lanjut berikutnya):**

```
[1/8] rsync file sumber → docroot baru
      (exclude: wp-content/cache/, wp-content/litespeed/)
[2/8] CREATE DATABASE + user DB baru (password acak 24 karakter)
[3/8] mysqldump --single-transaction --quick | mysql   ← streaming, RAM minim
[4/8] Patch wp-config.php: kredensial DB baru, salts baru,
      kredensial Redis baru (user/pass/DB ID unik)
[5/8] wp search-replace URL lama → URL baru (aman untuk serialized data)
[6/8] Salin & patch vhconf + tambah blok virtualhost + map listener :80
      → restart OLS graceful
[7/8] Fix ownership otomatis
[8/8] Cek DNS → certbot (webroot) → pasang vhssl + map :443 → restart
      → buat Redis ACL user → update kredensial Redis di LSCWP
      → purge all cache LSCWP
```

**Penanganan LSCWP:** pengaturan plugin otomatis terbawa karena tersimpan di database. Pasca-import, identitas object cache diperbarui via `wp litespeed-option`: username + password Redis milik clone dan **Redis DB ID unik** per app. `.htaccess` (rewrite LSCWP) ikut tersalin; clone mulai dengan cache kosong.

**Penanganan kegagalan:** gagal di langkah 1–7 → artefak setengah jadi dibersihkan (rollback) dan antrian lanjut ke app berikutnya dengan laporan. Gagal di langkah 8/SSL (umumnya DNS belum pointing) → **bukan kegagalan clone**: app tetap live di HTTP, SSL diulang lewat menu *Retry SSL*.

**Kriteria selesai:** clone dapat diakses di domain barunya; login wp-admin memakai kredensial yang sama dengan sumber; setting LSCWP identik; cache antar-app terisolasi penuh.

### F-3 — Kelola Web App

**F-3a · PHP Settings** — via blok `phpIniOverride` di vhconf masing-masing app. Parameter: `memory_limit`, `upload_max_filesize`, `post_max_size`, `max_execution_time`, `max_input_vars`; plus pemilihan versi lsphp bila terpasang lebih dari satu.

| Preset | memory_limit | upload / post | max_execution_time |
|---|---|---|---|
| **Low** (default 1 GB RAM) | 128M | 32M / 34M | 60 s |
| Normal | 256M | 64M / 68M | 120 s |
| High | 512M | 128M / 136M | 300 s |

**F-3b · Redis ACL** — berbasis `aclfile /etc/redis/users.acl`. Tiap app mendapat user Redis sendiri (`app_<nama>`) dengan password acak, **dibatasi hanya key ber-prefix miliknya** (`~<nama>:*`), dan perintah berbahaya diblok (`-@dangerous -flushall -flushdb -config`). Kredensial disinkronkan otomatis ke LSCWP. Menu: lihat kredensial, regenerate password, enable/disable user.

**F-3c · Access Log per app** — tiap vhost memiliki blok `accesslog` sendiri: `$VH_ROOT/logs/access.log` dengan `rollingSize 10M`, `keepDays 7`, `compressArchive 1` (hemat disk). Viewer bawaan: tail live, Top 10 IP, Top 10 URL, ringkasan status code (berbasis `awk`, beban nyaris nol).

**F-3d · Retry SSL** — mengulang penerbitan sertifikat untuk app berstatus `failed`/`none`: cek DNS → certbot webroot → pasang blok vhssl + map listener :443 → restart graceful.

**F-3e · Delete Web App** — konfirmasi ganda (ketik ulang nama app). Yang dihapus: vhconf, blok virtualhost + map listener di `httpd_config`, file situs (opsi backup `.tar.gz` terlebih dahulu), database + user DB, Redis ACL user + flush DB ID miliknya, sertifikat (opsional), dan entry registry. Diakhiri restart graceful.

### F-4 — Tools

- **Fix Ownership** — chown rekursif ke user OLS (dideteksi dari `httpd_config`, default `nobody:nogroup`); direktori 755, file 644, `wp-config.php` 640.
- **Rebuild Web App Config** — menulis ulang vhconf dari snapshot "last known good" + data registry. Berguna saat config rusak/terhapus; data situs tidak disentuh.
- **Clear Web App Cache** — menghapus `wp-content/cache/` dan folder LiteSpeed, lalu `FLUSHDB` **hanya pada Redis DB ID milik app tersebut** (via koneksi admin) — app lain tidak terpengaruh.

### F-5 — Web Server Settings (OpenLiteSpeed)

Restart/reload graceful; ganti port & reset password WebAdmin (7080); preset tuning low-end (maxConnections, keepalive, dsb.); edit `httpd_config.conf` langsung via editor dengan **backup otomatis sebelum perubahan** dan restart setelah simpan.

### F-6 — Telegram & Monitoring

**F-6a · Monitor Alert (cron, tanpa daemon).** Cron berjalan tiap 60 detik menjalankan `monitor.sh`: baca metrik → bandingkan threshold → kirim via `curl` ke Bot API → selesai, proses mati. RAM saat idle: 0.

| Metrik | Threshold default | Sumber data |
|---|---|---|
| Load average (5 menit) | > jumlah core × 2.0 | `/proc/loadavg` |
| RAM | > 90% terpakai | `MemAvailable` di `/proc/meminfo` |
| Swap | > 60% | `/proc/meminfo` |
| Disk `/` | > 85% | `df` |
| Service down | OLS / MariaDB / Redis | `systemctl is-active` |

Anti-spam bawaan: alert hanya saat **melewati** ambang (state crossing), re-alert tiap 30 menit selama masih tinggi, dan notifikasi **RECOVERED** dengan hysteresis (contoh: alert di 90%, dianggap pulih di bawah 78%) beserta durasi insiden. Auto-restart service yang mati tersedia sebagai toggle (default off).

Contoh format pesan:

```
🚨 WPM ALERT — vps-jkt1
RAM 93% (918/987 MB) · Swap 71%
Top proses: lsphp 34% · mariadbd 26% · redis 4%
Load: 1.8 · Disk: 61%
```

```
✅ RECOVERED — vps-jkt1
RAM kembali normal: 64%
Durasi insiden: 14 menit
```

**F-6b · Bot Interaktif (systemd, opsional, ±5 MB RAM).** Loop long-polling `getUpdates` berbasis bash + curl; saat idle, curl hanya menunggu — CPU nyaris nol. Dapat dimatikan sepenuhnya tanpa memengaruhi alert (F-6a).

| Perintah | Fungsi |
|---|---|
| `/uptime` | Uptime server + load average |
| `/stats` | Snapshot lengkap: uptime, load, RAM, swap, disk, status service |
| `/apps` | Daftar web app + ukuran disk + status SSL |
| `/status` | Status service OLS / MariaDB / Redis |
| `/help` | Daftar perintah |

Contoh keluaran `/stats`:

```
📊 vps-jkt1 — 09 Jul 14:02 WIB
⏱ Uptime : 12 hari 4 jam
🔥 Load   : 0.42 / 0.38 / 0.35 (1 core)
🧠 RAM    : 612 / 987 MB (62%)
💾 Swap   : 180 MB / 2 GB (9%)
🗄 Disk   : 14.2 / 25 GB (57%)
⚙️ OLS ✓ · MariaDB ✓ · Redis ✓
```

**Keamanan:** bot hanya merespons **chat ID whitelist** — pesan dari pihak lain diabaikan tanpa balasan. Token disimpan di `/etc/wpm/telegram.conf` (600) dan tidak pernah tampil di log. Versi 1 bersifat **read-only** (tanpa perintah aksi) — lihat §7.5.

**F-6c · Setup wizard** — minta token dari @BotFather; chat ID dideteksi otomatis (pengguna cukup kirim `/start` ke bot, wizard membacanya via `getUpdates`); diakhiri pesan tes. Dapat dilewati saat instalasi dan disetel belakangan dari menu 6.

---

## 4. User Flow

### 4.1 Peta Menu

```
╔══════════════════════════════════╗
║   WPM — WordPress Manager (OLS)  ║
╚══════════════════════════════════╝
 1) List Web Apps
 2) Clone Web App
 3) Kelola Web App
     → PHP Settings
     → Redis ACL
     → Lihat Access Log
     → Retry SSL
     → Delete Web App
 4) Tools
     → Fix Ownership
     → Rebuild Web App Config
     → Clear Web App Cache
 5) Web Server Settings (OpenLiteSpeed)
 6) Telegram & Monitoring
     → Setup bot (token + chat ID + tes)
     → Atur threshold alert
     → Nyalakan/matikan alert monitor
     → Nyalakan/matikan bot interaktif
     → Kirim tes notifikasi
 0) Keluar
```

### 4.2 Flow Instalasi (One-Click)

```
bash <(curl -sL https://raw.githubusercontent.com/<USER>/wpm/main/install.sh)
 → cek root & Ubuntu 24.04
 → deteksi OLS, MariaDB/MySQL, lsphp, Redis
     └─ tidak lengkap → berhenti + petunjuk komponen yang kurang
 → pasang dependensi yang belum ada (certbot, rsync, wp-cli, jq)
 → kredensial root DB: deteksi /root/.my.cnf → bila tidak ada, tanya
   → simpan ke /etc/wpm/.secrets (600)
 → tawaran opsional: swap 2 GB (bila belum ada) · tuning MariaDB
   · redis databases 16 → 64
 → pasang /usr/local/bin/wpm + /usr/local/share/wpm/
 → scan vhost existing → tawarkan import ke registry
 → tawaran setup Telegram (boleh dilewati)
 → selesai — jalankan dengan perintah:  wpm
```

### 4.3 Flow Clone (flow utama)

```
wpm → 2) Clone Web App
 → pilih app sumber dari daftar
 → jumlah salinan: N
 → loop i = 1..N:
     nama app   [default: zahraX]   ← Enter = pakai default
     nama DB    [default: zahra_dbX]
     domain     (wajib, validasi unik + format)
 → ringkasan tabel N baris → konfirmasi y/N
 → eksekusi berurutan:
     app #1: pipeline 8 langkah ✓ → app #2: pipeline ✓ → …
 → laporan akhir per app:
     ✓ sukses (HTTPS)  ·  ◐ live HTTP, SSL pending  ·  ✗ gagal (+ path log)
```

### 4.4 Flow Delete

```
3) Kelola Web App → pilih app → Delete
 → tampilkan rincian yang akan dihapus (config, file, DB, ACL, cert)
 → konfirmasi 1: y/N
 → konfirmasi 2: ketik ulang nama app
 → tawaran backup .tar.gz terlebih dahulu
 → eksekusi penghapusan → restart OLS graceful → laporan
```

### 4.5 Siklus Alert Monitoring

```
NORMAL ──ambang terlampaui──▶ ALERT (kirim 🚨)
ALERT  ──masih tinggi, tiap 30 menit──▶ re-alert
ALERT  ──turun di bawah ambang pulih (hysteresis)──▶ RECOVERED (kirim ✅ + durasi) ──▶ NORMAL
```

### 4.6 Flow Interaksi Bot

```
Pengguna kirim /stats
 → bot.sh (long-poll) menerima update
 → chat ID cocok whitelist?
     ├─ tidak → abaikan tanpa balasan
     └─ ya    → kumpulkan metrik → format pesan → sendMessage → kembali polling
```

---

## 5. Architecture

### 5.1 Diagram Komponen

```
┌─────────────── Terminal (SSH) ───────────────┐
│                 wpm  (menu utama)             │
│  lib/: core · ols · clone · ssl · redis       │
│        php · tools · telegram                 │
└──────┬────────────────────────────────────────┘
       │ membaca/menulis
       ▼
┌── Sistem yang dikendalikan ───────────────────────────────┐
│ OpenLiteSpeed : httpd_config.conf, vhconf/, graceful      │
│ MariaDB/MySQL : mysqldump | mysql (streaming)             │
│ Redis         : ACL user, alokasi DB ID, FLUSHDB per app  │
│ Certbot       : ACME HTTP-01 (webroot)                    │
│ Filesystem    : docroot situs, log, backup                │
└───────────────────────────────────────────────────────────┘

cron (tiap 60 dtk) ──▶ monitor.sh ──▶ Telegram Bot API (sendMessage)
systemd (opsional) ──▶ bot.sh (long-poll getUpdates) ──▶ jawab /stats dll.
```

### 5.2 Struktur Repositori

```
wpm/
├── install.sh              → one-click installer
├── wpm                     → entry point + menu utama
├── monitor.sh              → checker alert (dijalankan cron)
├── bot.sh                  → listener Telegram (daemon opsional)
├── lib/
│   ├── core.sh             → util umum: warna, prompt, logging, lock, validasi
│   ├── ols.sh              → parser & penulis config OLS, marker blok, restart
│   ├── clone.sh            → engine cloning (pipeline 8 langkah + rollback)
│   ├── ssl.sh              → cek DNS, certbot, pemasangan vhssl, retry
│   ├── redis.sh            → ACL, alokasi DB ID, sinkron kredensial LSCWP
│   ├── php.sh              → phpIniOverride, preset, versi lsphp
│   ├── tools.sh            → fix ownership, rebuild config, clear cache
│   └── telegram.sh         → kirim pesan, format stats, escape MarkdownV2
└── templates/
    └── vhssl.tpl           → blok SSL untuk vhconf
```

### 5.3 Layout Instalasi di VPS

```
/usr/local/bin/wpm                     → command global
/usr/local/share/wpm/                  → lib/ + templates/ + monitor.sh + bot.sh
/etc/wpm/apps/<nama-app>.conf          → registry per app (600)
/etc/wpm/apps/<nama-app>.vhconf.snap   → snapshot "last known good" vhconf
/etc/wpm/.secrets                      → kredensial root DB (600)
/etc/wpm/telegram.conf                 → token, chat ID, threshold (600)
/etc/cron.d/wpm-monitor                → cron alert tiap menit
/etc/systemd/system/wpm-bot.service    → unit bot interaktif (opsional)
/var/lib/wpm/monitor.state             → state anti-spam alert
/var/log/wpm/                          → log aktivitas & hasil clone (rotasi)
```

### 5.4 Tanggung Jawab Modul

| Modul | Tanggung jawab |
|---|---|
| `core.sh` | Warna ANSI, prompt & konfirmasi, logging, lock file global, validasi input, generator password acak |
| `ols.sh` | Parse blok `virtualhost`/`listener` di `httpd_config.conf`, tulis blok bermarker WPM, patch vhconf, graceful restart |
| `clone.sh` | Orkestrasi pipeline 8 langkah, penghitungan default numerik, rollback saat gagal |
| `ssl.sh` | Verifikasi A record vs IP VPS, penerbitan certbot webroot, pemasangan vhssl + map :443 |
| `redis.sh` | Pengelolaan `users.acl`, alokasi Redis DB ID, sinkron kredensial ke LSCWP via wp-cli, flush per app |
| `php.sh` | Baca/tulis `phpIniOverride`, preset Low/Normal/High, deteksi & pindah versi lsphp |
| `tools.sh` | Fix ownership, rebuild dari snapshot, pembersihan cache file + Redis |
| `telegram.sh` | Wrapper `sendMessage`, format pesan stats/alert, masking token |
| `monitor.sh` | Pembacaan metrik, mesin state (crossing/re-alert/recovery), auto-restart opsional |
| `bot.sh` | Long-polling `getUpdates`, whitelist chat ID, router perintah |

### 5.5 Prinsip Arsitektur

- **Stateless saat idle** — tidak ada proses residen kecuali bot opsional; alert berjalan lewat cron.
- **Registry sebagai source of truth** — konfigurasi OLS milik app selalu dapat direkonstruksi dari registry + snapshot (fitur Rebuild).
- **Marker blok** `# BEGIN WPM:<app> … # END WPM:<app>` pada setiap suntingan `httpd_config.conf` → penambahan dan penghapusan blok idempoten serta aman di-parse; file selalu di-backup sebelum diubah.
- **Semua perubahan OLS diakhiri graceful restart** — tanpa memutus koneksi yang sedang berjalan.
- Integrasi eksternal hanya dua: **Telegram Bot API** (HTTPS keluar) dan **Let's Encrypt** (ACME HTTP-01 webroot). Tidak ada dependensi cloud lain.

---

## 6. Database Schema

WPM tidak memakai RDBMS untuk dirinya sendiri — seluruh state disimpan pada **flat-file** demi bobot minimal (lihat §7.1). Skema berikut mendefinisikan struktur file-file tersebut serta objek yang dibuat WPM di MySQL dan Redis untuk tiap app.

### 6.1 Registry App — `/etc/wpm/apps/<APP>.conf` (format key=value, 600, root)

| Field | Contoh | Keterangan |
|---|---|---|
| `APP_NAME` | `zahra2` | Unik; pola `[a-z0-9-]+` |
| `SOURCE_APP` | `zahra` | Asal clone (kosong bila hasil import) |
| `DOMAIN` | `zahra2.example.com` | Unik antar app |
| `VH_ROOT` | `/var/www/zahra2` | Root virtual host |
| `DOCROOT` | `/var/www/zahra2/html` | Mengikuti pola struktur sumber |
| `DB_NAME` | `zahra_db2` | Unik |
| `DB_USER` | `zahra_db2` | Sama dengan DB_NAME secara default |
| `DB_PASS` | *(acak 24 karakter)* | |
| `PHP_HANDLER` | `lsphp82` | Mengikuti sumber clone |
| `REDIS_DB_ID` | `2` | Unik, rentang 1–63 |
| `REDIS_USER` | `app_zahra2` | |
| `REDIS_PASS` | *(acak 24 karakter)* | Disinkron ke LSCWP |
| `SSL_STATUS` | `none · active · failed` | |
| `SSL_ISSUED_AT` | ISO-8601 | Kosong bila belum terbit |
| `CREATED_AT` | ISO-8601 | |
| `WPM_VERSION` | `1.0` | Versi tool saat app dibuat |

### 6.2 Kredensial Global — `/etc/wpm/.secrets` (600)

`MYSQL_ROOT_USER`, `MYSQL_ROOT_PASS`. Dilewati bila `/root/.my.cnf` tersedia (dipakai langsung).

### 6.3 Konfigurasi Telegram — `/etc/wpm/telegram.conf` (600)

| Field | Default | Keterangan |
|---|---|---|
| `BOT_TOKEN` | — | Dari @BotFather |
| `CHAT_ID` | — | Whitelist penerima & pengirim perintah |
| `ALERTS_ENABLED` | `1` | Toggle alert monitor |
| `TH_LOAD_MULT` | `2.0` | Ambang load = core × nilai ini |
| `TH_RAM` / `TH_RAM_RECOVER` | `90` / `78` | % — alert / pulih (hysteresis) |
| `TH_SWAP` / `TH_SWAP_RECOVER` | `60` / `45` | % |
| `TH_DISK` | `85` | % partisi `/` |
| `REALERT_MIN` | `30` | Menit antar re-alert |
| `AUTO_RESTART` | `0` | Auto-restart service mati |
| `LABEL` | *hostname* | Nama server pada pesan |

### 6.4 State Monitor — `/var/lib/wpm/monitor.state`

Per metrik: `STATE_<METRIK>` (`ok`/`alert`), `LAST_SENT_<METRIK>` (epoch kirim terakhir), `SINCE_<METRIK>` (epoch awal insiden — untuk menghitung durasi pada pesan RECOVERED). Ditulis atomik (tulis ke file temp lalu `mv`).

### 6.5 Redis ACL — `/etc/redis/users.acl`

```
user app_zahra2 on ><password> ~zahra2:* +@all -@dangerous -flushall -flushdb -config
```

Catatan desain: ACL Redis tidak dapat membatasi `SELECT` antar-database, sehingga **isolasi utama adalah prefix key**; Redis DB ID unik dipakai untuk organisasi data dan flush per-app oleh koneksi admin WPM.

### 6.6 Objek MySQL per App

```sql
CREATE DATABASE <DB_NAME> CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '<DB_USER>'@'localhost' IDENTIFIED BY '<DB_PASS>';
GRANT ALL PRIVILEGES ON <DB_NAME>.* TO '<DB_USER>'@'localhost';
```

Tanpa hak global — tiap user hanya dapat mengakses database miliknya sendiri.

### 6.7 Konvensi Penamaan & Alokasi

- Nama app default = nama sumber + bilangan bulat terkecil yang belum terpakai (dicek terhadap registry, filesystem, dan daftar database): `zahra` → `zahra2`, `zahra3`, …
- Nama database default = nama DB sumber + angka yang sama dengan nama app-nya.
- `REDIS_DB_ID` = angka bebas terkecil pada rentang 1–63 (DB 0 dicadangkan; installer menaikkan `databases 64` di `redis.conf`).

### 6.8 Relasi Entitas

```
1 registry app ── 1 vhost OLS ──── 1 direktori situs (VH_ROOT)
              ── 1 database MySQL ── 1 user MySQL
              ── 1 Redis DB ID ──── 1 Redis ACL user
              ── 0..1 sertifikat Let's Encrypt
              ── 1 access log terpisah
```

---

## 7. Design & Technical Constraints

### 7.1 Batasan Desain — "Low-End First" (1 vCPU / 1 GB RAM)

| Keputusan desain | Alasan |
|---|---|
| 100% Bash; tanpa panel web & daemon wajib | RAM idle = 0; tidak ada attack surface tambahan |
| Swap 2 GB dibuat otomatis saat instalasi (bila belum ada) | Mencegah OOM killer saat dump + rsync berjalan di RAM 1 GB |
| Proses berat dibungkus `nice -n 19` + `ionice -c3` | Situs live tetap responsif selama cloning |
| Dump DB streaming: `mysqldump --single-transaction --quick \| mysql` | Tanpa file SQL besar di disk; baca row-per-row, RAM minim |
| rsync lokal tanpa kompresi | Kompresi hanya membuang CPU pada 1 core |
| Clone sekuensial + lock file global | Menghindari kontensi resource dan proses ganda |
| Tuning MariaDB opsional (`innodb_buffer_pool_size=128M`, `performance_schema=OFF`) | Menghemat 200–300 MB RAM |
| Log per-app dibatasi (10 MB, 7 hari, terkompresi) | Hemat disk VPS kecil |

### 7.2 Batasan Teknis Platform

- Hanya mendukung OLS **instalasi manual** di `/usr/local/lsws`; lingkungan CyberPanel/aaPanel di luar cakupan v1 (struktur config berbeda total).
- Seluruh restart web server memakai mode **graceful**.
- SSL: metode **HTTP-01 webroot** saja; DNS wajib sudah pointing ke IP VPS sebelum penerbitan; wildcard/DNS-01 tidak didukung v1; tunduk pada rate limit Let's Encrypt (±5 sertifikat per set domain per minggu) — karenanya kegagalan tidak boleh memicu retry otomatis beruntun.
- Redis ≥ 6 wajib (fitur ACL); keterbatasan `SELECT` lintas-DB ditangani dengan isolasi prefix (§6.5).
- LSCWP: konfigurasi plugin ikut terbawa lewat database; kredensial Redis dan DB ID diperbarui via `wp litespeed-option`; purge all dijalankan pasca-clone.
- Penggantian URL memakai `wp search-replace` (bukan `sed`) agar aman terhadap serialized data PHP di database.
- Salts pada `wp-config.php` selalu digenerate ulang pada setiap clone agar sesi tidak bentrok antar app.
- Kompatibilitas: Bash ≥ 5 + coreutils standar Ubuntu; tanpa Python/Node/runtime tambahan.

### 7.3 Batasan Keamanan

- Hanya dapat dijalankan sebagai root (pemeriksaan EUID di awal setiap entry point).
- Seluruh file kredensial `chmod 600`; token dan password di-masking pada seluruh output log.
- Operasi destruktif (delete app, overwrite config) selalu berkonfirmasi ganda.
- Bot Telegram: whitelist chat ID ketat; pesan pihak lain diabaikan tanpa respons; v1 sepenuhnya **read-only**.
- Password dibangkitkan dari `/dev/urandom`, panjang ≥ 24 karakter.

### 7.4 Keterbatasan yang Diketahui

- Antarmuka berbahasa Indonesia (belum ada i18n).
- Kapasitas praktis ±60 web app per server (batas alokasi Redis DB ID 1–63).
- Tanpa backup terjadwal dan tanpa dukungan multi-server — kandidat versi berikutnya.

### 7.5 Keputusan Terbuka (Open Decisions)

| Topik | Status |
|---|---|
| Perintah aksi via Telegram (`/restart_ols`, `/clearcache <app>`, `/fixowner`) | **Ditunda** — v1 read-only. Masuk backlog v1.1, direncanakan dengan konfirmasi inline-button sebelum eksekusi |

---

## 8. Roadmap Pengembangan

| Fase | Cakupan | Keluaran yang bisa dipakai |
|---|---|---|
| **1 — Core** | Installer, registry, parser OLS, List Web Apps, engine Clone penuh (file + DB + patch vhconf + search-replace + purge LSCWP) | Clone berfungsi via HTTP |
| **2 — SSL & housekeeping** | SSL otomatis + Retry SSL, access log per app + viewer, Delete Web App | Clone langsung HTTPS |
| **3 — Isolasi** | PHP Settings per app, Redis ACL + DB ID, integrasi kredensial ke LSCWP | Antar-app terisolasi penuh |
| **4 — Tools & server** | Fix Ownership, Rebuild Config, Clear Cache, Web Server Settings, polish UI menu | Perawatan harian lengkap |
| **5 — Telegram** | Monitor alert (cron) → bot interaktif → integrasi ke installer | Monitoring & notifikasi aktif |

Estimasi total: **2.000–2.500 baris Bash** dalam satu repositori.

---

## 9. Risiko & Mitigasi

| Risiko | Dampak | Mitigasi |
|---|---|---|
| OOM killer saat clone di RAM 1 GB | Clone gagal di tengah jalan | Swap otomatis + dump streaming + `nice`/`ionice` |
| DNS belum pointing saat penerbitan SSL | Sertifikat gagal terbit | Non-blocking: app tetap live HTTP; menu Retry SSL; cek DNS sebelum memanggil certbot (hemat kuota rate limit) |
| `httpd_config.conf` korup saat penyuntingan | Seluruh situs down | Backup otomatis sebelum tiap perubahan + marker blok idempoten + fitur Rebuild Config |
| Duplikasi nama app / domain / database | Bentrok konfigurasi | Validasi wizard terhadap registry + filesystem + daftar database |
| Telegram API tidak terjangkau | Alert tidak terkirim | State insiden tetap tersimpan; pengiriman diulang pada siklus cron berikutnya |
| Kesalahan konfigurasi Redis ACL | Object cache miss | LSCWP fallback berjalan tanpa object cache — situs tetap hidup, hanya lebih lambat |
| Dua sesi `wpm` berjalan bersamaan | Race condition pada config | Lock file global untuk seluruh operasi tulis |

---

*Dokumen ini merupakan acuan final v1.0. Perubahan cakupan dicatat sebagai revisi dokumen dengan penambahan nomor versi.*
