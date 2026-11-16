# CudaLite OS - design decisions and deviations (working notes for the report)

Track C (CUDA/GPU compute). Target: Lenovo Legion Slim 5 16AHP9, RTX 4060 Laptop (AD107M, 8 GB),
AMD Ryzen 7 8845HS + Radeon 780M (hybrid graphics), 16 GB RAM.

## Build-system choice (Task 2)

| | Debian live-build (chosen) | Yocto / Buildroot | JetPack / PetaLinux |
|---|---|---|---|
| Fit for x86 PC + NVIDIA proprietary driver | Debian ships `nvidia-kernel-dkms`, `libcuda1`, `nvidia-smi` as packages | NVIDIA driver is out-of-tree binary blob; needs a custom recipe/package per release | Jetson/Zynq only, not an x86 RTX |
| Reproducibility | Config + package lists + hooks in git; package versions from a Debian suite | Strongest (pinned sources, sstate) | Vendor-controlled |
| Effort / iteration time | Minutes (incremental `lb chroot`) | Hours for first build | n/a |
| Image size | ~hundreds of MB with driver | Smallest possible, but CUDA userspace is glibc/binary and awkward on musl/uclibc | n/a |

Decision: live-build. The deciding factor is the proprietary NVIDIA stack: Debian already packages and
tests it against its own kernel, so DKMS builds the module for the exact target kernel.

## Deviations from the original plan / handoff guide, and why

1. **Hook path.** The handoff put the setup hook at `config/hooks/normal/9999-*.hook.chroot`. Ubuntu's
   live-build 3.0~a57 only runs `config/hooks/*.chroot` (verified in `/usr/lib/live/build/lb_chroot_hooks`),
   so that hook would never have run: no `cudauser`, no enabled service, no DKMS build. Fixed:
   `config/hooks/9999-cudalite-setup.chroot`.
2. **Hook fails loudly.** The guide's `dkms autoinstall ... || true` would ship an image without the GPU
   driver. The hook now asserts `modinfo nvidia` succeeds for every installed kernel and the build script
   re-checks for `nvidia.ko` in the chroot.
3. **Headless driver stack.** `nvidia-kernel-dkms libcuda1 nvidia-smi nvidia-modprobe firmware-nvidia-gsp`
   instead of the `nvidia-driver` metapackage (which adds Xorg driver, GL/EGL/Vulkan, VDPAU: unused here).
4. **Driver/CUDA version match.** Debian 13 ships NVIDIA 550.163.01 (= CUDA 12.4 level); the host toolkit
   is CUDA 12.4.131, so a statically linked 12.4 runtime runs on the image's driver. (The Ubuntu host runs
   driver 595 / CUDA 13.2; host and image drivers differ and are reported as such.)
5. **Device nodes with `NoNewPrivileges`.** CUDA normally has the setuid `nvidia-modprobe` create
   `/dev/nvidia*`; `NoNewPrivileges=true` disables setuid, so a privileged `ExecStartPre=+` creates the nodes.
6. **`firmware-amd-graphics`.** The AMD iGPU drives the panel; `amdgpu` without firmware can leave a black
   console. Costs ~92 MB installed (measured in the final size breakdown).
7. **`--apt-recommends false`.** Smaller image; every needed dependency is listed explicitly.
8. **Benchmark source completed.** The handoff's source was truncated and had no `--quick`. The new
   benchmark adds a multithreaded CPU baseline, naive + tiled GPU kernels, medians/spread and a correctness gate.
9. **glibc guard.** Host is Ubuntu (glibc 2.43), target is Debian 13 (glibc 2.41). `build_benchmark.sh`
   fails if a binary needs a newer glibc symbol; libstdc++ is linked statically.
10. **Reproducibility gaps closed:** `auto/config` records the `lb config` recipe (the original command only
    existed in shell history); `scripts/patch_live_build.sh` captures the one host patch to
    `lb_chroot_dpkg`; the ISO volume label no longer embeds a timestamp.
11. **SquashFS.** 1 MiB xz blocks, and the kernel/initrd copies inside `/boot` are excluded (they are shipped
    uncompressed next to the squashfs anyway; keeping them duplicated the initramfs).
12. **Secure Boot.** The host has Secure Boot **enabled**. The DKMS module is unsigned and the GRUB image
    from `grub-mkrescue` is not shim-signed, so the image only boots with Secure Boot **disabled**. This is a
    documented controlled-test setup; Secure Boot support is not claimed.

13. **Toolchain trimmed after the module is built.** gcc-14, cpp-14, kernel headers/kbuild (~200 MB
    installed) are purged by the hook once DKMS has produced `nvidia-current.ko`; the hook asserts that
    dkms, nvidia-kernel-dkms, libcuda1, nvidia-smi, live-boot and the module survive (dkms has no
    header-removal hook, checked in the dkms package). Result of the first QEMU-tested build vs trimmed:
    244 -> 214 packages, SquashFS 387 -> 323 MB, ISO 453 -> 389 MB.
