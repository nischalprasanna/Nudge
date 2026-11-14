import Foundation
import SwiftUI
import WatchKit

/// What the Watch knows about the task on the phone, and the beat on the wrist.
///
/// The phone says how near the finger is to the button about five times a second. The Watch
/// turns that into a steady beat of taps: about one a second when the finger is far away,
/// quickening smoothly to about seven a second when it is nearly on the button. The beat is
/// timed here, not on the phone, so it stays even when Bluetooth delivers messages in bursts.
final class WatchGuidance: ObservableObject {
    static let shared = WatchGuidance()

    @Published private(set) var phase: WatchPhase = .idle
    @Published private(set) var word = ""
    /// 0 (far) to 1 (on the button). Nil when the finger is not in view.
    @Published private(set) var closeness: Double?
    @Published private(set) var direction = CGVector.zero

    private var lastUpdate = Date.distantPast
    private var lastBeat = Date.distantPast
    private var timer: Timer?

    /// Seconds between taps for a given closeness.
    static func interval(for closeness: Double) -> TimeInterval {
        let c = min(max(closeness, 0), 1)
        // Eased so the change is easy to feel across the whole approach, not only at the end.
        return 1.0 - 0.86 * pow(c, 0.8)
    }

    /// Call on the main thread with each update from the phone.
    func update(phase: WatchPhase, closeness: Double?, direction: CGVector?, word: String) {
        self.phase = phase
        self.closeness = closeness
        if let direction { self.direction = direction }
        self.word = word
        lastUpdate = Date()
        if phase == .seeking, closeness != nil {
            startBeating()
        } else {
            stopBeating()
        }
        if phase == .done || phase == .problem {
            // Show the result for a few seconds, then settle back.
            let shown = lastUpdate
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.lastUpdate == shown else { return }
                self.phase = .idle
                self.word = ""
            }
        }
    }

    private func startBeating() {
        guard timer == nil else { return }
        // Checked many times a second so a sudden move closer is felt at once, without waiting
        // out a long gap that was right for where the finger used to be.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopBeating() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        // Nothing from the phone for a while: it is out of reach or the task has ended.
        #if targetEnvironment(simulator)
        lastUpdate = now   // layout previews have no phone feeding them
        #endif
        guard phase == .seeking, let closeness, now.timeIntervalSince(lastUpdate) < 1.5 else {
            stopBeating()
            if now.timeIntervalSince(lastUpdate) >= 1.5, phase == .seeking || phase == .tap || phase == .working {
                phase = .idle
                word = ""
            }
            return
        }
        if now.timeIntervalSince(lastBeat) >= Self.interval(for: closeness) {
            lastBeat = now
            WKInterfaceDevice.current().play(.click)
        }
    }
}
