import CoreGraphics
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }
func screen(_ display: String) -> ScreenReading {
    var e = [ScreenElement(label: display, box: CGRect(x: 0.4, y: 0.1, width: 0.3, height: 0.1), confidence: 0.9)]
    for (i, n) in ["Popcorn", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Stop", "0", "Start"].enumerated() {
        e.append(ScreenElement(label: n, box: CGRect(x: 0.1 + CGFloat(i % 3) * 0.3, y: 0.3 + CGFloat(i / 3) * 0.12, width: 0.2, height: 0.08), confidence: 0.9, kind: .text, isButton: true))
    }
    return ScreenReading(elements: e, source: .savedDevice, readAt: Date(), aspectRatio: 0.5)
}
final class Cloud: TaskPlanner {
    let name = "cloud"; var calls = 0
    func nextStep(_ request: PlanRequest) async throws -> PlanStep {
        calls += 1
        return PlanStep(action: .cannot, targetID: -1, targetX: 0, targetY: 0, targetName: "", say: "cloud took over", expect: "", previousStepSucceeded: false, thenPress: nil)
    }
}
func request(_ now: String, _ before: String?, _ presses: [String]) -> PlanRequest {
    PlanRequest(goal: "cook for 90 seconds", screen: screen(now), previousScreen: before.map(screen),
                history: presses.map { CompletedStep(targetName: $0, expected: "") }, userConfirmedRisk: false, imageJPEG: nil)
}
let routine = Routine(phrase: "Cook for 90 seconds", steps: ["9", "0", "Start"])

// A clean run with no network.
do {
    let p = RoutinePlanner(routine: routine, deviceName: "Kitchen microwave", fallback: nil)
    var s = try await p.nextStep(request("5:50", nil, []))
    check(s.action == .tap && s.targetName == "9" && (s.thenPress ?? []).map(\.targetName) == ["0", "Start"] && s.say == "Press 9.", "starts with 9 and gives the whole route")
    s = try await p.nextStep(request("0:09", "5:50", ["9"]))
    check(s.action == .tap && s.targetName == "0" && s.previousStepSucceeded && (s.thenPress ?? []).map(\.targetName) == ["Start"], "after 9 registers, moves to 0")
    // asked twice about the same press: no double counting
    s = try await p.nextStep(request("0:09", "5:50", ["9"]))
    check(s.targetName == "0", "asking again about the same press changes nothing")
    s = try await p.nextStep(request("0:90", "0:09", ["9", "0"]))
    check(s.targetName == "Start" && (s.thenPress ?? []).isEmpty, "then Start")
    s = try await p.nextStep(request("1:29", "0:90", ["9", "0", "Start"]))
    check(s.action == .done && s.say == "Done. The display shows 1:29.", "ends by reading the display: \(s.say)")
}
// A press that does not register, with no network.
do {
    let p = RoutinePlanner(routine: routine, deviceName: "Kitchen microwave", fallback: nil)
    _ = try await p.nextStep(request("5:50", nil, []))
    var s = try await p.nextStep(request("5:50", "5:50", ["9"]))
    check(s.action == .tap && s.targetName == "9" && !s.previousStepSucceeded && s.say.contains("didn't register"), "an unregistered press is repeated: \(s.say)")
    s = try await p.nextStep(request("0:09", "5:50", ["9", "9"]))
    check(s.targetName == "0" && s.previousStepSucceeded, "and the route carries on once it registers")
    s = try await p.nextStep(request("0:09", "0:09", ["9", "9", "0"]))
    s = try await p.nextStep(request("0:09", "0:09", ["9", "9", "0", "0"]))
    check(s.action == .cannot, "two failures running, no network: stops and says so: \(s.say)")
}
// The same failure with a cloud planner to fall back on.
do {
    let cloud = Cloud()
    let p = RoutinePlanner(routine: routine, deviceName: "Kitchen microwave", fallback: cloud)
    _ = try await p.nextStep(request("5:50", nil, []))
    check(cloud.calls == 0, "the first step uses no network")
    _ = try await p.nextStep(request("5:50", "5:50", ["9"]))
    check(cloud.calls == 0, "one failure is handled on the phone")
    let s = try await p.nextStep(request("5:50", "5:50", ["9", "9"]))
    check(cloud.calls == 1 && s.say == "cloud took over", "two failures hand the task to the cloud planner")
}
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
