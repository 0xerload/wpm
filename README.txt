================================================================================
WPM — WordPress Manager untuk OpenLiteSpeed
================================================================================

WPM adalah tool manajemen WordPress berbasis terminal untuk server
OpenLiteSpeed. Fungsi intinya: meng-clone web app WordPress secara massal
(file, database, vhost, SSL, cache) lewat wizard bermenu, ditambah perkakas
perawatan harian dan monitoring resource via bot Telegram.

100% Bash. Tidak ada panel web, tidak ada daemon wajib — konsumsi RAM saat
idle adalah nol. Lihat PRD-WPM.md untuk spesifikasi lengkap.


--------------------------------------------------------------------------------
1. PRASYARAT
--------------------------------------------------------------------------------

Sebelum memasang WPM, komponen berikut HARUS sudah terpasang dan berjalan
secara manual (WPM tidak memasangkan ini untuk Anda):

  - Ubuntu 24.04 LTS
  - OpenLiteSpeed, terpasang di /usr/local/lsws
  - MariaDB atau MySQL (sudah berjalan)
  - Minimal satu versi lsphp (mis. lsphp82)
  - Redis >= 6.0 (wajib — dipakai fitur ACL per app)
  - Akses root
  - Spesifikasi minimum: 1 vCPU, 1 GB RAM

Yang AKAN dipasangkan otomatis oleh installer: certbot, rsync, wp-cli, curl,
jq, cron (paket-paket kecil, bukan komponen inti di atas).

Jika salah satu komponen wajib di atas belum ada, install.sh akan berhenti
dan menampilkan daftar yang kurang secara spesifik.

1.1 One-click installer untuk prasyarat (opsional)
----------------------------------------------------
Belum punya OpenLiteSpeed/MariaDB/lsphp/Redis sama sekali di VPS baru? Ada
script terpisah, install-prereqs.sh, yang memasangkan keempatnya sekaligus
di atas Ubuntu 24.04 LTS bersih:

    sudo ./install-prereqs.sh

