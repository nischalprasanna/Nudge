import SwiftUI

@main
struct NudgeWatchApp: App {
    @StateObject private var link = WatchLink.shared
    @StateObject private var keeper = RuntimeKeeper.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(link)
                .environmentObject(keeper)
                .onAppear {
                    link.start()
                    keeper.start()
                    #if targetEnvironment(simulator)
                    // For checking the layout: launch with -NudgePreview seeking | tap | done | problem | working.
                    switch UserDefaults.standard.string(forKey: "NudgePreview") {
                    case "seeking":
                        let defaults = UserDefaults.standard
                        WatchGuidance.shared.update(phase: .seeking,
                                                    closeness: defaults.object(forKey: "NudgeCloseness") == nil ? 0.55 : defaults.double(forKey: "NudgeCloseness"),
                                                    direction: CGVector(dx: -1, dy: 0.3),
                                                    word: defaults.string(forKey: "NudgeWord") ?? "Left a little")
                    case "far": WatchGuidance.shared.update(phase: .seeking, closeness: 0.1, direction: CGVector(dx: 1, dy: -1), word: "Up")
                    case "tap": WatchGuidance.shared.update(phase: .tap, closeness: 1, direction: nil, word: "Tap")
                    case "done": WatchGuidance.shared.update(phase: .done, closeness: nil, direction: nil, word: "")
                    case "problem": WatchGuidance.shared.update(phase: .problem, closeness: nil, direction: nil, word: "")
                    case "working": WatchGuidance.shared.update(phase: .working, closeness: nil, direction: nil, word: "")
                    default: break
                    }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { keeper.start() }
                }
        }
    }
}

/// The Watch's one screen. It mirrors the phone: the same dots, the same cue word, and it says
/// plainly whether it is connected. The wrist does the real work; this is for onlookers, for
/// low-vision users, and for checking that everything is linked up.
struct WatchHomeView: View {
    @EnvironmentObject private var link: WatchLink
    @EnvironmentObject private var keeper: RuntimeKeeper
    @ObservedObject private var guidance = WatchGuidance.shared
    @State private var cueSize: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            WatchDotField(phase: guidance.phase, closeness: guidance.closeness, direction: guidance.direction,
                          gap: cueSize)
                .ignoresSafeArea()
            content
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { cueSize = proxy.size }
                            .onChange(of: proxy.size) { _, size in cueSize = size }
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var content: some View {
        switch guidance.phase {
        case .idle:
            Button {
                link.play(.ping)
            } label: {
                VStack(spacing: 6) {
                    BrailleN(height: 30)
                    Text("Nudge")
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(.white)
                    Text(link.status)
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(WatchTheme.quiet)
                        .multilineTextAlignment(.center)
                    Text(keeper.status)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(WatchTheme.quiet.opacity(0.8))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

        case .working:
            Text("Working")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(WatchTheme.quiet)
                .padding(8)

        case .seeking:
            VStack(spacing: 0) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .heavy))
                }
                Text(mainWord)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if isSmallStep {
                    Text("a little")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(WatchTheme.quiet)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

        case .tap:
            Label("Tap", systemImage: "hand.tap.fill")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(WatchTheme.signal, in: Capsule())

        case .done:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(WatchTheme.done)
                .padding(8)

        case .problem:
            Label("Stopped", systemImage: "exclamationmark.triangle.fill")
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(WatchTheme.alert)
                .padding(8)
        }
    }

    /// "Left a little" is shown as a large "Left" with "a little" beneath.
    private var mainWord: String {
        let first = guidance.word.split(separator: " ").first.map(String.init) ?? ""
        if first.isEmpty { return guidance.closeness == nil ? "No finger" : "" }
        return first
    }

    private var isSmallStep: Bool { guidance.word.hasSuffix("a little") }

    private var symbol: String? {
        switch mainWord {
        case "Left": return "arrow.left"
        case "Right": return "arrow.right"
        case "Up": return "arrow.up"
        case "Down": return "arrow.down"
        default: return nil
        }
    }

    private var spoken: String {
        switch guidance.phase {
        case .idle: return "Nudge. \(link.status). \(keeper.status). Double tap to test the buzz."
        case .working: return "Working"
        case .seeking: return guidance.word.isEmpty ? "Guiding" : guidance.word
        case .tap: return "Tap"
        case .done: return "Done"
        case .problem: return "Stopped"
        }
    }
}

/// The Nudge mark: the letter "n" in braille (dots 1, 3, 4 and 5).
struct BrailleN: View {
    var height: CGFloat = 30

    private static let pattern: [[Bool]] = [[true, true], [false, true], [true, false]]

    var body: some View {
        let dot = height / 4.2
        let gap = (height - dot * 3) / 2
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { column in
                        Circle()
                            .fill(Self.pattern[row][column] ? WatchTheme.signal : WatchTheme.dotOff)
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
