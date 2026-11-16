#!/usr/bin/env bash
# Build the CudaLite OS bootable ISO from this repository.
#
#   scripts/build_iso.sh            incremental: re-run package/includes/hook stages on the
#                                   existing chroot (fast; use while iterating)
#   scripts/build_iso.sh --clean    from scratch: wipe chroot+binary, re-bootstrap Debian 13
#                                   (downloaded .debs in build/live/cache are reused)
#   scripts/build_iso.sh --skip-bench   don't rebuild the CUDA binaries first
#
# Needs sudo (chroot, mksquashfs) and, once, the host patch in scripts/patch_live_build.sh.
# Host: Ubuntu with live-build 3.0~a57, debootstrap, squashfs-tools, xorriso, grub-pc-bin,
# grub-efi-amd64-bin, mtools, nvidia-cuda-toolkit, g++-13.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build/live"
ISO_OUT="$BUILD_DIR/cudalite-os-rtx4060.iso"
LOG="$ROOT/build.log"

CLEAN=0; SKIP_BENCH=0
for a in "$@"; do
    case "$a" in
        --clean) CLEAN=1 ;;
        --skip-bench) SKIP_BENCH=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown option $a"; exit 64 ;;
    esac
done

step() { printf '\n\033[1m[%s] %s\033[0m\n' "$1" "$2"; }

# ---- sudo: authenticate once and keep it alive for the (long) chroot stage ------------
sudo -n true 2>/dev/null || sudo -v
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
KEEPALIVE=$!

# Unmount anything still mounted under the chroot (an interrupted lb run leaves
# proc/sys/dev mounts behind, and a later `rm -rf chroot` would then reach into the host).
unmount_chroot() {
    findmnt -rn -o TARGET | grep "^$BUILD_DIR/chroot" | sort -r | xargs -r -n1 sudo umount -l 2>/dev/null || true
}
cleanup() { kill "$KEEPALIVE" 2>/dev/null || true; unmount_chroot; }
trap cleanup EXIT

cd "$BUILD_DIR"
unmount_chroot

step 0/7 "Host prerequisites"
"$ROOT/scripts/patch_live_build.sh"
for tool in lb mksquashfs grub-mkrescue xorriso debootstrap; do
    command -v "$tool" >/dev/null || { echo "missing host tool: $tool"; exit 1; }
done

step 1/7 "CUDA binaries -> config/includes.chroot/usr/local/bin"
if [[ $SKIP_BENCH -eq 0 ]]; then "$ROOT/scripts/build_benchmark.sh"; fi
[[ -x config/includes.chroot/usr/local/bin/cudalite-benchmark ]] || { echo "benchmark binary not staged"; exit 1; }
chmod 0755 config/includes.chroot/usr/local/bin/*

step 2/7 "live-build configuration (auto/config)"
# earlier sudo runs leave root-owned stage files; `lb config` runs unprivileged
sudo chown -R "$USER:$USER" .build config 2>/dev/null || true
lb config

step 3/7 "Debian 13 chroot (packages, includes, hooks)"
# stdin must NOT be a terminal: sudo gives the command a pty, and apt-get inside the chroot then
# calls tcsetattr() on it, which stops it (SIGTTOU) and hangs the whole build after "tzdata" is upgraded.
if [[ $CLEAN -eq 1 ]]; then
    sudo lb clean --all </dev/null
    sudo lb bootstrap </dev/null 2>&1 | tee "$LOG"
    sudo lb chroot </dev/null 2>&1 | tee -a "$LOG"
else
    sudo rm -f chroot/sbin/start-stop-daemon.orig
    sudo find .build -maxdepth 1 \( -name 'chroot*' -o -name 'includes.chroot*' \) -delete
    sudo lb chroot </dev/null 2>&1 | tee "$LOG"
fi
unmount_chroot
ls chroot/boot/vmlinuz-* >/dev/null 2>&1 || { echo "no kernel in chroot"; exit 1; }
ls chroot/lib/modules/*/updates/dkms/nvidia-current.ko* >/dev/null 2>&1 \
    || { echo "FATAL: nvidia-current.ko missing from chroot"; exit 1; }

