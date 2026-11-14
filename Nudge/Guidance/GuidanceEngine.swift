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
///
/// Division of labour: the beeps carry the continuous guidance. The voice says very little:
/// one direction word when the direction changes, "closer" or "lift" for height, and "tap".
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
        /// Over the button but still too far from the glass to tap.
        case aboveTarget
        /// Over the button and close to the glass; "tap" has been given.
        case onTarget
    }

    struct Snapshot {
        var phase: Phase = .idle
        /// True once "tap" has been given at least once for the current target.
        var hasArrived = false
        var distance: Float?
        var lastSeen: TimeInterval = 0
        /// From the finger to the button in metres: x to the right, y down. Nil while the finger is not seen.
        var offset: SIMD2<Float>?
    }

    private enum Axis { case horizontal, vertical }

    private struct State {
        var target: Target?
        var screenWidth: Float = 0.1
        var screenHeight: Float = 0.1
        var snapshot = Snapshot()
        var dwellStart: TimeInterval?
        /// Lowest height seen while over the button, and when it last got meaningfully lower.
        var lowestAbove: Float?
        var lastDescent: TimeInterval = 0
        /// Height the sensor reports when the finger is actually on the glass, learned from use.
        var touchHeight: Float = 0
        var lastVoiceTime: TimeInterval = 0
        var lastVoiceText = ""
        var lastHeightPrompt: TimeInterval = 0
        var lastMissingPrompt: TimeInterval = 0
        var startedAt: TimeInterval = 0
        var lastApproachPulse: TimeInterval = 0
        var axis: Axis?
    }

    private let tones: ToneEngine
    private let speaker: Speaker
    private let lock = OSAllocatedUnfairLock(initialState: State())

    var channels = FeedbackChannels()
    /// Haptic cues for the Watch. Called from the camera thread.
    var onHaptic: ((HapticCommand) -> Void)?
    /// What is said when the finger is on the button and close enough to press it.
    var tapPhrase = "Tap."
    /// The finger pad must be within this height of the glass before "tap" is given (metres).
    var tapHeight: Float = 0.035
    /// Below this height while still far from the button, the user is told to lift (metres).
    var dragHeight: Float = 0.005

    init(tones: ToneEngine, speaker: Speaker) {
        self.tones = tones
        self.speaker = speaker
    }

    var snapshot: Snapshot { lock.withLock { $0.snapshot } }

    /// Start guiding to a target. `screenWidth` and `screenHeight` are the anchored screen's size in metres.
    func begin(target: Target, screenWidth: Float, screenHeight: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            // What was learned about the height sensor carries over from one button to the next.
            let learned = $0.touchHeight
            $0 = State()
            $0.touchHeight = learned
            $0.target = target
            $0.screenWidth = screenWidth
            $0.screenHeight = screenHeight
            $0.snapshot.phase = .seeking
            $0.startedAt = now
            $0.lastMissingPrompt = now
            // Give the "Press ..." sentence a moment before any direction word.
            $0.lastVoiceTime = now
        }
    }

    func end() {
        lock.withLock {
            $0.target = nil
            $0.snapshot.phase = .idle
        }
        tones.silence()
    }

    /// Forgets what was learned about the height sensor. Call when a new screen is anchored.
    func resetHeightCalibration() {
        lock.withLock { $0.touchHeight = 0 }
    }

    /// Feed the latest fingertip position.
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
        let tapPhrase = self.tapPhrase
        let tapHeight = self.tapHeight
        let dragHeight = self.dragHeight

        lock.withLockUnchecked { state in
            guard let target = state.target else { return }

            guard let finger else {
                cue = .silent
                state.snapshot.distance = nil
                state.snapshot.offset = nil
                state.dwellStart = nil
                state.lowestAbove = nil
                if state.snapshot.phase != .seeking { state.snapshot.phase = .seeking }
                // Only mention it if the finger has been missing for a while, and rarely.
                if !state.snapshot.hasArrived,
                   now - max(state.snapshot.lastSeen, state.startedAt) > 3,
                   now - state.lastMissingPrompt > 8 {
                    state.lastMissingPrompt = now
                    say = "I can't see your finger."
                }
                return
            }
            state.snapshot.lastSeen = now

            // Offsets in metres: positive dx means move right, positive dy means move down.
            let dx = Float(target.uv.x - finger.uv.x) * state.screenWidth
            let dy = Float(target.uv.y - finger.uv.y) * state.screenHeight
            let distance = (dx * dx + dy * dy).squareRoot()
            state.snapshot.distance = distance
            state.snapshot.offset = SIMD2(dx, dy)

            let wasOver = state.snapshot.phase == .onTarget || state.snapshot.phase == .aboveTarget
            // A little slack once over the button, so small tremors do not flip the state.
            let over = distance < (wasOver ? target.radius * 1.5 : target.radius)

            if over {
                // Over the button. Is the finger close enough to the glass to press it?
                // If the height is unknown (no depth reading), assume it is.
                var near = true
                if let reported = finger.hoverMeters {
                    near = reported - state.touchHeight <= tapHeight
                    if near {
                        state.lowestAbove = nil
                    } else {
                        // The reading says "too high". If it has also stopped coming down, the finger
                        // has nowhere left to go: it is on the glass and the sensor is reading high.
                        // Accept the tap, and remember that reading as the touching height from now on.
                        if let lowest = state.lowestAbove {
                            if reported < lowest - 0.004 {
                                state.lowestAbove = reported
                                state.lastDescent = now
                            }
                        } else {
                            state.lowestAbove = reported
                            state.lastDescent = now
                        }
                        if now - state.lastDescent > 1.2 {
                            // Only learn from readings that could plausibly be a touch. A finger held
                            // still well above the glass still gets its tap, but teaches nothing.
                            if reported <= 0.06 {
                                state.touchHeight = max(state.touchHeight, reported - 0.01)
                            }
                            state.lowestAbove = nil
                            near = true
                        }
                    }
                }

                if near {
                    cue = .onTarget
                    if state.snapshot.phase == .onTarget { return }
                    if state.dwellStart == nil { state.dwellStart = now }
                    if now - (state.dwellStart ?? now) >= 0.25 {
                        state.snapshot.phase = .onTarget
                        state.snapshot.hasArrived = true
                        state.lastVoiceTime = now
                        state.lastVoiceText = "tap"
                        say = tapPhrase
                        haptic = .onTarget
                    }
                } else {
                    // Right spot, too high: fast centred beeps, and one word now and then.
                    state.dwellStart = nil
                    state.snapshot.phase = .aboveTarget
                    cue = .seek(pan: 0, rise: 0, closeness: 1)
                    if now - state.lastHeightPrompt > 2.5 {
                        state.lastHeightPrompt = now
                        state.lastVoiceTime = now
                        state.lastVoiceText = "closer"
                        say = "Closer."
                    }
                }
                return
            }

            state.dwellStart = nil
            state.lowestAbove = nil
            state.snapshot.phase = .seeking
            let closeness = 1 - min(distance / 0.12, 1)
            cue = .seek(pan: dx / 0.06, rise: -dy / 0.06, closeness: closeness)

            // Watch pulses that speed up as the finger approaches.
            let pulseInterval = TimeInterval(0.8 - 0.65 * closeness)
            if now - state.lastApproachPulse > pulseInterval {
                state.lastApproachPulse = now
                haptic = .approach
            }

            // Dragging along the glass while still away from the button would press other buttons.
            if let hover = finger.hoverMeters, hover - state.touchHeight < dragHeight, distance > target.radius * 2.5,
               now - state.lastHeightPrompt > 4 {
                state.lastHeightPrompt = now
                state.lastVoiceTime = now
                state.lastVoiceText = "lift"
                say = "Lift."
                return
            }

            // One direction word. Stick with the current axis unless the other is clearly larger,
            // so the word does not flip back and forth on a diagonal.
            let ax = abs(dx)
            let ay = abs(dy)
            var axis = state.axis ?? (ax >= ay ? .horizontal : .vertical)
            if axis == .horizontal, ay > ax * 1.6 { axis = .vertical }
            if axis == .vertical, ax > ay * 1.6 { axis = .horizontal }
            // Once one direction is nearly lined up, hand over to the other.
            if axis == .horizontal, ax < target.radius * 0.7, ay >= target.radius * 0.7 { axis = .vertical }
            if axis == .vertical, ay < target.radius * 0.7, ax >= target.radius * 0.7 { axis = .horizontal }
            state.axis = axis

            let word: String
            switch axis {
            case .horizontal: word = dx > 0 ? "Right." : "Left."
            case .vertical: word = dy > 0 ? "Down." : "Up."
            }

            // Speak when the word changes (not more than about once a second),
            // or as an occasional reminder if nothing has changed.
            let sinceLast = now - state.lastVoiceTime
            if (word != state.lastVoiceText && sinceLast > 1.1) || sinceLast > 4.5 {
                state.lastVoiceTime = now
                state.lastVoiceText = word
                say = word
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
}