14. **Debian's module naming.** Debian ships `nvidia-current*.ko` and maps `nvidia`/`nvidia-uvm` onto them
    through `/etc/modprobe.d/nvidia.conf` (alternatives). My first hook check used `modinfo nvidia` and
    wrongly failed a good build.
15. **Redundant module loading removed.** The PCI alias (udev), Debian's `modules-load.d/nvidia.conf`
    (`nvidia-drm`) and the service's `nvidia-modprobe -u` already load the driver; the extra
    `modules-load.d` file only produced repeated failed attempts on machines without the GPU (VM test:
    `NVRM: No NVIDIA GPU found`, 7.7 s in `systemd-modules-load`).
16. **Services removed:** `cron`, `logrotate` (nothing scheduled). Remaining network software is the DHCP
    client from `ifupdown`/`dhcpcd-base`: `ss -tulpn` shows only a DHCPv6 *client* socket, no listeners.
17. **Build-process bug worth documenting:** under `sudo`, `lb`'s `apt-get` inherits a pty as stdin, gets
    SIGTTOU and hangs after the tzdata upgrade; the build script runs `lb` with stdin from `/dev/null`.

## Package inclusion / exclusion (Task 4)

| Included | Why |
|---|---|
| `linux-image-amd64`, `linux-headers-amd64`, `dkms`, `gcc`, `make` | Debian kernel (known-good config, see `kernel.config`) + toolchain to build the NVIDIA module for that exact kernel |
| `nvidia-kernel-dkms`, `firmware-nvidia-gsp`, `libcuda1`, `nvidia-smi`, `nvidia-modprobe` | Minimum driver stack for CUDA compute and `nvidia-smi` |
| `live-boot`, `live-config(-systemd)`, `systemd(-sysv)`, `udev`, `dbus`, `libpam-systemd` | Live ISO boot (SquashFS + overlay), init, device management, login sessions |
| `firmware-amd-graphics` | Display on the hybrid laptop |
| `nftables` | Default-deny firewall |
| `sudo`, `procps`, `pciutils`, `usbutils`, `iproute2`, `iputils-ping`, `less`, `nano`, `openssh-client`, `ca-certificates` | Demo / diagnostics |

| Excluded | Why |
|---|---|
| CUDA toolkit (`nvcc`, headers, libs ~3 GB) | Apps are built on the host with a static CUDA runtime; image needs only the driver |
| cuDNN, cuBLAS | Matrix-multiply benchmark uses hand-written kernels; cuDNN is for neural nets (the plan says not to add it for show) |
| Xorg/Wayland, desktop, GL/Vulkan, `nvidia-driver` metapackage | Headless compute; text console only |
| sshd, network services, Debian installer, Python | No inbound services; smaller attack surface and size |

## Hardening measures (Task 5, needs >= 3; all verified by `cudalite-report` on the booted image)

1. Dedicated unprivileged service account `cudalite` (no login shell) running the benchmark.
2. systemd sandbox on the service (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
   `PrivateNetwork`, kernel/cgroup/clock protections, empty capability set).
3. nftables default-deny inbound; no listening sockets (`ss -tulpn` is empty).
4. Read-only SquashFS root + RAM overlay (live-boot); results are the only writable service path.
5. Kernel sysctl hardening (`kptr_restrict`, `dmesg_restrict`, `ptrace_scope`, unprivileged BPF disabled, ...).
6. `nouveau`/`nvidiafb` blacklisted so only the intended driver binds the GPU.

Known demo trade-off: the console user `cudauser` autologins with passwordless sudo (no sshd, firewall
closed). Not for production.

## Filesystem layout

Read-only: `/run/live/medium/live/filesystem.squashfs` (xz). Writable: tmpfs-backed overlay on `/` (RAM;
changes vanish at reboot). Benchmark results land in `/var/lib/cudalite/` (overlay); copy to USB to keep.

## Measurement caveats (to state in the report)

* Stock baseline = the Ubuntu 26.04.1 install on the same machine. The first baseline run was on
  **battery** (`docs/results/ubuntu-host-benchmark.txt`); the final comparison must be re-run on **AC power**
  for both systems.
* The Ubuntu desktop session shares the GPU (compositor) and has background services; the live image is
  headless. Boot time and idle RAM therefore compare a desktop install with a headless live system - say so.
* A VM without GPU passthrough proves boot only, never CUDA.
* Power is not measured (no external meter); `nvidia-smi power.draw` is GPU-only and is not whole-system power.
