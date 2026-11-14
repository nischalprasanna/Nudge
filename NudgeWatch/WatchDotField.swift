import SwiftUI

/// The Watch's colours: the same tactile-paving yellow on black as the phone.
enum WatchTheme {
    static let signal = Color(red: 1.0, green: 0.82, blue: 0.12)
    static let dotOff = Color(white: 0.16)
    static let quiet = Color(white: 0.62)
    static let done = Color(red: 0.30, green: 0.85, blue: 0.52)
    static let alert = Color(red: 1.0, green: 0.42, blue: 0.36)
}

/// The grid of dots behind everything on the Watch, showing what the phone's dot field shows:
/// a glow that sits toward the button and closes in as the finger nears it.
struct WatchDotField: View {
    var phase: WatchPhase
    var closeness: Double?
    var direction: CGVector
    /// A centred area left empty for the word on top. Whole dots are left out; none are cut.
    var gap: CGSize = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed

    private let spacing: CGFloat = 12
    private let dotRadius: CGFloat = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion || dimmed)) { timeline in
            Canvas { context, size in
                let still = reduceMotion || dimmed
                draw(in: &context, size: size, time: still ? 0 : timeline.date.timeIntervalSinceReferenceDate, still: still)
            }
        }
        .accessibilityHidden(true)
    }

    /// The dots sit on rings around the centre, not on a square grid, and thin out softly
    /// toward whatever is written in the middle. Rings suit a watch face and the ripple that
    /// runs through them; a grid with a rectangle cut out of it looked like a box in a box.
    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval, still: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = max(hypot(size.width, size.height) / 2, 1)
        let t = CGFloat(time)
        // The space left for the words: an ellipse a little larger than they are.
        let clearX = gap.width / 2 + 10
        let clearY = gap.height / 2 + 8

        var ring = 1
        while CGFloat(ring) * spacing < reach + spacing {
            let radius = CGFloat(ring) * spacing
            let count = max(6, Int((2 * .pi * radius / spacing).rounded()))
            // Alternate rings are turned by half a step, so the dots do not line up in spokes.
            let turn = ring % 2 == 0 ? CGFloat.pi / CGFloat(count) : 0
            for step in 0..<count {
                let angle = CGFloat(step) / CGFloat(count) * 2 * .pi + turn
                let dx = cos(angle) * radius
                let dy = sin(angle) * radius
                let point = CGPoint(x: centre.x + dx, y: centre.y + dy)
                guard point.x > -dotRadius, point.y > -dotRadius,
                      point.x < size.width + dotRadius, point.y < size.height + dotRadius else { continue }

                // 0 inside the space for the words, rising smoothly to 1 a little way out.
                var presence: CGFloat = 1
                if gap.width > 0 {
                    let q = (dx * dx) / (clearX * clearX) + (dy * dy) / (clearY * clearY)
                    if q < 1 { continue }
                    presence = min(1, (q - 1) / 0.9)
                }

                let (level, scale, color) = appearance(dx: dx, dy: dy, distance: radius, reach: reach, t: t, still: still)
                let amount = min(max(level, 0), 1)
                let size = dotRadius * scale * (0.55 + 0.45 * presence)
                let fill = amount <= 0.01
                    ? WatchTheme.dotOff.opacity(Double(presence))
                    : color.opacity(Double((0.16 + 0.84 * amount) * presence))
                context.fill(Path(ellipseIn: CGRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2)),
                             with: .color(fill))
            }
            ring += 1
        }
    }

    /// Brightness (0...1), size multiplier and lit colour for one dot.
    private func appearance(dx: CGFloat, dy: CGFloat, distance: CGFloat, reach: CGFloat, t: CGFloat,
                            still: Bool) -> (CGFloat, CGFloat, Color) {
        switch phase {
        case .idle:
            // A ring travelling slowly outward.
            let phaseValue = distance / reach * 2.2 - t * 0.35
            let band = 1 - abs((phaseValue - floor(phaseValue)) - 0.5) * 2
            let wave = still ? 0 : pow(max(0, band), 2.2)
            let level = wave * max(0, 1 - distance / reach) * 0.9
            return (level, 1 + level * 0.5, WatchTheme.signal)

        case .working:
            // A bright arc sweeping round.
            guard !still else { return (distance < reach * 0.35 ? 0.4 : 0, 1, WatchTheme.signal) }
            var delta = (atan2(dy, dx) - t * 3.2).truncatingRemainder(dividingBy: 2 * .pi)
            if delta < 0 { delta += 2 * .pi }
            let trail = max(0, 1 - delta / 2.2)
            let ring = max(0, 1 - abs(distance - reach * 0.42) / (reach * 0.3))
            return (trail * ring, 1 + trail * ring * 0.6, WatchTheme.signal)

        case .seeking:
            guard let closeness else {
                // Finger not in view: a dim, still field.
                return (distance < reach * 0.25 ? 0.25 : 0, 1, WatchTheme.signal)
            }
            // A glowing patch toward the button that closes in on the centre, pulsing in time
            // with the taps on the wrist.
            let near = CGFloat(min(max(closeness, 0), 1))
            let length = max(hypot(direction.dx, direction.dy), 0.0001)
            let offset = reach * 0.6 * (1 - near)
            let patch = CGPoint(x: direction.dx / length * offset, y: direction.dy / length * offset)
            let spread = reach * (0.28 + 0.1 * (1 - near))
            let d = hypot(dx - patch.x, dy - patch.y)
            let glow = exp(-(d * d) / (2 * spread * spread))
            let rate = 2 * CGFloat.pi / CGFloat(WatchGuidance.interval(for: closeness))
            let beat = still ? 1 : (0.7 + 0.3 * (sin(t * rate) * 0.5 + 0.5))
            return (glow * beat, 1 + glow * beat * 0.7, WatchTheme.signal)

        case .tap:
            let inside = distance < reach * 0.5
            let beat = still ? 1 : (0.8 + 0.2 * (sin(t * 14) * 0.5 + 0.5))
            return (inside ? beat : 0.08, inside ? 1.6 : 1, WatchTheme.signal)

        case .done:
            let fade = max(0, 1 - distance / (reach * 0.75))
            return (0.35 + fade * 0.65, 1 + fade * 0.6, WatchTheme.done)

        case .problem:
            let fade = max(0, 1 - distance / (reach * 0.75))
            return (0.25 + fade * 0.5, 1, WatchTheme.alert)
        }
    }
}
