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
    ///
    /// A big image is also read in overlapping quarters. Vision shrinks what it is given before
    /// looking for text, so the small print on a keypad that fills only part of the picture is
    /// lost in a single pass over the whole thing; each quarter keeps its detail.
    func readText(in image: CGImage) -> [ScreenElement] {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        var regions = [whole]
        let columns = image.width >= 1500 ? 2 : 1
        let rows = image.height >= 1500 ? 2 : 1
        if columns * rows > 1 {
            // Each piece covers a little more than half, so a label on the join is whole in one of them.
            let span: CGFloat = 0.57
            for row in 0..<rows {
                for column in 0..<columns {
                    regions.append(CGRect(x: columns == 1 ? 0 : (column == 0 ? 0 : 1 - span),
                                          y: rows == 1 ? 0 : (row == 0 ? 0 : 1 - span),
                                          width: columns == 1 ? 1 : span,
                                          height: rows == 1 ? 1 : span))
                }
            }
        }

        var passes = [[ScreenElement]](repeating: [], count: regions.count)
        passes.withUnsafeMutableBufferPointer { buffer in
            let results = buffer
            DispatchQueue.concurrentPerform(iterations: regions.count) { index in
                results[index] = self.recognize(image, region: regions[index])
            }
        }

        // The same label can turn up in several passes. Keep the fullest version of each:
        // largest box first, then drop anything that mostly lies inside one already kept.
        var kept: [ScreenElement] = []
        for element in passes.joined().sorted(by: { $0.box.width * $0.box.height > $1.box.width * $1.box.height }) {
            let area = element.box.width * element.box.height
            let duplicate = kept.contains { other in
                let overlap = other.box.intersection(element.box)
                return !overlap.isNull && overlap.width * overlap.height > 0.4 * area
            }
            if !duplicate { kept.append(element) }
        }

        let elements = Self.mergeStacked(kept, imageWidth: CGFloat(image.width), imageHeight: CGFloat(image.height))

        // Reading order: top to bottom in rows, then left to right.
        return elements.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > 0.04 { return a.box.midY < b.box.midY }
            return a.box.midX < b.box.midX
        }
    }

    /// Reads the text in one part of the image. `region` is normalized with the origin at the
    /// top-left; the boxes returned are positions in the whole image.
    private func recognize(_ full: CGImage, region: CGRect) -> [ScreenElement] {
        let pixels = CGRect(x: region.minX * CGFloat(full.width), y: region.minY * CGFloat(full.height),
                            width: region.width * CGFloat(full.width), height: region.height * CGFloat(full.height)).integral
        guard let image = region.width >= 1 && region.height >= 1 ? full : full.cropping(to: pixels) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Button labels are short ("30 SEC", "+1 MIN"); dictionary correction makes them worse.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        // Low enough to keep the small print on a keypad seen from arm's length.
        request.minimumTextHeight = 0.006

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }

        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        var elements: [ScreenElement] = []

        for observation in observations {
            guard let best = observation.topCandidates(1).first else { continue }
            let string = best.string

            // Vision returns a whole line of text as one item, so a keypad row comes back as
            // "1 2 3" with one box. Split the line into words with their own boxes, then join
            // back only the words that sit close together (as in "TIME COOK").
            var words: [(text: String, box: CGRect)] = []
            var index = string.startIndex
            while index < string.endIndex {
                while index < string.endIndex, string[index].isWhitespace { index = string.index(after: index) }
                guard index < string.endIndex else { break }
                var end = index
                while end < string.endIndex, !string[end].isWhitespace { end = string.index(after: end) }
                if let box = try? best.boundingBox(for: index..<end)?.boundingBox {
                    words.append((String(string[index..<end]), box))
                }
                index = end
            }

            if words.isEmpty {
                let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { words = [(text, observation.boundingBox)] }
            }

            var groups: [(text: String, box: CGRect)] = []
            for word in words.sorted(by: { $0.box.minX < $1.box.minX }) {
                if let last = groups.last {
                    let gap = (word.box.minX - last.box.maxX) * imageWidth
                    let lineHeight = max(last.box.height, word.box.height) * imageHeight
                    if gap < lineHeight * 0.9 {
                        groups[groups.count - 1] = (last.text + " " + word.text, last.box.union(word.box))
                        continue
                    }
                }
                groups.append(word)
            }

            for group in groups {
                // Vision's origin is bottom-left of the piece; screen coordinates use the
                // top-left of the whole image.
                let box = CGRect(x: region.minX + group.box.minX * region.width,
                                 y: region.minY + (1 - group.box.maxY) * region.height,
                                 width: group.box.width * region.width,
                                 height: group.box.height * region.height)
                elements.append(ScreenElement(label: group.text, box: box, confidence: best.confidence))
            }
        }
        return elements
    }

    /// Joins a label printed on two lines ("TIME" over "COOK") into one button name.
    /// Two pieces are joined when one sits directly under the other, almost touching,
    /// in a similar text size. A big digit over a small caption stays separate.
    static func mergeStacked(_ input: [ScreenElement], imageWidth: CGFloat, imageHeight: CGFloat) -> [ScreenElement] {
        var elements = input.sorted { $0.box.minY < $1.box.minY }
        var index = 0
        while index < elements.count {
            let upper = elements[index]
            let match = elements.indices.first { other in
                guard other != index else { return false }
                let lower = elements[other]
                let upperHeight = upper.box.height * imageHeight
                let lowerHeight = lower.box.height * imageHeight
                let gap = (lower.box.minY - upper.box.maxY) * imageHeight
                let offset = abs(lower.box.midX - upper.box.midX) * imageWidth
                let widest = max(upper.box.width, lower.box.width) * imageWidth
                // Keypad digits sit in columns too ("4" over "7") and must stay separate buttons.
                // Only words can be two lines of one name.
                let words = upper.label.contains(where: \.isLetter) && lower.label.contains(where: \.isLetter)
                return words
                    && gap > -0.3 * min(upperHeight, lowerHeight)
                    && gap < 0.7 * min(upperHeight, lowerHeight)
                    && offset < 0.25 * widest
                    && max(upperHeight, lowerHeight) < 1.5 * min(upperHeight, lowerHeight)
            }
            if let match {
                let lower = elements[match]
                elements[index] = ScreenElement(label: upper.label + " " + lower.label,
                                                box: upper.box.union(lower.box),
                                                confidence: min(upper.confidence, lower.confidence))
                elements.remove(at: match)
                // Stay on this element in case a third line follows.
                if match < index { index -= 1 }
            } else {
                index += 1
            }
        }
        return elements
    }
}
