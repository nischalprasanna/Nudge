import CoreGraphics
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }

// The demo keypad as saved: 3 columns, function keys, digits, bottom row. Positions in the saved outline.
let names = [["Popcorn", "Reheat", "Defrost"], ["Power", "Timer", "Clock"], ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["Stop", "0", "Start"]]
let rowY: [CGFloat] = [0.30, 0.38, 0.50, 0.60, 0.70, 0.80]
var keys: [SavedKey] = []
for (r, row) in names.enumerated() { for (c, name) in row.enumerated() {
    keys.append(SavedKey(label: name, box: CGRect(x: 0.2 + CGFloat(c) * 0.22, y: rowY[r], width: 0.18, height: 0.07)))
} }
let device = SavedDevice(name: "Kitchen microwave", keys: keys,
                         routines: [Routine(phrase: "Cook for 90 seconds", steps: ["9", "0", "Start"])])

/// A reading of the same keypad under a different outline, with labels as the reader really gave them.
func reading(scale: CGSize, offset: CGPoint, labels: [String: String], drop: Set<String> = [], jitter: CGFloat = 0.004,
             extra: [(String, CGRect)] = []) -> ScreenReading {
    var elements: [ScreenElement] = []
    var seed: UInt64 = 7
    func noise() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (CGFloat(seed >> 33 % 1000) / 1000 - 0.5) * 2 * jitter }
    for key in keys where !drop.contains(key.label) {
        let box = CGRect(x: key.box.minX * scale.width + offset.x + noise(), y: key.box.minY * scale.height + offset.y + noise(),
                         width: key.box.width * scale.width, height: key.box.height * scale.height)
        elements.append(ScreenElement(label: labels[key.label] ?? key.label, box: box, confidence: 0.8, kind: .text, isButton: true))
    }
    for (label, box) in extra { elements.append(ScreenElement(label: label, box: box, confidence: 0.9)) }
    return ScreenReading(elements: elements, source: .onDeviceText, readAt: Date(), aspectRatio: 0.55)
}

// 1. The blind run's reading: function keys garbled, one unread, Start read as "S".
let garbled = ["Popcorn": "opoom", "Reheat": "?", "Defrost": "ЗВоцА", "Power": "lowe", "Timer": "Timai", "Start": "S"]
let r1 = reading(scale: CGSize(width: 0.8, height: 0.9), offset: CGPoint(x: 0.12, y: 0.05), labels: garbled,
                 extra: [("8:00", CGRect(x: 0.4, y: 0.12, width: 0.25, height: 0.08))])
if let fit = DeviceStore.fit(device, to: r1) {
    check(fit.matched >= 10, "garbled reading recognised from \(fit.matched) labels")
    let fixed = DeviceStore.apply(fit, to: r1)
    let labels = fixed.elements.map(\.label)
    check(Set(names.flatMap { $0 }).isSubset(of: Set(labels)), "every key has its saved label")
    check(labels.contains("8:00"), "the display is left as read")
    check(!labels.contains("?") && !labels.contains("opoom"), "no garbled or unread labels remain")
    check(fixed.elements.count == r1.elements.count, "nothing added or lost (\(fixed.elements.count))")
    let start = fixed.elements.first { $0.label == "Start" }!, wanted = keys.last!.box
    check(abs(start.center.x - (wanted.midX * 0.8 + 0.12)) < 0.01 && abs(start.center.y - (wanted.midY * 0.9 + 0.05)) < 0.01, "Start is where it should be")
} else { check(false, "garbled reading recognised") }

// 2. Keys the reader missed altogether are put back.
let r2 = reading(scale: CGSize(width: 1.1, height: 0.7), offset: CGPoint(x: -0.05, y: 0.2), labels: [:], drop: ["Start", "Popcorn", "5"])
if let fit = DeviceStore.fit(device, to: r2) {
    let fixed = DeviceStore.apply(fit, to: r2)
    check(fixed.elements.count == 18 && fixed.elements.contains { $0.label == "Start" }, "missing keys are restored (\(fixed.elements.count))")
} else { check(false, "reading with missing keys recognised") }

// 3. A different appliance is not taken for this one: same labels, different arrangement.
var shuffled: [ScreenElement] = []
let other = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "Start", "Stop"]
for (i, name) in other.enumerated() {
    // one row of twelve, in a different order across and down
    shuffled.append(ScreenElement(label: name, box: CGRect(x: CGFloat((i * 5) % 12) * 0.08, y: CGFloat((i * 7) % 12) * 0.08, width: 0.06, height: 0.06), confidence: 0.9, kind: .text, isButton: true))
}
check(DeviceStore.fit(device, to: ScreenReading(elements: shuffled, source: .onDeviceText, readAt: Date(), aspectRatio: 1)) == nil, "a different layout with the same labels is refused")

// 4. Too little read: no guess.
let r4 = reading(scale: CGSize(width: 1, height: 1), offset: .zero, labels: Dictionary(uniqueKeysWithValues: keys.map { ($0.label, "?") }))
check(DeviceStore.fit(device, to: r4) == nil, "an unreadable screen is not guessed at")

// 5. Words.
for (said, expect) in [("Cook for 90 seconds", true), ("cook 90 seconds", true), ("Coke 90 seconds", true), ("Cook for ninety seconds", true),
                       ("Reheat 90 seconds", false), ("Cook for 9 seconds", false), ("heat for 90 seconds", false), ("Cook for 30 seconds", false), ("popcorn", false)] {
    check((DeviceStore.routine(for: said, on: device) != nil) == expect, "\"\(said)\" \(expect ? "runs" : "does not run") the saved routine")
}
// 6. Saving from several readings: each key takes its most common label.
let a = reading(scale: CGSize(width: 1, height: 1), offset: .zero, labels: ["Start": "art", "Popcorn": "Popcom"])
let b = reading(scale: CGSize(width: 1, height: 1), offset: .zero, labels: ["Start": "Start", "Popcorn": "Popcom", "5": "?"])
let c = reading(scale: CGSize(width: 1, height: 1), offset: .zero, labels: ["Start": "Start", "Popcorn": "?"])
let merged = DeviceStore.keys(from: [a, b, c])
check(merged.count == 18, "all 18 keys are saved (\(merged.count))")
check(merged.contains { $0.label == "Start" } && !merged.contains { $0.label == "art" }, "Start wins over a cut-off reading")
check(merged.contains { $0.label == "5" }, "a key unread once is still saved")
check(merged.contains { $0.label == "Popcom" }, "a label misread every time is saved as read (it can be corrected in Settings)")
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")

extension DeviceFit: Equatable { public static func == (a: DeviceFit, b: DeviceFit) -> Bool { a.device == b.device && a.matched == b.matched } }