atau langsung lewat curl (tanpa perlu clone repo dulu):

    bash <(curl -sL https://raw.githubusercontent.com/<user>/<repo>/main/install-prereqs.sh)

Script ini memakai installer resmi OpenLiteSpeed (ols1clk.sh dari
litespeedtech/ols1clk) untuk memasang OpenLiteSpeed + lsphp82 (+ MariaDB
bila belum ada database yang berjalan sama sekali, TANPA contoh WordPress
— WPM mengelola WordPress lewat clone, bukan lewat instalasi contoh), lalu
memasang Redis via apt. Setiap komponen yang sudah ada otomatis dilewati,
jadi aman dijalankan ulang. Password root database yang dibuatkan akan
otomatis tersimpan di /etc/wpm/.secrets supaya install.sh nanti tidak
perlu menanyakannya lagi.

Variabel environment opsional (semua punya default yang masuk akal):

    WPM_LSPHP_VERSION   Versi lsphp (default: 82; pilihan lain: 74 80 81 83 84 85)
    WPM_DB_ENGINE       mariadb (default) atau mysql
    WPM_DB_ROOT_PASS    Password root database (default: acak 24 karakter)
    WPM_OLS_ADMIN_PASS  Password WebAdmin OLS (default: acak 24 karakter)
    WPM_SKIP_OLS=1      Lewati instalasi OpenLiteSpeed/lsphp
    WPM_SKIP_DB=1       Lewati instalasi database
    WPM_SKIP_REDIS=1    Lewati instalasi Redis
    WPM_ASSUME_YES=1    Lewati konfirmasi awal (otomatis aktif bila dijalankan non-interaktif)

Setelah script ini selesai, lanjutkan ke bagian 2 (INSTALASI) di bawah
untuk memasang WPM itu sendiri.

Jika Anda sudah punya server dengan sebagian/seluruh komponen ini
terpasang manual, lewati install-prereqs.sh dan langsung ke bagian 2.


--------------------------------------------------------------------------------
2. INSTALASI
--------------------------------------------------------------------------------

Cara paling aman — clone repo lalu jalankan installer lokal:

    git clone <url-repo-wpm-anda>.git wpm
    cd wpm
    sudo ./install.sh

Cara one-click (curl), bila Anda sudah meng-host repo ini di GitHub:

    bash <(curl -sL https://raw.githubusercontent.com/<user>/<repo>/main/install.sh)

  Catatan: karena file install.sh saja tidak membawa lib/, templates/,
  monitor.sh, bot.sh, dan wpm, mode curl-langsung ini butuh tahu ke mana
  harus mengunduh source lengkapnya. Set salah satu variabel environment
  berikut sebelum menjalankan perintah di atas:

    WPM_REPO_SLUG=<owner>/<repo>            # contoh: WPM_REPO_SLUG=someuser/wpm
    WPM_REPO_REF=<branch-atau-tag>          # default: main
    WPM_TARBALL_URL=<url-.tar.gz-langsung>  # override total, kalau bukan GitHub

  Contoh lengkap:

    WPM_REPO_SLUG=someuser/wpm bash <(curl -sL https://raw.githubusercontent.com/someuser/wpm/main/install.sh)

install.sh akan, secara berurutan:

  1. Memastikan dijalankan sebagai root, di Ubuntu 24.04 LTS persis.
  2. Mendeteksi OpenLiteSpeed / MariaDB-MySQL / lsphp / Redis — berhenti
     dengan pesan jelas bila ada yang belum siap.
  3. Memasang paket pendukung yang belum ada (certbot, rsync, wp-cli, curl,
     jq, cron).
  4. Meminta kredensial root database — dilewati otomatis bila /root/.my.cnf
     sudah ada. Kredensial diverifikasi dengan koneksi nyata sebelum
     disimpan ke /etc/wpm/.secrets (mode 600).
  5. Menawarkan (semua boleh dilewati, tekan Enter untuk default):
       - Swap 2GB (mencegah OOM saat clone di RAM 1GB)
       - Tuning MariaDB untuk RAM rendah (innodb_buffer_pool_size=128M,
         performance_schema=OFF)
       - Redis "databases" dinaikkan ke 64 (mendukung hingga ~60 app)
     Pengaturan aclfile Redis (untuk fitur Redis ACL per app) dipasang
     otomatis dan wajib, tidak bisa dilewati.
  6. Menyalin lib/, templates/, monitor.sh, bot.sh ke /usr/local/share/wpm
     dan wpm ke /usr/local/bin/wpm.
  7. Membuat direktori /etc/wpm, /etc/wpm/apps, /var/lib/wpm, /var/log/wpm
     dengan permission yang benar, plus kebijakan logrotate mingguan.
  8. Memasang cron alert monitor (/etc/cron.d/wpm-monitor, tiap 60 detik)
     dan unit systemd wpm-bot.service (ditulis tapi TIDAK diaktifkan
     otomatis — nyalakan lewat menu bila ingin memakai bot Telegram).
  9. Memindai vhost OpenLiteSpeed yang sudah ada secara manual dan
     menawarkan untuk mengimpornya ke registry WPM.
  10. Menawarkan setup wizard Telegram (boleh dilewati, bisa disetel
      belakangan lewat menu 6).

Setelah selesai, jalankan tool dengan:

    wpm


--------------------------------------------------------------------------------
3. PEMAKAIAN — MENU UTAMA
--------------------------------------------------------------------------------

Jalankan `wpm` sebagai root. Anda akan melihat menu:

    1) List Web Apps
    2) Clone Web App
    3) Kelola Web App
    4) Tools
    5) Web Server Settings (OpenLiteSpeed)
    6) Telegram & Monitoring
    0) Keluar

Pilih dengan mengetik angka lalu Enter. Hampir semua prompt punya nilai
default — tekan Enter saja untuk memakainya.

  wpm --version    Menampilkan versi WPM lalu keluar.
  wpm --help       Menampilkan bantuan singkat lalu keluar.


3.1 List Web Apps
------------------
Menampilkan tabel seluruh web app yang terdaftar: nama, domain, docroot,
database, versi PHP, status SSL, ukuran disk. Jika ada vhost OpenLiteSpeed
yang dibuat manual dan belum terdaftar di WPM, akan ditampilkan terpisah
dengan opsi untuk mengimpornya — setelah diimpor, app tersebut bisa dipakai
sebagai sumber clone. Menu ini murni baca, tidak mengunci apa pun.


