import RoomPlan
import simd

/// Builds Hybrid's editable result with RoomPlan as the authoritative clean
/// geometry and the detailed reconstruction as its colour source. Moving a
/// table therefore reveals an intact flat floor/wall instead of a hole cut
/// from one fused triangle soup.
enum HybridSemanticMesh {
    struct Result {
        var mesh: MeshSnapshot
        var sampledVertices: Int
        var usedRoomPlanLayout: Bool

        var summary: String {
            guard usedRoomPlanLayout else { return "RoomPlan layout unavailable · detailed mesh preserved" }
            let total = mesh.positions.count
            let percent = total == 0 ? 0 : Int((Double(sampledVertices) / Double(total) * 100).rounded())
            return "RoomPlan layout · \(mesh.editableObjects.count) editable objects · \(percent)% scan-colour coverage"
        }
    }

    static func build(room: CapturedRoom, detailed: MeshSnapshot,
                      library: [String: MeshSnapshot]) -> Result {
        let semantic = RoomPlanMesh.build(room, library: library)
        // RoomBuilder can occasionally return an incomplete-but-nonthrowing
        // result after an interruption. Never discard a valid detailed scan
        // just because that semantic result has no renderable surfaces.
        guard !semantic.faces.isEmpty else {
            return Result(mesh: detailed, sampledVertices: 0, usedRoomPlanLayout: false)
        }
        let sampler = ColourSampler(mesh: detailed)
        let objectBoxes = room.objects.map {
            (inverse: $0.transform.inverse, half: $0.dimensions / 2 + SIMD3<Float>(repeating: 0.035))
        }

        var owner = [Int?](repeating: nil, count: semantic.faces.count)
        for (objectIndex, object) in semantic.editableObjects.enumerated() {
            for face in object.faces where semantic.faces.indices.contains(face) { owner[face] = objectIndex }
        }
        // Library furniture is already a detailed indexed mesh. Sampling and
        // duplicating each triangle corner made a 500k-triangle phone scan
        // take more than a minute to prepare. Accumulate a smooth normal once
        // and preserve its shared vertices instead.
        var semanticNormals = [SIMD3<Float>](repeating: .zero, count: semantic.positions.count)
        for face in semantic.faces {
            let a = semantic.positions[Int(face.x)]
            let b = semantic.positions[Int(face.y)]
            let c = semantic.positions[Int(face.z)]
            let normal = simd_cross(b - a, c - a)
            semanticNormals[Int(face.x)] += normal
            semanticNormals[Int(face.y)] += normal
            semanticNormals[Int(face.z)] += normal
        }
        semanticNormals = semanticNormals.map {
            simd_length_squared($0) > 1e-8 ? simd_normalize($0) : SIMD3<Float>(0, 1, 0)
        }
        var output = MeshSnapshot()
        var objectFaces = [[Int]](repeating: [], count: semantic.editableObjects.count)
        var furnitureVertexMap: [UInt32: UInt32] = [:]
        var sampledVertices = 0

        for (faceIndex, face) in semantic.faces.enumerated() {
            let indices = [Int(face.x), Int(face.y), Int(face.z)]
            let points = indices.map { semantic.positions[$0] }
            let colours = indices.map { semantic.colors[$0] }

            if owner[faceIndex] != nil {
                var remapped = SIMD3<UInt32>()
                for (corner, original) in [face.x, face.y, face.z].enumerated() {
                    if let existing = furnitureVertexMap[original] {
                        remapped[corner] = existing
                        continue
                    }
                    let index = Int(original)
                    let colour = sampler.colour(at: semantic.positions[index], matching: semanticNormals[index])
                    let mapped = UInt32(output.positions.count)
                    output.positions.append(semantic.positions[index])
                    output.colors.append(colour ?? semantic.colors[index])
                    if colour != nil { sampledVertices += 1 }
                    furnitureVertexMap[original] = mapped
                    remapped[corner] = mapped
                }
                let newFace = output.faces.count
                output.faces.append(remapped)
                objectFaces[owner[faceIndex]!].append(newFace)
                continue
            }

            let normal = simd_normalize(simd_cross(points[1] - points[0], points[2] - points[0]))
            let longest = max(simd_length(points[1] - points[0]),
                              simd_length(points[2] - points[1]),
                              simd_length(points[0] - points[2]))
            // RoomPlan walls can be a pair of room-sized triangles. A 12 cm
            // grid is fine enough for the detailed scan's colour variation
            // without recreating its noisy geometry.
            let divisions = min(48, max(1, Int(ceil(longest / 0.12))))
            var grid = [[UInt32]]()
            grid.reserveCapacity(divisions + 1)

            for i in 0...divisions {
                var row: [UInt32] = []
                row.reserveCapacity(divisions - i + 1)
                for j in 0...(divisions - i) {
                    let u = Float(i) / Float(divisions)
                    let v = Float(j) / Float(divisions)
                    let w = 1 - u - v
                    let point = points[0] * w + points[1] * u + points[2] * v
                    let fallback = blend(colours[0], colours[1], colours[2], weights: SIMD3(w, u, v))
                    let isFurniture = owner[faceIndex] != nil
                    let hiddenByFurniture = !isFurniture && objectBoxes.contains { box in
                        let local = (box.inverse * SIMD4(point, 1)).xyz
                        return all(abs(local) .<= box.half)
                    }
                    let colour = hiddenByFurniture ? nil : sampler.colour(at: point, matching: normal)
                    output.positions.append(point)
                    output.colors.append(colour ?? fallback)
                    if colour != nil { sampledVertices += 1 }
                    row.append(UInt32(output.positions.count - 1))
                }
                grid.append(row)
            }

            func add(_ triangle: SIMD3<UInt32>) {
                let newFace = output.faces.count
                output.faces.append(triangle)
                if let objectIndex = owner[faceIndex] { objectFaces[objectIndex].append(newFace) }
            }
            for i in 0..<divisions {
                for j in 0..<(divisions - i) {
                    add(SIMD3(grid[i][j], grid[i + 1][j], grid[i][j + 1]))
                    if j < divisions - i - 1 {
                        add(SIMD3(grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]))
                    }
                }
            }
        }

