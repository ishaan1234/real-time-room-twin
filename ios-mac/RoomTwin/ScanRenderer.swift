import ARKit
import Darwin.Mach
import MetalKit

enum ScanPerformanceProfile {
    case detailed, hybrid
}

struct RoomPlanGuideBox {
    var transform: simd_float4x4
    var dimensions: SIMD3<Float>
    var identifier: UUID?
    var state: FurniturePhotoState = .detected

    var color: SIMD4<Float> {
        // Structural RoomPlan guides stay white. Only detected furniture has
        // the manual-capture red/yellow/green state machine.
        if identifier == nil { return SIMD4(1, 1, 1, 0.92) }
        switch state {
        // Red is deliberately reserved for action required: RoomPlan knows
        // about this item, but the user has not framed and photographed it.
        case .detected: return SIMD4(1, 0.12, 0.12, 0.98)
        case .ready: return SIMD4(1, 0.78, 0.05, 0.98)
        case .captured: return SIMD4(0.18, 1, 0.32, 0.98)
        }
    }
}

enum FurniturePhotoState: Equatable {
    case detected, ready, captured
}

enum MeshViewMode: CaseIterable {
    case color, shaded, hidden

    var label: String {
        switch self {
        case .color: "Color"
        case .shaded: "Gray"
        case .hidden: "Hidden"
        }
    }

    var systemImage: String {
        self == .hidden ? "eye.slash" : "eye"
    }
}

/// Runs the AR session, feeds each new LiDAR frame to the reconstructor and
/// draws the camera image with the mesh on top. All methods run on the main thread.
final class ScanRenderer: NSObject, MTKViewDelegate {
    let session = ARSession()
    let device: MTLDevice
    let reconstructor: Reconstructor
    private weak var view: MTKView?

