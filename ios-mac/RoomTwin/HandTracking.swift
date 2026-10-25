import ARKit
import ImageIO
import MetalKit
import SceneKit
import SwiftUI
import Vision

/// A camera-independent hand sample. Coordinates use Vision's normalized,
/// portrait image space (origin at the lower left).
struct HandPoseSample {
    /// Midway between the thumb and index tips, or nil when they or the palm
    /// are too unclear to steer or pinch by.
    let cursor: CGPoint?
    let pinchRatio: CGFloat
    let confidence: Float
}

/// Detection is deliberately separate from manipulation. A MediaPipe or
/// Vision Pro provider can implement this protocol without changing the room
/// interaction code. Called on the camera's queue only.
protocol HandLandmarkProvider: AnyObject {
    func detect(in image: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> HandPoseSample?
    func reset()
}

/// Apple's on-device hand-pose request, with the thumb and index tips smoothed.
final class VisionHandLandmarkProvider: HandLandmarkProvider {
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()
    private var filteredThumb: CGPoint?
    private var filteredIndex: CGPoint?
    private var misses = 0

    func detect(in image: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> HandPoseSample? {
        do {
            try VNImageRequestHandler(cvPixelBuffer: image, orientation: orientation).perform([request])
            return try makeSample(from: request.results?.first)
        } catch {
            return nil
        }
    }

    func reset() {
        filteredThumb = nil
        filteredIndex = nil
        misses = 0
    }

    private func makeSample(from observation: VNHumanHandPoseObservation?) throws -> HandPoseSample? {
        guard let observation else {
            noteMiss()
            return nil
        }
        let points = try observation.recognizedPoints(.all)
        guard let thumb = points[.thumbTip], let index = points[.indexTip],
              let indexMCP = points[.indexMCP], let littleMCP = points[.littleMCP] else {
            noteMiss()
            return HandPoseSample(cursor: nil, pinchRatio: 1, confidence: 0)
        }
        let confidence = min(thumb.confidence, index.confidence, indexMCP.confidence, littleMCP.confidence)
        guard confidence >= 0.35 else {
            noteMiss()
            return HandPoseSample(cursor: nil, pinchRatio: 1, confidence: confidence)
        }

        misses = 0
        let alpha: CGFloat = 0.38
        filteredThumb = smooth(CGPoint(x: thumb.location.x, y: thumb.location.y), from: filteredThumb, alpha: alpha)
        filteredIndex = smooth(CGPoint(x: index.location.x, y: index.location.y), from: filteredIndex, alpha: alpha)
        guard let filteredThumb, let filteredIndex else { return nil }
        let palm = hypot(indexMCP.location.x - littleMCP.location.x,
                         indexMCP.location.y - littleMCP.location.y)
        let separation = hypot(filteredThumb.x - filteredIndex.x, filteredThumb.y - filteredIndex.y)
        return HandPoseSample(
            cursor: CGPoint(x: (filteredThumb.x + filteredIndex.x) / 2,
                            y: (filteredThumb.y + filteredIndex.y) / 2),
            pinchRatio: separation / max(palm, 0.035),
            confidence: confidence
        )
    }

    private func noteMiss() {
        misses += 1
        if misses >= 3 {
            filteredThumb = nil
            filteredIndex = nil
        }
    }

    private func smooth(_ point: CGPoint, from previous: CGPoint?, alpha: CGFloat) -> CGPoint {
        guard let previous else { return point }
        return CGPoint(x: previous.x + (point.x - previous.x) * alpha,
                       y: previous.y + (point.y - previous.y) * alpha)
    }
}

/// The back camera through ARKit, for following a hand while walking round a
/// room layout. ARKit's person segmentation, the same as AR uses to put
/// people in front of virtual things, gives the matte that draws the hand
/// into the room (HandMatte), and Vision finds the hand's joints in the same
/// frames, about 15 a second. RoomPlan and the scanner have stopped their
/// sessions by then, so this one has the camera to itself.
final class HandCamera: NSObject, ARSessionDelegate {
    let session = ARSession()
    /// Each looked-at frame's hand, or nil for none, on the main thread.
    var onSample: ((HandPoseSample?) -> Void)?
    var onFailure: ((String) -> Void)?

    private let provider: HandLandmarkProvider = VisionHandLandmarkProvider()
    private let queue = DispatchQueue(label: "dev.roomtwin.hand-camera", qos: .userInitiated)
    private var lastLooked: TimeInterval = 0

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    func start() {
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
            configuration.frameSemantics = .personSegmentation
        }
        queue.async { [self] in
            provider.reset()
            lastLooked = 0
        }
        session.run(configuration, options: [.resetTracking])
    }

