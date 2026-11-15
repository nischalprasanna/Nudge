import CoreGraphics
import Foundation
import simd

/// Finds a pointing finger from LiDAR depth when the camera's hand tracker cannot.
///
/// Apple's hand tracker needs to see the palm. When only a finger reaches into the picture
/// (common for keys near the edge of the view) it reports nothing, although the finger is in
/// plain sight. LiDAR still sees that finger as a ridge standing a few centimetres proud of the
/// screen. This finder takes that ridge, works out which way it points, and reports its far end.
///
/// Measured on 800 recorded frames (two runs, one in dim coloured light): where the hand tracker
/// also saw the finger, the two agreed to 2.7 mm at the median and 10 mm at the 90th percentile,
/// and the finder gave an answer in about 160 frames where the tracker gave none. Following the
/// finger's colour to refine the tip was tried and removed: in dim light it ran on past the finger.
///
/// No ARKit types are used here, so the same code runs on a Mac against recorded frames
/// (`Tools/track-replay`).
struct DepthFingerFinder {
    /// One frame's depth map, row by row, in the raw (landscape) camera orientation.
    struct Depth {
        let width: Int
        let height: Int
        let values: UnsafePointer<Float32>
        /// Floats per row (can exceed `width` when rows are padded).
        let rowLength: Int
        /// How far each sample can be trusted (0 low, 1 medium, 2 high), same layout, if known.
        var confidence: UnsafePointer<UInt8>? = nil
        var confidenceRowLength = 0
    }

    struct Result {
        /// Where the fingertip is in the raw camera picture (0...1).
        var imagePoint: CGPoint
        /// Where the finger pad lands on the screen (0...1, can fall a little outside).
        var uv: CGPoint
        /// Height of the finger pad above the glass in metres.
        var hover: Float
        /// Where the depth ridge ended in the raw picture. For testing.
        var ridgeEnd: CGPoint
        /// Depth samples in the ridge.
        var samples: Int
        /// The share of those samples that LiDAR marks as low confidence. For testing.
        var doubtful: Float = 0
        /// Where LiDAR places the glass relative to the anchored plane, in metres.
        var glass: Float = 0
        /// Height of the top of the finger at its tip above the anchored plane, in metres.
        var top: Float = 0
    }

    // MARK: Settings

    /// How far outside the screen's edges to look, in metres. A finger on a key at the edge of
    /// the screen lies almost wholly outside it.
    var margin: Float = 0.04
    /// A point this far above the screen (or above what was there before, outside the screen)
    /// belongs to something in front of it.
    var raise: Float = 0.010
    /// A shape only counts if part of it is over the screen or within this distance of its edge.
    var core: Float = 0.008
    /// A shape with a larger share of low-confidence samples than this is not used.
    var maximumDoubtful: Float = 0.8
    var raiseOutside: Float = 0.015
    /// Nothing higher than this above the glass is a pointing finger about to press.
    var ceiling: Float = 0.20
    /// Taken off the far end of the ridge. Measured against the hand tracker on recorded frames,
    /// the ridge's end and the tracker's fingertip land in the same place, so this is zero.
    var tipInset: Float = 0
    /// Measured on recorded frames: the depth map shows a finger about two of its pixels to one
    /// side of where the camera picture shows it (raw picture, y direction). Depth samples are
    /// moved back by this much before use.
    var registrationShift: Float = 2.2
    var fingerThickness: Float = 0.012

    // MARK: Memory of what is around the screen with no hand there

    private let cell: Float = 0.005
    private var background: [Float] = []
    private var backgroundColumns = 0
    private var backgroundRows = 0
    private var backgroundOrigin = simd_float3(repeating: .nan)

    var hasBackground: Bool { !background.isEmpty }

    mutating func forget() {
        background = []
    }

    /// Call with a frame in which no hand is in view. Notes how high everything around the screen
    /// stands, so that a keyboard, a handle or a worktop is not later taken for a finger.
    mutating func learnBackground(_ depth: Depth, geometry: FrameGeometry, anchor: ScreenAnchor) {
        backgroundColumns = Int(((anchor.width + 2 * margin) / cell).rounded(.up))
        backgroundRows = Int(((anchor.height + 2 * margin) / cell).rounded(.up))
        var grid = [Float](repeating: .nan, count: backgroundColumns * backgroundRows)
        guard let box = searchBox(depth, geometry: geometry, anchor: anchor) else { return }
        for py in box.minY...box.maxY {
            for px in box.minX...box.maxX {
                guard let p = point(depth, px, py, geometry: geometry, anchor: anchor),
                      let index = backgroundIndex(x: p.x, y: p.y) else { continue }
                if grid[index].isNaN || p.h > grid[index] { grid[index] = p.h }
            }
        }
        background = grid
        backgroundOrigin = anchor.origin
    }

