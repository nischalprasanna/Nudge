import CoreGraphics
import Foundation
import simd

// Synthetic scene: a 10 x 20 cm screen, a camera about 40 cm away, and a finger reaching in
// from the bottom whose tip sits at 50% across, 60% down, with its top surface 1.5 cm above the glass.
func rotationX(_ a: Float) -> simd_float4x4 {
    simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, cos(a), -sin(a), 0), SIMD4(0, sin(a), cos(a), 0), SIMD4(0, 0, 0, 1)])
}
func rotationY(_ a: Float) -> simd_float4x4 {
    simd_float4x4(rows: [SIMD4(cos(a), 0, sin(a), 0), SIMD4(0, 1, 0, 0), SIMD4(-sin(a), 0, cos(a), 0), SIMD4(0, 0, 0, 1)])
}
func translation(_ t: simd_float3) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
    return m
}

struct Scene {
    var camera: simd_float4x4
    var anchorShift: Float      // how far the anchored plane sits in front of the real glass (metres)
    var noise: Float
    var tipV: Float = 0.6
    var tipHeight: Float = 0.015
    /// A laptop base or shelf sticking out from the bottom edge of the screen.
    var shelf = false
    /// Where the camera's hand tracker "sees" a hand, in screen fractions (u0, v0, u1, v1). Nil: no limit.
    var handSeen: (Float, Float, Float, Float)? = nil
    var expectHand = true
    var name: String
}

let screenCenter = simd_float3(0, 0, -0.4)
let trueNormal = simd_float3(0, 0, 1)
let xAxis = simd_float3(1, 0, 0), yAxis = simd_float3(0, -1, 0)
let screenW: Float = 0.10, screenH: Float = 0.20
let origin = screenCenter - xAxis * screenW / 2 - yAxis * screenH / 2

func fingerHeight(u: Float, v: Float, scene: Scene) -> Float? {
    guard abs(u - 0.5) < 0.08, v >= scene.tipV else { return nil }
    return scene.tipHeight + (v - scene.tipV) * screenH * 0.7
}

