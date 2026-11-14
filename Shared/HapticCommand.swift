import Foundation

/// Haptic patterns the phone can ask the Watch to play.
/// Shared by the iOS and watchOS targets so both sides agree on the wire format.
enum HapticCommand: String, CaseIterable, Codable {
    /// Bootstrap test: a single clear buzz.
    case ping
    /// One guidance pulse while the finger approaches the target. The phone sets the pulse rate.
    case approach
    /// Strong, distinct buzz: the finger is over the target.
    case onTarget
    /// A tap was verified as correct.
    case confirmed
    /// A wrong button was pressed or the screen state is unexpected.
    case wrong
}

/// Keys used in WatchConnectivity message dictionaries.
enum WatchMessageKey {
    static let haptic = "haptic"
    static let sentAt = "sentAt"
    static let ack = "ack"
    /// A guidance update. The value is one of the `WatchPhase` names.
    static let phase = "phase"
    /// How near the finger is to the button, 0 (12 cm or more away) to 1 (on it). Absent when
    /// the finger is not in view.
    static let closeness = "closeness"
    /// Direction from the finger to the button: x to the right, y down. Any length.
    static let directionX = "dx"
    static let directionY = "dy"
    /// The cue being spoken, for the Watch's screen ("Left", "Tap").
    static let word = "word"
}

/// What the phone is doing, as far as the Watch needs to know.
enum WatchPhase: String, Codable {
    /// No task running.
    case idle
    /// A task is running but the finger is not being guided (finding the screen, planning, listening).
    case working
    /// Guiding the finger toward a button.
    case seeking
    /// On the button: press now.
    case tap
    /// The task finished.
    case done
    /// The task stopped with a problem.
    case problem
}