    private func backgroundIndex(x: Float, y: Float) -> Int? {
        let column = Int(((x + margin) / cell).rounded(.down))
        let row = Int(((y + margin) / cell).rounded(.down))
        guard column >= 0, column < backgroundColumns, row >= 0, row < backgroundRows else { return nil }
        return row * backgroundColumns + column
    }

    /// The highest thing noted at or right beside this spot. Nil where nothing was seen.
    private func backgroundHeight(x: Float, y: Float) -> Float? {
        guard let centre = backgroundIndex(x: x, y: y) else { return nil }
        let column = centre % backgroundColumns, row = centre / backgroundColumns
        var best: Float?
        for r in max(0, row - 1)...min(backgroundRows - 1, row + 1) {
            for c in max(0, column - 1)...min(backgroundColumns - 1, column + 1) {
                let value = background[r * backgroundColumns + c]
                if !value.isNaN, value > (best ?? -.infinity) { best = value }
            }
        }
        return best
    }

    // MARK: Finding

    private struct Sample {
        var x: Float        // metres across the screen from its left edge
        var y: Float        // metres down the screen from its top edge
        var h: Float        // metres above the screen plane
        var doubtful = false  // LiDAR itself marks this sample as low confidence
    }

    private func point(_ depth: Depth, _ px: Int, _ py: Int, geometry: FrameGeometry, anchor: ScreenAnchor) -> Sample? {
        let d = depth.values[py * depth.rowLength + px]
        guard d.isFinite, d > 0.08, d < 1.5 else { return nil }
        let raw = CGPoint(x: (CGFloat(px) + 0.5) / CGFloat(depth.width),
                          y: (CGFloat(py) + 0.5 - CGFloat(registrationShift)) / CGFloat(depth.height))
        let world = geometry.unproject(raw: raw, depth: d)
        let offset = world - anchor.origin
        var doubtful = false
        if let confidence = depth.confidence { doubtful = confidence[py * depth.confidenceRowLength + px] == 0 }
        return Sample(x: simd_dot(offset, anchor.xAxis), y: simd_dot(offset, anchor.yAxis), h: simd_dot(offset, anchor.normal),
                      doubtful: doubtful)
    }

    /// The part of the depth map that can show the screen and its surroundings.
    private func searchBox(_ depth: Depth, geometry: FrameGeometry, anchor: ScreenAnchor)
        -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for h in [Float(0), 0.10] {
            for (x, y) in [(-margin, -margin), (anchor.width + margin, -margin),
                           (anchor.width + margin, anchor.height + margin), (-margin, anchor.height + margin)] {
                let world = anchor.origin + anchor.xAxis * x + anchor.yAxis * y + anchor.normal * h
                guard let p = geometry.project(world) else { continue }
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard minX.isFinite, maxX > 0, minX < 1, maxY > 0, minY < 1 else { return nil }
        let x0 = max(0, Int(minX * CGFloat(depth.width)) - 1), x1 = min(depth.width - 1, Int(maxX * CGFloat(depth.width)) + 1)
        let y0 = max(0, Int(minY * CGFloat(depth.height)) - 1), y1 = min(depth.height - 1, Int(maxY * CGFloat(depth.height)) + 1)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, x1, y0, y1)
    }

