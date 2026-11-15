#include <cstdio>
#include <cuda_runtime.h>

__global__ void helloKernel() {
    printf("Hello from CUDA thread %d\n", threadIdx.x);
}

int main() {
    int deviceCount = 0;
    cudaError_t status = cudaGetDeviceCount(&deviceCount);
    if (status != cudaSuccess || deviceCount == 0) {
        fprintf(stderr, "No CUDA device: %s\n", cudaGetErrorString(status));
        return 1;
    }
    cudaDeviceProp prop{};
    cudaGetDeviceProperties(&prop, 0);
    printf("GPU: %s\n", prop.name);

    helloKernel<<<1, 8>>>();
    status = cudaDeviceSynchronize();
    if (status != cudaSuccess) {
        fprintf(stderr, "Kernel failed: %s\n", cudaGetErrorString(status));
        return 1;
    }
    return 0;
}