    func stop() {
        session.pause()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastLooked >= 1.0 / 15 else { return }
        lastLooked = frame.timestamp
        // The captured image is landscape; .right reads it upright.
        let sample = provider.detect(in: frame.capturedImage, orientation: .right)
        DispatchQueue.main.async { self.onSample?(sample) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.onFailure?("The camera stopped: \(error.localizedDescription)") }
    }
}

/// Draws the user's own hand into the room preview: the camera image where
/// ARKit's person segmentation finds them and clear everywhere else, filling
/// the screen the way AR Edit's camera view does, so it lines up with the
/// hand cursor. A transparent Metal view over the SceneKit one.
final class HandMatte: NSObject, MTKViewDelegate {
    let view: MTKView
    private let session: ARSession
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    init?(session: ARSession) {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        let view = MTKView(frame: .zero, device: device)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Hand matte"
        descriptor.vertexFunction = library.makeFunction(name: "cameraVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "handFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor), let cache else { return nil }
        self.view = view
        self.session = session
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        textureCache = cache
        super.init()
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Clears every frame, so a hand that has gone doesn't linger.
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let frame = session.currentFrame, let segmentation = frame.segmentationBuffer,
           let y = texture(frame.capturedImage, plane: 0, format: .r8Unorm),
           let cbcr = texture(frame.capturedImage, plane: 1, format: .rg8Unorm),
           let matte = texture(segmentation, plane: 0, format: .r8Unorm) {
            // Map the screen corners into the landscape camera image, as ScanRenderer does.
            let toImage = frame.displayTransform(for: .portrait, viewportSize: view.bounds.size).inverted()
            var uvs = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)].map {
                let p = $0.applying(toImage)
                return SIMD2(Float(p.x), Float(p.y))
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uvs, length: MemoryLayout<SIMD2<Float>>.stride * 4, index: 0)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(cbcr), index: 1)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(matte), index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // The camera's buffers must outlive the GPU's use of them.
            commandBuffer.addCompletedHandler { _ in _ = [y, cbcr, matte] }
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
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

/// The hand matte in SwiftUI. It keeps the HandMatte, as an MTKView holds its delegate weakly.
struct HandMatteView: UIViewRepresentable {
    let session: ARSession

    func makeCoordinator() -> HandMatte? { HandMatte(session: session) }
    func makeUIView(context: Context) -> UIView { context.coordinator?.view ?? UIView() }
    func updateUIView(_ view: UIView, context: Context) {}
}

/// Pinch recognition with scale-independent thresholds, hysteresis and a
/// two-frame confirmation. This prevents a noisy single frame from grabbing
/// or releasing furniture.
struct PinchGestureRecognizer {
    enum Update { case open, began, pinched, ended }

    private(set) var isPinched = false
    private var closeFrames = 0
    private var openFrames = 0
    private let closeThreshold: CGFloat = 0.34
    private let releaseThreshold: CGFloat = 0.52

    mutating func update(ratio: CGFloat, confidence: Float) -> Update {
        guard confidence >= 0.35 else { return isPinched ? .pinched : .open }
        if isPinched {
            if ratio >= releaseThreshold { openFrames += 1 } else { openFrames = 0 }
            if openFrames >= 2 {
                isPinched = false
                openFrames = 0
                closeFrames = 0
                return .ended
            }
            return .pinched
        }
        if ratio <= closeThreshold { closeFrames += 1 } else { closeFrames = 0 }
        if closeFrames >= 2 {
            isPinched = true
            closeFrames = 0
            return .began
        }
        return .open
    }

    mutating func cancel() -> Bool {
        let wasPinched = isPinched
        self = PinchGestureRecognizer()
        return wasPinched
    }
}

/// Converts a cursor into a world ray and its intersection with the plane a
/// grabbed piece moves in.
enum ScreenToSceneMapper {
    struct Ray {
        let origin: SIMD3<Float>
        let direction: SIMD3<Float>
    }

    static func ray(in view: SCNView, at point: CGPoint) -> Ray? {
        guard view.bounds.contains(point) else { return nil }
        let near = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
        let far = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
        let origin = SIMD3<Float>(near.x, near.y, near.z)
        let delta = SIMD3<Float>(far.x - near.x, far.y - near.y, far.z - near.z)
        guard simd_length_squared(delta) > 1e-8 else { return nil }
        return Ray(origin: origin, direction: simd_normalize(delta))
    }

