import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import simd

// replay <track.bin> <outdir> [variant]
let args = CommandLine.arguments
let records = loadTrack(args[1])
let outDir = args[2]
let variant = args.count > 3 ? args[3] : "base"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
print("frames: \(records.count)")

struct Seen {
    var tip: CGPoint?            // raw coordinates
    var tipConfidence: Float = 0
    var joints: [(CGPoint, Float)] = []   // raw, confidence
    var hands = 0
}

let joints: [VNHumanHandPoseObservation.JointName] = [
    .wrist, .thumbTip, .thumbIP, .thumbMP, .thumbCMC, .indexTip, .indexDIP, .indexPIP, .indexMCP,
    .middleTip, .middleDIP, .middlePIP, .middleMCP, .ringTip, .ringDIP, .ringPIP, .ringMCP,
    .littleTip, .littleDIP, .littlePIP, .littleMCP]

/// Runs the hand tracker the way the phone does, optionally on part of the picture.
/// `roi` is in Vision's upright coordinates (origin bottom-left).
func handPose(_ image: CGImage, maxHands: Int = 1, roi: CGRect? = nil) -> Seen {
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = maxHands
    if let roi { request.regionOfInterest = roi }
    let handler = VNImageRequestHandler(cgImage: image, orientation: .right, options: [:])
    try? handler.perform([request])
    var seen = Seen()
    guard let results = request.results, let hand = results.first else { return seen }
    seen.hands = results.count
    func full(_ p: CGPoint) -> CGPoint {
        guard let roi else { return p }
        return CGPoint(x: roi.minX + p.x * roi.width, y: roi.minY + p.y * roi.height)
    }
    for name in joints {
        if let p = try? hand.recognizedPoint(name) {
            seen.joints.append((FrameGeometry.raw(fromVisionPortrait: full(p.location)), p.confidence))
        }
    }
    if let tip = try? hand.recognizedPoint(.indexTip), tip.confidence > 0.2 {
        seen.tip = FrameGeometry.raw(fromVisionPortrait: full(tip.location))
        seen.tipConfidence = tip.confidence
    }
    return seen
}

/// The upright picture, with extra canvas added on the right and bottom. `mode`: black or mirror.
func padded(_ image: CGImage, right: CGFloat, bottom: CGFloat, mode: String) -> (CGImage, CGSize)? {
    let w = image.height, h = image.width            // upright size
    let W = Int(CGFloat(w) * (1 + right)), H = Int(CGFloat(h) * (1 + bottom))
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    func drawUpright() {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.restoreGState()
    }
    // CG origin is bottom-left; the picture sits at the top-left of the canvas.
    let oy = CGFloat(H - h)
    if mode == "mirror" {
        for (fx, fy) in [(false, false), (true, false), (false, true), (true, true)] {
            ctx.saveGState()
            ctx.translateBy(x: fx ? CGFloat(2 * w) : 0, y: fy ? oy : oy)
            if fx { ctx.scaleBy(x: -1, y: 1) }
            if fy { ctx.translateBy(x: 0, y: 0); ctx.scaleBy(x: 1, y: -1) }
            drawUpright()
            ctx.restoreGState()
        }
    }
    ctx.saveGState(); ctx.translateBy(x: 0, y: oy); drawUpright(); ctx.restoreGState()
    guard let out = ctx.makeImage() else { return nil }
    return (out, CGSize(width: CGFloat(w) / CGFloat(W), height: CGFloat(h) / CGFloat(H)))
}

func handPosePadded(_ image: CGImage, right: CGFloat, bottom: CGFloat, mode: String) -> Seen {
    guard let (big, frac) = padded(image, right: right, bottom: bottom, mode: mode) else { return Seen() }
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 1
    try? VNImageRequestHandler(cgImage: big, orientation: .up, options: [:]).perform([request])
    var seen = Seen()
    guard let hand = request.results?.first else { return seen }
    seen.hands = 1
    // Vision: origin bottom-left of the big canvas. The picture is the top-left part.
    func raw(_ p: CGPoint) -> CGPoint {
        let x = p.x / frac.width, yTop = (1 - p.y) / frac.height
        return FrameGeometry.raw(fromPortrait: CGPoint(x: x, y: yTop))
    }
    for name in joints { if let p = try? hand.recognizedPoint(name) { seen.joints.append((raw(p.location), p.confidence)) } }
    if let tip = try? hand.recognizedPoint(.indexTip), tip.confidence > 0.2 {
        let r = raw(tip.location)
        if (0...1).contains(r.x), (0...1).contains(r.y) { seen.tip = r; seen.tipConfidence = tip.confidence }
    }
    return seen
}

func detect(_ record: Record, _ image: CGImage) -> Seen {
    switch variant {
    case "two": return handPose(image, maxHands: 2)
    case "black": return handPosePadded(image, right: 0.5, bottom: 0.5, mode: "black")
    case "mirror": return handPosePadded(image, right: 0.5, bottom: 0.5, mode: "mirror")
    case "roi":
        // The lower right two thirds of the upright picture (Vision: origin bottom-left).
        return handPose(image, roi: CGRect(x: 0.3, y: 0, width: 0.7, height: 0.7))
    case "roi2":
        return handPose(image, roi: CGRect(x: 0.15, y: 0, width: 0.85, height: 0.55))
    default: return handPose(image)
    }
}

