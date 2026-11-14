import CoreGraphics
import Foundation
import os

/// Which feedback channels are switched on. Any combination is allowed.
struct FeedbackChannels: Equatable {
    var tones = true
    var voice = true
    var watch = true
}

/// Turns the live fingertip position into guidance toward one target button.
///
/// `update(finger:)` is called for every camera frame (well above 15 times a second) and never
/// waits on anything, so guidance keeps flowing regardless of network or speech.
final class GuidanceEngine {
    struct Target {
        /// Centre of the button on the screen, normalized 0...1, origin top-left.
        var uv: CGPoint
        /// How close the fingertip must be to count as on the button, in metres.
        var radius: Float
        var name: String
    }

    enum Phase: Equatable {
        case idle
        case seeking
        /// The finger has rested on the target long enough; "tap now" has been given.
        case onTarget
    }

    struct Snapshot {
        var phase: Phase = .idle
        /// True once the finger has reached the target at least once for the current target.
        var hasArrived = false
        var distance: Float?
        var lastSeen: TimeInterval = 0
    }

    private struct State {
        var target: Target?
        var screenWidth: Float = 0.1
        var screenHeight: Float = 0.1
        var snapshot = Snapshot()
        var dwellStart: TimeInterval?
        var lastVoiceTime: TimeInterval = 0
        var lastVoiceText = ""
        var lastMissingPrompt: TimeInterval = 0
        var startedAt: TimeInterval = 0
        var lastApproachPulse: TimeInterval = 0
    }

    private let tones: ToneEngine
    private let speaker: Speaker
    private let lock = OSAllocatedUnfairLock(initialState: State())

    var channels = FeedbackChannels()
    /// Haptic cues for the Watch. Called from the camera thread.
    var onHaptic: ((HapticCommand) -> Void)?

    init(tones: ToneEngine, speaker: Speaker) {
        self.tones = tones
        self.speaker = speaker
    }

    var snapshot: Snapshot { lock.withLock { $0.snapshot } }

    /// Start guiding to a target. `screenWidth` and `screenHeight` are the anchored screen's size in metres.
    func begin(target: Target, screenWidth: Float, screenHeight: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            $0 = State()
            $0.target = target
            $0.screenWidth = screenWidth
            $0.screenHeight = screenHeight
            $0.snapshot.phase = .seeking
            $0.startedAt = now
            $0.lastMissingPrompt = now
        }
    }

    func end() {
        lock.withLock {
            $0.target = nil
            $0.snapshot.phase = .idle
        }
        tones.silence()
    }

    /// Feed the latest fingertip position. `finger.timestamp` uses the same clock as system uptime.
    func update(finger: FingerState?) {
        enum Cue {
            case none
            case silent
            case seek(pan: Float, rise: Float, closeness: Float)
            case onTarget
        }
        var cue = Cue.none
        var say: String?
        var haptic: HapticCommand?
        let now = ProcessInfo.processInfo.systemUptime

        lock.withLockUnchecked { state in
            guard let target = state.target else { return }

            guard let finger else {
                cue = .silent
                state.snapshot.distance = nil
                state.dwellStart = nil
                if state.snapshot.phase == .onTarget { state.snapshot.phase = .seeking }
                // Only prompt if the finger has been missing for a while, and not too often.
                if !state.snapshot.hasArrived,
                   now - max(state.snapshot.lastSeen, state.startedAt) > 3,
                   now - state.lastMissingPrompt > 6 {
                    state.lastMissingPrompt = now
                    say = "I can't see your finger. Point with one finger in front of the screen."
                }
                return
            }
            state.snapshot.lastSeen = now

            // Offsets in metres: positive dx means move right, positive dy means move down.
            let dx = Float(target.uv.x - finger.uv.x) * state.screenWidth
            let dy = Float(target.uv.y - finger.uv.y) * state.screenHeight
            let distance = (dx * dx + dy * dy).squareRoot()
            state.snapshot.distance = distance

            let wasOnTarget = state.snapshot.phase == .onTarget
            // A little slack once on target, so small tremors do not flip the state.
            let inside = distance < (wasOnTarget ? target.radius * 1.5 : target.radius)

            if inside {
                cue = .onTarget
                if wasOnTarget { return }
                if state.dwellStart == nil { state.dwellStart = now }
                if now - (state.dwellStart ?? now) >= 0.3 {
                    state.snapshot.phase = .onTarget
                    state.snapshot.hasArrived = true
                    state.lastVoiceTime = now
                    state.lastVoiceText = "tap"
                    say = "Tap now, then move your hand away."
                    haptic = .onTarget
                }
                return
            }

            state.dwellStart = nil
            state.snapshot.phase = .seeking
            let closeness = 1 - min(distance / 0.12, 1)
            cue = .seek(pan: dx / 0.06, rise: -dy / 0.06, closeness: closeness)

            // Watch pulses that speed up as the finger approaches.
            let pulseInterval = TimeInterval(0.8 - 0.65 * closeness)
            if now - state.lastApproachPulse > pulseInterval {
                state.lastApproachPulse = now
                haptic = .approach
            }

            // Spoken direction: when it changes, or as a reminder every couple of seconds.
            var text = Self.direction(dx: dx, dy: dy)
            if let hover = finger.hoverMeters {
                if hover < 0.006, distance > target.radius * 2 {
                    text = "Lift your finger a little. " + text
                } else if hover > 0.09 {
                    text = "Closer to the screen. " + text
                }
            }
            let sinceLast = now - state.lastVoiceTime
            if (text != state.lastVoiceText && sinceLast > 0.9) || sinceLast > 2.2 {
                state.lastVoiceTime = now
                state.lastVoiceText = text
                say = text
            }
        }

        if channels.tones {
            switch cue {
            case .none: break
            case .silent: tones.silence()
            case .seek(let pan, let rise, let closeness): tones.seek(pan: pan, rise: rise, closeness: closeness)
            case .onTarget: tones.onTarget()
            }
        }
        if channels.voice, let say { speaker.say(say) }
        if channels.watch, let haptic { onHaptic?(haptic) }
    }

    /// Short spoken direction such as "left", "up a little" or "down and right".
    static func direction(dx: Float, dy: Float) -> String {
        let horizontal = dx > 0 ? "right" : "left"
        let vertical = dy > 0 ? "down" : "up"
        let ax = abs(dx)
        let ay = abs(dy)
        let distance = max(ax, ay)

        let words: String
        if ax > ay * 2 {
            words = horizontal
        } else if ay > ax * 2 {
            words = vertical
        } else {
            words = "\(vertical) and \(horizontal)"
        }
        if distance < 0.015 { return "\(words), slightly" }
        if distance < 0.04 { return "\(words) a little" }
        return words
    }
}
