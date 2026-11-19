# CudaLite OS — Custom Kernel

## 1. Summary

| | Before: Debian stock kernel | After: CudaLite kernel |
|---|---|---|
| Version | `6.12.107+deb13-amd64` | `6.12.107-cudalite` (same upstream release, kernel.org source) |
| Config | `docs/kernel.config` | `kernel/config-cudalite` |
| Built-in options (`=y`) / modules (`=m`) | 2,650 / 4,051 | 1,983 / 289 |
| `vmlinuz` | 12,142,528 B | **10,592,768 B (-12.8 %)** |
| `initrd.img` | 43,774,865 B | **13,653,318 B (-68.8 %)** |
| `/lib/modules` | 148 MB, 4,234 files | **54 MB, 286 files (-63.5 % / -93.2 %)** |
| ISO | 389 MB | **278 MB (-28.5 %)** |
| Boot on RTX 4060 laptop, kernel + `multi-user.target` | 5.737 + 8.943 = 14.68 s (hw-run2) | **5.238 + 7.515 = 12.75 s (-13.1 %)** (hw-run3) |
| Boot in QEMU/KVM, kernel + userspace | 2.479 + 5.182 = 7.661 s | **2.229 + 4.830 = 7.060 s (-7.8 %)** |

Raw measurements: `docs/results/kernel-before.txt`, `docs/results/kernel-after.txt`,
`docs/results/cudalite-hw-run2/`, `docs/results/cudalite-hw-run3/`.

## 2. How it is built (`scripts/build_kernel.sh`)

1. A clean Debian 13 build chroot (`debootstrap --variant=buildd trixie`) so the compiler (gcc-14) matches the
   one DKMS uses inside the image to build the NVIDIA module.
2. Linux 6.12.107 source from kernel.org, checked against kernel.org's `sha256sums.asc`.
3. Start from Debian's own config (`make olddefconfig`), so every default stays the distribution's.
4. `make localmodconfig` with a module list: the union of
   - `kernel/lsmod-legion-ubuntu.txt`: modules loaded on the target laptop (Ubuntu, RTX 4060 + Radeon 780M),
   - `kernel/modules-cudalite-qemu.txt`: modules loaded by the CudaLite image in the QEMU test VM,
   - `kernel/modules-extra.txt`: modules needed but not loaded at capture time (USB boot, FAT/NLS, NVMe/AHCI,
     nftables, NVIDIA's dependencies `drm`, `ttm`, `video`, `wmi`, `i2c_algo_bit`).
   Every other module is switched off.
5. The fragment `kernel/cudalite.config` is applied, then `make olddefconfig`.
6. `make bindeb-pkg` produces `linux-image-6.12.107-cudalite` and `linux-headers-6.12.107-cudalite`.
   The image build installs both in the chroot hook; DKMS builds `nvidia-current.ko` for the new kernel, and the
   headers and compiler are then removed.

## 3. The fragment (`kernel/cudalite.config`) and why

| Option | Value | Reason |
|---|---|---|
| `LOCALVERSION` | `-cudalite` | Identifies the kernel (`uname -r`). |
| `SYSTEM_TRUSTED_KEYS`, `SYSTEM_REVOCATION_KEYS` | `""` | Debian's signing certificates are not in the kernel.org tree. |
| `MODULE_SIG_FORCE` | off | The NVIDIA DKMS module is unsigned; it must still load (Secure Boot is off, documented). |
| `DEBUG_INFO_NONE` | y (DWARF, BTF off) | Smaller packages and a faster build; the appliance never debugs the kernel. |
| `SQUASHFS`, `SQUASHFS_XZ`, `OVERLAY_FS`, `BLK_DEV_LOOP`, `ISO9660_FS` | m | Live boot: xz SquashFS root on a loop device, RAM overlay, ISO medium. |
| `VFAT_FS` | m | EFI partition and the RESULTS stick partition. |

Options kept from Debian's config and required by the workload: `PCI`, `PCIEPORTBUS`, `MODULES`, `MODULE_UNLOAD`,
`FW_LOADER` (NVIDIA GSP firmware), `DRM` (needed by `nvidia-drm`), `SECCOMP` and namespaces (systemd sandbox of
the benchmark service), `NF_TABLES` (firewall), Yama (`ptrace_scope`).

## 4. Verified on the hardware (run 3)

- `uname -r` = `6.12.107-cudalite`; `nvidia` 550.163.01 is bound to the RTX 4060; `amdgpu` drives the display;
  keyboard and USB work.
- `cudalite-benchmark.service`: `active (exited)`, ALL PASS at boot; full benchmark identical to the Debian kernel
  within noise (N = 2048 tiled: 1290 GFLOP/s on both).
- Hardening intact: nftables default-deny, read-only SquashFS, sysctl settings, service exposure 2.6 OK.
- Removed on purpose: Wi-Fi and Bluetooth firmware (the appliance is offline); their drivers' firmware requests fail
  harmlessly in `dmesg`.

## 5. Trade-offs

- Hardware not present at capture time (other GPUs, other Wi-Fi cards, other storage controllers) is unsupported.
  This is intended for a single-target appliance; add the module name to `kernel/modules-extra.txt` and rebuild.
- The kernel taints when NVIDIA's proprietary module loads; Secure Boot must stay off unless the module is signed
  with an enrolled key (MOK), which is outside this assignment.
