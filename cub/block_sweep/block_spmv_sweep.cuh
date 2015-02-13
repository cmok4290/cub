/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2014, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/**
 * \file
 * cub::BlockSpmvSweep implements a stateful abstraction of CUDA thread blocks for participating in device-wide SpMV.
 */

#pragma once

#include <iterator>

#include "../util_type.cuh"
#include "../block/block_load.cuh"
#include "../grid/grid_queue.cuh"
#include "../iterator/cache_modified_input_iterator.cuh"
#include "../util_namespace.cuh"

/// Optional outer namespace(s)
CUB_NS_PREFIX

/// CUB namespace
namespace cub {


/******************************************************************************
 * Tuning policy
 ******************************************************************************/

/**
 * Parameterizable tuning policy type for BlockSpmvSweep
 */
template <
    int                             _BLOCK_THREADS,                         ///< Threads per thread block
    int                             _ITEMS_PER_THREAD,                      ///< Items per thread (per tile of input)
    CacheLoadModifier               _MATRIX_ROW_OFFSETS_LOAD_MODIFIER,      ///< Cache load modifier for reading CSR row-offsets
    CacheLoadModifier               _MATRIX_COLUMN_INDICES_LOAD_MODIFIER,   ///< Cache load modifier for reading CSR column-indices
    CacheLoadModifier               _MATRIX_VALUES_LOAD_MODIFIER,           ///< Cache load modifier for reading CSR values
    CacheLoadModifier               _VECTOR_VALUES_LOAD_MODIFIER>           ///< Cache load modifier for reading vector values
struct BlockSpmvSweepPolicy
{
    enum
    {
        BLOCK_THREADS                                           = _BLOCK_THREADS,                   ///< Threads per thread block
        ITEMS_PER_THREAD                                        = _ITEMS_PER_THREAD,                ///< Items per thread (per tile of input)
    };

    static const CacheLoadModifier MATRIX_ROW_OFFSETS_LOAD_MODIFIER    = _MATRIX_ROW_OFFSETS_LOAD_MODIFIER;       ///< Cache load modifier for reading CSR row-offsets
    static const CacheLoadModifier MATRIX_COLUMN_INDICES_LOAD_MODIFIER = _MATRIX_COLUMN_INDICES_LOAD_MODIFIER;    ///< Cache load modifier for reading CSR column-indices
    static const CacheLoadModifier MATRIX_VALUES_LOAD_MODIFIER         = _MATRIX_VALUES_LOAD_MODIFIER;            ///< Cache load modifier for reading CSR values
    static const CacheLoadModifier VECTOR_VALUES_LOAD_MODIFIER         = _VECTOR_VALUES_LOAD_MODIFIER;            ///< Cache load modifier for reading vector values
};


/******************************************************************************
 * Thread block abstractions
 ******************************************************************************/

/**
 * \brief BlockSpmvSweep implements a stateful abstraction of CUDA thread blocks for participating in device-wide SpMV.
 */
template <
    typename    BlockSpmvSweepPolicyT,      ///< Parameterized BlockSpmvSweepPolicy tuning policy type
    typename    VertexT,                    ///< Integer type for vertex identifiers
    typename    ValueT,                     ///< Matrix and vector value type
    typename    OffsetT,                    ///< Signed integer type for sequence offsets
    int         PTX_ARCH = CUB_PTX_ARCH>    ///< PTX compute capability
struct BlockSpmvSweep
{
    //---------------------------------------------------------------------
    // Types and constants
    //---------------------------------------------------------------------

    /// Constants
    enum
    {
        BLOCK_THREADS           = BlockSpmvSweepPolicyT::BLOCK_THREADS,
        ITEMS_PER_THREAD        = BlockSpmvSweepPolicyT::ITEMS_PER_THREAD,
        TILE_ITEMS              = BLOCK_THREADS * ITEMS_PER_THREAD,
    };

    /// Input iterator wrapper types (for applying cache modifiers)

    typedef CacheModifiedInputIterator<
            BlockSpmvSweepPolicyT::MATRIX_ROW_OFFSETS_LOAD_MODIFIER,
            OffsetT,
            OffsetT>
        MatrixValueIteratorT;

    typedef CacheModifiedInputIterator<
            BlockSpmvSweepPolicyT::MATRIX_COLUMN_INDICES_LOAD_MODIFIER,
            VertexT,
            OffsetT>
        MatrixRowOffsetsIteratorT;

