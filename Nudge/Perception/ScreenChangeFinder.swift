import CoreGraphics
import Foundation

/// Finds the fingertip by comparing how the screen looks now with how it looked with no hand
/// in front of it.
///
/// The camera's hand tracker needs to see a hand. When someone reaches in from the edge of the
/// picture only a finger is in view, and the tracker returns nothing. But Nudge already knows
/// exactly what the screen looks like, so anything that newly covers it and reaches in from the
/// edge is the hand, and the end of that shape furthest from where it came in is the fingertip.
struct ScreenChangeFinder {
    /// A small picture of the screen area: luminance and the two colour channels, row by row.
    struct Sample {
        var width: Int
        var height: Int
        var y: [UInt8]
        var cb: [UInt8]
        var cr: [UInt8]
    }

    enum Side { case top, bottom, left, right }

    struct Result {
        /// Where the finger pad will land, as a fraction of the sampled area (origin top-left).
        var contact: CGPoint
        /// The very end of the finger, same units.
        var tip: CGPoint
        /// Share of the sampled area covered by the hand.
        var coverage: Float
        var entry: Side
    }

    /// How different a pixel must be to count as covered (0...255 scale, colour weighted).
    var threshold: Float = 24
    /// The pad of the finger touches the glass this far behind its very tip (metres).
    var padOffset: Float = 0.007

