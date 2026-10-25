import MetalKit
import QuickLook
import RealityKit
import SwiftUI

struct ContentView: View {
    @StateObject private var scan = ScanController()
    @StateObject private var objects = ObjectCapture()
    @StateObject private var walk = WalkAroundCapture()
    @StateObject private var sender = ModelSender()
    @StateObject private var roomPlan = RoomPlanScan()
    @State private var mode = Mode.room
    /// Asking which kind of room scan to start.
    @State private var choosingScan = false
    /// The model AR Quick Look is showing, if any.
    @State private var arModel: URL?
    @Environment(\.scenePhase) private var scenePhase

    private enum Mode {
        case room, photo, walkAround
    }

    var body: some View {
        ZStack {
            if mode == .walkAround, let session = walk.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
            } else if mode == .room, let captureView = roomPlan.captureView {
                RoomCaptureContainer(view: captureView)
                    .ignoresSafeArea()
            } else {
                MetalView(view: scan.view)
                    .ignoresSafeArea()
            }
            if (mode == .photo && objects.photo != nil) || (mode == .walkAround && walk.session == nil) {
                // Hides the live camera while a photo is up or a model is being built.
                Color.black.ignoresSafeArea()
            }
            VStack(spacing: 0) {
                modePicker
                switch mode {
                case .room where roomPlan.phase != .idle:
                    RoomPlanControls(scan: roomPlan)
                case .room:
                    roomControls
                case .photo:
                    ObjectModeView(capture: objects) {
                        scan.currentFrame.map(objects.capture)
                    }
                case .walkAround:
                    WalkAroundControls(capture: walk)
                }
            }
            reveal
            if let preview = scan.preview {
                ScanPreview(scene: preview, isExporting: scan.isExporting, onExport: scan.export,
                            onClose: scan.closePreview)
                    .transition(.opacity)
            } else if let preview = roomPlan.preview {
                ScanPreview(scene: preview, isExporting: roomPlan.isExporting, onExport: roomPlan.export,
                            onClose: roomPlan.closePreview)
                    .transition(.opacity)
            }
            if let message = scan.errorMessage {
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .onTapGesture { scan.errorMessage = nil }
            }
        }
        .onAppear {
            scan.start()
            sender.start()
        }
        .onDisappear { scan.stop() }
        .onChange(of: scenePhase) { _, phase in
            Diagnostics.log("scene phase: \(phase)")
            scan.setActive(phase == .active)
        }
        .onChange(of: mode) { old, new in
            scan.setObjectMode(new != .room)
            if new == .walkAround { walk.begin() } else if old == .walkAround { walk.end() }
        }
        .onChange(of: cameraPaused) { _, paused in
            scan.setCameraPaused(paused)
        }
        .quickLookPreview($arModel)
        .sheet(item: $scan.exportedFile) { file in
            ShareSheet(items: file.urls)
        }
        .background {
            // A second sheet on the same view wouldn't present, so RoomPlan's hangs here.
            Color.clear.sheet(item: $roomPlan.exportedFile) { file in
                ShareSheet(items: file.urls)
            }
        }
    }

    /// Object Capture, RoomPlan and AR Quick Look need the camera to
    /// themselves, and the preview doesn't need it.
    private var cameraPaused: Bool {
        mode == .walkAround || arModel != nil || scan.preview != nil
            || (mode == .room && roomPlan.captureView != nil) || roomPlan.preview != nil
    }

    /// A finished model popping out of its picture.
    @ViewBuilder
    private var reveal: some View {
        if mode == .photo, let model = objects.revealURL {
            ModelReveal(model: model, backdrop: objects.photo, origin: objects.tap ?? CGPoint(x: 0.5, y: 0.5),
                        sender: sender, onAR: { arModel = model }, onClose: { objects.revealURL = nil })
                .id(model)
                .transition(.opacity)
        } else if mode == .walkAround, let model = walk.revealURL {
            ModelReveal(model: model, backdrop: walk.backdrop, origin: CGPoint(x: 0.5, y: 0.5),
                        sender: sender, onAR: { arModel = model }, onClose: { walk.revealURL = nil })
                .id(model)
                .transition(.opacity)
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Room").tag(Mode.room)
            Text("Photo").tag(Mode.photo)
            Text("Walk Around").tag(Mode.walkAround)
        }
        .pickerStyle(.segmented)
        .frame(width: 300)
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .disabled(scan.isBusy || roomPlan.isBusy)
        .padding(.top, 8)
    }

    private var roomControls: some View {
        VStack {
            if scan.hasStarted {
                StatsBar(stats: scan.stats, isScanning: scan.isScanning)
            }
            Spacer()
            if let hint = scan.trackingHint {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
            if scan.hasStarted {
                controls
            } else {
                startButton
            }
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: scan.trackingHint)
        .animation(.easeInOut(duration: 0.25), value: scan.preview == nil)
    }

    private var startButton: some View {
        Button {
            if RoomPlanScan.isSupported { choosingScan = true } else { scan.startScanning() }
        } label: {
            Label("Start Scan", systemImage: "record.circle")
                .font(.headline)
                .padding(.horizontal, 28)
                .frame(height: 56)
        }
        .foregroundStyle(.white)
        .background(Color.red, in: Capsule())
        .confirmationDialog("What kind of scan?", isPresented: $choosingScan, titleVisibility: .visible) {
            Button("Detailed Mesh", action: scan.startScanning)
            Button("Room Layout (RoomPlan)", action: roomPlan.start)
        } message: {
            Text("Detailed Mesh captures every surface in colour. Room Layout finds the walls, doors, windows "
                 + "and furniture, and fills in furniture from your library.")
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ControlButton(title: "Reset", systemImage: "arrow.counterclockwise", action: scan.reset)
                .disabled(scan.isBusy)
            ControlButton(title: scan.viewMode.label, systemImage: scan.viewMode.systemImage, action: scan.cycleViewMode)
            ControlButton(title: scan.isScanning ? "Pause" : "Scan",
                          systemImage: scan.isScanning ? "pause.fill" : "record.circle",
                          prominent: true, action: scan.toggleScanning)
                .disabled(scan.isBusy)
            ControlButton(title: scan.isPreparingPreview ? "Loading" : "View", systemImage: "view.3d",
                          action: scan.openPreview)
                .disabled(scan.isBusy || scan.stats.triangles == 0)
            ControlButton(title: scan.isExporting ? "Saving" : "Export",
                          systemImage: "square.and.arrow.up", action: scan.export)
                .disabled(scan.isBusy)
        }
    }
}

private struct StatsBar: View {
    let stats: ReconstructionStats
    let isScanning: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text("\(compact(stats.triangles)) triangles · \(compact(stats.vertices)) vertices · \(compact(stats.blocks)) blocks")
            Text(isScanning ? String(format: "%.1f ms GPU per frame", stats.gpuMilliseconds) : "Paused")
                .foregroundStyle(.secondary)
            if stats.overflow != 0 {
                Text("Memory full: export or reset to keep scanning")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
            : n >= 1_000 ? String(format: "%.0fk", Double(n) / 1e3) : "\(n)"
    }
}

private struct ControlButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption)
            }
            .frame(width: 64, height: 52)
        }
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .background(prominent ? AnyShapeStyle(Color.red) : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MetalView: UIViewRepresentable {
    let view: MTKView
    func makeUIView(context: Context) -> MTKView { view }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, error in
            Diagnostics.action("share finished: \(activity?.rawValue ?? "dismissed"), completed \(completed)"
                               + (error.map { ", error \($0)" } ?? ""))
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