    typedef CacheModifiedInputIterator<
            BlockSpmvSweepPolicyT::MATRIX_VALUES_LOAD_MODIFIER,
            ValueT,
            OffsetT>
        MatrixColumnIndicesIteratorT;

    typedef CacheModifiedInputIterator<
            BlockSpmvSweepPolicyT::VECTOR_VALUES_LOAD_MODIFIER,
            ValueT,
            OffsetT>
        VectorValueIteratorT;


    /// Shared memory type required by this thread block
    struct _TempStorage
    {
        union
        {
            OffsetT row_offset;
            ValueT  partial_sum;

        } merge[TILE_ITEMS];


        OffsetT block_row_offsets_start_idx;
        OffsetT block_column_indices_start_idx;
    };


    /// Temporary storage type (unionable)
    struct TempStorage : Uninitialized<_TempStorage> {};


    //---------------------------------------------------------------------
    // Per-thread fields
    //---------------------------------------------------------------------

    /// Reference to temp_storage
    _TempStorage &temp_storage;

    /// Sample input iterator (with cache modifier applied, if possible)
    WrappedSampleIteratorT d_wrapped_samples;

    /// Native pointer for input samples (possibly NULL if unavailable)
    SampleT* d_native_samples;

    /// The number of output bins for each channel
    int (&num_output_bins)[NUM_ACTIVE_CHANNELS];

    /// The number of privatized bins for each channel
    int (&num_privatized_bins)[NUM_ACTIVE_CHANNELS];

    /// Reference to gmem privatized histograms for each channel
    CounterT* d_privatized_histograms[NUM_ACTIVE_CHANNELS];

    /// Reference to final output histograms (gmem)
    CounterT* (&d_output_histograms)[NUM_ACTIVE_CHANNELS];

    /// The transform operator for determining output bin-ids from privatized counter indices, one for each channel
    OutputDecodeOpT (&output_decode_op)[NUM_ACTIVE_CHANNELS];

    /// The transform operator for determining privatized counter indices from samples, one for each channel
    PrivatizedDecodeOpT (&privatized_decode_op)[NUM_ACTIVE_CHANNELS];


    //---------------------------------------------------------------------
    // Initialize privatized bin counters
    //---------------------------------------------------------------------

    // Initialize privatized bin counters
    __device__ __forceinline__ void InitBinCounters(CounterT* privatized_histograms[NUM_ACTIVE_CHANNELS])
    {
        // Initialize histogram bin counts to zeros
        #pragma unroll
        for (int CHANNEL = 0; CHANNEL < NUM_ACTIVE_CHANNELS; ++CHANNEL)
        {
            for (int privatized_bin = threadIdx.x; privatized_bin < num_privatized_bins[CHANNEL]; privatized_bin += BLOCK_THREADS)
            {
                privatized_histograms[CHANNEL][privatized_bin] = 0;
            }
        }

        // Barrier to make sure all threads are done updating counters
        __syncthreads();
    }


    // Initialize privatized bin counters.  Specialized for privatized shared-memory counters
    __device__ __forceinline__ void InitSmemBinCounters()
    {
        CounterT* privatized_histograms[NUM_ACTIVE_CHANNELS];

        for (int CHANNEL = 0; CHANNEL < NUM_ACTIVE_CHANNELS; ++CHANNEL)
            privatized_histograms[CHANNEL] = temp_storage.histograms[CHANNEL];

        InitBinCounters(privatized_histograms);
    }


    // Initialize privatized bin counters.  Specialized for privatized global-memory counters
    __device__ __forceinline__ void InitGmemBinCounters()
    {
        InitBinCounters(d_privatized_histograms);
    }


    //---------------------------------------------------------------------
    // Update final output histograms
    //---------------------------------------------------------------------

