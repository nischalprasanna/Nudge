import Foundation
import WatchKit

/// Keeps the Watch app running while the wrist is down, so haptics keep arriving during a task.
/// Without this the app is suspended a few seconds after the screen dims and the phone can no
/// longer reach it. A session lasts up to an hour and is started whenever the app comes forward.
final class RuntimeKeeper: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    static let shared = RuntimeKeeper()

    @Published private(set) var status = "Not started"
    /// False only once it is known that the keep-awake session is not running.
    @Published private(set) var isAwake = true
    private var session: WKExtendedRuntimeSession?

    /// Call when the app becomes active. Does nothing if a session is already running.
    func start() {
        if let session, session.state == .running || session.state == .scheduled { return }
        let fresh = WKExtendedRuntimeSession()
        fresh.delegate = self
        fresh.start()
        session = fresh
        status = "Starting"
    }

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async {
            self.status = "Staying awake"
            self.isAwake = true
        }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async { self.status = "About to sleep. Open Nudge again." }
        WKInterfaceDevice.current().play(.notification)
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        DispatchQueue.main.async {
            self.session = nil
            self.status = "Not staying awake"
            self.isAwake = false
        }
    }
}
