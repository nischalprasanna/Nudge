import Foundation

/// The demo-safe switch: use only what is saved on the phone, and never the network.
enum DemoSafe {
    static let onKey = "demoSafe.on"
    static let deviceKey = "demoSafe.device"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: onKey) }

    /// The saved device chosen for the demo, if one has been.
    static var deviceID: UUID? {
        UserDefaults.standard.string(forKey: deviceKey).flatMap(UUID.init(uuidString:))
    }
}

/// Plans from a saved routine: the keys the user pressed the last time they asked for this.
/// Answers at once and uses no network.
///
/// It confirms a press the only way it can without a model to ask: the finger was guided onto
/// the key, and the screen changed afterwards. It cannot tell that a wrong key was pressed, so
/// at the end it reads out what the display shows instead of claiming more than it knows. If a
/// press does not register twice running it hands the task to `fallback` (the cloud planner),
/// when there is one.
final class RoutinePlanner: TaskPlanner {
    let name: String

    private let routine: Routine
    private let fallback: TaskPlanner?
    private let lock = NSLock()
    private var index = 0
    private var pressesSeen = 0
    private var retries = 0
    private var handedOver = false

    init(routine: Routine, deviceName: String, fallback: TaskPlanner?) {
        self.routine = routine
        self.fallback = fallback
        name = "Saved routine on \(deviceName) (no network)"
    }

    func nextStep(_ request: PlanRequest) async throws -> PlanStep {
        let (step, tries, useFallback) = progress(after: request)
        if useFallback, let fallback { return try await fallback.nextStep(request) }

        guard step < routine.steps.count else {
            return Self.result(.done, say: Self.closing(request.screen), ok: true)
        }
        if tries >= 2 {
            return Self.result(.cannot, say: "The screen isn't responding to \(routine.steps[step]), so I've stopped.", ok: false)
        }
        guard let target = Self.find(routine.steps[step], in: request.screen) else {
            if let fallback {
                lock.withLock { handedOver = true }
                return try await fallback.nextStep(request)
            }
            return Self.result(.cannot, say: "I can't find \(routine.steps[step]) on the screen, so I've stopped.", ok: tries == 0)
        }
        var following: [PlanStep.FollowingPress] = []
        for label in routine.steps[(step + 1)...] {
            guard let next = Self.find(label, in: request.screen) else { break }
            following.append(PlanStep.FollowingPress(targetID: next, targetX: 0, targetY: 0,
                                                     targetName: request.screen.elements[next].label, expect: ""))
        }
        let label = request.screen.elements[target].label
        let say: String
        if tries > 0 {
            say = "That press didn't register. Press \(label) again."
        } else {
            say = step == 0 ? "Press \(label)." : "Next, press \(label)."
        }
        return PlanStep(action: .tap, targetID: target, targetX: 0, targetY: 0, targetName: label, say: say,
                        expect: "", previousStepSucceeded: tries == 0, thenPress: following)
    }

    /// Brings the count of confirmed presses up to date and says where things stand. Requests
    /// can arrive from more than one task, so this is the only place the state changes.
    private func progress(after request: PlanRequest) -> (step: Int, tries: Int, useFallback: Bool) {
        lock.withLock {
            if request.history.count > pressesSeen {
                pressesSeen = request.history.count
                let changed = request.previousScreen.map { Self.labels($0) != Self.labels(request.screen) } ?? true
                if changed {
                    index += 1
                    retries = 0
                } else {
                    retries += 1
                }
            }
            if retries >= 2, fallback != nil { handedOver = true }
            return (index, retries, handedOver)
        }
    }

    private static func result(_ action: PlanStep.Action, say: String, ok: Bool) -> PlanStep {
        PlanStep(action: action, targetID: -1, targetX: 0, targetY: 0, targetName: "", say: say, expect: "",
                 previousStepSucceeded: ok, thenPress: nil)
    }

    private static func find(_ label: String, in reading: ScreenReading) -> Int? {
        let wanted = DeviceStore.key(label)
        return reading.elements.firstIndex { $0.isButton && DeviceStore.key($0.label) == wanted }
            ?? reading.elements.firstIndex { DeviceStore.key($0.label) == wanted }
    }

    private static func labels(_ reading: ScreenReading) -> [String] {
reading.elements.map { $0.label.lowercased() }.filter { $0 != DeviceStore.unreadMark }.sorted()
    }

    /// What to say at the end: only what can be seen. The display is the largest piece of
    /// writing with a number in it that is not a key.
    static func closing(_ reading: ScreenReading) -> String {
        let display = reading.elements
            .filter { !$0.isButton && $0.label.contains(where: \.isNumber) && $0.label.count <= 8 }
            .max { $0.box.height < $1.box.height }
        guard let display else { return "Done." }
        return "Done. The display shows \(display.label)."
    }
}
