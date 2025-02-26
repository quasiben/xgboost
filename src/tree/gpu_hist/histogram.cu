/*!
 * Copyright 2020-2021 by XGBoost Contributors
 */
#include <thrust/reduce.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>
#include <thrust/functional.h>
#include <algorithm>
#include <ctgmath>
#include <limits>

#include "xgboost/base.h"
#include "row_partitioner.cuh"

#include "histogram.cuh"

#include "../../data/ellpack_page.cuh"
#include "../../common/device_helpers.cuh"

namespace xgboost {
namespace tree {
// Following 2 functions are slightly modified version of fbcuda.

/* \brief Constructs a rounding factor used to truncate elements in a sum such that the
   sum of the truncated elements is the same no matter what the order of the sum is.

 * Algorithm 5: Reproducible Sequential Sum in 'Fast Reproducible Floating-Point
 * Summation' by Demmel and Nguyen

 * In algorithm 5 the bound is calculated as $max(|v_i|) * n$.  Here we use the bound
 *
 * \begin{equation}
 *   max( fl(\sum^{V}_{v_i>0}{v_i}), fl(\sum^{V}_{v_i<0}|v_i|) )
 * \end{equation}
 *
 * to avoid outliers, as the full reduction is reproducible on GPU with reduction tree.
 */
template <typename T>
T CreateRoundingFactor(T max_abs, int n) {
  T delta = max_abs / (static_cast<T>(1.0) - 2 * n * std::numeric_limits<T>::epsilon());

  // Calculate ceil(log_2(delta)).
  // frexpf() calculates exp and returns `x` such that
  // delta = x * 2^exp, where `x` in (-1.0, -0.5] U [0.5, 1).
  // Because |x| < 1, exp is exactly ceil(log_2(delta)).
  int exp;
  std::frexp(delta, &exp);

  // return M = 2 ^ ceil(log_2(delta))
  return std::ldexp(static_cast<T>(1.0), exp);
}

namespace {
struct Pair {
  GradientPair first;
  GradientPair second;
};
__host__ XGBOOST_DEV_INLINE Pair operator+(Pair const& lhs, Pair const& rhs) {
  return {lhs.first + rhs.first, lhs.second + rhs.second};
}
}  // anonymous namespace

struct Clip : public thrust::unary_function<GradientPair, Pair> {
  static XGBOOST_DEV_INLINE float Pclip(float v) {
    return v > 0 ? v : 0;
  }
  static XGBOOST_DEV_INLINE float Nclip(float v) {
    return v < 0 ? abs(v) : 0;
  }

