#!/usr/bin/env bash
# Build the CudaLite custom kernel (Linux 6.12.107, same version as Debian 13's kernel) as .deb
# packages and stage them for the image (build/live/config/packages.chroot/).
#
#   scripts/build_kernel.sh            build (re-uses the build chroot and source if present)
#   scripts/build_kernel.sh --config   only produce the .config (kernel/config-cudalite) and stop
#
# Why a Debian 13 build chroot: the NVIDIA module is compiled by DKMS *inside the image* with
# Debian's gcc-14; the kernel must be built with the same compiler, so it is built in Debian too.
#
# How the config is made:
#   1. start from Debian's own config for this kernel (docs/kernel.config)
#   2. `make localmodconfig` keeps only modules named in: this laptop's lsmod (kernel/lsmod-legion-ubuntu.txt),
#      what the live image loads (kernel/modules-cudalite-qemu.txt) and kernel/modules-extra.txt
#   3. kernel/cudalite.config: identity, no signing certs, no debug info, live-boot essentials
#   4. `make olddefconfig`; the result is saved as kernel/config-cudalite (tracked in git)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KB="$ROOT/build/kernel"
CH="$KB/chroot"
KVER="6.12.107"
TARBALL="linux-$KVER.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v6.x"
PKGVER="$KVER-1cudalite"
STAGE="$ROOT/build/live/config/packages.chroot"
CONFIG_ONLY=0; [[ "${1:-}" == "--config" ]] && CONFIG_ONLY=1
JOBS="$(nproc)"

step() { printf '\n\033[1m[%s] %s\033[0m\n' "$1" "$2"; }
sudo -n true 2>/dev/null || sudo -v

umount_chroot() { for m in dev/pts dev proc sys; do mountpoint -q "$CH/$m" && sudo umount -l "$CH/$m" || true; done; }
trap umount_chroot EXIT

step 1/6 "Debian 13 build chroot (gcc-14, same as the image)"
if [[ ! -x "$CH/usr/bin/gcc-14" ]]; then
    sudo debootstrap --variant=buildd \
        --include=bc,bison,flex,libssl-dev,libelf-dev,rsync,kmod,cpio,python3,xz-utils,zstd,ca-certificates,wget,dwarves,debhelper \
        trixie "$CH" http://deb.debian.org/debian/
fi
sudo chroot "$CH" sh -c 'command -v dh_listpackages >/dev/null || { apt-get update -qq && apt-get install -y -qq --no-install-recommends debhelper; }' </dev/null
sudo chroot "$CH" gcc --version | head -1

step 2/6 "Kernel source $KVER (kernel.org, checksum verified)"
mkdir -p "$KB/src"
if [[ ! -f "$KB/src/$TARBALL" ]] || ! (cd "$KB/src" && grep " $TARBALL\$" sha256sums.asc 2>/dev/null | sha256sum -c --status -); then
    curl -fL -o "$KB/src/$TARBALL" "$URL/$TARBALL"
    curl -fsSL -o "$KB/src/sha256sums.asc" "$URL/sha256sums.asc"
fi
(cd "$KB/src" && grep " $TARBALL\$" sha256sums.asc | sha256sum -c -)
SRC="$CH/build/linux-$KVER"
if [[ ! -f "$SRC/Makefile" ]]; then
    sudo mkdir -p "$CH/build"
    sudo tar -C "$CH/build" -xf "$KB/src/$TARBALL"
fi

step 3/6 "Configuration: Debian config -> localmodconfig -> CudaLite fragment"
# module list in lsmod format (localmodconfig reads `lsmod` output); normalise '-' to '_'
{
    echo "Module Size Used"
    { tail -n +2 "$ROOT/kernel/lsmod-legion-ubuntu.txt" | awk '{print $1}'
      cat "$ROOT/kernel/modules-cudalite-qemu.txt"
      grep -v '^#' "$ROOT/kernel/modules-extra.txt" | tr ' ' '\n'
    } | grep -v '^$' | tr '-' '_' | sort -u | awk '{print $1" 0 0"}'
} | sudo tee "$CH/build/lsmod.txt" >/dev/null
sudo cp "$ROOT/docs/kernel.config" "$SRC/.config"
sudo chroot "$CH" /bin/bash -c "cd /build/linux-$KVER && make olddefconfig >/dev/null && \
    yes '' | make LSMOD=/build/lsmod.txt localmodconfig >/dev/null 2>&1"
