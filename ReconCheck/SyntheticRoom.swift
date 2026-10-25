import Metal
import simd

/// An analytic room (ARKit world frame: metres, +y up) with a table and a ball.
struct SyntheticRoom {
    // Real walls never sit exactly on voxel planes, so neither do these.
    let roomMin = SIMD3<Float>(-1.9929, 0.0133, -2.5047)
    let roomMax = SIMD3<Float>(2.0071, 2.6133, 2.4953)
    let ballCenter = SIMD3<Float>(0.9, 0.55, -1.3)
    let ballRadius: Float = 0.45
    let tableMin = SIMD3<Float>(-1.5, 0.0, 0.5)
    let tableMax = SIMD3<Float>(-0.5, 0.75, 1.4)

    /// Signed distance to the nearest surface, positive in free space.
    func distance(_ p: SIMD3<Float>) -> Float {
        let walls = min((p - roomMin).min(), (roomMax - p).min())
        let ball = simd_length(p - ballCenter) - ballRadius
        let q = simd_abs(p - (tableMin + tableMax) / 2) - (tableMax - tableMin) / 2
        let table = simd_length(simd_max(q, .zero)) + min(q.max(), 0)
        return min(walls, ball, table)
    }

    /// First hit along origin + t * direction, with the surface color.
    func cast(origin o: SIMD3<Float>, direction d: SIMD3<Float>) -> (t: Float, color: SIMD3<Float>)? {
        var best = Float.infinity
        var color = SIMD3<Float>.zero
        for axis in 0..<3 where d[axis] != 0 {
            let positive = d[axis] > 0
            let t = ((positive ? roomMax[axis] : roomMin[axis]) - o[axis]) / d[axis]
            if t > 0 && t < best {
                best = t
                color = Self.wallColors[axis * 2 + (positive ? 1 : 0)]
            }
        }

        let oc = o - ballCenter
        let a = simd_dot(d, d), b = simd_dot(oc, d), c = simd_dot(oc, oc) - ballRadius * ballRadius
        let disc = b * b - a * c
        if disc > 0 {
            let t = (-b - disc.squareRoot()) / a
            if t > 0 && t < best { best = t; color = SIMD3(0.85, 0.2, 0.15) }
        }

        var near = -Float.infinity, far = Float.infinity
        for axis in 0..<3 {
            if d[axis] == 0 {
                if o[axis] < tableMin[axis] || o[axis] > tableMax[axis] { near = .infinity }
                continue
            }
            let t0 = (tableMin[axis] - o[axis]) / d[axis], t1 = (tableMax[axis] - o[axis]) / d[axis]
            near = max(near, min(t0, t1))
            far = min(far, max(t0, t1))
        }
        if near <= far && near > 0 && near < best { best = near; color = SIMD3(0.2, 0.35, 0.8) }

        return best.isFinite ? (best, color) : nil
    }

    // -x, +x, floor, ceiling, -z, +z
    private static let wallColors: [SIMD3<Float>] = [
        SIMD3(0.75, 0.78, 0.70), SIMD3(0.70, 0.72, 0.82), SIMD3(0.55, 0.40, 0.25),
        SIMD3(0.95, 0.95, 0.95), SIMD3(0.82, 0.76, 0.64), SIMD3(0.64, 0.76, 0.70),
    ]
}

/// Renders LiDAR-like frames of the room into textures laid out like ARKit's.
final class SyntheticCamera {
    static let colorWidth = 320, colorHeight = 240
    static let depthWidth = 256, depthHeight = 192
    static let intrinsics = simd_float3x3(columns: (SIMD3(242, 0, 0), SIMD3(0, 242, 0), SIMD3(159.5, 119.5, 1)))

    let room: SyntheticRoom
    let depthNoise: Float
    let depth: MTLTexture
    let confidence: MTLTexture
    let colorY: MTLTexture
    let colorCbCr: MTLTexture
    private var random = SplitMix64(seed: 7)