    func find(_ depth: Depth, geometry: FrameGeometry, anchor: ScreenAnchor) -> Result? {
        guard let box = searchBox(depth, geometry: geometry, anchor: anchor) else { return nil }
        let columns = box.maxX - box.minX + 1, rows = box.maxY - box.minY + 1
        let width = anchor.width, height = anchor.height

        var samples = [Sample?](repeating: nil, count: columns * rows)
        var surface: [Float] = []
        for row in 0..<rows {
            for column in 0..<columns {
                guard let p = point(depth, box.minX + column, box.minY + row, geometry: geometry, anchor: anchor) else { continue }
                guard p.x > -margin, p.x < width + margin, p.y > -margin, p.y < height + margin else { continue }
                samples[row * columns + column] = p
                if p.x >= 0, p.x <= width, p.y >= 0, p.y <= height, abs(p.h) < 0.015 { surface.append(p.h) }
            }
        }
        // Where LiDAR places the glass itself relative to the anchored plane.
        var glass: Float = 0
        if surface.count >= 40 {
            surface.sort()
            glass = surface[surface.count / 2]
        }

        // Everything standing proud of the screen. Beside the screen it must also stand proud of
        // whatever was there with no hand in view, where that is known.
        let sameBackground = hasBackground && simd_distance(backgroundOrigin, anchor.origin) < 0.002
        var raised = [Bool](repeating: false, count: columns * rows)
        // Over the screen itself (and a finger's width around it), which is where a shape must
        // show up to count at all: only a hand has any business there.
        var overScreen = [Bool](repeating: false, count: columns * rows)
        for index in 0..<samples.count {
            guard let p = samples[index] else { continue }
            let above = p.h - glass
            guard above <= ceiling else { continue }
            let onScreen = p.x >= 0 && p.x <= width && p.y >= 0 && p.y <= height
            if onScreen {
                raised[index] = above >= raise
                overScreen[index] = raised[index]
            } else {
                guard above >= raiseOutside else { continue }
                if sameBackground, let before = backgroundHeight(x: p.x, y: p.y), p.h - before < raiseOutside { continue }
                raised[index] = true
                overScreen[index] = p.x >= -core && p.x <= width + core && p.y >= -core && p.y <= height + core
            }
        }

        // Group into connected shapes and keep the one that reaches furthest onto the screen.
        var seen = [Bool](repeating: false, count: columns * rows)
        var best: (score: Float, result: Result)?
        var stack: [Int] = []
        for start in 0..<raised.count where raised[start] && !seen[start] {
            var members: [Sample] = []
            var touchesEdge: [Sample] = []
            var seeds = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            seen[start] = true
            while let index = stack.popLast() {
                guard let p = samples[index] else { continue }
                members.append(p)
                if overScreen[index] { seeds += 1 }
                let column = index % columns, row = index / columns
                let atPictureEdge = box.minX + column <= 1 || box.minX + column >= depth.width - 2
                    || box.minY + row <= 1 || box.minY + row >= depth.height - 2
                let atSearchEdge = p.x < -margin + 0.008 || p.x > width + margin - 0.008
                    || p.y < -margin + 0.008 || p.y > height + margin - 0.008
                if atPictureEdge || atSearchEdge { touchesEdge.append(p) }
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let c = column + dx, r = row + dy
                        guard c >= 0, c < columns, r >= 0, r < rows else { continue }
                        let next = r * columns + c
                        if raised[next], !seen[next] {
                            seen[next] = true
                            stack.append(next)
                        }
                    }
                }
            }
            // LiDAR marks a fast-moving hand as untrustworthy, and the depths it gives there are
            // smeared between hand and background. A still finger is only doubtful round its
            // outline. So a shape that is mostly doubtful gives no answer instead of a wrong one.
            let doubtful = members.filter(\.doubtful).count
            guard members.count >= 20, seeds >= 6, Float(doubtful) <= maximumDoubtful * Float(members.count),
                  var candidate = measure(members, entering: touchesEdge, glass: glass, geometry: geometry,
                                          anchor: anchor) else { continue }
            candidate.result.doubtful = Float(doubtful) / Float(members.count)
            if candidate.score > (best?.score ?? -.infinity) { best = candidate }
        }
        return best?.result
    }

    /// Turns one raised shape into a fingertip, or nil if it is not shaped like a finger
    /// reaching for the screen.
    private func measure(_ members: [Sample], entering: [Sample], glass: Float, geometry: FrameGeometry,
                         anchor: ScreenAnchor) -> (score: Float, result: Result)? {
        func centre(_ points: [Sample]) -> simd_float2 {
            var sum = simd_float2(0, 0)
            for p in points { sum += simd_float2(p.x, p.y) }
            return sum / Float(points.count)
        }
        /// Main direction of a set of points (unit vector), and how elongated they are.
        func mainAxis(_ points: [Sample]) -> (axis: simd_float2, elongation: Float)? {
            guard points.count >= 8 else { return nil }
            let c = centre(points)
            var xx: Float = 0, xy: Float = 0, yy: Float = 0
            for p in points {
                let d = simd_float2(p.x, p.y) - c
                xx += d.x * d.x; xy += d.x * d.y; yy += d.y * d.y
            }
            let trace = xx + yy, det = xx * yy - xy * xy
            let root = max(0, trace * trace / 4 - det).squareRoot()
            let large = trace / 2 + root, small = max(trace / 2 - root, 1e-12)
            var axis = abs(xy) > 1e-12 ? simd_float2(large - yy, xy) : (xx >= yy ? simd_float2(1, 0) : simd_float2(0, 1))
            guard simd_length(axis) > 1e-9 else { return nil }
            axis = simd_normalize(axis)
            return (axis, (large / small).squareRoot())
        }
        func percentile(_ values: [Float], _ fraction: Float) -> Float {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * fraction)))]
        }

        let middle = centre(members)
        var origin: simd_float2
        var direction: simd_float2
        if entering.count >= 3 {
            // It comes in from outside: it points from where it enters toward its far end.
            origin = centre(entering)
            let toward = middle - origin
            guard simd_length(toward) > 0.004 else { return nil }
            direction = simd_normalize(toward)
        } else {
            // Wholly in view: a pointing finger slopes down toward its tip.
            guard let (axis, _) = mainAxis(members) else { return nil }
            let along = members.map { simd_dot(simd_float2($0.x, $0.y) - middle, axis) }
            let low = percentile(along, 0.2), high = percentile(along, 0.8)
            var lowHeights: [Float] = [], highHeights: [Float] = []
            for (p, s) in zip(members, along) {
                if s <= low { lowHeights.append(p.h) } else if s >= high { highHeights.append(p.h) }
            }
            guard !lowHeights.isEmpty, !highHeights.isEmpty else { return nil }
            let tipIsHighEnd = percentile(highHeights, 0.5) < percentile(lowHeights, 0.5)
            direction = tipIsHighEnd ? axis : -axis
            origin = middle + direction * (tipIsHighEnd ? percentile(along, 0.02) : -percentile(along, 0.98))
        }

        /// The far end of the shape along the current direction. A few stray samples are passed
        /// over, but only a few: the shape can be mostly fist, and its far end is all fingertip.
        func farEnd(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return sorted[max(0, sorted.count - 4)]
        }
        // Refine the direction from the last few centimetres, where there is only finger.
        var along = members.map { simd_dot(simd_float2($0.x, $0.y) - origin, direction) }
        var far = farEnd(along)
        for _ in 0..<2 {
            let lastStretch = zip(members, along).filter { $0.1 >= far - 0.035 }.map(\.0)
            guard let (axis, elongation) = mainAxis(lastStretch), elongation > 1.5 else { break }
            direction = simd_dot(axis, direction) >= 0 ? axis : -axis
            along = members.map { simd_dot(simd_float2($0.x, $0.y) - origin, direction) }
            far = farEnd(along)
        }
        let side = simd_float2(-direction.y, direction.x)
        let near = percentile(along, 0.03)
        guard far - near >= 0.015 else { return nil }

        // The end of the ridge: its last centimetre and a half.
        var endSides: [Float] = [], endHeights: [Float] = []
        for (p, s) in zip(members, along) where s >= far - 0.015 {
            endSides.append(simd_dot(simd_float2(p.x, p.y) - origin, side))
            endHeights.append(p.h)
        }
        guard endSides.count >= 4 else { return nil }
        // A finger is narrow. A fist, a forearm or a mug is not.
        guard percentile(endSides, 0.9) - percentile(endSides, 0.1) <= 0.03 else { return nil }
        let centreLine = percentile(endSides, 0.5)
        // The finger slopes down toward its tip, so its height is taken from the very end.
        var tipHeights: [Float] = []
        for (p, s) in zip(members, along) where s >= far - 0.006 { tipHeights.append(p.h) }
        let top = tipHeights.count >= 3 ? percentile(tipHeights, 0.5) : percentile(endHeights, 0.3)

        func place(_ s: Float, _ l: Float) -> simd_float2 { origin + direction * s + side * l }
        func picture(_ s: Float, _ l: Float) -> CGPoint? {
            let at = place(s, l)
            return geometry.project(anchor.origin + anchor.xAxis * at.x + anchor.yAxis * at.y + anchor.normal * top)
        }

        let tipAlong = far
        let tip = place(tipAlong - tipInset, centreLine)

        // It must be at or near the screen to be a finger reaching for a key.
        let outside = max(max(-tip.x, tip.x - anchor.width), max(-tip.y, tip.y - anchor.height))
        guard outside <= core + 0.004 else { return nil }
        guard let imagePoint = picture(tipAlong - tipInset, centreLine), let ridgeEnd = picture(far, centreLine),
              (0...1).contains(imagePoint.x), (0...1).contains(imagePoint.y) else { return nil }

        let result = Result(imagePoint: imagePoint,
                            uv: CGPoint(x: CGFloat(tip.x / anchor.width), y: CGFloat(tip.y / anchor.height)),
                            hover: max(0, top - glass - fingerThickness),
                            ridgeEnd: ridgeEnd, samples: members.count, glass: glass, top: top)
        // Prefer the shape that reaches furthest onto the screen (the pointing finger, not a thumb).
        return (-outside, result)
    }
}
