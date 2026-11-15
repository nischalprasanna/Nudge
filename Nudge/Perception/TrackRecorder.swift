import ARKit
import CoreImage
import Foundation

/// A test tool: while Nudge is guiding a finger, keeps the camera pictures, the LiDAR depth and
/// what the tracker made of them, in one file on the phone (`Documents/track.bin`). The file is
/// copied to a Mac over the cable so that changes to finger tracking can be measured on real
/// frames before they are shipped. Nothing is sent anywhere. Off unless switched on in Settings.
final class TrackRecorder {
    static let settingKey = "record.tracking"

    private let queue = DispatchQueue(label: "nudge.recorder", qos: .utility)
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("track.bin")
    private var handle: FileHandle?
    private var written = 0
    private var lastTime: TimeInterval = 0
    private let pending = NSLock()
    private var inFlight = 0

    /// About 80 seconds of guidance; the file stays under roughly 400 MB.
    private let limit = 800
    private let interval: TimeInterval = 0.1

    var isOn: Bool { UserDefaults.standard.bool(forKey: Self.settingKey) }

    init() {
        // Off unless switched on in Settings: it costs storage and some speed.
        UserDefaults.standard.register(defaults: [Self.settingKey: false])
    }

    /// Starts a fresh file. Called when the camera starts.
    func begin() {
        let on = isOn
        queue.async {
            try? self.handle?.close()
            self.handle = nil
            self.written = 0
            try? FileManager.default.removeItem(at: self.url)
            guard on else { return }
            FileManager.default.createFile(atPath: self.url.path, contents: nil)
            self.handle = try? FileHandle(forWritingTo: self.url)
        }
    }

    func end() {
        queue.async {
            try? self.handle?.close()
            self.handle = nil
            if self.written > 0 { DebugLog.add("recorder: kept \(self.written) frames") }
        }
    }

    /// Call from the frame-processing queue. `info` is anything JSON can hold.
    func record(frame: ARFrame, info: [String: Any]) {
        guard isOn, frame.timestamp - lastTime >= interval else { return }
        pending.lock()
        let busy = inFlight >= 2
        if !busy { inFlight += 1 }
        pending.unlock()
        guard !busy else { return }
        lastTime = frame.timestamp

        let image = frame.capturedImage
        var depth = Data(), confidence = Data()
        var depthWidth = 0, depthHeight = 0
        if let scene = frame.sceneDepth {
            let map = scene.depthMap
            CVPixelBufferLockBaseAddress(map, .readOnly)
            depthWidth = CVPixelBufferGetWidth(map)
            depthHeight = CVPixelBufferGetHeight(map)
            if let base = CVPixelBufferGetBaseAddress(map) {
                let rowBytes = CVPixelBufferGetBytesPerRow(map)
                for row in 0..<depthHeight {
                    depth.append(Data(bytes: base + row * rowBytes, count: depthWidth * 4))
                }
            }
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
            if let conf = scene.confidenceMap {
                CVPixelBufferLockBaseAddress(conf, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(conf) {
                    let rowBytes = CVPixelBufferGetBytesPerRow(conf)
                    for row in 0..<CVPixelBufferGetHeight(conf) {
                        confidence.append(Data(bytes: base + row * rowBytes, count: CVPixelBufferGetWidth(conf)))
                    }
                }
                CVPixelBufferUnlockBaseAddress(conf, .readOnly)
            }
        }

        var details = info
        let camera = frame.camera
        let k = camera.intrinsics
        details["time"] = frame.timestamp
        details["intrinsics"] = [k[0][0], k[1][1], k[2][0], k[2][1]]
        details["imageSize"] = [camera.imageResolution.width, camera.imageResolution.height]
        let t = camera.transform
        details["camera"] = [t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }

        queue.async {
            defer {
                self.pending.lock()
                self.inFlight -= 1
                self.pending.unlock()
            }
            guard let handle = self.handle, self.written < self.limit,
                  let json = try? JSONSerialization.data(withJSONObject: details),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let jpeg = self.context.jpegRepresentation(
                      of: CIImage(cvPixelBuffer: image), colorSpace: space,
                      options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.6])
            else { return }
            var header = Data("NTRK".utf8)
            for value in [json.count, jpeg.count, depthWidth, depthHeight, confidence.count] {
                var number = UInt32(value).littleEndian
                header.append(Data(bytes: &number, count: 4))
            }
            try? handle.write(contentsOf: header + json + jpeg + depth + confidence)
            self.written += 1
        }
    }
}
