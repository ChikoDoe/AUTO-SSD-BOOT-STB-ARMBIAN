#!/bin/bash
# auto-ssd-boot.sh
# Deteksi rootfs SSD (ext4 berisi /etc/fstab) dan sinkronkan root= di uEnv.txt eMMC.
#
# Pemakaian:
#   sudo ./auto-ssd-boot.sh              # cek dan terapkan jika perlu
#   sudo ./auto-ssd-boot.sh --dry-run    # hanya tampilkan apa yang akan diubah
#   sudo ./auto-ssd-boot.sh --restore    # kembalikan uEnv.txt ke versi asli eMMC
set -euo pipefail

DRY_RUN=0
RESTORE=0
ROOTDELAY=10
EMMC_MNT=/mnt/emmc_boot
PROBE_MNT=/mnt/ssd_probe

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --restore) RESTORE=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Opsi tidak dikenal: $arg" >&2; exit 1 ;;
  esac
done

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Jalankan sebagai root"

cleanup() {
  mountpoint -q "$PROBE_MNT" && umount "$PROBE_MNT" || true
  mountpoint -q "$EMMC_MNT"  && umount "$EMMC_MNT"  || true
}
trap cleanup EXIT

# 1. Temukan partisi boot eMMC (berdasarkan label, fallback ke mmcblk*p1)
EMMC_BOOT_DEV=$(blkid -L BOOT_EMMC 2>/dev/null || true)
if [ -z "$EMMC_BOOT_DEV" ]; then
  EMMC_BOOT_DEV=$(blkid -o device -t TYPE=vfat | grep '^/dev/mmcblk' | head -n1 || true)
fi
[ -n "$EMMC_BOOT_DEV" ] || die "Partisi boot eMMC tidak ditemukan"
log "Boot eMMC      : $EMMC_BOOT_DEV"

# 2. Temukan rootfs SSD
find_ssd_root() {
  local dev
  # Prioritas: label ROOTFS (bukan ROOTFS_EMMC)
  dev=$(blkid -L ROOTFS 2>/dev/null || true)
  if [ -n "$dev" ] && [[ "$dev" != /dev/mmcblk* ]]; then
    echo "$dev"; return 0
  fi
  # Fallback: scan semua ext4 non-eMMC yang punya /etc/fstab dan /usr
  while read -r dev; do
    [[ "$dev" == /dev/mmcblk* ]] && continue
    mkdir -p "$PROBE_MNT"
    if mount -o ro "$dev" "$PROBE_MNT" 2>/dev/null; then
      if [ -f "$PROBE_MNT/etc/fstab" ] && [ -d "$PROBE_MNT/usr" ]; then
        umount "$PROBE_MNT"
        echo "$dev"; return 0
      fi
      umount "$PROBE_MNT"
    fi
  done < <(blkid -o device -t TYPE=ext4)
  return 1
}

SSD_DEV=$(find_ssd_root) || die "Rootfs SSD tidak ditemukan"
SSD_UUID=$(blkid -s UUID -o value "$SSD_DEV")
[ -n "$SSD_UUID" ] || die "UUID SSD tidak terbaca"
log "Rootfs SSD    : $SSD_DEV (UUID=$SSD_UUID)"

# Pastikan UUID ini memang ada di fstab SSD (sanity check)
CUR_ROOT_SRC=$(findmnt -no SOURCE / || true)
if [ "$CUR_ROOT_SRC" = "$SSD_DEV" ]; then
  FSTAB_FILE=/etc/fstab
else
  mkdir -p "$PROBE_MNT"
  mount -o ro "$SSD_DEV" "$PROBE_MNT"
  FSTAB_FILE="$PROBE_MNT/etc/fstab"
fi
grep -q "UUID=$SSD_UUID" "$FSTAB_FILE" || log "PERINGATAN: UUID SSD tidak ada di fstab SSD (cek manual)"
if mountpoint -q "$PROBE_MNT"; then umount "$PROBE_MNT"; fi

