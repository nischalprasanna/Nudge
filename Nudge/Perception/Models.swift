import CoreGraphics
import Foundation

/// One button or label found on an appliance screen.
struct ScreenElement: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, icon }

    var id = UUID()
    var label: String
    /// Position on the screen, normalized 0...1 with the origin at the top-left (x right, y down).
    var box: CGRect
    var confidence: Float
    var kind: Kind = .text

    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

/// Everything read from the screen at one moment.
struct ScreenReading: Codable, Equatable {
    enum Source: String, Codable { case onDeviceText, cloudVision, savedDevice }

    var elements: [ScreenElement]
    var source: Source
    var readAt: Date
    /// Physical width divided by height of the anchored screen.
    var aspectRatio: Double
}

/// Where the index fingertip is relative to the anchored screen.
struct FingerState: Equatable {
    enum Method: String {
        /// LiDAR depth, projected straight down onto the glass (parallax corrected).
        case lidar
        /// Camera ray through the fingertip hitting the glass (no hover height, has parallax when hovering).
        case ray
    }

    /// Landing position on the screen, normalized 0...1, origin top-left. Can fall outside 0...1.
    var uv: CGPoint
    /// Estimated height of the finger pad above the glass in metres. Nil when LiDAR depth is unavailable.
    var hoverMeters: Float?
    var method: Method
    var confidence: Float
    var timestamp: TimeInterval

    var isOverScreen: Bool {
        (0...1).contains(uv.x) && (0...1).contains(uv.y)
    }
}