    /// `physicalWidth` and `physicalHeight` are the size of the sampled area in metres.
    func find(reference: Sample, current: Sample, physicalWidth: Float, physicalHeight: Float) -> Result? {
        let w = current.width, h = current.height
        guard w >= 16, h >= 16, reference.width == w, reference.height == h else { return nil }
        let count = w * h

        // The camera changes exposure and colour balance as a hand comes into view. Estimate
        // that overall shift from the middle of the distribution and take it out.
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        var ratios: [Int] = [], shiftCb: [Int] = [], shiftCr: [Int] = []
        ratios.reserveCapacity(count / 4)
        for index in stride(from: 0, to: count, by: 4) {
            ratios.append(Int(current.y[index]) * 256 / max(Int(reference.y[index]), 8))
            shiftCb.append(Int(current.cb[index]) - Int(reference.cb[index]))
            shiftCr.append(Int(current.cr[index]) - Int(reference.cr[index]))
        }
        let gain = min(max(Float(median(ratios)) / 256, 0.6), 1.7)
        let offsetCb = Float(median(shiftCb)), offsetCr = Float(median(shiftCr))

        // A pixel is "covered" if nothing near the same spot in the reference looks like it.
        // Looking at the neighbours forgives the reference being a pixel or two out of register.
        var covered = [Bool](repeating: false, count: count)
        for y in 0..<h {
            for x in 0..<w {
                let index = y * w + x
                let cy = Float(current.y[index]), ccb = Float(current.cb[index]) - offsetCb, ccr = Float(current.cr[index]) - offsetCr
                var best = Float.greatestFiniteMagnitude
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        let other = ny * w + nx
                        let difference = abs(cy - Float(reference.y[other]) * gain) * 0.5
                            + abs(ccb - Float(reference.cb[other])) + abs(ccr - Float(reference.cr[other]))
                        if difference < best { best = difference }
                    }
                }
                covered[index] = best > threshold
            }
        }

        // Drop specks and thin lines: keep pixels with most of their neighbours covered too.
        var solid = [Bool](repeating: false, count: count)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where covered[y * w + x] {
                var neighbours = 0
                for dy in -1...1 { for dx in -1...1 where covered[(y + dy) * w + x + dx] { neighbours += 1 } }
                solid[y * w + x] = neighbours >= 6
            }
        }
        // The outermost ring of pixels has no full neighbourhood; let it join whatever touches it.
        for x in 0..<w {
            solid[x] = covered[x] && solid[w + x]
            solid[(h - 1) * w + x] = covered[(h - 1) * w + x] && solid[(h - 2) * w + x]
        }
        for y in 0..<h {
            solid[y * w] = covered[y * w] && solid[y * w + 1]
            solid[y * w + w - 1] = covered[y * w + w - 1] && solid[y * w + w - 2]
        }

        // The hand is the largest connected shape. It usually reaches the edge of the picture,
        // but not always as one piece: where a finger passes over something its own colour
        // (a wooden trim, a beige bezel) the shape breaks, so reaching the edge is not required.
        var label = [Int32](repeating: 0, count: count)
        var bestPixels: [Int] = []
        var next: Int32 = 0
        var stack: [Int] = []
        for start in 0..<count where solid[start] && label[start] == 0 {
            next += 1
            var pixels: [Int] = []
            stack.append(start)
            label[start] = next
            while let index = stack.popLast() {
                pixels.append(index)
                let x = index % w, y = index / w
                if x > 0, solid[index - 1], label[index - 1] == 0 { label[index - 1] = next; stack.append(index - 1) }
                if x < w - 1, solid[index + 1], label[index + 1] == 0 { label[index + 1] = next; stack.append(index + 1) }
                if y > 0, solid[index - w], label[index - w] == 0 { label[index - w] = next; stack.append(index - w) }
                if y < h - 1, solid[index + w], label[index + w] == 0 { label[index + w] = next; stack.append(index + w) }
            }
            if pixels.count > bestPixels.count { bestPixels = pixels }
        }
        let coverage = Float(bestPixels.count) / Float(count)
        // Too small is noise or a digit changing on the display; too large means the picture as
        // a whole has changed (the phone moved, the lights changed) and nothing can be concluded.
        guard coverage > 0.015, coverage < 0.6 else { return nil }

        // A finger is long and narrow. Find the line it lies along, and its two ends.
        let metresX = physicalWidth / Float(w), metresY = physicalHeight / Float(h)
        func metres(_ index: Int) -> SIMD2<Float> { SIMD2(Float(index % w) * metresX, Float(index / w) * metresY) }
        func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { ((a - b) * (a - b)).sum().squareRoot() }
        var centre = SIMD2<Float>(0, 0)
        for index in bestPixels { centre += metres(index) }
        centre /= Float(bestPixels.count)
        var sxx: Float = 0, sxy: Float = 0, syy: Float = 0
        for index in bestPixels {
            let d = metres(index) - centre
            sxx += d.x * d.x
            sxy += d.x * d.y
            syy += d.y * d.y
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let axis = SIMD2<Float>(cos(angle), sin(angle))

        let along = bestPixels.map { (index: $0, t: ((metres($0) - centre) * axis).sum()) }.sorted { $0.t < $1.t }
        let take = max(4, along.count / 25)
        func mean(_ items: ArraySlice<(index: Int, t: Float)>) -> SIMD2<Float> {
            var sum = SIMD2<Float>(0, 0)
            for item in items { sum += metres(item.index) }
            return sum / Float(items.count)
        }
        let endA = mean(along.prefix(take)), endB = mean(along.suffix(take))

        // The hand comes from outside, so the end nearer the edge of the picture is where it
        // came in, and the other end is the fingertip.
        func fromEdge(_ point: SIMD2<Float>) -> Float {
            min(point.x, physicalWidth - point.x, point.y, physicalHeight - point.y)
        }
        let tip = fromEdge(endA) > fromEdge(endB) ? endA : endB
        let base = fromEdge(endA) > fromEdge(endB) ? endB : endA
        // A hand reaches in from outside, so its near end is close to the edge of the picture.
        // A change in the middle of the screen (the display counting down, a new message) is not a hand.
        guard fromEdge(base) < 0.35 * min(physicalWidth, physicalHeight) else { return nil }
        let entry: Side
        let gaps: [(Side, Float)] = [(.left, base.x), (.right, physicalWidth - base.x), (.top, base.y), (.bottom, physicalHeight - base.y)]
        entry = gaps.min(by: { $0.1 < $1.1 })?.0 ?? .bottom

        // The pad touches the glass a little behind the very tip, back along the finger.
        var contact = tip
        let length = distance(tip, base)
        if length > 0.01 { contact = tip - (tip - base) / length * padOffset }

        func fraction(_ point: SIMD2<Float>) -> CGPoint {
            CGPoint(x: CGFloat((point.x / metresX + 0.5) / Float(w)), y: CGFloat((point.y / metresY + 0.5) / Float(h)))
        }
        return Result(contact: fraction(contact), tip: fraction(tip), coverage: coverage, entry: entry)
    }
}