3.2 Clone Web App (fitur inti)
--------------------------------
Wizard: pilih app sumber -> jumlah salinan (N) -> untuk tiap salinan, isi
nama app / nama database (Enter = default dengan akhiran angka otomatis,
mis. zahra -> zahra2, zahra3, ...) / domain (wajib, divalidasi unik) ->
ringkasan rencana -> konfirmasi -> eksekusi berurutan satu app per satu.

Tiap app melewati pipeline 8 langkah: salin file (rsync, exclude cache) ->
buat database + user baru -> import data (streaming, tanpa file SQL di
disk) -> patch wp-config.php (kredensial baru + salt baru + kredensial
Redis baru) -> search-replace URL lama ke URL baru -> salin & patch
konfigurasi vhost + restart graceful -> perbaiki ownership -> terbitkan SSL
otomatis (bila DNS sudah pointing) + pasang ACL Redis + sinkron ke plugin
cache + purge cache.

Jika langkah 1-7 gagal: app tersebut di-rollback otomatis (dibersihkan) dan
proses lanjut ke app berikutnya dalam antrian. Jika hanya SSL yang gagal
(biasanya karena DNS belum pointing): app TETAP LIVE di HTTP — bukan
kegagalan clone — tinggal jalankan Retry SSL nanti.


3.2b Clone dari Folder Staging (sumber alternatif)
-----------------------------------------------------
Selain meng-clone dari app yang sudah terdaftar & hidup di server ini,
wizard "2) Clone Web App" juga menerima sumber lain: folder staging berisi
snapshot file WordPress + dump SQL mentah (bukan app yang sedang berjalan)
— misalnya hasil export dari server lain, atau template situs yang mau
dipakai berulang kali.

Struktur folder yang harus disiapkan lebih dulu (WPM hanya membaca, tidak
membuatkan isinya):

    /var/lib/wpm/stag/<nama-sumber>/data/   isi docroot WordPress lengkap
                                             (termasuk wp-config.php)
    /var/lib/wpm/stag/<nama-sumber>/db/     satu atau lebih file .sql atau
                                             .sql.gz

Contoh: /var/lib/wpm/stag/mei_26/data/ dan /var/lib/wpm/stag/mei_26/db/.

Kalau dump SQL dipecah jadi beberapa file, urutan importnya mengikuti urutan
nama file (alfabetis) — beri prefix angka kalau butuh urutan tertentu, mis.
01-schema.sql lalu 02-data.sql.

Catatan penting: $table_prefix di data/wp-config.php harus SUDAH cocok
dengan prefix tabel yang benar-benar ada di dump SQL-nya — WPM tidak
menyentuh $table_prefix sama sekali, hanya men-sync define()
DB_NAME/DB_USER/DB_PASSWORD + salt baru + kredensial Redis baru ke
wp-config.php, persis seperti clone dari app biasa.

Domain lama untuk search-replace URL TIDAK ditanya manual — WPM
mendeteksinya otomatis lewat wp-cli (wp option get siteurl) dari data
staging itu sendiri, setelah database-nya diimpor.

Versi PHP untuk app hasil clone dari staging memakai satu default tetap
untuk semua sumber staging (bukan ditanya di wizard tiap kali) — atur lewat
menu "5) Web Server Settings" > "PHP Default untuk Clone dari Staging".

Cara pakai: di wizard "2) Clone Web App", langkah pertama sekarang bertanya
sumbernya:

    Sumber clone: 1) App terdaftar   2) Folder staging

Pilih 2, lalu pilih salah satu sumber staging yang terdeteksi. Sisanya sama
persis dengan clone dari app terdaftar: jumlah salinan, nama app/database
per salinan, domain, ringkasan rencana, konfirmasi, sampai laporan akhir.


