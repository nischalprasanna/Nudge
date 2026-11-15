import Combine
import CoreGraphics
import Foundation

/// One key on a saved device.
struct SavedKey: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    /// Where the key was on the screen when the device was saved (0...1 across and down the
    /// area Nudge had outlined then). Only the keys' places relative to each other matter: the
    /// outline is never quite the same twice, so they are fitted afresh each time.
    var box: CGRect
}

/// A goal the user has completed on a device, kept so that it can be done again at once,
/// with no planning and no network.
struct Routine: Codable, Equatable, Identifiable {
    var id = UUID()
    /// What the user said, for example "cook for 90 seconds".
    var phrase: String
    /// The keys pressed, in order, by label.
    var steps: [String]
    var savedAt = Date()
}

/// An appliance screen the user has used before. Holds labels and positions only, never pictures.
struct SavedDevice: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var savedAt = Date()
    var keys: [SavedKey]
    var routines: [Routine] = []
}

/// How a saved device's keys sit on the screen as it is outlined right now.
struct DeviceFit {
    var device: SavedDevice
    /// current = scale * saved + offset, separately across and down.
    var scale: CGSize
    var offset: CGPoint
    /// Saved keys whose labels were read in the right places.
    var matched: Int

    func place(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX * scale.width + offset.x, y: box.minY * scale.height + offset.y,
               width: box.width * scale.width, height: box.height * scale.height)
    }
}

/// The user's saved devices, kept in one file on the phone.
final class DeviceStore: ObservableObject {
    static let shared = DeviceStore()

    @Published private(set) var devices: [SavedDevice] = []

    private let fileURL: URL?

