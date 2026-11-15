import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

// fingertest <track.bin> <outdir> [tipInset] [chromaTol] [brightTol]
let args = CommandLine.arguments
let records = loadTrack(args[1])
let outDir = args[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var finder = DepthFingerFinder()
if args.count > 3 { finder.registrationShift = Float(args[3])! }
if args.count > 4 { finder.maximumDoubtful = Float(args[4])! }
let useConfidence = ProcessInfo.processInfo.environment["NOCONF"] == nil

struct Pixels {
    let width: Int, height: Int
    var data: [UInt8]
    init?(_ image: CGImage) {
        width = image.width; height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    /// Brightness and colour differences, as the phone's camera buffer holds them.
    func ycc(_ p: CGPoint) -> SIMD3<Float>? {
        let x = Int(p.x * CGFloat(width)), y = Int(p.y * CGFloat(height))
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let i = (y * width + x) * 4
        let r = Float(data[i]), g = Float(data[i + 1]), b = Float(data[i + 2])
        return SIMD3(0.299 * r + 0.587 * g + 0.114 * b, 128 - 0.168736 * r - 0.331264 * g + 0.5 * b, 128 + 0.5 * r - 0.418688 * g - 0.081312 * b)
    }
}

func tile(_ record: Record, _ image: CGImage, vision: CGPoint?, found: DepthFingerFinder.Result?) -> CGImage? {
    let scale: CGFloat = 0.3
    let w = Int(CGFloat(image.height) * scale), h = Int(CGFloat(image.width) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.saveGState(); ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: 0, y: CGFloat(image.width)); ctx.rotate(by: -.pi / 2)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); ctx.restoreGState()
    func place(_ raw: CGPoint) -> CGPoint { let p = FrameGeometry.portrait(fromRaw: raw); return CGPoint(x: p.x * CGFloat(w), y: (1 - p.y) * CGFloat(h)) }
    let g = record.geometry
    if let anchor = record.anchor {
        let corners = anchor.corners.compactMap { g.project($0) }.map(place)
        if corners.count == 4 { ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 1)); ctx.setLineWidth(1); ctx.addLines(between: corners + [corners[0]]); ctx.strokePath() }
    }
    if let vision { let c = place(vision); ctx.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1)); ctx.setLineWidth(2); ctx.strokeEllipse(in: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)) }
    if let found {
        let e = place(found.ridgeEnd); ctx.setFillColor(CGColor(red: 0, green: 1, blue: 1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: e.x - 3, y: e.y - 3, width: 6, height: 6))
        let c = place(found.imagePoint); ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
    }
    return ctx.makeImage()
}
func save(_ image: CGImage, _ path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary); CGImageDestinationFinalize(dest)
}
func sheets(_ tiles: [CGImage], _ name: String) {
    var index = 0
    for start in stride(from: 0, to: tiles.count, by: 24) {
        let part = Array(tiles[start..<min(tiles.count, start + 24)])
        let tw = part[0].width, th = part[0].height, cols = 8, rows = (part.count + cols - 1) / cols
        guard let ctx = CGContext(data: nil, width: cols * (tw + 6), height: rows * (th + 6), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
        for (i, t) in part.enumerated() { ctx.draw(t, in: CGRect(x: (i % cols) * (tw + 6), y: (rows - 1 - i / cols) * (th + 6), width: tw, height: th)) }
        if let image = ctx.makeImage() { save(image, "\(outDir)/\(name)_\(String(format: "%02d", index)).jpg") }
        index += 1
    }
}

var errors: [Float] = [], alongs: [Float] = [], sides: [Float] = [], extended: [Float] = []
var both = 0, visionOnly = 0, finderOnly = 0, neither = 0
var finderOnlyTiles: [CGImage] = [], worstTiles: [CGImage] = [], bothTiles: [CGImage] = [], visionOnlyTiles: [CGImage] = []
var finderOnlyFrames: [Int] = [], worstFrames: [Int] = []
var csv = ["i,along,across,dxmm,dymm,hover,phoneHover,du,dv,samples,method"]
var previous: (time: Double, at: simd_float2)?
var seq: [(Int, Double, simd_float2, simd_float2, simd_float2, simd_float2)] = []
func glassOffset(_ f: DepthFingerFinder.Result, _ anchor: ScreenAnchor) -> Float { f.glass }
var withheld = 0
var doubt: [(Int, Float, Bool)] = []
let gate = ProcessInfo.processInfo.environment["NOGATE"] == nil
var lastTime = -10.0
var lastTarget = CGPoint(x: -1, y: -1)
var elapsed = 0.0
for (i, record) in records.enumerated() {
    guard let image = record.image, let anchor = record.anchor, let pixels = Pixels(image) else { continue }
    let g = record.geometry
    let target = record.point("target") ?? .zero
    let newStretch = record.time - lastTime > 0.8 || abs(target.x - lastTarget.x) + abs(target.y - lastTarget.y) > 0.01
    lastTime = record.time; lastTarget = target
    let vision = record.point("tip")
    let confidenceCopy = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, record.confidence.count))
    confidenceCopy.initialize(from: record.confidence, count: record.confidence.count)
    defer { confidenceCopy.deallocate() }
    let confidencePointer = UnsafePointer(confidenceCopy)
    let foundNow: DepthFingerFinder.Result? = record.depth.withUnsafeBufferPointer { buffer in
        var depth = DepthFingerFinder.Depth(width: record.depthWidth, height: record.depthHeight, values: buffer.baseAddress!, rowLength: record.depthWidth)
        if useConfidence, record.confidence.count == record.depthWidth * record.depthHeight {
            depth.confidence = confidencePointer; depth.confidenceRowLength = record.depthWidth
        }
        // On the phone the surroundings are noted when the screen is read with no hand in view.
        // The start of each stretch of guidance stands in for that here.
        if newStretch, vision == nil { finder.learnBackground(depth, geometry: g, anchor: anchor) }
        let started = Date()
        let r = finder.find(depth, geometry: g, anchor: anchor)
        elapsed += Date().timeIntervalSince(started)
        return r
    }
    if let f = foundNow { doubt.append((i, f.doubtful, vision != nil)) }
    var found = foundNow
    let rawFound = foundNow
    if let f = found {
        let here = simd_float2(Float(f.uv.x) * anchor.width, Float(f.uv.y) * anchor.height)
        let steady = previous.map { record.time - $0.time < 0.25 && simd_distance($0.at, here) < 0.025 } ?? false
        previous = (record.time, here)
        if !steady, gate { found = nil; withheld += 1 }
    } else { previous = nil }
    _ = rawFound
    let t = tile(record, image, vision: vision, found: found)
    switch (vision, found) {
    case let (v?, f?):
        both += 1
        let dx = Float(f.imagePoint.x - v.x) * Float(g.imageSize.width), dy = Float(f.imagePoint.y - v.y) * Float(g.imageSize.height)
        let range = simd_length(anchor.world(u: 0.5, v: 0.5) - g.cameraPosition)
        let mmPerPixel = range / g.fx * 1000
        let e = (dx * dx + dy * dy).squareRoot() * mmPerPixel
        errors.append(e)
        if let j = record.point("joint") {
            var ax = Float(v.x - j.x) * Float(g.imageSize.width), ay = Float(v.y - j.y) * Float(g.imageSize.height)
            let n = (ax * ax + ay * ay).squareRoot()
            if n > 2 { ax /= n; ay /= n; alongs.append((dx * ax + dy * ay) * mmPerPixel); sides.append((-dx * ay + dy * ax) * mmPerPixel) }
        }
        // Hybrid: the tracker's point in the picture, raised to the height the ridge gives.
        let ray = g.ray(throughRaw: v)
        let lift = f.hover + finder.fingerThickness + glassOffset(f, anchor)
        var hybrid = simd_float2(.nan, .nan)
        let denom = simd_dot(ray.direction, anchor.normal)
        if abs(denom) > 1e-5 {
            let t = simd_dot(anchor.origin + anchor.normal * lift - ray.origin, anchor.normal) / denom
            let hit = ray.origin + ray.direction * t
            let l = anchor.locate(hit)
            hybrid = simd_float2(Float(l.uv.x) * anchor.width, Float(l.uv.y) * anchor.height) * 1000
        }
        let phoneUV = record.point("uv") ?? .zero
        seq.append((i, record.time, simd_float2(Float(v.x) * Float(g.imageSize.width), Float(v.y) * Float(g.imageSize.height)) * mmPerPixel,
                    simd_float2(Float(phoneUV.x) * anchor.width, Float(phoneUV.y) * anchor.height) * 1000,
                    simd_float2(Float(f.uv.x) * anchor.width, Float(f.uv.y) * anchor.height) * 1000, hybrid))
        var al: Float = .nan, sd: Float = .nan
        if !alongs.isEmpty, record.point("joint") != nil { al = alongs.last!; sd = sides.last! }
        csv.append(String(format: "%d,%.2f,%.2f,%.2f,%.2f,%.4f,%.4f,%.3f,%.3f,%d", i, al, sd, dx * mmPerPixel, dy * mmPerPixel, f.hover, (record.info["hover"] as? Double) ?? -1, (Float(f.uv.x) - Float(record.point("uv")?.x ?? 0)) * anchor.width * 1000, (Float(f.uv.y) - Float(record.point("uv")?.y ?? 0)) * anchor.height * 1000, f.samples) + "," + ((record.info["method"] as? String) ?? ""))
        if e > 12, let t { worstTiles.append(t); worstFrames.append(i) } else if i % 12 == 0, let t { bothTiles.append(t) }
    case (_?, nil): visionOnly += 1; if let t, visionOnlyTiles.count < 48 { visionOnlyTiles.append(t) }
    case (nil, _?): finderOnly += 1; if let t { finderOnlyTiles.append(t); finderOnlyFrames.append(i) }
    default: neither += 1
    }
}
func pct(_ v: [Float], _ f: Float) -> Float { let s = v.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int(Float(s.count - 1) * f))] }
print("frames \(records.count): both \(both), tracker only \(visionOnly), finder only \(finderOnly), neither \(neither); \(String(format: "%.2f", elapsed / Double(records.count) * 1000)) ms per frame")
print(String(format: "distance from tracker's tip (mm): median %.1f, 75%% %.1f, 90%% %.1f, 95%% %.1f, worst %.1f; over 12 mm: %d", pct(errors, 0.5), pct(errors, 0.75), pct(errors, 0.9), pct(errors, 0.95), errors.max() ?? .nan, errors.filter { $0 > 12 }.count))
print(String(format: "along the finger (mm, + is beyond the tracker's tip): 10%% %.1f, median %.1f, 90%% %.1f", pct(alongs, 0.1), pct(alongs, 0.5), pct(alongs, 0.9)))
print(String(format: "across the finger (mm): 10%% %.1f, median %.1f, 90%% %.1f", pct(sides, 0.1), pct(sides, 0.5), pct(sides, 0.9)))
print("doubtful share, frames 96-108:", doubt.filter { (96...108).contains($0.0) }.map { String(format: "%d:%.2f", $0.0, $0.1) }.joined(separator: " "))
let ds = doubt.map { $0.1 }
print(String(format: "doubtful share overall: median %.2f, 75%% %.2f, 90%% %.2f, 95%% %.2f, 99%% %.2f", pct(ds, 0.5), pct(ds, 0.75), pct(ds, 0.9), pct(ds, 0.95), pct(ds, 0.99)))
var out = ["i,t,imgx,imgy,phonex,phoney,finderx,findery,hybridx,hybridy"]
for e in seq { out.append(String(format: "%d,%.2f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", e.0, e.1, e.2.x, e.2.y, e.3.x, e.3.y, e.4.x, e.4.y, e.5.x, e.5.y)) }
try? out.joined(separator: "\n").write(toFile: "\(outDir)/seq.csv", atomically: true, encoding: .utf8)
print("withheld by the two-frames-agree rule: \(withheld)")
print("finder-only frames:", finderOnlyFrames.map(String.init).joined(separator: " "))
print("worst frames:", worstFrames.map(String.init).joined(separator: " "))
try? csv.joined(separator: "\n").write(toFile: "\(outDir)/both.csv", atomically: true, encoding: .utf8)
sheets(finderOnlyTiles, "finderonly"); sheets(worstTiles, "worst"); sheets(bothTiles, "both"); sheets(visionOnlyTiles, "trackeronly")
