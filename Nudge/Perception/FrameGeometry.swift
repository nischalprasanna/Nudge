import ARKit
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

    init(frame: ARFrame) {
        let camera = frame.camera
        cameraTransform = camera.transform
        worldToCamera = camera.transform.inverse
        let k = camera.intrinsics
        fx = k[0][0]
        fy = k[1][1]
        cx = k[2][0]
        cy = k[2][1]
        imageSize = camera.imageResolution
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

/// Reads LiDAR depth around an image point.
enum DepthSampler {
    /// Returns the depth in metres at the given percentile of trustworthy samples in a small
    /// window around a raw image point. A low percentile prefers the nearest surface, which is
    /// what you want for a fingertip in front of a screen. Nil when there is no usable depth.
    static func depth(in depthData: ARDepthData, atRaw p: CGPoint, radius: Int, percentile: Float,
                      minimumConfidence: UInt8 = 1) -> Float? {
        let map = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        let confidence = depthData.confidenceMap
        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceRowBytes = 0
        if let confidence,
           CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidence)
            confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer {
            if let confidence, confidenceBase != nil {
                CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            }
        }

        let centerX = Int(p.x * CGFloat(width))
        let centerY = Int(p.y * CGFloat(height))
        guard centerX >= 0, centerX < width, centerY >= 0, centerY < height else { return nil }

        var samples: [Float] = []
        samples.reserveCapacity((2 * radius + 1) * (2 * radius + 1))
        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?.advanced(by: y * confidenceRowBytes).assumingMemoryBound(to: UInt8.self)
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) {
                let d = row[x]
                guard d.isFinite, d > 0.05, d < 3 else { continue }
                // 0 = low, 1 = medium, 2 = high confidence.
                if let confidenceRow, confidenceRow[x] < minimumConfidence { continue }
                samples.append(d)
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        let index = Int((Float(samples.count - 1) * min(max(percentile, 0), 1)).rounded())
        return samples[index]
    }
}
