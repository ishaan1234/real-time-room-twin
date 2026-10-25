import SceneKit

/// Loads model files (USD, USDZ) as furniture for PreviewScene: standing on
/// y = 0, centred, front towards +z.
enum ModelLoader {
    /// `height` is the model's real height in metres, if known. Blender
    /// exports USD with z up and SceneKit doesn't turn it upright, so when the
    /// height lies along z rather than y, the model is stood up. Blender's
    /// front (-y) then faces +z. `fitHeight` scales a model of unknown units
    /// (Sketchfab's) to that many metres tall.
    static func load(_ url: URL, height: Float? = nil, fitHeight: Float? = nil) throws -> SCNNode {
        let scene = try SCNScene(url: url, options: nil)
        let content = SCNNode()
        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
            content.addChildNode(child)
        }
        let (lo, hi) = content.boundingBox
        if let height, abs(Float(hi.z - lo.z) - height) < abs(Float(hi.y - lo.y) - height) {
            content.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        }
        let assetFolder = url.deletingLastPathComponent()
        content.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { repair($0, relativeTo: assetFolder) }
        }
        if let fitHeight {
            let (low, high) = content.boundingBox
            let rotated = content.simdOrientation.act(SIMD3(Float(high.x - low.x), Float(high.y - low.y), Float(high.z - low.z)))
            content.simdScale = SIMD3(repeating: fitHeight / max(abs(rotated.y), 1e-4))
        }
        let model = SCNNode()
        model.addChildNode(content)
        let (low, high) = model.boundingBox
        content.simdPosition -= SIMD3(Float(low.x + high.x) / 2, Float(low.y), Float(low.z + high.z) / 2)
        return model
    }

    /// Texture maps that weren't downloaded (Poly Haven's EXRs, to keep the
    /// download small) load as empty paths, which render black. Drop them,
    /// make the material non-metallic, and use the roughness JPEG beside
    /// the colour map if there is one.
    private static func repair(_ material: SCNMaterial, relativeTo folder: URL) {
        func file(_ contents: Any?) -> URL? {
            if let url = contents as? URL {
                return url.isFileURL && !url.path.hasPrefix("/") ? folder.appendingPathComponent(url.path) : url
            }
            guard let path = contents as? String, !path.isEmpty else { return nil }
            if path.hasPrefix("file://"), let url = URL(string: path) { return url }
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
        }
        func exists(_ url: URL?) -> Bool {
            url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
        if let diffuse = file(material.diffuse.contents) {
            material.diffuse.contents = exists(diffuse) ? diffuse : PlatformColor(white: 0.72, alpha: 1)
        }
        for property in [material.normal, material.metalness, material.roughness, material.ambientOcclusion]
        where property.contents is String && !exists(file(property.contents)) {
            property.contents = nil
        }
        if material.metalness.contents == nil {
            material.metalness.contents = 0.0
        }
        if material.roughness.contents == nil {
            let rough = file(material.diffuse.contents).map {
                URL(fileURLWithPath: $0.path.replacingOccurrences(of: "_diff_", with: "_roughness_"))
            }
            material.roughness.contents = exists(rough) ? rough : 0.8
        }
        material.lightingModel = .physicallyBased
    }
}
