import ARKit
import SceneKit
import SwiftUI

/// Looking round the scan without exporting it. Orbit circles the room like
/// a dollhouse; Walk puts you inside at the phone's height, with a stick to
/// move and a drag anywhere else to look, and for a room layout a hand held
/// up behind the phone to pick things up and move them. AR Edit (detailed
/// scans) shows the furniture over the camera. Talk asks the voice agent to add
/// furniture (from Poly Haven or Sketchfab) or texture the walls; My Objects
/// adds something you scanned and saved to your account.
struct ScanPreview: View {
    let scene: PreviewScene
    let isExporting: Bool
    let onExport: () -> Void
    let onClose: () -> Void
    /// Present only for detailed-mesh scans, whose AR world coordinates match
    /// this PreviewScene. RoomPlan keeps Orbit/Walk until a shared world map is
    /// available.
    let arSession: ARSession?
    let onARModeChanged: (Bool) -> Void
    /// Walk takes a hand held up behind the phone (room layouts, whose scan
    /// has finished with the camera).
    var handTracking = false

    @State private var mode = PreviewScene.Mode.orbit
    @StateObject private var voice = VoiceAgent()
    @StateObject private var hand = HandInteractionController()
    @State private var arCamera = ARCameraFollower()
    @EnvironmentObject private var account: Account
    @State private var showingMyObjects = false
    @State private var draggedLibraryObject: ObjectLibrarySelection?
    @State private var libraryDragPoint = CGPoint.zero
    @State private var showingHistory = false
    /// Credits for added models whose licences need one (Sketchfab's CC BY).
    @State private var credits: [String] = []
    /// A short note about the last thing added from My Objects.
    @State private var notice: String?
    /// The RoomPlan or added object tapped in the scene.
    @State private var selection: String?
    @State private var editRevision = 0
    /// The look drag's translation at the last update, so each update turns by the change.
    @State private var lastLook = CGSize.zero
    /// Whether the walk drag under way moves a gizmo handle; nil until it's begun.
    @State private var isDraggingGizmo: Bool?
    @State private var gizmoMode = PreviewScene.GizmoMode.move

