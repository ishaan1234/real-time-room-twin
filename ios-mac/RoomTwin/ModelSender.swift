import MultipeerConnectivity
import UIKit

/// Finds RoomTwin Viewer on nearby Macs and sends them models. A model can
/// be preloaded first: the Macs load it out of sight and say when it's ready,
/// and then the swipe only has to tell them to show it.
final class ModelSender: NSObject, ObservableObject {
    enum PreloadState: Equatable {
        case none, loading, ready, failed(String)
    }

    /// A model sent to the Macs ahead of its swipe.
    private struct Preload {
        let model: URL
        let id: String
        let name: String
        /// Macs it's on its way to, or loading on.
        var pending: Set<MCPeerID>
        /// Macs that have it loaded, ready to show.
        var ready: Set<MCPeerID> = []
        /// Macs swiped to before it was ready there, to show it the moment it is.
        var showWhenReady: Set<MCPeerID> = []
        var failure: String?
    }

    /// Names of the Macs the phone is connected to.
    @Published private(set) var macs: [String] = []
    /// The Mac to name on screen: the last one connected, kept through a brief
    /// drop so buttons don't blink out under a finger, and cleared once it's
    /// gone from the network.
    @Published private(set) var knownMac: String?
    /// Macs whose Viewer is new enough to take preloads (see ModelTransfer.discoveryInfo).
    @Published private(set) var preloadingMacs = Set<MCPeerID>()
    /// The last send's outcome, for a short toast.
    @Published var status: String?
    @Published private var preload: Preload?

    private let peer = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session: MCSession = {
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }()
    private lazy var browser: MCNearbyServiceBrowser = {
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: ModelTransfer.serviceType)
        browser.delegate = self
        return browser
    }()
    private var isBrowsing = false
    private var isRestartingBrowser = false
    /// Macs invited that haven't connected or turned the phone down yet.
    private var invited = Set<MCPeerID>()

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        browser.startBrowsingForPeers()
    }

    func preloadState(for model: URL) -> PreloadState {
        guard let preload, preload.model == model else { return .none }
        if !preload.pending.isEmpty { return .loading }
        if !preload.ready.isEmpty { return .ready }
        return preload.failure.map(PreloadState.failed) ?? .none
    }

    /// Whether the Mac by this name can take preloads.
    func canPreload(on mac: String) -> Bool {
        preloadingMacs.contains { $0.displayName == mac }
    }

    /// Sends the model to every connected Mac that takes preloads, to load
    /// out of sight, so a swipe shows it at once.
    func preload(_ model: URL, name: String) {
        let targets = session.connectedPeers.filter { preloadingMacs.contains($0) }
        guard !targets.isEmpty else {
            status = session.connectedPeers.isEmpty ? "No Mac nearby. Open RoomTwin Viewer on your Mac."
                : "Update RoomTwin Viewer on your Mac to pre-load."
            return
        }
        Diagnostics.action("preload model on \(targets.map(\.displayName))")
        preload = Preload(model: model, id: UUID().uuidString, name: name, pending: [])
        for mac in targets { sendPreload(to: mac) }
    }

    /// Sends the preload to one Mac. If the connection drops on the way, it
    /// stays pending and goes again when the Mac reconnects.
    private func sendPreload(to mac: MCPeerID) {
        guard let preload else { return }
        let id = preload.id
        self.preload?.pending.insert(mac)
        session.sendResource(at: preload.model, withName: ModelTransfer.resourceName(preload.name, preloadID: id),
                             toPeer: mac) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.preload?.id == id else { return }
                if let error {
                    guard self.session.connectedPeers.contains(mac) else { return }
                    self.givePreloadUp(on: mac, "Couldn't reach \(mac.displayName): \(error.localizedDescription)")
                    return
                }
                // The Mac says when it has loaded it; it shouldn't take long.
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    guard self.preload?.id == id, self.preload?.pending.contains(mac) == true,
                          self.session.connectedPeers.contains(mac) else { return }
                    self.givePreloadUp(on: mac, "\(mac.displayName) didn't load it")
                }
            }
        }
    }

    private func givePreloadUp(on mac: MCPeerID, _ reason: String) {
        preload?.pending.remove(mac)
        preload?.showWhenReady.remove(mac)
        preload?.failure = reason
    }

    /// Shows the model on every connected Mac: at once where it's preloaded,
    /// as soon as it's ready where it's still loading, and by sending it
    /// everywhere else. False if no Mac is connected.
    @discardableResult
    func send(_ model: URL, name: String) -> Bool {
        let targets = session.connectedPeers
        guard !targets.isEmpty else {
            status = "No Mac nearby. Open RoomTwin Viewer on your Mac."
            return false
        }
        Diagnostics.action("send model to \(targets.map(\.displayName))")
        for mac in targets {
            if let preload, preload.model == model, preload.ready.contains(mac) {
                tell(mac, .show, preload.id)
                status = "Showing on \(mac.displayName)"
            } else if let preload, preload.model == model, preload.pending.contains(mac) {
                self.preload?.showWhenReady.insert(mac)
            } else {
                sendFile(model, name: name, to: mac)
            }
        }
        return true
    }

    private func sendFile(_ model: URL, name: String, to mac: MCPeerID) {
        session.sendResource(at: model, withName: name, toPeer: mac) { [weak self] error in
            DispatchQueue.main.async {
                self?.status = error.map { "Couldn't send to \(mac.displayName): \($0.localizedDescription)" }
                    ?? "Sent to \(mac.displayName)"
            }
        }
    }

    private func tell(_ mac: MCPeerID, _ kind: ModelTransfer.Message.Kind, _ id: String) {
        guard let data = try? JSONEncoder().encode(ModelTransfer.Message(kind: kind, id: id)) else { return }
        try? session.send(data, toPeers: [mac], with: .reliable)
    }

    private func received(_ message: ModelTransfer.Message, from mac: MCPeerID) {
        guard var preload, preload.id == message.id else { return }
        switch message.kind {
        case .ready:
            preload.pending.remove(mac)
            preload.ready.insert(mac)
            if preload.showWhenReady.remove(mac) != nil {
                tell(mac, .show, preload.id)
                status = "Showing on \(mac.displayName)"
            }
        case .missing:
            // The Viewer lost it, so the swipe sends the file after all.
            preload.ready.remove(mac)
            preload.pending.remove(mac)
            preload.showWhenReady.remove(mac)
            sendFile(preload.model, name: preload.name, to: mac)
        case .show:
            break
        }
        self.preload = preload
    }
}

