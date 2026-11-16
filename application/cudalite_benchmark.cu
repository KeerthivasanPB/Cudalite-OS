// CudaLite OS - CPU vs GPU matrix-multiplication benchmark.
//
// Computes C = A * B for square float matrices on:
//   * one CPU thread        (reference implementation, cache-friendly i-k-j loop)
//   * all CPU threads       (std::thread, rows partitioned)
//   * GPU, naive kernel     (one thread per output element, global memory only)
//   * GPU, tiled kernel     (16x16 shared-memory tiles)
//
// Timing uses CUDA events for the GPU and steady_clock for the CPU. Every
// measurement is repeated; the median and min/max spread are reported.
// GPU results are verified against the single-thread CPU reference before any
// speed figure is trusted.
//
// Usage:  cudalite-benchmark [--quick | --full] [--sizes 512,1024,...]
//                            [--reps N] [--out DIR] [--help]
//
// Build:  see scripts/build_benchmark.sh   (static CUDA runtime on purpose:
//         the target image ships only the NVIDIA driver, not the CUDA toolkit)
//
// SPDX-License-Identifier: MIT

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <thread>
#include <vector>

#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cuda_runtime.h>

#define TILE 16
#define VERSION "1.0"

#define CUDA_CHECK(call)                                                      \
    do {                                                                      \
        cudaError_t err_ = (call);                                            \
        if (err_ != cudaSuccess) {                                            \
            fprintf(stderr, "CUDA error at %s:%d - %s\n", __FILE__, __LINE__, \
                    cudaGetErrorString(err_));                                \
            exit(EXIT_FAILURE);                                               \
        }                                                                     \
    } while (0)

// ---------------------------------------------------------------- GPU kernels

__global__ void matMulNaive(const float* A, const float* B, float* C, int N) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    if (row < N && col < N) {
        float sum = 0.0f;
        for (int k = 0; k < N; ++k) sum += A[row * N + k] * B[k * N + col];
        C[row * N + col] = sum;
    }
}

__global__ void matMulTiled(const float* A, const float* B, float* C, int N) {
    __shared__ float tileA[TILE][TILE];
    __shared__ float tileB[TILE][TILE];

    int row = blockIdx.y * TILE + threadIdx.y;
    int col = blockIdx.x * TILE + threadIdx.x;
    float sum = 0.0f;

    for (int t = 0; t < (N + TILE - 1) / TILE; ++t) {
        int aCol = t * TILE + threadIdx.x;
        int bRow = t * TILE + threadIdx.y;
        tileA[threadIdx.y][threadIdx.x] = (row < N && aCol < N) ? A[row * N + aCol] : 0.0f;
        tileB[threadIdx.y][threadIdx.x] = (bRow < N && col < N) ? B[bRow * N + col] : 0.0f;
        __syncthreads();
        for (int k = 0; k < TILE; ++k) sum += tileA[threadIdx.y][k] * tileB[k][threadIdx.x];
        __syncthreads();
    }
    if (row < N && col < N) C[row * N + col] = sum;
}

// ---------------------------------------------------------------- CPU kernels

// Computes rows [r0, r1) of C. i-k-j order streams B and C rows sequentially,
// which is far faster than the textbook i-j-k order and a fairer CPU baseline.
static void cpuMatMulRows(const float* A, const float* B, float* C, int N, int r0, int r1) {
    for (int i = r0; i < r1; ++i) {
        float* c = C + (size_t)i * N;
        std::fill(c, c + N, 0.0f);
        for (int k = 0; k < N; ++k) {
            const float a = A[(size_t)i * N + k];
            const float* b = B + (size_t)k * N;
            for (int j = 0; j < N; ++j) c[j] += a * b[j];
        }
    }
}

static void cpuMatMul(const float* A, const float* B, float* C, int N, int threads) {
    if (threads <= 1) {
        cpuMatMulRows(A, B, C, N, 0, N);
        return;
    }
    std::vector<std::thread> pool;
    int chunk = (N + threads - 1) / threads;
    for (int t = 0; t < threads; ++t) {
        int r0 = t * chunk, r1 = std::min(N, r0 + chunk);
        if (r0 >= r1) break;
        pool.emplace_back(cpuMatMulRows, A, B, C, N, r0, r1);
    }
    for (auto& th : pool) th.join();
}

// -------------------------------------------------------------------- helpers

