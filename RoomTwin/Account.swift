import SwiftUI

/// The signed-in user, through Supabase: username and password sign-in, and
/// the scanned objects they save to their account. It talks to Supabase's
/// REST API directly. The project URL and public key come from
/// supabase.json, which Accounts/setup_supabase.py writes from .env.local
/// into the app. The public key is meant to ship in apps: row-level security
/// (Accounts/schema.sql) limits each user to their own rows and files.
///
/// Supabase signs in by email, so a username becomes a placeholder address
/// that never receives mail; that's why the project has email confirmation
/// turned off.
@MainActor
final class Account: ObservableObject {
    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var userID: String
        var username: String
    }

    struct SavedObject: Identifiable, Decodable {
        let id: UUID
        let name: String
        let modelPath: String
        let thumbPath: String?
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case id, name
            case modelPath = "model_path", thumbPath = "thumb_path", createdAt = "created_at"
        }
    }

    struct SavedRoomLayout: Identifiable, Decodable {
        let id: UUID
        let name: String
        let modelPath: String
        let plyPath: String
        let jsonPath: String
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case id, name
            case modelPath = "model_path", plyPath = "ply_path", jsonPath = "json_path", createdAt = "created_at"
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    @Published private(set) var session: Session?

    static let config: (url: URL, key: String)? = {
        guard let file = Bundle.main.url(forResource: "supabase", withExtension: "json"),
              let json = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] }),
              let url = json["url"].flatMap(URL.init(string:)), let key = json["anonKey"] else { return nil }
        return (url, key)
    }()

    private static let sessionKey = "account-session"
    private static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyObjects")
    private static let roomCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SavedRooms")

    init() {
        session = Keychain.read(Self.sessionKey).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
    }

    // MARK: Signing in

    func signIn(username: String, password: String) async throws {
        let email = try Self.email(for: username)
        try await start(try await call("auth/v1/token?grant_type=password", json: ["email": email, "password": password],
                                       signedIn: false), username: username)
    }

    func signUp(username: String, password: String) async throws {
        let email = try Self.email(for: username)
        guard password.count >= 6 else { throw Failure(errorDescription: "Use a password of at least 6 characters.") }
        let reply = try await call("auth/v1/signup", json: ["email": email, "password": password,
                                                            "data": ["username": username]], signedIn: false)
        guard (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["access_token"] != nil else {
            throw Failure(errorDescription: "The account was made but needs email confirmation. Turn off "
                          + "Authentication › Email › Confirm email in Supabase, then log in.")
        }
        try await start(reply, username: username)
    }

    func signOut() {
        let token = session?.accessToken
        session = nil
        Keychain.write(Self.sessionKey, nil)
        try? FileManager.default.removeItem(at: Self.cache)
        try? FileManager.default.removeItem(at: Self.roomCache)
        if let token {
            Task { _ = try? await call("auth/v1/logout", method: "POST", bearer: token) }
        }
    }

    private static func email(for username: String) throws -> String {
        let name = username.lowercased().trimmingCharacters(in: .whitespaces)
        guard (3...24).contains(name.count), name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
              name.allSatisfy(\.isASCII) else {
            throw Failure(errorDescription: "Use 3–24 letters, numbers, dots, dashes or underscores for the username.")
        }
        return "\(name)@users.roomtwin.app"
    }

    private func start(_ reply: Data, username: String) async throws {
        guard let json = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String,
              let user = (json["user"] as? [String: Any])?["id"] as? String else {
            throw Failure(errorDescription: "Supabase sent back something unexpected.")
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let display = ((json["user"] as? [String: Any])?["user_metadata"] as? [String: Any])?["username"] as? String
        let session = Session(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn),
                              userID: user, username: display ?? username)
        self.session = session
        Keychain.write(Self.sessionKey, try JSONEncoder().encode(session))
    }

    /// A fresh access token, renewing the session if it's about to expire.
    private func accessToken() async throws -> String {
        guard let session else { throw Failure(errorDescription: "Log in first.") }
        if session.expiresAt > Date().addingTimeInterval(60) { return session.accessToken }
        do {
            let reply = try await call("auth/v1/token?grant_type=refresh_token",
                                       json: ["refresh_token": session.refreshToken], signedIn: false)
            try await start(reply, username: session.username)
            return self.session!.accessToken
        } catch {
            signOut()
            throw Failure(errorDescription: "You've been logged out. Log in again.")
        }
    }

    // MARK: Saved objects

    /// The user's saved objects, newest first.
    func objects() async throws -> [SavedObject] {
        let data = try await call("rest/v1/objects?select=id,name,model_path,thumb_path,created_at&order=created_at.desc")
        return try JSONDecoder().decode([SavedObject].self, from: data)
    }

    /// Uploads a scanned model (USDZ) and its picture, and lists it in the account.
    func save(model: URL, thumbnail: UIImage?, name: String) async throws {
        guard let user = session?.userID else { throw Failure(errorDescription: "Log in first.") }
        let folder = "\(user)/\(UUID().uuidString.lowercased())"
        try await call("storage/v1/object/objects/\(folder)/model.usdz", method: "POST",
                       body: try Data(contentsOf: model), contentType: "model/vnd.usdz+zip")
        var thumbPath: String?
        if let jpeg = thumbnail.flatMap(Self.smallJPEG) {
            try await call("storage/v1/object/objects/\(folder)/thumb.jpg", method: "POST", body: jpeg, contentType: "image/jpeg")
            thumbPath = "\(folder)/thumb.jpg"
        }
        var row: [String: Any] = ["name": name, "model_path": "\(folder)/model.usdz"]
        row["thumb_path"] = thumbPath
        try await call("rest/v1/objects", method: "POST", json: row)
    }

    func delete(_ object: SavedObject) async throws {
        try await call("rest/v1/objects?id=eq.\(object.id.uuidString.lowercased())", method: "DELETE")
        try await call("storage/v1/object/objects", method: "DELETE",
                       json: ["prefixes": [object.modelPath] + (object.thumbPath.map { [$0] } ?? [])])
    }

    /// The model file, downloaded once and then kept on the phone.
    func modelFile(for object: SavedObject) async throws -> URL {
        let file = Self.cache.appendingPathComponent("\(object.id.uuidString).usdz")
        if !FileManager.default.fileExists(atPath: file.path) {
            let data = try await call("storage/v1/object/authenticated/objects/\(object.modelPath)")
            try FileManager.default.createDirectory(at: Self.cache, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        return file
    }

    func thumbnail(for object: SavedObject) async -> UIImage? {
        guard let path = object.thumbPath else { return nil }
        return (try? await call("storage/v1/object/authenticated/objects/\(path)")).flatMap(UIImage.init(data:))
    }

    // MARK: Saved room layouts

    func roomLayouts() async throws -> [SavedRoomLayout] {
        let data = try await call("rest/v1/room_layouts?select=id,name,model_path,ply_path,json_path,created_at&order=created_at.desc")
        return try JSONDecoder().decode([SavedRoomLayout].self, from: data)
    }

    /// Uploads the edited room model together with the raw PLY and RoomPlan's
    /// semantic JSON, then creates the row owned by the signed-in user.
    func saveRoomLayout(model: URL, ply: URL, json: URL, name: String) async throws {
        guard let user = session?.userID else { throw Failure(errorDescription: "Log in first.") }
        let folder = "\(user)/\(UUID().uuidString.lowercased())"
        let modelPath = "\(folder)/room.usdz"
        let plyPath = "\(folder)/room.ply"
        let jsonPath = "\(folder)/room.json"
        try await call("storage/v1/object/room-layouts/\(modelPath)", method: "POST",
                       body: try Data(contentsOf: model), contentType: "model/vnd.usdz+zip")
        try await call("storage/v1/object/room-layouts/\(plyPath)", method: "POST",
                       body: try Data(contentsOf: ply), contentType: "application/octet-stream")
        try await call("storage/v1/object/room-layouts/\(jsonPath)", method: "POST",
                       body: try Data(contentsOf: json), contentType: "application/json")
        try await call("rest/v1/room_layouts", method: "POST",
                       json: ["name": name, "model_path": modelPath, "ply_path": plyPath, "json_path": jsonPath])
    }

    /// The room's USDZ and RoomPlan JSON, downloaded once and then kept on the phone.
    func roomFiles(for layout: SavedRoomLayout) async throws -> (model: URL, json: URL) {
        let folder = Self.roomCache.appendingPathComponent(layout.id.uuidString)
        let model = folder.appendingPathComponent("room.usdz"), json = folder.appendingPathComponent("room.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, path) in [(model, layout.modelPath), (json, layout.jsonPath)]
        where !FileManager.default.fileExists(atPath: file.path) {
            try await call("storage/v1/object/authenticated/room-layouts/\(path)").write(to: file, options: .atomic)
        }
        return (model, json)
    }

    func delete(_ layout: SavedRoomLayout) async throws {
        try await call("rest/v1/room_layouts?id=eq.\(layout.id.uuidString.lowercased())", method: "DELETE")
        try await call("storage/v1/object/room-layouts", method: "DELETE",
                       json: ["prefixes": [layout.modelPath, layout.plyPath, layout.jsonPath]])
        try? FileManager.default.removeItem(at: Self.roomCache.appendingPathComponent(layout.id.uuidString))
    }

    private static func smallJPEG(_ image: UIImage) -> Data? {
        let scale = min(1, 480 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.75)
    }

    // MARK: Requests

    /// One request to Supabase. Signed in, it carries the user's token, so
    /// row-level security sees who's asking.
    @discardableResult
    private func call(_ path: String, method: String? = nil, json: Any? = nil, body: Data? = nil,
                      contentType: String? = nil, signedIn: Bool = true, bearer: String? = nil) async throws -> Data {
        guard let config = Self.config, let url = URL(string: path, relativeTo: config.url) else {
            throw Failure(errorDescription: "Accounts aren't set up in this build. Run python3 Accounts/setup_supabase.py on the Mac and rebuild.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method ?? (json == nil && body == nil ? "GET" : "POST")
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        // Only a user's token goes in Authorization: newer publishable keys aren't JWTs.
        if let token = signedIn ? try await accessToken() : bearer {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (reply?["msg"] ?? reply?["error_description"] ?? reply?["message"] ?? reply?["error"]) as? String
            throw Failure(errorDescription: Self.plain(message) ?? "Supabase said no (HTTP \(status)).")
        }
        return data
    }

    /// Supabase's messages in this app's terms.
    private static func plain(_ message: String?) -> String? {
        switch message {
        case "Invalid login credentials": "Wrong username or password."
        case "User already registered": "That username is taken."
        default: message
        }
    }
}
