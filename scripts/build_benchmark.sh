#!/usr/bin/env bash
# Build the CUDA applications on the Ubuntu development host and stage them
# into the live-build tree so they are baked into the CudaLite OS image.
#
# Why static CUDA runtime: the target image ships only the NVIDIA *driver*
# (libcuda.so.1, nvidia-smi), not the ~3 GB CUDA toolkit. --cudart static embeds
# the runtime in the executable.
#
# Why the glibc check: the host (Ubuntu) is newer than the target (Debian 13,
# glibc 2.41). A binary needing a newer glibc symbol would fail to start there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/application"
STAGE="$ROOT/build/live/config/includes.chroot/usr/local/bin"

TARGET_GLIBC_MAX="2.41"   # Debian 13 (trixie)
# nvcc 12.4 supports host gcc <= 13; the driver on Debian 13 is the 550 branch (CUDA 12.4).
CCBIN="${CCBIN:-g++-13}"
# RTX 4060 Laptop (Ada, compute capability 8.9): native SASS plus PTX for forward compatibility.
GENCODE=(-gencode arch=compute_89,code=sm_89 -gencode arch=compute_89,code=compute_89)

command -v nvcc >/dev/null || { echo "nvcc not found (install nvidia-cuda-toolkit)"; exit 1; }
command -v "$CCBIN" >/dev/null || { echo "$CCBIN not found (nvcc $(nvcc --version | grep -o 'release [0-9.]*') needs gcc<=13)"; exit 1; }

build() {  # build <source.cu> <output> [extra nvcc flags...]
    local src="$1" out="$2"; shift 2
    echo "[nvcc] $src -> $out"
    nvcc -O3 -std=c++17 -ccbin "$CCBIN" --cudart static "${GENCODE[@]}" \
         -Xcompiler "-static-libstdc++ -static-libgcc" "$@" "$src" -o "$out"
}

check_glibc() {
    local bin="$1" max
    max="$(objdump -T "$bin" | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/GLIBC_//' | sort -V | tail -1)"
    if [[ -n "$max" && "$(printf '%s\n%s\n' "$max" "$TARGET_GLIBC_MAX" | sort -V | tail -1)" != "$TARGET_GLIBC_MAX" ]]; then
        echo "FAIL: $bin needs GLIBC_$max > Debian 13's $TARGET_GLIBC_MAX"; exit 1
    fi
    if objdump -p "$bin" | grep -q 'NEEDED.*libstdc++'; then
        echo "FAIL: $bin dynamically links libstdc++"; exit 1
    fi
    echo "[ok]   $(basename "$bin"): max GLIBC_${max:-none}, deps: $(ldd "$bin" | awk '{print $1}' | grep -v -E '^(linux-vdso|/lib64)' | xargs echo)"
}

build "$APP/hello_cuda.cu"          "$APP/hello_cuda"
build "$APP/cudalite_benchmark.cu"  "$APP/cudalite-benchmark"
check_glibc "$APP/hello_cuda"
check_glibc "$APP/cudalite-benchmark"

mkdir -p "$STAGE"
install -m 0755 "$APP/hello_cuda" "$APP/cudalite-benchmark" "$STAGE/"
echo "Staged into $STAGE"
ls -l "$STAGE"
