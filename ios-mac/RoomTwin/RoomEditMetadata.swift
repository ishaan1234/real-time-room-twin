import Foundation

/// Versioned, engine-independent state stored beside a saved room. The USDZ
/// remains the source of exact mesh/material data; this file identifies every
/// edited node and records the semantic settings USDZ cannot reliably round
/// trip (lighting, enclosure, snapping, and original object identity).
struct RoomEditMetadata: Codable, Sendable {
    static let currentVersion = 1

    struct MaterialReference: Codable, Sendable {
        let assetID: String?
        let name: String?
        /// Real-world width and height covered by one texture tile.
        let size: [Float]
    }

    struct FurnitureItem: Codable, Sendable {
        /// Stable across replacement, movement, saving and reopening.
        let id: String
        let name: String
        let modelName: String
        let source: String
        /// Unique USDZ node name; never matched using the display name.
        let exportNodeName: String
        /// Column-major 4×4 transform.
        let transform: [Float]
        let modelScale: [Float]
        let material: MaterialReference?
    }

    struct WallMaterial: Codable, Sendable {
        let wallIndex: Int
        let exportNodeName: String
        let material: MaterialReference?
    }

    struct FloorMaterial: Codable, Sendable {
        let exportNodeName: String
        let material: MaterialReference?
    }

    struct Lighting: Codable, Sendable {
        let brightness: Float
        let warmth: Float
    }

    struct Enclosure: Codable, Sendable {
        let ceiling: Bool
        let openWalls: Bool
    }

    let version: Int
    let furniture: [FurnitureItem]
    let wallMaterials: [WallMaterial]
    let floorMaterial: FloorMaterial?
    let lighting: Lighting?
    let enclosure: Enclosure
    let snappingEnabled: Bool
}
