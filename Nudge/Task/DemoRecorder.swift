import AVFoundation
import CoreImage
import UIKit

/// Makes a video of each task from inside the app, for showing what Nudge sees and says.
///
/// It is drawn from the camera frames and the app's own state, not captured from the screen, so
/// it keeps going when the screen is off against the wearer's chest and is not cut short by Siri
/// opening the app (which stops the phone's own screen recording). Each frame shows the camera
/// view with the screen's outline, the key to press and the fingertip, and below it what Nudge
/// is doing and saying. There is no sound: the captions carry the words.
///
/// Videos stay on the phone in `Documents/demo-videos` until they are shared from Settings.
final class DemoRecorder {
    static let shared = DemoRecorder()
    static let settingKey = "demoVideo.on"

    /// What the lower part of the picture says.
    struct Caption {
        var status = ""
        var instruction = ""
        /// The one-word cue ("Left", "Tap"), or empty.
        var cue = ""
        var goal = ""
        /// Keys so far: name, and 0 for the current one, 1 for done, 2 for a press that went wrong.
        var trail: [(name: String, state: Int)] = []
        /// Nudge is asking what to do and has not started looking for a screen.
        var greeting = false
    }

    /// What is drawn over the camera view, in the upright picture (0...1 across and down).
    struct Marks {
        var screen: [CGPoint] = []
        var target: CGPoint?
        var fingertip: CGPoint?
        /// The fingertip comes from LiDAR alone, not the hand tracker.
        var fromLidar = false
    }

    private let queue = DispatchQueue(label: "nudge.demo-video", qos: .utility)
    private let lock = NSLock()
    private var caption = Caption()
    private var busy = false

    // Used on `queue` only.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstTime: TimeInterval?
    private var lastStamp = CMTime.invalid
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let width = 720
    private let cameraHeight = 960
    private let height = 1280

    static let folder: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("demo-videos")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The videos kept, newest first.
    static var videos: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "mov" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private init() {
        // On by default while the demo is being recorded.
        UserDefaults.standard.register(defaults: [Self.settingKey: true])
    }

    var isOn: Bool { UserDefaults.standard.bool(forKey: Self.settingKey) }

    func update(_ change: (inout Caption) -> Void) {
        lock.withLock { change(&caption) }
    }

    /// Starts a new video. Call when a task starts.
    func begin() {
        guard isOn else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = Self.folder.appendingPathComponent("nudge-\(stamp.string(from: Date())).mov")
        queue.async {
            self.finishOnQueue()
            // Keep the newest dozen.
            for old in Self.videos.dropFirst(11) { try? FileManager.default.removeItem(at: old) }
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            // Written in one-second pieces, so the file plays even if the app is closed mid-task.
            writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: self.width,
                AVVideoHeightKey: self.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: self.width,
                kCVPixelBufferHeightKey as String: self.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            guard writer.canAdd(input) else { return }
            writer.add(input)
            guard writer.startWriting() else {
                DebugLog.add("video: could not start, \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.firstTime = nil
            self.lastStamp = .invalid
        }
    }

    /// Closes the video. Call when the task ends.
    func end() {
        queue.async { self.finishOnQueue() }
    }

    private func finishOnQueue() {
        guard let writer, let input else { return }
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        guard firstTime != nil else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            return
        }
        input.markAsFinished()
        let name = writer.outputURL.lastPathComponent
        writer.finishWriting { DebugLog.add("video: saved \(name)") }
    }

    /// Adds one frame. Call from the camera's processing queue; frames are skipped, never queued
    /// up, when drawing falls behind.
    func add(pixelBuffer: CVPixelBuffer, marks: Marks, time: TimeInterval) {
        let skip = lock.withLock { () -> Bool in
            if busy { return true }
            busy = true
            return false
        }
        if skip { return }
        let words = lock.withLock { caption }
        queue.async {
            defer { self.lock.withLock { self.busy = false } }
            guard let writer = self.writer, let input = self.input, let adaptor = self.adaptor,
                  writer.status == .writing, input.isReadyForMoreMediaData else { return }
            if self.firstTime == nil {
                self.firstTime = time
                writer.startSession(atSourceTime: .zero)
            }
            let elapsed = time - (self.firstTime ?? time)
            let stamp = CMTime(seconds: elapsed, preferredTimescale: 600)
            if self.lastStamp.isValid, stamp <= self.lastStamp { return }
            guard let pool = adaptor.pixelBufferPool else { return }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let canvas = made else { return }
            self.draw(camera: pixelBuffer, marks: marks, words: words, elapsed: elapsed, into: canvas)
            if adaptor.append(canvas, withPresentationTime: stamp) { self.lastStamp = stamp }
        }
    }

    // MARK: Drawing

    private static let yellow = UIColor(red: 1.0, green: 0.82, blue: 0.12, alpha: 1)
    private static let grey = UIColor(white: 0.62, alpha: 1)
    private static let green = UIColor(red: 0.30, green: 0.85, blue: 0.52, alpha: 1)
    private static let red = UIColor(red: 1.0, green: 0.42, blue: 0.36, alpha: 1)

    private static func font(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: size)
    }

