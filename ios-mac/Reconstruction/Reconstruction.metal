// Volumetric mesh reconstruction with spatial hashing, after Dong et al.,
// "An Efficient Volumetric Mesh Representation for Real-time Scene
// Reconstruction using Spatial Hashing" (ICRA 2018).
//
// Per frame, in order:
//   allocateBlocks     insert the blocks around every depth sample into the hash table
//   integrateDepth     fuse the depth (and color) into the TSDF of those blocks
//   collectMeshBlocks  those blocks plus their -x/-y/-z neighbours need remeshing
//   classifyCubes      cube type (+ Hamming refinement); claim vertex slots on owned edges
//   triangulateCubes   move vertices, rebuild triangles of cubes whose type changed
//   collectGarbage     recycle vertices no triangle references any more
//
// Every edge belongs to exactly one cube, so each vertex is stored once and found
// with one hash lookup. Claims and reads of a vertex happen in different
// dispatches, which is what lets us avoid the paper's per-vertex locks.

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "MetalCommon.h"
#include "MarchingCubesTables.h"

using namespace metal;

constant uint kEmptyKey = 0xFFFFFFFFu;
constant int kMaxProbes = 32;
constant int kBlockRange = 512;   // block coordinates must lie in [-512, 512)

// Corner k of a cube is the min corner of the cube at this offset.
constant int3 kCornerOffset[8] = {
    int3(0, 0, 0), int3(1, 0, 0), int3(1, 1, 0), int3(0, 1, 0),
    int3(0, 0, 1), int3(1, 0, 1), int3(1, 1, 1), int3(0, 1, 1),
};
// Edge e runs from corner kEdgeA[e] to kEdgeB[e] along axis kEdgeAxis[e].
// The cube whose min corner is kEdgeA[e] owns it.
constant uchar kEdgeA[12] = {0, 1, 3, 0, 4, 5, 7, 4, 0, 1, 2, 3};
constant uchar kEdgeB[12] = {1, 2, 2, 3, 5, 6, 6, 7, 4, 5, 6, 7};
constant uchar kEdgeAxis[12] = {0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2};
// Types where an axis-aligned plane cuts the cube in half. They are all at
// Hamming distance 4 or 8 from each other.
constant uchar kRegularTypes[6] = {0xCC, 0x33, 0x99, 0x66, 0xF0, 0x0F};

// MARK: - Helpers

inline bool blockInRange(int3 b) {
    return all(b >= -kBlockRange) && all(b < kBlockRange);
}

inline uint packBlockKey(int3 b) {
    uint3 u = uint3(b + kBlockRange);
    return u.x | (u.y << 10) | (u.z << 20);
}

inline uint hashKey(uint k) {
    k ^= k >> 16; k *= 0x7feb352du;
    k ^= k >> 15; k *= 0x846ca68bu;
    k ^= k >> 16;
    return k;
}

inline int3 localCoord(uint i) {
    return int3(i & 7, (i >> 3) & 7, i >> 6);
}

inline uint localIndex(int3 l) {
    return uint(l.x + RT_BLOCK_SIDE * l.y + RT_BLOCK_SIDE * RT_BLOCK_SIDE * l.z);
}

inline uint listCount(device atomic_int* counters, int index, uint capacity) {
    return min(uint(atomic_load_explicit(&counters[index], memory_order_relaxed)), capacity);
}

inline void flagOverflow(device atomic_int* counters, int bit) {
    atomic_fetch_or_explicit(&counters[RT_COUNTER_OVERFLOW], bit, memory_order_relaxed);
}

inline void appendToList(device atomic_int* counters, int counterIndex,
                         device int* list, uint capacity, int value) {
    int i = atomic_fetch_add_explicit(&counters[counterIndex], 1, memory_order_relaxed);
    if (uint(i) < capacity) {
        list[i] = value;
    } else {
        flagOverflow(counters, RT_OVERFLOW_LIST);
    }
}

// Strong compare-and-swap built from the weak one Metal provides.
inline bool compareExchange(device atomic_int* p, thread int& expected, int desired) {
    int wanted = expected;
    while (!atomic_compare_exchange_weak_explicit(p, &expected, desired,
                                                  memory_order_relaxed, memory_order_relaxed)) {
        if (expected != wanted) return false;
    }
    return true;
}

