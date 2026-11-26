# Penerapan keamanan tahap 2

Lingkup: S01, S02, S03, S04, S05, dan S07. Perubahan backend dalam repository ini **belum diterapkan ke layanan sekolah**. Panduan ini ditujukan kepada admin yang akan menerapkannya sendiri. Laporan dan bukti lokal tetap berada di `audit/`.

## Perubahan yang harus diterapkan bersama

| Bagian | Perubahan |
| --- | --- |
| Aplikasi Flutter | OTP orangtua, relasi anak dari server, konfigurasi publik melalui Dart defines, keystore/keychain, lampiran melalui URL 60 detik, tanpa REST key/fallback push |
| Migrasi 001 | RLS per keluarga/kelas, perlindungan role guru, penutupan grant anonim/kolom dan RPC lama, view memakai izin pemanggil, bucket surat privat |
| Migrasi 002 | Identitas push acak per akun dewasa, antrean kejadian tersimpan, batas 120 request/menit/pengirim, lease dan idempotensi |
| Edge Function | Menerima identitas kejadian saja; memverifikasi pengguna, kelas, dan kejadian sebelum server menentukan penerima dan isi |
| Layanan | Akun orangtua dan kontak terdaftar, pengiriman OTP, REST key OneSignal baru, pencabutan key lama |

