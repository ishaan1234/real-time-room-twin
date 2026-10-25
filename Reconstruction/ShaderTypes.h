// Types and constants shared by the Metal kernels and the Swift host code.
// This file is also the Swift bridging header, so keep it plain C.

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Space is split into blocks of 8x8x8 cubes. A cube stores the TSDF at its
// min corner and owns the three edges leaving that corner along +x, +y, +z.
#define RT_BLOCK_SIDE 8
#define RT_CUBES_PER_BLOCK 512
#define RT_MAX_TRIANGLES_PER_CUBE 5
#define RT_THREADGROUP_SIZE 64

#define RT_EMPTY (-1)
#define RT_CLAIMED (-2)

// Slots in the counters buffer. Everything from RT_FIRST_FRAME_COUNTER on is
// cleared at the start of each frame; the rest persists.
#define RT_COUNTER_BLOCKS 0
#define RT_COUNTER_VERTEX_FREE_TOP 1
#define RT_COUNTER_TRIANGLE_FREE_TOP 2
#define RT_COUNTER_TRIANGLE_HIGH_WATER 3
#define RT_COUNTER_OVERFLOW 4
#define RT_COUNTER_TRIANGLES 5
#define RT_FIRST_FRAME_COUNTER 8
#define RT_COUNTER_ACTIVE 8
#define RT_COUNTER_MESH 9
#define RT_COUNTER_GARBAGE 10
#define RT_COUNTER_RETRIANGULATED 11
#define RT_COUNTER_COUNT 16

// Bits in RT_COUNTER_OVERFLOW.
#define RT_OVERFLOW_BLOCKS 1
#define RT_OVERFLOW_HASH 2
#define RT_OVERFLOW_VERTICES 4
#define RT_OVERFLOW_TRIANGLES 8
#define RT_OVERFLOW_LIST 16

// Offsets (in uint32s) into the indirect-arguments buffer.
#define RT_ARGS_ACTIVE_CUBES 0
#define RT_ARGS_ACTIVE_NEIGHBORS 4
#define RT_ARGS_MESH_CUBES 8
#define RT_ARGS_GARBAGE 12
#define RT_ARGS_DRAW 16
#define RT_ARGS_COUNT 24

#define RT_MESH_MODE_COLOR 0
#define RT_MESH_MODE_SHADED 1

typedef struct {
    simd_float4x4 cameraToWorld;   // ARKit camera: +x right, +y up, looks down -z
    simd_float4x4 worldToCamera;
    simd_float4 depthIntrinsics;   // fx, fy, cx, cy in depth-map pixels
    simd_float4 colorIntrinsics;   // fx, fy, cx, cy in color-image pixels
    simd_uint2 depthSize;
    simd_uint2 colorSize;
    float voxelSize;
    float truncation;
    float minDepth;
    float maxDepth;
    float maxWeight;
    float refineThreshold;
    uint32_t minConfidence;
    uint32_t frameIndex;
    uint32_t hashMask;
    uint32_t maxBlocks;
    uint32_t listCapacity;
    uint32_t garbageCapacity;
} FrameUniforms;

typedef struct {
    float position[3];
    uint32_t color;                // RGBA8, as packed by pack_float_to_unorm4x8
} MeshVertex;

typedef struct {
    simd_float4x4 viewProjection;
    simd_float4 cameraPosition;
    float clipHeight;              // fragments above this world height are discarded
    uint32_t mode;
    float padding[2];
} MeshUniforms;

#endif
