import SwiftUI

@main
struct NudgeWatchApp: App {
    @StateObject private var link = WatchLink.shared

    var body: some Scene {
        WindowGroup {
            WatchBootstrapView()
                .environmentObject(link)
                .onAppear { link.start() }
        }
    }
}

/// Bootstrap screen: shows link status and lets you test a haptic locally.
struct WatchBootstrapView: View {
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        VStack(spacing: 8) {
            Text("Nudge")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(link.status)
                .font(.footnote)
                .multilineTextAlignment(.center)
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
