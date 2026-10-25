import ARKit
import CoreImage
import SwiftUI

/// Where the object server is. ObjectServer/start.sh on the Mac writes this to
/// Library/object-server.json in the app's container; it can also be typed in.
struct ObjectServerConfig: Codable, Equatable {
    var url: String
    var token: String

    static let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("object-server.json")

    static func load() -> ObjectServerConfig? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save() throws {
        try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
    }
}

private struct ObjectServerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One of SAM 3's mask candidates for a tap.
struct ObjectMask {
    let overlay: UIImage
    let score: Float
    let area: Float
}

/// Object mode: take one photo, tap the object to see SAM 3's mask, then have
/// SAM 3D Objects turn it into a model. Both run on the Colab VM behind
/// ObjectServer/server.py; models are saved in Documents/Objects.
@MainActor
final class ObjectCapture: ObservableObject {
    enum Step: Equatable {
        case aiming
        case uploading
        case choosing
        case selecting
        case generating(String)
        case done
    }

    @Published private(set) var step = Step.aiming
    @Published private(set) var photo: UIImage?
    /// The last tap, 0...1 across the upright photo.
    @Published private(set) var tap: CGPoint?
    /// Largest first.
    @Published private(set) var masks: [ObjectMask] = []
    @Published var chosenMask: Int?
    /// The model ModelReveal is showing, if any.
    @Published var revealURL: URL?
    @Published private(set) var modelURL: URL?
    @Published var errorMessage: String?
    @Published private(set) var config = ObjectServerConfig.load()

    private var rawPhoto: CGImage?
    private var photoJPEG: Data?
    private var photoID: String?
    private var task: Task<Void, Never>?

    func reloadConfig() {
        config = ObjectServerConfig.load()
    }

    func setConfig(_ config: ObjectServerConfig) {
        do {
            try config.save()
            self.config = config
        } catch {
            errorMessage = "Couldn't save the server address: \(error.localizedDescription)"
        }
    }