static double nowSec() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct Stat {
    double med = 0, lo = 0, hi = 0;
};

static Stat summarize(std::vector<double> v) {
    Stat s;
    if (v.empty()) return s;
    std::sort(v.begin(), v.end());
    s.lo = v.front();
    s.hi = v.back();
    s.med = (v.size() % 2) ? v[v.size() / 2] : 0.5 * (v[v.size() / 2 - 1] + v[v.size() / 2]);
    return s;
}

static void fillRandom(std::vector<float>& m, unsigned seed) {
    unsigned x = seed;
    for (auto& f : m) {  // xorshift32 -> [0,1); deterministic across runs and machines
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        f = (x >> 8) * (1.0f / 16777216.0f);
    }
}

// Max relative error of `got` against reference `ref` (all ref values are > 0).
static double maxRelErr(const std::vector<float>& ref, const std::vector<float>& got) {
    double worst = 0;
    for (size_t i = 0; i < ref.size(); ++i) {
        double r = ref[i], g = got[i];
        double e = std::fabs(g - r) / std::max(std::fabs(r), 1e-12);
        if (e > worst || std::isnan(e)) worst = std::isnan(e) ? INFINITY : e;
    }
    return worst;
}

static double gflops(int N, double sec) {
    return sec > 0 ? (2.0 * N * N * (double)N) / sec / 1e9 : 0;
}

static double memAvailableMiB() {
    FILE* f = fopen("/proc/meminfo", "r");
    if (!f) return -1;
    char line[256];
    double kb = -1;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "MemAvailable: %lf kB", &kb) == 1) break;
    fclose(f);
    return kb < 0 ? -1 : kb / 1024.0;
}

struct Row {
    int N;
    Stat cpu1, cpuMT, naive, tiled, h2d, d2h, e2e;
    double errNaive, errTiled, errMT;
    double gpuUsedMiB;  // GPU memory in use (whole device) with this size's buffers resident
    bool pass;
};

static void usage(const char* p) {
    printf("CudaLite matrix-multiplication benchmark v" VERSION "\n"
           "Usage: %s [options]\n"
           "  --quick        sizes 512,1024; few repetitions (used by the boot service)\n"
           "  --full         sizes 512,1024,2048,4096 (default)\n"
           "  --sizes a,b,c  explicit comma-separated matrix sizes\n"
           "  --reps N       GPU repetitions per size (CPU repetitions are scaled down)\n"
           "  --out DIR      also write DIR/cudalite-benchmark-<UTC time>.csv and DIR/latest.csv\n"
           "  --help         this text\n", p);
}