    init(device: MTLDevice, room: SyntheticRoom, depthNoise: Float) {
        self.room = room
        self.depthNoise = depthNoise
        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = .shaderRead
            return device.makeTexture(descriptor: descriptor)!
        }
        depth = texture(.r32Float, Self.depthWidth, Self.depthHeight)
        confidence = texture(.r8Uint, Self.depthWidth, Self.depthHeight)
        colorY = texture(.r8Unorm, Self.colorWidth, Self.colorHeight)
        colorCbCr = texture(.rg8Unorm, Self.colorWidth / 2, Self.colorHeight / 2)
        let high = [UInt8](repeating: 2, count: Self.depthWidth * Self.depthHeight)
        confidence.replace(region: MTLRegionMake2D(0, 0, Self.depthWidth, Self.depthHeight), mipmapLevel: 0,
                           withBytes: high, bytesPerRow: Self.depthWidth)
    }

    /// Camera pose i of n on a slow loop around the middle of the room, sweeping
    /// a full turn while tilting up and down.
    static func pose(_ i: Int, of n: Int) -> simd_float4x4 {
        let phase = Float(i) / Float(n) * 2 * .pi
        let yaw = simd_quatf(angle: phase, axis: SIMD3(0, 1, 0))
        let pitch = simd_quatf(angle: 0.55 * sin(3 * phase), axis: SIMD3(1, 0, 0))
        var pose = simd_float4x4(yaw * pitch)
        pose.columns.3 = SIMD4(0.25 * cos(phase), 1.35 + 0.05 * sin(2 * phase), 0.25 * sin(phase), 1)
        return pose
    }

    /// Fills the textures for a camera at `cameraToWorld` and returns the frame.
    func render(cameraToWorld: simd_float4x4) -> FrameInput {
        let k = Self.intrinsics
        let scale = Float(Self.depthWidth) / Float(Self.colorWidth)
        var depthPixels = [Float](repeating: .nan, count: Self.depthWidth * Self.depthHeight)
        for v in 0..<Self.depthHeight {
            for u in 0..<Self.depthWidth {
                let x = (Float(u) - k[2][0] * scale) / (k[0][0] * scale)
                let y = (Float(v) - k[2][1] * scale) / (k[1][1] * scale)
                // The ray has unit length along the view axis, so t is the depth.
                if let hit = cast(cameraToWorld, x, y) {
                    depthPixels[v * Self.depthWidth + u] = hit.t + depthNoise * random.nextGaussian()
                }
            }
        }
        depth.replace(region: MTLRegionMake2D(0, 0, Self.depthWidth, Self.depthHeight), mipmapLevel: 0,
                      withBytes: depthPixels, bytesPerRow: Self.depthWidth * 4)

        var luma = [UInt8](repeating: 0, count: Self.colorWidth * Self.colorHeight)
        var chroma = [UInt8](repeating: 128, count: Self.colorWidth * Self.colorHeight / 2)
        for v in 0..<Self.colorHeight {
            for u in 0..<Self.colorWidth {
                let x = (Float(u) - k[2][0]) / k[0][0], y = (Float(v) - k[2][1]) / k[1][1]
                guard let rgb = cast(cameraToWorld, x, y)?.color else { continue }
                luma[v * Self.colorWidth + u] = UInt8(255 * simd_dot(rgb, SIMD3(0.299, 0.587, 0.114)))
                if u % 2 == 0 && v % 2 == 0 {
                    let i = (v / 2 * Self.colorWidth / 2 + u / 2) * 2
                    chroma[i] = UInt8(128 + 255 * simd_dot(rgb, SIMD3(-0.168736, -0.331264, 0.5)))
                    chroma[i + 1] = UInt8(128 + 255 * simd_dot(rgb, SIMD3(0.5, -0.418688, -0.081312)))
                }
            }
        }
        colorY.replace(region: MTLRegionMake2D(0, 0, Self.colorWidth, Self.colorHeight), mipmapLevel: 0,
                       withBytes: luma, bytesPerRow: Self.colorWidth)
        colorCbCr.replace(region: MTLRegionMake2D(0, 0, Self.colorWidth / 2, Self.colorHeight / 2), mipmapLevel: 0,
                          withBytes: chroma, bytesPerRow: Self.colorWidth)

        return FrameInput(depth: depth, confidence: confidence, colorY: colorY, colorCbCr: colorCbCr,
                          colorIntrinsics: k, cameraToWorld: cameraToWorld)
    }

    /// Casts the ray through normalized image point (x, y), using ARKit's camera axes.
    private func cast(_ cameraToWorld: simd_float4x4, _ x: Float, _ y: Float) -> (t: Float, color: SIMD3<Float>)? {
        let direction = cameraToWorld * SIMD4(x, -y, -1, 0)
        let origin = cameraToWorld.columns.3
        return room.cast(origin: SIMD3(origin.x, origin.y, origin.z),
                         direction: SIMD3(direction.x, direction.y, direction.z))
    }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextGaussian() -> Float {
        let u1 = max(Float(next() >> 40) / Float(1 << 24), 1e-7)
        let u2 = Float(next() >> 40) / Float(1 << 24)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
