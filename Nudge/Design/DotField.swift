import SwiftUI

/// What the dot field is showing. It mirrors what the user hears, so a sighted onlooker
/// can follow the guidance without sound.
enum DotFieldMode: Equatable {
    /// Slow ripple spreading from the centre. Used on the home screen and while waiting.
    case idle
    /// Dots sweep round while Nudge is looking or working something out.
    case working
    /// Dots rise and fall with the microphone level (0...1).
    case listening(level: Float)
    /// Guidance. `direction` points from the finger toward the button (x right, y down), any
    /// length; `closeness` is 0 (far) to 1 (nearly there).
    case seeking(direction: CGVector, closeness: Float)
    /// Over the button but too high: rings close in on the centre.
    case closer
    /// On the button: press now.
    case tap
    /// A step or the whole task succeeded.
    case success
    /// Something went wrong.
    case problem
}

/// A grid of dots that light up in patterns. The single animated element of the interface.
///
/// With Reduce Motion on, the patterns hold still: position and brightness still carry the
/// information, but nothing travels or pulses.
struct DotField: View {
    var mode: DotFieldMode
    var spacing: CGFloat = Theme.dotSpacing
    var dotRadius: CGFloat = Theme.dotRadius
    /// Where ripples start, as a fraction of the view's size.
    var focus: UnitPoint = .center
    /// A centred area to leave empty, for a word set on top. Whole dots are left out; none are cut.
    var gap: CGSize = .zero
    /// Leave out every dot within this distance of the focus point (for a round button placed there).
    var clearRadius: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                draw(in: &context, size: size, time: time)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }
        let columns = max(1, Int(size.width / spacing))
        let rows = max(1, Int(size.height / spacing))
        let offsetX = (size.width - CGFloat(columns - 1) * spacing) / 2
        let offsetY = (size.height - CGFloat(rows - 1) * spacing) / 2
        let center = CGPoint(x: size.width * focus.x, y: size.height * focus.y)
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
                let dx = point.x - center.x
                let dy = point.y - center.y
                let distance = hypot(dx, dy)
                if clearRadius > 0, distance < clearRadius + dotRadius * 2 { continue }
                let (level, scale, color) = appearance(dx: dx, dy: dy, distance: distance, reach: reach,
                                                       column: column, columns: columns,
                                                       y: point.y, height: size.height, t: t)
                let radius = dotRadius * scale
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(blend(color, level)))
            }
        }
    }

    /// Brightness (0...1), size multiplier and lit colour for one dot.
    private func appearance(dx: CGFloat, dy: CGFloat, distance: CGFloat, reach: CGFloat,
                            column: Int, columns: Int, y: CGFloat, height: CGFloat,
                            t: CGFloat) -> (CGFloat, CGFloat, Color) {
        switch mode {
        case .idle:
            // A ring travelling outward, fading as it goes.
            let wave = reduceMotion ? 0 : pulse(distance / reach * 2.2 - t * 0.35)
            let fade = max(0, 1 - distance / reach)
            let level = wave * fade * 0.9
            return (level, 1 + level * 0.5, Theme.signal)

        case .working:
            // A bright arc sweeping round the centre.
            guard !reduceMotion else {
                return (distance < reach * 0.35 ? 0.5 : 0, 1, Theme.signal)
            }
            let angle = atan2(dy, dx)
            let sweep = t * 3.2
            var delta = (angle - sweep).truncatingRemainder(dividingBy: 2 * .pi)
            if delta < 0 { delta += 2 * .pi }
            let trail = max(0, 1 - delta / 2.2)
            let ring = max(0, 1 - abs(distance - reach * 0.42) / (reach * 0.3))
            let level = trail * ring
            return (level, 1 + level * 0.6, Theme.signal)

        case .listening(let micLevel):
            // Columns of dots lighting from the middle outward, like a sound meter.
            let phase = CGFloat(column) * 0.9
            let wobble = reduceMotion ? 0.6 : (sin(t * 7 + phase) * 0.5 + 0.5)
            let strength = 0.18 + CGFloat(min(max(micLevel, 0), 1)) * 0.82
            let columnHeight = height * 0.5 * strength * (0.35 + 0.65 * wobble)
            let fromMiddle = abs(y - height / 2)
            let level: CGFloat = fromMiddle <= columnHeight ? 1 : 0
            return (level, 1 + level * 0.4, Theme.signal)

        case .seeking(let direction, let closeness):
            // A glowing patch that sits toward the button and closes in on the centre as the
            // finger gets nearer. It pulses faster when close, like the beeps.
            let length = max(hypot(direction.dx, direction.dy), 0.0001)
            let near = CGFloat(min(max(closeness, 0), 1))
            let offset = reach * 0.62 * (1 - near)
            let patch = CGPoint(x: direction.dx / length * offset, y: direction.dy / length * offset)
            let spread = reach * (0.26 + 0.1 * (1 - near))
            let d = hypot(dx - patch.x, dy - patch.y)
            let glow = exp(-(d * d) / (2 * spread * spread))
            let rate = 2.0 + 7.0 * near
            let beat = reduceMotion ? 1 : (0.72 + 0.28 * (sin(t * rate) * 0.5 + 0.5))
            let level = glow * beat
            return (level, 1 + level * 0.7, Theme.signal)

        case .closer:
            // Rings contracting toward the centre: come in.
            let wave = reduceMotion ? (distance < reach * 0.3 ? 1 : 0.2) : pulse(distance / reach * 2.4 + t * 1.1)
            let fade = max(0, 1 - distance / (reach * 0.8))
            let level = wave * fade
            return (level, 1 + level * 0.6, Theme.signal)

        case .tap:
            // A solid disc in the middle with a quick beat.
            let inside = distance < reach * 0.42
            let beat = reduceMotion ? 1 : (0.8 + 0.2 * (sin(t * 14) * 0.5 + 0.5))
            let level: CGFloat = inside ? beat : 0.08
            return (level, inside ? 1.7 : 1, Theme.signal)

        case .success:
            let fade = max(0, 1 - distance / (reach * 0.75))
            return (0.35 + fade * 0.65, 1 + fade * 0.6, Theme.done)

        case .problem:
            let fade = max(0, 1 - distance / (reach * 0.75))
            return (0.25 + fade * 0.5, 1, Theme.alert)
        }
    }

    /// A soft-edged band that repeats every 1.0 of `x`.
    private func pulse(_ x: CGFloat) -> CGFloat {
        let phase = x - floor(x)
        let band = 1 - abs(phase - 0.5) * 2
        return pow(max(0, band), 2.2)
    }

    private func blend(_ lit: Color, _ level: CGFloat) -> Color {
        let amount = min(max(level, 0), 1)
        return amount <= 0.01 ? Theme.dotOff : lit.opacity(0.16 + 0.84 * amount)
    }
}