    var body: some View {
        ZStack {
            PreviewSceneView(scene: scene, mode: mode)
                .simultaneousGesture(selectTap)
                .ignoresSafeArea()
            if mode == .walk {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(look)
                    .simultaneousGesture(selectTap)
                    .ignoresSafeArea()
            }
            if mode == .walk, hand.isEnabled {
                // Both full screen like the SceneKit view, so the hand, its
                // cursor and the room share one frame.
                HandMatteView(session: hand.camera.session)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                HandCursor(point: hand.cursor, isPinching: hand.isPinching, isTargeting: hand.targetedObject != nil)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
            VStack(spacing: 14) {
                Picker("View", selection: $mode) {
                    Text("Orbit").tag(PreviewScene.Mode.orbit)
                    Text("Walk").tag(PreviewScene.Mode.walk)
                    if arSession != nil { Text("AR Edit").tag(PreviewScene.Mode.ar) }
                }
                .pickerStyle(.segmented)
                .frame(width: arSession == nil ? 200 : 290)
                .padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
                if mode == .walk, handTracking { handControls }
                Spacer()
                if let message = hand.feedback {
                    Text(message)
                        .font(.footnote.bold())
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                } else if let message = notice {
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
                } else if voice.status != .off {
                    subtitles
                }
                if mode == .walk {
                    HStack {
                        Joystick { scene.move = $0 }
                        Spacer()
                    }
                }
                if selection != nil { objectEditor }
                Text(modeHint)
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
                    Button("History", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                        .buttonStyle(.bordered)
                    Button("Add", systemImage: "plus.square.on.square") { showingMyObjects = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                    Button(isExporting ? "Saving" : "Export", systemImage: "square.and.arrow.up", action: onExport)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .disabled(isExporting)
                }
                .tint(.white)
            }
            .padding()
            if showingMyObjects {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        Spacer()
                        MyObjectsSheet(
                            onPick: { selection in add(selection) },
                            onDragChanged: { selection, point in
                                draggedLibraryObject = selection
                                libraryDragPoint = point
                            },
                            onDragEnded: { selection, point in
                                libraryDragPoint = point
                                add(selection, at: point)
                            },
                            onClose: { showingMyObjects = false }
                        )
                        .frame(height: min(proxy.size.height * 0.58, 540))
                        // Keep the gesture source alive, but move the panel out
                        // of the way so the scene becomes the drop target.
                        .offset(y: draggedLibraryObject == nil ? 0 : proxy.size.height)
                    }
                }
                .transition(.move(edge: .bottom))
                .zIndex(3)
            }
            if let draggedLibraryObject {
                Label(draggedLibraryObject.name, systemImage: "cube.fill")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 1))
                    .position(libraryDragPoint)
                    .allowsHitTesting(false)
                    .zIndex(4)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showingMyObjects)
        .animation(.easeInOut(duration: 0.18), value: draggedLibraryObject != nil)
        .onChange(of: mode) { _, newMode in
            scene.move = .zero
            onARModeChanged(newMode == .ar)
            arCamera.follow(newMode == .ar ? arSession : nil, in: scene)
            hand.setAvailable(handTracking && newMode == .walk)
        }
        // The gizmo shows on the piece the editor is for.
        .onChange(of: selection) { _, selected in scene.showsGizmo = selected != nil }
        .onChange(of: gizmoMode) { _, tool in scene.gizmoMode = tool }
        .animation(.easeInOut(duration: 0.2), value: voice.caption)
        .animation(.easeInOut(duration: 0.2), value: voice.heard)
        .onAppear {
            voice.perform = { try await perform($0, $1) }
            voice.describeRoom = {
                let names = scene.furnitureNames
                return names.isEmpty ? "The room has no editable objects right now."
                    : "Editable objects in the room right now: \(names.suffix(40).joined(separator: ", "))."
            }
            hand.configure(scene: scene)
            hand.onSelection = { name in
                if hand.isGrabbing || name == nil { selection = name }
            }
            hand.onEditCommitted = { editRevision += 1 }
        }
        .onDisappear {
            onARModeChanged(false)
            arCamera.stop()
            hand.stop()
            scene.clearSelection()
            Task { await voice.stop() }
        }
        .sheet(isPresented: $showingHistory) {
            ConversationHistorySheet(entries: voice.transcript,
                                     exportURL: voice.transcriptExportURL,
                                     onClear: voice.clearTranscript)
        }
    }

    private var modeHint: String {
        switch mode {
        case .orbit: "Drag to turn · pinch to zoom · two fingers to pan"
        case .walk where hand.isEnabled:
            switch hand.tracking {
            case .off, .searching: "Hold your free hand up behind the phone, in the back camera's view"
            case .found: "Point at an object · pinch to grab"
            case .holding: "Move your hand · open your fingers to drop"
            }
        case .walk: "Tap an object to edit · stick to walk · drag to look"
        case .ar: "Tap an object to edit · move the phone to look round"
        }
    }

    private var trackingColor: Color {
        switch hand.tracking {
        case .off: .gray
        case .searching: .orange
        case .found: .green
        case .holding: .mint
        }
    }

    /// A small pill: the hand switch, and while it's on, how tracking is
    /// going and undo/redo for hand moves.
    private var handControls: some View {
        HStack(spacing: 6) {
            Button(hand.isEnabled ? "Hand tracking on" : "Hand tracking off",
                   systemImage: hand.isEnabled ? "hand.raised.fill" : "hand.raised",
                   action: hand.toggle)
                .buttonStyle(.borderedProminent)
                .tint(hand.isEnabled ? .green : .white.opacity(0.25))
            if hand.isEnabled {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(trackingColor)
                    .symbolEffect(.pulse, isActive: hand.tracking == .searching)
                Text(hand.status)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.trailing, 2)
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    if let name = scene.undoLastEdit() {
                        selection = name
                        notice = "Undid hand move."
                        editRevision += 1
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!scene.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") {
                    if let name = scene.redoLastEdit() {
                        selection = name
                        notice = "Redid hand move."
                        editRevision += 1
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!scene.canRedo)
            }
        }
        .labelStyle(.iconOnly)
        .controlSize(.mini)
        .tint(.white)
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .id(editRevision)
    }

    /// Film-style subtitles that leave the room visible: the user's words
    /// faint on one line, the agent's answer small on a light scrim. Taps
    /// pass through to the scene.
    private var subtitles: some View {
        VStack(spacing: 4) {
            if let heard = voice.heard {
                Text(heard)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let caption = voice.caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Picks which gizmo the selected piece shows: drag its red (x), green
    /// (y) or blue (z) handle in the scene to move, turn or tilt, or stretch it.
    private var objectEditor: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(selection ?? "Object").font(.caption.bold()).lineLimit(1)
                Spacer()
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    if let name = scene.undoLastEdit() { selection = name }
                }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    if let removed = scene.removeFurniture(named: selection) {
                        notice = "Removed \(removed)."
                        selection = nil
                    }
                }
                Button("Done", systemImage: "checkmark") {
                    scene.clearSelection()
                    selection = nil
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            Picker("Tool", selection: $gizmoMode) {
                Text("Move").tag(PreviewScene.GizmoMode.move)
                Text("Rotate").tag(PreviewScene.GizmoMode.rotate)
                Text("Scale").tag(PreviewScene.GizmoMode.scale)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                axisKey("X", .red)
                axisKey("Y", .green)
                axisKey("Z", .blue)
                Text(gizmoMode == .scale ? "· middle cube scales evenly" : "· drag a handle")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func axisKey(_ name: String, _ colour: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(name).bold()
        }
    }

    private func add(_ selection: ObjectLibrarySelection, at point: CGPoint? = nil) {
        showingMyObjects = false
        draggedLibraryObject = nil
        Task {
            switch selection {
            case .saved(let object): await add(object, at: point)
            case .sketchfab(let model): await add(model, at: point)
            }
        }
    }

    /// Places a saved object where the user taps or drops it.
    private func add(_ object: Account.SavedObject, at point: CGPoint?) async {
        notice = "Fetching \(object.name)…"
        do {
            let file = try await account.modelFile(for: object)
            let model = try await Task.detached { try ModelLoader.load(file) }.value
            model.name = object.name
            let place = try point.map { try scene.place(model, at: $0) } ?? scene.place(model)
            notice = "Added \(object.name) \(place)."
        } catch {
            notice = "Couldn't add \(object.name): \(error.localizedDescription)"
        }
    }

    /// Sketchfab files don't consistently declare real units. Start at a
    /// furniture-sized one metre; the existing free scale controls can adjust
    /// it immediately after placement.
    private func add(_ object: Sketchfab.Model, at point: CGPoint?) async {
        notice = "Fetching \(object.name)…"
        do {
            let model = try await Sketchfab.model(object, height: 1)
            let place = try point.map { try scene.place(model, at: $0) } ?? scene.place(model)
            if !credits.contains(object.attribution) { credits.append(object.attribution) }
            notice = "Added \(object.name) \(place)."
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
        func number(_ key: String) -> Float? { (parameters[key] as? NSNumber)?.floatValue }
        func boolean(_ key: String) -> Bool? { (parameters[key] as? NSNumber)?.boolValue }
        func requestedPlacement() -> PreviewScene.Placement {
            let reference = text("reference")
            return switch text("placement") {
            case "against_wall": .againstWall
            case "next_to": .nextTo(reference)
            case "on_top_of": .onTopOf(reference)
            case "on_wall": .onWall
            case "ceiling": .ceiling
            default: .inView
            }
        }
        switch tool {
        case "add_object":
            guard let query = text("query") else { throw VoiceAgent.Failure(message: "Say what to add.") }
            let placement = requestedPlacement()
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
            let place = try scene.place(found.model, placement, facing: facing,
                                        elevation: number("elevation_m"))
            if let credit = found.credit { credits.append(credit) }
            return String(format: "Added “%@” from %@, %.1f m wide and %.1f m tall, %@.", found.model.name ?? query,
                          found.source, hi.x - lo.x, hi.y - lo.y, place)
        case "place_saved_object":
            guard let requestedName = text("name") else {
                throw VoiceAgent.Failure(message: "Say which saved object to place.")
            }
            let saved = try await account.objects()
            guard let object = bestSavedObject(named: requestedName, in: saved) else {
                let available = saved.prefix(20).map(\.name).joined(separator: ", ")
                throw VoiceAgent.Failure(message: available.isEmpty
                                         ? "No saved objects were found. Scan or import it into My Objects first."
                                         : "No saved object matches \(requestedName). Available: \(available).")
            }
            let file = try await account.modelFile(for: object)
            let model = try await Task.detached { try ModelLoader.load(file) }.value
            model.name = object.name
            let place = try scene.place(model, requestedPlacement())
            return "Placed your saved “\(object.name)” \(place)."
        case "remove_object":
            guard let name = scene.removeFurniture(named: text("name")) else {
                throw VoiceAgent.Failure(message: scene.furnitureNames.isEmpty ? "No editable objects were found."
                                         : "Nothing matches that. Editable objects: \(scene.furnitureNames.joined(separator: ", ")).")
            }
            return "Removed “\(name)”."
        case "move_object":
            let name = try scene.moveFurniture(named: text("name"), direction: text("direction") ?? "forward",
                                                distance: number("distance_m") ?? 0.3)
            return "Moved “\(name)” \(text("direction") ?? "forward")."
        case "replace_object":
            guard let query = text("query") else { throw VoiceAgent.Failure(message: "Say what to replace it with.") }
            let height = number("height_m") ?? 0.9
            let found = try await FurnitureSearch.find(query, height: height,
                                                       from: FurnitureSearch.Source(rawValue: text("source") ?? "") ?? .any)
            let name = try scene.replaceFurniture(named: text("name"), with: found.model)
            if let credit = found.credit { credits.append(credit) }
            return "Replaced it with “\(name)” from \(found.source)."
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
        case "set_floor_texture":
            guard let query = text("query"), let asset = try await PolyHaven.surfaceTextures(matching: query).first else {
                throw VoiceAgent.Failure(message: "Couldn't find a floor material like that.")
            }
            let texture = try await PolyHaven.wallTexture(asset)
            try scene.setGroundTexture(texture.image, size: texture.size)
            return "Covered the floor with “\(asset.name)” from Poly Haven."
        case "reset_floor":
            try scene.setGroundTexture(nil)
            return "The floor is back to its scanned look."
        case "set_object_texture":
            guard let query = text("query"), let asset = try await PolyHaven.surfaceTextures(matching: query).first else {
                throw VoiceAgent.Failure(message: "Couldn't find an object material like that.")
            }
            let texture = try await PolyHaven.wallTexture(asset)
            let name = try scene.setFurnitureTexture(texture.image, named: text("name"))
            return "Covered “\(name)” with “\(asset.name)” from Poly Haven."
        case "resize_object":
            guard let height = number("height_m") else {
                throw VoiceAgent.Failure(message: "Say how tall the object should be.")
            }
            let name = try scene.resizeFurniture(named: text("name"), height: height)
            return String(format: "Resized “%@” to %.2f metres tall.", name, height)
        case "set_lighting":
            scene.setLighting(brightness: number("brightness") ?? 0.65, warmth: number("warmth") ?? 0.5)
            return "Updated the room lighting."
        case "set_enclosure":
            return scene.setEnclosure(ceiling: boolean("ceiling"), openWalls: boolean("open_walls"))
        default:
            throw VoiceAgent.Failure(message: "The app doesn't know \(tool).")
        }
    }

    /// Matches natural names such as “my Hoka shoes” to a user-owned object
    /// without sending the private object list to an external model.
    private func bestSavedObject(named request: String, in objects: [Account.SavedObject]) -> Account.SavedObject? {
        func normalized(_ value: String) -> String {
            value.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && !["my", "saved", "imported", "object"].contains($0) }
                .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
                .joined(separator: " ")
        }
        let wanted = normalized(request)
        guard !wanted.isEmpty else { return objects.first }
        if let exact = objects.first(where: { normalized($0.name) == wanted }) { return exact }
        if let contained = objects.first(where: {
            let name = normalized($0.name)
            return name.contains(wanted) || wanted.contains(name)
        }) { return contained }
        let wantedWords = Set(wanted.split(separator: " ").map(String.init))
        return objects.map { object -> (Account.SavedObject, Int) in
            let words = Set(normalized(object.name).split(separator: " ").map(String.init))
            return (object, words.intersection(wantedWords).count)
        }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    private var selectTap: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                selection = scene.selectFurniture(at: value.location)
            }
    }

    /// Turns the walking view, unless the drag starts on a gizmo handle.
    private var look: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if isDraggingGizmo == nil { isDraggingGizmo = scene.beginGizmoDrag(at: value.startLocation) }
                if isDraggingGizmo == true {
                    scene.updateGizmoDrag(to: value.location)
                    return
                }
                scene.look(by: CGSize(width: value.translation.width - lastLook.width,
                                      height: value.translation.height - lastLook.height))
                lastLook = value.translation
            }
            .onEnded { _ in
                if isDraggingGizmo == true { scene.endGizmoDrag() }
                isDraggingGizmo = nil
                lastLook = .zero
            }
    }
}

