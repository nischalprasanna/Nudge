import SwiftUI
import UIKit

/// Nudge's visual language.
///
/// It borrows from tactile paving, the raised yellow dots that guide blind pedestrians:
/// safety yellow on black, and dots as the one recurring shape. Yellow on black is also among
/// the most legible pairings for low vision, so the identity and the accessibility need are the
/// same choice. Yellow is reserved for "this is where to go": the target, the main action,
/// and the dots that are lit. Nothing else is yellow.
enum Theme {
    // MARK: Colour

    /// Background everywhere. True black: highest contrast, and the camera view stays the focus.
    static let ink = Color.black
    /// Primary text.
    static let paper = Color.white
    /// Secondary text. About 7:1 against ink.
    static let quiet = Color(white: 0.62)
    /// The signal colour (tactile-paving yellow). About 14:1 against ink.
    static let signal = Color(red: 1.0, green: 0.82, blue: 0.12)
    /// An unlit dot.
    static let dotOff = Color(white: 0.16)
    /// Raised surfaces: sheets, chips, the bottom panel.
    static let surface = Color(white: 0.09)
    /// Confirmation. Always paired with a tick, never colour alone.
    static let done = Color(red: 0.30, green: 0.85, blue: 0.52)
    /// Problems. Always paired with an icon or words, never colour alone.
    static let alert = Color(red: 1.0, green: 0.42, blue: 0.36)

    // MARK: Type

    /// Rounded faces echo the dots. All sizes follow the user's text-size setting.
    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .rounded, weight: .heavy)
    }

    static func title(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .rounded, weight: .bold)
    }

    static func body(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .default, weight: .regular)
    }

    static func label(_ style: Font.TextStyle = .headline) -> Font {
        .system(style, design: .rounded, weight: .semibold)
    }

    // MARK: Layout

    static let gutter: CGFloat = 20
    static let panelRadius: CGFloat = 30
    static let dotSpacing: CGFloat = 20
    static let dotRadius: CGFloat = 3

    // MARK: Motion

    /// Moves and layout changes: settles without bouncing.
    static let move = Animation.spring(response: 0.4, dampingFraction: 1.0)
    /// Things that arrive with momentum, such as the panel content swapping.
    static let arrive = Animation.spring(response: 0.35, dampingFraction: 0.82)
    /// Press feedback.
    static let press = Animation.easeOut(duration: 0.14)
    /// Cross-fade used in place of movement when Reduce Motion is on.
    static let fade = Animation.easeOut(duration: 0.2)
}

/// Light touch feedback on the phone itself, used sparingly for moments that matter.
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// Shrinks slightly while pressed, so a button answers the finger straight away.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// The wide main button at the bottom of a screen.
struct MainButtonStyle: ButtonStyle {
    enum Kind { case go, stop }
    var kind: Kind = .go
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(.title))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(kind == .go ? Theme.signal : Theme.paper, in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// A round icon button that floats over the camera.
struct FloatingIconButton: View {
    let systemName: String
    let label: String
    var hint: String = ""
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.paper)
                .frame(width: 52, height: 52)
                .background {
                    // Solid when the user has asked for less transparency.
                    if reduceTransparency {
                        Circle().fill(Theme.surface)
                    } else {
                        Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    }
                }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}