step 4/7 "SquashFS root filesystem (xz)"
sudo mkdir -p binary/live binary/boot/grub
sudo rm -f binary/live/filesystem.squashfs
# kernel+initrd are shipped uncompressed next to the squashfs, so leave their copies out of it
sudo mksquashfs chroot binary/live/filesystem.squashfs -comp xz -b 1M -Xdict-size 100% -noappend \
    -wildcards -e 'boot/vmlinuz-*' -e 'boot/initrd.img-*' 2>&1 | tail -3

step 5/7 "Kernel, initramfs, GRUB menu"
sudo cp -f chroot/boot/vmlinuz-*   binary/live/vmlinuz
sudo cp -f chroot/boot/initrd.img-* binary/live/initrd.img
sudo tee binary/boot/grub/grub.cfg >/dev/null <<'EOG'
set timeout=3
set default=0
set gfxpayload=keep

menuentry "CudaLite OS (Debian 13 / NVIDIA CUDA, RTX 4060)" {
    linux /live/vmlinuz boot=live components hostname=cudalite username=cudauser modprobe.blacklist=nouveau
    initrd /live/initrd.img
}
menuentry "CudaLite OS - nomodeset fallback (if the display stays black)" {
    linux /live/vmlinuz boot=live components hostname=cudalite username=cudauser modprobe.blacklist=nouveau nomodeset
    initrd /live/initrd.img
}
EOG

step 6/7 "Hybrid BIOS+UEFI ISO"
sudo rm -f "$ISO_OUT"
sudo grub-mkrescue -V CUDALITE_OS -o "$ISO_OUT" binary/ 2>&1 | tee -a "$LOG" | tail -5
[[ -f "$ISO_OUT" ]] || { echo "ERROR: ISO not created at $ISO_OUT"; exit 1; }
sudo chown "$USER:$USER" "$ISO_OUT"

step 7/7 "Checksum, package manifest, versions"
mkdir -p "$ROOT/docs"
( cd "$BUILD_DIR" && sha256sum "$(basename "$ISO_OUT")" ) | tee "$ROOT/docs/image.sha256"
dpkg-query --admindir="$BUILD_DIR/chroot/var/lib/dpkg" -W -f='${binary:Package}\t${Version}\n' \
    | sort > "$ROOT/docs/package-manifest.tsv"
{
    echo "built (UTC) : $(date -u -Is)"
    echo "live-build  : $(lb --version 2>/dev/null || true)"
    echo "host        : $(uname -srm) / $(. /etc/os-release; echo "$PRETTY_NAME")"
    echo "host gcc    : $(g++-13 --version | head -n1)   host nvcc: $(nvcc --version | tail -n1)"
    echo "debian      : $(cat chroot/etc/debian_version)"
    echo "kernel pkg  : $(grep -P '^linux-image-\d' "$ROOT/docs/package-manifest.tsv" | tr '\t' ' ')"
    for p in nvidia-kernel-dkms libcuda1 nvidia-smi firmware-nvidia-gsp nvidia-modprobe systemd dkms gcc-14 libc6; do
        echo "pkg         : $(grep -P "^$p\t" "$ROOT/docs/package-manifest.tsv" | tr '\t' ' ')"
    done
    echo "source rev  : $(git -C "$ROOT" rev-parse --short HEAD) $(git -C "$ROOT" diff --quiet || echo '(+uncommitted changes)')"
} | tee "$ROOT/docs/versions.txt"

echo
echo "Packages     : $(wc -l < "$ROOT/docs/package-manifest.tsv")"
echo "SquashFS     : $(ls -lh binary/live/filesystem.squashfs | awk '{print $5}')"
echo "initramfs    : $(ls -lh binary/live/initrd.img | awk '{print $5}')   kernel: $(ls -lh binary/live/vmlinuz | awk '{print $5}')"
echo "Rootfs (du)  : $(sudo du -sxh chroot | cut -f1)"
echo "ISO          : $(ls -lh "$ISO_OUT" | awk '{print $5}')  $ISO_OUT"
