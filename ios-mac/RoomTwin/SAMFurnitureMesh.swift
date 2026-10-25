import RoomPlan
import simd

/// Combines the detailed scan with completed SAM models. RoomPlan is used only
/// for the furniture cut and the small floor/wall repairs hidden by that item;
/// it never replaces the rest of the captured room.
enum SAMFurnitureMesh {
    struct Result {
        let mesh: MeshSnapshot
        let replacements: Int
        let removedFaces: Int
        let repairPatches: Int

        var summary: String {
            "SAM Furniture · \(replacements) replacement\(replacements == 1 ? "" : "s") · "
                + "\(repairPatches) local surface repair\(repairPatches == 1 ? "" : "s")"
        }
    }

    private struct Target {
        let object: CapturedRoom.Object
        let replacement: SAMFurnitureReplacement
        let inverse: simd_float4x4
        let half: SIMD3<Float>
    }

    static func build(room: CapturedRoom, detailed: MeshSnapshot,
                      replacements: [SAMFurnitureReplacement]) -> Result {
        var unused = replacements
        let targets = room.objects.compactMap { object -> Target? in
            let identifier = object.identifier.uuidString.lowercased()
            let category = RoomPlanMesh.name(of: object.category)
            let exact = unused.firstIndex { $0.targetIdentifier.lowercased() == identifier }
            let nearby = unused.indices
                .filter { unused[$0].category == category }
                .min { matchRank(unused[$0], object) < matchRank(unused[$1], object) }
            guard let index = exact ?? nearby else { return nil }
            let candidate = unused[index]
            // RoomPlan can replace an identifier while refining a box. Accept
            // that only when the final same-category box is still nearby and
            // similarly sized; adjacent chairs remain separate.
            if exact == nil {
                let scale = max(simd_length(object.dimensions), 0.2)
                guard simd_distance(candidate.targetTransform.position, object.transform.position) < 0.22 * scale,
                      simd_length(candidate.targetDimensions - object.dimensions) < 0.28 * scale else { return nil }
            }
            let replacement = unused.remove(at: index)
            return Target(object: object, replacement: replacement, inverse: object.transform.inverse,
                          half: object.dimensions / 2 + SIMD3<Float>(repeating: 0.045))
        }
        guard !targets.isEmpty else {
            return Result(mesh: detailed, replacements: 0, removedFaces: 0, repairPatches: 0)
        }

        let floorPlanes = room.floors.map { ($0.transform.inverse, simd_normalize($0.transform.normal)) }
        var output = detailed
        output.editableObjects = []
        let originalCount = output.faces.count
        output.faces = detailed.faces.filter { face in
            let points = [detailed.positions[Int(face.x)], detailed.positions[Int(face.y)],
                          detailed.positions[Int(face.z)]]
            let centre = (points[0] + points[1] + points[2]) / 3
            let normal = simd_normalize(simd_cross(points[1] - points[0], points[2] - points[0]))
            let protectedFloor = floorPlanes.contains { inverse, planeNormal in
                let local = inverse * SIMD4(centre, 1)
                return abs(local.z) < 0.055 && abs(simd_dot(normal, planeNormal)) > 0.72
            }
            guard !protectedFloor else { return true }
            return !targets.contains { target in
                let local = (target.inverse * SIMD4(centre, 1)).xyz
                return all(abs(local) .<= target.half)
            }
        }
        let removedFaceCount = originalCount - output.faces.count

        let sampler = ColourSampler(mesh: detailed)
        var repairPatches = 0
        for target in targets {
            repairPatches += addRepairs(for: target, room: room, sampler: sampler, to: &output)
        }

        var counts: [String: Int] = [:]
        for target in targets {
            let category = target.replacement.category
            counts[category, default: 0] += 1
            let firstFace = output.faces.count
            append(target.replacement.mesh, to: &output)
            output.editableObjects.append(.init(name: "\(category) \(counts[category]!)",
                                                faces: Array(firstFace..<output.faces.count)))
        }
        return Result(mesh: output, replacements: targets.count,
                      removedFaces: removedFaceCount,
                      repairPatches: repairPatches)
    }

    private static func matchRank(_ replacement: SAMFurnitureReplacement,
                                  _ object: CapturedRoom.Object) -> Float {
        simd_distance(replacement.targetTransform.position, object.transform.position)
            + 0.35 * simd_length(replacement.targetDimensions - object.dimensions)
    }

    private static func addRepairs(for target: Target, room: CapturedRoom,
                                   sampler: ColourSampler, to mesh: inout MeshSnapshot) -> Int {
        let corners = boxCorners(transform: target.object.transform, dimensions: target.object.dimensions)
        let surfaces: [(CapturedRoom.Surface, SIMD3<UInt8>, Float)]
            = room.walls.map { ($0, SIMD3(226, 222, 214), 0.22) }
            + room.floors.map { ($0, SIMD3(176, 160, 138), 0.18) }
        var count = 0
        for (surface, fallback, maximumGap) in surfaces {
            let local = corners.map { (surface.transform.inverse * SIMD4($0, 1)).xyz }
            guard local.map({ abs($0.z) }).min() ?? .infinity <= maximumGap else { continue }
            let half = SIMD2(surface.dimensions.x, surface.dimensions.y) / 2
            var low = SIMD2(local.map(\.x).min()!, local.map(\.y).min()!) - SIMD2(repeating: 0.08)
            var high = SIMD2(local.map(\.x).max()!, local.map(\.y).max()!) + SIMD2(repeating: 0.08)
            low = simd_max(low, -half)
            high = simd_min(high, half)
            guard all((high - low) .>= SIMD2<Float>(repeating: 0.05)) else { continue }
            let localPoints = [SIMD3(low.x, low.y, 0), SIMD3(high.x, low.y, 0),
                               SIMD3(high.x, high.y, 0), SIMD3(low.x, high.y, 0)]
            let normal = simd_normalize(surface.transform.normal)
            let first = UInt32(mesh.positions.count)
            for localPoint in localPoints {
                let point = (surface.transform * SIMD4(localPoint, 1)).xyz
                mesh.positions.append(point)
                mesh.colors.append(sampler.colour(at: point, matching: normal) ?? fallback)
                mesh.poolIndices.append(-1)
            }
            // Two windings: visible from either side in PLY/SceneKit viewers.
            mesh.faces += [SIMD3(first, first + 1, first + 2), SIMD3(first, first + 2, first + 3),
                           SIMD3(first + 2, first + 1, first), SIMD3(first + 3, first + 2, first)]
            count += 1
        }
        return count
    }

    private static func append(_ source: MeshSnapshot, to destination: inout MeshSnapshot) {
        let offset = UInt32(destination.positions.count)
        destination.positions += source.positions
        destination.colors += source.colors
        destination.poolIndices += [Int32](repeating: -1, count: source.positions.count)
        destination.faces += source.faces.map { $0 &+ SIMD3<UInt32>(repeating: offset) }
    }

    private static func boxCorners(transform: simd_float4x4, dimensions: SIMD3<Float>) -> [SIMD3<Float>] {
        [-1 as Float, 1].flatMap { x in
            [-1 as Float, 1].flatMap { y in
                [-1 as Float, 1].map { z in
                    (transform * SIMD4(SIMD3(x, y, z) * dimensions / 2, 1)).xyz
                }
            }
        }
    }
}

private extension simd_float4x4 {
    var normal: SIMD3<Float> { SIMD3(columns.2.x, columns.2.y, columns.2.z) }
    var position: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