    var isScanning = false
    var viewMode = MeshViewMode.color
    /// Offered every fused frame.
    var keyframes: KeyframeRecorder?
    /// Called on the main thread a few times per second.
    var onStats: ((ReconstructionStats) -> Void)?
    /// Called on the main thread when the advice for the user changes; nil
    /// once tracking is normal and frames can be fused again.
    var onTrackingHint: ((String?) -> Void)?

    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let cameraPipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState
    private let guidePipeline: MTLRenderPipelineState
    private let cameraDepthState: MTLDepthStencilState
    private let meshDepthState: MTLDepthStencilState
    private let framesInFlight = DispatchSemaphore(value: 3)
    private var viewportSize = CGSize(width: 1, height: 1)
    private var lastIntegratedTimestamp: TimeInterval = 0
    /// When the last fused frame was taken and where the camera was, to tell
    /// how fast it was moving.
    private var lastIntegratedPose: (time: TimeInterval, transform: simd_float4x4)?
    private var needsReset = true
    private var frameCounter = 0
    private var trackingHint: String?
    private var pendingHint: (hint: String?, since: TimeInterval)?
    private var profile = ScanPerformanceProfile.detailed
    private var reportStarted = ProcessInfo.processInfo.systemUptime
    private var drawsSinceReport = 0
    private var integrationsSinceReport = 0
    private var lastGPUMilliseconds = 0.0
    private let guideLock = NSLock()
    private var roomPlanGuide: [RoomPlanGuideBox] = []

    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            throw ReconstructionError.missingFunction("Metal device or default library")
        }
        self.device = device
        self.view = view
        commandQueue = queue
        reconstructor = try Reconstructor(device: device, library: library)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache!

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 60

        let camera = MTLRenderPipelineDescriptor()
        camera.label = "Camera image"
        camera.vertexFunction = library.makeFunction(name: "cameraVertex")
        camera.fragmentFunction = library.makeFunction(name: "cameraFragment")
        camera.colorAttachments[0].pixelFormat = view.colorPixelFormat
        camera.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        cameraPipeline = try device.makeRenderPipelineState(descriptor: camera)

        let mesh = MTLRenderPipelineDescriptor()
        mesh.label = "Mesh"
        mesh.vertexFunction = library.makeFunction(name: "meshVertex")
        mesh.fragmentFunction = library.makeFunction(name: "meshFragment")
        mesh.colorAttachments[0].pixelFormat = view.colorPixelFormat
        mesh.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        meshPipeline = try device.makeRenderPipelineState(descriptor: mesh)

        let guide = MTLRenderPipelineDescriptor()
        guide.label = "RoomPlan guide"
        guide.vertexFunction = library.makeFunction(name: "roomGuideVertex")
        guide.fragmentFunction = library.makeFunction(name: "roomGuideFragment")
        guide.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guide.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        guide.colorAttachments[0].isBlendingEnabled = true
        guide.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        guide.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        guide.colorAttachments[0].sourceAlphaBlendFactor = .one
        guide.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guidePipeline = try device.makeRenderPipelineState(descriptor: guide)

        let always = MTLDepthStencilDescriptor()
        always.depthCompareFunction = .always
        always.isDepthWriteEnabled = false
        cameraDepthState = device.makeDepthStencilState(descriptor: always)!
        let less = MTLDepthStencilDescriptor()
        less.depthCompareFunction = .less
        less.isDepthWriteEnabled = true
        meshDepthState = device.makeDepthStencilState(descriptor: less)!

        super.init()
        view.delegate = self
    }

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func start(profile: ScanPerformanceProfile? = nil) {
        if let profile { self.profile = profile }
        let configuration = ARWorldTrackingConfiguration()
        // Depth only: the reconstruction here is our own, so ARKit's planes and
        // mesh would only spend CPU.
        configuration.frameSemantics = [.sceneDepth]
        if self.profile == .hybrid, let format = Self.bestThirtyFPSFormat() {
            configuration.videoFormat = format
            Diagnostics.log("hybrid camera: \(Int(format.imageResolution.width))x\(Int(format.imageResolution.height)) @ \(format.framesPerSecond) FPS")
        }
        view?.preferredFramesPerSecond = self.profile == .hybrid ? 30 : 60
        session.run(configuration)
    }

    /// Reconfigures the existing ARSession without resetting tracking, so a
    /// RoomPlan session created from it retains the same world coordinates.
    func use(_ profile: ScanPerformanceProfile) {
        guard profile != self.profile else {
            view?.preferredFramesPerSecond = profile == .hybrid ? 30 : 60
            return
        }
        start(profile: profile)
    }

    func pause() {
        session.pause()
    }

    func reset() {
        needsReset = true
    }

    /// RoomPlan detections update relatively slowly, but their boxes are
    /// reprojected inside the Metal draw using every ARFrame. The guide thus
    /// follows the camera at the same 30 FPS as the detailed mesh.
    func setRoomPlanGuide(_ boxes: [RoomPlanGuideBox]) {
        guideLock.lock()
        roomPlanGuide = boxes
        guideLock.unlock()
    }

    func setFurniturePhotoStates(_ states: [UUID: FurniturePhotoState]) {
        guideLock.lock()
        for index in roomPlanGuide.indices {
            guard let identifier = roomPlanGuide[index].identifier else { continue }
            roomPlanGuide[index].state = states[identifier] ?? .detected
        }
        guideLock.unlock()
    }

    /// Runs `body` on a background queue once all GPU work submitted so far has finished.
    func whenGPUIdle(_ body: @escaping () -> Void) {
        let commandBuffer = commandQueue.makeCommandBuffer()!
        commandBuffer.addCompletedHandler { _ in DispatchQueue.global(qos: .userInitiated).async(execute: body) }
        commandBuffer.commit()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = size
    }

    func draw(in view: MTKView) {
        guard let frame = session.currentFrame,
              let capturedY = texture(frame.capturedImage, plane: 0, format: .r8Unorm),
              let capturedCbCr = texture(frame.capturedImage, plane: 1, format: .rg8Unorm) else { return }
        drawsSinceReport += 1
        updateTrackingHint(frame)
        Diagnostics.note("draw: waiting for GPU")
        let waitStart = ProcessInfo.processInfo.systemUptime
        framesInFlight.wait()
        logIfSlow("waiting for in-flight frames", since: waitStart)
        Diagnostics.note("draw: encoding")
        var retained: [CVMetalTexture] = [capturedY, capturedCbCr]

        let reconstructionBuffer = commandQueue.makeCommandBuffer()!
        reconstructionBuffer.label = "Reconstruction"
        if needsReset {
            reconstructor.reset(commandBuffer: reconstructionBuffer)
            needsReset = false
        }
        let minimumInterval = 1.0 / targetIntegrationFPS
        if isScanning, frame.timestamp - lastIntegratedTimestamp >= minimumInterval * 0.9,
           case .normal = frame.camera.trackingState,
           let sceneDepth = frame.sceneDepth, let confidenceMap = sceneDepth.confidenceMap,
           let depth = texture(sceneDepth.depthMap, plane: 0, format: .r32Float),
           let confidence = texture(confidenceMap, plane: 0, format: .r8Uint) {
            let colorWeight = Self.sharpness(of: frame, since: lastIntegratedPose)
            lastIntegratedTimestamp = frame.timestamp
            lastIntegratedPose = (frame.timestamp, frame.camera.transform)
            retained += [depth, confidence]
            let input = FrameInput(depth: CVMetalTextureGetTexture(depth)!,
                                   confidence: CVMetalTextureGetTexture(confidence)!,
                                   colorY: CVMetalTextureGetTexture(capturedY)!,
                                   colorCbCr: CVMetalTextureGetTexture(capturedCbCr)!,
                                   colorIntrinsics: frame.camera.intrinsics,
                                   cameraToWorld: frame.camera.transform,
                                   colorWeight: colorWeight)
            reconstructor.integrate(input, commandBuffer: reconstructionBuffer)
            keyframes?.consider(frame, viewportSize: viewportSize)
            frameCounter += 1
            integrationsSinceReport += 1
            reconstructionBuffer.addCompletedHandler { [weak self] buffer in
                let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                DispatchQueue.main.async { self?.lastGPUMilliseconds = milliseconds }
            }
        }
        reportProblems(reconstructionBuffer)
        reconstructionBuffer.commit()

        let renderBuffer = commandQueue.makeCommandBuffer()!
        renderBuffer.label = "Render"
        reportProblems(renderBuffer)
        Diagnostics.note("draw: acquiring drawable")
        let drawableStart = ProcessInfo.processInfo.systemUptime
        let pass = view.currentRenderPassDescriptor, drawable = view.currentDrawable
        logIfSlow("acquiring a drawable", since: drawableStart)
        Diagnostics.note("draw: done")
        if let pass, let drawable, let encoder = renderBuffer.makeRenderCommandEncoder(descriptor: pass) {
            drawCamera(frame, y: capturedY, cbcr: capturedCbCr, encoder: encoder)
            if viewMode != .hidden {
                drawMesh(frame, encoder: encoder)
            }
            if profile == .hybrid { drawRoomPlanGuide(frame, encoder: encoder) }
            encoder.endEncoding()
            renderBuffer.present(drawable)
        }
        renderBuffer.addCompletedHandler { [framesInFlight] _ in
            _ = retained   // keep the ARKit pixel buffers alive until the GPU is done
            framesInFlight.signal()
        }
        renderBuffer.commit()
        reportPerformanceIfNeeded()
    }

    /// Hybrid starts at 30 reconstruction updates per second. Serious heat
    /// halves fusion work while keeping the camera/render UI at 30 FPS; at a
    /// critical state it drops further so iOS is less likely to terminate it.
    private var targetIntegrationFPS: Double {
        guard profile == .hybrid else { return 60 }
        switch ProcessInfo.processInfo.thermalState {
        case .serious: return 15
        case .critical: return 8
        default: return 30
        }
    }

    private func reportPerformanceIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - reportStarted
        guard elapsed >= 1 else { return }
        var stats = reconstructor.stats()
        stats.gpuMilliseconds = lastGPUMilliseconds
        stats.framesPerSecond = Double(drawsSinceReport) / elapsed
        stats.integrationsPerSecond = Double(integrationsSinceReport) / elapsed
        stats.memoryMegabytes = Self.residentMemoryMegabytes()
        stats.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        if frameCounter % 60 < integrationsSinceReport {
            Diagnostics.log(String(format: "reconstruction %.1f ms GPU, %.0f/%.0f render/fusion FPS, %d triangles, %.0f MB",
                                   stats.gpuMilliseconds, stats.framesPerSecond, stats.integrationsPerSecond,
                                   stats.triangles, stats.memoryMegabytes))
        }
        onStats?(stats)
        reportStarted = now
        drawsSinceReport = 0
        integrationsSinceReport = 0
    }

    private static func bestThirtyFPSFormat() -> ARConfiguration.VideoFormat? {
        // RoomPlan is designed around the normal AR camera field of view. A
        // device can also advertise large cinematic formats at 30 FPS; those
        // would increase bandwidth and heat, defeating Hybrid's purpose.
        let targetPixels = 1920.0 * 1440.0
        return ARWorldTrackingConfiguration.supportedVideoFormats
            .filter { $0.framesPerSecond == 30 }
            .min { lhs, rhs in
                abs(lhs.imageResolution.width * lhs.imageResolution.height - targetPixels)
                    < abs(rhs.imageResolution.width * rhs.imageResolution.height - targetPixels)
            }
    }

    private static func residentMemoryMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    // MARK: Tracking hint

    /// Frames are only fused while tracking is normal, so say why it isn't.
    /// A change is passed on once it has held for half a second, so brief
    /// dips don't flicker on screen.
    private func updateTrackingHint(_ frame: ARFrame) {
        let hint = Self.hint(for: frame.camera.trackingState)
        guard hint != trackingHint else {
            pendingHint = nil
            return
        }
        guard let pending = pendingHint, pending.hint == hint else {
            pendingHint = (hint, frame.timestamp)
            return
        }
        guard frame.timestamp - pending.since >= 0.5 else { return }
        trackingHint = hint
        pendingHint = nil
        Diagnostics.log("tracking hint: \(hint ?? "none")")
        onTrackingHint?(hint)
    }

    private static func hint(for state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal:
            return nil
        case .notAvailable, .limited(.initializing):
            return "Move the phone slowly to start tracking"
        case .limited(.excessiveMotion):
            return "Moving too fast. Slow down."
        case .limited(.insufficientFeatures):
            return "Not enough detail. Add light or aim at something textured."
        case .limited(.relocalizing):
            return "Point the camera back at where you were"
        case .limited:
            return "Tracking is limited"
        }
    }

    // MARK: Drawing

    /// How much a frame's colour should count, from how far the picture
    /// smeared while it was exposed: 1 under about 2 pixels, falling to 0 by
    /// 8. Turning sweeps the image by the focal length in pixels per radian;
    /// moving sweeps it by that over the distance, taken as 1.5 m.
    private static func sharpness(of frame: ARFrame,
                                  since last: (time: TimeInterval, transform: simd_float4x4)?) -> Float {
        guard let last, frame.timestamp > last.time else { return 1 }
        let elapsed = Float(frame.timestamp - last.time)
        var turn = (simd_quatf(frame.camera.transform) * simd_quatf(last.transform).inverse).angle
        turn = min(turn, 2 * .pi - turn)
        let shift = simd_distance(SIMD3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y,
                                        frame.camera.transform.columns.3.z),
                                  SIMD3(last.transform.columns.3.x, last.transform.columns.3.y,
                                        last.transform.columns.3.z))
        let exposure = frame.camera.exposureDuration > 0 ? Float(frame.camera.exposureDuration) : 1 / 60
        let focal = frame.camera.intrinsics[0][0]
        let smear = (turn + shift / 1.5) / elapsed * focal * exposure
        return min(max(1 - (smear - 2) / 6, 0), 1)
    }

    private func drawCamera(_ frame: ARFrame, y: CVMetalTexture, cbcr: CVMetalTexture,
                            encoder: MTLRenderCommandEncoder) {
        // Map the screen corners into the landscape camera image.
        let toImage = frame.displayTransform(for: .portrait, viewportSize: viewportSize).inverted()
        let corners = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]
        var uvs = corners.map { point -> SIMD2<Float> in
            let p = point.applying(toImage)
            return SIMD2(Float(p.x), Float(p.y))
        }
        encoder.setRenderPipelineState(cameraPipeline)
        encoder.setDepthStencilState(cameraDepthState)
        encoder.setVertexBytes(&uvs, length: MemoryLayout<SIMD2<Float>>.stride * 4, index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(cbcr), index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawMesh(_ frame: ARFrame, encoder: MTLRenderCommandEncoder) {
        let projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: viewportSize,
                                                       zNear: 0.02, zFar: 30)
        var uniforms = MeshUniforms()
        uniforms.viewProjection = projection * frame.camera.viewMatrix(for: .portrait)
        uniforms.cameraPosition = frame.camera.transform.columns.3
        uniforms.clipHeight = .greatestFiniteMagnitude
        uniforms.mode = UInt32(viewMode == .shaded ? RT_MESH_MODE_SHADED : RT_MESH_MODE_COLOR)
        encoder.setRenderPipelineState(meshPipeline)
        encoder.setDepthStencilState(meshDepthState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MeshUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MeshUniforms>.stride, index: 0)
        reconstructor.drawMesh(encoder)
    }

    private func drawRoomPlanGuide(_ frame: ARFrame, encoder: MTLRenderCommandEncoder) {
        guideLock.lock()
        let boxes = roomPlanGuide
        guideLock.unlock()
        guard !boxes.isEmpty else { return }

        let projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: viewportSize,
                                                       zNear: 0.02, zFar: 30)
        var uniforms = MeshUniforms()
        uniforms.viewProjection = projection * frame.camera.viewMatrix(for: .portrait)
        encoder.setRenderPipelineState(guidePipeline)
        // Guidance is UI feedback, so it remains visible over reconstructed
        // geometry instead of disappearing through a noisy depth edge. Keep an
        // explicit valid state here: passing nil crashes the AGX driver on the
        // iPhone 14 Pro family even though the API's Swift type is optional.
        encoder.setDepthStencilState(cameraDepthState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MeshUniforms>.stride, index: 1)
        for box in boxes {
            var color = box.color
            let vertices = Self.guideVertices(for: box)
            vertices.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                encoder.setVertexBytes(base, length: bytes.count, index: 0)
            }
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
        }
    }

    private static func guideVertices(for box: RoomPlanGuideBox) -> [SIMD4<Float>] {
        let half = simd_max(box.dimensions / 2, SIMD3<Float>(repeating: 0.008))
        let signs: [SIMD3<Float>] = [
            [-1, -1, -1], [1, -1, -1], [-1, 1, -1], [1, 1, -1],
            [-1, -1, 1], [1, -1, 1], [-1, 1, 1], [1, 1, 1]
        ]
        let points = signs.map { sign in box.transform * SIMD4(sign * half, 1) }
        let edges = [(0, 1), (0, 2), (0, 4), (1, 3), (1, 5), (2, 3),
                     (2, 6), (3, 7), (4, 5), (4, 6), (5, 7), (6, 7)]
        return edges.flatMap { [points[$0.0], points[$0.1]] }
    }

    /// Logs command buffers that fail (e.g. a GPU timeout) or run over 100 ms on the GPU.
    private func reportProblems(_ commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { buffer in
            let label = buffer.label ?? "command buffer"
            if let error = buffer.error {
                Diagnostics.log("GPU error in \(label): \(error.localizedDescription)")
            }
            let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            if milliseconds > 100 {
                Diagnostics.log(String(format: "%@ took %.0f ms on the GPU", label, milliseconds))
            }
        }
    }

    private func logIfSlow(_ what: String, since start: TimeInterval) {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if elapsed > 0.1 {
            Diagnostics.log(String(format: "draw spent %.0f ms %@", elapsed * 1000, what))
        }
    }

    private func texture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) : CVPixelBufferGetHeight(pixelBuffer)
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, format,
                                                               width, height, plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }
}
