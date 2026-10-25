import ARKit
import MetalKit
import SwiftUI

struct ExportedFile: Identifiable {
    let urls: [URL]
    let triangles: Int
    var id: URL { urls[0] }
}

/// UI-facing state for a scan; owns the Metal view and renderer.
final class ScanController: ObservableObject {
    @Published private(set) var stats = ReconstructionStats()
    /// False until the first tap on Start Scan; the camera runs but nothing is fused.
    @Published private(set) var hasStarted = false
    @Published private(set) var isScanning = false
    @Published private(set) var viewMode = MeshViewMode.color
    @Published private(set) var isExporting = false
    /// The scan as a 3D scene to look round, while the preview is open.
    @Published private(set) var preview: PreviewScene?
    @Published private(set) var isPreparingPreview = false
    /// Why frames aren't being fused right now, if tracking isn't normal.
    @Published private(set) var trackingHint: String?
    @Published var exportedFile: ExportedFile?
    @Published var errorMessage: String?

    let view = MTKView()
    private var renderer: ScanRenderer?
    /// Each scan gets a folder in Documents with its keyframes and exports.
    private var keyframes: KeyframeRecorder?
    private var isActive = true
    private static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        guard ScanRenderer.isSupported else {
            errorMessage = "This device has no LiDAR scanner. RoomTwin needs an iPhone 12 Pro or later Pro model, or an iPad Pro."
            return
        }
        do {
            let renderer = try ScanRenderer(view: view)
            renderer.onStats = { [weak self] in self?.stats = $0 }
            renderer.onTrackingHint = { [weak self] in self?.trackingHint = $0 }
            self.renderer = renderer
        } catch {
            errorMessage = "Could not set up Metal: \(error)"
        }
    }

    func start() {
        renderer?.start()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        renderer?.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Stops drawing while the app is inactive. A frame drawn while the phone
    /// locks or the app switcher opens can wait a full second for a drawable,
    /// blocking the main thread.
    func setActive(_ active: Bool) {
        isActive = active
        updateDrawing()
    }

    /// The live view also stops while the preview covers it.
    private func updateDrawing() {
        view.isPaused = !isActive || preview != nil
    }

    /// Reading the mesh pools while the GPU writes them would give a torn
    /// mesh, so scanning and reset wait for these.
    var isBusy: Bool {
        isExporting || isPreparingPreview
    }

    func startScanning() {
        hasStarted = true
        startRecording()
        setScanning(true)
        Diagnostics.action("start scan")
    }

    func toggleScanning() {
        setScanning(!isScanning)
        Diagnostics.action(isScanning ? "scan" : "pause")
    }

    /// The camera's latest frame, for Object mode's photo.
    var currentFrame: ARFrame? {
        renderer?.session.currentFrame
    }

    /// Object Capture and AR Quick Look need the camera to themselves. Unlike
    /// stop(), this keeps the screen awake.
    func setCameraPaused(_ paused: Bool) {
        if paused { renderer?.pause() } else { renderer?.start() }
    }

    /// Object mode uses the camera but not the room: fusion pauses and the mesh is hidden.
    func setObjectMode(_ on: Bool) {
        if on { setScanning(false) }
        renderer?.viewMode = on ? .hidden : viewMode
        Diagnostics.action(on ? "object mode" : "room mode")
    }

    func cycleViewMode() {
        let modes = MeshViewMode.allCases
        viewMode = modes[(modes.firstIndex(of: viewMode)! + 1) % modes.count]
        renderer?.viewMode = viewMode
        Diagnostics.action("view mode \(viewMode.label)")
    }

    /// Clears the scan and goes back to Start Scan, where either kind of scan can begin.
    func reset() {
        renderer?.reset()
        stats = ReconstructionStats()
        setScanning(false)
        keyframes?.discard()
        keyframes = nil
        renderer?.keyframes = nil
        hasStarted = false
        Diagnostics.action("reset")
    }

    func export() {
        guard let renderer, !isBusy else { return }
        Diagnostics.action("export")
        isExporting = true
        setScanning(false)
        let reconstructor = renderer.reconstructor
        let folder = keyframes?.folder ?? Self.documents
        renderer.whenGPUIdle { [weak self] in
            var stepStart = ProcessInfo.processInfo.systemUptime
            func step(_ name: String) {
                let now = ProcessInfo.processInfo.systemUptime
                Diagnostics.log(String(format: "export: %@ took %.0f ms", name, (now - stepStart) * 1000))
                stepStart = now
            }
            let mesh = reconstructor.snapshot()
            step("snapshot of \(mesh.faces.count) triangles")
            let base = folder.appendingPathComponent("RoomTwin-\(Self.timestamp())")
            let ply = base.appendingPathExtension("ply")
            let usdz = base.appendingPathExtension("usdz")
            let result = Result {
                try mesh.writePLY(to: ply)
                step("PLY")
                try mesh.writeUSDZ(to: usdz)
                step("USDZ")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExporting = false
                switch result {
                case .success:
                    Diagnostics.action("share sheet opening")
                    self.exportedFile = ExportedFile(urls: [usdz, ply], triangles: mesh.faces.count)
                case .failure(let error): self.errorMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Pauses scanning and opens the scan as a 3D scene. Scanning can resume
    /// after closing it.
    func openPreview() {
        guard let renderer, !isBusy else { return }
        Diagnostics.action("preview")
        isPreparingPreview = true
        setScanning(false)
        let reconstructor = renderer.reconstructor
        let viewer = renderer.session.currentFrame?.camera.transform
        renderer.whenGPUIdle { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            let mesh = reconstructor.snapshot()
            let preview = mesh.faces.isEmpty ? nil : PreviewScene(mesh: mesh, viewer: viewer)
            Diagnostics.log(String(format: "preview: %d triangles in %.0f ms", mesh.faces.count,
                                   (ProcessInfo.processInfo.systemUptime - start) * 1000))
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPreparingPreview = false
                guard let preview else {
                    self.errorMessage = "Nothing scanned yet. Scan for a few seconds first."
                    return
                }
                self.preview = preview
                self.updateDrawing()
            }
        }
    }

    func closePreview() {
        Diagnostics.action("close preview")
        preview = nil
        updateDrawing()
    }

    private func setScanning(_ scanning: Bool) {
        isScanning = scanning
        renderer?.isScanning = scanning
    }

    private func startRecording() {
        do {
            keyframes = try KeyframeRecorder(folder: Self.documents.appendingPathComponent("RoomTwin-\(Self.timestamp())"))
        } catch {
            keyframes = nil
            errorMessage = "Could not create the scan folder: \(error.localizedDescription)"
        }
        renderer?.keyframes = keyframes
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        // Without a fixed locale, a 12-hour time setting turns HH into "2 PM".
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
