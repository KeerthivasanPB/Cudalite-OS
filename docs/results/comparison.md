# CudaLite OS vs stock Ubuntu 26.04.1 LTS (same laptop)

Hardware: Lenovo Legion Slim 5 16AHP9, Ryzen 7 8845HS (16 threads), RTX 4060 Laptop (8 GB), 14.9 GiB RAM,
on AC power for both systems. Same benchmark binary (`cudalite-benchmark --full`, static CUDA 12.4 runtime).

Sources: CudaLite = `cudalite-hw-run3/` (custom 6.12.107-cudalite kernel, booted from USB, 2026-11-19;
run 2 = same image with Debian's stock kernel); Ubuntu = `ubuntu-host-benchmark-ac.txt`
and measurements on the installed system; stock ISO sizes from releases.ubuntu.com/26.04.1/.

## OS footprint and boot

| Metric | Stock Ubuntu 26.04.1 | CudaLite OS (custom kernel, run 3) | Difference |
|---|---|---|---|
| Image size (ISO) | 6.0 GB desktop ISO (2.7 GB server ISO) | **278 MB** (389 MB with Debian kernel) | **-95.4 %** vs desktop (-89.7 % vs server) |
| Root filesystem content | 18,029 MB (`du -sxm /usr /var /etc` = 14,296 + 3,719 + 14) | **683 MB** (`du` of the squashfs layer) | **-96.2 %** |
| Installed packages | 2,003 | **212** | -89.4 % |
| Boot, kernel + userspace | 2.18 s + 25.78 s = **27.96 s** (to `graphical.target`) | 5.24 s + 7.52 s = **12.75 s** (to `multi-user.target`; Debian kernel 14.68 s) | -54.4 % |
| Idle RAM used (`free`) | 3,428 MiB (desktop session open) | **646 MiB** | -81.2 % |
| GPU driver | 595.99.02 (CUDA 13.2) | 550.163.01 (CUDA 12.4) | Debian 13 driver branch |
| Benchmark auto-start | n/a | `active (exited)`, ALL PASS at boot | systemd service |

Assignment target: image at least 40 % smaller than stock. **Met: 95.4 % smaller** (89.7 % even against the server ISO).

## Workload: matrix multiplication C = A x B (float32), medians

| N | Metric | Ubuntu (AC) | CudaLite OS | Note |
|---|---|---|---|---|
| 1024 | GPU tiled kernel | 2.313 ms / 928 GFLOP/s | 2.316 ms / 927 GFLOP/s | identical |
| 2048 | GPU tiled kernel | 13.315 ms / 1290 GFLOP/s | 13.318 ms / 1290 GFLOP/s | identical |
| 4096 | GPU tiled kernel | 119.6 ms / 1149 GFLOP/s | 144.0 ms / 954 GFLOP/s | CudaLite 20 % slower, see caveats (run 2: 145.7 ms) |
| 4096 | GPU end-to-end (H2D+kernel+D2H) | 139.4 ms | 164.0 ms | |
| 4096 | CPU 1 thread | 14,343 ms | 9,906 ms | CudaLite 31 % faster (no desktop load) |
| 4096 | CPU 16 threads | 1,706 ms | 1,391 ms | CudaLite 18 % faster |
| 4096 | Speedup GPU kernel vs CPU 1 thread | 119.9x | 68.8x | |
| all | Correctness vs CPU reference | PASS (max rel. err 3.6e-07) | PASS (3.6e-07) | |
| 4096 | Peak GPU memory in use | 306 MiB | 289 MiB | whole device incl. CUDA context (Ubuntu desktop also uses the GPU) |

## Caveats (state these in the report)

* **Not identical conditions.** Ubuntu ran with a desktop session open (GNOME, browser, editor); CudaLite is headless.
  That inflates Ubuntu's idle RAM and slows its CPU numbers; it is also why boot endpoints differ
  (`graphical.target` vs `multi-user.target`).
* **Firmware/loader time excluded** from boot comparison: it depends on how long the F12 boot menu was open
  (CudaLite firmware time was 7.9 s in run 1, 18.4 s in run 2 and 14.5 s in run 3).
* **Different GPU drivers** (595 vs 550): Debian 13 ships the 550 branch. At N <= 2048 GPU results are identical;
  at N = 4096 CudaLite was 20-22 % slower in both runs 2 and 3 (spread 133.8-149.6 ms). The kernel swap did not
  change it, which points away from the kernel. Likely causes are driver
  version and power/clock state; not proven - a single run each. Repeat runs needed before drawing a conclusion.
* **Single repetition** for CPU single-thread at N >= 2048 (by design, they take seconds); treat as indicative.
* **Live system:** CudaLite runs from USB with a RAM overlay; disk I/O is not part of this workload.
* **Power** was not measured (no external meter); `nvidia-smi` power is GPU-only and is not whole-system power.
