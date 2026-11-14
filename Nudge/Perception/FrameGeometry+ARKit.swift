import ARKit
import CoreGraphics
import simd

extension FrameGeometry {
    init(frame: ARFrame) {
        self.init(cameraTransform: frame.camera.transform,
                  intrinsics: frame.camera.intrinsics,
                  imageSize: frame.camera.imageResolution)
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
