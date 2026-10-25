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
    @StateObject private var hybrid = HybridScan()
    @State private var mode = Mode.room
    /// Asking which kind of room scan to start.
    @State private var choosingScan = false
    @State private var showingSavedRooms = false
    /// Which kind of object capture the Object tab opens on.
    @State private var objectMode = Mode.walkAround
    @State private var showingSavedObjects = false
    /// An object opened from My Objects, being shown.
    @State private var openedObject: OpenedObject?
    @EnvironmentObject private var account: Account
    /// The model AR Quick Look is showing, if any.
    @State private var arModel: URL?
    @Environment(\.scenePhase) private var scenePhase

    /// Room, or one of Object's two kinds of capture.
    private enum Mode {
        case room, photo, walkAround
    }

    private struct OpenedObject {
        let model: URL
        let picture: UIImage?
        let name: String
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
            if mode == .room, roomPlan.isCleanMode, roomPlan.phase == .capturing {
                CleanFurnitureStatusOverlay(indicators: roomPlan.cleanFurnitureIndicators)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if (mode == .photo && objects.photo != nil) || (mode == .walkAround && walk.session == nil) {
                // Hides the live camera while a photo is up or a model is being built.
                Color.black.ignoresSafeArea()
            }
            if mode == .room, hybrid.outputMode.usesManualFurnitureCapture,
               hybrid.phase == .processing || hybrid.phase == .failed {
                // The live detailed capture is not the final replacement
                // result. Keep it private until the selected room is complete.
                Color.black.ignoresSafeArea()
            }
            VStack(spacing: 0) {
                modePicker
                switch mode {
                case .room where roomPlan.phase != .idle:
                    RoomPlanControls(scan: roomPlan)
                case .room where hybrid.phase != .idle:
                    hybridControls
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
            // AR Edit's view is see-through, down to the camera.
            .opacity(scan.isARPreviewActive ? 0 : 1)
            reveal
            if scan.isPreviewOpen, let preview = scan.preview {
                ScanPreview(scene: preview, isExporting: scan.isExporting, onExport: scan.export,
                            onClose: scan.closePreview, arSession: scan.arSession,
                            onARModeChanged: scan.setARPreviewActive)
                    .transition(.opacity)
            } else if roomPlan.isPreviewOpen, let preview = roomPlan.preview {
                ScanPreview(scene: preview, isExporting: roomPlan.isExporting, onExport: roomPlan.export,
                            onClose: roomPlan.closePreview, arSession: nil,
                            onARModeChanged: { _ in }, handTracking: true)
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
            if new != .room { objectMode = new }
            scan.setObjectMode(new != .room)
            if old == .walkAround { walk.end() }
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
    /// themselves. A detailed-mesh preview keeps ARKit tracking quietly so
    /// AR Edit can retain the scan's exact world origin.
    private var cameraPaused: Bool {
        mode == .walkAround || arModel != nil
            || (mode == .room && roomPlan.captureView != nil) || roomPlan.isPreviewOpen
    }

    /// A finished model popping out of its picture.
    @ViewBuilder
    private var reveal: some View {
        if mode != .room, let opened = openedObject {
            ModelReveal(model: opened.model, backdrop: opened.picture, origin: CGPoint(x: 0.5, y: 0.5),
                        sender: sender, onAR: { arModel = opened.model }, onClose: { openedObject = nil },
                        savedName: opened.name)
                .id(opened.model)
                .transition(.opacity)
        } else if mode == .photo, let model = objects.revealURL {
            ModelReveal(model: model, backdrop: objects.photo, origin: objects.selectionOrigin,
                        sender: sender, onAR: { arModel = model }, onClose: { objects.revealURL = nil },
                        savedName: objects.libraryName)
                .id(model)
                .transition(.opacity)
        } else if mode == .walkAround, let model = walk.revealURL {
            ModelReveal(model: model, backdrop: walk.backdrop, origin: CGPoint(x: 0.5, y: 0.5),
                        sender: sender, onAR: { arModel = model }, onClose: { walk.revealURL = nil })
                .id(model)
                .transition(.opacity)
        }
    }

    /// Room or Object on top; under Object, Walk Around or Picture, and the
    /// objects already saved to the account.
    private var modePicker: some View {
        VStack(spacing: 6) {
            Picker("Mode", selection: Binding(get: { mode != .room }, set: { mode = $0 ? objectMode : .room })) {
                Text("Room").tag(false)
                Text("Object").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            if mode != .room {
                HStack(spacing: 8) {
                    Picker("Capture", selection: $mode) {
                        Text("Walk Around").tag(Mode.walkAround)
                        Text("Picture").tag(Mode.photo)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    Button("My Objects", systemImage: "shippingbox") { showingSavedObjects = true }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(.primary)
                }
                .controlSize(.small)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .disabled(scan.isBusy || roomPlan.isBusy || hybrid.isBusy)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: mode == .room)
        .sheet(isPresented: $showingSavedObjects) {
            SavedObjectsSheet { object, picture in
                let model = try await account.modelFile(for: object)
                openedObject = OpenedObject(model: model, picture: picture, name: object.name)
            }
        }
    }

    private var roomControls: some View {
        VStack {
            if scan.hasStarted {
                StatsBar(stats: scan.stats, isScanning: scan.isScanning,
                         isHybrid: scan.profile == .hybrid)
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
            if let stage = detailedStage { ProcessingProgress(stage: stage) }
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
        VStack(spacing: 12) {
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
                Button("Detailed Mesh") { scan.startScanning() }
                Button("Room Layout (RoomPlan)", action: roomPlan.start)
                Button("Hybrid · Clean RoomPlan + Scan Colours") {
                    hybrid.start(with: scan, account: account, outputMode: .semanticRoom)
                }
                Button("Clean · RoomPlan + SAM Replacements") {
                    roomPlan.startClean(account: account)
                }
                Button("SAM Furniture · Detailed Room + Detected Replacements") {
                    hybrid.start(with: scan, account: account, outputMode: .samFurnitureReplacement)
                }
            } message: {
                Text("Detailed Mesh captures every surface in colour. Room Layout finds the walls, doors, windows "
                     + "and furniture. Hybrid rebuilds RoomPlan with scan colours. Clean shows RoomPlan's full capture "
                     + "animation, runs no detailed mesh, and adds manual SAM replacements. SAM Furniture preserves detailed geometry.")
            }
            Button("Saved Rooms", systemImage: "icloud.and.arrow.down") { showingSavedRooms = true }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(.primary)
                .disabled(roomPlan.isBusy)
        }
        .sheet(isPresented: $showingSavedRooms) {
            SavedRoomsSheet { layout in
                try await roomPlan.open(layout, from: account)
            }
        }
    }

    /// What the detailed scanner is busy with after scanning, for the progress
    /// bar. Both take longer the more there is, so they're timed per hundred
    /// thousand triangles.
    private var detailedStage: ProcessingProgress.Stage? {
        let work = max(Double(scan.stats.triangles) / 100_000, 1)
        if scan.isPreparingPreview {
            return .init(title: "Building the 3D view", key: "preview", guess: 0.8, work: work)
        }
        if scan.isExporting {
            return .init(title: "Exporting", key: "export", guess: 1.2, work: work)
        }
        return nil
    }

    /// The rest of a Hybrid scan's processing, after RoomPlan's part.
    private var hybridStage: ProcessingProgress.Stage? {
        let work = max(Double(scan.stats.triangles) / 100_000, 1)
        if scan.isPreparingPreview {
            let title = hybrid.outputMode == .samFurnitureReplacement
                ? "Building the detailed room preview"
                : hybrid.outputMode == .clean
                    ? "Building the clean textured room"
                    : "Fitting objects and building the 3D view"
            return .init(title: title, key: "hybrid-preview",
                         range: 0.55...1, guess: 1, work: work)
        }
        if scan.isExporting {
            return .init(title: "Exporting", key: "export", guess: 1.2, work: work)
        }
        return nil
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

    private var hybridControls: some View {
        VStack(spacing: 10) {
            StatsBar(stats: scan.stats, isScanning: scan.isScanning, isHybrid: true)
            if let summary = hybrid.summary {
                Text(summary)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            if hybrid.outputMode.usesManualFurnitureCapture,
               let photos = scan.samFurniturePhotoSummary,
               hybrid.phase == .capturing {
                Label(photos, systemImage: "camera.viewfinder")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            Spacer()
            if let instruction = hybrid.instruction {
                Label(instruction, systemImage: "viewfinder")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            if let message = hybrid.errorMessage {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { hybrid.errorMessage = nil }
            }
            switch hybrid.phase {
            case .capturing:
                HStack(spacing: 8) {
                    ControlButton(title: "Cancel", systemImage: "xmark") { hybrid.close(with: scan) }
                    ControlButton(title: scan.viewMode.label, systemImage: scan.viewMode.systemImage,
                                  action: scan.cycleViewMode)
                    if hybrid.outputMode.usesManualFurnitureCapture {
                        SAMPhotoButton(enabled: scan.samFurnitureCanCapture && scan.isScanning) {
                            scan.captureSAMFurniturePhoto()
                        }
                    } else {
                        ControlButton(title: scan.isScanning ? "Mesh Pause" : "Mesh Scan",
                                      systemImage: scan.isScanning ? "pause.fill" : "record.circle",
                                      prominent: true, action: scan.toggleScanning)
                    }
                    ControlButton(title: "Finish", systemImage: "checkmark", prominent: true) {
                        hybrid.finish(with: scan)
                    }
                }
            case .processing:
                if let progress = hybrid.processingProgress {
                    DeterminateProcessingProgress(progress: progress)
                } else {
                    ProcessingProgress(stage: .init(title: "Finishing the room layout",
                                                    key: "hybrid-roomplan", range: 0...0.55, guess: 6))
                }
            case .done:
                if let stage = hybridStage {
                    ProcessingProgress(stage: stage)
                } else if let extracted = scan.hybridExtractionSummary {
                    VStack(spacing: 4) {
                        Text(extracted)
                    }
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                }
                HStack(spacing: 8) {
                    ControlButton(title: "New Scan", systemImage: "arrow.counterclockwise") {
                        hybrid.close(with: scan)
                    }
                    ControlButton(title: scan.isPreparingPreview ? "Loading" : "View", systemImage: "view.3d",
                                  action: scan.openPreview)
                        .disabled(scan.isBusy || scan.stats.triangles == 0)
                    ControlButton(title: scan.isExporting ? "Saving" : "Export",
                                  systemImage: "square.and.arrow.up", action: scan.export)
                        .disabled(scan.isBusy)
                }
            case .failed:
                VStack(spacing: 10) {
                    Text(hybrid.summary ?? "Replacement did not finish.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        ControlButton(title: "New Scan", systemImage: "arrow.counterclockwise") {
                            hybrid.close(with: scan)
                        }
                        ControlButton(title: "Retry", systemImage: "arrow.clockwise", prominent: true) {
                            hybrid.retry(with: scan)
                        }
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            case .idle:
                EmptyView()
            }
        }
        .padding()
    }
}

private struct SAMPhotoButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "camera.fill").font(.title3)
                Text("Photo").font(.caption)
            }
            .frame(width: 64, height: 52)
        }
        .foregroundStyle(enabled ? Color.black : Color.secondary)
        .background(enabled ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: 12))
        .disabled(!enabled)
    }
}

private struct StatsBar: View {
    let stats: ReconstructionStats
    let isScanning: Bool
    var isHybrid = false

    var body: some View {
        VStack(spacing: 4) {
            Text("\(compact(stats.triangles)) triangles · \(compact(stats.vertices)) vertices · \(compact(stats.blocks)) blocks")
            Text(isScanning ? String(format: "%.1f ms GPU per frame", stats.gpuMilliseconds) : "Paused")
                .foregroundStyle(.secondary)
            if isHybrid {
                Text(String(format: "%.0f FPS · %.0f fusion/s · %@ · %.0f MB",
                            stats.framesPerSecond, stats.integrationsPerSecond,
                            thermalLabel, stats.memoryMegabytes))
                    .foregroundStyle(stats.thermalState >= 2 ? .orange : .secondary)
            }
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

    private var thermalLabel: String {
        switch stats.thermalState {
        case 1: "thermal fair"
        case 2: "thermal serious"
        case 3: "thermal critical"
        default: "thermal nominal"
        }
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
