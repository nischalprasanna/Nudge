import Foundation
import WatchConnectivity
import WatchKit

/// Watch side of the phone-to-watch link. Receives haptic commands and plays them.
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchLink()

    @Published private(set) var status: String = "Starting"
    /// True while the phone's app can be reached.
    @Published private(set) var isConnected = false
    @Published private(set) var lastCommand: String = "None yet"

    func start() {
        guard WCSession.isSupported() else {
            status = "Link not supported"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func play(_ command: HapticCommand) {
        let device = WKInterfaceDevice.current()
        switch command {
        case .ping:
            device.play(.notification)
        case .approach:
            // No longer sent: the Watch times the approach beat itself. Kept for older builds.
            device.play(.start)
        case .onTarget:
            // The strongest pattern the Watch has, so "press now" cannot be mistaken for a beat.
            device.play(.notification)
        case .confirmed:
            device.play(.success)
        case .wrong:
            device.play(.failure)
        }
        DispatchQueue.main.async {
            self.lastCommand = command.rawValue
        }
    }

    private func handle(_ message: [String: Any]) {
        // Anything arriving from the phone means it is in reach.
        DispatchQueue.main.async { if !self.isConnected { self.isConnected = true } }
        if let name = message[WatchMessageKey.phase] as? String, let phase = WatchPhase(rawValue: name) {
            let closeness = message[WatchMessageKey.closeness] as? Double
            var direction: CGVector?
            if let dx = message[WatchMessageKey.directionX] as? Double, let dy = message[WatchMessageKey.directionY] as? Double {
                direction = CGVector(dx: dx, dy: dy)
            }
            let word = message[WatchMessageKey.word] as? String ?? ""
            DispatchQueue.main.async {
                WatchGuidance.shared.update(phase: phase, closeness: closeness, direction: direction, word: word)
            }
            return
        }
        guard let raw = message[WatchMessageKey.haptic] as? String,
              let command = HapticCommand(rawValue: raw) else { return }
        play(command)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.status = activationState == .activated ? "Connected to iPhone" : "Not connected"
            self.isConnected = activationState == .activated && session.isReachable
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.status = session.isReachable ? "Connected to iPhone" : "iPhone not reachable"
            self.isConnected = session.isReachable
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handle(message)
        replyHandler([WatchMessageKey.ack: true])
    }
}
