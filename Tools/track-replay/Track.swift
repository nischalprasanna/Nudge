import CoreGraphics
import Foundation
import ImageIO
import simd

/// One recorded frame from the phone.
struct Record {
    var info: [String: Any]
    var jpeg: Data
    var depth: [Float]
    var confidence: [UInt8]
    var depthWidth: Int
    var depthHeight: Int

    var time: Double { info["time"] as? Double ?? 0 }
    func point(_ key: String) -> CGPoint? {
        guard let a = info[key] as? [Double], a.count == 2 else { return nil }
        return CGPoint(x: a[0], y: a[1])
    }
    var image: CGImage? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    var geometry: FrameGeometry {
        let k = (info["intrinsics"] as? [Double] ?? []).map { Float($0) }
        let size = info["imageSize"] as? [Double] ?? [1920, 1440]
        let c = (info["camera"] as? [Double] ?? []).map { Float($0) }
        let t = simd_float4x4(columns: (SIMD4(c[0], c[1], c[2], c[3]), SIMD4(c[4], c[5], c[6], c[7]),
                                        SIMD4(c[8], c[9], c[10], c[11]), SIMD4(c[12], c[13], c[14], c[15])))
        let intr = simd_float3x3(columns: (SIMD3(k[0], 0, 0), SIMD3(0, k[1], 0), SIMD3(k[2], k[3], 1)))
        return FrameGeometry(cameraTransform: t, intrinsics: intr, imageSize: CGSize(width: size[0], height: size[1]))
    }
    var anchor: ScreenAnchor? {
        let a = (info["anchor"] as? [Double] ?? []).map { Float($0) }
        guard a.count == 12 else { return nil }
        return ScreenAnchor(topLeft: SIMD3(a[0], a[1], a[2]), topRight: SIMD3(a[3], a[4], a[5]),
                            bottomRight: SIMD3(a[6], a[7], a[8]), bottomLeft: SIMD3(a[9], a[10], a[11]),
                            cameraPosition: geometry.cameraPosition, createdAt: 0)
    }
    /// Depth at a raw image point: the given percentile of a small window, as on the phone.
    func depthAt(_ p: CGPoint, radius: Int = 1, percentile: Float = 0.25) -> Float? {
        guard depthWidth > 0 else { return nil }
        let cx = Int(p.x * CGFloat(depthWidth)), cy = Int(p.y * CGFloat(depthHeight))
        guard cx >= 0, cx < depthWidth, cy >= 0, cy < depthHeight else { return nil }
        var samples: [Float] = []
        for y in max(0, cy - radius)...min(depthHeight - 1, cy + radius) {
            for x in max(0, cx - radius)...min(depthWidth - 1, cx + radius) {
                let d = depth[y * depthWidth + x]
                if d.isFinite, d > 0.05, d < 3 { samples.append(d) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[min(samples.count - 1, Int(Float(samples.count - 1) * percentile))]
    }
}

func loadTrack(_ path: String) -> [Record] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    var out: [Record] = []
    var at = 0
    func u32(_ o: Int) -> Int { Int(data.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
    while at + 24 <= data.count {
        guard String(data: data.subdata(in: at..<at + 4), encoding: .utf8) == "NTRK" else { break }
        let jsonLen = u32(at + 4), jpegLen = u32(at + 8), dw = u32(at + 12), dh = u32(at + 16), confLen = u32(at + 20)
        var p = at + 24
        guard p + jsonLen + jpegLen + dw * dh * 4 + confLen <= data.count else { break }
        let json = data.subdata(in: p..<p + jsonLen); p += jsonLen
        let jpeg = data.subdata(in: p..<p + jpegLen); p += jpegLen
        let depthData = data.subdata(in: p..<p + dw * dh * 4); p += dw * dh * 4
        let conf = [UInt8](data.subdata(in: p..<p + confLen)); p += confLen
        let depth = depthData.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        let info = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        out.append(Record(info: info, jpeg: jpeg, depth: depth, confidence: conf, depthWidth: dw, depthHeight: dh))
        at = p
    }
    return out
}
