import CoreGraphics
import CoreVideo
import Vision

/// A possible touchscreen outline found in one camera frame. Points are in raw image coordinates.
struct ScreenCandidate {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
    var confidence: Float
    /// At least three pieces of text sit inside it. A control panel is a rectangle full of
    /// labels; a desk, a door or a window is a rectangle without them.
    var hasText = false

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Largest distance any corner moved compared with another candidate.
    func maxCornerDistance(to other: ScreenCandidate) -> CGFloat {
        zip(corners, other.corners)
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .max() ?? .infinity
    }

    /// Corner-by-corner average of several sightings of the same outline, to steady it.
    static func average(_ candidates: [ScreenCandidate]) -> ScreenCandidate? {
        guard let first = candidates.first else { return nil }
        let n = CGFloat(candidates.count)
        func mean(_ pick: (ScreenCandidate) -> CGPoint) -> CGPoint {
            let sum = candidates.reduce(CGPoint.zero) { CGPoint(x: $0.x + pick($1).x, y: $0.y + pick($1).y) }
            return CGPoint(x: sum.x / n, y: sum.y / n)
        }
        return ScreenCandidate(topLeft: mean { $0.topLeft }, topRight: mean { $0.topRight },
                               bottomRight: mean { $0.bottomRight }, bottomLeft: mean { $0.bottomLeft },
                               confidence: first.confidence, hasText: first.hasText)
    }

    /// Fallback when no outline is detected: the middle of what the user is pointing at.
    static var centerOfView: ScreenCandidate {
        // Defined in portrait space (top-left origin) then converted, so "top" is the user's top.
        func raw(_ x: CGFloat, _ y: CGFloat) -> CGPoint { FrameGeometry.raw(fromPortrait: CGPoint(x: x, y: y)) }
        return ScreenCandidate(topLeft: raw(0.15, 0.30), topRight: raw(0.85, 0.30),
                               bottomRight: raw(0.85, 0.70), bottomLeft: raw(0.15, 0.70),
                               confidence: 0)
    }
}

/// A fingertip found in one camera frame, in raw image coordinates.
struct FingertipDetection {
    var point: CGPoint
    var confidence: Float
    /// The last finger joint before the tip, when visible. Tip minus this is the pointing direction.
    var previousJoint: CGPoint?
}

/// Where the camera sees writing, taken as a whole. Positions are in the upright picture:
/// x across from the left, y down from the top, each 0...1.
struct TextSummary {
    var count = 0
    var center = CGPoint(x: 0.5, y: 0.5)
    /// The area holding the bulk of the writing (the outer tenth on each side is left out, so a
    /// stray word elsewhere does not stretch it).
    var bounds = CGRect.zero
}

/// What to tell someone who cannot see the camera's view, so that the control panel ends up
/// in the middle of it at a readable size.
enum SearchHint: String {
    /// Nothing useful to say: either the panel is well placed or nothing is known yet.
    case none
    case left, right, up, down, closer, back
    /// No writing in view at all.
    case nothingInView

    var spoken: String? {
        switch self {
        case .none: return nil
        case .left: return Phrases.turnLeft
        case .right: return Phrases.turnRight
        case .up: return Phrases.tiltUp
        case .down: return Phrases.tiltDown
        case .closer: return Phrases.closer
        case .back: return Phrases.back
        case .nothingInView: return Phrases.nothingInView
        }
    }

    /// Chooses a hint from where the writing is in the picture.
    static func from(_ text: TextSummary) -> SearchHint {
        guard text.count >= 4 else { return text.count == 0 ? .nothingInView : .none }
        let b = text.bounds
        // Running off the picture on opposite sides, or nearly filling it: too close to see it all.
        if b.width > 0.9 || b.height > 0.9 { return .back }
        // Off to one side: turn toward it. The larger offset is dealt with first.
        let dx = text.center.x - 0.5, dy = text.center.y - 0.5
        if abs(dx) > 0.17 || abs(dy) > 0.2 {
            if abs(dx) / 0.17 >= abs(dy) / 0.2 { return dx < 0 ? .left : .right }
            return dy < 0 ? .up : .down
        }
        // In the middle but small: the labels will be too small to read.
        if max(b.width, b.height) < 0.22 { return .closer }
        return .none
    }
}

