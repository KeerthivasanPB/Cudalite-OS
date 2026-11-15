# CudaLite OS — Phase 3 Kernel Configuration & Documentation

## 1. Kernel Overview
- **Target Distribution:** Debian GNU/Linux 13 (trixie)
- **Kernel Version:** `6.12.107+deb13-amd64`
- **Config File:** `docs/kernel.config`
- **Kernel Image (`vmlinuz-6.12.107+deb13-amd64`) Size:** 12M
- **Modules Directory (`/lib/modules/6.12.107+deb13-amd64`) Size:** 107M
- **Patches Applied:** Standard Debian 13 packaged kernel patches (retained for full hardware and NVIDIA DKMS ABI compatibility).

## 2. Verified Kernel Options for Live OS & NVIDIA GPU Support
```
CONFIG_BLK_DEV_INITRD=y
CONFIG_64BIT=y
CONFIG_SMP=y
CONFIG_ACPI=y
CONFIG_SECCOMP=y
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_PCI=y
CONFIG_PCIEPORTBUS=y
CONFIG_FW_LOADER=y
CONFIG_DRM=m
CONFIG_FB=y
CONFIG_EXT4_FS=m
CONFIG_OVERLAY_FS=m
CONFIG_VFAT_FS=m
CONFIG_SQUASHFS=m
CONFIG_SECURITY=y
```

## 3. Rationale for Key Options
- **`CONFIG_64BIT=y` & `CONFIG_PCI=y` / `CONFIG_PCIEPORTBUS=y`:** Required for 64-bit x86 architecture and PCIe bus communication with the RTX 4060 GPU.
- **`CONFIG_MODULES=y` & `CONFIG_MODULE_UNLOAD=y`:** Required to dynamically load out-of-tree NVIDIA kernel modules (`nvidia.ko`, `nvidia-modeset.ko`, `nvidia-uvm.ko`).
- **`CONFIG_FW_LOADER=y`:** Required to load NVIDIA GPU GSP firmware and system hardware firmware.
- **`CONFIG_BLK_DEV_INITRD=y`, `CONFIG_SQUASHFS=m`, `CONFIG_OVERLAY_FS=m`:** Essential for booting the compressed read-only SquashFS root filesystem and mounting the writable RAM overlay in a Debian Live system.
