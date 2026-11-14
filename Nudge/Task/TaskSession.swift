import Combine
import SwiftUI
import UIKit

/// What the dot field and the direction word are showing. Kept apart from `TaskSession`
/// because it changes many times a second while guiding, and only the visualiser should redraw.
@MainActor
final class GuidanceVisual: ObservableObject {
    @Published var mode: DotFieldMode = .idle
    /// The latest one-word cue ("Left", "Closer", "Tap"), without its full stop. Empty when there is none.
    @Published var word = ""
}

/// One button press in the current task, for the progress trail.
struct TrailStep: Identifiable, Equatable {
    enum State { case current, done, failed }
    let id = UUID()
    var name: String
    var state: State
}

/// Runs one task from start to finish: find the screen, read it, hear the goal, then loop
/// plan -> guide -> tap -> re-read -> verify until the goal is done.
@MainActor
final class TaskSession: ObservableObject {
    enum Phase: String {
        case idle = "Ready"
        case findingScreen = "Looking for the screen"
        case reading = "Reading the screen"
        case listening = "Listening"
        case planning = "Working out the next step"
        case guiding = "Guiding your finger"
        case verifying = "Checking the screen"

        /// SF Symbol shown beside the phase name.
        var symbol: String {
            switch self {
            case .idle: return "circle.grid.2x2"
            case .findingScreen: return "viewfinder"
            case .reading: return "text.viewfinder"
            case .listening: return "waveform"
            case .planning: return "ellipsis"
            case .guiding: return "hand.point.up.left"
            case .verifying: return "checkmark.circle"
            }
        }
    }

