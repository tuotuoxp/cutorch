#ifndef THC_TENSOR_RANDOM_CUH
#define THC_TENSOR_RANDOM_CUH

#include "THCNumerics.cuh"
#include "THCReduceApplyUtils.cuh"
#include "THCTensorMathReduce.cuh"

#include <curand_kernel.h>

#define MAX_NUM_BLOCKS 64
#define BLOCK_SIZE 256
/* Separate kernel because curand_log_normal gets extra parameters. */

template <typename T>
__global__ void generateLogNormal(curandStateMtgp32 *state, int size, T *result, double mean, double stddev)
{
  int idx = blockIdx.x * BLOCK_SIZE + threadIdx.x;
  int rounded_size = THCCeilDiv(size, BLOCK_SIZE) * BLOCK_SIZE;
  for (int i = idx; i < rounded_size; i += BLOCK_SIZE * MAX_NUM_BLOCKS) {
    float x = curand_log_normal(&state[blockIdx.x], mean, stddev);
    if (i < size) {
      result[i] = ScalarConvert<float, T>::to(x);
    }
  }
}

template <>
__global__ void generateLogNormal<double>(curandStateMtgp32 *state, int size, double *result, double mean, double stddev)
{
  int idx = blockIdx.x * BLOCK_SIZE + threadIdx.x;
  int rounded_size = THCCeilDiv(size, BLOCK_SIZE) * BLOCK_SIZE;
  for (int i = idx; i < rounded_size; i += BLOCK_SIZE * MAX_NUM_BLOCKS) {
    double x = curand_log_normal_double(&state[blockIdx.x], mean, stddev);
    if (i < size) {
      result[i] = x;
    }
  }
}

#undef MAX_NUM_BLOCKS
#undef BLOCK_SIZE

// Normalizes the L1 norm of every row to 1; used by multinomial
template <typename T>
__global__ void renormRowsL1(T* dist, long rows, long cols) {
  extern __shared__ __align__(sizeof(T)) unsigned char my_smem[];
  T *smem = reinterpret_cast<T *>(my_smem);

  for (long row = blockIdx.x; row < rows; row += gridDim.x) {
    T sum = ScalarConvert<int, T>::to(0);
    for (long col = threadIdx.x; col < cols; col += blockDim.x) {
      sum = THCNumerics<T>::add(sum, dist[row * cols + col]);
    }

    sum = reduceBlock(smem, blockDim.x, sum, ReduceAdd<T, T>(), ScalarConvert<int, T>::to(0));
    if (threadIdx.x == 0) {
      smem[0] = sum;
    }
    __syncthreads();

    sum = smem[0];
    if (THCNumerics<T>::gt(sum, ScalarConvert<int, T>::to(0))) {
      for (long col = threadIdx.x; col < cols; col += blockDim.x) {
        dist[row * cols + col] = THCNumerics<T>::div(dist[row * cols + col], sum);
      }
    }
  }
}

template <typename T>
__global__ void
sampleMultinomialOnce(T* dest,
                      long distributions,
                      int categories,
                      T* dist) {
  extern __shared__ __align__(sizeof(T)) unsigned char my_smem[];
  T *smem = reinterpret_cast<T *>(my_smem);
  T zero = ScalarConvert<int, T>::to(0);

  for (long curDist = blockIdx.x;
       curDist < distributions; curDist += gridDim.x) {
    // Each block handles one distribution
    // First pass, find the total sum of the distribution
    T sum = zero;
    for (int cat = threadIdx.x; cat < categories; cat += blockDim.x) {
      sum = THCNumerics<T>::add(sum, dist[curDist * categories + cat]);
    }

    // threadIdx.x == 0 has the sum value from this
    sum = reduceBlock(smem, blockDim.x, sum, ReduceAdd<T, T>(), zero);

    // Broadcast sum and sample value
    if (threadIdx.x == 0) {
      smem[0] = sum;
      smem[1] = dest[curDist];
    }
    __syncthreads();

    sum = smem[0];
    T sample = smem[1];
    __syncthreads();

    if (THCNumerics<T>::eq(sum,  zero) || THCNumerics<T>::eq(sample, zero)) {
      // Choose the first element
      if (threadIdx.x == 0) {
        dest[curDist] = ScalarConvert<int, T>::to(1);
      }

      continue;
    }

    int chunks = THCCeilDiv(categories, (int) blockDim.x);
    T prevHighProb = zero;

    for (int chunk = 0; chunk < chunks; ++chunk) {
      // All threads in bounds load a value
      int cat = chunk * blockDim.x + threadIdx.x;

      T val =
        cat < categories ? THCNumerics<T>::div(dist[curDist * categories + cat], sum) : 
        zero;

      smem[threadIdx.x] = val;
      __syncthreads();

      // Perform an inclusive prefix sum of the shared memory contents
      for (int offset = 1; offset < blockDim.x; offset *= 2) {
        T val = zero;

        if (threadIdx.x >= offset) {
          val = THCNumerics<T>::add(smem[threadIdx.x - offset], smem[threadIdx.x]);
        }

        __syncthreads();
        if (threadIdx.x >= offset) {
          smem[threadIdx.x] = val;
        }
        __syncthreads();
      }

      // Each thread will check to see if the sample falls in its
      // bucket
      T curBucket = THCNumerics<T>::add(smem[threadIdx.x], prevHighProb);
      T prevBucket =
        threadIdx.x == 0 ? prevHighProb :
        THCNumerics<T>::add(smem[threadIdx.x - 1], prevHighProb);
      bool inBucket =
        (cat < categories) &&
        (!THCNumerics<T>::gt(sample, curBucket)) &&
        (THCNumerics<T>::gt(sample, prevBucket));

      if (inBucket) {
        // We're done; we have the sample
        // Torch indices are 1-based
        // FIXME: broadcast exit flag?
        dest[curDist] = ScalarConvert<int, T>::to(cat + TH_INDEX_BASE);
      }

      // Store the previous scan's high value for future use
      prevHighProb = THCNumerics<T>::add(prevHighProb, smem[blockDim.x - 1]);

      __syncthreads();
    }
  }
}

