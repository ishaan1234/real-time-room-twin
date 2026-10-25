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
        let editsPath: String?
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case id, name
            case modelPath = "model_path", plyPath = "ply_path", jsonPath = "json_path"
            case editsPath = "edits_path", createdAt = "created_at"
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    @Published private(set) var session: Session?
    @Published private(set) var roomDriveFolderName: String?

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
    private static let roomDriveBookmarkKey = "room-drive-folder"
    private static let roomDrivePrefix = "drive:"
    private static let roomDriveDirectory = "RoomTwin"

    init() {
        session = Keychain.read(Self.sessionKey).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        if let bookmark = UserDefaults.standard.data(forKey: Self.roomDriveBookmarkKey),
           let folder = try? Self.resolveRoomDriveFolder(bookmark) {
            roomDriveFolderName = folder.lastPathComponent
        }
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

    // MARK: Google Drive room folder

    /// Stores durable permission to a folder chosen from the iOS Files
    /// picker. Choosing a folder under Google Drive lets RoomTwin write whole
    /// room files there without shipping a Google API secret in the app.
    func connectRoomDriveFolder(_ folder: URL) throws {
        guard folder.startAccessingSecurityScopedResource() else {
            throw Failure(errorDescription: "RoomTwin could not access that folder. Choose it again from Google Drive in Files.")
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        let root = folder.appendingPathComponent(Self.roomDriveDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData(options: .minimalBookmark,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Self.roomDriveBookmarkKey)
        roomDriveFolderName = folder.lastPathComponent
    }

    func disconnectRoomDriveFolder() {
        UserDefaults.standard.removeObject(forKey: Self.roomDriveBookmarkKey)
        roomDriveFolderName = nil
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
        let data = try await call("rest/v1/room_layouts?select=id,name,model_path,ply_path,json_path,edits_path,created_at&order=created_at.desc")
        return try JSONDecoder().decode([SavedRoomLayout].self, from: data)
    }

    /// Writes complete room files to the user's selected Google Drive folder,
    /// then stores their relative paths and ownership record in Supabase.
    func saveRoomLayout(model: URL, ply: URL, json: URL, edits: URL, name: String) async throws {
        guard let user = session?.userID else { throw Failure(errorDescription: "Log in first.") }
        let bookmark = try roomDriveBookmark()
        let folder = "\(user)/\(UUID().uuidString.lowercased())"
        do {
            try await Task.detached(priority: .utility) {
                try Self.withRoomDriveFolder(bookmark) { root in
                    let destination = root.appendingPathComponent(folder, isDirectory: true)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try Self.copyRoomFile(model, to: destination.appendingPathComponent("room.usdz"))
                    try Self.copyRoomFile(ply, to: destination.appendingPathComponent("room.ply"))
                    try Self.copyRoomFile(json, to: destination.appendingPathComponent("room.json"))
                    try Self.copyRoomFile(edits, to: destination.appendingPathComponent("room-edits.json"))
                }
            }.value
            try await call("rest/v1/room_layouts", method: "POST",
                           json: ["name": name,
                                  "model_path": Self.roomDrivePrefix + "\(folder)/room.usdz",
                                  "ply_path": Self.roomDrivePrefix + "\(folder)/room.ply",
                                  "json_path": Self.roomDrivePrefix + "\(folder)/room.json",
                                  "edits_path": Self.roomDrivePrefix + "\(folder)/room-edits.json"])
        } catch {
            try? await Task.detached(priority: .utility) {
                try Self.withRoomDriveFolder(bookmark) { root in
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(folder))
                }
            }.value
            throw error
        }
    }

    /// The room's USDZ and RoomPlan JSON, downloaded once and then kept on the phone.
    func roomFiles(for layout: SavedRoomLayout) async throws -> (model: URL, json: URL, edits: URL?) {
        let folder = Self.roomCache.appendingPathComponent(layout.id.uuidString)
        let model = folder.appendingPathComponent("room.usdz"), json = folder.appendingPathComponent("room.json")
        let edits = layout.editsPath.map { _ in folder.appendingPathComponent("room-edits.json") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var downloads = [(model, layout.modelPath), (json, layout.jsonPath)]
        if let edits, let path = layout.editsPath { downloads.append((edits, path)) }
        for (file, path) in downloads where !FileManager.default.fileExists(atPath: file.path) {
            if let relative = Self.roomDriveRelativePath(path) {
                let bookmark = try roomDriveBookmark()
                try await Task.detached(priority: .utility) {
                    try Self.withRoomDriveFolder(bookmark) { root in
                        try Self.copyRoomFile(root.appendingPathComponent(relative), to: file)
                    }
                }.value
            } else {
                // Rooms saved by older builds remain readable.
                let data = try await call("storage/v1/object/authenticated/room-layouts/\(path)")
                try data.write(to: file, options: .atomic)
            }
        }
        return (model, json, edits)
    }

    func delete(_ layout: SavedRoomLayout) async throws {
        if let relative = Self.roomDriveRelativePath(layout.modelPath) {
            let bookmark = try roomDriveBookmark()
            let folder = URL(fileURLWithPath: relative).deletingLastPathComponent().path
            try await Task.detached(priority: .utility) {
                try Self.withRoomDriveFolder(bookmark) { root in
                    try FileManager.default.removeItem(at: root.appendingPathComponent(folder))
                }
            }.value
        } else {
            let objects = [layout.modelPath, layout.plyPath, layout.jsonPath]
                + (layout.editsPath.map { [$0] } ?? [])
            try await call("storage/v1/object/room-layouts", method: "DELETE",
                           json: ["prefixes": objects])
        }
        try await call("rest/v1/room_layouts?id=eq.\(layout.id.uuidString.lowercased())", method: "DELETE")
        try? FileManager.default.removeItem(at: Self.roomCache.appendingPathComponent(layout.id.uuidString))
    }

    private func roomDriveBookmark() throws -> Data {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.roomDriveBookmarkKey) else {
            throw Failure(errorDescription: "Choose a Google Drive folder from the account menu before saving a room.")
        }
        return bookmark
    }

    private nonisolated static func resolveRoomDriveFolder(_ bookmark: Data) throws -> URL {
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else {
            throw Failure(errorDescription: "Google Drive folder permission expired. Choose the folder again.")
        }
        return folder
    }

    private nonisolated static func withRoomDriveFolder<T>(_ bookmark: Data, body: (URL) throws -> T) throws -> T {
        let selected = try resolveRoomDriveFolder(bookmark)
        guard selected.startAccessingSecurityScopedResource() else {
            throw Failure(errorDescription: "Google Drive is unavailable. Open Drive in Files, then choose the folder again.")
        }
        defer { selected.stopAccessingSecurityScopedResource() }
        let root = selected.appendingPathComponent(roomDriveDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try body(root)
    }

    private nonisolated static func roomDriveRelativePath(_ path: String) -> String? {
        path.hasPrefix(roomDrivePrefix) ? String(path.dropFirst(roomDrivePrefix.count)) : nil
    }

    private nonisolated static func copyRoomFile(_ source: URL, to destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.copyItem(at: source, to: destination)
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
