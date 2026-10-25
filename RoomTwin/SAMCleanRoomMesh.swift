import RoomPlan

/// Clean mode keeps RoomPlan's stable walls, floors, openings and semantic
/// furniture. Only photographed furniture is swapped for SAM geometry. Every
/// untouched RoomPlan object and every replacement remains an independent
/// editable object in PreviewScene.
enum SAMCleanRoomMesh {
    struct Result {
        let mesh: MeshSnapshot
        let replacements: Int
    }

    static func build(room: CapturedRoom, library: [String: MeshSnapshot],
                      replacements: [SAMFurnitureReplacement]) -> Result {
        let semantic = RoomPlanMesh.build(room, library: library)
        guard !replacements.isEmpty else { return Result(mesh: semantic, replacements: 0) }

        var unused = replacements
        var replacementForObject: [Int: SAMFurnitureReplacement] = [:]
        for (index, object) in room.objects.enumerated() {
            let identifier = object.identifier.uuidString.lowercased()
            let category = RoomPlanMesh.name(of: object.category)
            let exact = unused.firstIndex { $0.targetIdentifier.lowercased() == identifier }
            let nearby = unused.indices
                .filter { unused[$0].category == category }
                .min { matchRank(unused[$0], object) < matchRank(unused[$1], object) }
            guard let match = exact ?? nearby else { continue }
            let replacement = unused[match]
            if exact == nil {
                let scale = max(simd_length(object.dimensions), 0.2)
                guard simd_distance(position(of: replacement.targetTransform), position(of: object.transform)) < 0.22 * scale,
                      simd_length(replacement.targetDimensions - object.dimensions) < 0.28 * scale else { continue }
            }
            replacementForObject[index] = unused.remove(at: match)
        }

        let removedFaces = Set(replacementForObject.keys.flatMap { index in
            semantic.editableObjects.indices.contains(index) ? semantic.editableObjects[index].faces : []
        })
        var output = semantic
        output.faces = []
        output.editableObjects = []
        var faceMap: [Int: Int] = [:]
        for (oldIndex, face) in semantic.faces.enumerated() where !removedFaces.contains(oldIndex) {
            faceMap[oldIndex] = output.faces.count
            output.faces.append(face)
        }

        for (index, object) in semantic.editableObjects.enumerated() {
            if let replacement = replacementForObject[index] {
                let firstFace = output.faces.count
                append(replacement.mesh, to: &output)
                output.editableObjects.append(.init(name: object.name,
                                                    faces: Array(firstFace..<output.faces.count)))
            } else {
                output.editableObjects.append(.init(name: object.name,
                                                    faces: object.faces.compactMap { faceMap[$0] }))
            }
        }
        return Result(mesh: output, replacements: replacementForObject.count)
    }

    private static func matchRank(_ replacement: SAMFurnitureReplacement,
                                  _ object: CapturedRoom.Object) -> Float {
        simd_distance(position(of: replacement.targetTransform), position(of: object.transform))
            + simd_length(replacement.targetDimensions - object.dimensions)
    }

    private static func position(of transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    private static func append(_ source: MeshSnapshot, to destination: inout MeshSnapshot) {
        let base = UInt32(destination.positions.count)
        destination.positions += source.positions
        destination.colors += source.colors.count == source.positions.count
            ? source.colors : Array(repeating: SIMD3<UInt8>(190, 190, 190), count: source.positions.count)
        destination.faces += source.faces.map { $0 &+ base }
    }
}