    private init() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = folder.appendingPathComponent("nudge-devices.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([SavedDevice].self, from: data) {
            devices = saved
        }
    }

    /// For tests: a store that is not read from or written to disk.
    init(devices: [SavedDevice]) {
        fileURL = nil
        self.devices = devices
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func device(_ id: UUID?) -> SavedDevice? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }

    func add(_ device: SavedDevice) {
        devices.append(device)
        save()
    }

    func update(_ device: SavedDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
        save()
    }

    func remove(_ id: UUID) {
        devices.removeAll { $0.id == id }
        save()
    }

    /// Keeps a routine for a device, replacing an earlier one for the same words.
    func remember(_ routine: Routine, on deviceID: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[index].routines.removeAll { Self.sameGoal($0.phrase, routine.phrase) }
        devices[index].routines.append(routine)
        save()
    }

    /// A name not already in use: "Device 1", "Device 2", ...
    func freshName() -> String {
        var number = devices.count + 1
        while devices.contains(where: { $0.name == "Device \(number)" }) { number += 1 }
        return "Device \(number)"
    }

    // MARK: Making a device from a reading

    /// The keys worth saving from a reading: outlined buttons whose labels were read.
    static func keys(from reading: ScreenReading) -> [SavedKey] {
        reading.elements
            .filter { $0.isButton && $0.label != unreadMark && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { SavedKey(label: $0.label, box: $0.box) }
    }

    /// The keys worth saving from several readings of the same screen taken during one task
    /// (the outline does not move within a task, so a key is in the same place in each).
    /// Each key takes the label it was given most often, so one bad reading does not stick.
    static func keys(from readings: [ScreenReading]) -> [SavedKey] {
        guard let first = readings.first else { return [] }
        // Start from the reading with the most outlined keys.
        let base = readings.max { $0.elements.filter(\.isButton).count < $1.elements.filter(\.isButton).count } ?? first
        var result: [SavedKey] = []
        for element in base.elements where element.isButton {
            var votes: [String: Int] = [:]
            for reading in readings {
                for other in reading.elements where other.isButton && element.box.contains(other.center) {
                    let label = other.label.trimmingCharacters(in: .whitespaces)
                    if label != unreadMark, !label.isEmpty { votes[label, default: 0] += 1 }
                }
            }
            // Most votes; between equals, the longer label (a cut-off reading is shorter).
            guard let winner = votes.max(by: { ($0.value, $0.key.count) < ($1.value, $1.key.count) }) else { continue }
            result.append(SavedKey(label: winner.key, box: element.box))
        }
        return result
    }

    /// What the reader puts on a key it found but could not read.
    static let unreadMark = "?"

    // MARK: Recognising a device

    static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Works out where a saved device's keys are on the screen as read just now, from the labels
    /// that were read the same as before. Nil when this is not that device, or too little of it
    /// was read to be sure.
    static func fit(_ device: SavedDevice, to reading: ScreenReading) -> DeviceFit? {
        // Pair up labels that occur exactly once on each side.
        var savedByLabel: [String: [SavedKey]] = [:]
        for saved in device.keys { savedByLabel[key(saved.label), default: []].append(saved) }
        var readByLabel: [String: [ScreenElement]] = [:]
        for element in reading.elements { readByLabel[key(element.label), default: []].append(element) }
        var pairs: [(saved: CGPoint, read: CGPoint)] = []
        for (label, saved) in savedByLabel where !label.isEmpty && saved.count == 1 {
            guard let read = readByLabel[label], read.count == 1 else { continue }
            pairs.append((CGPoint(x: saved[0].box.midX, y: saved[0].box.midY), read[0].center))
        }
        guard pairs.count >= 4 else { return nil }

        /// A straight-line fit read = a * saved + b that shrugs off a few wrong pairs:
        /// the slope is the median of the slopes between pairs.
        func line(_ points: [(CGFloat, CGFloat)]) -> (a: CGFloat, b: CGFloat)? {
            var slopes: [CGFloat] = []
            for i in 0..<points.count {
                for j in (i + 1)..<max(points.count, i + 1) where abs(points[j].0 - points[i].0) > 0.05 {
                    slopes.append((points[j].1 - points[i].1) / (points[j].0 - points[i].0))
                }
            }
            guard slopes.count >= 3 else { return nil }
            slopes.sort()
            let a = slopes[slopes.count / 2]
            let intercepts = points.map { $0.1 - a * $0.0 }.sorted()
            return (a, intercepts[intercepts.count / 2])
        }
        guard let across = line(pairs.map { ($0.saved.x, $0.read.x) }),
              let down = line(pairs.map { ($0.saved.y, $0.read.y) }),
              (0.3...3.5).contains(across.a), (0.3...3.5).contains(down.a) else { return nil }

        // How many of the pairs agree with that fit? A key is roughly a tenth of the screen
        // across, so 3% is well inside one key.
        let agreeing = pairs.filter {
            abs(across.a * $0.saved.x + across.b - $0.read.x) < 0.03 && abs(down.a * $0.saved.y + down.b - $0.read.y) < 0.03
        }.count
        guard agreeing >= 4, agreeing * 10 >= pairs.count * 6 else { return nil }
        return DeviceFit(device: device, scale: CGSize(width: across.a, height: down.a),
                         offset: CGPoint(x: across.b, y: down.b), matched: agreeing)
    }

    /// The saved device this reading belongs to, if any. `preferred` is tried first and wins a tie.
    func recognise(_ reading: ScreenReading, preferred: UUID? = nil) -> DeviceFit? {
        var best: DeviceFit?
        for device in devices {
            guard let fit = Self.fit(device, to: reading) else { continue }
            if let current = best {
                if fit.matched > current.matched || (fit.matched == current.matched && device.id == preferred) { best = fit }
            } else {
                best = fit
            }
        }
        return best
    }

    /// Rewrites a reading with what is known about the device: every saved key carries its saved
    /// label (so a key read as "Popcom" or not read at all is right again), and keys the reader
    /// missed are put back where they belong. Anything else on the screen, such as the display,
    /// is left exactly as read.
    static func apply(_ fit: DeviceFit, to reading: ScreenReading) -> ScreenReading {
        var elements = reading.elements
        var claimed = Set<Int>()
        var added: [ScreenElement] = []
        for saved in fit.device.keys {
            let box = fit.place(saved.box)
            let centre = CGPoint(x: box.midX, y: box.midY)
            // The element read at this key's place: its centre lies inside the key.
            var best: (index: Int, distance: CGFloat)?
            for (index, element) in elements.enumerated() where !claimed.contains(index) {
                guard box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.15).contains(element.center) else { continue }
                let distance = hypot(element.center.x - centre.x, element.center.y - centre.y)
                if distance < (best?.distance ?? .infinity) { best = (index, distance) }
            }
            if let best {
                claimed.insert(best.index)
                elements[best.index].label = saved.label
                // Keep the outline as read now if it is a key's outline; otherwise use the saved one.
                if !elements[best.index].isButton {
                    elements[best.index].box = box
                    elements[best.index].isButton = true
                }
            } else if box.minX > -0.05, box.maxX < 1.05, box.minY > -0.05, box.maxY < 1.05 {
                added.append(ScreenElement(label: saved.label, box: box, confidence: 0.5, kind: .text, isButton: true))
            }
        }
        // An unread key lying on a saved key that has already been filled in is a double.
        let keyBoxes = fit.device.keys.map { fit.place($0.box) }
        var result: [ScreenElement] = []
        for (index, element) in elements.enumerated() {
            if !claimed.contains(index), element.label == unreadMark,
               keyBoxes.contains(where: { $0.contains(element.center) }) { continue }
            result.append(element)
        }
        result.append(contentsOf: added)
        var updated = reading
        updated.elements = result
        updated.source = .savedDevice
        return updated
    }

    // MARK: Matching what was said to a routine

    private static let fillerWords: Set<String> = [
        "for", "to", "the", "a", "an", "please", "my", "it", "on", "at", "of", "and", "can", "you", "i", "want", "would", "like",
    ]
    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "fifteen": "15", "twenty": "20", "thirty": "30", "forty": "40",
        "fortyfive": "45", "fifty": "50", "sixty": "60", "ninety": "90",
    ]

    static func words(_ phrase: String) -> [String] {
        phrase.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillerWords.contains($0) }
            .map { numberWords[$0] ?? $0 }
            .map { $0.hasSuffix("s") && $0.count > 3 ? String($0.dropLast()) : $0 }
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var previous = row[0]
            row[0] = i
            for j in 1...y.count {
                let above = row[j]
                row[j] = min(previous + (x[i - 1] == y[j - 1] ? 0 : 1), min(row[j], row[j - 1]) + 1)
                previous = above
            }
        }
        return row[y.count]
    }

    /// The same word, allowing for how speech recognition slips ("coke" for "cook").
    private static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Numbers must match exactly: 90 seconds is not 9 seconds.
        if a.contains(where: \.isNumber) || b.contains(where: \.isNumber) { return false }
        guard a.count >= 4, b.count >= 4, a.first == b.first else { return false }
        return editDistance(a, b) <= 2
    }

    /// How alike two spoken goals are, 0...1. Zero if their numbers differ.
    static func likeness(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        let numbersX = x.filter { $0.contains(where: \.isNumber) }.sorted()
        let numbersY = y.filter { $0.contains(where: \.isNumber) }.sorted()
        guard numbersX == numbersY else { return 0 }
        var remaining = y
        var shared = 0
        for word in x {
            if let index = remaining.firstIndex(where: { sameWord(word, $0) }) {
                remaining.remove(at: index)
                shared += 1
            }
        }
        return Double(shared) / Double(x.count + y.count - shared)
    }

    static func sameGoal(_ a: String, _ b: String) -> Bool { likeness(a, b) >= 0.99 }

    /// The routine on this device that the words ask for, if one is close enough.
    static func routine(for goal: String, on device: SavedDevice) -> Routine? {
        let scored = device.routines.map { (routine: $0, score: likeness(goal, $0.phrase)) }
        guard let best = scored.max(by: { $0.score < $1.score }), best.score >= 0.6 else { return nil }
        return best.routine
    }
}
