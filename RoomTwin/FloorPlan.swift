import simd

/// The scan seen from above in 10 cm cells: where something stands between
/// 10 cm and 1.8 m above the floor (furniture, walls, people), and where the
/// floor itself was scanned. Built once from the triangles, so finding room
/// for furniture needs no ray casting.
struct FloorPlan {
    static let cell: Float = 0.1
    private let origin: SIMD2<Float>
    private let columns: Int, rows: Int
    private var blocked: [Bool], floor: [Bool]

    init(_ mesh: MeshSnapshot, floorY: Float, excludingFaces excluded: Set<Int> = []) {
        let lo = mesh.positions.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let hi = mesh.positions.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        origin = SIMD2(lo.x, lo.z)
        columns = Int((hi.x - lo.x) / Self.cell) + 1
        rows = Int((hi.z - lo.z) / Self.cell) + 1
        blocked = Array(repeating: false, count: columns * rows)
        floor = blocked
        for (faceIndex, f) in mesh.faces.enumerated() where !excluded.contains(faceIndex) {
            let a = mesh.positions[Int(f.x)], b = mesh.positions[Int(f.y)], c = mesh.positions[Int(f.z)]
            // Points at most half a cell apart, so a big triangle (a RoomPlan
            // wall or floor) reaches every cell it crosses. A scanned
            // triangle is smaller than that, so it's just its corners.
            let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
            let n = max(1, Int((longest / (Self.cell / 2)).rounded(.up)))
            for i in 0...n {
                for j in 0...(n - i) {
                    let p: SIMD3<Float> = a + (b - a) * (Float(i) / Float(n)) + (c - a) * (Float(j) / Float(n))
                    guard let cell = index(SIMD2(p.x, p.z)) else { continue }
                    if abs(p.y - floorY) < 0.05 {
                        floor[cell] = true
                    } else if p.y > floorY + 0.1 && p.y < floorY + 1.8 {
                        blocked[cell] = true
                    }
                }
            }
        }
    }

    private func index(_ point: SIMD2<Float>) -> Int? {
        let c = Int(((point.x - origin.x) / Self.cell).rounded(.down))
        let r = Int(((point.y - origin.y) / Self.cell).rounded(.down))
        return c >= 0 && c < columns && r >= 0 && r < rows ? r * columns + c : nil
    }

    /// Whether a footprint is clear: nothing stands inside it (shrunk by 8 cm,
    /// as the cells are coarse and scanned walls are a little rough), and
    /// there's scanned floor in it or within 20 cm. Floor right beside
    /// furniture is often missed by the scan, but requiring some keeps
    /// furniture inside the room.
    func isClear(_ footprint: Footprint) -> Bool {
        obstruction(footprint) == 0 && hasFloor(near: footprint)
    }

    /// How many points 5 cm apart inside the footprint (shrunk by 8 cm, as
    /// for `isClear`) land where something stands. Zero means clear.
    func obstruction(_ footprint: Footprint) -> Int {
        let inner = SIMD2(max(footprint.half.x - 0.08, 0.05), max(footprint.half.y - 0.08, 0.05))
        let step = Self.cell / 2
        var count = 0
        for z in stride(from: -inner.y, through: inner.y, by: step) {
            for x in stride(from: -inner.x, through: inner.x, by: step) {
                if let i = index(footprint.point(x, z)), blocked[i] { count += 1 }
            }
        }
        return count
    }

    /// Whether there's scanned floor in the footprint or within 20 cm of it.
    func hasFloor(near footprint: Footprint) -> Bool {
        let outer = footprint.half + 0.2
        for z in stride(from: -outer.y, through: outer.y, by: Self.cell) {
            for x in stride(from: -outer.x, through: outer.x, by: Self.cell) {
                if let i = index(footprint.point(x, z)), floor[i] { return true }
            }
        }
        return false
    }

    /// Whether the footprint lies over scanned floor. Unlike `isClear`, this
    /// deliberately ignores furniture and walls; it is used for ceiling
    /// fixtures whose projection may be above a table or sofa.
    func isInside(_ footprint: Footprint) -> Bool {
        let inset = SIMD2(max(footprint.half.x - 0.04, 0.02), max(footprint.half.y - 0.04, 0.02))
        let samples = [SIMD2<Float>(0, 0), SIMD2(-inset.x, -inset.y), SIMD2(inset.x, -inset.y),
                       SIMD2(inset.x, inset.y), SIMD2(-inset.x, inset.y)]
        return samples.allSatisfy { offset in
            if let i = index(footprint.point(offset.x, offset.y)), floor[i] { return true }
            // Sparse LiDAR floors often miss a cell; accept one within 20 cm.
            for z in stride(from: -Float(0.2), through: Float(0.2), by: Self.cell) {
                for x in stride(from: -Float(0.2), through: Float(0.2), by: Self.cell) {
                    if let i = index(footprint.point(offset.x + x, offset.y + z)), floor[i] { return true }
                }
            }
            return false
        }
    }
}

/// A rectangle on the floor: what a piece of furniture covers seen from above.
struct Footprint {
    /// Centre, as (x, z).
    var centre: SIMD2<Float>
    /// Half the width (along the piece's x) and half the depth (along its z).
    var half: SIMD2<Float>
    /// Turn about +y, as for the node.
    var yaw: Float

    /// The piece's local (x, z) in the world's (x, z).
    func point(_ x: Float, _ z: Float) -> SIMD2<Float> {
        // A turn by yaw about +y takes local +x to (cos, -sin) and +z to (sin, cos).
        centre + SIMD2(cos(yaw) * x + sin(yaw) * z, -sin(yaw) * x + cos(yaw) * z)
    }

    /// Whether two footprints overlap by more than `tolerance`, by separating axes.
    func overlaps(_ other: Footprint, tolerance: Float = 0.02) -> Bool {
        let axes = [yaw, other.yaw].flatMap { a in [SIMD2(cos(a), -sin(a)), SIMD2(sin(a), cos(a))] }
        for axis in axes {
            let (a0, a1) = projected(on: axis), (b0, b1) = other.projected(on: axis)
            if a1 - tolerance <= b0 || b1 - tolerance <= a0 { return false }
        }
        return true
    }

    private func projected(on axis: SIMD2<Float>) -> (Float, Float) {
        let corners = [point(-half.x, -half.y), point(half.x, -half.y), point(half.x, half.y), point(-half.x, half.y)]
        let values = corners.map { simd_dot($0, axis) }
        return (values.min()!, values.max()!)
    }
}
