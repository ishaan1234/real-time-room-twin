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
    }

    private func makeView(_ coordinator: Coordinator) -> SCNView {
        let view = SCNView()
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
        view.scene = scene
        view.pointOfView = camera
        view.defaultCameraController.target = SCNVector3Zero
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

#if canImport(UIKit)
typealias PlatformColor = UIColor
#else
typealias PlatformColor = NSColor
#endif
