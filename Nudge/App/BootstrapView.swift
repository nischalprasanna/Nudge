import SwiftUI
import UIKit

/// Home screen: start a task, plus test tools.
struct BootstrapView: View {
    @EnvironmentObject private var watchLink: PhoneWatchLink

    var body: some View {
        VStack(spacing: 20) {
            Text("Nudge")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            NavigationLink {
                TaskView()
            } label: {
                Text("Start a task")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens the camera and guides you through using a touchscreen")

            NavigationLink {
                PerceptionTestView()
            } label: {
                Text("Perception test")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Test screen for anchoring, fingertip tracking and text reading")

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                watchLink.send(.ping)
            } label: {
                Text("Buzz Watch")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Sends a test vibration to your Apple Watch")

            Text(watchLink.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Watch status: \(watchLink.status)")

            Spacer()
        }
        .padding(24)
    }
}
