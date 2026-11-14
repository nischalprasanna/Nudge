import Foundation
import WatchConnectivity
import WatchKit

/// Watch side of the phone-to-watch link. Receives haptic commands and plays them.
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchLink()

    @Published private(set) var status: String = "Starting"
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
            device.play(.click)
        case .onTarget:
            device.play(.success)
        case .confirmed:
            device.play(.directionUp)
        case .wrong:
            device.play(.failure)
        }
        DispatchQueue.main.async {
            self.lastCommand = command.rawValue
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let raw = message[WatchMessageKey.haptic] as? String,
              let command = HapticCommand(rawValue: raw) else { return }
        play(command)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.status = activationState == .activated ? "Connected to iPhone" : "Not connected"
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.status = session.isReachable ? "Connected to iPhone" : "iPhone not reachable"
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
