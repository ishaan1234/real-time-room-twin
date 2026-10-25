import SwiftUI

/// Object mode's screen: the live camera with a shutter, then the photo to tap
/// on, SAM 3's mask, and the button that turns it into a 3D model.
struct ObjectModeView: View {
    @ObservedObject var capture: ObjectCapture
    let takePhoto: () -> Void
    @State private var editingServer = false
    @EnvironmentObject private var account: Account

    var body: some View {
        VStack(spacing: 12) {
            if let photo = capture.photo {
                PhotoSelection(photo: photo, overlay: overlay, taps: capture.taps, onTap: capture.select)
            } else {
                Spacer()
            }
            if let message = capture.errorMessage {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { capture.errorMessage = nil }
            }
            status
            controls
        }
        .padding()
        .onAppear(perform: capture.reloadConfig)
        .sheet(isPresented: $editingServer) {
            ServerSettings(config: capture.config, save: capture.setConfig)
        }
    }

    private var overlay: UIImage? {
        capture.chosenMask.flatMap { capture.masks.indices.contains($0) ? capture.masks[$0].overlay : nil }
    }

    @ViewBuilder
    private var status: some View {
        let busy: String? = switch capture.step {
        case .uploading: "Uploading the photo"
        case .selecting: "Finding the object"
        case .generating(let message): message
        default: nil
        }
        if let busy {
            HStack(spacing: 8) {
                ProgressView()
                Text(busy)
            }
            .capsuleLabel()
        } else if capture.config == nil {
            Text("Object mode needs the object server. On your Mac, run\nbash ObjectServer/start.sh")
                .multilineTextAlignment(.center)
                .capsuleLabel()
        } else if capture.step == .aiming {
            Text("Point at one object and take a photo").capsuleLabel()
        } else if capture.step == .done {
            Text("Saved in Files › RoomTwin › Objects. Tap another object to make another.").capsuleLabel()
        } else if capture.masks.isEmpty {
            Text(capture.taps.isEmpty
                 ? "Tap the object you want in 3D"
                 : "Using \(capture.taps.count) point\(capture.taps.count == 1 ? "" : "s") on one object")
                .capsuleLabel()
        } else {
            VStack(spacing: 8) {
                Text("\(capture.taps.count) point\(capture.taps.count == 1 ? "" : "s") · Tap another part of the same object to refine")
                    .capsuleLabel()
                if capture.masks.count > 1 {
                    Picker("Mask", selection: $capture.chosenMask) {
                        ForEach(Array(["Large", "Medium", "Small"].prefix(capture.masks.count).enumerated()), id: \.offset) {
                            Text($0.element).tag(Int?.some($0.offset))
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if capture.step == .aiming {
            HStack {
                CircleButton(systemImage: "server.rack", action: { editingServer = true })
                Spacer()
                Button(action: takePhoto) {
                    Circle()
                        .fill(.white)
                        .frame(width: 64, height: 64)
                        .padding(4)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                }
                .disabled(capture.config == nil)
                .accessibilityLabel("Take photo")
                Spacer()
                CircleButton(systemImage: "cube", action: { capture.revealURL = capture.modelURL })
                    .opacity(capture.modelURL == nil ? 0 : 1)
                    .disabled(capture.modelURL == nil)
            }
            .padding(.horizontal, 24)
        } else {
            HStack(spacing: 12) {
                Button("Retake", systemImage: "camera", action: capture.retake)
                    .buttonStyle(.bordered)
                    .tint(.white)
                if !capture.taps.isEmpty {
                    Button("Clear", systemImage: "xmark.circle", action: capture.clearPoints)
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                if capture.step == .done, capture.modelURL != nil {
                    Button("View 3D", systemImage: "cube") { capture.revealURL = capture.modelURL }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                Button("Generate 3D", systemImage: "wand.and.stars") { capture.generate(account: account) }
                    .buttonStyle(.borderedProminent)
                    .disabled(capture.step != .choosing || capture.chosenMask == nil)
            }
        }
    }
}

/// The photo with the chosen mask over it. Points are reported as 0...1 across the photo.
private struct PhotoSelection: View {
    let photo: UIImage
    let overlay: UIImage?
    let taps: [CGPoint]
    let onTap: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / photo.size.width, geometry.size.height / photo.size.height)
            let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
            ZStack(alignment: .topLeading) {
                Image(uiImage: photo).resizable()
                if let overlay {
                    Image(uiImage: overlay).resizable()
                }
                ForEach(Array(taps.enumerated()), id: \.offset) { index, tap in
                    ZStack {
                        Circle()
                            .fill(.blue)
                            .stroke(.white, lineWidth: 2)
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 22, height: 22)
                    .position(x: tap.x * size.width, y: tap.y * size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture { location in
                onTap(CGPoint(x: location.x / size.width, y: location.y / size.height))
            }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

private struct CircleButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 52, height: 52)
                .background(.regularMaterial, in: Circle())
        }
        .foregroundStyle(.primary)
    }
}

/// For typing in the address and token start.sh prints when it can't reach the phone.
private struct ServerSettings: View {
    let save: (ObjectServerConfig) -> Void
    @State private var url: String
    @State private var token: String
    @Environment(\.dismiss) private var dismiss

    init(config: ObjectServerConfig?, save: @escaping (ObjectServerConfig) -> Void) {
        self.save = save
        _url = State(initialValue: config?.url ?? "")
        _token = State(initialValue: config?.token ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.10:8765", text: $url)
                        .keyboardType(.URL)
                    TextField("Token", text: $token)
                } footer: {
                    Text("ObjectServer/start.sh on your Mac sends these to the phone when it's connected, and prints them otherwise.")
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Object Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(ObjectServerConfig(url: url.trimmingCharacters(in: .whitespaces),
                                                token: token.trimmingCharacters(in: .whitespaces)))
                        dismiss()
                    }
                    .disabled(url.isEmpty || token.isEmpty)
                }
            }
        }
    }
}

private extension View {
    func capsuleLabel() -> some View {
        font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
    }
}
