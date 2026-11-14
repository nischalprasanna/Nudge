import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

// depthview <track.bin> <out.jpg> <frame> <frame> ...
let args = CommandLine.arguments
let records = loadTrack(args[1])
let picks = args[3...].compactMap { Int($0) }
var tiles: [CGImage] = []
for i in picks {
    let r = records[i]
    guard let image = r.image, let anchor = r.anchor else { continue }
    let g = r.geometry
    let dw = r.depthWidth, dh = r.depthHeight
    // Upright tile: width dh, height dw (rotated 90 degrees clockwise), scaled x3.
    let s = 3
    let W = dh * s, H = dw * s
    func ctxMake() -> CGContext { CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)! }
    let photo = ctxMake()
    photo.saveGState(); photo.scaleBy(x: CGFloat(W) / CGFloat(image.height), y: CGFloat(H) / CGFloat(image.width))
    photo.translateBy(x: 0, y: CGFloat(image.width)); photo.rotate(by: -.pi / 2)
    photo.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); photo.restoreGState()
    let map = ctxMake()
    var hist: [Float] = []
    for y in 0..<dh { for x in 0..<dw {
        let d = r.depth[y * dw + x]
        let raw = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(dw), y: (CGFloat(y) + 0.5) / CGFloat(dh))
        var color = CGColor(red: 0.2, green: 0, blue: 0.2, alpha: 1)
        if d.isFinite, d > 0.05, d < 3 {
            let located = anchor.locate(g.unproject(raw: raw, depth: d))
            let h = located.height
            let inside = (-0.3...1.3).contains(located.uv.x) && (-0.3...1.6).contains(located.uv.y)
            if (0...1).contains(located.uv.x), (0...1).contains(located.uv.y) { hist.append(h) }
            // blue below plane, black at plane, green to yellow to red as it rises to 8 cm
            let t = CGFloat(max(-0.03, min(0.08, h)))
            if t < 0 { color = CGColor(red: 0, green: 0, blue: -t / 0.03, alpha: 1) }
            else { color = CGColor(red: min(1, t / 0.04), green: min(1, t / 0.015) * (inside ? 1 : 0.5), blue: 0, alpha: 1) }
            let c = r.confidence.isEmpty ? 2 : r.confidence[y * dw + x]
            if c == 0 { color = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1) }
        }
        let p = FrameGeometry.portrait(fromRaw: raw)
        map.setFillColor(color)
        map.fill(CGRect(x: p.x * CGFloat(W) - CGFloat(s) / 2, y: (1 - p.y) * CGFloat(H) - CGFloat(s) / 2, width: CGFloat(s), height: CGFloat(s)))
    } }
    hist.sort()
    if !hist.isEmpty { print(i, "heights on screen: p10 \(hist[hist.count / 10]) p50 \(hist[hist.count / 2]) p90 \(hist[hist.count * 9 / 10])", "conf0:", r.confidence.filter { $0 == 0 }.count, "conf1:", r.confidence.filter { $0 == 1 }.count) }
    for c in [photo, map] {
        let corners = anchor.corners.compactMap { g.project($0) }.map { FrameGeometry.portrait(fromRaw: $0) }.map { CGPoint(x: $0.x * CGFloat(W), y: (1 - $0.y) * CGFloat(H)) }
        c.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); c.setLineWidth(1.5)
        c.addLines(between: corners + [corners[0]]); c.strokePath()
        if let tip = r.point("tip") { let p = FrameGeometry.portrait(fromRaw: tip); c.strokeEllipse(in: CGRect(x: p.x * CGFloat(W) - 6, y: (1 - p.y) * CGFloat(H) - 6, width: 12, height: 12)) }
        tiles.append(c.makeImage()!)
    }
}
let tw = tiles[0].width, th = tiles[0].height, cols = min(tiles.count, 8), rows = (tiles.count + cols - 1) / cols
let ctx = CGContext(data: nil, width: cols * (tw + 6), height: rows * (th + 6), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
for (i, t) in tiles.enumerated() { ctx.draw(t, in: CGRect(x: (i % cols) * (tw + 6), y: (rows - 1 - i / cols) * (th + 6), width: tw, height: th)) }
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
CGImageDestinationFinalize(dest)
