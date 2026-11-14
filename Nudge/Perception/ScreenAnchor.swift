import CoreGraphics
import Foundation
import simd

/// A touchscreen pinned as a fixed rectangle in ARKit world space, so button positions
/// stay correct while the phone moves.
///
/// Screen coordinates: `u` runs left to right and `v` runs top to bottom, both 0...1,
/// as the user saw the screen when it was anchored.
struct ScreenAnchor {
    /// World position of the top-left corner.
    let origin: simd_float3
    /// Unit vector along the screen, left to right.
    let xAxis: simd_float3
    /// Unit vector along the screen, top to bottom.
    let yAxis: simd_float3
    /// Unit vector out of the glass, toward the user.
    let normal: simd_float3
    /// Physical size in metres.
    let width: Float
    let height: Float
    let createdAt: TimeInterval

    /// Builds a clean rectangle from four measured corners, which are never perfectly
    /// coplanar or square. Returns nil if the result is not a plausible screen.
    init?(topLeft: simd_float3, topRight: simd_float3, bottomRight: simd_float3, bottomLeft: simd_float3,
          cameraPosition: simd_float3, createdAt: TimeInterval) {
        let center = (topLeft + topRight + bottomRight + bottomLeft) / 4
        let across = ((topRight - topLeft) + (bottomRight - bottomLeft)) / 2
        let down = ((bottomLeft - topLeft) + (bottomRight - topRight)) / 2
        guard simd_length(across) > 0.001, simd_length(down) > 0.001 else { return nil }

        let x = simd_normalize(across)
        // Remove any component of "down" that leans along x, so the axes are square.
        let downSquare = down - simd_dot(down, x) * x
        guard simd_length(downSquare) > 0.001 else { return nil }
        let y = simd_normalize(downSquare)

        var n = simd_normalize(simd_cross(x, y))
        if simd_dot(n, cameraPosition - center) < 0 { n = -n }

        let w = simd_length(across)
        let h = simd_length(downSquare)
        // Reject anything that is not roughly appliance-screen sized (3 cm to 1.5 m).
        guard (0.03...1.5).contains(w), (0.03...1.5).contains(h) else { return nil }

        self.origin = center - x * (w / 2) - y * (h / 2)
        self.xAxis = x
        self.yAxis = y
        self.normal = n
        self.width = w
        self.height = h
        self.createdAt = createdAt
    }

    var aspectRatio: Double { Double(width / height) }

    /// World corners in the order top-left, top-right, bottom-right, bottom-left.
    var corners: [simd_float3] {
        [world(u: 0, v: 0), world(u: 1, v: 0), world(u: 1, v: 1), world(u: 0, v: 1)]
    }

    /// World position of a normalized screen point.
    func world(u: Float, v: Float) -> simd_float3 {
        origin + xAxis * (u * width) + yAxis * (v * height)
    }

    /// Drops a world point straight down onto the glass.
    /// Returns where it lands (normalized) and its height above the glass in metres.
    func locate(_ point: simd_float3) -> (uv: CGPoint, height: Float) {
        let d = point - origin
        let u = simd_dot(d, xAxis) / width
        let v = simd_dot(d, yAxis) / height
        return (CGPoint(x: CGFloat(u), y: CGFloat(v)), simd_dot(d, normal))
    }

    /// Where a ray hits the screen plane, or nil if it runs parallel or points away.
    func intersect(rayOrigin: simd_float3, direction: simd_float3) -> simd_float3? {
        let denom = simd_dot(direction, normal)
        guard abs(denom) > 1e-5 else { return nil }
        let t = simd_dot(origin - rayOrigin, normal) / denom
        guard t > 0 else { return nil }
        return rayOrigin + direction * t
    }
}
