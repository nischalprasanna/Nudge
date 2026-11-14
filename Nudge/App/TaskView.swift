import SwiftUI

/// The main screen: one large button starts a task, and everything else is spoken.
struct TaskView: View {
    @StateObject private var session = TaskSession()
    @State private var typedGoal = ""
    @FocusState private var goalFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            CameraPane(pipeline: session.pipeline)
                .accessibilityHidden(true)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                Text(session.phase.rawValue)
                    .font(.title3.bold())
                    .accessibilityLabel("Status: \(session.phase.rawValue)")

                if !session.goal.isEmpty {
                    Text("Goal: \(session.goal)")
                        .font(.body)
                }

                if let last = session.transcript.last {
                    Text(last)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .accessibilityHidden(true)
                }

                Button {
                    goalFieldFocused = false
                    if session.isRunning {
                        session.stop()
                    } else {
                        session.start(typedGoal: typedGoal)
                    }
                } label: {
                    Text(session.isRunning ? "Stop" : "Start")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, minHeight: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(session.isRunning ? .red : .blue)
                .accessibilityHint(session.isRunning
                                   ? "Stops the current task"
                                   : "Finds the touchscreen, then asks what you would like to do")

                TextField("Or type a goal, e.g. heat for 90 seconds", text: $typedGoal)
                    .textFieldStyle(.roundedBorder)
                    .focused($goalFieldFocused)
                    .submitLabel(.done)
                    .disabled(session.isRunning)
                    .accessibilityLabel("Type a goal instead of speaking")

                HStack(spacing: 16) {
                    Toggle("Tones", isOn: $session.channels.tones)
                    Toggle("Voice", isOn: $session.channels.voice)
                }
                .font(.body)

                Text("\(session.plannerName) · \(session.pipeline.hasLiDAR ? "LiDAR on" : "No LiDAR")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Nudge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Re-find screen") { session.pipeline.clearAnchor() }
                    .disabled(session.isRunning)
                    .accessibilityHint("Forgets the current screen so Nudge looks for it again")
            }
        }
        .onAppear { session.prepare() }
        .onDisappear { session.shutdown() }
    }
}

/// Camera preview with the outline, target and fingertip drawn on top.
/// A separate view so it redraws when the pipeline publishes, without redrawing the controls.
private struct CameraPane: View {
    @ObservedObject var pipeline: PerceptionPipeline

    var body: some View {
        ZStack {
            ARPreview(session: pipeline.session)
            OverlayCanvas(overlay: pipeline.overlay, imageAspect: pipeline.portraitAspect)
        }
    }
}
