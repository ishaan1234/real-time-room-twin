import Foundation

/// How the app and RoomTwin Viewer on the Mac find each other: Multipeer
/// Connectivity over Wi-Fi or Bluetooth, no server or address needed. The
/// app browses, the Viewer advertises and accepts, and models travel as
/// USDZ resources.
///
/// A model can also be preloaded: sent ahead of its swipe, loaded by the
/// Viewer out of sight, and then shown by a short `show` message, so it
/// lands the moment it's swiped.
enum ModelTransfer {
    /// Bonjour type `_roomtwin-model._tcp`; both Info.plists list it under NSBonjourServices.
    static let serviceType = "roomtwin-model"

    /// What a Viewer advertises when it can take preloads. An older one
    /// shows a preload as soon as it arrives and never says it's ready, so
    /// the phone only offers Pre-load to a Mac advertising this.
    static let discoveryInfo = ["preload": "1"]

    static func canPreload(_ info: [String: String]?) -> Bool {
        info?["preload"] == discoveryInfo["preload"]
    }

    /// A short message between the phone and the Mac, sent as JSON data.
    struct Message: Codable {
        enum Kind: String, Codable {
            /// Phone to Mac: show the model preloaded as `id` now.
            case show
            /// Mac to phone: the model preloaded as `id` is loaded and can be shown at once.
            case ready
            /// Mac to phone: nothing is preloaded as `id` (the Viewer restarted, or
            /// another model took its place), so send the file instead.
            case missing
        }

        let kind: Kind
        let id: String
    }

    /// A resource's name: the model's file name, prefixed with its preload ID
    /// when it's sent ahead of its swipe.
    static func resourceName(_ name: String, preloadID: String?) -> String {
        preloadID.map { "\(preloadPrefix)\($0)/\(name)" } ?? name
    }

    /// The model's file name and preload ID from a resource's name.
    static func parse(resourceName: String) -> (name: String, preloadID: String?) {
        guard resourceName.hasPrefix(preloadPrefix) else { return (resourceName, nil) }
        let rest = resourceName.dropFirst(preloadPrefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return (resourceName, nil) }
        return (String(rest[rest.index(after: slash)...]), String(rest[..<slash]))
    }

    private static let preloadPrefix = "preload/"
}