/// A readable view of the free, on-device voice transcript. Export shares the
/// same structured JSON the app persists, ready to use as an improvement/eval
/// dataset without another network service or credit charge.
private struct ConversationHistorySheet: View {
    let entries: [VoiceAgent.TranscriptEntry]
    let exportURL: URL?
    let onClear: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("No Conversation Yet", systemImage: "text.bubble",
                                           description: Text("What you say and what RoomTwin answers will appear here."))
                } else {
                    List(entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.speaker == .user ? "You" : "RoomTwin")
                                    .font(.caption.bold())
                                Spacer()
                                Text(entry.date, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.text)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Clear", systemImage: "trash", role: .destructive, action: onClear)
                        .disabled(entries.isEmpty)
                }
            }
        }
    }
}

/// A ring between the hand's thumb and index, where it points. Green while
/// pinching, its edge orange when it's over something to grab.
private struct HandCursor: View {
    let point: CGPoint?
    let isPinching: Bool
    let isTargeting: Bool

    var body: some View {
        Canvas { context, _ in
            let colour = isPinching ? Color.green : .white
            if let cursor = point {
                let radius: CGFloat = isPinching ? 16 : 12
                let ring = Path(ellipseIn: CGRect(x: cursor.x - radius, y: cursor.y - radius,
                                                  width: 2 * radius, height: 2 * radius))
                context.fill(ring, with: .color(colour.opacity(0.35)))
                context.stroke(ring, with: .color(isTargeting ? .orange : colour), lineWidth: 3)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
    }
}

/// Keeps the preview's AR camera on the phone's own while AR Edit is open,
/// once a screen refresh.
private final class ARCameraFollower: NSObject {
    private var link: CADisplayLink?
    private weak var session: ARSession?
    private weak var scene: PreviewScene?

    /// Follows `session`, or stops following when it's nil.
    func follow(_ session: ARSession?, in scene: PreviewScene) {
        stop()
        guard let session else { return }
        self.session = session
        self.scene = scene
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        if let frame = session?.currentFrame { scene?.updateARCamera(frame) }
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

    func makeCoordinator() -> GizmoDragger { GizmoDragger(scene: scene) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene.scene
        view.delegate = scene
        view.antialiasingMode = .multisampling4X
        // Keeps the render loop, and so walking, running when nothing else changes.
        view.isPlaying = true
        scene.show(mode, in: view)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        scene.show(mode, in: view)
        context.coordinator.scene = scene
        context.coordinator.goFirst(in: view)
    }
}

/// One-finger drags on the gizmo's handles, ahead of SceneKit's own camera
/// gestures: those wait for this one, which only takes touches that land on
/// a handle, so orbiting elsewhere isn't held up. (Walk has its own look
/// drag over the view, which asks the gizmo first; see `look`.)
private final class GizmoDragger: NSObject, UIGestureRecognizerDelegate {
    var scene: PreviewScene
    private let pan = UIPanGestureRecognizer()

    init(scene: PreviewScene) {
        self.scene = scene
        super.init()
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pan.addTarget(self, action: #selector(dragged))
    }

    func attach(to view: SCNView) {
        view.addGestureRecognizer(pan)
        goFirst(in: view)
    }

    /// Camera control puts its gestures back each time it's turned on, so
    /// this is redone on every update.
    func goFirst(in view: SCNView) {
        for recognizer in view.gestureRecognizers ?? [] where recognizer !== pan && recognizer is UIPanGestureRecognizer {
            recognizer.require(toFail: pan)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        scene.gizmoHandle(at: touch.location(in: touch.view)) != nil
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: pan.view)
        switch pan.state {
        case .began:
            // The pan starts a little after the touch; grab where the finger came down.
            let translation = pan.translation(in: pan.view)
            if scene.beginGizmoDrag(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y)) {
                scene.updateGizmoDrag(to: point)
            }
        case .changed:
            scene.updateGizmoDrag(to: point)
        default:
            scene.endGizmoDrag()
        }
    }
}