inline bool compareExchange(device atomic_uint* p, thread uint& expected, uint desired) {
    uint wanted = expected;
    while (!atomic_compare_exchange_weak_explicit(p, &expected, desired,
                                                  memory_order_relaxed, memory_order_relaxed)) {
        if (expected != wanted) return false;
    }
    return true;
}

// Free lists are stacks. Pops and pushes on the same list never share a
// dispatch, so a plain atomic top is enough.
inline int popFree(device atomic_int* top, device const int* list) {
    int i = atomic_fetch_sub_explicit(top, 1, memory_order_relaxed) - 1;
    if (i < 0) {
        atomic_fetch_add_explicit(top, 1, memory_order_relaxed);
        return RT_EMPTY;
    }
    return list[i];
}

inline void pushFree(device atomic_int* top, device int* list, int value) {
    int i = atomic_fetch_add_explicit(top, 1, memory_order_relaxed);
    list[i] = value;
}

inline int lookupBlock(int3 b, device const uint* keys, device const int* values, uint mask) {
    if (!blockInRange(b)) return RT_EMPTY;
    uint key = packBlockKey(b);
    uint slot = hashKey(key) & mask;
    for (int i = 0; i < kMaxProbes; ++i) {
        uint k = keys[slot];
        if (k == key) return values[slot];
        if (k == kEmptyKey) return RT_EMPTY;
        slot = (slot + 1) & mask;
    }
    return RT_EMPTY;
}

// Returns the hash slot of block b, inserting it if needed. The thread that
// inserts the key also assigns the block, so other threads may see the slot's
// value as empty until the next dispatch.
inline int insertBlock(int3 b, constant FrameUniforms& u, device atomic_uint* keys,
                       device int* values, device int4* blockCoords, device atomic_int* counters) {
    if (!blockInRange(b)) return RT_EMPTY;
    uint key = packBlockKey(b);
    uint slot = hashKey(key) & u.hashMask;
    for (int i = 0; i < kMaxProbes; ++i) {
        uint current = atomic_load_explicit(&keys[slot], memory_order_relaxed);
        if (current == kEmptyKey) {
            uint expected = kEmptyKey;
            if (compareExchange(&keys[slot], expected, key)) {
                int blockIndex = atomic_fetch_add_explicit(&counters[RT_COUNTER_BLOCKS], 1, memory_order_relaxed);
                if (uint(blockIndex) < u.maxBlocks) {
                    values[slot] = blockIndex;
                    blockCoords[blockIndex] = int4(b, 0);
                } else {
                    flagOverflow(counters, RT_OVERFLOW_BLOCKS);
                }
                return int(slot);
            }
            current = expected;
        }
        if (current == key) return int(slot);
        slot = (slot + 1) & u.hashMask;
    }
    flagOverflow(counters, RT_OVERFLOW_HASH);
    return RT_EMPTY;
}

// Fills cubeOf[k] with the global index of the cube whose min corner is corner
// k of this cube. Fails if a neighbouring block does not exist.
inline bool resolveCorners(int blockIndex, int3 blockCoord, int3 local,
                           device const uint* keys, device const int* values, uint mask,
                           thread int* cubeOf) {
    int neighbor[8] = {blockIndex, -2, -2, -2, -2, -2, -2, -2};
    for (int k = 0; k < 8; ++k) {
        int3 l = local + kCornerOffset[k];
        int3 spill = int3(l >= RT_BLOCK_SIDE);
        int n = spill.x | (spill.y << 1) | (spill.z << 2);
        if (neighbor[n] == -2) {
            neighbor[n] = lookupBlock(blockCoord + spill, keys, values, mask);
        }
        if (neighbor[n] < 0) return false;
        cubeOf[k] = neighbor[n] * RT_CUBES_PER_BLOCK + int(localIndex(l - spill * RT_BLOCK_SIDE));
    }
    return true;
}

inline uint edgeSlot(thread const int* cubeOf, int e) {
    return uint(cubeOf[kEdgeA[e]]) * 3 + kEdgeAxis[e];
}