    // Update final output histograms from privatized histograms
    __device__ __forceinline__ void StoreOutput(CounterT* privatized_histograms[NUM_ACTIVE_CHANNELS])
    {
        // Barrier to make sure all threads are done updating counters
        __syncthreads();

        // Apply privatized bin counts to output bin counts
        #pragma unroll
        for (int CHANNEL = 0; CHANNEL < NUM_ACTIVE_CHANNELS; ++CHANNEL)
        {
            int channel_bins = num_privatized_bins[CHANNEL];
            for (int privatized_bin = threadIdx.x; 
                    privatized_bin < channel_bins;  
                    privatized_bin += BLOCK_THREADS)
            {
                int         output_bin;
                CounterT    count       = privatized_histograms[CHANNEL][privatized_bin];
                bool        is_valid    = count > 0;
                output_decode_op[CHANNEL].BinSelect<LOAD_MODIFIER>((SampleT) privatized_bin, output_bin, is_valid);

                if (output_bin >= 0)
                {
                    atomicAdd(&d_output_histograms[CHANNEL][output_bin], count);
                }

            }
        }
    }


    // Update final output histograms from privatized histograms.  Specialized for privatized shared-memory counters
    __device__ __forceinline__ void StoreSmemOutput()
    {
        CounterT* privatized_histograms[NUM_ACTIVE_CHANNELS];
        for (int CHANNEL = 0; CHANNEL < NUM_ACTIVE_CHANNELS; ++CHANNEL)
            privatized_histograms[CHANNEL] = temp_storage.histograms[CHANNEL];

        StoreOutput(privatized_histograms);
    }


    // Update final output histograms from privatized histograms.  Specialized for privatized global-memory counters
    __device__ __forceinline__ void StoreGmemOutput()
    {
        StoreOutput(d_privatized_histograms);
    }


    //---------------------------------------------------------------------
    // Accumulate privatized histograms
    //---------------------------------------------------------------------

    // Accumulate pixels.  Specialized for RLE compression.
    __device__ __forceinline__ void AccumulatePixels(
        SampleT             samples[PIXELS_PER_THREAD][NUM_CHANNELS],
        bool                is_valid[PIXELS_PER_THREAD],
        CounterT*           privatized_histograms[NUM_ACTIVE_CHANNELS],
        Int2Type<true>      is_rle_compress)
    {

        #pragma unroll
        for (int CHANNEL = 0; CHANNEL < NUM_ACTIVE_CHANNELS; ++CHANNEL)
        {
            // Bin pixels
            int bins[PIXELS_PER_THREAD];

            #pragma unroll
            for (int PIXEL = 0; PIXEL < PIXELS_PER_THREAD; ++PIXEL)
                privatized_decode_op[CHANNEL].BinSelect<LOAD_MODIFIER>(samples[PIXEL][CHANNEL], bins[PIXEL], is_valid[PIXEL]);
            
            CounterT accumulator = 1;

            #pragma unroll
            for (int PIXEL = 0; PIXEL < PIXELS_PER_THREAD - 1; ++PIXEL)
            {
                
                if (bins[PIXEL] < 0)
                {
                     accumulator = 1;
                } 
                else if (bins[PIXEL] == bins[PIXEL + 1])
                {   
                     accumulator++;
                } 
                else
                {
                     atomicAdd(privatized_histograms[CHANNEL] + bins[PIXEL], accumulator);
                     accumulator = 1;
                }
            }

            // Last pixel
            if (bins[PIXELS_PER_THREAD - 1] >= 0)
                atomicAdd(privatized_histograms[CHANNEL] + bins[PIXELS_PER_THREAD - 1], accumulator);

        }
    }


    // Accumulate pixels.  Specialized for individual accumulation of each pixel.
    __device__ __forceinline__ void AccumulatePixels(
        SampleT             samples[PIXELS_PER_THREAD][NUM_CHANNELS],
        bool                is_valid[PIXELS_PER_THREAD],
        CounterT*           privatized_histograms[NUM_ACTIVE_CHANNELS],
        Int2Type<false>     is_rle_compress)
    {
        #pragma unroll
        for (int PIXEL = 0; PIXEL < PIXELS_PER_THREAD; ++PIXEL)
        {
            #pragma unroll
            for (int CHANNEL = 0; CHANNEL < NUM_ACTIVE_CHANNELS; ++CHANNEL)
            {
                int bin;
                privatized_decode_op[CHANNEL].BinSelect<LOAD_MODIFIER>(samples[PIXEL][CHANNEL], bin, is_valid[PIXEL]);
                if (bin >= 0)
                    atomicAdd(privatized_histograms[CHANNEL] + bin, 1);
            }
        }
    }


