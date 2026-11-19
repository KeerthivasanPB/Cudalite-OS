# CudaLite OS

A minimal, bootable **Debian 13 (trixie)** live image for **NVIDIA CUDA compute** on an RTX 4060 laptop
(assignment Track C). It boots to a text console, loads the NVIDIA driver, and automatically runs a
CPU-vs-GPU matrix-multiplication benchmark as a sandboxed systemd service.

Status: configuration and build scripts complete; image build, hardware validation and evaluation in progress
(see `docs/report-notes.md` for decisions and `docs/results/` for measurements).

## Hardware tested
Lenovo Legion Slim 5 16AHP9: AMD Ryzen 7 8845HS, 16 GB RAM, NVIDIA RTX 4060 Laptop (8 GB), Radeon 780M iGPU.
Development host: Ubuntu 26.04.1 LTS (also the stock-Linux baseline).

## Repository layout
| Path | Purpose |
|---|---|
| `application/` | CUDA sources: `hello_cuda.cu` (smoke test), `cudalite_benchmark.cu` (CPU vs GPU matmul) |
| `build/live/auto/config` | The exact `lb config` recipe |
| `build/live/config/` | live-build config: package list, hook, files baked into the image (`includes.chroot`) |
| `kernel/` | Custom kernel inputs: config fragment, module lists, resulting `config-cudalite` |
| `scripts/build_kernel.sh` | Build the custom 6.12.107-cudalite kernel packages (Debian 13 build chroot) |
| `scripts/build_benchmark.sh` | Compile CUDA binaries (static CUDA runtime) and stage them into the image tree |
| `scripts/build_iso.sh` | One-command ISO build + checksum + manifest |
| `scripts/patch_live_build.sh` | One-line host fix for Ubuntu's old live-build |
| `docs/` | `kernel.config` (Debian's, for comparison), kernel notes, `package-manifest.tsv`, `versions.txt`, `report-notes.md`, `results/` |

## Build prerequisites (Ubuntu host)
```bash
sudo apt install live-build debootstrap squashfs-tools xorriso mtools grub-pc-bin grub-efi-amd64-bin \
                 nvidia-cuda-toolkit g++-13 qemu-system-x86 qemu-utils
```
Ubuntu's `live-build` is the old 3.0~a57 fork; `scripts/patch_live_build.sh` applies the single fix it needs.

## Build the ISO
```bash
scripts/build_kernel.sh           # custom kernel .debs (once; ~15 min first time)
scripts/build_iso.sh --clean      # from scratch (first time)
scripts/build_iso.sh              # incremental rebuild while iterating
```
Output: `build/live/cudalite-os-rtx4060.iso`, plus `docs/image.sha256`, `docs/package-manifest.tsv`,
`docs/versions.txt`, `build.log`.

## Boot it
* **QEMU (boot check only, no GPU):** `qemu-system-x86_64 -m 4G -enable-kvm -cdrom build/live/cudalite-os-rtx4060.iso`
  (add `-bios /usr/share/ovmf/OVMF.fd` for UEFI). A VM without GPU passthrough cannot prove CUDA.
* **Real hardware (one USB stick):** `sudo scripts/make_usb.sh /dev/sdX` writes the ISO and adds a FAT32
  partition labelled `RESULTS` in the stick's free space (refuses non-USB or mounted disks, asks you to retype
  the device name). **Disable Secure Boot** (the NVIDIA module is unsigned), boot from USB, pick the first
  GRUB entry; if the display stays black use the "nomodeset fallback" entry. `cudalite-report` copies its
  output to the stick's `RESULTS` partition automatically; to copy anything else by hand use
  `sudo mount -L RESULTS /mnt`, `sudo cp ... /mnt`, `sync`, `sudo umount /mnt` (FAT32 is root-owned there).

## Verify the GPU and run the benchmark
Log-in is automatic (`cudauser`). Then:
```bash
nvidia-smi
systemctl status cudalite-benchmark.service     # ran automatically at boot
journalctl -u cudalite-benchmark.service -b
cudalite-benchmark --full                       # full sizes (512..4096)
cudalite-report --full                          # collect every validation output into one file
```

## Proprietary components
NVIDIA driver (550.163.01, NVIDIA licence), NVIDIA GSP firmware, and the CUDA runtime statically linked into
the benchmark (NVIDIA EULA). Justified in `docs/report-notes.md`; everything else is open source.

## Known limitations
* Boots only with Secure Boot disabled.
* No persistence: results live in a RAM overlay; copy them off before power-off.
* Debian package versions float within trixie; `docs/package-manifest.tsv` records the exact set used.