/// Draws the upright picture with what was found on it.
func annotate(_ record: Record, _ image: CGImage, phone: CGPoint?, mac: Seen, label: String) -> CGImage? {
    let scale: CGFloat = 0.3
    let w = Int(CGFloat(image.height) * scale), h = Int(CGFloat(image.width) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: CGFloat(image.width))
    ctx.rotate(by: -.pi / 2)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.restoreGState()
    func place(_ raw: CGPoint) -> CGPoint {
        let p = FrameGeometry.portrait(fromRaw: raw)
        return CGPoint(x: p.x * CGFloat(w), y: (1 - p.y) * CGFloat(h))
    }
    func dot(_ raw: CGPoint, _ r: CGFloat, _ color: CGColor, fill: Bool = true) {
        let c = place(raw)
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        if fill { ctx.setFillColor(color); ctx.fillEllipse(in: rect) } else { ctx.setStrokeColor(color); ctx.setLineWidth(2); ctx.strokeEllipse(in: rect) }
    }
    let g = record.geometry
    if let anchor = record.anchor {
        let corners = anchor.corners.compactMap { g.project($0) }.map(place)
        if corners.count == 4 {
            ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 1)); ctx.setLineWidth(1.5)
            ctx.addLines(between: corners + [corners[0]]); ctx.strokePath()
        }
        if let t = record.point("target"), let raw = g.project(anchor.world(u: Float(t.x), v: Float(t.y))) {
            dot(raw, 4, CGColor(red: 1, green: 0.9, blue: 0, alpha: 1))
        }
    }
    for (p, c) in mac.joints where c > 0.2 { dot(p, 2, CGColor(red: 0.3, green: 0.7, blue: 1, alpha: 1)) }
    if let phone { dot(phone, 9, CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1), fill: false) }
    if let tip = mac.tip { dot(tip, 5, CGColor(red: 0.1, green: 1, blue: 0.2, alpha: 1)) }
    return ctx.makeImage()
}

func save(_ image: CGImage, _ path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

func sheet(_ tiles: [CGImage], columns: Int, _ path: String) {
    guard let first = tiles.first else { return }
    let tw = first.width, th = first.height, gap = 6
    let rows = (tiles.count + columns - 1) / columns
    guard let ctx = CGContext(data: nil, width: columns * (tw + gap), height: rows * (th + gap), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
    for (i, tile) in tiles.enumerated() {
        let col = i % columns, row = i / columns
        ctx.draw(tile, in: CGRect(x: col * (tw + gap), y: (rows - 1 - row) * (th + gap), width: tw, height: th))
    }
    if let image = ctx.makeImage() { save(image, path) }
}

var lines = ["i,time,phoneTip,phoneConf,macTip,macConf,jointsSeen,hands,targetX,targetY"]
var tiles: [CGImage] = []
var phoneFound = 0, macFound = 0, both = 0, handSeen = 0
var sheetIndex = 0
let start = records.first?.time ?? 0
for (i, record) in records.enumerated() {
    guard let image = record.image else { continue }
    let phoneTip = record.point("tip")
    let mac = detect(record, image)
    let strong = mac.joints.filter { $0.1 > 0.3 }.count
    if phoneTip != nil { phoneFound += 1 }
    if mac.tip != nil { macFound += 1 }
    if phoneTip != nil, mac.tip != nil { both += 1 }
    if strong >= 4 { handSeen += 1 }
    var target = CGPoint(x: -1, y: -1)
    if let anchor = record.anchor, let t = record.point("target"),
       let raw = record.geometry.project(anchor.world(u: Float(t.x), v: Float(t.y))) {
        target = FrameGeometry.portrait(fromRaw: raw)
    }
    lines.append(String(format: "%d,%.2f,%d,%.2f,%d,%.2f,%d,%d,%.2f,%.2f", i, record.time - start, phoneTip == nil ? 0 : 1,
                        record.info["tipConfidence"] as? Double ?? 0, mac.tip == nil ? 0 : 1, mac.tipConfidence, strong, mac.hands, target.x, target.y))
    if let tile = annotate(record, image, phone: phoneTip, mac: mac, label: "\(i)") { tiles.append(tile) }
    if tiles.count == 24 || i == records.count - 1 {
        sheet(tiles, columns: 8, "\(outDir)/sheet_\(String(format: "%02d", sheetIndex)).jpg")
        sheetIndex += 1
        tiles = []
    }
}
try? lines.joined(separator: "\n").write(toFile: "\(outDir)/frames.csv", atomically: true, encoding: .utf8)
print("variant \(variant): phone found tip in \(phoneFound), mac in \(macFound), both \(both), hand (4+ joints) in \(handSeen) of \(records.count)")
