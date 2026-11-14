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
                               confidence: first.confidence)
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

    /// `screens` holds every outline found, best first.
    func detect(pixelBuffer: CVPixelBuffer, wantScreen: Bool) -> (fingertip: FingertipDetection?, screens: [ScreenCandidate]) {
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
            return (nil, [])
        }
        return (fingertip(), wantScreen ? screens() : [])
    }

    private func fingertip() -> FingertipDetection? {
        guard let hand = handRequest.results?.first,
              let tip = try? hand.recognizedPoint(.indexTip),
              tip.confidence > 0.2 else { return nil }
        var previous: CGPoint?
        if let joint = try? hand.recognizedPoint(.indexDIP), joint.confidence > 0.2 {
            previous = FrameGeometry.raw(fromVisionPortrait: joint.location)
        }
        return FingertipDetection(point: FrameGeometry.raw(fromVisionPortrait: tip.location),
                                  confidence: tip.confidence, previousJoint: previous)
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
                                   confidence: o.confidence)
        }
    }
}
