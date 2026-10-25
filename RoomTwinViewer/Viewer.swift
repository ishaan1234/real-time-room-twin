import AppKit
import MultipeerConnectivity
import SwiftUI

/// Waits for models from the RoomTwin app and lands them on a transparent
/// layer over the screen. Models are saved in ~/Downloads/RoomTwin; one sent
/// again isn't saved twice, it shakes if it's on screen and lands again if not.
final class Viewer: NSObject, ObservableObject {
    static let shared = Viewer()

    struct Arrival: Equatable {
        let model: URL
        let from: String
        let id = UUID()
    }

    /// The model on screen, if any.
    @Published private(set) var arrival: Arrival?
    /// Names of the connected phones.
    @Published private(set) var phones: [String] = []
    @Published private(set) var lastModel: URL?
    /// Bumped to shake the model on screen.
    @Published private(set) var shakes = 0

    let folder: URL = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return downloads.appendingPathComponent("RoomTwin")
    }()

    private let peer = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    private lazy var session: MCSession = {
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }()
    private lazy var advertiser: MCNearbyServiceAdvertiser = {
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: ModelTransfer.serviceType)
        advertiser.delegate = self
        return advertiser
    }()
    private var window: OverlayWindow?

    func start() {
        window = OverlayWindow(content: LandingView(viewer: self))
        advertiser.startAdvertisingPeer()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.arrival != nil else { return event }   // Esc
            self?.dismiss()
            return nil
        }
    }

    func land(_ model: URL, from phone: String) {
        lastModel = model
        window?.cover(NSScreen.main)
        window?.ignoresMouseEvents = false
        window?.orderFrontRegardless()
        window?.makeKey()
        arrival = Arrival(model: model, from: phone)
    }

    /// "Already here": the model on screen shakes its head.
    func shake() {
        window?.orderFrontRegardless()
        withAnimation(.linear(duration: 0.6)) { shakes += 1 }
    }

    func dismiss() {
        withAnimation(.easeIn(duration: 0.35)) { arrival = nil }
        // Let clicks through again once it has gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if self?.arrival == nil { self?.window?.ignoresMouseEvents = true }
        }
    }

    /// Moves a received file into the models folder under a name nothing else
    /// has, unless the same file is already there under the sender's name.
    private func keep(_ received: URL, named name: String) throws -> (model: URL, isDuplicate: Bool) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only the last component of the sender's name, so it can't point elsewhere.
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent(base).appendingPathExtension("usdz")
        if FileManager.default.contentsEqual(atPath: received.path, andPath: destination.path) {
            return (destination, true)
        }
        var copy = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) \(copy)").appendingPathExtension("usdz")
            copy += 1
        }
        try FileManager.default.moveItem(at: received, to: destination)
        return (destination, false)
    }
}

extension Viewer: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension Viewer: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { self.phones = session.connectedPeers.map(\.displayName) }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {
        // The received file is deleted when this returns, so move it first.
        guard let localURL, error == nil, let (model, isDuplicate) = try? keep(localURL, named: resourceName) else {
            NSLog("RoomTwin Viewer: couldn't receive \(resourceName): \(String(describing: error))")
            return
        }
        DispatchQueue.main.async {
            if isDuplicate && self.arrival?.model == model {
                self.shake()
            } else {
                self.land(model, from: peerID.displayName)
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {}
}

/// A borderless, see-through window over the whole screen. It lets clicks
/// through to the apps underneath while nothing has landed on it.
final class OverlayWindow: NSPanel {
    init<Content: View>(content: Content) {
        super.init(contentRect: NSScreen.main?.frame ?? .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: content)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }

    func cover(_ screen: NSScreen?) {
        if let screen { setFrame(screen.frame, display: true) }
    }
}
