import SceneKit
import SwiftUI

#if canImport(UIKit)
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

/// A model file (USDZ, or anything SceneKit opens) turning slowly on a clear
/// background, fitted to the view. Drag to turn it, pinch or scroll to zoom;
/// the turning stops once the viewer takes over. The light comes from just
/// above the viewer whichever way the model faces. Shared by the app and
/// RoomTwin Viewer.
struct SpinningModel: PlatformViewRepresentable {
    let url: URL
    /// False holds it still, so nothing is drawn while it waits out of sight.
    var isPlaying = true
    /// Called once the model is loaded and on the GPU, when it can appear
    /// without a hitch.
    var onReady: (() -> Void)? = nil
    /// The camera's vertical view angle in degrees. Wider shows the model
    /// smaller in the same view.
    var fieldOfView: CGFloat = 35
    #if os(macOS)
    /// A click that lands on no part of the model.
    var onEmptyClick: (() -> Void)? = nil
    #endif

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if canImport(UIKit)
    func makeUIView(context: Context) -> SCNView { makeView(context.coordinator) }
    func updateUIView(_ view: SCNView, context: Context) { update(view, context.coordinator) }
    #else
    func makeNSView(context: Context) -> SCNView { makeView(context.coordinator) }
    func updateNSView(_ view: SCNView, context: Context) { update(view, context.coordinator) }
    #endif

    private func update(_ view: SCNView, _ coordinator: Coordinator) {
        show(url, in: view, coordinator)
        view.isPlaying = isPlaying
        #if os(macOS)
        (view as? PinchableSCNView)?.onEmptyClick = onEmptyClick
        #endif
    }

    private func makeView(_ coordinator: Coordinator) -> SCNView {
        #if os(macOS)
        let view: SCNView = PinchableSCNView()
        #else
        let view = SCNView()
        #endif
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.delegate = coordinator
        update(view, coordinator)
        return view
    }

    private func show(_ url: URL, in view: SCNView, _ coordinator: Coordinator) {
        guard view.scene?.rootNode.name != url.path else { return }
        let scene = Self.scene(for: url)
        let camera = scene.rootNode.childNode(withName: "camera", recursively: false)
        camera?.camera?.fieldOfView = fieldOfView
        view.scene = scene
        view.pointOfView = camera
        view.defaultCameraController.target = SCNVector3Zero
        #if os(macOS)
        (view as? PinchableSCNView)?.rememberHome()
        #endif
        coordinator.watch(camera: camera, turntable: scene.rootNode.childNode(withName: "turntable", recursively: false),
                          headlight: scene.rootNode.childNode(withName: "headlight", recursively: false))
        // Uploads the textures and geometry and builds the shaders now,
        // rather than on the first frame it's seen.
        let onReady = onReady
        view.prepare([scene]) { _ in DispatchQueue.main.async { onReady?() } }
    }

    /// Keeps the light pointing along the view, and stops the turntable as
    /// soon as the viewer moves the camera.
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        private var camera: SCNNode?
        private var start = matrix_identity_float4x4
        private weak var turntable: SCNNode?
        private weak var headlight: SCNNode?
        /// From the camera's view direction: tipped down 20 degrees, so it comes from a little above.
        private let tilt = simd_quatf(angle: -0.35, axis: SIMD3(1, 0, 0))