    /**
     * Accumulate pixel, specialized for smem privatized histogram
     */
    __device__ __forceinline__ void AccumulateSmemPixels(
        SampleT             samples[PIXELS_PER_THREAD][NUM_CHANNELS],
        bool                is_valid[PIXELS_PER_THREAD])
    {
        CounterT* privatized_histograms[NUM_ACTIVE_CHANNELS];

        for (int CHANNEL = 0; CHANNEL < NUM_ACTIVE_CHANNELS; ++CHANNEL)
            privatized_histograms[CHANNEL] = temp_storage.histograms[CHANNEL];

        AccumulatePixels(samples, is_valid, privatized_histograms, Int2Type<RLE_COMPRESS>());
    }


    /**
     * Accumulate pixel, specialized for gmem privatized histogram
     */
    __device__ __forceinline__ void AccumulateGmemPixels(
        SampleT             samples[PIXELS_PER_THREAD][NUM_CHANNELS],
        bool                is_valid[PIXELS_PER_THREAD])
    {
        AccumulatePixels(samples, is_valid, d_privatized_histograms, Int2Type<RLE_COMPRESS>());
    }



    //---------------------------------------------------------------------
    // Tile processing
    //---------------------------------------------------------------------

    // Load full, aligned tile using pixel iterator
    __device__ __forceinline__ void LoadTile(
        OffsetT         block_offset,
        int             valid_samples,
        SampleT         (&samples)[PIXELS_PER_THREAD][NUM_CHANNELS],
        Int2Type<true>  is_full_tile,
        Int2Type<true>  is_aligned)
    {
        typedef PixelT AliasedPixels[PIXELS_PER_THREAD];

        WrappedPixelIteratorT d_wrapped_pixels((PixelT*) (d_native_samples + block_offset));

        // Load using a wrapped pixel iterator
        BlockLoadPixelT(temp_storage.pixel_load).Load(
            d_wrapped_pixels,
            reinterpret_cast<AliasedPixels&>(samples));
    }

    // Load full, mis-aligned tile using sample iterator
    __device__ __forceinline__ void LoadTile(
        OffsetT         block_offset,
        int             valid_samples,
        SampleT         (&samples)[PIXELS_PER_THREAD][NUM_CHANNELS],
        Int2Type<true>  is_full_tile,
        Int2Type<false> is_aligned)
    {
        typedef SampleT AliasedSamples[SAMPLES_PER_THREAD];

        // Load using sample iterator
        BlockLoadSampleT(temp_storage.sample_load).Load(
            d_wrapped_samples + block_offset,
            reinterpret_cast<AliasedSamples&>(samples));
    }

    // Load partially-full, aligned tile using pixel iterator
    __device__ __forceinline__ void LoadTile(
        OffsetT         block_offset,
        int             valid_samples,
        SampleT         (&samples)[PIXELS_PER_THREAD][NUM_CHANNELS],
        Int2Type<false> is_full_tile,
        Int2Type<true>  is_aligned)
    {
        typedef PixelT AliasedPixels[PIXELS_PER_THREAD];

        WrappedPixelIteratorT d_wrapped_pixels((PixelT*) (d_native_samples + block_offset));

        int valid_pixels = valid_samples / NUM_CHANNELS;

        // Load using a wrapped pixel iterator
        BlockLoadPixelT(temp_storage.pixel_load).Load(
            d_wrapped_pixels,
            reinterpret_cast<AliasedPixels&>(samples),
            valid_pixels);

    }

    // Load partially-full, mis-aligned tile using sample iterator
    __device__ __forceinline__ void LoadTile(
        OffsetT         block_offset,
        int             valid_samples,
        SampleT         (&samples)[PIXELS_PER_THREAD][NUM_CHANNELS],
        Int2Type<false> is_full_tile,
        Int2Type<false> is_aligned)
    {
        typedef SampleT AliasedSamples[SAMPLES_PER_THREAD];

        BlockLoadSampleT(temp_storage.sample_load).Load(
            d_wrapped_samples + block_offset,
            reinterpret_cast<AliasedSamples&>(samples),
            valid_samples);
    }

