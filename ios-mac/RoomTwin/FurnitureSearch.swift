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
                if let best = bestSketchfabModel(in: try await Sketchfab.models(matching: query), for: query) {
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

    /// Sketchfab relevance is generally good, but the first lightweight USDZ
    /// is not always the best visual match. Keep the API order as a tiebreaker
    /// while preferring titles that retain the user's noun and style words.
    /// This is especially important for requests such as "modern flat-screen
    /// television", where a vintage CRT should not win merely because it is
    /// the first downloadable result.
    private static func bestSketchfabModel(in models: [Sketchfab.Model], for query: String) -> Sketchfab.Model? {
        guard !models.isEmpty else { return nil }
        let ignored: Set<String> = ["a", "an", "and", "for", "of", "the", "with"]
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
                .subtracting(ignored)
        }
        let wanted = words(query)
        let wantsModernScreen = !wanted.isDisjoint(with: ["modern", "flat", "flatscreen", "smart", "led", "lcd"])
        let televisionWords: Set<String> = ["television", "tv", "screen", "display", "monitor"]
        let wantsTelevision = !wanted.isDisjoint(with: televisionWords)
        let preferredScreenWords: Set<String> = ["modern", "flat", "flatscreen", "smart", "led", "lcd", "oled"]
        let datedScreenWords: Set<String> = ["antique", "console", "crt", "old", "retro", "tube", "vintage"]

        return models.enumerated().max { lhs, rhs in
            func score(_ item: (offset: Int, element: Sketchfab.Model)) -> Int {
                let title = words(item.element.name)
                var value = wanted.intersection(title).count * 12
                // Common catalogue synonyms should reinforce the requested
                // object kind even when the literal words differ.
                if wantsTelevision, !title.isDisjoint(with: televisionWords) { value += 20 }
                if wantsModernScreen {
                    value += title.intersection(preferredScreenWords).count * 12
                    value -= title.intersection(datedScreenWords).count * 25
                }
                // Preserve Sketchfab relevance ordering when names score alike.
                value += max(0, 10 - item.offset)
                return value
            }
            return score(lhs) < score(rhs)
        }?.element
    }
}
