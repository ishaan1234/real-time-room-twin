import ARKit
import CoreImage

/// Saves keyframes while scanning, for the offline furniture step: the color
/// photo, LiDAR depth and confidence, and the camera pose and intrinsics.
///
/// Layout of a scan folder:
///   keyframes/000000.jpg    color image as captured (landscape, sensor orientation)
///   keyframes/000000.depth  Float32 metres, depthWidth x depthHeight, row-major
///   keyframes/000000.conf   UInt8 ARConfidenceLevel per depth pixel (0 low ... 2 high)
///   keyframes.json          one entry per keyframe, see `Keyframe`
///
/// Poses are in the same ARKit world frame as the exported mesh.
final class KeyframeRecorder {
    let folder: URL

    private struct Keyframe: Encodable {
        let index: Int
        let timestamp: TimeInterval
        let image: String
        let depth: String
        let confidence: String
        let imageWidth: Int
        let imageHeight: Int
        let depthWidth: Int
        let depthHeight: Int
        /// fx, fy, cx, cy of the color image, in pixels.
        let intrinsics: [Float]
        /// Column-major 4x4. ARKit camera axes: +x right, +y up, looking down -z,
        /// with the image's +x to the right and +y down.
        let cameraToWorld: [Float]
    }

    private let queue = DispatchQueue(label: "KeyframeRecorder", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var keyframes: [Keyframe] = []                       // queue only
    private var lastSaved: (time: TimeInterval, transform: simd_float4x4)?
    private var pending = 0
    private var count = 0

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("keyframes"),
                                                withIntermediateDirectories: true)
    }

    /// Saves `frame` if the camera has moved or turned enough since the last
    /// keyframe, at most twice a second. Call on the main thread with frames
    /// that were fused into the mesh.
    func consider(_ frame: ARFrame) {
        guard pending == 0, let sceneDepth = frame.sceneDepth,
              let confidenceMap = sceneDepth.confidenceMap else { return }
        let transform = frame.camera.transform
        if let last = lastSaved {
            let elapsed = frame.timestamp - last.time
            let moved = simd_distance(transform.columns.3, last.transform.columns.3)
            let turned = simd_dot(transform.columns.2, last.transform.columns.2)   // cosine between view axes
            guard elapsed >= 0.5, elapsed >= 3 || moved >= 0.15 || turned <= cos(Float.pi / 18) else { return }
        }
        lastSaved = (frame.timestamp, transform)

        let index = count
        count += 1
        let name = String(format: "keyframes/%06d", index)
        let depth = copyPlane(sceneDepth.depthMap, bytesPerPixel: 4)
        let confidence = copyPlane(confidenceMap, bytesPerPixel: 1)
        let image = frame.capturedImage
        let k = frame.camera.intrinsics
        let c = transform.columns
        let keyframe = Keyframe(index: index, timestamp: frame.timestamp,
                                image: name + ".jpg", depth: name + ".depth", confidence: name + ".conf",
                                imageWidth: CVPixelBufferGetWidth(image), imageHeight: CVPixelBufferGetHeight(image),
                                depthWidth: CVPixelBufferGetWidth(sceneDepth.depthMap),
                                depthHeight: CVPixelBufferGetHeight(sceneDepth.depthMap),
                                intrinsics: [k[0][0], k[1][1], k[2][0], k[2][1]],
                                cameraToWorld: [c.0, c.1, c.2, c.3].flatMap { [$0.x, $0.y, $0.z, $0.w] })
        pending += 1
        queue.async { [self] in
            defer { DispatchQueue.main.async { self.pending -= 1 } }
            guard let jpeg = context.jpegRepresentation(
                of: CIImage(cvPixelBuffer: image), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
            else { return }
            do {
                try jpeg.write(to: folder.appendingPathComponent(keyframe.image))
                try depth.write(to: folder.appendingPathComponent(keyframe.depth))
                try confidence.write(to: folder.appendingPathComponent(keyframe.confidence))
                keyframes.append(keyframe)
                // Rewritten every time so the list survives the app being killed.
                try JSONEncoder().encode(keyframes).write(to: folder.appendingPathComponent("keyframes.json"),
                                                          options: .atomic)
            } catch {
                Diagnostics.log("keyframe \(index) not saved: \(error.localizedDescription)")
            }
        }
    }

    /// Deletes the keyframes once pending writes are done. Exports in the folder are kept.
    func discard() {
        queue.async { [folder] in
            let files = FileManager.default
            try? files.removeItem(at: folder.appendingPathComponent("keyframes"))
            try? files.removeItem(at: folder.appendingPathComponent("keyframes.json"))
            if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? files.removeItem(at: folder)
            }
        }
    }

    private func copyPlane(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data {
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