    // Consume a tile of data samples
    template <
        bool IS_ALIGNED,        // Whether the tile offset is aligned (quad-aligned for single-channel, pixel-aligned for multi-channel)
        bool IS_FULL_TILE>      // Whether the tile is full
    __device__ __forceinline__ void ConsumeTile(OffsetT block_offset, int valid_samples)
    {
        SampleT     samples[PIXELS_PER_THREAD][NUM_CHANNELS];
        bool        is_valid[PIXELS_PER_THREAD];

        // Load tile
        LoadTile(
            block_offset,
            valid_samples,
            samples,
            Int2Type<IS_FULL_TILE>(),
            Int2Type<IS_ALIGNED>());

        // Set valid flags
        #pragma unroll
        for (int PIXEL = 0; PIXEL < PIXELS_PER_THREAD; ++PIXEL)
            is_valid[PIXEL] = IS_FULL_TILE || (((threadIdx.x * PIXELS_PER_THREAD + PIXEL) * NUM_CHANNELS) < valid_samples);

        // Accumulate samples
        if (prefer_smem)
            AccumulateSmemPixels(samples, is_valid);
        else
            AccumulateGmemPixels(samples, is_valid);


    }


    // Consume row tiles.  Specialized for work-stealing from queue
    template <bool IS_ALIGNED>
    __device__ __forceinline__ void ConsumeTiles(
        OffsetT             row_offset,
        OffsetT             row_end,
        int                 tiles_per_row,
        GridQueue<int>      tile_queue,
        Int2Type<true>      is_work_stealing)
    {
        OffsetT tile_offset = blockIdx.x * TILE_SAMPLES;
        OffsetT num_remaining = row_end - tile_offset;
        OffsetT even_share_base = gridDim.x * TILE_SAMPLES;

        while (num_remaining >= TILE_SAMPLES)
        {
            // Consume full tile
            ConsumeTile<IS_ALIGNED, true>(tile_offset, TILE_SAMPLES);

            __syncthreads();

            // Get next tile
            if (threadIdx.x == 0)
                temp_storage.tile_offset = tile_queue.Drain(TILE_SAMPLES) + even_share_base;

            __syncthreads();

            tile_offset     = temp_storage.tile_offset;
            num_remaining   = row_end - tile_offset;

        }
        
        if (num_remaining > 0)
        {
            // Consume the last (and potentially partially-full) tile
            ConsumeTile<IS_ALIGNED, false>(tile_offset, num_remaining);
        }
    }


    // Consume row tiles.  Specialized for even-share (striped across thread blocks)
    template <bool IS_ALIGNED>
    __device__ __forceinline__ void ConsumeTiles(
        OffsetT             row_offset,
        OffsetT             row_end,
        int                 tiles_per_row,
        GridQueue<int>      tile_queue,
        Int2Type<false>     is_work_stealing)
    {
        OffsetT tile_offset = row_offset + (blockIdx.x * TILE_SAMPLES);
        while (tile_offset + TILE_SAMPLES <= row_end)
        {
            ConsumeTile<IS_ALIGNED, true>(tile_offset, TILE_SAMPLES);
            tile_offset += gridDim.x * TILE_SAMPLES;
        }

        if (tile_offset < row_end)
        {
            int valid_samples = row_end - tile_offset;
            ConsumeTile<IS_ALIGNED, false>(tile_offset, valid_samples);
        }
    }


    //---------------------------------------------------------------------
    // Parameter extraction
    //---------------------------------------------------------------------

    // Return a native pixel pointer (specialized for CacheModifiedInputIterator types)
    template <
        CacheLoadModifier   _MODIFIER,
        typename            _ValueT,
        typename            _OffsetT>
    __device__ __forceinline__ SampleT* NativePointer(CacheModifiedInputIterator<_MODIFIER, _ValueT, _OffsetT> itr)
    {
        return itr.ptr;
    }

    // Return a native pixel pointer (specialized for other types)
    template <typename IteratorT>
    __device__ __forceinline__ SampleT* NativePointer(IteratorT itr)
    {
        return NULL;
    }



    //---------------------------------------------------------------------
    // Interface
    //---------------------------------------------------------------------

    bool prefer_smem;

