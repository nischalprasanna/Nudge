import CoreGraphics
import simd

/// Finds the pointing hand straight from LiDAR depth, without needing to see the fingertip.
///
/// The camera's hand tracker loses the finger when the back of the hand hides it, in poor
/// light, or when only part of the hand is in view. LiDAR still sees "something in front of
/// the screen". Whatever part of that is nearest the glass is what will touch it first, so
/// that is reported as the pointer. When the fingertip itself is hidden this lands on the
/// leading knuckle, which is a centimetre or two off, but far better than no position at all.
struct DepthHandFinder {
    struct Result {
        /// Where the nearest part of the hand would land on the screen, normalized, origin top-left.
        var uv: CGPoint
        /// Its height above the glass in metres (surface seen by LiDAR, not corrected for finger thickness).
        var height: Float
        /// Same point in the raw camera image, normalized, for drawing.
        var imagePoint: CGPoint
        /// How many depth samples were classed as hand.
        var sampleCount: Int
    }

    /// Anything lower than this above the glass is treated as the screen itself (metres).
    var minimumHeight: Float = 0.012
    /// Anything higher than this is ignored: it is not reaching for the screen (metres).
    var maximumHeight: Float = 0.25

    /// `depth` returns metres along the camera axis for a depth-map pixel; `confidence` returns
    /// 0 (low), 1 (medium) or 2 (high). `width` and `height` are the depth map's size in pixels.
    func find(width: Int, height: Int, depth: (_ x: Int, _ y: Int) -> Float,
              confidence: (_ x: Int, _ y: Int) -> UInt8,
              anchor: ScreenAnchor, geometry: FrameGeometry) -> Result? {
        // Region of the depth map to scan: the anchored screen as it appears now, plus a margin.
        let corners = anchor.corners.compactMap { geometry.project($0) }
        guard corners.count == 4 else { return nil }
        let margin: CGFloat = 0.06
        let minX = max(0, Int(((corners.map(\.x).min() ?? 0) - margin) * CGFloat(width)))
        let maxX = min(width - 1, Int(((corners.map(\.x).max() ?? 1) + margin) * CGFloat(width)))
        let minY = max(0, Int(((corners.map(\.y).min() ?? 0) - margin) * CGFloat(height)))
        let maxY = min(height - 1, Int(((corners.map(\.y).max() ?? 1) + margin) * CGFloat(height)))
        guard maxX - minX >= 8, maxY - minY >= 8 else { return nil }
        let regionWidth = maxX - minX + 1
        let regionHeight = maxY - minY + 1

        // One matrix takes a point in camera space straight to (across, down, height) on the screen.
        let rotation = simd_float3x3(columns: (simd_make_float3(geometry.cameraTransform.columns.0),
                                               simd_make_float3(geometry.cameraTransform.columns.1),
                                               simd_make_float3(geometry.cameraTransform.columns.2)))
        let toScreen = simd_float3x3(rows: [anchor.xAxis / anchor.width,
                                            anchor.yAxis / anchor.height,
                                            anchor.normal])
        let combined = toScreen * rotation
        let offset = toScreen * (geometry.cameraPosition - anchor.origin)
        let scaleX = Float(geometry.imageSize.width) / Float(width)
        let scaleY = Float(geometry.imageSize.height) / Float(height)

        let count = regionWidth * regionHeight
        var across = [Float](repeating: .nan, count: count)
        var down = [Float](repeating: .nan, count: count)
        var above = [Float](repeating: .nan, count: count)
        var trusted = [Bool](repeating: false, count: count)
        var screenHeights: [Float] = []
        screenHeights.reserveCapacity(count / 2)

        for y in minY...maxY {
            let imageY = (Float(y) + 0.5) * scaleY
            for x in minX...maxX {
                let d = depth(x, y)
                guard d.isFinite, d > 0.08, d < 1.5 else { continue }
                let imageX = (Float(x) + 0.5) * scaleX
                let camera = simd_float3((imageX - geometry.cx) / geometry.fx * d,
                                         -(imageY - geometry.cy) / geometry.fy * d,
                                         -d)
                let p = combined * camera + offset
                guard p.x > -0.1, p.x < 1.1, p.y > -0.1, p.y < 1.1 else { continue }
                let index = (y - minY) * regionWidth + (x - minX)
                across[index] = p.x
                down[index] = p.y
                above[index] = p.z
                trusted[index] = confidence(x, y) >= 1
                if abs(p.z) < 0.03, p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 { screenHeights.append(p.z) }
            }
        }

        // Where LiDAR places the bare screen relative to the anchored plane in this frame.
        // Measuring the hand against that removes any disagreement between the two.
        var surface: Float = 0
        if screenHeights.count >= 40 {
            screenHeights.sort()
            surface = screenHeights[screenHeights.count / 2]
        }

        // Hand = trusted samples clearly in front of the screen...
        var isHand = [Bool](repeating: false, count: count)
        for index in 0..<count where trusted[index] {
            let h = above[index] - surface
            if h > minimumHeight, h < maximumHeight { isHand[index] = true }
        }
        // ...that are surrounded by other hand samples. This drops the ragged ring of mixed
        // readings around the hand's outline, which otherwise look like "nearest to the glass".
        var interior: [Int] = []
        for y in 1..<(regionHeight - 1) {
            for x in 1..<(regionWidth - 1) {
                let index = y * regionWidth + x
                guard isHand[index] else { continue }
                var neighbours = 0
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        if isHand[index + dy * regionWidth + dx] { neighbours += 1 }
                    }
                }
                if neighbours >= 6 { interior.append(index) }
            }
        }
        guard interior.count >= 20 else { return nil }

        // The nearest-to-glass slice of the hand.
        interior.sort { above[$0] < above[$1] }
        let take = min(max(interior.count * 8 / 100, 6), 40)
        var lowest = Array(interior.prefix(take))

        // Keep the samples that sit together; a stray low sample elsewhere must not drag the point away.
        let xs = lowest.map { $0 % regionWidth }.sorted()
        let ys = lowest.map { $0 / regionWidth }.sorted()
        let medianX = xs[xs.count / 2]
        let medianY = ys[ys.count / 2]
        lowest = lowest.filter { abs($0 % regionWidth - medianX) <= 8 && abs($0 / regionWidth - medianY) <= 8 }
        guard lowest.count >= 4 else { return nil }

        var sumAcross: Float = 0, sumDown: Float = 0, sumAbove: Float = 0, sumX: Float = 0, sumY: Float = 0
        for index in lowest {
            sumAcross += across[index]
            sumDown += down[index]
            sumAbove += above[index] - surface
            sumX += Float(index % regionWidth + minX) + 0.5
            sumY += Float(index / regionWidth + minY) + 0.5
        }
        let n = Float(lowest.count)
        return Result(uv: CGPoint(x: CGFloat(sumAcross / n), y: CGFloat(sumDown / n)),
                      height: sumAbove / n,
                      imagePoint: CGPoint(x: CGFloat(sumX / n) / CGFloat(width), y: CGFloat(sumY / n) / CGFloat(height)),
                      sampleCount: interior.count)
    }
}