3.3 Kelola Web App
-------------------
Pilih salah satu app terdaftar, lalu:

  1) PHP Settings   — terapkan preset atau atur manual 5 parameter PHP,
                      atau ganti versi lsphp bila terpasang lebih dari satu.

                      Preset:
                        Low    (default 1GB RAM): memory 128M, upload/post
                                32M/34M, max_execution_time 60s
                        Normal: memory 256M, upload/post 64M/68M, 120s
                        High:   memory 512M, upload/post 128M/136M, 300s

  2) Redis ACL      — lihat kredensial (user/password/DB ID), regenerate
                      password, enable/disable user Redis app tersebut.
                      Tiap app punya user Redis sendiri, dibatasi hanya
                      key dengan prefix miliknya, perintah berbahaya
                      diblok.

  3) Lihat Access Log — tail log secara live (Ctrl+C untuk kembali ke
                      menu), Top 10 IP, Top 10 URL, ringkasan status code.

  4) Retry SSL      — coba terbitkan/pasang ulang sertifikat Let's Encrypt
                      untuk app yang SSL-nya belum aktif/gagal.

  5) Delete Web App — hapus total (config, file, database, ACL Redis,
                      sertifikat, entry registry). Konfirmasi ganda (y/N
                      lalu ketik ulang nama app), dengan opsi backup
                      .tar.gz sebelum menghapus.


3.4 Tools
----------
Pilih app, lalu:

  1) Fix Ownership          — perbaiki kepemilikan & permission file/folder.
  2) Rebuild Web App Config — bangun ulang konfigurasi vhost dari snapshot
                              atau registry (data situs tidak disentuh).
  3) Clear Web App Cache    — hapus cache file (wp-content/cache,
                              litespeed) dan flush Redis DB milik app
                              tersebut saja — app lain tidak terpengaruh.


3.5 Web Server Settings (OpenLiteSpeed)
-----------------------------------------
  1) Restart / Reload Graceful       — tanpa memutus koneksi aktif.
  2) Ganti Port & Password WebAdmin  — ganti port console WebAdmin (default
                                        7080) dan/atau reset passwordnya.
  3) Preset Tuning Low-End           — terapkan preset koneksi untuk VPS
                                        1 vCPU/1GB RAM.
  4) Edit httpd_config.conf          — buka file config langsung di editor
                                        (backup otomatis sebelum dibuka,
                                        restart graceful setelah disimpan).


3.6 Telegram & Monitoring
---------------------------
  1) Setup bot                      — masukkan token dari @BotFather, chat
                                       ID terdeteksi otomatis (cukup kirim
                                       /start ke bot Anda), diakhiri pesan
                                       tes.
  2) Atur threshold alert           — ubah ambang load/RAM/swap/disk,
                                       interval re-alert, auto-restart
                                       service yang down, label nama
                                       server.
  3) Nyalakan/matikan alert monitor — toggle cron /etc/cron.d/wpm-monitor.
  4) Nyalakan/matikan bot interaktif — toggle systemd wpm-bot.service.
  5) Kirim tes notifikasi           — kirim pesan tes ke chat Telegram
                                       yang sudah disetel.


--------------------------------------------------------------------------------
4. MONITORING & TELEGRAM BOT
--------------------------------------------------------------------------------

Ada dua komponen terpisah, bisa dinyalakan/dimatikan sendiri-sendiri:

  - Alert monitor (cron, wajib untuk notifikasi otomatis)
    Berjalan tiap 60 detik lewat /etc/cron.d/wpm-monitor, memeriksa load
    average, RAM, swap, disk, dan status service (OLS/MariaDB/Redis).
    Tanpa proses residen — RAM idle = 0. Default threshold:

      Load average (5 menit) : > jumlah core x 2.0
      RAM                    : alert di atas 90%, pulih di bawah 78%
      Swap                   : alert di atas 60%, pulih di bawah 45%
      Disk /                 : alert di atas 85%
      Re-alert               : tiap 30 menit selama masih tinggi

    Alert hanya dikirim saat AMBANG DILEWATI (bukan tiap menit), dan
    notifikasi RECOVERED dikirim setelah turun ke bawah ambang pulih
    (hysteresis), lengkap dengan durasi insiden.

  - Bot interaktif (systemd, opsional, ~5MB RAM saat aktif)
    Bisa dimatikan total tanpa memengaruhi alert monitor di atas. Perintah
    yang didukung (read-only, v1 tidak ada perintah aksi/destruktif):

      /uptime   Uptime server + load average
      /stats    Snapshot lengkap: uptime, load, RAM, swap, disk, status service
      /apps     Daftar web app + ukuran disk + status SSL
      /status   Status service OLS / MariaDB / Redis
      /help     Daftar perintah

    Bot hanya merespons chat ID yang sudah di-whitelist saat setup — pesan
    dari chat lain diabaikan tanpa balasan.