int main(int argc, char** argv) {
    std::vector<int> sizes = {512, 1024, 2048, 4096};
    int gpuReps = 10;
    bool quick = false;
    std::string outDir;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--quick") {
            quick = true;
            sizes = {512, 1024};
            gpuReps = 5;
        } else if (a == "--full") {
            quick = false;
            sizes = {512, 1024, 2048, 4096};
            gpuReps = 10;
        } else if (a == "--sizes" && i + 1 < argc) {
            sizes.clear();
            char* s = strdup(argv[++i]);
            for (char* t = strtok(s, ","); t; t = strtok(nullptr, ",")) sizes.push_back(atoi(t));
            free(s);
        } else if (a == "--reps" && i + 1 < argc) {
            gpuReps = std::max(1, atoi(argv[++i]));
        } else if (a == "--out" && i + 1 < argc) {
            outDir = argv[++i];
        } else if (a == "--help" || a == "-h") {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown option: %s\n", a.c_str());
            usage(argv[0]);
            return 64;
        }
    }
    for (int n : sizes)
        if (n < 16 || n > 16384) {
            fprintf(stderr, "invalid size %d (allowed 16..16384)\n", n);
            return 64;
        }

    // ---- device discovery -------------------------------------------------
    int devCount = 0;
    cudaError_t st = cudaGetDeviceCount(&devCount);
    if (st != cudaSuccess || devCount == 0) {
        fprintf(stderr, "No usable CUDA device: %s\n", cudaGetErrorString(st));
        return 1;
    }
    CUDA_CHECK(cudaSetDevice(0));
    cudaDeviceProp prop{};
    CUDA_CHECK(cudaGetDeviceProperties(&prop, 0));
    int drv = 0, rt = 0;
    CUDA_CHECK(cudaDriverGetVersion(&drv));
    CUDA_CHECK(cudaRuntimeGetVersion(&rt));
    int cpuThreads = (int)std::max(1u, std::thread::hardware_concurrency());

    time_t t0 = time(nullptr);
    char stamp[32];
    strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", gmtime(&t0));

    printf("==== CudaLite OS benchmark v" VERSION " (%s mode) ====\n", quick ? "quick" : "full");
    printf("time (UTC)    : %s\n", stamp);
    printf("GPU           : %s  (compute %d.%d, %d SMs, %.0f MiB VRAM)\n", prop.name, prop.major,
           prop.minor, prop.multiProcessorCount, prop.totalGlobalMem / 1048576.0);
    printf("CUDA driver   : %d.%d   runtime: %d.%d (statically linked)\n", drv / 1000,
           (drv % 1000) / 10, rt / 1000, (rt % 1000) / 10);
    printf("CPU threads   : %d   MemAvailable: %.0f MiB\n", cpuThreads, memAvailableMiB());
    printf("workload      : C = A x B, float32, 2*N^3 FLOP, GPU reps=%d, medians reported\n\n", gpuReps);

    size_t freeB0 = 0, totalB = 0;
    CUDA_CHECK(cudaMemGetInfo(&freeB0, &totalB));  // forces context creation
    double wallStart = nowSec();

    cudaEvent_t e0, e1, e2, e3;
    CUDA_CHECK(cudaEventCreate(&e0));
    CUDA_CHECK(cudaEventCreate(&e1));
    CUDA_CHECK(cudaEventCreate(&e2));
    CUDA_CHECK(cudaEventCreate(&e3));

    std::vector<Row> rows;
    bool allPass = true;
    double peakGpuUsedMiB = (totalB - freeB0) / 1048576.0;

    for (int N : sizes) {
        size_t elems = (size_t)N * N, bytes = elems * sizeof(float);
        double needMiB = 3.0 * bytes / 1048576.0 * 2;  // host: A,B,Cref + GPU result copies
        double avail = memAvailableMiB();
        if (avail > 0 && needMiB * 1.5 > avail) {
            printf("N=%d: skipped (needs ~%.0f MiB host RAM, %.0f MiB available)\n", N, needMiB, avail);
            continue;
        }
        size_t freeNow = 0, tot = 0;
        CUDA_CHECK(cudaMemGetInfo(&freeNow, &tot));
        if (3 * bytes + (64u << 20) > freeNow) {
            printf("N=%d: skipped (needs %.0f MiB VRAM, %.0f MiB free)\n", N, 3.0 * bytes / 1048576.0,
                   freeNow / 1048576.0);
            continue;
        }

        std::vector<float> hA(elems), hB(elems), hRef(elems), hMT(elems), hNaive(elems), hTiled(elems);
        fillRandom(hA, 0x1234567u + N);
        fillRandom(hB, 0x89abcdefu + N);

        Row r{};
        r.N = N;

        // ---- CPU -----------------------------------------------------------
        int cpuReps = (N <= 1024) ? 3 : 1;
        std::vector<double> t1, tm;
        for (int i = 0; i < cpuReps; ++i) {
            double s = nowSec();
            cpuMatMul(hA.data(), hB.data(), hRef.data(), N, 1);
            t1.push_back(nowSec() - s);
        }
        for (int i = 0; i < std::max(2, cpuReps); ++i) {
            double s = nowSec();
            cpuMatMul(hA.data(), hB.data(), hMT.data(), N, cpuThreads);
            tm.push_back(nowSec() - s);
        }
        r.cpu1 = summarize(t1);
        r.cpuMT = summarize(tm);
        r.errMT = maxRelErr(hRef, hMT);

        // ---- GPU -----------------------------------------------------------
        float *dA, *dB, *dC;
        CUDA_CHECK(cudaMalloc(&dA, bytes));
        CUDA_CHECK(cudaMalloc(&dB, bytes));
        CUDA_CHECK(cudaMalloc(&dC, bytes));
        size_t freeAfter = 0;
        CUDA_CHECK(cudaMemGetInfo(&freeAfter, &tot));
        r.gpuUsedMiB = (tot - freeAfter) / 1048576.0;
        peakGpuUsedMiB = std::max(peakGpuUsedMiB, r.gpuUsedMiB);

        dim3 block(TILE, TILE), grid((N + TILE - 1) / TILE, (N + TILE - 1) / TILE);

        // warm-up (context, module load, clocks): not timed
        CUDA_CHECK(cudaMemcpy(dA, hA.data(), bytes, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(dB, hB.data(), bytes, cudaMemcpyHostToDevice));
        for (int i = 0; i < 3; ++i) {
            matMulNaive<<<grid, block>>>(dA, dB, dC, N);
            matMulTiled<<<grid, block>>>(dA, dB, dC, N);
        }
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());

        std::vector<double> tn, tt, th, td, te;
        for (int i = 0; i < gpuReps; ++i) {  // naive kernel, kernel-only
            CUDA_CHECK(cudaEventRecord(e0));
            matMulNaive<<<grid, block>>>(dA, dB, dC, N);
            CUDA_CHECK(cudaEventRecord(e1));
            CUDA_CHECK(cudaEventSynchronize(e1));
            float ms;
            CUDA_CHECK(cudaEventElapsedTime(&ms, e0, e1));
            tn.push_back(ms / 1e3);
        }
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaMemcpy(hNaive.data(), dC, bytes, cudaMemcpyDeviceToHost));

        for (int i = 0; i < gpuReps; ++i) {  // tiled: H2D -> kernel -> D2H, each timed
            CUDA_CHECK(cudaEventRecord(e0));
            CUDA_CHECK(cudaMemcpy(dA, hA.data(), bytes, cudaMemcpyHostToDevice));
            CUDA_CHECK(cudaMemcpy(dB, hB.data(), bytes, cudaMemcpyHostToDevice));
            CUDA_CHECK(cudaEventRecord(e1));
            matMulTiled<<<grid, block>>>(dA, dB, dC, N);
            CUDA_CHECK(cudaEventRecord(e2));
            CUDA_CHECK(cudaMemcpy(hTiled.data(), dC, bytes, cudaMemcpyDeviceToHost));
            CUDA_CHECK(cudaEventRecord(e3));
            CUDA_CHECK(cudaEventSynchronize(e3));
            float a, b, c, d;
            CUDA_CHECK(cudaEventElapsedTime(&a, e0, e1));
            CUDA_CHECK(cudaEventElapsedTime(&b, e1, e2));
            CUDA_CHECK(cudaEventElapsedTime(&c, e2, e3));
            CUDA_CHECK(cudaEventElapsedTime(&d, e0, e3));
            th.push_back(a / 1e3);
            tt.push_back(b / 1e3);
            td.push_back(c / 1e3);
            te.push_back(d / 1e3);
        }
        CUDA_CHECK(cudaGetLastError());
        cudaFree(dA);
        cudaFree(dB);
        cudaFree(dC);

        r.naive = summarize(tn);
        r.tiled = summarize(tt);
        r.h2d = summarize(th);
        r.d2h = summarize(td);
        r.e2e = summarize(te);
        r.errNaive = maxRelErr(hRef, hNaive);
        r.errTiled = maxRelErr(hRef, hTiled);
        const double tol = 1e-3;
        r.pass = r.errNaive < tol && r.errTiled < tol && r.errMT < tol;
        allPass = allPass && r.pass;

        printf("N = %d  (%.1f MiB per matrix)\n", N, bytes / 1048576.0);
        printf("  CPU 1 thread        : %9.2f ms  [%.2f-%.2f]   %8.2f GFLOP/s\n", r.cpu1.med * 1e3,
               r.cpu1.lo * 1e3, r.cpu1.hi * 1e3, gflops(N, r.cpu1.med));
        printf("  CPU %2d threads      : %9.2f ms  [%.2f-%.2f]   %8.2f GFLOP/s\n", cpuThreads,
               r.cpuMT.med * 1e3, r.cpuMT.lo * 1e3, r.cpuMT.hi * 1e3, gflops(N, r.cpuMT.med));
        printf("  GPU naive kernel    : %9.3f ms  [%.3f-%.3f]   %8.2f GFLOP/s   (kernel only)\n",
               r.naive.med * 1e3, r.naive.lo * 1e3, r.naive.hi * 1e3, gflops(N, r.naive.med));
        printf("  GPU tiled kernel    : %9.3f ms  [%.3f-%.3f]   %8.2f GFLOP/s   (kernel only)\n",
               r.tiled.med * 1e3, r.tiled.lo * 1e3, r.tiled.hi * 1e3, gflops(N, r.tiled.med));
        printf("  GPU H2D / D2H       : %9.3f ms / %.3f ms   (pageable host memory)\n", r.h2d.med * 1e3,
               r.d2h.med * 1e3);
        printf("  GPU end-to-end      : %9.3f ms  [%.3f-%.3f]   %8.2f GFLOP/s   (H2D+kernel+D2H)\n",
               r.e2e.med * 1e3, r.e2e.lo * 1e3, r.e2e.hi * 1e3, gflops(N, r.e2e.med));
        printf("  speedup vs CPU 1T   : %8.1fx kernel-only, %8.1fx end-to-end\n",
               r.cpu1.med / r.tiled.med, r.cpu1.med / r.e2e.med);
        printf("  speedup vs CPU %2dT  : %8.1fx kernel-only, %8.1fx end-to-end\n", cpuThreads,
               r.cpuMT.med / r.tiled.med, r.cpuMT.med / r.e2e.med);
        printf("  GPU memory in use   : %9.0f MiB of %.0f MiB (whole device, incl. CUDA context)\n",
               r.gpuUsedMiB, tot / 1048576.0);
        printf("  max rel. error      : naive %.2e  tiled %.2e  cpu-mt %.2e  => %s\n\n", r.errNaive,
               r.errTiled, r.errMT, r.pass ? "PASS" : "FAIL");
        fflush(stdout);
        rows.push_back(r);
    }

    double wall = nowSec() - wallStart;
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    double cpuSec = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec +
                    ru.ru_stime.tv_usec / 1e6;
    printf("---- summary ----\n");
    printf("wall time          : %.2f s\n", wall);
    printf("process CPU use    : %.0f %% of one core (%.1f core-seconds)\n", 100.0 * cpuSec / wall, cpuSec);
    printf("peak process RSS   : %.0f MiB\n", ru.ru_maxrss / 1024.0);
    printf("peak GPU mem in use: %.0f MiB\n", peakGpuUsedMiB);
    printf("correctness        : %s\n", allPass && !rows.empty() ? "ALL PASS" : "FAILED / NO RESULTS");

    if (!outDir.empty() && !rows.empty()) {
        mkdir(outDir.c_str(), 0755);
        char tsfile[32];
        strftime(tsfile, sizeof tsfile, "%Y%m%dT%H%M%SZ", gmtime(&t0));
        std::string paths[2] = {outDir + "/cudalite-benchmark-" + tsfile + ".csv", outDir + "/latest.csv"};
        for (auto& p : paths) {
            FILE* f = fopen(p.c_str(), "w");
            if (!f) {
                fprintf(stderr, "cannot write %s\n", p.c_str());
                continue;
            }
            fprintf(f, "gpu,N,cpu1_ms,cpu_mt_ms,cpu_threads,gpu_naive_ms,gpu_tiled_ms,gpu_tiled_min_ms,"
                       "gpu_tiled_max_ms,h2d_ms,d2h_ms,gpu_e2e_ms,cpu1_gflops,cpu_mt_gflops,"
                       "gpu_tiled_gflops,gpu_e2e_gflops,speedup_kernel_vs_cpu1,speedup_e2e_vs_cpu1,"
                       "gpu_mem_used_mib,max_rel_err,pass\n");
            for (auto& r : rows)
                fprintf(f, "\"%s\",%d,%.3f,%.3f,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%.2f,"
                           "%.1f,%.1f,%.0f,%.3e,%d\n",
                        prop.name, r.N, r.cpu1.med * 1e3, r.cpuMT.med * 1e3, cpuThreads, r.naive.med * 1e3,
                        r.tiled.med * 1e3, r.tiled.lo * 1e3, r.tiled.hi * 1e3, r.h2d.med * 1e3,
                        r.d2h.med * 1e3, r.e2e.med * 1e3, gflops(r.N, r.cpu1.med), gflops(r.N, r.cpuMT.med),
                        gflops(r.N, r.tiled.med), gflops(r.N, r.e2e.med), r.cpu1.med / r.tiled.med,
                        r.cpu1.med / r.e2e.med, r.gpuUsedMiB, std::max(r.errNaive, r.errTiled),
                        r.pass ? 1 : 0);
            fclose(f);
        }
        printf("results written    : %s and %s\n", paths[0].c_str(), paths[1].c_str());
    }
    return (allPass && !rows.empty()) ? 0 : 2;
}
