import SwiftUI

@main
struct NudgeWatchApp: App {
    @StateObject private var link = WatchLink.shared
    @StateObject private var keeper = RuntimeKeeper.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchBootstrapView()
                .environmentObject(link)
                .environmentObject(keeper)
                .onAppear {
                    link.start()
                    keeper.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { keeper.start() }
                }
        }
    }
}

/// Bootstrap screen: shows link status and lets you test a haptic locally.
struct WatchBootstrapView: View {
    @EnvironmentObject private var link: WatchLink
    @EnvironmentObject private var keeper: RuntimeKeeper

    var body: some View {
        VStack(spacing: 8) {
            Text("Nudge")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(link.status)
                .font(.footnote)
                .multilineTextAlignment(.center)
            Text(keeper.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Last: \(link.lastCommand)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Last haptic: \(link.lastCommand)")
            Button("Test buzz") {
                link.play(.ping)
            }
            .accessibilityHint("Plays a test vibration on this Watch")
        }
        .padding()
    }
}
