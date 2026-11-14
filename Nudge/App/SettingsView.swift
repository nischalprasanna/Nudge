import ARKit
import SwiftUI

/// Feedback choices, what this build is using, and the test tools.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchLink: PhoneWatchLink
    @ObservedObject private var log = TestLog.shared
    @State private var confirmClear = false

    @AppStorage("channel.tones") private var tones = true
    @AppStorage("channel.voice") private var voice = true
    @AppStorage("channel.watch") private var watch = true

    private var plannerName: String {
        CloudPlanner.fromConfiguredKeys()?.name ?? "Not set up (no key in this build)"
    }

    private var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $tones) {
                        Label("Guidance tones", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Toggle(isOn: $voice) {
                        Label("Spoken directions", systemImage: "waveform")
                    }
                    Toggle(isOn: $watch) {
                        Label("Apple Watch taps", systemImage: "applewatch.radiowaves.left.and.right")
                    }
                } header: {
                    Text("How Nudge guides you")
                } footer: {
                    Text("Use any combination. Tones move left and right with the button, rise when it is higher, and speed up as you get close. With tones and voice both off, guidance comes through the watch alone.")
                }

                Section("This phone") {
                    LabeledContent("Depth sensor", value: hasLiDAR ? "LiDAR available" : "Not available")
                    LabeledContent("Step planning", value: plannerName)
                    LabeledContent("Apple Watch", value: watchLink.status)
                }

                Section {
                    LabeledContent("Attempts recorded", value: "\(log.records.count)")
                    if let rate = log.successRate {
                        LabeledContent("Completed", value: "\(Int((rate * 100).rounded())) percent")
                    }
                    if let url = log.exportCSV(), !log.records.isEmpty {
                        ShareLink(item: url) {
                            Label("Share as a spreadsheet file", systemImage: "square.and.arrow.up")
                        }
                    }
                    if !log.records.isEmpty {
                        Button("Clear the log", role: .destructive) { confirmClear = true }
                    }
                } header: {
                    Text("Test log")
                } footer: {
                    Text("Each task is recorded on this phone: goal, steps, corrections, time and result. Nothing is sent anywhere unless you share the file.")
                }

                Section {
                    NavigationLink("Camera and tracking test") {
                        PerceptionTestView()
                    }
                    Button("Send a test tap to the watch") {
                        Haptics.tap()
                        watchLink.send(.ping)
                    }
                } header: {
                    Text("Test tools")
                } footer: {
                    Text("For checking the camera, finger tracking and watch link.")
                }
            }
            .confirmationDialog("Clear every recorded attempt?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear the log", role: .destructive) { log.clear() }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.signal)
        .preferredColorScheme(.dark)
    }
}