    /// How the last task ended.
    enum Outcome: Equatable { case none, done, problem }

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != .guiding { refreshVisual() } }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var goal = ""
    /// The current full instruction, as last spoken ("Press Time Cook.").
    @Published private(set) var instruction = ""
    @Published private(set) var trail: [TrailStep] = []
    @Published private(set) var outcome: Outcome = .none
    @Published private(set) var transcript: [String] = []
    @Published private(set) var plannerName = "No planner (API key not set)"
    @Published var channels = TaskSession.savedChannels() {
        didSet {
            applyChannels()
            Self.save(channels)
        }
    }

    let pipeline = PerceptionPipeline()
    let visual = GuidanceVisual()

    /// One-word cues given during guidance. They drive the big word on screen, not the instruction line.
    private static let cueWords: Set<String> = ["Left.", "Right.", "Up.", "Down.", "Closer.", "Lift.", "Tap."]

    private let speaker = Speaker()
    private let listener = Listener()
    private let tones = ToneEngine()
    private let guidance: GuidanceEngine
    private var planner: TaskPlanner?
    private var runTask: Task<Void, Never>?
    private var isPrepared = false
    /// When the current attempt began. Nil once it has been written to the test log.
    private var attemptStarted: Date?

    init() {
        guidance = GuidanceEngine(tones: tones, speaker: speaker)
        if let cloud = CloudPlanner.fromConfiguredKeys() {
            planner = cloud
            plannerName = cloud.name
        }
        speaker.onSpeak = { [weak self] line in
            guard let self else { return }
            self.transcript.append(line)
            if self.transcript.count > 30 { self.transcript.removeFirst(self.transcript.count - 30) }
            if Self.cueWords.contains(line) || line.hasPrefix("Tap") {
                self.visual.word = line.hasPrefix("Tap") ? "Tap" : String(line.dropLast())
            } else {
                self.instruction = line
            }
        }
        listener.onLevel = { [weak self] level in
            guard let self, self.phase == .listening else { return }
            self.visual.mode = .listening(level: level)
        }
        guidance.onHaptic = { command in
            DispatchQueue.main.async { PhoneWatchLink.shared.send(command) }
        }
    }

    // MARK: Lifecycle

    /// Starts the camera and audio. Call when the task screen appears.
    func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        AudioSession.configure()
        tones.start()
        applyChannels()
        pipeline.onFinger = { [guidance] finger in guidance.update(finger: finger) }
        pipeline.start()
        Task { _ = await Listener.requestPermissions() }
    }

    /// Stops everything. Call when the task screen goes away.
    func shutdown() {
        stop(announce: false)
        pipeline.onFinger = nil
        pipeline.stop()
        tones.stop()
        isPrepared = false
    }

    func start(typedGoal: String? = nil) {
        guard !isRunning else { return }
        isRunning = true
        transcript.removeAll()
        goal = ""
        instruction = ""
        trail = []
        outcome = .none
        visual.word = ""
        Haptics.tap()
        attemptStarted = Date()
        runTask = Task { [weak self] in
            await self?.run(typedGoal: typedGoal)
            guard !Task.isCancelled else { return }
            self?.logAttempt(stopped: false)
            self?.finish()
        }
    }

    func stop(announce: Bool = true) {
        guard isRunning else { return }
        runTask?.cancel()
        runTask = nil
        logAttempt(stopped: true)
        finish()
        if announce { speaker.say("Stopped.") } else { speaker.stop() }
    }

    private func finish() {
        guidance.end()
        tones.silence()
        pipeline.setTarget(nil)
        isRunning = false
        phase = .idle
    }

    private func applyChannels() {
        guidance.channels = channels
        tones.isEnabled = channels.tones
        speaker.isEnabled = channels.voice
    }

    // MARK: Test log

    /// Records the attempt that just ended. Attempts that never got as far as a goal are not recorded.
    private func logAttempt(stopped: Bool) {
        guard let started = attemptStarted else { return }
        attemptStarted = nil
        guard !goal.isEmpty else { return }
        let result: String
        if stopped { result = "stopped" } else { result = outcome == .done ? "success" : "failed" }
        var on: [String] = []
        if channels.tones { on.append("tones") }
        if channels.voice { on.append("voice") }
        if channels.watch { on.append("watch") }
        let screen = pipeline.screenSizeText.isEmpty ? "Unsaved screen" : "Unsaved screen (\(pipeline.screenSizeText))"
        TestLog.shared.add(TaskRecord(startedAt: started,
                                      device: screen,
                                      goal: goal,
                                      outcome: result,
                                      reason: result == "success" ? "" : instruction,
                                      stepsCompleted: trail.filter { $0.state == .done }.count,
                                      recoveries: trail.filter { $0.state == .failed }.count,
                                      seconds: Date().timeIntervalSince(started),
                                      channels: on.isEmpty ? "none" : on.joined(separator: "+"),
                                      planner: plannerName))
    }

    // MARK: Saved preferences

    private static func savedChannels() -> FeedbackChannels {
        let defaults = UserDefaults.standard
        func value(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        return FeedbackChannels(tones: value("channel.tones"), voice: value("channel.voice"), watch: value("channel.watch"))
    }

    private static func save(_ channels: FeedbackChannels) {
        let defaults = UserDefaults.standard
        defaults.set(channels.tones, forKey: "channel.tones")
        defaults.set(channels.voice, forKey: "channel.voice")
        defaults.set(channels.watch, forKey: "channel.watch")
    }

    // MARK: What the screen shows

    /// Sets the dot field for every phase except guiding, which updates it continuously.
    private func refreshVisual() {
        switch phase {
        case .idle:
            switch outcome {
            case .none: visual.mode = .idle
            case .done: visual.mode = .success
            case .problem: visual.mode = .problem
            }
        case .listening:
            visual.mode = .listening(level: 0)
        case .findingScreen, .reading, .planning, .verifying:
            visual.mode = .working
        case .guiding:
            break
        }
        if phase != .guiding { visual.word = "" }
    }

    /// Ends the task on a good note: chime, tick, and the closing sentence.
    private func succeed(_ text: String) async {
        outcome = .done
        tones.playSuccess()
        Haptics.success()
        await speaker.sayAndWait(text)
    }

    /// Ends the task with a problem: error sound and what went wrong.
    private func fail(_ text: String) async {
        outcome = .problem
        tones.playError()
        Haptics.warning()
        await speaker.sayAndWait(text)
    }

    // MARK: The task loop

    private func run(typedGoal: String?) async {
        guard let planner else {
            await speaker.sayAndWait("The cloud key is not set yet, so I can't plan steps.")
            return
        }

        // 1. Find and anchor the screen, and 2. read it.
        // The camera looks for the screen from the moment this page opens. If the outline it
        // already has is still on a screen in view, use it and start at once. Otherwise look
        // afresh: an outline left over from earlier may no longer be on the screen.
        var first: (reading: ScreenReading, image: CGImage)?
        for attempt in 0..<3 {
            phase = .findingScreen
            var reused = false
            if attempt == 0, pipeline.isAnchored { reused = await pipeline.anchorStillValid() }
            if !reused {
                guidance.resetHeightCalibration()
                pipeline.clearAnchor()
                _ = await waitUntil(timeout: 1) { !self.pipeline.isAnchored }
                // Not awaited: the search runs while this is being said, and carries on as soon as it succeeds.
                if attempt == 0 { speaker.say("Point the phone at the touchscreen.") }
                var found = await waitUntil(timeout: 10) { self.pipeline.isAnchored }
                if !found, !Task.isCancelled {
                    // No outline with labels in it. Accept the middle of the view instead, as
                    // soon as there is something to read there, and give the user time to line up.
                    pipeline.anchorNow(requireText: true)
                    speaker.say("Still looking. Face the touchscreen from about an arm's length away.")
                    found = await waitUntil(timeout: 30) { self.pipeline.isAnchored }
                }
                guard found else {
                    pipeline.clearAnchor()
                    if !Task.isCancelled {
                        await fail("I couldn't find a touchscreen. Face it from about an arm's length away and try again.")
                    }
                    return
                }
                // Let the outline settle for a moment before reading.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if Task.isCancelled { return }

            phase = .reading
            guard let result = await readScreen() else { return }
            // A touchscreen has labels. Next to nothing readable means this is something else.
            if result.reading.elements.count >= Self.fewestLabelsForAScreen {
                first = result
                break
            }
            if attempt < 2 { await speaker.sayAndWait("That doesn't look like a touchscreen. Looking again.") }
        }
        guard var current = first else {
            if !Task.isCancelled {
                await fail("I couldn't find a touchscreen with buttons I can read, so I've stopped.")
            }
            return
        }
        await speaker.sayAndWait("Found it.")
        if await stopIfPayment(current.reading) { return }

        // 3. Get the goal.
        var spokenGoal = typedGoal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if spokenGoal.isEmpty {
            phase = .listening
            spokenGoal = await ask("What would you like to do?") ?? ""
            if spokenGoal.isEmpty, !Task.isCancelled {
                spokenGoal = await ask("I didn't catch that. What would you like to do?") ?? ""
            }
        }
        guard !spokenGoal.isEmpty, !Task.isCancelled else {
            if !Task.isCancelled { await speaker.sayAndWait("I didn't hear a goal. Press start to try again.") }
            return
        }
        goal = spokenGoal

        // 4. Plan, guide, verify, repeat.
        var history: [CompletedStep] = []
        var previous: ScreenReading?
        var confirmedRisk = false
        var sendImage = false
        var looks = 0

        for _ in 0..<24 {
            if Task.isCancelled { return }
            phase = .planning
            // Screens with little readable text are mostly icons, so the labels alone are not
            // enough: include a picture from the start, unless the screen may show something personal.
            let personal = SafetyScreen.mayShowPersonalInformation(current.reading)
            let fewLabels = current.reading.elements.count < Self.fewLabelsThreshold
            let attachImage = !personal && (sendImage || fewLabels)
            let request = PlanRequest(goal: spokenGoal, screen: current.reading, previousScreen: previous,
                                      history: history, userConfirmedRisk: confirmedRisk,
                                      imageJPEG: attachImage ? Self.jpeg(from: current.image) : nil)
            sendImage = false

            let step: PlanStep
            do {
                step = try await planner.nextStep(request)
            } catch {
                if Task.isCancelled { return }
                await fail("I couldn't reach the planner. \(error.localizedDescription)")
                return
            }
            if Task.isCancelled { return }

            switch step.action {
            case .done:
                await succeed(step.say.isEmpty ? "Done." : step.say)
                return

            case .refusePayment:
                await fail("This is a payment screen. Nudge does not handle payments, so I'm stopping here.")
                return

            case .cannot:
                await fail(step.say.isEmpty ? "I can't do that from this screen." : step.say)
                return

            case .look:
                looks += 1
                if SafetyScreen.mayShowPersonalInformation(current.reading) {
                    await fail("This screen may show personal information, so I won't send a picture of it. I can't work out the buttons from the text alone.")
                    return
                }
                guard looks <= 2 else {
                    await fail("I can't work out the buttons on this screen.")
                    return
                }
                sendImage = true

            case .confirm:
                phase = .listening
                let answer = await ask(step.say + " Say yes to continue, or no to stop.", maxSeconds: 7) ?? ""
                guard Self.isYes(answer) else {
                    await speaker.sayAndWait("Okay, I've stopped.")
                    return
                }
                confirmedRisk = true

            case .tap:
                guard let target = target(for: step, in: current.reading) else {
                    await fail("I couldn't locate that button on the screen.")
                    return
                }
                if !step.previousStepSucceeded {
                    tones.playError()
                    if let last = trail.indices.last { trail[last].state = .failed }
                }
                trail.append(TrailStep(name: target.name, state: .current))
                await speaker.sayAndWait(step.say.isEmpty ? "Next, press \(target.name)." : step.say)
                if Task.isCancelled { return }

                phase = .guiding
                // Explain the hand-away step once; after that a single word is enough.
                guidance.tapPhrase = history.isEmpty ? "Tap, then move your hand away." : "Tap."
                guard await guide(to: target) else {
                    if !Task.isCancelled {
                        await fail("I lost track of your finger for too long, so I've stopped.")
                    }
                    return
                }

                phase = .verifying
                Haptics.tap()
                if let last = trail.indices.last { trail[last].state = .done }
                history.append(CompletedStep(targetName: target.name, expected: step.expect))
                previous = current.reading
                confirmedRisk = false
                guard let fresh = await readSettledScreen(after: current.reading) else { return }
                current = fresh
                if await stopIfPayment(current.reading) { return }
            }
        }
        await speaker.sayAndWait("That took more steps than I expected, so I've stopped.")
    }

    // MARK: Steps

    /// Reads the screen, coaching the user if it is not fully in view.
    private func readScreen() async -> (reading: ScreenReading, image: CGImage)? {
        for attempt in 0..<5 {
            if Task.isCancelled { return nil }
            if let result = await pipeline.readScreenNow() { return result }
            if attempt == 0 || attempt == 2 {
                await speaker.sayAndWait("Move the phone back a little.")
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        if !Task.isCancelled {
            await fail("I couldn't read the screen, so I've stopped.")
        }
        return nil
    }

    /// Reads the screen after a press, waiting until it has finished changing.
    /// Screens animate and appliances redraw slowly, so one early read can catch a half-drawn state.
    private func readSettledScreen(after before: ScreenReading) async -> (reading: ScreenReading, image: CGImage)? {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard var latest = await readScreen() else { return nil }
        for _ in 0..<2 {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let next = await pipeline.readScreenNow() else { break }
            let settled = Self.labels(of: next.reading) == Self.labels(of: latest.reading)
            latest = next
            // Two matching reads in a row means the screen has stopped changing. If it still looks
            // exactly like it did before the press, give it one more chance to react.
            if settled, Self.labels(of: latest.reading) != Self.labels(of: before) { break }
            if settled { try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        return latest
    }

    private func stopIfPayment(_ reading: ScreenReading) async -> Bool {
        guard SafetyScreen.looksLikePayment(reading) else { return false }
        await fail("This looks like a payment screen. Nudge does not handle payments, so I'm stopping here.")
        return true
    }

    /// Speaks a question, plays the listening sound, and returns what the user said.
    private func ask(_ question: String, maxSeconds: TimeInterval = 10) async -> String? {
        await speaker.sayAndWait(question)
        if Task.isCancelled { return nil }
        tones.playListening()
        try? await Task.sleep(nanoseconds: 300_000_000)
        return await listener.listen(maxSeconds: maxSeconds)
    }

    private func target(for step: PlanStep, in reading: ScreenReading) -> GuidanceEngine.Target? {
        let size = pipeline.screenSize ?? CGSize(width: 0.1, height: 0.1)
        // Small models sometimes give an id that does not match the button they name.
        // The name is what gets spoken, so when the two disagree, trust the name.
        var index: Int? = reading.elements.indices.contains(step.targetID) ? step.targetID : nil
        let wanted = step.targetName.lowercased().trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty {
            let matchesID = index.map { reading.elements[$0].label.lowercased().contains(wanted)
                || wanted.contains(reading.elements[$0].label.lowercased()) } ?? false
            if !matchesID,
               let byName = reading.elements.firstIndex(where: { $0.label.lowercased() == wanted })
                ?? reading.elements.firstIndex(where: { $0.label.lowercased().contains(wanted) }) {
                index = byName
            }
        }
        if let index {
            let element = reading.elements[index]
            // Aim for the label; the button is at least as big as its text.
            let halfWidth = Float(element.box.width * size.width) / 2
            let halfHeight = Float(element.box.height * size.height) / 2
            let radius = min(max(max(halfWidth, halfHeight) * 0.8, 0.008), 0.02)
            let name = step.targetName.isEmpty ? element.label : step.targetName
            return GuidanceEngine.Target(uv: element.center, radius: radius, name: name)
        }
        if step.targetID == -1, (0...100).contains(step.targetX), (0...100).contains(step.targetY),
           step.targetX + step.targetY > 0 {
            let uv = CGPoint(x: step.targetX / 100, y: step.targetY / 100)
            return GuidanceEngine.Target(uv: uv, radius: 0.01, name: step.targetName.isEmpty ? "the button" : step.targetName)
        }
        return nil
    }

    /// Guides the finger to the target. Returns true once the user has reached it and pulled
    /// their hand away (which is when they will have tapped). False on timeout or cancel.
    private func guide(to target: GuidanceEngine.Target) async -> Bool {
        guard let size = pipeline.screenSize else { return false }
        pipeline.setTarget(target.uv)
        guidance.begin(target: target, screenWidth: Float(size.width), screenHeight: Float(size.height))
        defer {
            guidance.end()
            pipeline.setTarget(nil)
        }

        let started = Date()
        var awaySince: Date?
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let snapshot = guidance.snapshot
            switch snapshot.phase {
            case .onTarget:
                visual.mode = .tap
            case .aboveTarget:
                visual.mode = .closer
            case .seeking, .idle:
                if let offset = snapshot.offset, let distance = snapshot.distance {
                    visual.mode = .seeking(direction: CGVector(dx: CGFloat(offset.x), dy: CGFloat(offset.y)),
                                           closeness: 1 - min(distance / 0.12, 1))
                } else {
                    visual.mode = .working
                    visual.word = ""
                }
            }
            if snapshot.hasArrived {
                let finger = pipeline.finger
                let away = finger.map { !(-0.3...1.3).contains($0.uv.x) || !(-0.3...1.3).contains($0.uv.y) } ?? true
                if away {
                    let since = awaySince ?? Date()
                    awaySince = since
                    if Date().timeIntervalSince(since) > 0.6 { return true }
                } else {
                    awaySince = nil
                }
            }
            if Date().timeIntervalSince(started) > 120 { return false }
        }
        return false
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if condition() { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    /// Below this many readable labels, a picture of the screen is sent along with them.
    private static let fewLabelsThreshold = 8
    /// Fewer readable labels than this and the thing in view is not treated as a touchscreen.
    private static let fewestLabelsForAScreen = 3

    private static func labels(of reading: ScreenReading) -> [String] {
        reading.elements.map { $0.label.lowercased() }.sorted()
    }

    private static func isYes(_ answer: String) -> Bool {
        let words = Set(answer.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["yes", "yeah", "yep", "sure", "continue", "go", "okay", "ok", "confirm"])
            && words.isDisjoint(with: ["no", "stop", "cancel", "don't"])
    }

    /// JPEG of the flattened screen, scaled down for upload.
    private static func jpeg(from image: CGImage) -> Data? {
        let longest = CGFloat(max(image.width, image.height))
        let scale = min(1, 1400 / longest)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: 0.75)
    }
}

#if targetEnvironment(simulator)
extension TaskSession {
    /// Puts the screen into a fixed state so its layout can be checked in the simulator,
    /// which has no camera. Chosen with the launch argument `-NudgePreview <name>`.
    func applyPreview(_ name: String) {
        goal = "heat for 90 seconds"
        trail = [TrailStep(name: "Time Cook", state: .done), TrailStep(name: "1", state: .done),
                 TrailStep(name: "3", state: .current)]
        isRunning = true
        var overlay = PerceptionPipeline.Overlay()
        overlay.anchored = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.85), CGPoint(x: 0.2, y: 0.85)]
        overlay.target = CGPoint(x: 0.62, y: 0.55)
        overlay.fingertip = CGPoint(x: 0.4, y: 0.7)
        switch name {
        case "listening":
            trail = []
            goal = ""
            phase = .listening
            instruction = "What would you like to do?"
            visual.mode = .listening(level: 0.7)
            overlay.target = nil
            overlay.fingertip = nil
        case "planning":
            phase = .planning
            instruction = "Set to 1 minute. Next, press 3."
            visual.mode = .working
            overlay.target = nil
            overlay.fingertip = nil
        case "seeking":
            phase = .guiding
            instruction = "Next, press 3."
            visual.mode = .seeking(direction: CGVector(dx: 0.05, dy: -0.03), closeness: 0.45)
            visual.word = "Right"
        case "closer":
            phase = .guiding
            instruction = "Next, press 3."
            visual.mode = .closer
            visual.word = "Closer"
            overlay.fingertip = overlay.target
        case "tap":
            phase = .guiding
            instruction = "Next, press 3."
            visual.mode = .tap
            visual.word = "Tap"
            overlay.fingertip = overlay.target
        case "done":
            isRunning = false
            trail = trail.map { TrailStep(name: $0.name, state: .done) } + [TrailStep(name: "0", state: .done), TrailStep(name: "Start", state: .done)]
            outcome = .done
            phase = .idle
            instruction = "Heating for 1 minute 30. Done."
            overlay.target = nil
            overlay.fingertip = nil
        case "problem":
            isRunning = false
            trail[2].state = .failed
            outcome = .problem
            phase = .idle
            instruction = "This looks like a payment screen. Nudge does not handle payments, so I'm stopping here."
            overlay.target = nil
            overlay.fingertip = nil
        default:
            isRunning = false
            trail = []
            goal = ""
            overlay = PerceptionPipeline.Overlay()
        }
        pipeline.setPreviewOverlay(overlay)
    }
}
#endif