// Hamming-distance refinement (paper eq. 3-5): a cube whose type is close to
// both its previous type and a regular type, where every differing corner is
// near the surface, is snapped to the regular type. This removes the slivers
// and cracks that appear when the surface passes close to cube corners.
inline uchar refineType(uchar type, uchar previous, thread const float* d, float threshold) {
    if (popcount(uint(type ^ previous)) > 3) return type;
    for (int r = 0; r < 6; ++r) {
        uint diff = uint(type ^ kRegularTypes[r]);
        if (popcount(diff) > 3) continue;
        for (int k = 0; k < 8; ++k) {
            if (((diff >> k) & 1) && fabs(d[k]) >= threshold) return type;
        }
        return kRegularTypes[r];
    }
    return type;
}

// MARK: - Kernels

kernel void initializeState(device int* vertexFreeList [[buffer(0)]],
                            device int* triangleFreeList [[buffer(1)]],
                            device int* counters [[buffer(2)]],
                            constant uint2& sizes [[buffer(3)]],
                            uint tid [[thread_position_in_grid]]) {
    // Low indices are popped first, which keeps the triangle high-water mark tight.
    if (tid < sizes.x) vertexFreeList[tid] = int(sizes.x - 1 - tid);
    if (tid < sizes.y) triangleFreeList[tid] = int(sizes.y - 1 - tid);
    if (tid < RT_COUNTER_COUNT) {
        counters[tid] = tid == RT_COUNTER_VERTEX_FREE_TOP ? int(sizes.x)
                      : tid == RT_COUNTER_TRIANGLE_FREE_TOP ? int(sizes.y) : 0;
    }
}

// params: x = counter, y = threads per list item, z = argument offset, w = list capacity
kernel void prepareIndirect(device atomic_int* counters [[buffer(0)]],
                            device uint* args [[buffer(1)]],
                            constant uint4& params [[buffer(2)]]) {
    uint threads = listCount(counters, params.x, params.w) * params.y;
    args[params.z + 0] = (threads + RT_THREADGROUP_SIZE - 1) / RT_THREADGROUP_SIZE;
    args[params.z + 1] = 1;
    args[params.z + 2] = 1;
}

kernel void prepareDraw(device atomic_int* counters [[buffer(0)]],
                        device uint* args [[buffer(1)]]) {
    uint cubes = uint(atomic_load_explicit(&counters[RT_COUNTER_TRIANGLE_HIGH_WATER], memory_order_relaxed));
    args[RT_ARGS_DRAW + 0] = cubes * RT_MAX_TRIANGLES_PER_CUBE * 3;  // index count
    args[RT_ARGS_DRAW + 1] = 1;                                     // instance count
    args[RT_ARGS_DRAW + 2] = 0;                                     // index start
    args[RT_ARGS_DRAW + 3] = 0;                                     // base vertex
    args[RT_ARGS_DRAW + 4] = 0;                                     // base instance
}

