import RoomPlan
import SceneKit
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
    @Published private(set) var isPreviewOpen = false
    @Published private(set) var isExporting = false
    @Published private(set) var isSavingToAccount = false
    @Published private(set) var isSavedToAccount = false
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

    var isBusy: Bool { phase == .capturing || phase == .processing || isExporting || isSavingToAccount || isPreparingPreview }

    func start() {
        Diagnostics.action("roomplan start")
        let view = RoomCaptureView(frame: .zero)
        delegate.onResult = { [weak self] room, error in self?.finished(room, error) }
        view.delegate = delegate
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        captureView = view
        room = nil
        mesh = nil
        preview = nil
        isPreviewOpen = false
        isSavedToAccount = false
        summary = nil
        isSavedToAccount = false
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
        isPreviewOpen = false
        room = nil
        mesh = nil
        summary = nil
        phase = .idle
    }

    func openPreview() {
        guard let mesh, !isBusy else { return }
        Diagnostics.action("roomplan preview")
        if preview != nil {
            isPreviewOpen = true
            return
        }
        isPreparingPreview = true
        let viewer = viewer
        Task {
            let preview = await Task.detached { PreviewScene(mesh: mesh, viewer: viewer) }.value
            isPreparingPreview = false
            self.preview = preview
            self.isPreviewOpen = true
        }
    }

    func closePreview() {
        isPreviewOpen = false
    }

    /// USDZ and PLY of the room as shown in the preview, and RoomPlan's JSON of
    /// every wall, door, window and object with its category, size and pose.
    func export() {
        guard let room, let mesh, !isExporting else { return }
        Diagnostics.action("roomplan export")
        isExporting = true
        let edits = preview?.exportContents()
        Task {
            let result = await Task.detached { Result { try Self.write(room, mesh, edits) } }.value
            isExporting = false
            switch result {
            case .success(let urls): exportedFile = ExportedFile(urls: urls, triangles: mesh.faces.count)
            case .failure(let error): errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Saves the same edited room shown in Orbit/Walk to the signed-in user's
    /// private Supabase storage and records it in `room_layouts`.
    func saveToAccount(_ account: Account) {
        guard let room, let mesh, !isBusy, !isSavedToAccount else { return }
        Diagnostics.action("roomplan cloud save")
        isSavingToAccount = true
        let edits = preview?.exportContents()
        Task {
            do {
                let urls = try await Task.detached { try Self.write(room, mesh, edits) }.value
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                try await account.saveRoomLayout(model: urls[0], ply: urls[1], json: urls[2],
                                                 name: "Room \(formatter.string(from: Date()))")
                isSavedToAccount = true
            } catch {
                errorMessage = "Couldn't save the room: \(error.localizedDescription)"
            }
            isSavingToAccount = false
        }
    }

    /// Opens a room saved to the account in the preview. RoomPlan's JSON
    /// rebuilds the room as scanned, every piece editable, and the furniture
    /// goes back as it was saved (see PreviewScene.restoreFurniture).
    /// Exporting or saving it again works as for a new scan.
    func open(_ layout: Account.SavedRoomLayout, from account: Account) async throws {
        guard !isBusy else { return }
        Diagnostics.action("roomplan open saved")
        isPreparingPreview = true
        defer { isPreparingPreview = false }
        let files = try await account.roomFiles(for: layout)
        let kinds = FurnitureLibrary.kinds
        let (room, mesh, preview) = try await Task.detached {
            let room = try JSONDecoder().decode(CapturedRoom.self, from: Data(contentsOf: files.json))
            let library = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in
                FurnitureLibrary.mesh(kind).map { (kind, $0) }
            })
            let mesh = RoomPlanMesh.build(room, library: library)
            let preview = PreviewScene(mesh: mesh, viewer: nil)
            if let saved = try? SCNScene(url: files.model) { preview.restoreFurniture(from: saved) }
            return (room, mesh, preview)
        }.value
        close()
        self.room = room
        self.mesh = mesh
        self.preview = preview
        summary = Self.describe(room)
        isSavedToAccount = false
        phase = .done
        isPreviewOpen = true
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

    private nonisolated static func write(_ room: CapturedRoom, _ mesh: MeshSnapshot,
                                          _ edits: PreviewScene.ExportContents?) throws -> [URL] {
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
        var exportMesh = edits?.scan ?? mesh
        if let edits {
            exportMesh.faces = exportMesh.faces.enumerated().compactMap {
                edits.replacedScanFaces.contains($0.offset) ? nil : $0.element
            }
        }
        try exportMesh.writeUSDZ(to: usdz, adding: edits?.nodes ?? [])
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
    @EnvironmentObject private var account: Account

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
                VStack(spacing: 10) {
                    Button(scan.isSavedToAccount ? "Saved to Account" : scan.isSavingToAccount ? "Saving to Account" : "Save to Account",
                           systemImage: scan.isSavedToAccount ? "checkmark.icloud.fill" : "icloud.and.arrow.up") {
                        scan.saveToAccount(account)
                    }
                    .buttonStyle(.borderedProminent)
                    // White like the rest, so its label needs to be dark to show.
                    .foregroundStyle(.black)
                    .disabled(scan.isBusy || scan.isSavedToAccount)
                    HStack(spacing: 12) {
                        Button("New Scan", systemImage: "arrow.counterclockwise", action: scan.close)
                            .disabled(scan.isBusy)
                        Button(scan.isPreparingPreview ? "Loading" : "View", systemImage: "view.3d", action: scan.openPreview)
                            .disabled(scan.isBusy)
                        Button(scan.isExporting ? "Saving" : "Export", systemImage: "square.and.arrow.up", action: scan.export)
                            .disabled(scan.isBusy)
                    }
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