Migrasi mengubah akses untuk **semua aplikasi yang memakai project Supabase ini**, termasuk admin web terpisah. RPC lama pada schema `public` dicabut dari `anon`/`authenticated`; aplikasi mobile memakai RPC baru berawalan `siab_`. Sesuaikan pemanggil lain sebelum penerapan. Jangan memberi kembali izin ke RPC `SECURITY DEFINER` lama tanpa meninjau isi dan batas aksesnya. Lihat [RLS dan fungsi database Supabase](https://supabase.com/docs/guides/database/postgres/row-level-security).

## 1. Periksa schema dan jadwalkan penerapan

1. Buat backup database/schema melalui mekanisme Supabase yang biasa digunakan sekolah.
2. Jalankan [00_preflight.sql](../supabase/ops/00_preflight.sql) di SQL Editor. Script ini hanya membaca metadata dan tidak menampilkan isi tabel atau source fungsi yang mungkin memuat secret.
3. Tinjau tipe ID, relasi kelas, `guru.role`, struktur JSON `kelas_diampu`, policy, grant kolom, view, RPC, dan trigger yang terdaftar. Schema sumber lengkap sebelumnya tidak tersedia dalam repository; kecocokan nama kolom saja belum membuktikan seluruh definisi server cocok.
4. Tinjau trigger lama melalui dashboard secara lokal. Migrasi berhenti bila ada trigger `SECURITY DEFINER` pada tabel sekolah yang belum ditinjau. Ganti fungsinya dengan versi yang membatasi aktor atau memakai izin pemanggil. Periksa juga webhook/pengiriman OneSignal lama agar tidak berjalan paralel dengan jalur baru.
5. Uji pada project staging/salinan schema terlebih dahulu, lalu lakukan penerapan dalam jendela pemeliharaan bersama pembaruan aplikasi. Aplikasi lama yang hanya memakai NIS tidak memperoleh jalur kompatibilitas anonim.

Project memerlukan PostgreSQL 15+. ID guru memakai UUID Auth; ID siswa/kelas/absensi/surat berupa bilangan bulat. `kelas_diampu` berbentuk objek JSON berisi array nama kelas, misalnya `{"IX":["9A"]}`. Perbedaan schema harus diselesaikan sebelum menerapkan migrasi.

## 2. Terapkan kedua migrasi berurutan

Jalankan isi file berikut di SQL Editor, satu file hingga selesai sebelum file berikutnya:

1. [202611260001_access_and_private_storage.sql](../supabase/migrations/202611260001_access_and_private_storage.sql)
2. [202611260002_authorized_push_events.sql](../supabase/migrations/202611260002_authorized_push_events.sql)

Masing-masing file memakai transaksi. Bila terjadi error, hentikan penerapan dan perbaiki penyebabnya; jangan menyalin hanya sebagian statement atau melonggarkan policy untuk melewati error. Bila perlu mengulang, jalankan kembali **keduanya dalam urutan yang sama**. Schema `siab_private` harus tetap di luar daftar **Exposed schemas** pada pengaturan Data API.

Periksa di Storage bahwa bucket `surat_keterangan` berstatus **private**, dengan upload JPG/PNG maksimal 5 MB. Path baru berbentuk `<siswa_id>/<nama_acak>.jpg`; path lama `pengajuan/surat_<id>_...` dan `absensi/<id>_...` tetap dapat dikenali oleh policy. URL publik lama pada baris surat diperlakukan sebagai referensi path oleh aplikasi baru; aplikasi meminta URL terotorisasi baru saat gambar dibuka. Pembatasan bucket mengikuti [Storage access control](https://supabase.com/docs/guides/storage/security/access-control).

Bucket `avatars` dipisahkan untuk foto profil. Bucket ini dapat bersifat publik, dan bukan tempat menyimpan surat. Aplikasi tidak lagi mengunggah avatar ke bucket surat. Avatar lama yang terlanjur berada di bucket surat perlu dipindahkan melalui Storage API/dashboard atau diunggah ulang ke `avatars`; jangan memindahkan file hanya dengan mengubah baris `storage.objects`.

## 3. Daftarkan akun orangtua dan kontak OTP

1. Buat akun orangtua di **Authentication → Users** menggunakan email atau nomor HP yang sudah diverifikasi sekolah. Jangan menyediakan pendaftaran publik untuk menautkan siswa. Pada permintaan OTP, aplikasi memakai `shouldCreateUser: false`.
2. Aktifkan metode OTP yang dipakai sekolah. Email memerlukan SMTP yang berfungsi dan template pesan berisi `{{ .Token }}` agar pengguna memperoleh kode, bukan hanya magic link. Nomor HP memakai SMS dan memerlukan provider yang dikonfigurasi pada Supabase Auth.
3. Gunakan panjang kode **6 angka**, masa berlaku singkat yang disepakati sekolah, serta rate limit Auth yang sesuai. Aplikasi membatasi kirim ulang selama 60 detik; batas server tetap wajib karena klien dapat dimodifikasi.
4. Pastikan custom JWT hook, bila ada, mempertahankan claim `amr`. Akses orangtua memerlukan metode `otp` pada sesi; sesi password saja tidak membuka data anak.
5. Ambil UUID akun dari dashboard, lalu tautkan siswa lewat SQL Editor. Ganti seluruh placeholder berikut dengan data yang telah disetujui sekolah:

```sql
begin;
insert into public.siab_wali_accounts(user_id, active)
values ('UUID_AKUN_ORANGTUA'::uuid, true)
on conflict(user_id) do update set active=true;

insert into public.siab_wali_students(wali_id, siswa_id)
select 'UUID_AKUN_ORANGTUA'::uuid, id from public.siswa
where nis='NIS_SISWA_YANG_DISETUJUI'
on conflict do nothing;
commit;
```

Pastikan satu siswa yang dimaksud ditemukan; jangan mengandalkan nama yang dapat sama. Untuk beberapa anak, tambahkan relasi bagi setiap siswa yang telah disetujui. Menu pemilihan anak di aplikasi hanya memilih relasi yang sudah ada; memasukkan NIS tidak menambah hak akses.

Pencabutan hubungan dilakukan dengan menghapus baris yang tepat pada `siab_wali_students`. Menonaktifkan seluruh akses orangtua dilakukan dengan `siab_wali_accounts.active=false`. Uji perubahan ini melalui API dengan sesi pengguna, bukan hanya dari dashboard admin. Rujukan alur kode OTP: [permintaan OTP Flutter](https://supabase.com/docs/reference/dart/auth-signinwithotp) dan [verifikasi OTP](https://supabase.com/docs/reference/dart/auth-verifyotp).

## 4. Rotasi key OneSignal dan deploy fungsi

1. Di OneSignal, buat App API key pengganti untuk aplikasi yang sesuai. Simpan key baru hanya pada backend.
2. Salin [backend.env.example](../supabase/backend.env.example) menjadi `supabase/backend.env`, lalu isi App ID dan key baru. `*.env` diabaikan Git; jangan memasukkan nilai tersebut ke kode Flutter, Dart defines, screenshot, atau chat.
3. Setelah CLI Supabase terpasang dan login pada akun admin, jalankan:

```powershell
supabase link --project-ref PROJECT_REF_ANDA
supabase secrets set --env-file supabase/backend.env
supabase functions deploy send-push
```

Runtime hosted Supabase menyediakan `SUPABASE_URL`, `SUPABASE_ANON_KEY`, dan `SUPABASE_SERVICE_ROLE_KEY`. Jangan menyalin service-role key ke konfigurasi aplikasi. Konfigurasi fungsi mempertahankan `verify_jwt=true`; handler juga memverifikasi token melalui Auth, lalu SQL memeriksa role dan kelas aktor.

4. Uji alur penerapan dengan akun dan siswa khusus uji. Setelah backend baru siap, **cabut key lama yang pernah ada dalam APK** di OneSignal; menghapusnya dari source tidak membatalkan key tersebut. Hapus salinannya dari `.env` frontend dan arsip distribusi yang tidak lagi diperlukan sesuai kebijakan sekolah.

Kontrak request baru:

```json
{"event_type":"attendance","record_id":123}
```

`event_type` hanya `attendance` atau `letter_decision`; `record_id` menunjuk rekaman yang sudah tersimpan. Field isi pesan, `app_id`, target user, tag, dan segment dari pemanggil ditolak. Pesan ditentukan server dan tidak memasukkan nama/NIS/alasan kesehatan ke teks notifikasi.

Trigger hanya menambahkan antrean setelah perubahan data tersimpan. Trigger ini **tidak mengirim notifikasi sendiri**. Pemanggilan fungsi mengklaim kejadian terbaru yang cocok, memeriksa guru/admin yang berwenang, dan memakai relasi orangtua aktif saat menentukan penerima. Event tanpa penerima tidak dilaporkan berhasil. `accepted=true` berarti request diterima provider atau sudah pernah diterima; bukan bukti perangkat telah menampilkan pesan. Integrasi pengiriman scanner/webhook dan uji penerimaan nyata tetap harus diverifikasi pada alur terkait.

Identitas OneSignal baru adalah nilai acak server per akun dewasa, tanpa alias NIS atau ID siswa. Mapping tidak dibaca oleh klien lain atau guru; Edge Function memakai service role untuk mengambil target. Flutter SDK yang digunakan belum mendukung token identity verification OneSignal secara penuh. Jangan mengaktifkan toggle JWT identity verification untuk SDK ini tanpa implementasi yang kompatibel; lihat [dokumentasi OneSignal](https://documentation.onesignal.com/docs/en/identity-verification). Jangan menjadikan tag/alias SDK sebagai sumber keputusan akses database.

## 5. Konfigurasi dan build aplikasi baru

```powershell
flutter pub get
dart tool/configure_public.dart
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub --dart-define-from-file=config/public.json
```

Generator membaca `.env` lokal dan menulis **empat konfigurasi publik yang diizinkan** ke `config/public.json`: URL Supabase, anon/publishable key, OneSignal App ID, dan environment aplikasi. Key lain dibuang. File `.env` tidak lagi menjadi aset APK. Alternatifnya, salin `config/public.example.json` dan isi keempat nilai publik secara manual.

Untuk menjalankan aplikasi:

```powershell
flutter run --dart-define-from-file=config/public.json
```

Pembaruan pertama membersihkan cache orangtua dan sesi plaintext versi lama; pengguna perlu masuk lagi. Token disimpan melalui [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage/versions/10.3.4), cache privat dipisahkan per akun dan dibatasi 24 jam, backup cloud/transfer Android dibatasi melalui [aturan backup Android](https://developer.android.com/identity/data/autobackup), dan logout menghapus cache serta melepaskan identitas push. Uji upgrade dan logout pada perangkat sasaran sebelum distribusi.

## 6. Verifikasi setelah penerapan

Jalankan [01_verify_after_deploy.sql](../supabase/ops/01_verify_after_deploy.sql), lalu lakukan pemeriksaan berikut melalui API/perangkat:

| Skenario | Hasil yang harus diperoleh |
| --- | --- |
| Tanpa sesi: SELECT siswa/guru/kelas/absensi/surat/pengumuman | Tidak memperoleh baris privat, termasuk lewat view/RPC lama |
| Orangtua A: ganti ID ke anak B dalam kelas yang sama | Data dan lampiran B tidak tersedia |
| Guru 9A: minta kelas lain atau ubah `role`/`kelas_diampu` sendiri | Akses ditolak/tidak ada baris; cakupan tidak berubah |
| Akun orangtua belum ditautkan atau dinonaktifkan | Dashboard anak tidak terbuka |
| Orangtua memakai sesi password tanpa OTP | Data anak ditolak |
| URL publik lampiran lama, tanpa header apa pun | Tidak mengembalikan file |
| URL sementara lampiran | Berfungsi untuk pemegangnya selama maksimal 60 detik; gagal setelah kedaluwarsa |
| Push anonim/orangtua/guru lintas kelas atau payload segment bebas | Ditolak sebelum request OneSignal |
| Pengiriman ulang kejadian yang sama | Idempotency key tetap sama; tidak mengirim ulang setelah sukses |
| Logout dan restart aplikasi | Tidak membuka anak dari cache; token/cache privat tidak muncul sebagai plaintext |
| Inspeksi APK/AAB | Tidak ada aset `.env` maupun REST/service-role key |

Test lokal backend tidak menghubungi layanan sekolah atau OneSignal:

```powershell
npx --yes deno test --config supabase/deno.json --allow-read --allow-write --allow-env supabase/tests/
```

Suite PostgreSQL memakai fixture sintetis dengan policy lama yang sengaja terlalu permisif; itu bukan salinan database sekolah. **Jangan menjalankan `supabase/tests/fixture.sql` pada layanan sekolah.** Hasil lokal belum menggantikan pemeriksaan grant/trigger dan uji API setelah penerapan.

Panduan ini tidak menutup S06, transaksi/keputusan surat, cache harian, race pergantian anak, atau signing rilis. Perbaikan tersebut mengikuti tahap selanjutnya. Bila penerapan bermasalah, pertahankan pembatasan data dan perbaiki konfigurasi; jangan mengembalikan akses anonim, bucket surat publik, atau REST key ke klien.