func run(_ scene: Scene) {
    let intrinsics = simd_float3x3(columns: (SIMD3(1450, 0, 0), SIMD3(0, 1450, 0), SIMD3(960, 720, 1)))
    let geometry = FrameGeometry(cameraTransform: scene.camera, intrinsics: intrinsics, imageSize: CGSize(width: 1920, height: 1440))
    let shift = trueNormal * scene.anchorShift
    guard let anchor = ScreenAnchor(topLeft: origin + shift, topRight: origin + xAxis * screenW + shift,
                                    bottomRight: origin + xAxis * screenW + yAxis * screenH + shift,
                                    bottomLeft: origin + yAxis * screenH + shift,
                                    cameraPosition: geometry.cameraPosition, createdAt: 0) else { print("anchor failed"); return }
    let w = 256, h = 192
    var depth = [Float](repeating: 0, count: w * h)
    var conf = [UInt8](repeating: 2, count: w * h)
    var generator = SystemRandomNumberGenerator()
    let camPos = geometry.cameraPosition
    let forward = -simd_make_float3(scene.camera.columns.2)
    for y in 0..<h {
        for x in 0..<w {
            let raw = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(w), y: (CGFloat(y) + 0.5) / CGFloat(h))
            let ray = geometry.ray(throughRaw: raw)
            // Hit on the real glass.
            let denom = simd_dot(ray.direction, trueNormal)
            guard abs(denom) > 1e-5 else { continue }
            var t = simd_dot(screenCenter - ray.origin, trueNormal) / denom
            guard t > 0 else { continue }
            // March along the ray toward the glass; stop at the first point inside the finger.
            let glassT = t
            var step = max(glassT - 0.30, 0.02)
            while step < glassT {
                let p = ray.origin + ray.direction * step
                let d = p - origin
                let u = simd_dot(d, xAxis) / screenW, v = simd_dot(d, yAxis) / screenH
                let height = simd_dot(p - screenCenter, trueNormal)
                if let fh = fingerHeight(u: u, v: v, scene: scene), height <= fh, height >= fh - 0.014 { t = step; break }
                if scene.shelf, v >= 1.0, v <= 1.08, u > -0.3, u < 1.3, height >= 0, height <= 0.2 { t = step; break }
                step += 0.0007
            }
            let point = ray.origin + ray.direction * t
            let z = simd_dot(point - camPos, forward)
            let jitter = Float.random(in: -scene.noise...scene.noise, using: &generator)
            depth[y * w + x] = z + jitter
            _ = conf
        }
    }
    // Mark the finger's silhouette as low confidence with in-between depths, as real LiDAR does.
    var edged = depth
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let c = depth[y * w + x]
            let neighbours = [depth[y * w + x - 1], depth[y * w + x + 1], depth[(y - 1) * w + x], depth[(y + 1) * w + x]]
            if let far = neighbours.max(), far - c > 0.01 || c - (neighbours.min() ?? c) > 0.01 {
                conf[y * w + x] = 0
                edged[y * w + x] = (c + far) / 2
            }
        }
    }
    // The hand tracker's box, turned from screen fractions into image coordinates.
    var searchBox: CGRect?
    if let seen = scene.handSeen {
        let cornersUV = [(seen.0, seen.1), (seen.2, seen.1), (seen.2, seen.3), (seen.0, seen.3)]
        let points = cornersUV.compactMap { uv in
            geometry.project(origin + xAxis * screenW * uv.0 + yAxis * screenH * uv.1 + trueNormal * 0.03)
        }
        if points.count == 4 {
            let xs = points.map(\.x), ys = points.map(\.y)
            searchBox = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }
    let finder = DepthHandFinder()
    let start = Date()
    var result: DepthHandFinder.Result?
    for _ in 0..<50 {
        result = finder.find(width: w, height: h, depth: { x, y in edged[y * w + x] }, confidence: { x, y in conf[y * w + x] },
                             anchor: anchor, geometry: geometry, searchBox: searchBox)
    }
    let ms = Date().timeIntervalSince(start) * 1000 / 50
    let verdict = (result != nil) == scene.expectHand ? "ok  " : "FAIL"
    print(verdict, terminator: " ")
    if let r = result {
        print(String(format: "%@: across %.2f (want 0.50)  down %.2f (want ~%.2f)  height %.1f mm (want ~%.0f)  samples %d  %.2f ms",
                     scene.name, r.uv.x, r.uv.y, scene.tipV + 0.03, r.height * 1000, scene.tipHeight * 1000 + 3, r.sampleCount, ms))
    } else {
        print("\(scene.name): no hand found  (\(String(format: "%.2f", ms)) ms)")
    }
}

run(Scene(camera: matrix_identity_float4x4, anchorShift: 0, noise: 0, name: "straight on, perfect"))
run(Scene(camera: matrix_identity_float4x4, anchorShift: 0, noise: 0.004, name: "straight on, 4 mm noise"))
run(Scene(camera: matrix_identity_float4x4, anchorShift: 0.02, noise: 0.004, name: "anchor 2 cm off, noise"))
let tilted = translation(SIMD3(0.08, 0.15, 0.02)) * rotationY(0.18) * rotationX(-0.35)
run(Scene(camera: tilted, anchorShift: 0, noise: 0.004, name: "camera up and to the side"))
run(Scene(camera: tilted, anchorShift: -0.015, noise: 0.004, name: "tilted, anchor 1.5 cm behind"))
run(Scene(camera: tilted, anchorShift: 0, noise: 0.004, tipHeight: 0.06, name: "tilted, finger 6 cm up"))
run(Scene(camera: matrix_identity_float4x4, anchorShift: 0, noise: 0.004, tipV: 5, expectHand: false, name: "no hand at all"))
run(Scene(camera: tilted, anchorShift: 0, noise: 0.004, tipV: 5, shelf: true, expectHand: false, name: "laptop base, no hand"))
run(Scene(camera: tilted, anchorShift: 0, noise: 0.004, shelf: true, handSeen: (0.3, 0.5, 0.7, 1.0), name: "laptop base, hand seen by camera"))
run(Scene(camera: tilted, anchorShift: 0, noise: 0.004, shelf: true, handSeen: (0.0, 0.0, 0.3, 0.3), expectHand: false, name: "laptop base, camera sees hand elsewhere"))