template <typename T>
__device__ int binarySearchForMultinomial(T* dist,
                                          int size,
                                          T val) {
  int start = 0;
  int end = size;

  while (end - start > 0) {
    int mid = start + (end - start) / 2;

    T midVal = dist[mid];
    if (THCNumerics<T>::lt(midVal, val)) {
      start = mid + 1;
    } else {
      end = mid;
    }
  }

  if (start == size) {
    // No probability mass or precision problems; just return the
    // first element
    start = 0;
  }

  return start;
}

template <typename T>
__global__ void
sampleMultinomialWithReplacement(curandStateMtgp32* state,
                                 int totalSamples,
                                 T* dest,
                                 long distributions,
                                 int categories,
                                 T* normDistPrefixSum) {
  // At the moment, each warp computes one sample value in the binary
  // search due to divergence. It seems possible to compute multiple
  // values and limit divergence though later on. However, no matter
  // what, all block threads must participate in the curand_uniform
  // call to update the generator state.

  // The block determines the distribution for which we generate a point
  for (long curDist = blockIdx.x;
       curDist < distributions;
       curDist += gridDim.x) {
    for (int sampleBase = 0;
         sampleBase < totalSamples; sampleBase += blockDim.y) {
      // The warp determines the sample
      int sample = sampleBase + threadIdx.y;

      // All threads participate in this
      T r = ScalarConvert<float, T>::to(curand_uniform(&state[blockIdx.x]));

      if (threadIdx.x == 0 && sample < totalSamples) {
        // Find the bucket that a uniform sample lies in
        int choice = binarySearchForMultinomial<T>(
          normDistPrefixSum + curDist * categories,
          categories,
          r);

        // Torch indices are 1-based
        dest[curDist * totalSamples + sample] = ScalarConvert<int, T>::to(choice + TH_INDEX_BASE);
      }
    }
  }
}

template <typename T>
__global__ void
sampleMultinomialWithoutReplacement(curandStateMtgp32* state,
                                    int totalSamples,
                                    int sample,
                                    T* dest,
                                    long distributions,
                                    int categories,
                                    T* origDist,
                                    T* normDistPrefixSum) {
  // At the moment, each warp computes one sample value in the binary
  // search due to divergence. It seems possible to compute multiple
  // values and limit divergence though later on. However, no matter
  // what, all block threads must participate in the curand_uniform
  // call to update the generator state.

  // The block and warp determines the distribution for which we
  // generate a point
  for (long curDistBase = blockIdx.x * blockDim.y;
       curDistBase < distributions;
       curDistBase += gridDim.x * blockDim.y) {
    // The warp determines the distribution
    long curDist = curDistBase + threadIdx.y;

    // All threads must participate in this
    T r = ScalarConvert<float, T>::to(curand_uniform(&state[blockIdx.x]));

    if (threadIdx.x == 0 && curDist < distributions) {
      // Find the bucket that a uniform sample lies in
      int choice = binarySearchForMultinomial<T>(
        normDistPrefixSum + curDist * categories,
        categories,
        r);

      // Torch indices are 1-based
      dest[curDist * totalSamples + sample] = ScalarConvert<int, T>::to(choice + TH_INDEX_BASE);

      // Without replacement, so update the original probability so it
      // is not considered a second time
      origDist[curDist * categories + choice] = ScalarConvert<int, T>::to(0);
    }
  }
}

#endif // THC_TENSOR_RANDOM_CUH
