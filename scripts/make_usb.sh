#!/usr/bin/env bash
# Write the CudaLite ISO to a USB stick AND add a FAT32 partition labelled RESULTS in the
# stick's free space, so one stick both boots the image and receives the benchmark results.
#
#   sudo scripts/make_usb.sh /dev/sdX [path/to/image.iso]
#
# ERASES the stick. Safety checks (it refuses to continue if any fails):
#   - target must be a whole disk, not a partition
#   - target must be a USB disk (override only for testing: ALLOW_NON_USB=1)
#   - no partition of it may be mounted (so the system disk can never be chosen by mistake)
#   - you must retype the device name
# Verified on a disk-image file: ISO data identical after the extra partition is added,
# boots via UEFI/GRUB as a USB device, and `mount -L RESULTS /mnt` works inside the live system.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="${1:-}"
ISO="${2:-$ROOT/build/live/cudalite-os-rtx4060.iso}"
die() { echo "REFUSING: $*" >&2; exit 1; }

[[ -n "$DEV" ]] || { echo "usage: sudo $0 /dev/sdX [image.iso]"; echo; lsblk -o NAME,SIZE,MODEL,TRAN,RM,MOUNTPOINTS | grep -v loop; exit 64; }
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
[[ -f "$ISO" ]] || die "ISO not found: $ISO"
[[ -b "$DEV" ]] || die "$DEV is not a block device"
TYPE="$(lsblk -dno TYPE "$DEV")"
if [[ "$TYPE" != "disk" && ! ( "$TYPE" == "loop" && "${ALLOW_NON_USB:-0}" == 1 ) ]]; then
    die "$DEV is a '$TYPE', not a whole disk (give e.g. /dev/sdb, not /dev/sdb1)"
fi
if [[ "${ALLOW_NON_USB:-0}" != 1 ]]; then
    [[ "$(lsblk -dno TRAN "$DEV")" == "usb" ]] || die "$DEV is not a USB disk (transport: '$(lsblk -dno TRAN "$DEV")')"
fi
lsblk -nro MOUNTPOINTS "$DEV" | grep -q . && die "something on $DEV is mounted; unmount it (or you picked the system disk)"

SIZE=$(blockdev --getsize64 "$DEV")
NEED=$(( $(stat -c%s "$ISO") + 64*1024*1024 ))
(( SIZE >= NEED )) || die "stick too small ($((SIZE/1048576)) MiB, need at least $((NEED/1048576)) MiB)"

echo "About to ERASE this device and write CudaLite OS to it:"
echo
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINTS "$DEV"
echo
read -r -p "Type the device name (e.g. sdb) to confirm, anything else aborts: " ANS
[[ "$ANS" == "$(basename "$DEV")" ]] || die "confirmation did not match; nothing was written"

echo "[1/4] writing the ISO..."
dd if="$ISO" of="$DEV" bs=4M conv=fsync status=progress
sync

echo "[2/4] adding the RESULTS partition in the free space..."
echo ',,L' | sfdisk --append "$DEV" >/dev/null
partprobe "$DEV" 2>/dev/null || true
udevadm settle

echo "[3/4] formatting RESULTS (FAT32)..."
PART="/dev/$(lsblk -nlo NAME,TYPE "$DEV" | awk '$2=="part"{p=$1} END{print p}')"
[[ -b "$PART" ]] || die "could not find the new partition"
mkfs.vfat -F32 -n RESULTS "$PART" >/dev/null

echo "[4/4] done."
sync
lsblk -o NAME,SIZE,FSTYPE,LABEL "$DEV"
echo
echo "Boot from this stick. To save results inside the live system:  sudo mount -L RESULTS /mnt"
