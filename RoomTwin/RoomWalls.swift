import simd

/// A wall found in the room's mesh: a large vertical plane.
struct Wall {
    /// Horizontal unit vector out of the wall, into the room.
    let normal: SIMD3<Float>
    /// Horizontal unit vector along the wall: to your right as you face it.
    let along: SIMD3<Float>
    /// `dot(p, normal)` for points p on the wall.
    let offset: Float
    /// `dot(p, along)` over the wall's length.
    let span: ClosedRange<Float>
    /// Height of its highest part.
    let top: Float
    /// The mesh's faces that make it up.
    let faces: [Int]

    /// How far `p` is in front of the wall; negative behind it.
    func distance(to p: SIMD3<Float>) -> Float {
        simd_dot(p, normal) - offset
    }

    /// The floor point `standoff` metres out from the wall at `s` along it.
    func point(along s: Float, standoff: Float, floorY: Float) -> SIMD3<Float> {
        var p = s * along + (offset + standoff) * normal
        p.y = floorY
        return p
    }
}

/// Finds walls: big vertical planes. Rooms are nearly always built on two
/// perpendicular directions, so the strongest direction of vertical surface
/// (mod 90°) gives four wall directions. Along each, surfaces at the same
/// distance from the origin form one wall. Both the scanner's mesh and
/// RoomPlan's are wound counter-clockwise seen from inside the room, so face
/// normals point into the room.
enum WallFinder {
    static func walls(in mesh: MeshSnapshot, floorY: Float, excludingFaces excluded: Set<Int> = []) -> [Wall] {
        struct Face {
            let index: Int
            let angle: Float
            let centre: SIMD3<Float>
            let area: Float
        }
        var vertical: [Face] = []
        for (i, f) in mesh.faces.enumerated() where !excluded.contains(i) {
            let a = mesh.positions[Int(f.x)], b = mesh.positions[Int(f.y)], c = mesh.positions[Int(f.z)]
            let n = simd_cross(b - a, c - a)
            let length = simd_length(n)
            guard length > 0, abs(n.y) < 0.3 * length else { continue }
            vertical.append(Face(index: i, angle: atan2(n.z, n.x), centre: (a + b + c) / 3, area: length / 2))
        }
        guard !vertical.isEmpty else { return [] }

        // The room's main direction: the angle mod 90° with the most vertical surface, in 1° bins.
        let quarter = Float.pi / 2
        var bins = [Float](repeating: 0, count: 90)
        for face in vertical {
            let a = face.angle - quarter * (face.angle / quarter).rounded(.down)
            bins[min(Int(a / quarter * 90), 89)] += face.area
        }
        let smoothed = bins.indices.map { bins[($0 + 89) % 90] + bins[$0] + bins[($0 + 1) % 90] }
        let coarse = (Float(smoothed.indices.max { smoothed[$0] < smoothed[$1] }!) + 0.5) * quarter / 90
        // Refined to the area-weighted mean of faces within 3° of it.
        var sum: Float = 0, weight: Float = 0
        for face in vertical {
            let offset = remainder(face.angle - coarse, quarter)
            if abs(offset) < 0.05 {
                sum += offset * face.area
                weight += face.area
            }
        }
        let main = coarse + (weight > 0 ? sum / weight : 0)

        var walls: [Wall] = []
        for k in 0..<4 {
            let angle = main + Float(k) * quarter
            let normal = SIMD3(cos(angle), 0, sin(angle))
            let along = simd_cross(SIMD3(0, 1, 0), normal)
            // Faces within 15° of this direction, by their distance along it.
            var faces = vertical.filter { abs(remainder($0.angle - angle, 2 * .pi)) < 0.26 }
            while !faces.isEmpty {
                // The 4 cm slab holding the most surface.
                let offsets = faces.map { simd_dot($0.centre, normal) }
                let low = offsets.min()!
                var slabs = [Float](repeating: 0, count: Int((offsets.max()! - low) / 0.02) + 2)
                for (face, d) in zip(faces, offsets) {
                    slabs[Int((d - low) / 0.02)] += face.area
                }
                let paired = slabs.indices.map { slabs[$0] + ($0 + 1 < slabs.count ? slabs[$0 + 1] : 0) }
                let best = paired.indices.max { paired[$0] < paired[$1] }!
                guard paired[best] >= 0.5 else { break }
                let centre = low + Float(best + 1) * 0.02
                // Everything within 6 cm of it is this wall.
                let member = offsets.map { abs($0 - centre) < 0.06 }
                let wallFaces = zip(faces, member).filter { $0.1 }.map { $0.0 }
                faces = zip(faces, member).filter { !$0.1 }.map { $0.0 }

                let area = wallFaces.reduce(0) { $0 + $1.area }
                let offset = wallFaces.reduce(0) { $0 + simd_dot($1.centre, normal) * $1.area } / area
                let positions = wallFaces.flatMap { face -> [SIMD3<Float>] in
                    let f = mesh.faces[face.index]
                    return [mesh.positions[Int(f.x)], mesh.positions[Int(f.y)], mesh.positions[Int(f.z)]]
                }
                let heights = positions.map(\.y), lengths = positions.map { simd_dot($0, along) }
                let top = heights.max()!, bottom = heights.min()!
                // Tall and wide enough to be a wall, not a cupboard door or a sofa back.
                guard area >= 0.8, top - floorY >= 1.2, top - bottom >= 0.9,
                      lengths.max()! - lengths.min()! >= 0.6 else { continue }
                walls.append(Wall(normal: normal, along: along, offset: offset,
                                  span: lengths.min()!...lengths.max()!, top: top,
                                  faces: wallFaces.map(\.index)))
            }
        }
        return walls
    }
}