--------------------------------------------------------------------------------
5. LOKASI FILE PENTING
--------------------------------------------------------------------------------

  /usr/local/bin/wpm                     Perintah utama
  /usr/local/share/wpm/                  lib/, templates/, monitor.sh, bot.sh
  /etc/wpm/apps/<nama-app>.conf          Registry per app (600)
  /etc/wpm/apps/<nama-app>.vhconf.snap   Snapshot config vhost ("last known good")
  /etc/wpm/.secrets                      Kredensial root database (600)
  /etc/wpm/telegram.conf                 Token, chat ID, threshold alert (600)
  /var/lib/wpm/stag/                     Sumber staging (<nama>/data, <nama>/db)
  /etc/wpm/staging.conf                  Versi PHP default untuk clone-dari-staging (600)
  /etc/redis/users.acl                   ACL user Redis per app
  /etc/cron.d/wpm-monitor                Jadwal alert monitor (tiap menit)
  /etc/systemd/system/wpm-bot.service    Unit bot Telegram interaktif
  /var/lib/wpm/monitor.state             State anti-spam alert
  /var/log/wpm/wpm.log                   Log aktivitas (rotasi mingguan)


--------------------------------------------------------------------------------
6. YANG PERLU DIKETAHUI SEBELUM DIPAKAI DI SERVER PRODUKSI
--------------------------------------------------------------------------------

  - WPM hanya mendukung OpenLiteSpeed instalasi manual di /usr/local/lsws —
    tidak untuk CyberPanel/aaPanel.
  - SSL memakai metode HTTP-01 webroot saja; domain harus sudah pointing ke
    IP VPS sebelum penerbitan berhasil; tunduk pada rate limit Let's
    Encrypt, jadi kegagalan tidak otomatis di-retry berkali-kali — gunakan
    menu Retry SSL secara manual.
  - Tidak ada backup terjadwal — backup hanya ditawarkan saat menghapus
    app (opsional).
  - Satu instalasi WPM hanya mengelola satu VPS (bukan multi-server).
  - Kapasitas praktis sekitar 60 web app per server (batasan alokasi Redis
    DB ID, 1-63).
  - Kode ini sudah lolos pemeriksaan sintaks (bash -n / shellcheck) dan
    review konsistensi/keamanan statis, tetapi belum pernah dijalankan
    melawan OpenLiteSpeed/MariaDB/Redis/Telegram sungguhan. Uji dulu
    dengan satu app berisiko rendah sebelum dipakai di situs produksi.


--------------------------------------------------------------------------------
7. STRUKTUR REPOSITORI
--------------------------------------------------------------------------------

  wpm/
  |-- install-prereqs.sh  One-click installer prasyarat (OLS, DB, lsphp, Redis)
  |-- install.sh          One-click installer WPM itu sendiri
  |-- wpm                 Entry point + menu utama
  |-- monitor.sh          Checker alert (dijalankan cron)
  |-- bot.sh              Listener Telegram (daemon opsional)
  |-- lib/
  |   |-- core.sh         Util umum: warna, prompt, logging, lock, validasi
  |   |-- ols.sh          Parser & penulis config OpenLiteSpeed, restart
  |   |-- clone.sh        Engine cloning (pipeline 8 langkah + rollback)
  |   |-- ssl.sh          Cek DNS, certbot, pemasangan SSL, retry
  |   |-- redis.sh        ACL, alokasi DB ID, sinkron kredensial ke LSCWP
  |   |-- php.sh          phpIniOverride, preset, versi lsphp
  |   |-- tools.sh        Fix ownership, rebuild config, clear cache
  |   `-- telegram.sh     Kirim pesan, format stats/alert, setup wizard
  |-- templates/
  |   `-- vhssl.tpl       Blok SSL untuk config vhost
  `-- PRD-WPM.md          Spesifikasi produk lengkap
