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

    private let spacing: CGFloat = 13
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

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval, still: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        let columns = max(1, Int(size.width / spacing))
        let rows = max(1, Int(size.height / spacing))
        let offsetX = (size.width - CGFloat(columns - 1) * spacing) / 2
        let offsetY = (size.height - CGFloat(rows - 1) * spacing) / 2
        let reach = max(hypot(size.width, size.height) / 2, 1)
        let t = CGFloat(time)

        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: offsetX + CGFloat(column) * spacing, y: offsetY + CGFloat(row) * spacing)
                if gap.width > 0,
                   abs(point.x - size.width / 2) < gap.width / 2 + dotRadius,
                   abs(point.y - size.height / 2) < gap.height / 2 + dotRadius {
                    continue
                }
                let dx = point.x - size.width / 2
                let dy = point.y - size.height / 2
                let distance = hypot(dx, dy)
                let (level, scale, color) = appearance(dx: dx, dy: dy, distance: distance, reach: reach, t: t, still: still)
                let radius = dotRadius * scale
                let amount = min(max(level, 0), 1)
                let fill = amount <= 0.01 ? WatchTheme.dotOff : color.opacity(0.16 + 0.84 * amount)
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(fill))
            }
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
