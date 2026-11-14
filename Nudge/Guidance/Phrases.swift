import Foundation

/// The words for "move the camera", which depend on how the phone is carried. In the hand it
/// can be tilted and turned. On the chest it only moves when the body does, so every
/// instruction is given as a body movement: leaning forward tips the camera down, leaning back
/// tips it up, and turning the shoulders turns it.
enum Phrases {
    /// The "Worn on the chest" setting.
    static var onChest: Bool { UserDefaults.standard.bool(forKey: "wornOnChest") }

    static var pointAtScreen: String {
        onChest ? "Face the touchscreen." : "Point the phone at the touchscreen."
    }

    static var turnLeft: String {
        onChest ? "Turn your body a little to the left." : "Turn the phone a little to the left."
    }

    static var turnRight: String {
        onChest ? "Turn your body a little to the right." : "Turn the phone a little to the right."
    }

    static var tiltUp: String {
        onChest ? "Lean back a little." : "Tilt the phone up a little."
    }

    static var tiltDown: String {
        onChest ? "Lean forward a little." : "Tilt the phone down a little."
    }

    static var closer: String {
        onChest ? "Step a little closer." : "Move closer."
    }

    static var back: String {
        onChest ? "Step back a little." : "Move back a little."
    }

    /// Said when the whole panel does not fit in the picture.
    static var backToFit: String {
        onChest ? "Step back a little." : "Move the phone back a little."
    }

    static var nothingInView: String {
        onChest
            ? "I can't see any buttons yet. Slowly turn your body from side to side."
            : "I can't see any buttons yet. Slowly turn the phone from side to side."
    }

    /// Said when the finger keeps going missing, which usually means the hand is hiding it.
    static var fingerHidden: String {
        onChest
            ? "Lean forward a little, so the camera looks down at your hand."
            : "Hold the phone higher, so it looks down at your hand."
    }
}