        output.editableObjects = zip(semantic.editableObjects, objectFaces).map {
            .init(name: $0.0.name, faces: $0.1)
        }
        return Result(mesh: output, sampledVertices: sampledVertices, usedRoomPlanLayout: true)
    }

    private static func blend(_ a: SIMD3<UInt8>, _ b: SIMD3<UInt8>, _ c: SIMD3<UInt8>,
                              weights: SIMD3<Float>) -> SIMD3<UInt8> {
        let value = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)) * weights.x
            + SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z)) * weights.y
            + SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)) * weights.z
        return SIMD3(UInt8(clamping: Int(value.x.rounded())),
                     UInt8(clamping: Int(value.y.rounded())),
                     UInt8(clamping: Int(value.z.rounded())))
    }
}

/// A compact spatial index for transferring captured vertex colour onto the
/// clean semantic surface. Normal and plane checks stop floors colouring walls
/// and reject most furniture pixels in front of structural surfaces.
struct ColourSampler {
    private struct Cell: Hashable {
        var x: Int32
        var y: Int32
        var z: Int32
    }

    private let mesh: MeshSnapshot
    private let normals: [SIMD3<Float>]
    private let cells: [Cell: [Int]]
    // This is slightly larger than maximumDistance, so every possible match
    // is in the current cell or one of its 26 neighbours.
    private let cellSize: Float = 0.14

    init(mesh: MeshSnapshot) {
        self.mesh = mesh
        var accumulated = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        for face in mesh.faces {
            let a = mesh.positions[Int(face.x)], b = mesh.positions[Int(face.y)], c = mesh.positions[Int(face.z)]
            let normal = simd_cross(b - a, c - a)
            accumulated[Int(face.x)] += normal
            accumulated[Int(face.y)] += normal
            accumulated[Int(face.z)] += normal
        }
        normals = accumulated.map { simd_length_squared($0) > 1e-8 ? simd_normalize($0) : .zero }
        var buckets: [Cell: [Int]] = [:]
        for (index, point) in mesh.positions.enumerated() {
            buckets[Self.cell(for: point, size: cellSize), default: []].append(index)
        }
        cells = buckets
    }

    func colour(at point: SIMD3<Float>, matching normal: SIMD3<Float>) -> SIMD3<UInt8>? {
        let origin = Self.cell(for: point, size: cellSize)
        let maximumDistance: Float = 0.13
        let maximumSquared = maximumDistance * maximumDistance
        var total = SIMD3<Float>.zero
        var totalWeight: Float = 0
        for x in -1...1 {
            for y in -1...1 {
                for z in -1...1 {
                    let key = Cell(x: origin.x + Int32(x), y: origin.y + Int32(y), z: origin.z + Int32(z))
                    guard let candidates = cells[key] else { continue }
                    for index in candidates {
                        let delta = mesh.positions[index] - point
                        let distanceSquared = simd_length_squared(delta)
                        guard distanceSquared <= maximumSquared,
                              abs(simd_dot(normals[index], normal)) >= 0.58,
                              abs(simd_dot(delta, normal)) <= 0.055 else { continue }
                        let weight = 1 / max(0.0004, distanceSquared)
                        let colour = mesh.colors[index]
                        total += SIMD3(Float(colour.x), Float(colour.y), Float(colour.z)) * weight
                        totalWeight += weight
                    }
                }
            }
        }
        guard totalWeight > 0 else { return nil }
        let value = total / totalWeight
        return SIMD3(UInt8(clamping: Int(value.x.rounded())),
                     UInt8(clamping: Int(value.y.rounded())),
                     UInt8(clamping: Int(value.z.rounded())))
    }

    private static func cell(for point: SIMD3<Float>, size: Float) -> Cell {
        Cell(x: Int32(floor(point.x / size)),
             y: Int32(floor(point.y / size)),
             z: Int32(floor(point.z / size)))
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
