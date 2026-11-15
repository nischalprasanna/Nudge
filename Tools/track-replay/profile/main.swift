import CoreGraphics
import Foundation
import simd
// profile <track.bin> <frame>...   heights (mm above the glass) along the finger, from 40 mm behind the tracker's tip to 14 mm beyond
let args = CommandLine.arguments
let records = loadTrack(args[1])
for i in args[2...].compactMap({ Int($0) }) {
    let r = records[i]
    guard let anchor = r.anchor, let tip = r.point("tip"), let joint = r.point("joint") else { print(i, "no tip"); continue }
    let g = r.geometry
    var surface: [Float] = []
    for y in 0..<r.depthHeight { for x in 0..<r.depthWidth {
        let d = r.depth[y * r.depthWidth + x]; guard d > 0.08, d < 1.5 else { continue }
        let l = anchor.locate(g.unproject(raw: CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(r.depthWidth), y: (CGFloat(y) + 0.5) / CGFloat(r.depthHeight)), depth: d))
        if (0...1).contains(l.uv.x), (0...1).contains(l.uv.y), abs(l.height) < 0.015 { surface.append(l.height) }
    } }
    surface.sort(); let glass = surface.isEmpty ? 0 : surface[surface.count / 2]
    let w = Float(g.imageSize.width), h = Float(g.imageSize.height)
    var ax = Float(tip.x - joint.x) * w, ay = Float(tip.y - joint.y) * h
    let n = (ax * ax + ay * ay).squareRoot(); ax /= n; ay /= n
    let range = simd_length(anchor.world(u: 0.5, v: 0.5) - g.cameraPosition)
    let pxPerMM = g.fx / range / 1000
    var line = "frame \(i) hover \(r.info["hover"] ?? "-") method \(r.info["method"] ?? "-"): "
    for mm in stride(from: -40, through: 14, by: 3) {
        let p = CGPoint(x: tip.x + CGFloat(ax * Float(mm) * pxPerMM / w), y: tip.y + CGFloat(ay * Float(mm) * pxPerMM / h))
        // centre sample, no percentile
        let dx = Int(p.x * CGFloat(r.depthWidth)), dy = Int(p.y * CGFloat(r.depthHeight))
        guard dx >= 0, dx < r.depthWidth, dy >= 0, dy < r.depthHeight else { line += " --"; continue }
        let d = r.depth[dy * r.depthWidth + dx]
        let height = anchor.locate(g.unproject(raw: p, depth: d)).height - glass
        line += String(format: "%@%3.0f", mm == 0 ? " |" : " ", height * 1000)
        if mm == 0 { line += "|" }
    }
    print(line)
}