        func watch(camera: SCNNode?, turntable: SCNNode?, headlight: SCNNode?) {
            self.camera = camera
            self.turntable = turntable
            self.headlight = headlight
            start = camera?.simdWorldTransform ?? matrix_identity_float4x4
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let pointOfView = renderer.pointOfView else { return }
            headlight?.simdWorldOrientation = pointOfView.simdWorldOrientation * tilt
            // Camera control either moves our camera or swaps in a free camera of its own.
            if let turntable, turntable.hasActions,
               pointOfView !== camera || pointOfView.simdWorldTransform != start {
                turntable.removeAllActions()
            }
        }
    }

    private static func scene(for url: URL) -> SCNScene {
        let scene = (try? SCNScene(url: url)) ?? SCNScene()
        scene.rootNode.name = url.path
        scene.background.contents = nil

        // Centre the model on the origin and scale its largest side to 2 units.
        let model = SCNNode()
        for child in Array(scene.rootNode.childNodes) {
            child.removeFromParentNode()
            model.addChildNode(child)
        }
        let (low, high) = model.boundingBox
        let lo = SIMD3<Float>(Float(low.x), Float(low.y), Float(low.z))
        let hi = SIMD3<Float>(Float(high.x), Float(high.y), Float(high.z))
        model.simdPosition = -(lo + hi) / 2
        let turntable = SCNNode()
        turntable.name = "turntable"
        turntable.addChildNode(model)
        turntable.simdScale = SIMD3(repeating: 2 / max((hi - lo).max(), 1e-6))
        turntable.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 8)))
        scene.rootNode.addChildNode(turntable)

        // Even light all round, plus a soft light that the Coordinator keeps
        // pointing along the view, so the lit side never swings round.
        scene.lightingEnvironment.contents = PlatformColor.white
        scene.lightingEnvironment.intensity = 1.2
        let headlight = SCNNode()
        headlight.name = "headlight"
        headlight.light = SCNLight()
        headlight.light?.type = .directional
        headlight.light?.intensity = 400
        scene.rootNode.addChildNode(headlight)

        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 35
        camera.simdPosition = SIMD3(0, 1.1, 4.2)
        camera.simdLook(at: .zero)
        scene.rootNode.addChildNode(camera)
        return scene
    }
}

#if os(macOS)
/// SpinningModel's view on the Mac, zooming the way a browser zooms a page:
/// a trackpad pinch zooms towards the pointer, so what's under it stays
/// under it, and a two-finger double tap zooms in on that spot or back out.
/// Dragging still turns the model, through SceneKit's camera control.
final class PinchableSCNView: SCNView {
    var onEmptyClick: (() -> Void)?
    /// The camera and its place as first shown, for zooming back out.
    private var home: (camera: SCNNode, transform: simd_float4x4)?
    /// How far in the pinches have zoomed, 1 when it's as first shown.
    private var magnification: Float = 1
    private var mouseDownAt: NSPoint?

    func rememberHome() {
        home = pointOfView.map { ($0, $0.simdTransform) }
        magnification = 1
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + Float(event.magnification), at: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        if magnification > 1.05 {
            zoomOut()
        } else {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            zoom(by: 2.5, at: convert(event.locationInWindow, from: nil))
            SCNTransaction.commit()
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { mouseDownAt = nil }
        // A click, not a drag to turn, on nothing but the clear background.
        guard let down = mouseDownAt,
              hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) < 4,
              hitTest(convert(event.locationInWindow, from: nil), options: nil).isEmpty else { return }
        onEmptyClick?()
    }

    /// Moves the camera along the line through `point` (in this view's
    /// coordinates), so the model grows by `factor` there. The point SceneKit
    /// turns the model round moves sideways with it, so turning afterwards
    /// carries on round what's being looked at.
    private func zoom(by factor: Float, at point: NSPoint) {
        guard factor > 0, let camera = pointOfView else { return }
        defaultCameraController.stopInertia()
        let near = unprojectPoint(SCNVector3(point.x, point.y, 0))
        let far = unprojectPoint(SCNVector3(point.x, point.y, 1))
        let ray = simd_normalize(SIMD3(Float(far.x - near.x), Float(far.y - near.y), Float(far.z - near.z)))
        let eye = camera.simdWorldPosition, front = camera.simdWorldFront
        let centre = defaultCameraController.target
        let target = SIMD3(Float(centre.x), Float(centre.y), Float(centre.z))
        // How far ahead the turning point is, before and after.
        let depth = simd_dot(target - eye, front), along = simd_dot(ray, front)
        guard depth > 1e-3, along > 1e-3 else { return }
        let newDepth = min(max(depth / factor, 0.4), 16)
        let step = ray * ((depth - newDepth) / along)
        camera.simdWorldPosition = eye + step
        defaultCameraController.target = SCNVector3(target + step - front * simd_dot(step, front))
        magnification *= depth / newDepth
    }

    /// Back to the camera as first shown.
    private func zoomOut() {
        guard let home else { return }
        defaultCameraController.stopInertia()
        pointOfView = home.camera
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        home.camera.simdTransform = home.transform
        SCNTransaction.commit()
        defaultCameraController.target = SCNVector3Zero
        magnification = 1
    }
}
#endif

#if canImport(UIKit)
typealias PlatformColor = UIColor
#else
typealias PlatformColor = NSColor
#endif