kernel void allocateBlocks(texture2d<float, access::read> depthMap [[texture(0)]],
                           texture2d<uint, access::read> confidenceMap [[texture(1)]],
                           constant FrameUniforms& u [[buffer(0)]],
                           device atomic_uint* hashKeys [[buffer(1)]],
                           device int* hashValues [[buffer(2)]],
                           device int4* blockCoords [[buffer(3)]],
                           device atomic_uint* activeStamp [[buffer(4)]],
                           device int* activeList [[buffer(5)]],
                           device atomic_int* counters [[buffer(6)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.depthSize.x || gid.y >= u.depthSize.y) return;
    float depth = depthMap.read(gid).r;
    if (!(depth >= u.minDepth && depth <= u.maxDepth)) return;   // also rejects NaN
    if (confidenceMap.read(gid).r < u.minConfidence) return;

    float2 ray = (float2(gid) - u.depthIntrinsics.zw) / u.depthIntrinsics.xy;
    float blockSize = u.voxelSize * RT_BLOCK_SIDE;
    int steps = max(1, int(ceil(2.0 * u.truncation / u.voxelSize)));
    int3 lastBlock = int3(0x7fffffff);
    for (int s = 0; s <= steps; ++s) {
        float z = depth - u.truncation + 2.0 * u.truncation * float(s) / float(steps);
        if (z <= 0.0) continue;
        float3 pCamera = float3(ray.x * z, -ray.y * z, -z);
        float3 pWorld = (u.cameraToWorld * float4(pCamera, 1.0)).xyz;
        int3 b = int3(floor(pWorld / blockSize));
        if (all(b == lastBlock)) continue;
        lastBlock = b;
        int slot = insertBlock(b, u, hashKeys, hashValues, blockCoords, counters);
        if (slot < 0) continue;
        if (atomic_exchange_explicit(&activeStamp[slot], u.frameIndex, memory_order_relaxed) != u.frameIndex) {
            appendToList(counters, RT_COUNTER_ACTIVE, activeList, u.listCapacity, slot);
        }
    }
}

kernel void integrateDepth(texture2d<float, access::read> depthMap [[texture(0)]],
                           texture2d<uint, access::read> confidenceMap [[texture(1)]],
                           texture2d<float, access::sample> colorY [[texture(2)]],
                           texture2d<float, access::sample> colorCbCr [[texture(3)]],
                           constant FrameUniforms& u [[buffer(0)]],
                           device const int* hashValues [[buffer(1)]],
                           device const int4* blockCoords [[buffer(2)]],
                           device const int* activeList [[buffer(3)]],
                           device atomic_int* counters [[buffer(4)]],
                           device half2* voxels [[buffer(5)]],
                           device uchar4* colors [[buffer(6)]],
                           uint tid [[thread_position_in_grid]]) {
    uint item = tid / RT_CUBES_PER_BLOCK;
    if (item >= listCount(counters, RT_COUNTER_ACTIVE, u.listCapacity)) return;
    int blockIndex = hashValues[activeList[item]];
    if (blockIndex < 0) return;
    uint local = tid % RT_CUBES_PER_BLOCK;

    int3 voxel = blockCoords[blockIndex].xyz * RT_BLOCK_SIDE + localCoord(local);
    float3 pCamera = (u.worldToCamera * float4(float3(voxel) * u.voxelSize, 1.0)).xyz;
    float z = -pCamera.z;
    if (z <= 0.0) return;
    float2 ray = float2(pCamera.x, -pCamera.y) / z;
    int2 pixel = int2(round(ray * u.depthIntrinsics.xy + u.depthIntrinsics.zw));
    if (any(pixel < 0) || pixel.x >= int(u.depthSize.x) || pixel.y >= int(u.depthSize.y)) return;
    float depth = depthMap.read(uint2(pixel)).r;
    if (!(depth >= u.minDepth && depth <= u.maxDepth)) return;
    if (confidenceMap.read(uint2(pixel)).r < u.minConfidence) return;

    float sdf = depth - z;
    if (sdf < -u.truncation) return;   // hidden behind the observed surface

    uint cube = uint(blockIndex) * RT_CUBES_PER_BLOCK + local;
    float2 v = float2(voxels[cube]);
    v.x = (v.x * v.y + min(sdf, u.truncation)) / (v.y + 1.0);
    v.y = min(v.y + 1.0, u.maxWeight);
    voxels[cube] = half2(v);

    // Colour comes only from voxels near the surface: one further out, seen
    // at an angle, would sample a neighbouring spot. A frame counts for more
    // the nearer the voxel is to the surface, the closer the camera, and the
    // sharper the picture (u.colorWeight), and the average is capped low so
    // later, better views can still take over. The weight is kept in
    // sixteenths in the alpha byte; any weight at all marks a coloured voxel.
    float w = u.colorWeight * (1.0 - fabs(sdf) / u.colorBand) * clamp(1.2 / z, 0.25, 1.0);
    if (w > 0.01) {
        float2 colorPixel = ray * u.colorIntrinsics.xy + u.colorIntrinsics.zw;
        float2 uv = (colorPixel + 0.5) / float2(u.colorSize);
        if (all(uv >= 0.0) && all(uv <= 1.0)) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float3 rgb = ycbcrToRGB(colorY.sample(s, uv).r, colorCbCr.sample(s, uv).rg) * 255.0;
            float4 c = float4(colors[cube]);
            float stored = c.a / 16.0;
            float3 blended = (c.rgb * stored + rgb * w) / (stored + w);
            float weight = clamp(round(min(stored + w, u.maxColorWeight) * 16.0), 1.0, 255.0);
            colors[cube] = uchar4(uchar3(clamp(blended + 0.5, 0.0, 255.0)), uchar(weight));
        }
    }
}

