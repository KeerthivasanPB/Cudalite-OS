CudaLite OS v1.0: a headless Debian 13 live system for CUDA compute on the NVIDIA RTX 4060 Laptop GPU, with a custom Linux 6.12.107 kernel.

**Download:** `cudalite-os-rtx4060.iso` (278 MB, hybrid UEFI + BIOS)

**SHA-256:** `bdebf2907dda38f6d63bf1c1eca6c866112bbc3a0cedb72e6a46cdb8c79b903b`

Check the download with:
```
sha256sum cudalite-os-rtx4060.iso
```

**Write it to a USB stick** (from this repository; refuses internal and mounted disks):
```
sudo scripts/make_usb.sh /dev/sdX cudalite-os-rtx4060.iso
```
Disable Secure Boot, boot from the stick (F12 on Lenovo laptops), and choose the first GRUB entry.

**Results on the target laptop (Lenovo Legion Slim 5 16AHP9)**

| | Ubuntu 26.04.1 | CudaLite OS |
|---|---|---|
| Image size | 6.0 GB | 278 MB (-95.4 %) |
| Boot, kernel + userspace | 27.96 s | 12.75 s |
| Idle RAM | 3,428 MiB | 646 MiB |
| Packages | 2,003 | 212 |
| GPU tiled matmul, N = 2048 | 1,290 GFLOP/s | 1,290 GFLOP/s |

Contains proprietary NVIDIA driver and firmware components and AMD GPU firmware, listed and justified in `docs/licences.md`. Rebuild from source with `scripts/build_kernel.sh` and then `scripts/build_iso.sh --clean`.
