import Foundation
import SceneKit

/// Furniture and wall textures from Poly Haven (polyhaven.com), all CC0,
/// fetched through its public API. Everything is at 1k: a model with its
/// textures is about a megabyte, so it arrives in a second or two. The API's
/// terms ask for a User-Agent naming the app and a visible "Powered by Poly
/// Haven" credit wherever its content shows.
enum PolyHaven {
    struct Asset {
        let id: String
        let name: String
        let categories: [String]
        let tags: [String]
        /// In millimetres. Models: width, depth, height (Blender's x, y, z).
        /// Textures: the width and height the image covers.
        let dimensions: [Float]?

        /// A model's real height in metres.
        var height: Float? { dimensions.flatMap { $0.count == 3 ? $0[2] / 1000 : nil } }
    }

    static let userAgent = "RoomTwin/1.0 (iOS app)"
    static let credit = "Powered by Poly Haven"
    private static let api = URL(string: "https://api.polyhaven.com")!
    private static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PolyHaven")
    @MainActor private static var catalogs: [String: [Asset]] = [:]

    // MARK: Searching

    /// Models matching a request like "floor lamp" or "wooden dining table",
    /// best first. Indoor furniture wins ties over garden and street props.
    @MainActor
    static func models(matching query: String) async throws -> [Asset] {
        rank(try await catalog("models"), query,
             prefer: ["furniture", "seating", "table", "lighting", "decorative", "shelves", "appliances",
                      "electronics", "plants", "containers", "storage", "bed"],
             avoid: misplaced)
    }

    /// Textures for walls matching a request like "red brick" or "white plaster".
    @MainActor
    static func wallTextures(matching query: String) async throws -> [Asset] {
        rank(try await catalog("textures"), query,
             prefer: ["wall", "indoor", "plaster", "plaster-concrete", "brick", "wood", "tiles", "fabric", "clean"],
             avoid: [])
    }