    /**
     * Constructor
     */
    __device__ __forceinline__ BlockSpmvSweep(
        TempStorage         &temp_storage,                                      ///< Reference to temp_storage
        SampleIteratorT     d_samples,                                          ///< Input data to reduce
        int                 (&num_output_bins)[NUM_ACTIVE_CHANNELS],            ///< The number bins per final output histogram
        int                 (&num_privatized_bins)[NUM_ACTIVE_CHANNELS],        ///< The number bins per privatized histogram
        CounterT*           (&d_output_histograms)[NUM_ACTIVE_CHANNELS],        ///< Reference to final output histograms
        CounterT*           (&d_privatized_histograms)[NUM_ACTIVE_CHANNELS],    ///< Reference to privatized histograms
        OutputDecodeOpT     (&output_decode_op)[NUM_ACTIVE_CHANNELS],           ///< The transform operator for determining output bin-ids from privatized counter indices, one for each channel
        PrivatizedDecodeOpT (&privatized_decode_op)[NUM_ACTIVE_CHANNELS])       ///< The transform operator for determining privatized counter indices from samples, one for each channel
    :
        temp_storage(temp_storage.Alias()),
        d_wrapped_samples(d_samples),
        num_output_bins(num_output_bins),
        num_privatized_bins(num_privatized_bins),
        d_output_histograms(d_output_histograms),
        privatized_decode_op(privatized_decode_op),
        output_decode_op(output_decode_op),
        d_native_samples(NativePointer(d_wrapped_samples)),
        prefer_smem((MEM_PREFERENCE == SMEM) ?
            true :                              // prefer smem privatized histograms
            (MEM_PREFERENCE == GMEM) ?
                false :                         // prefer gmem privatized histograms
                blockIdx.x & 1)                 // prefer blended privatized histograms
    {
        int blockId = (blockIdx.y * gridDim.x) + blockIdx.x;

        for (int CHANNEL = 0; CHANNEL < NUM_ACTIVE_CHANNELS; ++CHANNEL)
            this->d_privatized_histograms[CHANNEL] = d_privatized_histograms[CHANNEL] + (blockId * num_privatized_bins[CHANNEL]);
    }


    /**
     * Consume image
     */
    __device__ __forceinline__ void ConsumeTiles(
        OffsetT             num_row_pixels,             ///< The number of multi-channel pixels per row in the region of interest
        OffsetT             num_rows,                   ///< The number of rows in the region of interest
        OffsetT             row_stride_samples,         ///< The number of samples between starts of consecutive rows in the region of interest
        int                 tiles_per_row,              ///< Number of image tiles per row
        GridQueue<int>      tile_queue)                 ///< Queue descriptor for assigning tiles of work to thread blocks
    {
/*

        // Whether all row starting offsets are quad-aligned (in single-channel)
        // Whether all row starting offsets are pixel-aligned (in multi-channel)
        int     offsets             = int(d_native_samples) | (int(row_stride_samples) * int(sizeof(SampleT)));
        int     quad_mask           = sizeof(SampleT) * 4 - 1;
        int     pixel_mask          = AlignBytes<PixelT>::ALIGN_BYTES - 1;

        bool    quad_aligned_rows   = (NUM_CHANNELS == 1) && ((offsets & quad_mask) == 0);
        bool    pixel_aligned_rows  = (NUM_CHANNELS > 1) && ((offsets & pixel_mask) == 0);

        // Whether rows are aligned and can be vectorized
        if ((d_native_samples != NULL) && (quad_aligned_rows || pixel_aligned_rows))
            ConsumeRows<true>(num_row_pixels, num_rows, row_stride_samples, d_native_samples);
        else
            ConsumeRows<false>(num_row_pixels, num_rows, row_stride_samples, d_native_samples);
*/

//        ConsumeRows<true>(num_row_pixels, num_rows, row_stride_samples);

        ConsumeTiles<true>(
            0,
            num_row_pixels * NUM_CHANNELS,
            tiles_per_row,
            tile_queue,
            Int2Type<WORK_STEALING>());
    }


    /**
     * Initialize privatized bin counters.  Specialized for privatized shared-memory counters
     */
    __device__ __forceinline__ void InitBinCounters()
    {
        if (prefer_smem)
            InitSmemBinCounters();
        else
            InitGmemBinCounters();
    }


    /**
     * Store privatized histogram to global memory.  Specialized for privatized shared-memory counters
     */
    __device__ __forceinline__ void StoreOutput()
    {
        if (prefer_smem)
            StoreSmemOutput();
        else
            StoreGmemOutput();
    }


};




}               // CUB namespace
CUB_NS_POSTFIX  // Optional outer namespace(s)