# 3. Mount boot eMMC dan baca uEnv.txt
mkdir -p "$EMMC_MNT"
mountpoint -q "$EMMC_MNT" || mount "$EMMC_BOOT_DEV" "$EMMC_MNT"
UENV="$EMMC_MNT/uEnv.txt"
[ -f "$UENV" ] || die "uEnv.txt tidak ada di boot eMMC"

# Simpan salinan asli sekali saja (sebagai referensi untuk --restore)
if [ ! -f "$EMMC_MNT/uEnv.txt.orig" ]; then
  cp -a "$UENV" "$EMMC_MNT/uEnv.txt.orig"
  log "Salinan asli disimpan: uEnv.txt.orig"
fi

if [ "$RESTORE" -eq 1 ]; then
  log "Mengembalikan uEnv.txt dari uEnv.txt.orig"
  [ "$DRY_RUN" -eq 1 ] && { log "(dry-run) tidak ada perubahan"; exit 0; }
  cp -a "$EMMC_MNT/uEnv.txt.orig" "$UENV"
  sync
  log "Selesai. Reboot untuk memakai config asli."
  exit 0
fi

CUR_APPEND=$(grep '^APPEND=' "$UENV" || true)
[ -n "$CUR_APPEND" ] || die "Baris APPEND= tidak ditemukan di uEnv.txt"
CUR_ROOT_UUID=$(echo "$CUR_APPEND" | grep -o 'root=UUID=[^ ]*' | head -n1 | cut -d= -f3- || true)
log "root= di uEnv  : ${CUR_ROOT_UUID:-<tidak ada>}"

# 4. Bangun APPEND baru
NEW_APPEND="$CUR_APPEND"
if [ -n "$CUR_ROOT_UUID" ]; then
  NEW_APPEND=$(echo "$NEW_APPEND" | sed "s|root=UUID=$CUR_ROOT_UUID|root=UUID=$SSD_UUID|")
else
  NEW_APPEND=$(echo "$NEW_APPEND" | sed "s|^APPEND=|APPEND=root=UUID=$SSD_UUID |")
fi
if ! echo "$NEW_APPEND" | grep -q "rootdelay="; then
  NEW_APPEND=$(echo "$NEW_APPEND" | sed "s|^APPEND=|APPEND=rootdelay=$ROOTDELAY |")
fi

if [ "$NEW_APPEND" = "$CUR_APPEND" ]; then
  log "uEnv.txt sudah sesuai dengan SSD. Tidak ada perubahan."
  exit 0
fi

log "Perubahan:"
log "  lama: $CUR_APPEND"
log "  baru: $NEW_APPEND"

if [ "$DRY_RUN" -eq 1 ]; then
  log "(dry-run) tidak ada perubahan yang ditulis"
  exit 0
fi

# 5. Backup bertanggal, lalu tulis
cp -a "$UENV" "$EMMC_MNT/uEnv.txt.$(date +%Y%m%d-%H%M%S).bak"
TMP=$(mktemp "$EMMC_MNT/.uenv.XXXX")
grep -v '^APPEND=' "$UENV" > "$TMP" || true
echo "$NEW_APPEND" >> "$TMP"
# Pertahankan urutan: APPEND di posisi semula
awk -v new="$NEW_APPEND" '
  /^APPEND=/ { print new; next }
  { print }
' "$UENV" > "$TMP"
cat "$TMP" > "$UENV"
rm -f "$TMP"
sync

# 6. Verifikasi
VERIFY=$(grep -o 'root=UUID=[^ ]*' "$UENV" | head -n1 | cut -d= -f3-)
[ "$VERIFY" = "$SSD_UUID" ] || die "Verifikasi gagal: root di uEnv = $VERIFY"
log "Berhasil. uEnv.txt sekarang menunjuk ke SSD. Reboot untuk menerapkan."
