import Metal
import simd

struct ReconstructionSettings {
    var voxelSize: Float = 0.02
    var truncationInVoxels: Float = 4
    var minDepth: Float = 0.15
    var maxDepth: Float = 3.5
    /// ARConfidenceLevel raw value: 0 low, 1 medium, 2 high.
    var minConfidence: UInt32 = 2
    var maxWeight: Float = 64
    /// Corners closer than this to the surface may be flipped by the paper's
    /// Hamming refinement (try 0.3). Off by default: neighbouring cubes snap
    /// independently, and on surfaces near a voxel plane both sides snap,
    /// leaving overlapping sheets and cracks. ReconCheck measures this.
    var refineThresholdInVoxels: Float = 0
    var maxBlocks = 24_576
    var hashSlots = 1 << 17
    var maxVertices = 2_000_000
    var maxSurfaceCubes = 1_200_000
    var garbageCapacity = 1 << 20

    var cubeCount: Int { maxBlocks * Int(RT_CUBES_PER_BLOCK) }
}

/// One RGB-D frame in ARKit conventions.
struct FrameInput {
    var depth: MTLTexture          // r32Float, metres along the view axis
    var confidence: MTLTexture     // r8Uint
    var colorY: MTLTexture         // r8Unorm
    var colorCbCr: MTLTexture      // rg8Unorm, half resolution
    /// ARCamera.intrinsics, in color-image pixels.
    var colorIntrinsics: simd_float3x3
    /// ARCamera.transform: camera to world, camera looks down -z with +y up.
    var cameraToWorld: simd_float4x4
}

struct ReconstructionStats {
    var blocks = 0
    var vertices = 0
    var triangles = 0
    var activeBlocks = 0
    var retriangulatedCubes = 0
    var overflow: Int32 = 0
    var gpuMilliseconds = 0.0
}

enum ReconstructionError: Error {
    case missingFunction(String)
    case allocationFailed(String, Int)
}

/// GPU state and passes for the hashed TSDF and its incrementally updated mesh.
final class Reconstructor {
    let device: MTLDevice
    let settings: ReconstructionSettings

    // Hash table: block coordinate -> block index.
    let hashKeys: MTLBuffer
    let hashValues: MTLBuffer
    let activeStamp: MTLBuffer
    // Per block.
    let blockCoords: MTLBuffer
    let meshStamp: MTLBuffer
    // Per cube.
    let voxels: MTLBuffer          // half2 (tsdf, weight)
    let colors: MTLBuffer          // uchar4 (rgb, weight)
    let cubeState: MTLBuffer       // uchar2 (committed type, new type)
    let edgeVertex: MTLBuffer      // int32 x3: vertices on the owned +x, +y, +z edges
    let triangleBlock: MTLBuffer   // int32: slot of this cube's 5 triangles
    // Vertex and triangle pools. These are drawn directly as the mesh.
    let vertices: MTLBuffer
    let vertexOwner: MTLBuffer
    let vertexRef: MTLBuffer
    let vertexFreeList: MTLBuffer
    let triangles: MTLBuffer
    let triangleFreeList: MTLBuffer
    // Work lists and bookkeeping.
    let activeList: MTLBuffer
    let meshList: MTLBuffer
    let garbageList: MTLBuffer
    let counters: MTLBuffer
    let indirectArgs: MTLBuffer

    private let initializePipeline: MTLComputePipelineState
    private let prepareIndirectPipeline: MTLComputePipelineState
    private let prepareDrawPipeline: MTLComputePipelineState
    private let allocatePipeline: MTLComputePipelineState
    private let integratePipeline: MTLComputePipelineState
    private let collectMeshPipeline: MTLComputePipelineState
    private let classifyPipeline: MTLComputePipelineState
    private let triangulatePipeline: MTLComputePipelineState
    private let garbagePipeline: MTLComputePipelineState

    private(set) var frameIndex: UInt32 = 0

    /// Byte offset of the MTLDrawIndexedPrimitivesIndirectArguments in `indirectArgs`.
    let drawArgumentsOffset = Int(RT_ARGS_DRAW) * 4

