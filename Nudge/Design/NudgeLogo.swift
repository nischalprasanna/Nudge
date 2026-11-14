import SwiftUI

/// The Nudge mark: the letter "n" in braille (dots 1, 3, 4 and 5 of the six-dot cell).
///
/// It is the app's name written for the people it is built for, and it is made of the same
/// dots as the rest of the interface.
struct NudgeMark: View {
    /// Height of the mark. Width follows from the braille cell's proportions.
    var height: CGFloat = 44
    var lit: Color = Theme.signal
    var unlit: Color = Theme.dotOff

    /// Braille "n": left column top and bottom, right column top and middle.
    static let pattern: [[Bool]] = [
        [true, true],
        [false, true],
        [true, false],
    ]

    var body: some View {
        let dot = height / 4.2
        let gap = (height - dot * 3) / 2
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { column in
                        Circle()
                            .fill(Self.pattern[row][column] ? lit : unlit)
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Mark plus name, for the top of the home screen.
struct NudgeWordmark: View {
    var body: some View {
        HStack(spacing: 14) {
            NudgeMark(height: 40)
            Text("Nudge")
                .font(Theme.display(.largeTitle))
                .foregroundStyle(Theme.paper)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nudge")
        .accessibilityAddTraits(.isHeader)
    }
}
