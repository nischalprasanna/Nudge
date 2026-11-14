import Foundation

/// A plain text diary of what a task did and how long each part took, kept on the phone.
/// It exists so that a failed run can be explained afterwards. Nothing here is sent anywhere.
enum DebugLog {
    private static let queue = DispatchQueue(label: "nudge.debuglog")
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("nudge-debug.log")
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func add(_ line: String) {
        let now = Date()
        queue.async {
            let text = "\(stamp.string(from: now)) \(line)\n"
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                // Start again once it gets large; only recent runs matter.
                if let size = try? handle.seekToEnd(), size > 400_000 {
                    try? handle.truncate(atOffset: 0)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
