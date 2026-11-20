# AUTO-SSD-BOOT-STB-ARMBIAN

Script bash untuk Armbian (ophub, Amlogic S905X) yang memindahkan root filesystem dari eMMC ke SSD SATA via USB. Script mendeteksi rootfs SSD secara otomatis dan menyinkronkan `root=` di `uEnv.txt` pada partisi boot eMMC.

## Latar belakang

Pada setup ini, U-Boot tetap dimuat dari eMMC dan membaca `uEnv.txt` dari partisi boot eMMC (`mmcblk2p1`, label `BOOT_EMMC`). Kernel dan initramfs juga dibaca dari sana. Rootfs (`/`) dipindahkan ke SSD (`sda2`, label `ROOTFS`).

## Struktur repo

```
.
├── auto-ssd-boot.sh   # script utama
├── README.md
└── LICENSE            # opsional (MIT)
```

## Persyaratan

- Armbian (ophub) dengan U-Boot yang membaca `uEnv.txt` dari eMMC
- SSD SATA via adapter USB yang sudah berisi sistem Armbian lengkap (partisi `ROOTFS` ext4 berisi `/etc/fstab`)
- Dijalankan sebagai root

## Pemakaian

```bash
chmod +x auto-ssd-boot.sh

# Cek apa yang akan diubah, tanpa menulis apa pun
sudo ./auto-ssd-boot.sh --dry-run

# Terapkan perubahan
sudo ./auto-ssd-boot.sh

# Kembalikan uEnv.txt ke versi asli eMMC
sudo ./auto-ssd-boot.sh --restore
```

Setelah menerapkan perubahan, reboot lalu cek:

```bash
cat /proc/cmdline | grep -o 'root=[^ ]*'
findmnt / -o SOURCE
```

## Yang dilakukan script

1. Mencari partisi boot eMMC (label `BOOT_EMMC`, fallback ke vfat `mmcblk*`).
2. Mencari rootfs SSD (label `ROOTFS`, fallback ke ext4 non-eMMC yang berisi `/etc/fstab` dan `/usr`).
3. Membandingkan `root=UUID=...` di `uEnv.txt` dengan UUID SSD. Menambahkan `rootdelay=10` jika belum ada.
4. Membuat backup bertanggal sebelum menulis, dan menyimpan `uEnv.txt.orig` (dibuat sekali sebagai referensi asli).
5. Memverifikasi hasil tulis.

Script tidak menyentuh `mmcblk2boot0`, `mmcblk2boot1`, atau `mmcblk2` secara langsung, dan tidak memakai `dd`.

## Batasan

- Script hanya mengubah `uEnv.txt`. Jika kernel (`zImage`, `uInitrd`, dtb) di SSD dan eMMC berbeda, tidak disinkronkan.
- Jika SSD tidak terpasang, boot akan gagal menemukan root. Pastikan rootfs eMMC tetap utuh sebagai cadangan, dan gunakan `--restore` untuk kembali.
- Script tidak menjalankan `update-initramfs`. Setelah mengganti kernel atau modul USB, initramfs perlu dibuat ulang.
- Hanya diuji pada layout partisi dan label yang digunakan di setup ini.

## Troubleshooting

- **Boot masuk ke `initramfs` atau panic**: cabut SSD lalu boot dari eMMC, kemudian jalankan `--restore`.
- **`/proc/cmdline` tidak berubah setelah reboot**: pastikan script sudah menulis ke partisi yang dibaca U-Boot (`BOOT_EMMC`), dan cek `findmnt /boot`.
- **`/boot` menunjuk SSD**: itu wajar setelah `fstab` SSD dipakai. `uEnv.txt` yang dibaca U-Boot tetap ada di partisi eMMC.

## Peringatan

Mengubah konfigurasi boot berisiko membuat perangkat tidak bisa boot. Selalu siapkan backup dan akses fallback sebelum menjalankan script.

## Lisensi

MIT (atau sesuaikan dengan lisensi yang kamu pilih di GitHub).
