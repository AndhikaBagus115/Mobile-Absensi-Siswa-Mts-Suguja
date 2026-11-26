# 📱 Aplikasi Mobile Absensi & Presensi MTs Sunan Gunung Jati

![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?style=for-the-badge&logo=dart&logoColor=white)
![Backend](https://img.shields.io/badge/Backend-Supabase-3ECF8E?style=for-the-badge&logo=supabase&logoColor=white)
![Notifications](https://img.shields.io/badge/Push_Notif-OneSignal-E54B4D?style=for-the-badge&logo=onesignal&logoColor=white)
![Scanner](https://img.shields.io/badge/Scanner-Mobile_Scanner_v7-FF6F00?style=for-the-badge&logo=qrcode&logoColor=white)
![Design](https://img.shields.io/badge/UI-Material_3-7C3AED?style=for-the-badge&logo=materialdesign&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

> **Aplikasi Mobile Multi-Role berbasis Flutter (Android & iOS)** untuk Sistem Informasi Absensi & Presensi Sekolah MTs Sunan Gunung Jati. Dilengkapi dengan **Continuous QR/Barcode Scanner**, portal pemantauan siswa untuk Guru & Wali Kelas, persetujuan surat izin/sakit digital, sistem multi-anak untuk Wali Murid, serta integrasi **Push Notification OneSignal & Supabase Cloud**.

---

## 📌 Ringkasan Proyek

Aplikasi mobile ini dirancang sebagai solusi *mobile companion* yang komprehensif, modern, dan andal untuk operasional harian sekolah:
1. **Guru & Wali Kelas**: Mengelola presensi harian siswa per kelas, meninjau dan memvalidasi pengajuan surat izin/sakit, mengedit status kehadiran manual disertai catatan guru, serta memperbarui profil pribadi.
2. **Admin / Petugas Scanner Gerbang**: Melakukan pemindaian (*scan*) QR Code / Barcode kartu pelajar siswa secara cepat dan kontinu (*continuous scanning*) dengan verifikasi instan.
3. **Orang Tua / Wali Murid**: Memantau status kehadiran harian anak secara *real-time*, mengelola lebih dari satu anak (*multi-child switcher*), melihat statistik absensi bulanan & grafik kehadiran, menerima pengumuman resmi sekolah, serta mengajukan surat izin/sakit dengan lampiran foto terkompresi.

Aplikasi ini terhubung langsung secara *real-time* dengan database Supabase Cloud dan bekerja berdampingan dengan dashboard admin web/desktop **`SIM-Dasbor-Absensi-Mts-Suguja`**.

---

## 🌐 Ekosistem Arsitektur Sistem

```text
       ┌───────────────────────────────────────────────────────────┐
       │   💻 SIM-Dasbor-Absensi-Mts-Suguja (Web & Desktop Admin)   │
       └─────────────────────────────┬─────────────────────────────┘
                                     │
                                     ▼
                   ┌───────────────────────────────────┐
                   │    ☁️ SUPABASE CLOUD BACKEND       │
                   │  - PostgreSQL Database            │
                   │  - Row Level Security & Auth      │
                   │  - Storage (Foto Profil & Surat)  │
                   │  - Edge Functions Trigger         │
                   └───────────────┬─┬─────────────────┘
                                   │ │
                 ┌─────────────────┘ └─────────────────┐
                 │                                     │
                 ▼                                     ▼
   ┌───────────────────────────┐         ┌───────────────────────────┐
   │ 🔔 ONESIGNAL PUSH CLOUD   │         │ 📱 FLUTTER MOBILE APP     │
   │ - Real-time Attendance    │ ◄────── │ - Portal Guru & Wali Kls  │
   │ - Surat Approval Alerts   │         │ - Portal Wali Murid       │
   │ - Broadcast Pengumuman    │ ──────► │ - Continuous QR Scanner   │
   └───────────────────────────┘         └───────────────────────────┘
```

---

## 🚀 Fitur Unggulan Berdasarkan Peran

### 👨‍🏫 1. Portal Guru & Wali Kelas (`/features/auth`, `/features/kelas`, `/features/profil`)
* **Dashboard Interaktif & Ringkasan Harian**: Menampilkan statistik kehadiran (Hadir, Sakit, Izin, Alfa, Terlambat) secara langsung dengan *Animated Counter* dan sistem *Lifecycle Auto-Refresh*.
* **Manajemen Kelas & Rekap Siswa**: Filter daftar siswa berdasarkan kelas yang diampu atau seluruh kelas, pencarian siswa *instant debounce*, serta status kehadiran harian.
* **Edit Kehadiran Manual & Catatan Guru**: Penyesuaian status kehadiran siswa dengan tombol cepat (*Quick Pills*) dan input catatan keterangan guru.
* **Persetujuan Surat Izin & Sakit (`/features/persetujuan_surat`)**:
  * Tab filter status: *Menunggu*, *Disetujui*, *Ditolak*, dan *Semua*.
  * Preview foto lampiran surat dokter/keterangan dengan *pinch-to-zoom*.
  * Konfirmasi persetujuan/penolakan dengan catatan feedback yang otomatis terkirim ke orang tua melalui OneSignal.
* **Manajemen Profil Guru (`/features/profil`)**:
  * Ubah nama, kontak No. HP/WhatsApp, dan email.
  * Upload foto avatar profil dengan kompresi gambar otomatis (`flutter_image_compress`).
  * Ganti kata sandi akun secara aman.

---

### 📷 2. Continuous QR & Barcode Scanner (`/features/scanner`)
* **Continuous Scanning Engine**: Pemindaian kartu pelajar tanpa henti menggunakan pustaka performa tinggi `mobile_scanner` v7.
* **Per-NIS Smart Debounce**: Menghindari pemindaian ganda untuk siswa yang sama dalam interval waktu tertentu.
* **Visual & Haptic Feedback**: Animasi laser bergerak, border glowing indikator (hijau untuk hadir, oranye untuk pulang, merah untuk error), serta *haptic vibration*.
* **Popup Konfirmasi Cepat**: Menampilkan nama siswa, NIS, status, dan waktu scan secara instan tanpa menghentikan kamera.
* **Efisiensi Daya & Baterai**: Fitur *power-save timeout*, kontrol *torch/flashlight*, dan tombol *flip camera* (kamera depan/belakang).

---

### 👨‍👩‍👧 3. Portal Orang Tua / Wali Murid (`/features/wali`)
* **Login OTP Orangtua**: Masuk melalui email atau nomor HP yang didaftarkan sekolah. Anak ditautkan oleh admin di server; sesi dan cache privat memakai keystore/keychain.
* **Dukungan Multi-Anak (*Child Switcher Bar*)**: Memungkinkan orang tua yang memiliki lebih dari satu anak di sekolah untuk berpindah profil anak dengan satu ketukan, serta dialog *Tambah Anak*.
* **Kartu Presensi Live (*Live Attendance Card*)**:
  * Status kehadiran harian terkini (*Hadir, Terlambat, Pulang, Sakit, Izin, Alfa*).
  * Catatan guru, jam masuk, jam pulang, dan alasan penolakan jika surat ditolak.
* **Statistik & Grafik Kehadiran Bulanan**:
  * Visualisasi *interactive line chart* persentase kehadiran bulanan.
  * Kartu rekapitulasi total hadir, sakit, izin, dan alfa.
* **Feed Pengumuman Sekolah & Notifikasi (`/features/wali/wali_notifications_screen.dart`)**:
  * Kotak masuk pengumuman resmi sekolah terintegrasi database dan push inbox.
  * Filter otomatis pengumuman yang relevan berdasarkan tingkatan kelas anak.
  * Indikator pesan belum dibaca (*unread badge*) dan opsi tandai semua telah dibaca.
* **Pengajuan Surat Izin & Sakit Digital (`/features/wali/pengajuan_surat_screen.dart`)**:
  * Formulir jenis surat (*Izin* / *Sakit*) dengan kalender rentang tanggal (*Date Range*).
  * **Wajib unggah foto** untuk surat sakit (foto surat dokter/kuitansi klinik).
  * Kompresi foto cerdas otomatis sebelum diunggah ke Supabase Storage.
  * Riwayat dan pelacakan status pengajuan (*Menunggu, Disetujui, Ditolak*).

---

### 🔔 4. Sistem Notifikasi OneSignal & Background Service (`/data/services`)
* **Kejadian Presensi dan Keputusan Surat**: Klien mengirim jenis kejadian dan ID rekaman tersimpan ke Edge Function; server memeriksa pengirim, kelas, isi, dan penerimanya.
* **Identitas Orangtua**: Identitas OneSignal acak per akun dewasa dengan relasi anak di server. NIS dan tag SDK tidak menjadi dasar otorisasi.
* **Antrean dan Idempotensi**: Migrasi menyiapkan antrean kejadian, batas request, dan pencegahan pengiriman ulang. Secret pengiriman hanya berada di backend.
* **Penerapan Layanan**: Migrasi, deploy fungsi, key baru, dan uji penerimaan diperlukan sebelum integrasi dipakai. Trigger antrean tidak mengirim sendiri; jalur scanner/webhook perlu diverifikasi sesuai [panduan tahap 2](docs/SECURITY_STAGE_2.md).

---

## 🛠️ Stack Teknologi & Dependensi

| Komponen | Pustaka / Layanan | Fungsi & Keterangan |
| :--- | :--- | :--- |
| **Core Framework** | [Flutter 3.x](https://flutter.dev/) & Dart 3.x | Framework UI Multiplatform (Android & iOS) |
| **Backend & Database** | [`supabase_flutter`](https://pub.dev/packages/supabase_flutter) | PostgreSQL Database, Auth, Realtime, & Storage |
| **Push Notification** | [`onesignal_flutter`](https://pub.dev/packages/onesignal_flutter) | Subscription dengan identitas akun dari server |
| **State Management** | [`provider`](https://pub.dev/packages/provider) | Manajemen status aplikasi yang terstruktur & efisien |
| **QR/Barcode Scanner** | [`mobile_scanner`](https://pub.dev/packages/mobile_scanner) | Engine pemindai kamera responsif dan hemat daya |
| **Media & Kompresi** | [`image_picker`](https://pub.dev/packages/image_picker), [`flutter_image_compress`](https://pub.dev/packages/flutter_image_compress) | Pengambilan foto & kompresi cerdas sebelum upload |
| **Penyimpanan Privat** | [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) | Token dan cache privat per akun, dibatasi retensi dan dibersihkan saat logout |
| **Preferensi & File Lokal** | [`shared_preferences`](https://pub.dev/packages/shared_preferences), [`path_provider`](https://pub.dev/packages/path_provider) | Preferensi umum dan lokasi file sementara |
| **UI & Animasi** | [`flutter_animate`](https://pub.dev/packages/flutter_animate), `Material 3`, `Custom Painters` | Transisi halus, grafik custom, laser scanner, & micro-interactions |
| **Format & Lokalisasi**| [`intl`](https://pub.dev/packages/intl), `flutter_localizations` | Format tanggal & jam Bahasa Indonesia (`id_ID`) |
| **Optimasi Build** | R8 / ProGuard Code & Resource Shrinking | Ukuran APK yang ringkas, aman, dan performa tinggi |

---

## 📁 Struktur Direktori Proyek

Arsitektur aplikasi menerapkan pola **Feature-First Clean Architecture**:

```text
lib/
├── core/                               # Utilitas inti, tema, dan konstanta global
│   ├── constants.dart                  # Konfigurasi konstanta, tabel database, & warna tema
│   ├── exceptions.dart                 # Custom exceptions & ErrorFormatter ramah pengguna
│   └── ui/                             # Widget visual bersama (Reusable UI Components)
│       ├── animated_counter.dart       # Komponen angka animasi penghitung statistik
│       ├── bouncing_widget.dart        # Micro-interaction bouncing saat tombol ditekan
│       ├── scan_result_sheet.dart      # Popup bottom sheet hasil pemindaian scanner
│       ├── scanner_laser_overlay.dart  # Efek laser animasi & border scanner
│       └── status_selector_pills.dart  # Komponen pil selektor status kehadiran
│
├── data/                               # Lapisan data, model, repository, & service
│   ├── models/                         # Definisi model data (Type-Safe Dart Data Models)
│   │   ├── absensi.dart                # Model log absensi harian
│   │   ├── class_summary.dart          # Model ringkasan kehadiran kelas
│   │   ├── guru.dart                   # Model data guru & profil akun
│   │   ├── kelas.dart                  # Model rombel & informasi kelas
│   │   ├── siswa.dart                  # Model siswa & status akademik
│   │   ├── surat.dart                  # Model surat perizinan & approval
│   │   └── wali_murid_models.dart      # Model sesi wali, profil anak, & notifikasi
│   │
│   ├── repositories/                   # Lapisan query & transaksi database Supabase
│   │   ├── absensi_repository.dart     # Query absensi, summary, & pencatatan scan
│   │   ├── auth_repository.dart        # Autentikasi guru, session check, & update profil
│   │   ├── siswa_repository.dart       # Query daftar siswa per kelas
│   │   ├── surat_repository.dart       # Query pengajuan, histori, & persetujuan surat
│   │   └── wali_repository.dart        # Relasi anak terotorisasi, absensi, & pengumuman
│   │
│   └── services/                       # Integrasi service eksternal & backend
│       ├── onesignal_service.dart      # Inisialisasi, listener, & pengiriman push notification
│       ├── supabase_service.dart       # Singleton Supabase Client instance
│       ├── secure_storage_service.dart # Token dan cache terenkripsi per akun
│       ├── private_document_service.dart # Path surat dan URL sementara terotorisasi
│       └── wali_storage_service.dart   # Cache profil/absensi/inbox pada secure storage
│
├── features/                           # Modul-modul fitur aplikasi (Feature-First)
│   ├── auth/                           # Fitur Autentikasi & Dashboard Utama Guru
│   │   ├── auth_wrapper.dart           # Route dispatcher berdasarkan role sesi login
│   │   ├── dashboard_logic.dart        # State logic ringkasan dashboard guru
│   │   ├── dashboard_screen.dart       # Tampilan dashboard utama guru & drawer navigasi
│   │   └── form_login.dart             # Layar login dwifungsi (Tab Guru/Admin & Tab Wali)
│   │
│   ├── edit_siswa/                     # Fitur Edit Kehadiran Manual & Catatan Guru
│   │   ├── edit_siswa_logic.dart       # State handler update presensi & keterangan
│   │   └── edit_siswa_screen.dart      # Layar formulir ubah status & catatan siswa
│   │
│   ├── kelas/                          # Fitur Pemantauan Presensi Kelas
│   │   ├── kelas_logic.dart            # State logic daftar siswa & filter pencarian
│   │   └── kelas_screen.dart           # Layar list presensi siswa & quick action
│   │
│   ├── persetujuan_surat/              # Fitur Verifikasi & Approval Surat oleh Guru
│   │   └── persetujuan_surat_screen.dart # Tab pengajuan surat, review foto, & approval modal
│   │
│   ├── profil/                         # Fitur Akun & Pengaturan Profil Guru
│   │   └── profil_guru_screen.dart     # Layar edit profil, kontak, ganti password, & avatar
│   │
│   ├── scanner/                        # Fitur Continuous QR Code & Barcode Scanner
│   │   ├── scan_dashboard_screen.dart  # Layar beranda modul scanner admin
│   │   ├── scanner_dialog.dart         # Fullscreen dialog continuous camera scanner
│   │   └── scanner_widget.dart         # Widget kamera mobile_scanner & overlay controls
│   │
│   └── wali/                           # Fitur Portal Khusus Orang Tua / Wali Murid
│       ├── pengajuan_surat_screen.dart # Formulir upload surat izin/sakit & riwayat pengajuan
│       ├── wali_dashboard_screen.dart  # Beranda utama wali murid, multi-anak, & live status
│       ├── wali_notifications_screen.dart # Kotak masuk pengumuman sekolah & detail dialog
│       └── widgets/                    # Komponen modular khusus portal wali
│           ├── add_child_dialog.dart   # Pemilihan anak yang sudah ditautkan admin
│           ├── attendance_line_chart.dart # Custom widget grafik kehadiran bulanan
│           ├── child_switcher_bar.dart # Bar pemilihan profil anak aktif
│           ├── live_attendance_card.dart # Kartu status kehadiran hari ini real-time
│           └── monthly_stats_card.dart # Kartu rekapitulasi statistik kehadiran per bulan
│
└── main.dart                           # Entrypoint aplikasi, inisialisasi SDK, & setup tema
```

---

## ⚙️ Panduan Instalasi & Menjalankan Proyek

### 1. Prasyarat Sistem
* [Flutter SDK](https://docs.flutter.dev/get-started/install) **3.35.6**, dengan Dart **3.9.2**, sesuai lingkungan verifikasi build. Batas SDK Dart proyek adalah `^3.9.2`.
* JDK **17** untuk Android Gradle Plugin 8.9.1 dan Gradle 8.12.
* Android Studio / VS Code dengan ekstensi Flutter & Dart.
* Android SDK (API Level 21+) atau perangkat fisik Android/iOS dengan mode Developer diaktifkan.

### 2. Clone Repositori
```bash
git clone https://github.com/AndhikaBagus115/Mobile-Absensi-Siswa-Mts-Suguja.git
cd Mobile-Absensi-Siswa-Mts-Suguja
```

### 3. Konfigurasi Publik untuk Build
Salin file template `.env.example` menjadi `.env` pada root direktori:
```bash
cp .env.example .env
```

Buka `.env` dan isi hanya konfigurasi publik berikut:
```env
# Supabase Configuration
SUPABASE_URL=https://your-project-id.supabase.co
SUPABASE_ANON_KEY=your-anon-public-key
APP_ENVIRONMENT=development

# OneSignal Push Notification Configuration
ONESIGNAL_APP_ID=your-onesignal-app-id-uuid

```

Kemudian buat file konfigurasi yang diizinkan masuk ke build:

```bash
dart tool/configure_public.dart
```

Generator menulis `config/public.json` dengan allowlist empat nilai publik di atas. File `.env` tidak dibundel ke APK. Alternatifnya, salin `config/public.example.json` menjadi `config/public.json`. Kedua file konfigurasi lokal diabaikan Git. REST key OneSignal dan service-role key hanya disimpan di backend, sesuai [panduan penerapan tahap 2](docs/SECURITY_STAGE_2.md).

### 4. Install Dependensi
Jalankan perintah berikut untuk mengunduh semua pustaka yang dibutuhkan:
```bash
flutter pub get
```

### 5. Generate Icon Aplikasi *(Opsional)*
Jika ingin memperbarui ikon aplikasi launcher:
```bash
dart run flutter_launcher_icons
```

### 6. Jalankan Aplikasi

#### Mode Debug:
```bash
flutter run --dart-define-from-file=config/public.json
```

#### Build APK Release (Dengan optimasi ProGuard / R8):
```bash
flutter build apk --release --dart-define-from-file=config/public.json
```
File output APK siap pasang akan berada di: `build/app/outputs/flutter-apk/app-release.apk`.

### 7. Pemeriksaan Lokal

Setelah `flutter pub get`, jalankan dari root proyek:

```bash
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub --dart-define-from-file=config/public.json
```

APK debug berada di `build/app/outputs/flutter-apk/app-debug.apk`.

Test pada `test/` membuka aplikasi dengan Supabase sintetis, HTTP mock, dan penyimpanan dalam memori. Cakupannya mencakup OTP, penolakan sesi/cache palsu, relasi anak dari server, logout, lampiran privat, dan kontrak push. Tidak diperlukan akun sekolah atau koneksi backend. Test RLS dan Edge Function tersedia pada `supabase/tests/`; petunjuknya ada di [panduan keamanan tahap 2](docs/SECURITY_STAGE_2.md). Hasil lokal belum menggantikan uji API setelah migrasi diterapkan.

`android/gradle.properties` menonaktifkan Jetifier karena dependency saat ini sudah AndroidX. Ini menghindari transformasi ulang library Flutter yang sebelumnya kehabisan heap Java; batas heap dan jumlah worker tetap dibatasi untuk mesin dengan RAM terbatas. Evaluasi kembali kebutuhan Jetifier jika menambahkan dependency Android lama.

---

## 🔒 Hak Akses & Akun Demo Pengujian

| Peran (Role) | Metode Login | Target Tampilan Utama |
| :--- | :--- | :--- |
| **Guru / Wali Kelas** | Email & Password (Tab Guru) | Dashboard Guru, Rekap Kelas, Persetujuan Surat, Profil |
| **Admin Scanner** | Email & Password Akun Admin | Modul Continuous QR Code Scanner Gerbang |
| **Wali Murid** | OTP ke email/nomor HP terdaftar (Tab Wali Murid) | Dashboard Wali, Anak Tertaut, Live Attendance, Form Surat, Notifikasi |

---

## 👨‍💻 Kontributor & Lisensi

Dikembangkan dengan penuh dedikasi oleh **Andhika Bagus Satria** & Tim Pengembang Sistem Informasi Sekolah MTs Sunan Gunung Jati.

Proyek ini dilisensikan di bawah lisensi terbuka [MIT License](LICENSE).
