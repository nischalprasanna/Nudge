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
    @AppStorage("wornOnChest") private var wornOnChest = false
    @AppStorage("marker.on") private var markerOn = false

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

                Section {
                    Toggle(isOn: $wornOnChest) {
                        Label("Worn on the chest", systemImage: "person.crop.rectangle")
                    }
                } header: {
                    Text("How you carry the phone")
                } footer: {
                    Text("Turn this on when the phone is tucked into a shirt or hangs on a lanyard with its screen against you. During a task the screen switches off and ignores touches while it is covered, so your body cannot press Stop. Take the phone out to use the controls.")
                }

                Section {
                    Toggle(isOn: $markerOn) {
                        Label("Fingernail marker", systemImage: "circle.circle")
                    }
                    NavigationLink("Set the marker colour") {
                        PerceptionTestView()
                    }
                } header: {
                    Text("Finger tracking")
                } footer: {
                    Text("A small bright sticker or dab of colour on the nail of your pointing finger lets Nudge follow it exactly, even when only your fingertip is in view. Set the colour once: hold the marker in the yellow circle and press Use colour in circle. Pick a colour that is not on the appliance.")
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
