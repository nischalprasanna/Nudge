import CoreGraphics
import simd

/// Camera maths for one AR frame. Copies what it needs so the ARFrame itself is not retained.
///
/// Three 2D coordinate spaces are used in the perception code:
/// - "raw": the camera image as delivered (landscape), normalized 0...1, origin top-left.
/// - "portrait": the same image turned upright for a phone held in portrait, normalized, origin top-left.
/// - "Vision portrait": what Vision returns for the upright image, normalized, origin bottom-left.
struct FrameGeometry {
    let cameraTransform: simd_float4x4
    let worldToCamera: simd_float4x4
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    /// Raw (landscape) image size in pixels.
    let imageSize: CGSize

    /// `intrinsics` is the 3x3 camera matrix for an image of `imageSize` pixels.
    init(cameraTransform: simd_float4x4, intrinsics: simd_float3x3, imageSize: CGSize) {
        self.cameraTransform = cameraTransform
        worldToCamera = cameraTransform.inverse
        fx = intrinsics[0][0]
        fy = intrinsics[1][1]
        cx = intrinsics[2][0]
        cy = intrinsics[2][1]
        self.imageSize = imageSize
    }

    var cameraPosition: simd_float3 { simd_make_float3(cameraTransform.columns.3) }

    /// Width divided by height of the upright (portrait) image.
    var portraitAspect: CGFloat { imageSize.height / imageSize.width }

    // MARK: 2D conversions (back camera, phone in portrait: upright image = raw turned 90 degrees clockwise)

    static func raw(fromPortrait p: CGPoint) -> CGPoint { CGPoint(x: p.y, y: 1 - p.x) }
    static func portrait(fromRaw p: CGPoint) -> CGPoint { CGPoint(x: 1 - p.y, y: p.x) }
    static func raw(fromVisionPortrait p: CGPoint) -> CGPoint {
        raw(fromPortrait: CGPoint(x: p.x, y: 1 - p.y))
    }

    // MARK: 2D <-> 3D

    /// World-space ray from the camera through a raw image point.
    func ray(throughRaw p: CGPoint) -> (origin: simd_float3, direction: simd_float3) {
        let px = Float(p.x) * Float(imageSize.width)
        let py = Float(p.y) * Float(imageSize.height)
        // ARKit camera space: x right, y up, z toward the viewer.
        let local = simd_float4((px - cx) / fx, -(py - cy) / fy, -1, 0)
        let world = simd_make_float3(cameraTransform * local)
        return (cameraPosition, simd_normalize(world))
    }

    /// World position of a raw image point at a given depth (metres along the camera axis).
    func unproject(raw p: CGPoint, depth: Float) -> simd_float3 {
        let px = Float(p.x) * Float(imageSize.width)
        let py = Float(p.y) * Float(imageSize.height)
        let local = simd_float4((px - cx) / fx * depth, -(py - cy) / fy * depth, -depth, 1)
        return simd_make_float3(cameraTransform * local)
    }

    /// Raw image point where a world position appears, or nil if it is behind the camera.
    func project(_ world: simd_float3) -> CGPoint? {
        let local = worldToCamera * simd_float4(world.x, world.y, world.z, 1)
        guard local.z < -0.01 else { return nil }
        let px = cx + fx * local.x / -local.z
        let py = cy - fy * local.y / -local.z
        return CGPoint(x: CGFloat(px) / imageSize.width, y: CGFloat(py) / imageSize.height)
    }
}
