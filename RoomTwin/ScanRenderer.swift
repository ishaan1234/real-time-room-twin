import ARKit
import MetalKit

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
    private let cameraDepthState: MTLDepthStencilState
    private let meshDepthState: MTLDepthStencilState
    private let framesInFlight = DispatchSemaphore(value: 3)
    private var viewportSize = CGSize(width: 1, height: 1)
    private var lastIntegratedTimestamp: TimeInterval = 0
    private var needsReset = true
    private var frameCounter = 0
    private var trackingHint: String?
    private var pendingHint: (hint: String?, since: TimeInterval)?

    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            throw ReconstructionError.missingFunction("Metal device or default library")
        }
        self.device = device
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

    func start() {
        let configuration = ARWorldTrackingConfiguration()
        // Depth only: the reconstruction here is our own, so ARKit's planes and
        // mesh would only spend CPU.
        configuration.frameSemantics = [.sceneDepth]
        session.run(configuration)
    }

    func pause() {
        session.pause()
    }

    func reset() {
        needsReset = true
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
        if isScanning, frame.timestamp != lastIntegratedTimestamp, case .normal = frame.camera.trackingState,
           let sceneDepth = frame.sceneDepth, let confidenceMap = sceneDepth.confidenceMap,
           let depth = texture(sceneDepth.depthMap, plane: 0, format: .r32Float),
           let confidence = texture(confidenceMap, plane: 0, format: .r8Uint) {
            lastIntegratedTimestamp = frame.timestamp
            retained += [depth, confidence]
            let input = FrameInput(depth: CVMetalTextureGetTexture(depth)!,
                                   confidence: CVMetalTextureGetTexture(confidence)!,
                                   colorY: CVMetalTextureGetTexture(capturedY)!,
                                   colorCbCr: CVMetalTextureGetTexture(capturedCbCr)!,
                                   colorIntrinsics: frame.camera.intrinsics,
                                   cameraToWorld: frame.camera.transform)
            reconstructor.integrate(input, commandBuffer: reconstructionBuffer)
            keyframes?.consider(frame)
            frameCounter += 1
            if frameCounter % 10 == 0 {
                let logThisFrame = frameCounter % 60 == 0
                reconstructionBuffer.addCompletedHandler { [weak self] buffer in
                    guard let self else { return }
                    var stats = self.reconstructor.stats()
                    stats.gpuMilliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                    if logThisFrame {
                        Diagnostics.log(String(format: "reconstruction %.1f ms GPU, %d triangles, %d active blocks",
                                               stats.gpuMilliseconds, stats.triangles, stats.activeBlocks))
                    }
                    DispatchQueue.main.async { self.onStats?(stats) }
                }
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
            encoder.endEncoding()
            renderBuffer.present(drawable)
        }
        renderBuffer.addCompletedHandler { [framesInFlight] _ in
            _ = retained   // keep the ARKit pixel buffers alive until the GPU is done
            framesInFlight.signal()
        }
        renderBuffer.commit()
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
