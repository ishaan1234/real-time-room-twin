import SceneKit

/// Finds a model for a spoken request. Poly Haven comes first when it has a
/// close match of about the right size (within 2× of the height the agent
/// expects), as its models are CC0, true to scale and consistently oriented.
/// Otherwise Sketchfab, which has far more but needs a credit and is scaled
/// to the expected height. Poly Haven's nearest is the last resort.
enum FurnitureSearch {
    enum Source: String {
        case any, polyHaven = "polyhaven", sketchfab
    }

    struct Found {
        let model: SCNNode
        /// The credit to show, for licences that need one.
        let credit: String?
        let source: String
    }

    @MainActor
    static func find(_ query: String, height: Float, from source: Source = .any) async throws -> Found {
        let polyHaven = source == .sketchfab ? [] : try await PolyHaven.models(matching: query)
        let sized = polyHaven.filter { $0.height.map { $0 > height / 2 && $0 < height * 2 } ?? true }
        if let best = source == .polyHaven ? sized.first ?? polyHaven.first
                                           : sized.first(where: { PolyHaven.isCloseMatch($0, for: query) }) {
            return Found(model: try await PolyHaven.model(best), credit: nil, source: "Poly Haven")
        }
        if source != .polyHaven, Sketchfab.token != nil {
            do {
                if let best = try await Sketchfab.models(matching: query).first {
                    return Found(model: try await Sketchfab.model(best, height: height), credit: best.attribution,
                                 source: "Sketchfab")
                }
            } catch where !polyHaven.isEmpty {
                // Fall back to Poly Haven's nearest.
            }
        }
        guard let nearest = sized.first ?? polyHaven.first else {
            throw PreviewScene.PlacementError(errorDescription: "Couldn't find a model of \(query).")
        }
        return Found(model: try await PolyHaven.model(nearest), credit: nil, source: "Poly Haven")
    }
}