    private func draw(camera: CVPixelBuffer, marks: Marks, words: Caption, elapsed: TimeInterval, into canvas: CVPixelBuffer) {
        let w = CGFloat(width), h = CGFloat(height), top = CGFloat(cameraHeight)

        // The camera picture, turned upright, in the top part. Core Image counts up from the bottom.
        var picture = CIImage(cvPixelBuffer: camera).oriented(.right)
        let scale = w / picture.extent.width
        picture = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: h - top - picture.extent.minY))
        let background = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        context.render(picture.composited(over: background), to: canvas, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        CVPixelBufferLockBaseAddress(canvas, [])
        defer { CVPixelBufferUnlockBaseAddress(canvas, []) }
        guard let base = CVPixelBufferGetBaseAddress(canvas),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(canvas), space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // Work from the top-left, as the rest of the app does.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        func place(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * top) }
        func text(_ string: String, _ font: UIFont, _ color: UIColor, in rect: CGRect, align: NSTextAlignment = .left,
                  wraps: Bool = false) {
            let style = NSMutableParagraphStyle()
            style.alignment = align
            style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
                .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: top))

        // The screen Nudge has locked onto: four corner brackets.
        if marks.screen.count == 4 {
            let corners = marks.screen.map(place)
            let path = CGMutablePath()
            for index in 0..<4 {
                let corner = corners[index], next = corners[(index + 1) % 4], previous = corners[(index + 3) % 4]
                func toward(_ other: CGPoint) -> CGPoint {
                    let length = max(hypot(other.x - corner.x, other.y - corner.y), 1)
                    let reach = min(length * 0.22, 44)
                    return CGPoint(x: corner.x + (other.x - corner.x) / length * reach, y: corner.y + (other.y - corner.y) / length * reach)
                }
                path.move(to: toward(previous))
                path.addLine(to: corner)
                path.addLine(to: toward(next))
            }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(10)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setStrokeColor(Self.yellow.cgColor)
            ctx.setLineWidth(6)
            ctx.strokePath()
        }

        // The key to press.
        if let target = marks.target {
            let p = place(target)
            let beat = CGFloat((elapsed * 1.6).truncatingRemainder(dividingBy: 1))
            let outer = 12 + beat * 16
            ctx.setStrokeColor(Self.yellow.withAlphaComponent(1 - beat * 0.9).cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: p.x - outer, y: p.y - outer, width: outer * 2, height: outer * 2))
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16))
            ctx.setFillColor(Self.yellow.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11))
        }

        // The fingertip, and which of the two ways it was found.
        if let tip = marks.fingertip {
            let p = place(tip)
            let ring = CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)
            ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(7)
            ctx.strokeEllipse(in: ring)
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(3.5)
            ctx.setLineDash(phase: 0, lengths: marks.fromLidar ? [7, 6] : [])
            ctx.strokeEllipse(in: ring)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            let label = marks.fromLidar ? "LiDAR" : "hand tracker"
            let labelWidth: CGFloat = marks.fromLidar ? 70 : 132
            let box = CGRect(x: min(max(p.x + 22, 6), w - labelWidth - 6), y: max(p.y - 14, 6), width: labelWidth, height: 28)
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: box, cornerRadius: 14).cgPath)
            ctx.fillPath()
            text(label, Self.font(18, .semibold), .white, in: box.insetBy(dx: 0, dy: 2), align: .center)
        }

        // The one-word cue, large, at the foot of the camera view.
        if !words.cue.isEmpty, !words.greeting {
            let cueFont = Self.font(84, .heavy)
            let box = CGRect(x: 0, y: top - 132, width: w, height: 110)
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = 12
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            NSAttributedString(string: words.cue, attributes: [.font: cueFont, .foregroundColor: Self.yellow, .shadow: shadow, .paragraphStyle: style])
                .draw(with: box, options: [.usesLineFragmentOrigin], context: nil)
        }

        // While Nudge is asking what to do, the camera has no job yet: dim it and show the question.
        if words.greeting {
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.82).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: top))
            text("Nudge", Self.font(54, .heavy), .white, in: CGRect(x: 40, y: 330, width: w - 80, height: 70), align: .center)
            text("What do you want to do?", Self.font(46, .bold), Self.yellow, in: CGRect(x: 40, y: 420, width: w - 80, height: 130), align: .center,
                 wraps: true)
            text("Listening", Self.font(26, .semibold), Self.grey, in: CGRect(x: 40, y: 560, width: w - 80, height: 40), align: .center)
        }
        ctx.restoreGState()

        // Below the camera: what Nudge is doing and saying.
        let margin: CGFloat = 34
        let minutes = Int(elapsed) / 60, seconds = elapsed - Double(minutes * 60)
        text(words.status, Self.font(24, .semibold), Self.grey, in: CGRect(x: margin, y: top + 22, width: w - margin * 2 - 130, height: 32))
        text(String(format: "%d:%04.1f", minutes, seconds), UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .medium), Self.grey,
             in: CGRect(x: w - margin - 130, y: top + 24, width: 130, height: 30), align: .right)
        text(words.instruction, Self.font(38, .bold), .white, in: CGRect(x: margin, y: top + 60, width: w - margin * 2, height: 156),
             wraps: true)

        // The goal, then each key: a tick when pressed and confirmed.
        var x = margin
        let rowY = top + 232
        if !words.goal.isEmpty {
            let goal = "“\(words.goal)”"
            let goalFont = Self.font(24, .semibold)
            let goalWidth = min((goal as NSString).size(withAttributes: [.font: goalFont]).width + 4, w * 0.5)
            text(goal, goalFont, Self.grey, in: CGRect(x: x, y: rowY + 6, width: goalWidth, height: 34))
            x += goalWidth + 18
        }
        for step in words.trail {
            let mark = step.state == 1 ? " ✓" : (step.state == 2 ? " ✕" : "")
            let label = step.name + mark
            let chipFont = Self.font(24, .bold)
            let size = (label as NSString).size(withAttributes: [.font: chipFont])
            let chip = CGRect(x: x, y: rowY, width: size.width + 28, height: 44)
            guard chip.maxX <= w - margin else { break }
            let color = step.state == 1 ? Self.green : (step.state == 2 ? Self.red : Self.yellow)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2.5)
            ctx.addPath(UIBezierPath(roundedRect: chip.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 20).cgPath)
            ctx.strokePath()
            text(label, chipFont, color, in: CGRect(x: chip.minX, y: chip.minY + 6, width: chip.width, height: 32), align: .center)
            x = chip.maxX + 10
        }
    }
}
