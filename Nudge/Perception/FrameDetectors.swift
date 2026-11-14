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
        request.minimumSize = 0.15
        request.quadratureTolerance = 25
        request.minimumConfidence = 0.6
        request.maximumObservations = 6
        return request
    }()

    /// `screens` holds every outline found, best first (largest and nearest the middle of the view).
    func detect(pixelBuffer: CVPixelBuffer, wantScreen: Bool) -> (fingertip: FingertipDetection?, screens: [ScreenCandidate]) {
        // .right turns the landscape camera image upright for a phone held in portrait.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        var requests: [VNRequest] = [handRequest]
        if wantScreen { requests.append(rectangleRequest) }
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
              tip.confidence > 0.3 else { return nil }
        return FingertipDetection(point: FrameGeometry.raw(fromVisionPortrait: tip.location),
                                  confidence: tip.confidence)
    }

    private func screens() -> [ScreenCandidate] {
        guard let observations = rectangleRequest.results, !observations.isEmpty else { return [] }
        // Prefer big outlines near the middle of the view: that is what the user is pointing at.
        func score(_ o: VNRectangleObservation) -> CGFloat {
            let box = o.boundingBox
            let offCenter = hypot(box.midX - 0.5, box.midY - 0.5)
            return box.width * box.height * (1 - min(offCenter, 0.5))
        }
        return observations.sorted { score($0) > score($1) }.map { observation in
            ScreenCandidate(topLeft: FrameGeometry.raw(fromVisionPortrait: observation.topLeft),
                            topRight: FrameGeometry.raw(fromVisionPortrait: observation.topRight),
                            bottomRight: FrameGeometry.raw(fromVisionPortrait: observation.bottomRight),
                            bottomLeft: FrameGeometry.raw(fromVisionPortrait: observation.bottomLeft),
                            confidence: observation.confidence)
        }
    }
}
