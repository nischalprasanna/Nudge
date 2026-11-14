import Foundation
import WatchConnectivity

/// Phone side of the phone-to-watch link. Sends haptic commands to the Watch.
/// If the Watch is unreachable this fails quietly: guidance must never block on the Watch.
final class PhoneWatchLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneWatchLink()

    @Published private(set) var status: String = "Watch link starting"
    @Published private(set) var isReachable = false
    @Published private(set) var lastRoundTripMs: Int?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func start() {
        guard let session else {
            status = "Watch link not supported on this device"
            return
        }
        session.delegate = self
        session.activate()
    }

    /// Ask the Watch to play a haptic. Returns immediately.
    func send(_ command: HapticCommand) {
        guard let session, session.activationState == .activated else {
            status = "Watch link not active yet"
            return
        }
        guard session.isReachable else {
            status = "Watch not reachable. Open Nudge on the Watch."
            return
        }
        let sent = Date()
        let message: [String: Any] = [
            WatchMessageKey.haptic: command.rawValue,
            WatchMessageKey.sentAt: sent.timeIntervalSince1970,
        ]
        if command == .approach {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
            return
        }
        session.sendMessage(message, replyHandler: { [weak self] _ in
            let ms = Int(Date().timeIntervalSince(sent) * 1000)
            DispatchQueue.main.async {
                self?.lastRoundTripMs = ms
                self?.status = "Watch buzzed (\(ms) ms round trip)"
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                self?.status = "Watch send failed: \(error.localizedDescription)"
            }
        })
    }

    private func refresh(_ session: WCSession) {
        let reachable = session.isReachable
        let text: String
        if session.activationState != .activated {
            text = "Watch link not active"
        } else if !session.isPaired {
            text = "No Apple Watch paired"
        } else if !session.isWatchAppInstalled {
            text = "Nudge is not installed on the Watch"
        } else if reachable {
            text = "Watch connected"
        } else {
            text = "Watch not reachable. Open Nudge on the Watch."
        }
        DispatchQueue.main.async {
            self.isReachable = reachable
            self.status = text
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        refresh(session)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        refresh(session)
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        refresh(session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