    static func intersection(of ray: Ray, planePoint: SIMD3<Float>,
                             planeNormal: SIMD3<Float>) -> SIMD3<Float>? {
        let denominator = simd_dot(ray.direction, planeNormal)
        guard abs(denominator) > 0.025 else { return nil }
        let distance = simd_dot(planePoint - ray.origin, planeNormal) / denominator
        guard distance > 0.05, distance < 20 else { return nil }
        return ray.origin + distance * ray.direction
    }
}

/// Lets a hand held up behind the phone pick up and move furniture while
/// walking round a room layout: aim with the gap between thumb and index,
/// pinch to grab, move, open the fingers to drop. Off until turned on, as it
/// runs the camera.
@MainActor
final class HandInteractionController: ObservableObject {
    enum Tracking { case off, searching, found, holding }

    @Published private(set) var isEnabled = false
    @Published private(set) var tracking = Tracking.off
    /// Between thumb and index, in the SceneKit view's points.
    @Published private(set) var cursor: CGPoint?
    @Published private(set) var isPinching = false
    @Published private(set) var isGrabbing = false
    @Published private(set) var targetedObject: String?
    @Published private(set) var status = "Hand tracking off"

    var onSelection: ((String?) -> Void)?
    var onEditCommitted: (() -> Void)?
    let camera = HandCamera()

    private weak var scene: PreviewScene?
    private var recognizer = PinchGestureRecognizer()
    /// Whether the current view takes hands at all.
    private var isAvailable = false
    private var lastSeen = 0.0
    private var reportedLoss = false

    init() {
        camera.onSample = { [weak self] sample in
            Task { @MainActor in self?.consume(sample) }
        }
        camera.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.disableInput(release: true)
                self?.status = message
            }
        }
    }

    func configure(scene: PreviewScene) {
        self.scene = scene
    }

    /// Whether hands can be used in the view now showing. Leaving it turns
    /// tracking, and the camera, off.
    func setAvailable(_ available: Bool) {
        guard available != isAvailable else { return }
        isAvailable = available
        if !available { disableInput(release: true) }
    }

    func toggle() {
        guard isAvailable else { return }
        if isEnabled {
            disableInput(release: true)
        } else {
            enableInput()
        }
    }

    func stop() {
        setAvailable(false)
        scene = nil
    }

    private func enableInput() {
        isEnabled = true
        recognizer = PinchGestureRecognizer()
        lastSeen = 0
        reportedLoss = false
        tracking = .searching
        status = "Looking for your hand"
        camera.start()
    }

    private func consume(_ sample: HandPoseSample?) {
        guard isEnabled, let scene, let frame = camera.session.currentFrame else { return }
        guard let sample else {
            noteNoHand()
            return
        }
        lastSeen = CACurrentMediaTime()
        reportedLoss = false
        guard let cursorPoint = sample.cursor,
              let point = scene.screenPoint(forVisionPoint: cursorPoint, in: frame) else {
            // A grab carries on through a blurry frame or two; noteNoHand ends it if the hand goes.
            cursor = nil
            if !isGrabbing {
                tracking = .searching
                status = "Show your thumb and index finger"
            }
            return
        }
        cursor = point

        let update = recognizer.update(ratio: sample.pinchRatio, confidence: sample.confidence)
        isPinching = recognizer.isPinched
        switch update {
        case .open:
            let target = scene.previewHandTarget(at: point)
            targetedObject = target
            onSelection?(target)
        case .began:
            if let name = scene.beginHandGrab(at: point) {
                isGrabbing = true
                targetedObject = name
                onSelection?(name)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        case .pinched:
            if isGrabbing { _ = scene.updateHandGrab(at: point) }
        case .ended:
            releaseGrab()
        }
        tracking = isGrabbing ? .holding : .found
        status = isGrabbing ? "Holding \(targetedObject ?? "object")"
            : targetedObject.map { "Pinch to grab \($0)" } ?? "Hand found"
    }

    /// No hand in this frame. Once it has been gone for 0.4 s, anything held
    /// is dropped where it is.
    private func noteNoHand() {
        guard lastSeen > 0, CACurrentMediaTime() - lastSeen > 0.4, !reportedLoss else { return }
        reportedLoss = true
        cursor = nil
        tracking = .searching
        status = "Hand lost"
        if recognizer.cancel() { releaseGrab() }
        scene?.clearSelection()
        targetedObject = nil
        onSelection?(nil)
    }

    private func releaseGrab() {
        if scene?.endHandGrab() != nil {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onEditCommitted?()
        }
        isPinching = false
        isGrabbing = false
    }

    private func disableInput(release: Bool) {
        if release { releaseGrab() }
        if isEnabled { camera.stop() }
        isEnabled = false
        tracking = .off
        cursor = nil
        isPinching = false
        isGrabbing = false
        targetedObject = nil
        lastSeen = 0
        reportedLoss = false
        recognizer = PinchGestureRecognizer()
        scene?.clearSelection()
        onSelection?(nil)
        status = "Hand tracking off"
    }
}