  XGBOOST_DEV_INLINE Pair operator()(GradientPair x) const {
    auto pg = Pclip(x.GetGrad());
    auto ph = Pclip(x.GetHess());

    auto ng = Nclip(x.GetGrad());
    auto nh = Nclip(x.GetHess());

    return { GradientPair{ pg, ph }, GradientPair{ ng, nh } };
  }
};

template <typename GradientSumT>
HistRounding<GradientSumT> CreateRoundingFactor(common::Span<GradientPair const> gpair) {
  using T = typename GradientSumT::ValueT;
  dh::XGBCachingDeviceAllocator<char> alloc;

  thrust::device_ptr<GradientPair const> gpair_beg {gpair.data()};
  thrust::device_ptr<GradientPair const> gpair_end {gpair.data() + gpair.size()};
  auto beg = thrust::make_transform_iterator(gpair_beg, Clip());
  auto end = thrust::make_transform_iterator(gpair_end, Clip());
  Pair p = dh::Reduce(thrust::cuda::par(alloc), beg, end, Pair{}, thrust::plus<Pair>{});
  GradientPair positive_sum {p.first}, negative_sum {p.second};

  auto histogram_rounding = GradientSumT {
    CreateRoundingFactor<T>(std::max(positive_sum.GetGrad(), negative_sum.GetGrad()),
                            gpair.size()),
    CreateRoundingFactor<T>(std::max(positive_sum.GetHess(), negative_sum.GetHess()),
                            gpair.size()) };

  using IntT = typename HistRounding<GradientSumT>::SharedSumT::ValueT;

  /**
   * Factor for converting gradients from fixed-point to floating-point.
   */
  GradientSumT to_floating_point =
      histogram_rounding /
      T(IntT(1) << (sizeof(typename GradientSumT::ValueT) * 8 -
                    2));  // keep 1 for sign bit
  /**
   * Factor for converting gradients from floating-point to fixed-point. For
   * f64:
   *
   *   Precision = 64 - 1 - log2(rounding)
   *
   * rounding is calcuated as exp(m), see the rounding factor calcuation for
   * details.
   */
  GradientSumT to_fixed_point = GradientSumT(
      T(1) / to_floating_point.GetGrad(), T(1) / to_floating_point.GetHess());

  return {histogram_rounding, to_fixed_point, to_floating_point};
}

template HistRounding<GradientPairPrecise>
CreateRoundingFactor(common::Span<GradientPair const> gpair);
template HistRounding<GradientPair>
CreateRoundingFactor(common::Span<GradientPair const> gpair);

template <typename GradientSumT, bool use_shared_memory_histograms>
__global__ void SharedMemHistKernel(EllpackDeviceAccessor matrix,
                                    FeatureGroupsAccessor feature_groups,
                                    common::Span<const RowPartitioner::RowIndexT> d_ridx,
                                    GradientSumT* __restrict__ d_node_hist,
                                    const GradientPair* __restrict__ d_gpair,
                                    HistRounding<GradientSumT> const rounding) {
  using SharedSumT = typename HistRounding<GradientSumT>::SharedSumT;
  using T = typename GradientSumT::ValueT;

  extern __shared__ char smem[];
  FeatureGroup group = feature_groups[blockIdx.y];
  SharedSumT *smem_arr = reinterpret_cast<SharedSumT *>(smem);
  if (use_shared_memory_histograms) {
    dh::BlockFill(smem_arr, group.num_bins, SharedSumT());
    __syncthreads();
  }
  int feature_stride = matrix.is_dense ? group.num_features : matrix.row_stride;
  size_t n_elements = feature_stride * d_ridx.size();
  for (auto idx : dh::GridStrideRange(static_cast<size_t>(0), n_elements)) {
    int ridx = d_ridx[idx / feature_stride];
    int gidx = matrix.gidx_iter[ridx * matrix.row_stride + group.start_feature +
                                idx % feature_stride];
    if (gidx != matrix.NumBins()) {
      // If we are not using shared memory, accumulate the values directly into
      // global memory
      gidx = use_shared_memory_histograms ? gidx - group.start_bin : gidx;
      if (use_shared_memory_histograms) {
        auto adjusted = rounding.ToFixedPoint(d_gpair[ridx]);
        dh::AtomicAddGpair(smem_arr + gidx, adjusted);
      } else {
        GradientSumT truncated{
            TruncateWithRoundingFactor<T>(rounding.rounding.GetGrad(),
                                          d_gpair[ridx].GetGrad()),
            TruncateWithRoundingFactor<T>(rounding.rounding.GetHess(),
                                          d_gpair[ridx].GetHess()),
        };
        dh::AtomicAddGpair(d_node_hist + gidx, truncated);
      }
    }
  }

  if (use_shared_memory_histograms) {
    // Write shared memory back to global memory
    __syncthreads();
    for (auto i : dh::BlockStrideRange(0, group.num_bins)) {
      auto truncated = rounding.ToFloatingPoint(smem_arr[i]);
      dh::AtomicAddGpair(d_node_hist + group.start_bin + i, truncated);
    }
  }
}

template <typename GradientSumT>
void BuildGradientHistogram(EllpackDeviceAccessor const& matrix,
                            FeatureGroupsAccessor const& feature_groups,
                            common::Span<GradientPair const> gpair,
                            common::Span<const uint32_t> d_ridx,
                            common::Span<GradientSumT> histogram,
                            HistRounding<GradientSumT> rounding,
                            bool force_global_memory) {
  // decide whether to use shared memory
  int device = 0;
  dh::safe_cuda(cudaGetDevice(&device));
  // opt into maximum shared memory for the kernel if necessary
  int max_shared_memory = dh::MaxSharedMemoryOptin(device);

  size_t smem_size = sizeof(typename HistRounding<GradientSumT>::SharedSumT) *
                     feature_groups.max_group_bins;
  bool shared = !force_global_memory && smem_size <= max_shared_memory;
  smem_size = shared ? smem_size : 0;

  auto runit = [&](auto kernel) {
    if (shared) {
      dh::safe_cuda(cudaFuncSetAttribute(
          kernel, cudaFuncAttributeMaxDynamicSharedMemorySize,
          max_shared_memory));
    }

    // determine the launch configuration
    int min_grid_size;
    int block_threads = 1024;
    dh::safe_cuda(cudaOccupancyMaxPotentialBlockSize(
        &min_grid_size, &block_threads, kernel, smem_size, 0));

    int num_groups = feature_groups.NumGroups();
    int n_mps = 0;
    dh::safe_cuda(
        cudaDeviceGetAttribute(&n_mps, cudaDevAttrMultiProcessorCount, device));
    int n_blocks_per_mp = 0;
    dh::safe_cuda(cudaOccupancyMaxActiveBlocksPerMultiprocessor(
        &n_blocks_per_mp, kernel, block_threads, smem_size));
    unsigned grid_size = n_blocks_per_mp * n_mps;

    // TODO(canonizer): This is really a hack, find a better way to distribute
    // the data among thread blocks. The intention is to generate enough thread
    // blocks to fill the GPU, but avoid having too many thread blocks, as this
    // is less efficient when the number of rows is low. At least one thread
    // block per feature group is required. The number of thread blocks:
    // - for num_groups <= num_groups_threshold, around  grid_size * num_groups
    // - for num_groups_threshold <= num_groups <= num_groups_threshold *
    // grid_size,
    //     around grid_size * num_groups_threshold
    // - for num_groups_threshold * grid_size <= num_groups, around num_groups
    int num_groups_threshold = 4;
    grid_size = common::DivRoundUp(
        grid_size, common::DivRoundUp(num_groups, num_groups_threshold));

    using T = typename GradientSumT::ValueT;
    dh::LaunchKernel {dim3(grid_size, num_groups),
          static_cast<uint32_t>(block_threads),
          smem_size} (kernel, matrix, feature_groups, d_ridx,
                      histogram.data(), gpair.data(), rounding);
  };

  if (shared) {
    runit(SharedMemHistKernel<GradientSumT, true>);
  } else {
    runit(SharedMemHistKernel<GradientSumT, false>);
  }

  dh::safe_cuda(cudaGetLastError());
}

template void BuildGradientHistogram<GradientPair>(
    EllpackDeviceAccessor const& matrix,
    FeatureGroupsAccessor const& feature_groups,
    common::Span<GradientPair const> gpair,
    common::Span<const uint32_t> ridx,
    common::Span<GradientPair> histogram,
    HistRounding<GradientPair> rounding,
    bool force_global_memory);

template void BuildGradientHistogram<GradientPairPrecise>(
    EllpackDeviceAccessor const& matrix,
    FeatureGroupsAccessor const& feature_groups,
    common::Span<GradientPair const> gpair,
    common::Span<const uint32_t> ridx,
    common::Span<GradientPairPrecise> histogram,
    HistRounding<GradientPairPrecise> rounding,
    bool force_global_memory);

}  // namespace tree
}  // namespace xgboost
