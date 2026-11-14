import ARKit

extension DepthHandFinder {
    /// Runs the finder on one frame of LiDAR depth.
    func find(depthData: ARDepthData, anchor: ScreenAnchor, geometry: FrameGeometry, searchBox: CGRect?) -> Result? {
        let map = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceRowBytes = 0
        let confidenceMap = depthData.confidenceMap
        if let confidenceMap,
           CVPixelBufferGetWidth(confidenceMap) == width, CVPixelBufferGetHeight(confidenceMap) == height {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap)
            confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if let confidenceMap, confidenceBase != nil { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        return find(width: width, height: height,
                    depth: { x, y in
                        base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)[x]
                    },
                    confidence: { x, y in
                        guard let confidenceBase else { return 2 }
                        return confidenceBase.advanced(by: y * confidenceRowBytes).assumingMemoryBound(to: UInt8.self)[x]
                    },
                    anchor: anchor, geometry: geometry, searchBox: searchBox)
    }
}
