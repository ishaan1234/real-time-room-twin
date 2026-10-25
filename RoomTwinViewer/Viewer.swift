import AppKit
import MultipeerConnectivity
import SwiftUI

/// Waits for models from the RoomTwin app and lands them on a transparent
/// layer over the screen. Models are saved in ~/Downloads/RoomTwin; one sent
/// again isn't saved twice, it shakes if it's on screen and lands again if not.
/// A preloaded model waits on the layer out of sight, loaded, until the phone
/// is swiped and says to show it.
final class Viewer: NSObject, ObservableObject {
    static let shared = Viewer()

    struct Arrival: Equatable, Identifiable {
        let model: URL
        let from: String
        var id = UUID().uuidString
    }

    /// The model on screen, if any.
    @Published private(set) var arrival: Arrival?
    /// A preloaded model, waiting just below the screen. Its ID is the phone's preload ID.
    @Published private(set) var staged: Arrival?
    /// The phone to tell when the staged model is ready.
    private var stagedPeer: MCPeerID?
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
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ModelTransfer.discoveryInfo,
                                                   serviceType: ModelTransfer.serviceType)
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

    /// Everything on the layer: the model on screen and the one staged.
    var models: [Arrival] {
        [arrival, staged].compactMap { $0 }
    }

    func land(_ model: URL, from phone: String) {
        land(Arrival(model: model, from: phone))
    }

    private func land(_ arrival: Arrival) {
        lastModel = arrival.model
        window?.cover(NSScreen.main)
        window?.ignoresMouseEvents = false
        window?.orderFrontRegardless()
        window?.makeKey()
        self.arrival = arrival
    }

    /// Puts a preloaded model on the layer out of sight, where it loads;
    /// `stagedIsReady` then tells the phone.
    private func stage(_ model: URL, id: String, from peer: MCPeerID) {
        staged = Arrival(model: model, from: peer.displayName, id: id)
        stagedPeer = peer
    }

    /// Called by the landing view once the staged model is loaded and on the GPU.
    func stagedIsReady(_ id: String) {
        guard staged?.id == id, let stagedPeer else { return }
        tell(stagedPeer, .ready, id)
    }

    /// The phone was swiped: the staged model flies up straight away.
    private func show(_ id: String, for peer: MCPeerID) {
        if arrival?.id == id {
            shake()
        } else if let staged, staged.id == id {
            self.staged = nil
            stagedPeer = nil
            land(staged)
        } else {
            tell(peer, .missing, id)
        }
    }

    private func tell(_ peer: MCPeerID, _ kind: ModelTransfer.Message.Kind, _ id: String) {
        guard let data = try? JSONEncoder().encode(ModelTransfer.Message(kind: kind, id: id)) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
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
        let (name, preloadID) = ModelTransfer.parse(resourceName: resourceName)
        guard let localURL, error == nil, let (model, isDuplicate) = try? keep(localURL, named: name) else {
            NSLog("RoomTwin Viewer: couldn't receive \(resourceName): \(String(describing: error))")
            return
        }
        DispatchQueue.main.async {
            if let preloadID {
                self.stage(model, id: preloadID, from: peerID)
            } else if isDuplicate && self.arrival?.model == model {
                self.shake()
            } else {
                self.land(model, from: peerID.displayName)
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(ModelTransfer.Message.self, from: data),
              message.kind == .show else { return }
        DispatchQueue.main.async { self.show(message.id, for: peerID) }
    }
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
