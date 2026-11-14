import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision

/// Turns the anchored screen into a flat, upright image and reads its text on the device.
final class ScreenReader {
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// Perspective-corrects the anchored screen out of a camera image.
    /// Returns nil if any corner of the screen is out of view.
    func rectify(pixelBuffer: CVPixelBuffer, anchor: ScreenAnchor, geometry: FrameGeometry) -> CGImage? {
        let imageHeight = geometry.imageSize.height
        var points: [CGPoint] = []
        for corner in anchor.corners {
            guard let raw = geometry.project(corner),
                  (-0.02...1.02).contains(raw.x), (-0.02...1.02).contains(raw.y) else { return nil }
            // Core Image puts the origin at the bottom-left.
            points.append(CGPoint(x: raw.x * geometry.imageSize.width, y: imageHeight - raw.y * imageHeight))
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        filter.topLeft = points[0]
        filter.topRight = points[1]
        filter.bottomRight = points[2]
        filter.bottomLeft = points[3]
        guard let output = filter.outputImage,
              output.extent.width >= 120, output.extent.height >= 120 else { return nil }
        return context.createCGImage(output, from: output.extent)
    }

    /// Reads every piece of text in a rectified screen image. Runs entirely on the device.
    func readText(in image: CGImage) -> [ScreenElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Button labels are short ("30 SEC", "+1 MIN"); dictionary correction makes them worse.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.015

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }

        let elements: [ScreenElement] = observations.compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let b = observation.boundingBox
            // Vision's origin is bottom-left; screen coordinates use top-left.
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            return ScreenElement(label: text, box: box, confidence: best.confidence)
        }
        // Reading order: top to bottom in rows, then left to right.
        return elements.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > 0.04 { return a.box.midY < b.box.midY }
            return a.box.midX < b.box.midX
        }
    }
}
