import Foundation

/// Finds a small coloured marker (a sticker or a dab of paint on the fingernail) in the camera
/// picture by its colour.
///
/// A marker is the most dependable way to follow a fingertip: it is found in every frame, to
/// within a millimetre or two, even when only the tip of the finger is in view and nothing in
/// the picture looks like a hand. It works in the camera's own colour channels (Cb and Cr),
/// which change little as the light gets brighter or dimmer.
struct MarkerFinder {
    struct Color: Equatable {
        var cb: UInt8
        var cr: UInt8

        /// How far the colour is from grey. Greys, white and black cannot be told apart by colour.
        var strength: Int { max(abs(Int(cb) - 128), abs(Int(cr) - 128)) }
        /// True when the colour is too close to typical skin to be told from the finger itself.
        var looksLikeSkin: Bool { abs(Int(cb) - 110) < 16 && abs(Int(cr) - 152) < 16 }
    }

    struct Blob {
        /// Centre, in pixels of the colour plane.
        var x: Float
        var y: Float
        /// How many sampled pixels matched.
        var count: Int
    }

    /// How close a pixel's colour must be to the marker's, in each channel.
    var tolerance = 20
    /// Darker pixels than this carry too little colour to judge.
    var minimumLuma: UInt8 = 45

    /// Every patch of marker colour inside the given rectangle of the colour plane, largest first.
    /// `colour(x, y)` and `luma(x, y)` read one pixel of the colour plane and the brightness at
    /// the same place. Every `step`-th pixel is looked at.
    func blobs(minX: Int, minY: Int, maxX: Int, maxY: Int, step: Int = 2, marker: Color,
               colour: (_ x: Int, _ y: Int) -> (cb: UInt8, cr: UInt8),
               luma: (_ x: Int, _ y: Int) -> UInt8) -> [Blob] {
        guard maxX > minX, maxY > minY else { return [] }
        // Matches are gathered into cells a few samples across, then neighbouring cells are joined.
        let cell = step * 4
        let columns = (maxX - minX) / cell + 1
        let rows = (maxY - minY) / cell + 1
        var counts = [Int](repeating: 0, count: columns * rows)
        var sumX = [Float](repeating: 0, count: columns * rows)
        var sumY = [Float](repeating: 0, count: columns * rows)
        let cb0 = Int(marker.cb), cr0 = Int(marker.cr)

        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let c = colour(x, y)
                if abs(Int(c.cb) - cb0) <= tolerance, abs(Int(c.cr) - cr0) <= tolerance, luma(x, y) >= minimumLuma {
                    let index = ((y - minY) / cell) * columns + (x - minX) / cell
                    counts[index] += 1
                    sumX[index] += Float(x)
                    sumY[index] += Float(y)
                }
                x += step
            }
            y += step
        }

        var seen = [Bool](repeating: false, count: columns * rows)
        var blobs: [Blob] = []
        var stack: [Int] = []
        for start in 0..<(columns * rows) where counts[start] >= 2 && !seen[start] {
            var total = 0
            var x: Float = 0, y: Float = 0
            stack.append(start)
            seen[start] = true
            while let index = stack.popLast() {
                total += counts[index]
                x += sumX[index]
                y += sumY[index]
                let column = index % columns, row = index / columns
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nc = column + dx, nr = row + dy
                        guard nc >= 0, nr >= 0, nc < columns, nr < rows else { continue }
                        let neighbour = nr * columns + nc
                        if counts[neighbour] >= 2, !seen[neighbour] {
                            seen[neighbour] = true
                            stack.append(neighbour)
                        }
                    }
                }
            }
            if total >= 6 { blobs.append(Blob(x: x / Float(total), y: y / Float(total), count: total)) }
        }
        return blobs.sorted { $0.count > $1.count }
    }
}
