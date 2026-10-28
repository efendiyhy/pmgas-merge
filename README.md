# EK Air Quality Hub

**Laptop Server — Monitoring PM & Gas**  
By **EK Instrumentation** | Windows 10/11 | Python 3.9+ | Port `8787`

Dashboard lokal untuk menggabungkan data dari **dua alat ESP32 yang berbeda**: alat particulate matter (PM) dan alat monitoring gas. Keduanya mengirim data melalui Wi-Fi/LAN yang sama ke aplikasi di laptop. Aplikasi ini bukan firmware ESP32 dan tidak perlu diunggah melalui Arduino IDE.

> **Repository resmi:** https://github.com/efendiyhy/pmgas-merge

## Instalasi cepat — Windows PowerShell

1. Pastikan laptop terhubung ke internet.
2. Buka **Windows PowerShell** (bukan CMD).
3. Salin dan jalankan **satu perintah** berikut:

```powershell
irm https://raw.githubusercontent.com/efendiyhy/pmgas-merge/main/install.ps1 | iex
```

4. Setelah installer sukses, buka ikon **EK Air Quality Hub** di **Desktop** atau **Start Menu**. Dashboard otomatis dibuka di browser:

   **http://localhost:8787**

Installer mengunduh kode dari branch `main` pada repository ini, memeriksa Python **3.9 atau lebih baru**, dan mengabaikan `python.exe` yang rusak, alias Windows, maupun virtual environment yang tidak lengkap (termasuk error `No pyvenv.cfg file`). Jika tidak ditemukan instalasi Python normal, installer mencoba memasang Python 3.13 melalui `winget`. Apabila Python tidak dapat dipasang otomatis, instal dari [python.org](https://www.python.org/downloads/) lalu jalankan ulang perintah di atas.

**Perhatian:** `irm ... | iex` mengunduh dan langsung menjalankan skrip PowerShell. Jalankan hanya setelah memeriksa sumber dan isi [`install.ps1`](./install.ps1). Koneksi internet diperlukan pada saat instalasi.

### Lokasi aplikasi dan data

| Item | Lokasi |
|---|---|
| Instalasi aplikasi | `%LOCALAPPDATA%\EKInstrumentation\LaptopServer` |
| Database lokal | `%LOCALAPPDATA%\EKInstrumentation\LaptopServer\data\monitoring.sqlite3` |
| Rekaman CSV | `%LOCALAPPDATA%\EKInstrumentation\LaptopServer\data\records` |
| Log aplikasi | `%LOCALAPPDATA%\EKInstrumentation\LaptopServer\data\logs` |
| Akses dashboard | `http://localhost:8787` |

Installer **tidak menghapus atau menimpa folder `data/` saat pembaruan**.

## Menghubungkan alat PM dan Gas ke laptop

1. Jalankan **EK Air Quality Hub** di laptop.
2. Sambungkan **laptop, ESP32 PM, dan ESP32 Gas ke jaringan Wi-Fi/router yang sama**.
3. Pada laptop, buka PowerShell lalu ketik `ipconfig`. Cari **IPv4 Address** pada adapter Wi-Fi aktif, misalnya `192.168.1.100`.
4. Di dashboard web ESP32 PM, pada pengaturan **Laptop Server**, masukkan **alamat IP saja**, misalnya `192.168.1.100`. Simpan lalu aktifkan pengiriman ke laptop.
5. Ulangi langkah yang sama pada dashboard web ESP32 Gas.
6. Lihat enam grafik realtime di dashboard laptop. Jika tidak ada data, pastikan Windows Firewall mengizinkan Python melalui jaringan **Private** untuk TCP port **8787**.

Alamat penerima data dibentuk otomatis oleh firmware ESP32:

```text
http://192.168.1.100:8787/api/ingest
```

`192.168.1.100` hanyalah contoh; pakai IP laptop sendiri. Jika IP laptop berubah setelah pindah router, perbarui IP yang disimpan di kedua ESP32. **Jangan membuka port server ini ke internet publik.**

## Fitur

- **Dashboard:** enam grafik realtime — PM1, PM2.5, PM10, CO, CO₂, NO₂.
- **Pilihan grafik:** Data Asli, MA 10, MA 20, MA 50, MA 100. Moving Average hanya mengubah *tampilan grafik*; data tersimpan tetap asli.
- **Suhu dan kelembapan:** widget lingkaran menampilkan rata-rata dari pembacaan alat PM dan Gas ketika keduanya tersedia.
- **Record:** sesi rekaman dengan nama yang dapat ditentukan, durasi manual atau berhenti otomatis.
- **Label:** ubah label seperti `RPM1000` → `RPM2000` selama sesi masih berjalan; perubahan berlaku pada pembacaan berikutnya dan masuk ke CSV.
- **Riwayat & Ekspor:** unduh CSV gabungan berdasarkan waktu pengukuran sensor, CSV per sesi, atau CSV mentah.
- **Tema:** enam pilihan pada **Pengaturan → Tema Tampilan**: Brutal Light, Brutal Dark, Modern Light, Modern Dark, Scientific, dan Midnight. Pilihan tersimpan pada browser.
- **Sidebar:** klik ikon `☰` untuk mengecilkan sidebar menjadi ikon, atau klik lagi untuk memperbesar. Pilihan tetap diingat di browser.
- **Grafik popup:** klik tombol `⛶` di kanan judul tiap grafik untuk memperbesar. Grafik terus diperbarui setiap 1 detik dan mengikuti Data Asli / MA yang dipilih. Tutup dengan `✕ TUTUP`, `Esc`, atau klik bagian gelap di luar popup.
- **Penyimpanan:** SQLite dan ekspor CSV di satu folder `data/`.

**Catatan data:** server menyimpan data yang masuk ke SQLite meskipun tombol Record tidak aktif; tombol Record digunakan untuk menetapkan sesi dan label. Data PM dan Gas pada ekspor gabungan dipasangkan berdasarkan **timestamp pengukuran**, bukan waktu paket tiba. Bila waktunya tidak cocok, sebagian kolom bisa kosong agar tidak memasangkan pembacaan yang salah.

## Update tampilan REV11 (tanpa perubahan firmware)

Untuk pengguna yang sudah menginstal aplikasinya, **hentikan server**, lalu cukup ganti file `index.html` di folder `%LOCALAPPDATA%\EKInstrumentation\LaptopServer`. Mulai lagi aplikasi melalui shortcut, dan tekan `Ctrl+F5` pada browser.

Jika update melalui GitHub, push file `index.html` dan `README.md` dari patch REV11 ke branch `main`, lalu jalankan ulang installer biasa. File `install.ps1` dan `launch.ps1` REV10 tetap digunakan; `data/` tidak ditimpa dan firmware PM/Gas tidak perlu di-flash ulang.

## Update versi aplikasi

1. Hentikan sesi rekaman dengan tombol **STOP**.
2. Jalankan kembali perintah instalasi yang sama:

```powershell
irm https://raw.githubusercontent.com/efendiyhy/pmgas-merge/main/install.ps1 | iex
```

3. Buka lagi shortcut **EK Air Quality Hub**. Installer mengambil file terbaru dari branch `main` sambil mempertahankan folder data lokal.

Untuk berjaga-jaga, backup `data/` sebelum pembaruan besar. Jangan jalankan dua server pada port yang sama.

## Penghapusan seluruh data lokal

Buka dashboard dari **`http://localhost:8787` di laptop server**, kemudian masuk ke **Pengaturan → Hapus Semua Data Lokal**.

- Hentikan rekaman aktif terlebih dahulu.
- Ikuti konfirmasi, ketik `HAPUS SEMUA`, dan masukkan kata sandi awal **`ekinstru`**.
- Data di SQLite, riwayat sesi, CSV lokal, dan backup migrasi yang disimpan aplikasi akan dihapus. **Data microSD ESP32 dan Supabase tidak ikut terhapus.**

Password awal di atas dapat diketahui siapa pun karena berada di repository publik. Untuk penggunaan di luar jaringan lab tepercaya, ganti melalui variabel lingkungan **`EK_DELETE_PASSWORD`** sebelum server dijalankan. Server ini bukan layanan yang dirancang untuk diekspos langsung ke internet.

## Menjalankan tanpa installer

Unduh / clone repository, pastikan Python 3.9+ terpasang, kemudian jalankan dari folder yang berisi `server.py`:

```powershell
python server.py
```

Buka `http://localhost:8787`. Tidak diperlukan `pip install` karena server menggunakan pustaka standar Python. Perintah manual ini tidak membuat shortcut aplikasi.

## Migrasi database dari versi lama

Jika Anda sudah pernah menggunakan REV5–REV8, **backup dulu database dan file CSV lama**. REV9 dapat memigrasikan `monitoring.sqlite3` serta folder `records/` yang berada di sebelah `server.py` ke dalam `data/` ketika server dijalankan dari folder tersebut. Untuk instalasi melalui `irm` pada lokasi baru, matikan server lama dan pindahkan data dengan hati-hati ke direktori aplikasi yang baru sebelum server pertama kali berjalan.

Jangan langsung menimpa SQLite baru yang sudah berisi pengukuran; ekspor data lama terlebih dahulu atau lakukan migrasi khusus.

## Uninstall — Windows (aman untuk data)

1. Jika sesi Record sedang aktif, tekan **STOP** terlebih dahulu.
2. Tutup jendela PowerShell/terminal yang menjalankan server, lalu tutup tab browser dashboard.
3. Buka **Windows PowerShell** dan jalankan perintah ini (tidak memerlukan `irm`):

```powershell
& "$env:LOCALAPPDATA\EKInstrumentation\LaptopServer\uninstall.ps1"
```

Uninstaller menghapus shortcut **EK Air Quality Hub** dari Desktop dan Start Menu serta file program utamanya. **Folder `data/` (SQLite dan CSV) tetap dipertahankan** agar hasil pengukuran tidak hilang. Python yang terpasang di Windows tidak ikut dihapus.

Jika Anda **juga ingin menghapus semua data pengukuran lokal**, pastikan data sudah diekspor dan dicadangkan terlebih dahulu. Setelah server berhenti dan uninstaller dijalankan, barulah jalankan perintah opsional berikut:

```powershell
Remove-Item -LiteralPath "$env:LOCALAPPDATA\EKInstrumentation\LaptopServer\data" -Recurse -Force
```

**PERINGATAN:** Perintah kedua menghapus permanen database, riwayat, serta CSV lokal. Perintah tersebut tidak diperlukan untuk uninstall biasa. Data pada SD card ESP32 serta Supabase tidak ikut dihapus.

Jika file `uninstall.ps1` belum ada karena instalasi yang sangat lama, unduh versi terbaru dari repository atau salin `uninstall.ps1` ke folder aplikasi tersebut terlebih dahulu.

---

**EK Instrumentation** · Project: [`efendiyhy/pmgas-merge`](https://github.com/efendiyhy/pmgas-merge)

## Jika muncul `No pyvenv.cfg file` pada laptop lain

Pesan ini menunjukkan bahwa salah satu `python.exe` yang dideteksi tidak dapat berjalan dengan benar, misalnya bekas virtual environment atau instalasi Python yang tidak lengkap. **Tidak berkaitan dengan firmware ESP32 PM/Gas atau sensor.**

Perbaikan tersedia pada `install.ps1` versi ini. Setelah mengunggah **`install.ps1` dan `launch.ps1` baru** ke branch `main`, buka PowerShell baru pada laptop yang bermasalah, lalu ulangi:

```powershell
irm https://raw.githubusercontent.com/efendiyhy/pmgas-merge/main/install.ps1 | iex
```

Versi ini melewati kandidat Python yang gagal dijalankan, mencari Python normal lain, atau memasang Python lewat `winget`. Folder `data/` lama tidak dihapus. Jika masih gagal, jalankan `py -0p` dan `where.exe python` untuk memeriksa instalasi Python, lalu lakukan **Repair** Python melalui Windows Settings atau instal versi resmi dari python.org.

Catatan: jika repository belum diperbarui di GitHub, perintah `irm` tetap menjalankan installer lama.
