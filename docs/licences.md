# CudaLite OS — Licence Inventory

Generated from the built image by `scripts/licence_inventory.py` (reads the chroot's dpkg database and each
package's `/usr/share/doc/<package>/copyright`). Full per-package list: **`docs/licences.tsv`** (212 packages:
name, version, Debian archive area, declared licences).

## 1. Summary

| Debian archive area | Packages | Meaning |
|---|---|---|
| `main` | 193 | Free software (Debian Free Software Guidelines) |
| `contrib` | 8 | Free software that only exists to support non-free software (NVIDIA glue scripts) |
| `non-free` | 9 | Proprietary: the NVIDIA driver user-space and kernel module |
| `non-free-firmware` | 2 | Proprietary but redistributable binary firmware (NVIDIA GSP, AMD GPU) |
| **Total** | **212** | |

Most common licences in `main`: GPL-2.0, LGPL-2.1/3, BSD-2/3-Clause, MIT/Expat, GPL-3.0; 189 of the 212
packages carry at least one GPL-family licence. The custom kernel `linux-image-6.12.107-cudalite` is GPL-2.0
(built from the unmodified kernel.org 6.12.107 source; source and config are in this repository's build recipe).

## 2. Proprietary components and why they are needed

| Component | Packages | Licence | Why it is in the image | Free alternative and why not |
|---|---|---|---|---|
| NVIDIA kernel module 550.163.01 | `nvidia-kernel-dkms`, `nvidia-kernel-support` | NVIDIA graphics driver licence | The only driver that gives CUDA access to the RTX 4060. Built by DKMS for the custom kernel at image-build time. | `nouveau` (GPL) has no CUDA support, so it is blacklisted. NVIDIA's MIT/GPL "open" kernel module also supports Ada GPUs, but it was not evaluated here; the user-space parts stay proprietary either way. |
| CUDA driver library | `libcuda1`, `libnvidia-ptxjitcompiler1`, `nvidia-alternative` | NVIDIA graphics driver licence | `libcuda.so` is the CUDA driver API that every CUDA program calls; the PTX JIT compiles kernels for the GPU. | None: CUDA has no open-source driver library. |
| Monitoring | `nvidia-smi`, `libnvidia-ml1` | NVIDIA graphics driver licence | GPU status, memory and power for the report and validation. | None for this GPU. |
| `libnvidia-pkcs11-openssl3` | (dependency of the driver set) | NVIDIA graphics driver licence | Pulled in by the 550 driver packages; unused by CudaLite. | Cannot be dropped without breaking the package dependencies. |
| `nvidia-legacy-check` | (dependency) | NVIDIA graphics driver licence | Install-time check that the GPU is supported by this driver branch. | — |
| NVIDIA GSP firmware | `firmware-nvidia-gsp` | NVIDIA graphics driver licence (redistributable) | Ada (RTX 40) GPUs require the GPU System Processor firmware for the 550 driver to initialise the GPU. | None. |
| AMD GPU firmware | `firmware-amd-graphics` | AMD binary-redistribution licence (from linux-firmware) | The laptop's Radeon 780M drives the built-in display; `amdgpu` needs this firmware, otherwise the screen falls back to an unaccelerated mode or stays black. | None. |
| CUDA runtime (statically linked) | not a package: inside `/usr/local/bin/cudalite-benchmark` and `hello_cuda` | NVIDIA CUDA Toolkit EULA (`cudart_static` is listed as redistributable in the application) | Static linking makes the benchmark independent of a CUDA toolkit in the image (saves ~3 GB). | None. |

The `contrib` packages (`nvidia-kernel-common`, `nvidia-support`, `nvidia-installer-cleanup`, `nvidia-modprobe`,
`glx-alternative-*`, `glx-diversions`, `update-glx`) are free software (GPL-2+ / Expat). They are in `contrib` only
because they serve the proprietary driver.

## 3. Consequences

* **Kernel taint.** Loading the NVIDIA module marks the kernel as tainted (`module license 'NVIDIA' taints
  kernel` in `dmesg`). This is expected and has no effect on operation.
* **Secure Boot must be off.** The DKMS-built module is not signed with a key the firmware trusts.
* **Redistribution.** All proprietary parts come unmodified from Debian's `non-free` / `non-free-firmware`
  archive, whose licences allow redistribution. The ISO may be shared under the same terms; the NVIDIA
  licence forbids modifying or reverse-engineering those components.
* **This repository's own code** (scripts, benchmark source, configuration) is separate from the packages above.
