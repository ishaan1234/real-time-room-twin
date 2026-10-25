import Foundation

/// How the app and RoomTwin Viewer on the Mac find each other: Multipeer
/// Connectivity over Wi-Fi or Bluetooth, no server or address needed. The
/// app browses, the Viewer advertises and accepts, and models travel as
/// USDZ resources.
enum ModelTransfer {
    /// Bonjour type `_roomtwin-model._tcp`; both Info.plists list it under NSBonjourServices.
    static let serviceType = "roomtwin-model"
}