grep -vE '^\s*(#|$)' "$ROOT/kernel/cudalite.config" | while IFS='=' read -r sym val; do
    case "$val" in
        y) sudo chroot "$CH" "/build/linux-$KVER/scripts/config" --file "/build/linux-$KVER/.config" -e "$sym" ;;
        m) sudo chroot "$CH" "/build/linux-$KVER/scripts/config" --file "/build/linux-$KVER/.config" -m "$sym" ;;
        n) sudo chroot "$CH" "/build/linux-$KVER/scripts/config" --file "/build/linux-$KVER/.config" -d "$sym" ;;
        \"*) sudo chroot "$CH" "/build/linux-$KVER/scripts/config" --file "/build/linux-$KVER/.config" --set-str "$sym" "${val//\"/}" ;;
        *) sudo chroot "$CH" "/build/linux-$KVER/scripts/config" --file "/build/linux-$KVER/.config" --set-val "$sym" "$val" ;;
    esac
done
sudo chroot "$CH" /bin/bash -c "cd /build/linux-$KVER && make olddefconfig >/dev/null"
cp "$SRC/.config" "$ROOT/kernel/config-cudalite"
echo "options =y: $(grep -c '=y$' "$ROOT/kernel/config-cudalite")  =m: $(grep -c '=m$' "$ROOT/kernel/config-cudalite")" \
     "(Debian: $(grep -c '=y$' "$ROOT/docs/kernel.config") / $(grep -c '=m$' "$ROOT/docs/kernel.config"))"
[[ $CONFIG_ONLY -eq 1 ]] && { echo "config written to kernel/config-cudalite"; exit 0; }

# bindeb-pkg needs debhelper (its debian/rules calls dh_listpackages); it is in the chroot.
step 4/6 "Compile ($JOBS jobs) and package (bindeb-pkg)"
sudo mount -t proc proc "$CH/proc"; sudo mount --bind /dev "$CH/dev"; sudo mount --bind /dev/pts "$CH/dev/pts"
sudo rm -f "$CH"/build/*.deb "$CH"/build/*.buildinfo "$CH"/build/*.changes
START=$(date +%s)
sudo chroot "$CH" /bin/bash -c "cd /build/linux-$KVER && \
    make -j$JOBS KDEB_PKGVERSION=$PKGVER KBUILD_BUILD_USER=cudalite KBUILD_BUILD_HOST=cudalite-build bindeb-pkg" \
    </dev/null 2>&1 | tee "$KB/build.log" | grep -E "^(  (LD|AR) +vmlinux|dpkg-deb: building)|error:|Error " || true
echo "build time: $(( $(date +%s) - START )) s"
umount_chroot

step 5/6 "Stage packages for the image"
ls "$CH"/build/linux-image-$KVER-cudalite_*_amd64.deb "$CH"/build/linux-headers-$KVER-cudalite_*_amd64.deb >/dev/null \
    || { echo "FATAL: kernel packages were not produced; see $KB/build.log"; exit 1; }
mkdir -p "$STAGE"
rm -f "$STAGE"/linux-image-*-cudalite_*.deb "$STAGE"/linux-headers-*-cudalite_*.deb
cp "$CH"/build/linux-image-$KVER-cudalite_*_amd64.deb "$CH"/build/linux-headers-$KVER-cudalite_*_amd64.deb "$STAGE/"
ls -l "$STAGE"

step 6/6 "Size summary"
VMLINUZ_SIZE=$(stat -c%s "$SRC/arch/x86/boot/bzImage")
MODS=$(sudo find "$SRC" -name '*.ko' | wc -l)
echo "bzImage (vmlinuz): $VMLINUZ_SIZE bytes   modules built: $MODS"