kernel void collectMeshBlocks(constant FrameUniforms& u [[buffer(0)]],
                              device const uint* hashKeys [[buffer(1)]],
                              device const int* hashValues [[buffer(2)]],
                              device const int4* blockCoords [[buffer(3)]],
                              device const int* activeList [[buffer(4)]],
                              device atomic_int* counters [[buffer(5)]],
                              device atomic_uint* meshStamp [[buffer(6)]],
                              device int* meshList [[buffer(7)]],
                              uint tid [[thread_position_in_grid]]) {
    // A cube reads corners from its +x/+y/+z neighbours, so a TSDF change in a
    // block also affects the 7 blocks at negative offsets from it.
    uint item = tid / 8;
    if (item >= listCount(counters, RT_COUNTER_ACTIVE, u.listCapacity)) return;
    int blockIndex = hashValues[activeList[item]];
    if (blockIndex < 0) return;
    uint n = tid % 8;
    int target = n == 0 ? blockIndex
                        : lookupBlock(blockCoords[blockIndex].xyz - kCornerOffset[n], hashKeys, hashValues, u.hashMask);
    if (target < 0) return;
    if (atomic_exchange_explicit(&meshStamp[target], u.frameIndex, memory_order_relaxed) != u.frameIndex) {
        appendToList(counters, RT_COUNTER_MESH, meshList, u.listCapacity, target);
    }
}

kernel void classifyCubes(constant FrameUniforms& u [[buffer(0)]],
                          device const uint* hashKeys [[buffer(1)]],
                          device const int* hashValues [[buffer(2)]],
                          device const int4* blockCoords [[buffer(3)]],
                          device const int* meshList [[buffer(4)]],
                          device atomic_int* counters [[buffer(5)]],
                          device const half2* voxels [[buffer(6)]],
                          device uchar2* cubeState [[buffer(7)]],   // x: committed type, y: new type
                          device atomic_int* edgeVertex [[buffer(8)]],
                          device int* triangleBlock [[buffer(9)]],
                          device const int* vertexFreeList [[buffer(10)]],
                          device const int* triangleFreeList [[buffer(11)]],
                          device int* vertexOwner [[buffer(12)]],
                          device atomic_int* vertexRef [[buffer(13)]],
                          device int* garbageList [[buffer(14)]],
                          uint tid [[thread_position_in_grid]]) {
    uint item = tid / RT_CUBES_PER_BLOCK;
    if (item >= listCount(counters, RT_COUNTER_MESH, u.listCapacity)) return;
    int blockIndex = meshList[item];
    uint local = tid % RT_CUBES_PER_BLOCK;
    uint cube = uint(blockIndex) * RT_CUBES_PER_BLOCK + local;
    uchar committed = cubeState[cube].x;

    int cubeOf[8];
    uchar type = 0;
    if (resolveCorners(blockIndex, blockCoords[blockIndex].xyz, localCoord(local),
                       hashKeys, hashValues, u.hashMask, cubeOf)) {
        float d[8];
        bool observed = true;
        for (int k = 0; k < 8; ++k) {
            float2 v = float2(voxels[cubeOf[k]]);
            d[k] = v.x;
            observed = observed && v.y > 0.0;
            if (v.x < 0.0) type |= uchar(1 << k);
        }
        type = observed ? refineType(type, committed, d, u.refineThreshold) : 0;
    }
    cubeState[cube] = uchar2(committed, type);
    if (type == committed) return;
    atomic_fetch_add_explicit(&counters[RT_COUNTER_RETRIANGULATED], 1, memory_order_relaxed);
    if (kTriangleCount[type] == 0) return;

    // Make sure every edge the new triangles use has a vertex. The first cube
    // to claim an edge allocates its vertex; the others see it next dispatch.
    uint mask = kEdgeMask[type];
    for (int e = 0; e < 12; ++e) {
        if (!(mask & (1u << e))) continue;
        uint slot = edgeSlot(cubeOf, e);
        if (atomic_load_explicit(&edgeVertex[slot], memory_order_relaxed) != RT_EMPTY) continue;
        int expected = RT_EMPTY;
        if (!compareExchange(&edgeVertex[slot], expected, RT_CLAIMED)) continue;
        int v = popFree(&counters[RT_COUNTER_VERTEX_FREE_TOP], vertexFreeList);
        if (v < 0) {
            atomic_store_explicit(&edgeVertex[slot], RT_EMPTY, memory_order_relaxed);
            flagOverflow(counters, RT_OVERFLOW_VERTICES);
            continue;
        }
        vertexOwner[v] = int(slot);
        atomic_store_explicit(&vertexRef[v], 0, memory_order_relaxed);
        // If no triangle ends up using it, the garbage pass frees it again.
        appendToList(counters, RT_COUNTER_GARBAGE, garbageList, u.garbageCapacity, v);
        atomic_store_explicit(&edgeVertex[slot], v, memory_order_relaxed);
    }

    if (triangleBlock[cube] == RT_EMPTY) {
        int t = popFree(&counters[RT_COUNTER_TRIANGLE_FREE_TOP], triangleFreeList);
        if (t < 0) {
            flagOverflow(counters, RT_OVERFLOW_TRIANGLES);
        } else {
            triangleBlock[cube] = t;
            atomic_fetch_max_explicit(&counters[RT_COUNTER_TRIANGLE_HIGH_WATER], t + 1, memory_order_relaxed);
        }
    }
}