    @MainActor
    private static func catalog(_ type: String) async throws -> [Asset] {
        if let cached = catalogs[type] { return cached }
        let data = try await fetch(api.appendingPathComponent("assets").appending(queryItems: [.init(name: "t", value: type)]))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] ?? [:]
        let assets = json.map { id, info in
            Asset(id: id, name: info["name"] as? String ?? id, categories: info["categories"] as? [String] ?? [],
                  tags: info["tags"] as? [String] ?? [],
                  dimensions: (info["dimensions"] as? [NSNumber])?.map(\.floatValue))
        }
        catalogs[type] = assets
        return assets
    }

    private static let synonyms = ["couch": "sofa", "settee": "sofa", "desk": "table", "bookcase": "shelf",
                                   "bookshelf": "shelf", "shelving": "shelf", "tv": "television", "light": "lamp",
                                   "bedside": "nightstand", "wallpaper": "wall", "paint": "painted", "wooden": "wood"]
    /// Models that don't stand in a room: hung from the ceiling or a wall,
    /// or outdoors. They rank low unless asked for by name.
    private static let misplaced: Set<String> = ["hanging", "ceiling", "chandelier", "sconce", "mounted", "wall",
                                                 "outdoor", "exterior", "street", "lamppost", "forest", "field",
                                                 "woodland", "karoo", "desert", "garden", "shrub"]
    private static let filler: Set<String> = ["a", "an", "the", "some", "with", "of", "and", "for", "in", "on",
                                              "please", "one", "new", "nice", "kind"]

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map { word in
            var w = String(word)
            if w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") { w.removeLast() }
            return synonyms[w] ?? w
        }
    }

    /// Scores each asset by how many of the request's words it has, in its
    /// name (most), tags or categories. The last word is usually the thing
    /// itself ("lamp" in "tall floor lamp"), so it counts double. Ceiling and
    /// outdoor things (`avoid`), and anything over 3 m (trees, scatter sets), drop.
    private static func rank(_ assets: [Asset], _ query: String, prefer: Set<String>, avoid: Set<String>) -> [Asset] {
        let wanted = words(query).filter { !filler.contains($0) }
        guard !wanted.isEmpty else { return [] }
        let scored = assets.map { asset -> (Asset, Float) in
            let name = Set(words(asset.name)), tags = Set(asset.tags.flatMap(words))
            let categories = Set(asset.categories.flatMap(words))
            var score: Float = 0
            for (i, word) in wanted.enumerated() {
                let weight: Float = i == wanted.count - 1 ? 2 : 1
                score += weight * (name.contains(word) ? 3 : tags.contains(word) ? 2 : categories.contains(word) ? 1.5 : 0)
            }
            if score > 0 && !prefer.isDisjoint(with: asset.categories) { score += 1 }
            let unwanted = avoid.subtracting(wanted)
            if !unwanted.isDisjoint(with: name.union(tags).union(categories)) { score -= 3 }
            if (asset.dimensions?.max() ?? 0) > 3000 { score -= 3 }
            return (asset, score)
        }
        // The thing itself must match, not just an adjective.
        let thing = wanted.last!
        return scored.filter { asset, score in
            score > 0 && (words(asset.name) + asset.tags.flatMap(words) + asset.categories.flatMap(words)).contains(thing)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
        .map(\.0)
    }

    /// Whether every word of the request is in the asset's name, tags or
    /// categories: "dining table" is, "red velvet sofa" isn't.
    static func isCloseMatch(_ asset: Asset, for query: String) -> Bool {
        let has = Set(words(asset.name) + asset.tags.flatMap(words) + asset.categories.flatMap(words))
        return words(query).filter { !filler.contains($0) }.allSatisfy(has.contains)
    }

    // MARK: Downloading

    /// The model as furniture: upright on y = 0, front towards +z. Files are
    /// cached, so a second request for it doesn't download again.
    static func model(_ asset: Asset) async throws -> SCNNode {
        let folder = cache.appendingPathComponent("models/\(asset.id)")
        let usd = folder.appendingPathComponent("\(asset.id)_1k.usdc")
        if !FileManager.default.fileExists(atPath: usd.path) {
            let files = try JSONSerialization.jsonObject(with: try await fetch(api.appendingPathComponent("files/\(asset.id)")))
            guard let entry = ((((files as? [String: Any])?["usd"] as? [String: Any])?["1k"] as? [String: Any])?["usd"])
                    as? [String: Any],
                  let link = (entry["url"] as? String).flatMap(URL.init(string:)) else {
                throw URLError(.resourceUnavailable)
            }
            // The textures it needs, except EXR maps: they're big and only add fine surface detail.
            let textures = (entry["include"] as? [String: [String: Any]] ?? [:]).compactMap { path, info -> (URL, URL)? in
                guard !path.hasSuffix(".exr"), let url = (info["url"] as? String).flatMap(URL.init(string:)) else { return nil }
                return (url, folder.appendingPathComponent(path))
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (url, file) in textures {
                    group.addTask { try await download(url, to: file) }
                }
                try await group.waitForAll()
            }
            // The model file last, so its presence means the download is complete.
            try await download(link, to: usd)
        }
        let height = asset.dimensions.flatMap { $0.count == 3 ? $0[2] / 1000 : nil }
        let model = try await Task.detached { try ModelLoader.load(usd, height: height) }.value
        model.name = asset.name
        return model
    }

    /// A wall texture's colour map, and the size in metres it covers.
    static func wallTexture(_ asset: Asset) async throws -> (image: URL, size: SIMD2<Float>) {
        let image = cache.appendingPathComponent("textures/\(asset.id)/diff_1k.jpg")
        if !FileManager.default.fileExists(atPath: image.path) {
            let files = try JSONSerialization.jsonObject(with: try await fetch(api.appendingPathComponent("files/\(asset.id)")))
            guard let link = (((((files as? [String: Any])?["Diffuse"] as? [String: Any])?["1k"] as? [String: Any])?["jpg"]
                    as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) else {
                throw URLError(.resourceUnavailable)
            }
            try await download(link, to: image)
        }
        let size = asset.dimensions.flatMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) / 1000 : nil } ?? SIMD2(2, 2)
        return (image, size)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func download(_ url: URL, to file: URL) async throws {
        let data = try await fetch(url)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