extension ModelSender: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if ModelTransfer.canPreload(info) {
                self.preloadingMacs.insert(peerID)
            } else {
                self.preloadingMacs.remove(peerID)
            }
            // Browsing afresh finds the Macs already connected too. Inviting one of
            // those, or one still answering, drops its connection, and the drop
            // would start browsing afresh again, round and round.
            guard !self.session.connectedPeers.contains(peerID), self.invited.insert(peerID).inserted else { return }
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 15)
        }
    }

    /// The Mac has gone from the network (the Viewer quit, or it's out of
    /// range): only now does a preload on its way to it give up.
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.invited.remove(peerID)
            guard !self.session.connectedPeers.contains(peerID) else { return }
            if self.preload?.pending.remove(peerID) != nil, self.preload?.ready.isEmpty == true {
                self.preload?.failure = "\(peerID.displayName) went away"
            }
            self.preload?.ready.remove(peerID)
            self.preload?.showWhenReady.remove(peerID)
            if self.knownMac == peerID.displayName { self.knownMac = self.session.connectedPeers.first?.displayName }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Diagnostics.log("model sender: browsing failed: \(error)")
        DispatchQueue.main.async { self.isBrowsing = false }
    }
}

extension ModelSender: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Diagnostics.log("model sender: \(peerID.displayName) \(state.rawValue)")
        DispatchQueue.main.async {
            self.macs = session.connectedPeers.map(\.displayName)
            if state != .connecting { self.invited.remove(peerID) }
            switch state {
            case .connected:
                self.knownMac = peerID.displayName
                // A preload cut off by a drop goes again, and one made before
                // this Mac turned up goes to it too. One it has ready stays ready:
                // the Viewer keeps it through a drop, and says if it hasn't.
                if let preload = self.preload, !preload.ready.contains(peerID), self.preloadingMacs.contains(peerID) {
                    self.sendPreload(to: peerID)
                }
            case .notConnected:
                // The preload's progress is kept, so the button doesn't reset.
                self.browseAgain()
            default:
                break
            }
        }
    }

    /// A dropped Mac is only found again by browsing afresh. That waits a
    /// second, so a Mac that keeps turning the phone down isn't asked again
    /// many times a second.
    private func browseAgain() {
        guard !isRestartingBrowser else { return }
        isRestartingBrowser = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.isRestartingBrowser = false
            self.browser.stopBrowsingForPeers()
            self.browser.startBrowsingForPeers()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(ModelTransfer.Message.self, from: data) else { return }
        DispatchQueue.main.async { self.received(message, from: peerID) }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {}
}