/// Runs the per-frame Vision requests: index fingertip (every frame) and screen outline (when asked).
final class FrameDetectors {
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()

    private let rectangleRequest: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.1
        // Corners must be close to right angles; looser settings let in skewed shapes.
        request.quadratureTolerance = 15
        request.minimumConfidence = 0.6
        request.maximumObservations = 10
        return request
    }()

    /// Finds where text is (not what it says). Fast, and used to tell a control panel from a blank rectangle.
    private let textRequest: VNDetectTextRectanglesRequest = {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        return request
    }()

    /// `screens` holds every outline found, best first. `handBox` is where a hand is in view
    /// (raw image coordinates), whether or not its fingertip can be made out. `centerText` is
    /// how many pieces of text sit in the middle of the view.
    func detect(pixelBuffer: CVPixelBuffer, wantScreen: Bool)
        -> (fingertip: FingertipDetection?, handBox: CGRect?, screens: [ScreenCandidate], centerText: Int, text: TextSummary?) {
        // .right turns the landscape camera image upright for a phone held in portrait.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        var requests: [VNRequest] = [handRequest]
        if wantScreen {
            requests.append(rectangleRequest)
            requests.append(textRequest)
        }
        do {
            try handler.perform(requests)
        } catch {
            return (nil, nil, [], 0, nil)
        }
        return (fingertip(), handBox(), wantScreen ? screens() : [], wantScreen ? centerText() : 0,
                wantScreen ? textSummary() : nil)
    }

    /// Where the writing in view is, in the upright picture.
    private func textSummary() -> TextSummary {
        let boxes = textRequest.results ?? []
        guard !boxes.isEmpty else { return TextSummary() }
        // Vision's origin is the bottom-left of the upright picture; flip to top-left.
        let xs = boxes.map { $0.boundingBox.midX }.sorted()
        let ys = boxes.map { 1 - $0.boundingBox.midY }.sorted()
        func pick(_ values: [CGFloat], _ fraction: Double) -> CGFloat {
            values[min(values.count - 1, max(0, Int(Double(values.count - 1) * fraction)))]
        }
        let left = pick(xs, 0.1), right = pick(xs, 0.9), top = pick(ys, 0.1), bottom = pick(ys, 0.9)
        return TextSummary(count: boxes.count,
                           center: CGPoint(x: pick(xs, 0.5), y: pick(ys, 0.5)),
                           bounds: CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }

    /// Text boxes inside the area that `ScreenCandidate.centerOfView` covers.
    private func centerText() -> Int {
        (textRequest.results ?? []).filter {
            (0.15...0.85).contains($0.boundingBox.midX) && (0.30...0.70).contains($0.boundingBox.midY)
        }.count
    }

    /// The area covered by the hand joints the tracker is reasonably sure of.
    private func handBox() -> CGRect? {
        guard let hand = handRequest.results?.first,
              let joints = try? hand.recognizedPoints(.all) else { return nil }
        let seen = joints.values
            .filter { $0.confidence > 0.3 }
            .map { FrameGeometry.raw(fromVisionPortrait: $0.location) }
        guard seen.count >= 4 else { return nil }
        let xs = seen.map(\.x), ys = seen.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Guess a hidden fingertip from the two joints behind it. Off: a guessed position that is
    /// a centimetre or two out is worse for guidance than saying the finger cannot be seen.
    var guessesHiddenTip = false

    private func fingertip() -> FingertipDetection? {
        guard let hand = handRequest.results?.first else { return nil }
        let tip = try? hand.recognizedPoint(.indexTip)
        let lastJoint = try? hand.recognizedPoint(.indexDIP)
        let middleJoint = try? hand.recognizedPoint(.indexPIP)

        if let tip, tip.confidence > 0.2 {
            var previous: CGPoint?
            if let lastJoint, lastJoint.confidence > 0.2 {
                previous = FrameGeometry.raw(fromVisionPortrait: lastJoint.location)
            }
            return FingertipDetection(point: FrameGeometry.raw(fromVisionPortrait: tip.location),
                                      confidence: tip.confidence, previousJoint: previous)
        }

        // The tip itself is hidden or blurred, but the two joints behind it are clear:
        // the tip lies a little further along the same line.
        if guessesHiddenTip, let lastJoint, let middleJoint, lastJoint.confidence > 0.3, middleJoint.confidence > 0.3 {
            let estimate = CGPoint(x: lastJoint.location.x + (lastJoint.location.x - middleJoint.location.x) * 0.9,
                                   y: lastJoint.location.y + (lastJoint.location.y - middleJoint.location.y) * 0.9)
            guard (0...1).contains(estimate.x), (0...1).contains(estimate.y) else { return nil }
            return FingertipDetection(point: FrameGeometry.raw(fromVisionPortrait: estimate),
                                      confidence: 0.25,
                                      previousJoint: FrameGeometry.raw(fromVisionPortrait: lastJoint.location))
        }
        return nil
    }

    /// Ranks outlines so that the one most likely to be the control panel comes first:
    /// the rectangle that tightly holds the most text. A blank rectangle scores zero.
    private func screens() -> [ScreenCandidate] {
        guard let observations = rectangleRequest.results, !observations.isEmpty else { return [] }
        let textCenters = (textRequest.results ?? []).map {
            CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)
        }

        func quad(_ o: VNRectangleObservation) -> [CGPoint] { [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft] }

        func area(_ q: [CGPoint]) -> CGFloat {
            var sum: CGFloat = 0
            for i in 0..<4 {
                let a = q[i], b = q[(i + 1) % 4]
                sum += a.x * b.y - b.x * a.y
            }
            return abs(sum) / 2
        }

        func contains(_ q: [CGPoint], _ p: CGPoint) -> Bool {
            var sign: CGFloat = 0
            for i in 0..<4 {
                let a = q[i], b = q[(i + 1) % 4]
                let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                if cross == 0 { continue }
                if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
            }
            return true
        }

        func textScore(_ o: VNRectangleObservation) -> CGFloat {
            let q = quad(o)
            let count = textCenters.filter { contains(q, $0) }.count
            guard count >= 3 else { return 0 }
            // Dividing by the square root of the area favours the tight rectangle around the labels
            // over a much larger one (a whole laptop screen, or the appliance door) that also contains them.
            return CGFloat(count) / max(area(q).squareRoot(), 0.05)
        }

        // Used only when no rectangle holds text: big outlines near the middle of the view.
        func sizeScore(_ o: VNRectangleObservation) -> CGFloat {
            let box = o.boundingBox
            let offCenter = hypot(box.midX - 0.5, box.midY - 0.5)
            return box.width * box.height * (1 - min(offCenter, 0.5))
        }

        let ranked = observations
            .map { (observation: $0, text: textScore($0), size: sizeScore($0)) }
            .sorted { a, b in
                if a.text != b.text { return a.text > b.text }
                return a.size > b.size
            }

        return ranked.map { item in
            let o = item.observation
            return ScreenCandidate(topLeft: FrameGeometry.raw(fromVisionPortrait: o.topLeft),
                                   topRight: FrameGeometry.raw(fromVisionPortrait: o.topRight),
                                   bottomRight: FrameGeometry.raw(fromVisionPortrait: o.bottomRight),
                                   bottomLeft: FrameGeometry.raw(fromVisionPortrait: o.bottomLeft),
                                   confidence: o.confidence, hasText: item.text > 0)
        }
    }
}
