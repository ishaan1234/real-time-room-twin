import SceneKit

/// Furniture the voice agent can add: SAM 3D models from a room twin,
/// bundled from RoomTwin/Library by Voice/make_library.py. Each stands on
/// y = 0, centred, facing +z. Use on the main thread.
enum FurnitureLibrary {
    /// What's bundled, e.g. ["chair", "sofa", "stool", "table"].
    static let kinds: [String] = (Bundle.main.urls(forResourcesWithExtension: "ply", subdirectory: nil) ?? [])
        .map { $0.deletingPathExtension().lastPathComponent }
        .filter { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count)) }
        .sorted()

    private static let prefix = "furniture-"
    private static var loaded: [String: SCNNode] = [:]

    /// A new copy of the model, named after its kind, or nil if there's none of that kind.
    static func model(_ kind: String) -> SCNNode? {
        if let model = loaded[kind] {
            return model.clone()
        }
        guard let mesh = mesh(kind) else { return nil }
        let model = PreviewScene.meshNode(mesh)
        model.name = kind
        loaded[kind] = model
        return model.clone()
    }

    /// The model's mesh, read afresh. Safe on any thread.
    static func mesh(_ kind: String) -> MeshSnapshot? {
        Bundle.main.url(forResource: prefix + kind, withExtension: "ply").flatMap { try? MeshSnapshot(ply: $0) }
    }
}
