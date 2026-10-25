import SwiftUI

/// RoomTwin Viewer: lives in the menu bar and waits, invisibly, for models
/// swiped up from the RoomTwin app on the iPhone.
@main
struct RoomTwinViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var viewer = Viewer.shared

    var body: some Scene {
        MenuBarExtra("RoomTwin Viewer", systemImage: "cube.transparent") {
            Text(viewer.phones.isEmpty ? "Waiting for RoomTwin on your iPhone"
                                       : "Connected to \(viewer.phones.joined(separator: ", "))")
            Divider()
            Button("Show Last Model") {
                if let model = viewer.lastModel { viewer.land(model, from: "this Mac") }
            }
            .disabled(viewer.lastModel == nil)
            Button("Open Models Folder") {
                try? FileManager.default.createDirectory(at: viewer.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(viewer.folder)
            }
            Divider()
            Button("Quit RoomTwin Viewer") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Viewer.shared.start()
    }
}
