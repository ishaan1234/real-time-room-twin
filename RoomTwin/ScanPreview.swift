import SceneKit
import SwiftUI

/// Looking round the scan without exporting it. Orbit circles the room like
/// a dollhouse; Walk puts you inside at the phone's height, with a stick to
/// move and a drag anywhere else to look. Talk asks the voice agent to add
/// furniture (from Poly Haven or Sketchfab) or texture the walls; My Objects
/// adds something you scanned and saved to your account.
struct ScanPreview: View {
    let scene: PreviewScene
    let isExporting: Bool
    let onExport: () -> Void
    let onClose: () -> Void

    @State private var mode = PreviewScene.Mode.orbit
    @StateObject private var voice = VoiceAgent()
    @EnvironmentObject private var account: Account
    @State private var showingMyObjects = false
    /// Credits for added models whose licences need one (Sketchfab's CC BY).
    @State private var credits: [String] = []
    /// A short note about the last thing added from My Objects.
    @State private var notice: String?
    /// The look drag's translation at the last update, so each update turns by the change.
    @State private var lastLook = CGSize.zero

    var body: some View {
        ZStack {
            PreviewSceneView(scene: scene, mode: mode)
                .ignoresSafeArea()
            if mode == .walk {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(look)
                    .ignoresSafeArea()
            }
            VStack(spacing: 14) {
                Picker("View", selection: $mode) {
                    Text("Orbit").tag(PreviewScene.Mode.orbit)
                    Text("Walk").tag(PreviewScene.Mode.walk)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
                Spacer()
                if let message = notice {
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .onTapGesture { notice = nil }
                } else if let message = voice.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .onTapGesture { voice.errorMessage = nil }
                } else if voice.status != .off, let caption = voice.caption {
                    Text(caption)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .transition(.opacity)
                }
                if mode == .walk {
                    HStack {
                        Joystick { scene.move = $0 }
                        Spacer()
                    }
                }
                Text(mode == .orbit ? "Drag to turn · pinch to zoom · two fingers to pan"
                                    : "Stick to walk · drag anywhere else to look")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                // Poly Haven's terms ask for this wherever its content shows; CC BY asks for each credit.
                Text(([PolyHaven.credit] + credits.suffix(2)).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                HStack(spacing: 12) {
                    Button("Close", systemImage: "xmark", action: onClose)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                    talkButton
                    Button("My Objects", systemImage: "shippingbox") { showingMyObjects = true }
                        .buttonStyle(.bordered)
                    Button(isExporting ? "Saving" : "Export", systemImage: "square.and.arrow.up", action: onExport)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .disabled(isExporting)
                }
                .tint(.white)
            }
            .padding()
        }
        .onChange(of: mode) { _, _ in scene.move = .zero }
        .animation(.easeInOut(duration: 0.2), value: voice.caption)
        .onAppear { voice.perform = { try await perform($0, $1) } }
        .onDisappear { Task { await voice.stop() } }
        .sheet(isPresented: $showingMyObjects) {
            MyObjectsSheet { object in
                showingMyObjects = false
                Task { await add(object) }
            }
        }
    }

    /// Places a saved object where the view points.
    private func add(_ object: Account.SavedObject) async {
        notice = "Fetching \(object.name)…"
        do {
            let file = try await account.modelFile(for: object)
            let model = try await Task.detached { try ModelLoader.load(file) }.value
            model.name = object.name
            notice = "Added \(object.name) " + (try scene.place(model)) + "."
        } catch {
            notice = "Couldn't add \(object.name): \(error.localizedDescription)"
        }
    }


    private var talkButton: some View {
        let (title, image): (String, String) = switch voice.status {
        case .off: ("Talk", "mic")
        case .connecting: ("Connecting", "ellipsis")
        case .listening: ("Listening", "mic.fill")
        case .thinking: ("Thinking", "ellipsis")
        case .speaking: ("Speaking", "waveform")
        }
        return Button(title, systemImage: image, action: voice.toggle)
            .buttonStyle(.borderedProminent)
            .tint(voice.status == .off ? .white.opacity(0.25) : .red)
            .symbolEffect(.pulse, isActive: voice.status == .listening)
    }

    /// What the voice agent's tools do (see Voice/setup_agent.py).
    private func perform(_ tool: String, _ parameters: [String: Any]) async throws -> String {
        func text(_ key: String) -> String? {
            (parameters[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        switch tool {
        case "add_object":
            guard let query = text("query") else { throw VoiceAgent.Failure(message: "Say what to add.") }
            let reference = text("reference")
            let placement: PreviewScene.Placement = switch text("placement") {
            case "against_wall": .againstWall
            case "next_to": .nextTo(reference)
            case "on_top_of": .onTopOf(reference)
            default: .inView
            }
            let facing: PreviewScene.Facing? = switch text("facing") {
            case "user": .viewer
            case "away_from_wall": .awayFromWall
            case "toward_wall": .towardWall
            case "same_as_reference": .sameAsReference
            default: nil
            }
            let height = (parameters["height_m"] as? NSNumber)?.floatValue ?? 0.9
            let found = try await FurnitureSearch.find(query, height: height,
                                                       from: FurnitureSearch.Source(rawValue: text("source") ?? "") ?? .any)
            let (lo, hi) = found.model.boundingBox
            let place = try scene.place(found.model, placement, facing: facing)
            if let credit = found.credit { credits.append(credit) }
            return String(format: "Added “%@” from %@, %.1f m wide and %.1f m tall, %@.", found.model.name ?? query,
                          found.source, hi.x - lo.x, hi.y - lo.y, place)
        case "remove_object":
            guard let name = scene.removeFurniture(named: text("name")) else {
                throw VoiceAgent.Failure(message: scene.furnitureNames.isEmpty ? "Nothing has been added yet."
                                         : "Nothing added matches that. Added so far: \(scene.furnitureNames.joined(separator: ", ")).")
            }
            return "Removed “\(name)”."
        case "set_wall_texture":
            guard let query = text("query"), let asset = try await PolyHaven.wallTextures(matching: query).first else {
                throw VoiceAgent.Failure(message: "Couldn't find a wall texture like that.")
            }
            let texture = try await PolyHaven.wallTexture(asset)
            let count = try scene.setWallTexture(texture.image, size: texture.size, wallsInView: text("walls") == "in_view")
            return "Covered \(count == 1 ? "the wall" : "\(count) walls") with “\(asset.name)” from Poly Haven."
        case "reset_walls":
            try scene.setWallTexture(nil)
            return "The walls are back to their scanned look."
        default:
            throw VoiceAgent.Failure(message: "The app doesn't know \(tool).")
        }
    }

    private var look: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                scene.look(by: CGSize(width: value.translation.width - lastLook.width,
                                      height: value.translation.height - lastLook.height))
                lastLook = value.translation
            }
            .onEnded { _ in lastLook = .zero }
    }
}

/// An on-screen stick. Reports how far it's pushed, each axis -1...1 with +y up.
private struct Joystick: View {
    let onChange: (SIMD2<Float>) -> Void
    @State private var knob = CGSize.zero
    private let reach: CGFloat = 50

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 2 * reach + 40, height: 2 * reach + 40)
            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 52, height: 52)
                .offset(knob)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let t = value.translation
                    let scale = min(1, reach / max(hypot(t.width, t.height), 1e-3))
                    knob = CGSize(width: t.width * scale, height: t.height * scale)
                    onChange(SIMD2(Float(knob.width / reach), Float(-knob.height / reach)))
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { knob = .zero }
                    onChange(.zero)
                }
        )
    }
}

private struct PreviewSceneView: UIViewRepresentable {
    let scene: PreviewScene
    let mode: PreviewScene.Mode

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene.scene
        view.delegate = scene
        view.antialiasingMode = .multisampling4X
        // Keeps the render loop, and so walking, running when nothing else changes.
        view.isPlaying = true
        scene.show(mode, in: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        scene.show(mode, in: view)
    }
}
