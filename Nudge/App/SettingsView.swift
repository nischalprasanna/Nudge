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
    @AppStorage(TrackRecorder.settingKey) private var recordTracking = false
    @AppStorage(DemoRecorder.settingKey) private var demoVideo = true
    @State private var videos: [URL] = []
    @AppStorage(DemoSafe.onKey) private var demoSafe = false
    @AppStorage(DemoSafe.deviceKey) private var demoDevice = ""
    @ObservedObject private var store = DeviceStore.shared

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
                    if store.devices.isEmpty {
                        Text("No saved devices yet. After a task goes right, Nudge offers to remember the device.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.devices) { device in
                        NavigationLink {
                            DeviceDetailView(deviceID: device.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text("\(device.keys.count) keys, \(device.routines.count) saved \(device.routines.count == 1 ? "task" : "tasks")")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("My devices")
                } footer: {
                    Text("A saved device keeps its key labels and where they are, never pictures, and only on this phone. On a saved device, a task you have done before starts at once and needs no internet.")
                }

                Section {
                    Toggle(isOn: $demoSafe) {
                        Label("Demo-safe mode", systemImage: "lock.shield")
                    }
                    .disabled(store.devices.isEmpty)
                    if demoSafe, !store.devices.isEmpty {
                        Picker("Device", selection: $demoDevice) {
                            ForEach(store.devices) { device in
                                Text(device.name).tag(device.id.uuidString)
                            }
                        }
                    }
                } header: {
                    Text("For demonstrations")
                } footer: {
                    Text("With this on, Nudge uses only the chosen saved device and the tasks saved for it, and makes no network requests while guiding, so a dropped connection cannot stall it. Tasks that have not been saved are not available until it is turned off. Speech is recognised on the phone where the phone supports that.")
                }
                .onAppear {
                    if store.device(UUID(uuidString: demoDevice)) == nil { demoDevice = store.devices.first?.id.uuidString ?? "" }
                    if store.devices.isEmpty { demoSafe = false }
                }

                Section {
                    Toggle(isOn: $wornOnChest) {
                        Label("Worn on the chest", systemImage: "person.crop.rectangle")
                    }
                } header: {
                    Text("How you carry the phone")
                } footer: {
                    Text("Turn this on when the phone is tucked into a shirt or hangs on a lanyard with its screen against you. Nudge then works by voice alone: as soon as it opens it asks what you want to do, and when a task ends it asks what to do next, so nothing needs pressing. Open it by saying \"Hey Siri, open Nudge\". The buttons all still work. During a task the screen switches off and ignores touches while it is covered, so your body cannot press Stop. Take the phone out to use the controls. Aiming directions are given as body movements: lean forward, lean back, turn your body.")
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
                    Toggle(isOn: $demoVideo) {
                        Label("Make a video of each task", systemImage: "video")
                    }
                    if let latest = videos.first {
                        ShareLink(item: latest) {
                            Label("Share the latest video", systemImage: "square.and.arrow.up")
                        }
                        if videos.count > 1 {
                            NavigationLink("All \(videos.count) videos") {
                                List(videos, id: \.self) { url in
                                    ShareLink(item: url) {
                                        Text(url.deletingPathExtension().lastPathComponent)
                                    }
                                }
                                .navigationTitle("Task videos")
                            }
                        }
                    } else {
                        Text("No videos yet.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Task videos")
                } footer: {
                    Text("Nudge draws its own video of each task: the camera view with the screen outline, the key to press and your fingertip marked, and what it is saying underneath. It works with the screen off and is not stopped by Siri. There is no sound. The newest twelve are kept on this phone.")
                }
                .onAppear { videos = DemoRecorder.videos }

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
                    Toggle("Record tracking frames", isOn: $recordTracking)
                    Button("Send a test tap to the watch") {
                        Haptics.tap()
                        watchLink.send(.ping)
                    }
                } header: {
                    Text("Test tools")
                } footer: {
                    Text("For checking the camera, finger tracking and watch link. Recording keeps the camera pictures from the last task on this phone, for copying to a Mac over the cable. Nothing is sent anywhere. Leave it off for normal use.")
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
