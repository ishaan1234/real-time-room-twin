import Foundation
import SceneKit

/// Models from Sketchfab, for things Poly Haven doesn't have. Searching is
/// open; downloading needs a signed-in account, here the owner's API token,
/// which Voice/setup_agent.py hands to the phone once and the app keeps in
/// the Keychain. Models come as USDZ, in whatever units their author used,
/// so each is scaled to a height the voice agent estimates. Most are CC BY:
/// whoever sees them must be told the model's name, author and licence.
enum Sketchfab {
    struct Model {
        let uid: String
        let name: String
        let author: String
        let license: String

        /// The credit CC BY asks for.
        var attribution: String { "“\(name)” by \(author) (\(license)) on Sketchfab" }
    }

    private static let api = URL(string: "https://api.sketchfab.com/v3")!
    private static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sketchfab")
    /// Bigger downloads take too long to wait for mid-conversation.
    private static let largestDownload = 10_000_000
    private static let keychainKey = "sketchfab-token"
    private static let handoverFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sketchfab.json")

    /// The API token, moving it into the Keychain if the setup script has just dropped it off.
    static var token: String? {
        if let data = try? Data(contentsOf: handoverFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String], let token = json["token"] {
            Keychain.write(keychainKey, Data(token.utf8))
            try? FileManager.default.removeItem(at: handoverFile)
        }
        return Keychain.read(keychainKey).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Downloadable models matching `query` with a USDZ small enough to fetch quickly, most relevant first.
    static func models(matching query: String) async throws -> [Model] {
        let url = api.appendingPathComponent("search").appending(queryItems: [
            .init(name: "type", value: "models"), .init(name: "q", value: query),
            .init(name: "downloadable", value: "true"), .init(name: "count", value: "24"),
        ])
        let json = try JSONSerialization.jsonObject(with: try await fetch(url)) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []
        return results.compactMap { result in
            guard let uid = result["uid"] as? String, let name = result["name"] as? String,
                  let usdz = (result["archives"] as? [String: Any])?["usdz"] as? [String: Any],
                  let size = usdz["size"] as? Int, size <= largestDownload else { return nil }
            return Model(uid: uid, name: name,
                         author: (result["user"] as? [String: Any])?["username"] as? String ?? "unknown",
                         license: (result["license"] as? [String: Any])?["label"] as? String ?? "see Sketchfab")
        }
    }

    /// The model as furniture, `height` metres tall, upright on y = 0.
    static func model(_ model: Model, height: Float) async throws -> SCNNode {
        let file = cache.appendingPathComponent("\(model.uid).usdz")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let token else { throw Failure.noToken }
            var request = URLRequest(url: api.appendingPathComponent("models/\(model.uid)/download"))
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let links = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let link = ((links["usdz"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) else {
                throw Failure.downloadRefused((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            // A short-lived link to the file itself, which needs no token.
            let (usdz, _) = try await URLSession.shared.data(from: link)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try usdz.write(to: file, options: .atomic)
        }
        let node = try await Task.detached { try ModelLoader.load(file, fitHeight: height) }.value
        node.name = model.name
        return node
    }

    enum Failure: LocalizedError {
        case noToken, downloadRefused(Int)

        var errorDescription: String? {
            switch self {
            case .noToken: "Sketchfab isn't set up on this phone: run python3 Voice/setup_agent.py with SKETCHFAB_API_TOKEN in .env.local."
            case .downloadRefused(let status): "Sketchfab wouldn't hand over the model (HTTP \(status))."
            }
        }
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(PolyHaven.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