    init(device: MTLDevice, library: MTLLibrary, settings: ReconstructionSettings = .init()) throws {
        precondition(settings.hashSlots & (settings.hashSlots - 1) == 0, "hashSlots must be a power of two")
        self.device = device
        self.settings = settings

        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw ReconstructionError.missingFunction(name) }
            return try device.makeComputePipelineState(function: function)
        }
        initializePipeline = try pipeline("initializeState")
        prepareIndirectPipeline = try pipeline("prepareIndirect")
        prepareDrawPipeline = try pipeline("prepareDraw")
        allocatePipeline = try pipeline("allocateBlocks")
        integratePipeline = try pipeline("integrateDepth")
        collectMeshPipeline = try pipeline("collectMeshBlocks")
        classifyPipeline = try pipeline("classifyCubes")
        triangulatePipeline = try pipeline("triangulateCubes")
        garbagePipeline = try pipeline("collectGarbage")

        func buffer(_ name: String, _ length: Int) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw ReconstructionError.allocationFailed(name, length)
            }
            buffer.label = name
            return buffer
        }
        let cubes = settings.cubeCount
        hashKeys = try buffer("hashKeys", settings.hashSlots * 4)
        hashValues = try buffer("hashValues", settings.hashSlots * 4)
        activeStamp = try buffer("activeStamp", settings.hashSlots * 4)
        blockCoords = try buffer("blockCoords", settings.maxBlocks * 16)
        meshStamp = try buffer("meshStamp", settings.maxBlocks * 4)
        voxels = try buffer("voxels", cubes * 4)
        colors = try buffer("colors", cubes * 4)
        cubeState = try buffer("cubeState", cubes * 2)
        edgeVertex = try buffer("edgeVertex", cubes * 12)
        triangleBlock = try buffer("triangleBlock", cubes * 4)
        vertices = try buffer("vertices", settings.maxVertices * MemoryLayout<MeshVertex>.stride)
        vertexOwner = try buffer("vertexOwner", settings.maxVertices * 4)
        vertexRef = try buffer("vertexRef", settings.maxVertices * 4)
        vertexFreeList = try buffer("vertexFreeList", settings.maxVertices * 4)
        triangles = try buffer("triangles", settings.maxSurfaceCubes * Int(RT_MAX_TRIANGLES_PER_CUBE) * 12)
        triangleFreeList = try buffer("triangleFreeList", settings.maxSurfaceCubes * 4)
        activeList = try buffer("activeList", settings.maxBlocks * 4)
        meshList = try buffer("meshList", settings.maxBlocks * 4)
        garbageList = try buffer("garbageList", settings.garbageCapacity * 4)
        counters = try buffer("counters", Int(RT_COUNTER_COUNT) * 4)
        indirectArgs = try buffer("indirectArgs", Int(RT_ARGS_COUNT) * 4)
    }

    /// Bytes of GPU memory held by the reconstruction.
    var allocatedBytes: Int {
        [hashKeys, hashValues, activeStamp, blockCoords, meshStamp, voxels, colors, cubeState, edgeVertex,
         triangleBlock, vertices, vertexOwner, vertexRef, vertexFreeList, triangles, triangleFreeList,
         activeList, meshList, garbageList, counters, indirectArgs].reduce(0) { $0 + $1.length }
    }

    /// Clears everything. Encoded on the GPU timeline, so it is safe to call between frames.
    func reset(commandBuffer: MTLCommandBuffer) {
        frameIndex = 0
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.label = "Reset reconstruction"
        for buffer in [hashKeys, hashValues, activeStamp, meshStamp, edgeVertex, triangleBlock, vertexOwner, vertexRef] {
            blit.fill(buffer: buffer, range: 0..<buffer.length, value: 0xFF)
        }
        for buffer in [voxels, colors, cubeState, vertices, triangles, indirectArgs] {
            blit.fill(buffer: buffer, range: 0..<buffer.length, value: 0)
        }
        blit.endEncoding()

        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.label = "Initialize free lists"
        var sizes = SIMD2<UInt32>(UInt32(settings.maxVertices), UInt32(settings.maxSurfaceCubes))
        encoder.setComputePipelineState(initializePipeline)
        encoder.setBuffer(vertexFreeList, offset: 0, index: 0)
        encoder.setBuffer(triangleFreeList, offset: 0, index: 1)
        encoder.setBuffer(counters, offset: 0, index: 2)
        encoder.setBytes(&sizes, length: MemoryLayout.size(ofValue: sizes), index: 3)
        dispatch(encoder, threads: max(settings.maxVertices, settings.maxSurfaceCubes), pipeline: initializePipeline)
        encoder.endEncoding()
    }

    /// Fuses one frame and updates the mesh.
    func integrate(_ frame: FrameInput, commandBuffer: MTLCommandBuffer) {
        frameIndex &+= 1
        var u = uniforms(for: frame)

        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.label = "Clear frame counters"
        blit.fill(buffer: counters, range: Int(RT_FIRST_FRAME_COUNTER) * 4..<Int(RT_COUNTER_COUNT) * 4, value: 0)
        blit.endEncoding()

        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.label = "Reconstruct frame \(frameIndex)"
        let uniformsLength = MemoryLayout<FrameUniforms>.stride
        let cubesPerBlock = UInt32(RT_CUBES_PER_BLOCK)
        let listCapacity = UInt32(settings.maxBlocks)

        encoder.setComputePipelineState(allocatePipeline)
        encoder.setTexture(frame.depth, index: 0)
        encoder.setTexture(frame.confidence, index: 1)
        encoder.setBytes(&u, length: uniformsLength, index: 0)
        encoder.setBuffers([hashKeys, hashValues, blockCoords, activeStamp, activeList, counters],
                           offsets: Array(repeating: 0, count: 6), range: 1..<7)
        encoder.dispatchThreads(MTLSize(width: frame.depth.width, height: frame.depth.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))

        prepareIndirect(encoder, counter: RT_COUNTER_ACTIVE, threadsPerItem: cubesPerBlock,
                        argument: RT_ARGS_ACTIVE_CUBES, capacity: listCapacity)
        prepareIndirect(encoder, counter: RT_COUNTER_ACTIVE, threadsPerItem: 8,
                        argument: RT_ARGS_ACTIVE_NEIGHBORS, capacity: listCapacity)

        encoder.setComputePipelineState(integratePipeline)
        encoder.setTextures([frame.depth, frame.confidence, frame.colorY, frame.colorCbCr], range: 0..<4)
        encoder.setBytes(&u, length: uniformsLength, index: 0)
        encoder.setBuffers([hashValues, blockCoords, activeList, counters, voxels, colors],
                           offsets: Array(repeating: 0, count: 6), range: 1..<7)
        dispatchIndirect(encoder, argument: RT_ARGS_ACTIVE_CUBES)

        encoder.setComputePipelineState(collectMeshPipeline)
        encoder.setBytes(&u, length: uniformsLength, index: 0)
        encoder.setBuffers([hashKeys, hashValues, blockCoords, activeList, counters, meshStamp, meshList],
                           offsets: Array(repeating: 0, count: 7), range: 1..<8)
        dispatchIndirect(encoder, argument: RT_ARGS_ACTIVE_NEIGHBORS)

        prepareIndirect(encoder, counter: RT_COUNTER_MESH, threadsPerItem: cubesPerBlock,
                        argument: RT_ARGS_MESH_CUBES, capacity: listCapacity)

        encoder.setComputePipelineState(classifyPipeline)
        encoder.setBytes(&u, length: uniformsLength, index: 0)
        encoder.setBuffers([hashKeys, hashValues, blockCoords, meshList, counters, voxels, cubeState, edgeVertex,
                            triangleBlock, vertexFreeList, triangleFreeList, vertexOwner, vertexRef, garbageList],
                           offsets: Array(repeating: 0, count: 14), range: 1..<15)
        dispatchIndirect(encoder, argument: RT_ARGS_MESH_CUBES)

        encoder.setComputePipelineState(triangulatePipeline)
        encoder.setBytes(&u, length: uniformsLength, index: 0)
        encoder.setBuffers([hashKeys, hashValues, blockCoords, meshList, counters, voxels, cubeState, edgeVertex,
                            triangleBlock, colors, triangleFreeList, vertices, vertexRef, garbageList, triangles],
                           offsets: Array(repeating: 0, count: 15), range: 1..<16)
        dispatchIndirect(encoder, argument: RT_ARGS_MESH_CUBES)

        prepareIndirect(encoder, counter: RT_COUNTER_GARBAGE, threadsPerItem: 1,
                        argument: RT_ARGS_GARBAGE, capacity: UInt32(settings.garbageCapacity))

        encoder.setComputePipelineState(garbagePipeline)
        encoder.setBytes(&u, length: uniformsLength, index: 0)
        encoder.setBuffers([counters, garbageList, vertexRef, vertexOwner, edgeVertex, vertexFreeList],
                           offsets: Array(repeating: 0, count: 6), range: 1..<7)
        dispatchIndirect(encoder, argument: RT_ARGS_GARBAGE)

        encoder.setComputePipelineState(prepareDrawPipeline)
        encoder.setBuffer(counters, offset: 0, index: 0)
        encoder.setBuffer(indirectArgs, offset: 0, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// Draws the mesh. The caller sets the pipeline, depth state and MeshUniforms (vertex buffer 1, fragment buffer 0).
    func drawMesh(_ encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexType: .uint32, indexBuffer: triangles,
                                      indexBufferOffset: 0, indirectBuffer: indirectArgs,
                                      indirectBufferOffset: drawArgumentsOffset)
    }

    /// Reads the counters. Values may be a frame stale while the GPU is busy.
    func stats() -> ReconstructionStats {
        let c = counters.contents().bindMemory(to: Int32.self, capacity: Int(RT_COUNTER_COUNT))
        var stats = ReconstructionStats()
        stats.blocks = min(Int(c[Int(RT_COUNTER_BLOCKS)]), settings.maxBlocks)
        stats.vertices = settings.maxVertices - Int(c[Int(RT_COUNTER_VERTEX_FREE_TOP)])
        stats.triangles = Int(c[Int(RT_COUNTER_TRIANGLES)])
        stats.activeBlocks = Int(c[Int(RT_COUNTER_ACTIVE)])
        stats.retriangulatedCubes = Int(c[Int(RT_COUNTER_RETRIANGULATED)])
        stats.overflow = c[Int(RT_COUNTER_OVERFLOW)]
        return stats
    }

    private func uniforms(for frame: FrameInput) -> FrameUniforms {
        let k = frame.colorIntrinsics
        let color = SIMD4<Float>(k[0][0], k[1][1], k[2][0], k[2][1])
        // Depth and color share the optical centre; only the resolution differs.
        let scale = SIMD2<Float>(Float(frame.depth.width) / Float(frame.colorY.width),
                                 Float(frame.depth.height) / Float(frame.colorY.height))
        let depth = SIMD4<Float>(color.x * scale.x, color.y * scale.y, color.z * scale.x, color.w * scale.y)
        var u = FrameUniforms()
        u.cameraToWorld = frame.cameraToWorld
        u.worldToCamera = frame.cameraToWorld.inverse
        u.depthIntrinsics = depth
        u.colorIntrinsics = color
        u.depthSize = SIMD2(UInt32(frame.depth.width), UInt32(frame.depth.height))
        u.colorSize = SIMD2(UInt32(frame.colorY.width), UInt32(frame.colorY.height))
        u.voxelSize = settings.voxelSize
        u.truncation = settings.voxelSize * settings.truncationInVoxels
        u.minDepth = settings.minDepth
        u.maxDepth = settings.maxDepth
        u.maxWeight = settings.maxWeight
        u.refineThreshold = settings.voxelSize * settings.refineThresholdInVoxels
        u.minConfidence = settings.minConfidence
        u.frameIndex = frameIndex
        u.hashMask = UInt32(settings.hashSlots - 1)
        u.maxBlocks = UInt32(settings.maxBlocks)
        u.listCapacity = UInt32(settings.maxBlocks)
        u.garbageCapacity = UInt32(settings.garbageCapacity)
        return u
    }

    private func prepareIndirect(_ encoder: MTLComputeCommandEncoder, counter: Int32, threadsPerItem: UInt32,
                                 argument: Int32, capacity: UInt32) {
        var params = SIMD4<UInt32>(UInt32(counter), threadsPerItem, UInt32(argument), capacity)
        encoder.setComputePipelineState(prepareIndirectPipeline)
        encoder.setBuffer(counters, offset: 0, index: 0)
        encoder.setBuffer(indirectArgs, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }

    private func dispatchIndirect(_ encoder: MTLComputeCommandEncoder, argument: Int32) {
        encoder.dispatchThreadgroups(indirectBuffer: indirectArgs, indirectBufferOffset: Int(argument) * 4,
                                     threadsPerThreadgroup: MTLSize(width: Int(RT_THREADGROUP_SIZE), height: 1, depth: 1))
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, threads: Int, pipeline: MTLComputePipelineState) {
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreadgroups(MTLSize(width: (threads + width - 1) / width, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }
}
