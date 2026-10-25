import MultipeerConnectivity
import UIKit

/// Finds RoomTwin Viewer on nearby Macs and sends them models.
final class ModelSender: NSObject, ObservableObject {
    /// Names of the Macs the phone is connected to.
    @Published private(set) var macs: [String] = []
    /// The last send's outcome, for a short toast.
    @Published var status: String?

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

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        browser.startBrowsingForPeers()
    }

    /// Sends the model to every connected Mac. False if none is connected.
    @discardableResult
    func send(_ model: URL, name: String) -> Bool {
        let targets = session.connectedPeers
        guard !targets.isEmpty else {
            status = "No Mac nearby. Open RoomTwin Viewer on your Mac."
            return false
        }
        Diagnostics.action("send model to \(targets.map(\.displayName))")
        for mac in targets {
            session.sendResource(at: model, withName: name, toPeer: mac) { [weak self] error in
                DispatchQueue.main.async {
                    self?.status = error.map { "Couldn't send to \(mac.displayName): \($0.localizedDescription)" }
                        ?? "Sent to \(mac.displayName)"
                }
            }
        }
        return true
    }
}

extension ModelSender: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

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
            // A dropped Mac is only found again by browsing afresh.
            if state == .notConnected {
                self.browser.stopBrowsingForPeers()
                self.browser.startBrowsingForPeers()
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {}
}
