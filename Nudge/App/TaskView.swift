import SwiftUI

/// The working screen. The top half shows what the camera and Nudge see; the bottom half says,
/// in large type and in the dot field, exactly what is being spoken and beeped.
///
/// A blind user never needs to look at it: one large button, everything else by ear. It is laid
/// out so that a low-vision user can read the current step from arm's length, and so that
/// someone watching can follow along.
struct TaskView: View {
    /// Start a task as soon as the screen opens (used when arriving from the home screen's Start).
    var autoStart = true

    @StateObject private var session = TaskSession()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showGoalEntry = false
    @State private var typedGoal = ""
    @State private var didAutoStart = false
    /// The phone is tucked into a shirt or on a lanyard, screen against the body.
    @AppStorage("wornOnChest") private var wornOnChest = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                camera
                    .frame(height: proxy.size.height * 0.44 + proxy.safeAreaInsets.top)
                panel
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 18)
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom, 12))
            }
            .ignoresSafeArea(edges: [.top, .bottom])
        }
        .background(Theme.ink.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showGoalEntry) { goalEntry }
        .accessibilityAction(.magicTap) { toggle() }
        .accessibilityAction(.escape) { dismiss() }
        .onAppear {
            #if targetEnvironment(simulator)
            if let state = UserDefaults.standard.string(forKey: "NudgePreview") {
                session.applyPreview(state)
                return
            }
            #endif
            setWorkingMode(true)
            session.prepare()
            if autoStart, !didAutoStart {
                didAutoStart = true
                session.start(handsFree: wornOnChest)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Worn on the chest, the app is reopened by voice ("Hey Siri, open Nudge"), and
            // nothing can be pressed: coming back to this screen starts the conversation again.
            if phase == .background { wasInBackground = true }
            if phase == .active, wasInBackground {
                wasInBackground = false
                if wornOnChest, !session.isRunning { session.start(handsFree: true) }
            }
        }
        .onDisappear {
            setWorkingMode(false)
            session.shutdown()
        }
    }

    /// While this screen is open the phone must not lock itself: nobody touches it during a task.
    /// When it is worn, the proximity sensor (the one that blanks the screen against your ear on
    /// a call) also switches the screen off and ignores touches while the phone is against the
    /// body, so the wearer's chest cannot press Stop or Close.
    private func setWorkingMode(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
        UIDevice.current.isProximityMonitoringEnabled = on && wornOnChest
    }

    // MARK: Camera

    private var camera: some View {
        ZStack(alignment: .top) {
            CameraPane(pipeline: session.pipeline)
                .accessibilityHidden(true)

            // The hands-free opening: Nudge is asking what to do and the camera has no job yet.
            if session.isGreeting {
                ZStack {
                    Theme.ink
                    VStack(spacing: 18) {
                        NudgeWordmark()
                        Image(systemName: "waveform")
                            .font(.system(size: 54, weight: .bold))
                            .foregroundStyle(Theme.signal)
                            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                        Text("What do you want to do?")
                            .font(Theme.title(.title))
                            .foregroundStyle(Theme.paper)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.gutter)
                    }
                    .padding(.top, 40)
                }
                .transition(.opacity)
                .accessibilityHidden(true) // The status below says the same, and it is spoken aloud.
            }

            HStack {
                FloatingIconButton(systemName: "chevron.down", label: "Close",
                                   hint: "Stops the task and goes back") { dismiss() }
                Spacer()
                FloatingIconButton(systemName: "keyboard", label: "Type a goal",
                                   hint: "Enter what you want to do with the keyboard instead of speaking") {
                    showGoalEntry = true
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 58)
        }
        .animation(Theme.fade, value: session.isGreeting)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: Theme.panelRadius,
                                          bottomTrailingRadius: Theme.panelRadius,
                                          style: .continuous))
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            status
            GuideStage(visual: session.visual)
                .frame(maxWidth: .infinity, minHeight: 84, maxHeight: .infinity)
            TrailView(goal: session.goal, steps: session.trail)
            Button {
                toggle()
            } label: {
                Label(session.isRunning ? "Stop" : (session.outcome == .none ? "Start" : "Start again"),
                      systemImage: session.isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(MainButtonStyle(kind: session.isRunning ? .stop : .go))
            .accessibilityHint(session.isRunning
                               ? "Stops the current task"
                               : "Finds the touchscreen, then asks what you want to do")
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .symbolEffect(.pulse, isActive: session.isRunning && !reduceMotion)
                Text(statusTitle)
            }
            .font(Theme.label(.headline))
            .foregroundStyle(statusColor)

            Text(instructionText)
                .font(Theme.title(.title))
                .foregroundStyle(Theme.paper)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .id(instructionText)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? Theme.fade : Theme.arrive, value: instructionText)
        .animation(Theme.fade, value: statusTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(statusTitle). \(instructionText)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var statusTitle: String {
        if session.isRunning { return session.phase.rawValue }
        switch session.outcome {
        case .none: return "Ready"
        case .done: return "Done"
        case .problem: return "Stopped"
        }
    }

    private var statusSymbol: String {
        if session.isRunning { return session.phase.symbol }
        switch session.outcome {
        case .none: return "circle.grid.2x2"
        case .done: return "checkmark.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        if session.isRunning { return Theme.quiet }
        switch session.outcome {
        case .none: return Theme.quiet
        case .done: return Theme.done
        case .problem: return Theme.alert
        }
    }

    private var instructionText: String {
        if !session.instruction.isEmpty { return session.instruction }
        return session.isRunning ? "Point the phone at the touchscreen." : "Press Start and say what you want to do."
    }

    private func toggle() {
        if session.isRunning {
            session.stop()
        } else {
            session.start(handsFree: wornOnChest)
        }
    }

    // MARK: Typing a goal

    private var goalEntry: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("What do you want to do?")
                    .font(Theme.title(.title2))
                    .foregroundStyle(Theme.paper)
                TextField("For example: heat for 90 seconds", text: $typedGoal, axis: .vertical)
                    .font(Theme.body(.title3))
                    .lineLimit(1...3)
                    .padding(16)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .submitLabel(.go)
                    .onSubmit(startTyped)
                    .accessibilityLabel("Goal")
                Button(action: startTyped) {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(MainButtonStyle(kind: .go))
                .disabled(typedGoal.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(typedGoal.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                Spacer()
            }
            .padding(Theme.gutter)
            .background(Theme.ink.ignoresSafeArea())
            .navigationTitle("Type a goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showGoalEntry = false }
                }
            }
        }
        .tint(Theme.signal)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func startTyped() {
        let goal = typedGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        showGoalEntry = false
        if session.isRunning { session.stop(announce: false) }
        session.start(typedGoal: goal)
    }
}

/// Camera preview with the corners, target and fingertip drawn on top.
/// A separate view so it redraws when the pipeline publishes, without redrawing the controls.
private struct CameraPane: View {
    @ObservedObject var pipeline: PerceptionPipeline

    private var debugLine: String {
        if !pipeline.searchInfo.isEmpty { return pipeline.searchInfo }
        return pipeline.status.hasPrefix("Read ") ? pipeline.status : ""
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ARPreview(session: pipeline.session)
            OverlayCanvas(overlay: pipeline.overlay, imageAspect: pipeline.portraitAspect)
            // While searching: what the finder sees, so a screen recording shows why it is stuck.
            // After a read: how many labels were found.
            if !debugLine.isEmpty {
                Text(debugLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.ink.opacity(0.7), in: Capsule())
                    .padding(.bottom, 12)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The dot field, with the current one-word cue set large on top of it.
private struct GuideStage: View {
    @ObservedObject var visual: GuidanceVisual
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cueSize: CGSize = .zero

    var body: some View {
        ZStack {
            DotField(mode: visual.mode, gap: visual.word.isEmpty ? .zero : cueSize)
            if !visual.word.isEmpty {
                cue
                    .id(visual.word)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? Theme.fade : Theme.arrive, value: visual.word)
        .accessibilityHidden(true) // The same word is spoken aloud.
    }

    private var cue: some View {
        let onDisc = visual.mode == .tap
        return HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(visual.word)
        }
        .font(.system(size: visual.word.count > 8 ? 40 : 50, weight: .heavy, design: .rounded))
        .foregroundStyle(onDisc ? Theme.ink : Theme.paper)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .padding(.horizontal, onDisc ? 26 : 14)
        .padding(.vertical, onDisc ? 6 : 2)
        .background {
            // "Tap" is the one moment that matters most: solid yellow, black type.
            if onDisc { Capsule().fill(Theme.signal) }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { cueSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in cueSize = size }
            }
        }
    }

    private var symbol: String? {
        // "Left a little" takes the same arrow as "Left".
        switch visual.word.split(separator: " ").first.map(String.init) ?? "" {
        case "Left": return "arrow.left"
        case "Right": return "arrow.right"
        case "Up": return "arrow.up"
        case "Down": return "arrow.down"
        case "Closer": return "arrow.down.to.line"
        case "Lift": return "arrow.up.to.line"
        case "Tap": return "hand.tap.fill"
        default: return nil
        }
    }
}

/// The goal and the buttons pressed so far.
private struct TrailView: View {
    let goal: String
    let steps: [TrailStep]

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if !goal.isEmpty {
                        chip(text: goal, symbol: "quote.opening", tint: Theme.quiet, outlined: false)
                    }
                    ForEach(steps) { step in
                        chip(text: step.name, symbol: symbol(for: step.state), tint: tint(for: step.state),
                             outlined: step.state == .current)
                            .id(step.id)
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            .frame(height: goal.isEmpty && steps.isEmpty ? 0 : 40)
            .onChange(of: steps.count) { _, _ in
                if let last = steps.last {
                    withAnimation(Theme.move) { reader.scrollTo(last.id, anchor: .trailing) }
                }
            }
        }
        .animation(Theme.move, value: steps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHidden(goal.isEmpty && steps.isEmpty)
    }

    private func chip(text: String, symbol: String, tint: Color, outlined: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(Theme.paper)
                .lineLimit(1)
        }
        .font(Theme.label(.subheadline))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Theme.surface, in: Capsule())
        .overlay {
            if outlined { Capsule().strokeBorder(Theme.signal, lineWidth: 2) }
        }
    }

    private func symbol(for state: TrailStep.State) -> String {
        switch state {
        case .current: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func tint(for state: TrailStep.State) -> Color {
        switch state {
        case .current: return Theme.signal
        case .done: return Theme.done
        case .failed: return Theme.alert
        }
    }

    private var spoken: String {
        var parts: [String] = []
        if !goal.isEmpty { parts.append("Goal: \(goal)") }
        for step in steps {
            switch step.state {
            case .current: parts.append("\(step.name), in progress")
            case .done: parts.append("\(step.name), done")
            case .failed: parts.append("\(step.name), missed")
            }
        }
        return parts.joined(separator: ". ")
    }
}