inline void releaseVertex(uint v, constant FrameUniforms& u, device atomic_int* vertexRef,
                          device atomic_int* counters, device int* garbageList) {
    if (atomic_fetch_sub_explicit(&vertexRef[v], 1, memory_order_relaxed) == 1) {
        appendToList(counters, RT_COUNTER_GARBAGE, garbageList, u.garbageCapacity, int(v));
    }
}

kernel void triangulateCubes(constant FrameUniforms& u [[buffer(0)]],
                             device const uint* hashKeys [[buffer(1)]],
                             device const int* hashValues [[buffer(2)]],
                             device const int4* blockCoords [[buffer(3)]],
                             device const int* meshList [[buffer(4)]],
                             device atomic_int* counters [[buffer(5)]],
                             device const half2* voxels [[buffer(6)]],
                             device uchar2* cubeState [[buffer(7)]],
                             device atomic_int* edgeVertex [[buffer(8)]],
                             device int* triangleBlock [[buffer(9)]],
                             device const uchar4* colors [[buffer(10)]],
                             device int* triangleFreeList [[buffer(11)]],
                             device MeshVertex* vertices [[buffer(12)]],
                             device atomic_int* vertexRef [[buffer(13)]],
                             device int* garbageList [[buffer(14)]],
                             device uint* triangles [[buffer(15)]],
                             uint tid [[thread_position_in_grid]]) {
    uint item = tid / RT_CUBES_PER_BLOCK;
    if (item >= listCount(counters, RT_COUNTER_MESH, u.listCapacity)) return;
    int blockIndex = meshList[item];
    uint local = tid % RT_CUBES_PER_BLOCK;
    uint cube = uint(blockIndex) * RT_CUBES_PER_BLOCK + local;
    uchar committed = cubeState[cube].x;
    uchar type = cubeState[cube].y;
    uint mask = kEdgeMask[type];
    if (mask == 0 && type == committed) return;

    int cubeOf[8];
    if (mask != 0) {
        // classifyCubes only produces a surface type when all corners resolve.
        int3 blockCoord = blockCoords[blockIndex].xyz;
        int3 local3 = localCoord(local);
        resolveCorners(blockIndex, blockCoord, local3, hashKeys, hashValues, u.hashMask, cubeOf);

        // Move this cube's surface vertices to the latest zero crossing. Up to
        // four cubes share an edge; they all compute bit-identical values.
        int3 baseVoxel = blockCoord * RT_BLOCK_SIDE + local3;
        for (int e = 0; e < 12; ++e) {
            if (!(mask & (1u << e))) continue;
            int v = atomic_load_explicit(&edgeVertex[edgeSlot(cubeOf, e)], memory_order_relaxed);
            if (v < 0) continue;
            int a = cubeOf[kEdgeA[e]];
            int b = cubeOf[kEdgeB[e]];
            float da = float(voxels[a].x);
            float db = float(voxels[b].x);
            float denom = da - db;
            float t = fabs(denom) > 1e-6 ? clamp(da / denom, 0.0, 1.0) : 0.5;
            float3 position = float3(baseVoxel + kCornerOffset[kEdgeA[e]]) * u.voxelSize;
            position[kEdgeAxis[e]] += t * u.voxelSize;
            float4 ca = float4(colors[a]);
            float4 cb = float4(colors[b]);
            float3 rgb = ca.a > 0.0 && cb.a > 0.0 ? mix(ca.rgb, cb.rgb, t) : (ca.a > 0.0 ? ca.rgb : cb.rgb);
            MeshVertex out;
            out.position[0] = position.x;
            out.position[1] = position.y;
            out.position[2] = position.z;
            out.color = pack_float_to_unorm4x8(float4(rgb / 255.0, 1.0));
            vertices[v] = out;
        }
    }
    if (type == committed) return;

    // Topology changed: drop the old triangles...
    int block = triangleBlock[cube];
    device uint* tri = triangles + max(block, 0) * RT_MAX_TRIANGLES_PER_CUBE * 3;
    int triangleDelta = 0;
    if (block >= 0) {
        for (int k = 0; k < RT_MAX_TRIANGLES_PER_CUBE; ++k) {
            uint a = tri[3 * k], b = tri[3 * k + 1], c = tri[3 * k + 2];
            if (a == b && b == c) continue;   // empty slot
            releaseVertex(a, u, vertexRef, counters, garbageList);
            releaseVertex(b, u, vertexRef, counters, garbageList);
            releaseVertex(c, u, vertexRef, counters, garbageList);
            triangleDelta -= 1;
        }
    }

    // ...and build the new ones from the marching cubes table.
    uint count = kTriangleCount[type];
    bool complete = true;
    if (count == 0) {
        if (block >= 0) {
            for (int i = 0; i < RT_MAX_TRIANGLES_PER_CUBE * 3; ++i) tri[i] = 0;
            pushFree(&counters[RT_COUNTER_TRIANGLE_FREE_TOP], triangleFreeList, block);
            triangleBlock[cube] = RT_EMPTY;
        }
    } else if (block < 0) {
        complete = false;   // triangle pool was exhausted in classifyCubes
    } else {
        for (uint k = 0; k < RT_MAX_TRIANGLES_PER_CUBE; ++k) {
            uint index[3] = {0, 0, 0};
            bool valid = k < count;
            for (int j = 0; j < 3 && valid; ++j) {
                int v = atomic_load_explicit(&edgeVertex[edgeSlot(cubeOf, kTriangleEdges[type][3 * k + j])],
                                             memory_order_relaxed);
                valid = v >= 0;
                index[j] = uint(max(v, 0));
            }
            if (valid) {
                for (int j = 0; j < 3; ++j) {
                    atomic_fetch_add_explicit(&vertexRef[index[j]], 1, memory_order_relaxed);
                }
                triangleDelta += 1;
            } else {
                if (k < count) complete = false;   // a vertex is missing (vertex pool full)
                index[0] = index[1] = index[2] = 0;
            }
            tri[3 * k] = index[0];
            tri[3 * k + 1] = index[1];
            tri[3 * k + 2] = index[2];
        }
    }
    atomic_fetch_add_explicit(&counters[RT_COUNTER_TRIANGLES], triangleDelta, memory_order_relaxed);
    // An incomplete cube is committed as empty so it is rebuilt next frame.
    cubeState[cube] = uchar2(complete ? type : 0, type);
}

kernel void collectGarbage(constant FrameUniforms& u [[buffer(0)]],
                           device atomic_int* counters [[buffer(1)]],
                           device const int* garbageList [[buffer(2)]],
                           device atomic_int* vertexRef [[buffer(3)]],
                           device const int* vertexOwner [[buffer(4)]],
                           device atomic_int* edgeVertex [[buffer(5)]],
                           device int* vertexFreeList [[buffer(6)]],
                           uint tid [[thread_position_in_grid]]) {
    if (tid >= listCount(counters, RT_COUNTER_GARBAGE, u.garbageCapacity)) return;
    int v = garbageList[tid];
    // A vertex can be listed twice in one frame; only one thread may free it.
    int expected = 0;
    if (!compareExchange(&vertexRef[v], expected, -1)) return;
    atomic_store_explicit(&edgeVertex[vertexOwner[v]], RT_EMPTY, memory_order_relaxed);
    pushFree(&counters[RT_COUNTER_VERTEX_FREE_TOP], vertexFreeList, v);
}
