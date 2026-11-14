import Foundation

/// One attempt at a task, recorded for testing.
struct TaskRecord: Codable, Identifiable {
    var id = UUID()
    var startedAt: Date
    /// Saved device name, or a description of the unsaved screen.
    var device: String
    var goal: String
    /// "success", "failed" or "stopped".
    var outcome: String
    /// The closing message when the task did not succeed.
    var reason: String
    /// Button presses that were verified.
    var stepsCompleted: Int
    /// Presses that had to be corrected or repeated.
    var recoveries: Int
    var seconds: Double
    /// Feedback channels that were on, for example "tones+voice".
    var channels: String
    var planner: String
}

/// Keeps every task attempt on the phone and exports them as CSV, so results can be reported
/// from real use. Nothing here leaves the phone unless the user shares the file.
final class TestLog: ObservableObject {
    static let shared = TestLog()

    @Published private(set) var records: [TaskRecord] = []

    private let fileURL: URL = {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("nudge-test-log.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([TaskRecord].self, from: data) {
            records = saved
        }
    }

    func add(_ record: TaskRecord) {
        records.append(record)
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Share of attempts that succeeded, 0...1. Nil when nothing has been recorded.
    var successRate: Double? {
        guard !records.isEmpty else { return nil }
        return Double(records.filter { $0.outcome == "success" }.count) / Double(records.count)
    }

    /// Writes the log as a CSV file and returns where it is, ready for the share sheet.
    func exportCSV() -> URL? {
        let formatter = ISO8601DateFormatter()
        var lines = ["started_at,device,goal,outcome,reason,steps_completed,recoveries,seconds,channels,planner"]
        for record in records {
            let fields = [
                formatter.string(from: record.startedAt),
                record.device,
                record.goal,
                record.outcome,
                record.reason,
                String(record.stepsCompleted),
                String(record.recoveries),
                String(format: "%.1f", record.seconds),
                record.channels,
                record.planner,
            ]
            lines.append(fields.map(Self.escape).joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nudge-test-log.csv")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
