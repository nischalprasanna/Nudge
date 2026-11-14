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
    func readText(in original: CGImage) -> [ScreenElement] {
        // A keypad seen from arm's length is only a few hundred pixels across, with letters
        // under ten pixels tall. Enlarging it first roughly doubles how many labels are read.
        let image = Self.enlarged(original)
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

        var elements = Self.mergeStacked(kept, imageWidth: CGFloat(image.width), imageHeight: CGFloat(image.height))
        elements = addKeys(to: elements, in: image)

        // Reading order: top to bottom in rows, then left to right.
        return elements.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > 0.04 { return a.box.midY < b.box.midY }
            return a.box.midX < b.box.midX
        }
    }

    // MARK: Keys

    /// Finds the keys of a keypad as boxes and makes sure each has a label.
    ///
    /// Text recognition is poor at a single digit standing alone inside a box: on a twelve-key
    /// pad it typically returns three to six of them. So the key outlines are found as
    /// rectangles, each unread key is read on its own, and digits still missing are filled in
    /// from the ones that were read, since keypads are laid out 1 to 9 in rows with 0 beneath 8.
    func addKeys(to elements: [ScreenElement], in image: CGImage) -> [ScreenElement] {
        let keys = Self.keyBoxes(in: image)
        guard keys.count >= 4 else { return elements }

        // Start from what the text pass already found on each key.
        var labels = [String](repeating: "", count: keys.count)
        var used = Set<Int>()
        for (index, element) in elements.enumerated() {
            if let key = keys.firstIndex(where: { $0.contains(element.center) }) {
                labels[key] = labels[key].isEmpty ? element.label : labels[key] + " " + element.label
                used.insert(index)
            }
        }

        // Read the remaining keys one at a time, at two sizes.
        let unread = keys.indices.filter { labels[$0].isEmpty }
        var found = [String](repeating: "", count: unread.count)
        found.withUnsafeMutableBufferPointer { buffer in
            let results = buffer
            DispatchQueue.concurrentPerform(iterations: unread.count) { slot in
                let box = keys[unread[slot]].insetBy(dx: keys[unread[slot]].width * 0.1, dy: keys[unread[slot]].height * 0.1)
                let pixels = CGRect(x: box.minX * CGFloat(image.width), y: box.minY * CGFloat(image.height),
                                    width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height)).integral
                guard let crop = image.cropping(to: pixels) else { return }
                for height in [120, 240] as [CGFloat] {
                    let text = Self.readSingle(Self.resized(crop, toHeight: height))
                    if !text.isEmpty {
                        results[slot] = text
                        break
                    }
                }
            }
        }
        for (slot, key) in unread.enumerated() { labels[key] = found[slot] }

        labels = Self.fillInDigits(labels, keys: keys)

        var result = elements.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        for (key, label) in zip(keys, labels) where !label.isEmpty {
            result.append(ScreenElement(label: label, box: key, confidence: 0.6, isButton: true))
        }
        return result
    }

    /// Outlines of same-sized buttons, normalized with the origin at the top-left.
    static func keyBoxes(in image: CGImage) -> [CGRect] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 60
        request.minimumSize = 0.06
        request.minimumAspectRatio = 0.4
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 20
        request.minimumConfidence = 0.3
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let observations = request.results, observations.count >= 4 else { return [] }
        let boxes = observations.map { o -> CGRect in
            let b = o.boundingBox
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }

        // Keys are all about one size. Take the middle size as "a key" and drop everything
        // far from it: the outline of the whole pad, the display, the loop of a "0".
        let widths = boxes.map(\.width).sorted()
        let heights = boxes.map(\.height).sorted()
        let width = widths[widths.count / 2]
        let height = heights[heights.count / 2]
        let alike = boxes.filter {
            $0.width > width * 0.65 && $0.width < width * 1.5 && $0.height > height * 0.65 && $0.height < height * 1.5
        }

        // The inner and outer edge of one key's border both come back; keep one box per key.
        var keys: [CGRect] = []
        for box in alike.sorted(by: { $0.width * $0.height < $1.width * $1.height }) {
            let duplicate = keys.contains { hypot($0.midX - box.midX, $0.midY - box.midY) < min(width, height) * 0.5 }
            if !duplicate { keys.append(box) }
        }
        return keys.count >= 4 ? keys : []
    }

    /// Fills in digits the reader missed, from those it got. Positions are worked out as rows
    /// and columns of the key grid; a digit d belongs at row (d-1)/3, column (d-1)%3 of the
    /// number block, and 0 sits under 8. Needs at least two digits that agree.
    static func fillInDigits(_ input: [String], keys: [CGRect]) -> [String] {
        var labels = input
        guard let height = keys.map(\.height).sorted().dropFirst(keys.count / 2).first,
              let width = keys.map(\.width).sorted().dropFirst(keys.count / 2).first else { return labels }

        func index(of value: CGFloat, in centres: [CGFloat], step: CGFloat) -> Int {
            // Rank among the distinct rows or columns.
            var distinct: [CGFloat] = []
            for centre in centres.sorted() where distinct.last.map({ centre - $0 > step * 0.5 }) ?? true {
                distinct.append(centre)
            }
            return distinct.lastIndex(where: { value - $0 > -step * 0.5 }) ?? 0
        }
        let rows = keys.map { index(of: $0.midY, in: keys.map(\.midY), step: height) }
        let columns = keys.map { index(of: $0.midX, in: keys.map(\.midX), step: width) }

        // Each digit that was read votes for where the "1" key must be.
        var votes: [SIMD2<Int>: Int] = [:]
        for (key, label) in labels.enumerated() {
            guard label.count == 1, let digit = Int(label), digit >= 1 else { continue }
            votes[SIMD2(rows[key] - (digit - 1) / 3, columns[key] - (digit - 1) % 3), default: 0] += 1
        }
        guard let winner = votes.max(by: { $0.value < $1.value }), winner.value >= 2,
              winner.value * 3 >= votes.values.reduce(0, +) * 2 else { return labels }
        let origin = winner.key

        for key in keys.indices {
            let row = rows[key] - origin.x
            let column = columns[key] - origin.y
            // Only overwrite nothing, or a stray single character; never a word such as "Stop".
            guard labels[key].count <= 1 else { continue }
            if (0..<3).contains(row), (0..<3).contains(column) {
                labels[key] = String(1 + row * 3 + column)
            } else if row == 3, column == 1 {
                labels[key] = "0"
            }
        }
        return labels
    }

    private static func readSingle(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        request.minimumTextHeight = 0
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return "" }
        let pieces = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resized(_ image: CGImage, toHeight target: CGFloat) -> CGImage {
        let scale = target / CGFloat(max(image.height, 1))
        let width = max(1, Int(CGFloat(image.width) * scale))
        guard let context = CGContext(data: nil, width: width, height: Int(target), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: Int(target)))
        return context.makeImage() ?? image
    }

    /// Scales a small image up so its longest side is about 2800 pixels (at most four times).
    static func enlarged(_ image: CGImage) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        // Up to about 2800 pixels: a whole control panel photographed from arm's length comes
        // in around 2000, with its small labels only a dozen pixels tall.
        guard longest < 2500, longest > 0 else { return image }
        let scale = min(4, 2800 / longest)
        let width = Int(CGFloat(image.width) * scale)
        let height = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
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
        // English only for now: with automatic language detection a lone digit sometimes came
        // back as an Arabic letter or a CJK full stop.
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
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