    func capture(_ frame: ARFrame) {
        reloadConfig()
        guard config != nil else {
            errorMessage = "Start the object server first: run ObjectServer/start.sh on your Mac."
            return
        }
        guard let sceneDepth = frame.sceneDepth, let confidence = sceneDepth.confidenceMap else {
            errorMessage = "This frame has no LiDAR depth. Try again."
            return
        }
        Diagnostics.action("object photo")
        let k = frame.camera.intrinsics
        let c = frame.camera.transform.columns
        // The same entry KeyframeRecorder writes, which Furniture/scan_io.py reads.
        let entry: [String: Any] = [
            "index": 0, "timestamp": frame.timestamp,
            "imageWidth": CVPixelBufferGetWidth(frame.capturedImage),
            "imageHeight": CVPixelBufferGetHeight(frame.capturedImage),
            "depthWidth": CVPixelBufferGetWidth(sceneDepth.depthMap),
            "depthHeight": CVPixelBufferGetHeight(sceneDepth.depthMap),
            "intrinsics": [k[0][0], k[1][1], k[2][0], k[2][1]],
            "cameraToWorld": [c.0, c.1, c.2, c.3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
        ]
        let depth = ObjectFiles.copyPlane(sceneDepth.depthMap, bytesPerPixel: 4)
        let confidenceData = ObjectFiles.copyPlane(confidence, bytesPerPixel: 1)
        let image = CIImage(cvPixelBuffer: frame.capturedImage)

        task?.cancel()
        clearSelection()
        photoID = nil
        step = .uploading
        task = Task {
            do {
                let (jpeg, raw) = try await Task.detached { try ObjectFiles.encode(image) }.value
                rawPhoto = raw
                photoJPEG = jpeg
                // The live view is always portrait; the server may turn it otherwise from gravity.
                photo = UIImage(cgImage: raw, scale: 1, orientation: .right)
                let body: [String: Any] = ["entry": entry, "image": jpeg.base64EncodedString(),
                                           "depth": depth.base64EncodedString(),
                                           "confidence": confidenceData.base64EncodedString()]
                let added: PhotoReply = try await send("POST", "photos", body)
                photoID = added.id
                photo = UIImage(cgImage: raw, scale: 1, orientation: Self.orientation(turns: added.turns))
                step = .choosing
            } catch {
                fail(error, fallback: .aiming)
            }
        }
    }

    /// Asks SAM 3 for the object under `point` (0...1 across the photo).
    func select(at point: CGPoint) {
        guard let photoID, [.choosing, .selecting, .done].contains(step) else { return }
        task?.cancel()
        tap = point
        step = .selecting
        task = Task {
            do {
                let reply: SelectReply = try await send("POST", "photos/\(photoID)/select",
                                                        ["x": point.x, "y": point.y])
                masks = reply.masks.compactMap { mask in
                    Data(base64Encoded: mask.overlay).flatMap(UIImage.init(data:)).map {
                        ObjectMask(overlay: $0, score: mask.score, area: mask.area)
                    }
                }
                chosenMask = masks.indices.contains(reply.best) ? reply.best : masks.indices.first
                step = .choosing
            } catch {
                fail(error, fallback: .choosing)
            }
        }
    }

    func generate() {
        guard let photoID, let chosenMask, step == .choosing else { return }
        Diagnostics.action("object generate")
        task?.cancel()
        step = .generating("Sending")
        task = Task {
            do {
                let job: JobReply = try await send("POST", "photos/\(photoID)/generate", ["mask": chosenMask])
                let start = Date()
                while true {
                    try await Task.sleep(for: .seconds(1))
                    let status: JobStatus = try await send("GET", "jobs/\(job.job)")
                    if status.state == "done" { break }
                    if status.state == "failed" { throw ObjectServerError(message: status.message ?? "Generation failed") }
                    step = .generating("\(status.message ?? "Working") · \(Int(Date().timeIntervalSince(start))) s")
                }
                step = .generating("Downloading")
                let ply = try await data("GET", "jobs/\(job.job)/model.ply")
                step = .generating("Preparing the preview")
                let jpeg = photoJPEG
                let url = try await Task.detached { try ObjectFiles.save(ply: ply, photo: jpeg) }.value
                modelURL = url
                revealURL = url
                step = .done
            } catch {
                fail(error, fallback: .choosing)
            }
        }
    }

    func retake() {
        task?.cancel()
        clearSelection()
        photo = nil
        rawPhoto = nil
        photoJPEG = nil
        photoID = nil
        step = .aiming
    }

    private func clearSelection() {
        tap = nil
        masks = []
        chosenMask = nil
    }

    private func fail(_ error: Error, fallback: Step) {
        // A newer request replaced this one and owns the step now.
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        step = fallback
        if let error = error as? URLError, [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
                                            .notConnectedToInternet].contains(error.code) {
            errorMessage = "Can't reach the object server at \(config?.url ?? "?"). Check that ObjectServer/start.sh "
                + "is running on your Mac and the phone is on the same Wi-Fi."
        } else {
            errorMessage = error.localizedDescription
        }
        Diagnostics.log("object mode error: \(error)")
    }

    // MARK: Server

    private struct PhotoReply: Decodable { let id: String; let turns: Int }
    private struct SelectReply: Decodable {
        struct Mask: Decodable { let overlay: String; let score: Float; let area: Float }
        let masks: [Mask]
        let best: Int
    }
    private struct JobReply: Decodable { let job: String }
    private struct JobStatus: Decodable { let state: String; let message: String? }
    private struct ErrorReply: Decodable { let error: String }

    private func send<Reply: Decodable>(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Reply {
        try JSONDecoder().decode(Reply.self, from: await data(method, path, body))
    }

    private func data(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Data {
        guard let config, let base = URL(string: config.url) else {
            throw ObjectServerError(message: "No object server is set up.")
        }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue(config.token, forHTTPHeaderField: "X-Token")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error ?? "HTTP \(status)"
            throw ObjectServerError(message: "Object server: \(message)")
        }
        return data
    }

    /// The UIImage orientation that shows a sensor-orientation photo turned
    /// `turns` times by np.rot90 (90 degrees counter-clockwise each).
    private static func orientation(turns: Int) -> UIImage.Orientation {
        switch (turns % 4 + 4) % 4 {
        case 1: .left
        case 2: .down
        case 3: .right
        default: .up
        }
    }
}

/// Photo and model files for ObjectCapture, off the main actor.
private enum ObjectFiles {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The photo as captured (sensor orientation): a JPEG to upload and a bitmap to show.
    static func encode(_ image: CIImage) throws -> (Data, CGImage) {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let jpeg = context.jpegRepresentation(
                of: image, colorSpace: sRGB,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9]),
              let raw = context.createCGImage(image, from: image.extent) else {
            throw ObjectServerError(message: "Couldn't encode the photo.")
        }
        return (jpeg, raw)
    }

    /// Saves the model as PLY and Quick Look-ready USDZ in Documents/Objects/Object-<time>/.
    static func save(ply: Data, photo: Data?) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Objects/Object-\(formatter.string(from: Date()))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plyURL = folder.appendingPathComponent("model.ply")
        try ply.write(to: plyURL)
        try photo?.write(to: folder.appendingPathComponent("photo.jpg"))
        let usdz = folder.appendingPathComponent("model.usdz")
        try MeshSnapshot(ply: plyURL).writeUSDZ(to: usdz)
        return usdz
    }

    static func copyPlane(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var data = Data(capacity: width * height * bytesPerPixel)
        for row in 0..<height {
            data.append(base + row * stride, count: width * bytesPerPixel)
        }
        return data
    }
}
