import RealityKit
import SwiftUI

/// Walk-around mode: Apple's Object Capture photographs the object from all
/// sides, then builds a textured model on the phone. No server needed.
/// Each capture is kept in Documents/Objects/Walk-<time>/: the photos in
/// Images/ (a Mac can rebuild them at higher detail) and model.usdz.
@MainActor
final class WalkAroundCapture: ObservableObject {
    enum Phase: Equatable {
        /// Waiting for Start: the camera isn't running.
        case ready
        /// Start was tapped and Object Capture is setting up.
        case starting
        case capturing
        case reconstructing(Double)
        case done
        case failed(String)
    }

    @Published private(set) var session: ObjectCaptureSession?
    @Published private(set) var phase = Phase.ready
    @Published private(set) var modelURL: URL?
    /// The first photo, for the model to pop out of.
    @Published private(set) var backdrop: UIImage?
    /// The model ModelReveal is showing, if any.
    @Published var revealURL: URL?

    private var folder: URL?
    private var watcher: Task<Void, Never>?

    static var isSupported: Bool { ObjectCaptureSession.isSupported }

    /// Starts a capture from the Start button. Object Capture's camera view
    /// takes a few seconds to set up, on the main thread, so the spinner goes
    /// up first; that's also why opening the mode doesn't start it.
    func start() {
        guard phase == .ready else { return }
        phase = .starting
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            begin()
        }
    }

    /// Starts a capture unless one is running or a model is being built.
    private func begin() {
        guard Self.isSupported, session == nil else { return }
        if case .reconstructing = phase { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Objects/Walk-\(formatter.string(from: Date()))")
        do {
            for name in ["Images", "Checkpoint"] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(name),
                                                        withIntermediateDirectories: true)
            }
        } catch {
            phase = .failed("Couldn't create the capture folder: \(error.localizedDescription)")
            return
        }
        Diagnostics.action("walk-around start")
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = folder.appendingPathComponent("Checkpoint")
        let session = ObjectCaptureSession()
        session.start(imagesDirectory: folder.appendingPathComponent("Images"), configuration: configuration)
        self.session = session
        self.folder = folder
        phase = .capturing
        UIApplication.shared.isIdleTimerDisabled = true
        watcher = Task { [weak self] in
            for await state in session.stateUpdates {
                if case .completed = state {
                    await self?.reconstruct()
                    return
                }
                if case .failed(let error) = state {
                    self?.fail(error)
                    return
                }
            }
        }
    }

    /// Leaving the mode drops an unfinished capture; a model being built carries on.
    func end() {
        guard session != nil, phase == .capturing else { return }
        watcher?.cancel()
        session?.cancel()
        session = nil
        // Photos of a capture that was never finished can't make a model.
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        phase = .ready
    }

    func restart() {
        end()
        session = nil
        phase = .ready
        start()
    }

    private func reconstruct() async {
        guard let folder else { return }
        // Object Capture's camera and memory have to be released before photogrammetry.
        session = nil
        phase = .reconstructing(0)
        Diagnostics.action("walk-around reconstruct")
        let images = folder.appendingPathComponent("Images")
        let output = folder.appendingPathComponent("model.usdz")
        do {
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = folder.appendingPathComponent("Checkpoint")
            let photogrammetry = try PhotogrammetrySession(input: images, configuration: configuration)
            try photogrammetry.process(requests: [.modelFile(url: output)])
            events: for try await event in photogrammetry.outputs {
                switch event {
                case .requestProgress(_, let fraction):
                    phase = .reconstructing(fraction)
                case .requestError(_, let error):
                    throw error
                case .processingComplete:
                    break events
                default:
                    break
                }
            }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("Checkpoint"))
            let first = (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil))?
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
            backdrop = first.flatMap { UIImage(contentsOfFile: $0.path) }
            modelURL = output
            revealURL = output
            phase = .done
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        Diagnostics.log("walk-around failed: \(error)")
        session = nil
        phase = .failed(error.localizedDescription)
    }
}

/// The controls over Object Capture's camera view, for each step of a capture.
struct WalkAroundControls: View {
    @ObservedObject var capture: WalkAroundCapture

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if !WalkAroundCapture.isSupported {
                Text("Walk-around capture needs a LiDAR iPhone or iPad with an A14 chip or newer.").label()
            } else if let session = capture.session {
                SessionControls(session: session)
            } else {
                switch capture.phase {
                case .reconstructing(let fraction):
                    VStack(spacing: 8) {
                        ProgressView(value: fraction)
                            .frame(width: 220)
                        Text("Building the model on your iPhone · \(Int(fraction * 100))%")
                        Text("Keep the app open").foregroundStyle(.secondary)
                    }
                    .label()
                case .failed(let message):
                    Text(message).label()
                    Button("Try Again", systemImage: "arrow.counterclockwise", action: capture.restart)
                        .buttonStyle(.borderedProminent)
                case .done:
                    HStack(spacing: 12) {
                        Button("View Model", systemImage: "cube") { capture.revealURL = capture.modelURL }
                            .buttonStyle(.bordered)
                        Button("New Capture", systemImage: "camera.viewfinder", action: capture.restart)
                            .buttonStyle(.borderedProminent)
                    }
                    .tint(.white)
                case .ready:
                    Text("Walk round an object with the phone; the model is built on your iPhone.").label()
                    Button("Start Capture", systemImage: "camera.viewfinder", action: capture.start)
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                case .starting, .capturing:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Starting the camera")
                    }
                    .label()
                }
            }
        }
        .padding()
    }
}

/// Reads the session's observable state, so it redraws as the capture moves on.
private struct SessionControls: View {
    let session: ObjectCaptureSession

    var body: some View {
        if let hint = feedbackHint {
            Label(hint, systemImage: "exclamationmark.triangle.fill").label()
        }
        switch session.state {
        case .initializing:
            ProgressView().label()
        case .ready:
            Text("Point at the object, then tap Continue").label()
            Button("Continue") { _ = session.startDetecting() }
                .buttonStyle(.borderedProminent)
        case .detecting:
            Text("Fit the box around the object").label()
            HStack(spacing: 12) {
                Button("Reset", systemImage: "arrow.counterclockwise") { _ = session.resetDetection() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("Start Capture", systemImage: "record.circle") { session.startCapturing() }
                    .buttonStyle(.borderedProminent)
            }
        case .capturing:
            Text(session.userCompletedScanPass
                 ? "Pass complete: \(session.numberOfShotsTaken) photos"
                 : "Walk slowly around the object · \(session.numberOfShotsTaken) photos").label()
            HStack(spacing: 12) {
                if session.userCompletedScanPass {
                    Button("Another Pass", systemImage: "arrow.triangle.2.circlepath") { session.beginNewScanPass() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                Button("Finish", systemImage: "checkmark") { session.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.numberOfShotsTaken < 20)
            }
        case .finishing, .completed:
            HStack(spacing: 8) {
                ProgressView()
                Text("Saving the photos")
            }
            .label()
        case .failed(let error):
            Text(error.localizedDescription).label()
        @unknown default:
            EmptyView()
        }
    }

    private var feedbackHint: String? {
        let feedback = session.feedback
        if feedback.contains(.objectTooClose) { return "Move back a little" }
        if feedback.contains(.objectTooFar) { return "Move closer" }
        if feedback.contains(.movingTooFast) { return "Slow down" }
        if feedback.contains(.environmentTooDark) || feedback.contains(.environmentLowLight) { return "Add more light" }
        if feedback.contains(.outOfFieldOfView) { return "Keep the object in view" }
        return nil
    }
}

private extension View {
    func label() -> some View {
        font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
    }
}
