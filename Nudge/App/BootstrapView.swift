import SwiftUI
import UIKit

/// Bootstrap screen: one large button that makes the Watch vibrate.
/// Replaced by the real task screen once the core loop lands.
struct BootstrapView: View {
    @EnvironmentObject private var watchLink: PhoneWatchLink

    var body: some View {
        VStack(spacing: 24) {
            Text("Nudge")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            Text(watchLink.status)
                .font(.title3)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Watch status: \(watchLink.status)")

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                watchLink.send(.ping)
            } label: {
                Text("Buzz Watch")
                    .font(.title.bold())
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Sends a test vibration to your Apple Watch")

            NavigationLink {
                PerceptionTestView()
            } label: {
                Text("Perception test")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Opens the camera to test screen anchoring, fingertip tracking and text reading")

            Spacer()
        }
        .padding(24)
        .onChange(of: watchLink.status) { _, newValue in
            UIAccessibility.post(notification: .announcement, argument: newValue)
        }
    }
}
