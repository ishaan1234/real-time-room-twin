import RoomPlan
import SwiftUI

/// Room layout scanning with Apple's RoomPlan, the alternative to the
/// detailed mesh: walls, doors, windows and labelled furniture. The finished
/// room becomes a mesh (RoomPlanMesh) so it opens in the same preview and
/// exports the same way, plus RoomPlan's own JSON. Exports go to
/// Documents/RoomPlan-<time>/.
@MainActor
final class RoomPlanScan: ObservableObject {
    enum Phase: Equatable {
        case idle, capturing, processing, done
    }

    @Published private(set) var phase = Phase.idle
    /// Apple's live view, while a scan is open.
    @Published private(set) var captureView: RoomCaptureView?
    @Published private(set) var preview: PreviewScene?
    @Published private(set) var isExporting = false
    @Published private(set) var isPreparingPreview = false
    @Published var exportedFile: ExportedFile?
    @Published var errorMessage: String?
    /// What RoomPlan found, e.g. "4 walls · 2 doors · 1 window · 5 objects".
    @Published private(set) var summary: String?

    private var room: CapturedRoom?
    private var mesh: MeshSnapshot?
    private var viewer: simd_float4x4?
    private let delegate = CaptureDelegate()

    static var isSupported: Bool { RoomCaptureSession.isSupported }

    var isBusy: Bool { phase == .capturing || phase == .processing || isExporting || isPreparingPreview }

    func start() {
        Diagnostics.action("roomplan start")
        let view = RoomCaptureView(frame: .zero)
        delegate.onResult = { [weak self] room, error in self?.finished(room, error) }
        view.delegate = delegate
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        captureView = view
        room = nil
        mesh = nil
        summary = nil
        phase = .capturing
    }

    /// Ends the scan; RoomPlan then builds the room and shows it in its view.
    func finish() {
        guard phase == .capturing, let captureView else { return }
        Diagnostics.action("roomplan finish")
        viewer = captureView.captureSession.arSession.currentFrame?.camera.transform
        captureView.captureSession.stop()
        phase = .processing
    }

    /// Drops the scan and goes back to Start Scan.
    func close() {
        if phase == .capturing { captureView?.captureSession.stop() }
        captureView = nil
        preview = nil
        room = nil
        mesh = nil
        summary = nil
        phase = .idle
    }

    func openPreview() {
        guard let mesh, !isBusy else { return }
        Diagnostics.action("roomplan preview")
        isPreparingPreview = true
        let viewer = viewer
        Task {
            let preview = await Task.detached { PreviewScene(mesh: mesh, viewer: viewer) }.value
            isPreparingPreview = false
            self.preview = preview
        }
    }

    func closePreview() {
        preview = nil
    }

    /// USDZ and PLY of the room as shown in the preview, and RoomPlan's JSON of
    /// every wall, door, window and object with its category, size and pose.
    func export() {
        guard let room, let mesh, !isExporting else { return }
        Diagnostics.action("roomplan export")
        isExporting = true
        Task {
            let result = await Task.detached { Result { try Self.write(room, mesh) } }.value
            isExporting = false
            switch result {
            case .success(let urls): exportedFile = ExportedFile(urls: urls, triangles: mesh.faces.count)
            case .failure(let error): errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func finished(_ room: CapturedRoom?, _ error: Error?) {
        guard let room else {
            errorMessage = "RoomPlan couldn't build the room: \(error?.localizedDescription ?? "unknown error")"
            phase = .capturing
            return
        }
        self.room = room
        summary = Self.describe(room)
        let kinds = FurnitureLibrary.kinds
        Task {
            let mesh = await Task.detached {
                let library = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in
                    FurnitureLibrary.mesh(kind).map { (kind, $0) }
                })
                return RoomPlanMesh.build(room, library: library)
            }.value
            Diagnostics.log("roomplan: \(self.summary ?? ""), \(mesh.faces.count) triangles")
            self.mesh = mesh
            phase = .done
        }
    }

    private nonisolated static func write(_ room: CapturedRoom, _ mesh: MeshSnapshot) throws -> [URL] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "RoomPlan-\(formatter.string(from: Date()))"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = folder.appendingPathComponent(name)
        let usdz = base.appendingPathExtension("usdz"), ply = base.appendingPathExtension("ply")
        let json = base.appendingPathExtension("json")
        try mesh.writePLY(to: ply)
        try mesh.writeUSDZ(to: usdz)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(room).write(to: json)
        return [usdz, ply, json]
    }

    private static func describe(_ room: CapturedRoom) -> String {
        func count(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return [count(room.walls.count, "wall"), count(room.doors.count, "door"), count(room.windows.count, "window"),
                count(room.objects.count, "object")].compactMap { $0 }.joined(separator: " · ")
    }
}

/// RoomPlan's view delegate has to be NSCoding; nothing here is ever archived.
@objc(RoomTwinCaptureDelegate)
private final class CaptureDelegate: NSObject, RoomCaptureViewDelegate {
    var onResult: ((CapturedRoom?, Error?) -> Void)?

    override init() { super.init() }
    required init?(coder: NSCoder) { return nil }
    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        onResult?(error == nil ? processedResult : nil, error)
    }
}

/// Shows RoomPlan's own live view.
struct RoomCaptureContainer: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ view: RoomCaptureView, context: Context) {}
}

/// Our buttons over RoomPlan's view, for each step of a room layout scan.
struct RoomPlanControls: View {
    @ObservedObject var scan: RoomPlanScan

    var body: some View {
        VStack(spacing: 12) {
            if let summary = scan.summary {
                Text(summary).capsule()
            }
            Spacer()
            if let message = scan.errorMessage {
                Text(message)
                    .capsule()
                    .onTapGesture { scan.errorMessage = nil }
            }
            switch scan.phase {
            case .capturing:
                HStack(spacing: 12) {
                    Button("Cancel", systemImage: "xmark", action: scan.close)
                        .buttonStyle(.bordered)
                    Button("Done", systemImage: "checkmark", action: scan.finish)
                        .buttonStyle(.borderedProminent)
                }
                .tint(.white)
                .foregroundStyle(.black)
            case .processing:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Building the room")
                }
                .capsule()
            case .done:
                HStack(spacing: 12) {
                    Button("New Scan", systemImage: "arrow.counterclockwise", action: scan.close)
                        .disabled(scan.isBusy)
                    Button(scan.isPreparingPreview ? "Loading" : "View", systemImage: "view.3d", action: scan.openPreview)
                        .disabled(scan.isBusy)
                    Button(scan.isExporting ? "Saving" : "Export", systemImage: "square.and.arrow.up", action: scan.export)
                        .disabled(scan.isBusy)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            case .idle:
                EmptyView()
            }
        }
        .padding()
    }
}

private extension View {
    func capsule() -> some View {
        font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
    }
}
