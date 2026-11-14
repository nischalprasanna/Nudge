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
}
