import ARKit
import Combine
import UIKit
import simd

/// Owns the AR session and turns camera frames into three things:
/// an anchored screen, a live fingertip position on that screen, and on-demand text readings.
///
/// Threading: ARKit delivers frames on `arQueue`. Vision work runs on `visionQueue`, and a frame
/// is dropped if the previous one is still being processed, so tracking never falls behind.
/// Text reading runs on its own queue so it never stalls fingertip tracking.
final class PerceptionPipeline: NSObject, ObservableObject, ARSessionDelegate {

    /// 2D points for drawing over the camera preview, in portrait image coordinates (origin top-left).
    struct Overlay: Equatable {
        var candidate: [CGPoint] = []
        var anchored: [CGPoint] = []
        var fingertip: CGPoint?
    }

    // MARK: Published state (main thread)

    @Published private(set) var status = "Starting camera"
    @Published private(set) var isAnchored = false
    @Published private(set) var finger: FingerState?
    @Published private(set) var reading: ScreenReading?
    @Published private(set) var rectifiedImage: UIImage?
    @Published private(set) var isReading = false
    @Published private(set) var overlay = Overlay()
    @Published private(set) var hasLiDAR = false
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var portraitAspect: CGFloat = 0.75
    @Published private(set) var screenSizeText = ""

    // MARK: Configuration

    let session = ARSession()

    /// Called on the vision queue for every processed frame (full rate). Guidance hooks in here.
    var onFinger: ((FingerState?) -> Void)?
    /// Anchor automatically once the same outline has been seen in several frames in a row.
    var autoAnchor = true
    /// LiDAR sees the back of the finger; the pad that touches the glass is about this much lower.
    var fingerThickness: Float = 0.012

    // MARK: Private state

    private let arQueue = DispatchQueue(label: "nudge.ar", qos: .userInteractive)
    private let visionQueue = DispatchQueue(label: "nudge.vision", qos: .userInteractive)
    private let ocrQueue = DispatchQueue(label: "nudge.ocr", qos: .userInitiated)

    private let detectors = FrameDetectors()
    private let reader = ScreenReader()

    /// Only touched on `arQueue`.
    private var busy = false

    // Everything below is only touched on `visionQueue`.
    private var anchor: ScreenAnchor?
    private var lastCandidate: ScreenCandidate?
    private var stableCount = 0
    private var frameIndex = 0
    private var wantsAnchorNow = false
    private var wantsReadFromNextFrame = false
    private var smoothedUV: simd_float2?
    private var smoothedHover: Float?
    private var lastFrameTime: TimeInterval?
    private var smoothedFPS: Double = 0
    private var lastPublishTime: TimeInterval = 0

    // MARK: Lifecycle

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            status = "This device does not support AR tracking"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal, .vertical]
        config.isAutoFocusEnabled = true
        let lidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if lidar { config.frameSemantics.insert(.sceneDepth) }
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
        hasLiDAR = lidar
        session.delegate = self
        session.delegateQueue = arQueue
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        status = "Point the phone at the touchscreen"
    }

    func stop() {
        session.pause()
    }

    // MARK: Commands (call from any thread)

    /// Anchor right now using the current outline, or the middle of the view if none is detected.
    func anchorNow() {
        visionQueue.async {
            self.anchor = nil
            self.wantsAnchorNow = true
        }
    }

    func clearAnchor() {
        visionQueue.async {
            self.anchor = nil
            self.lastCandidate = nil
            self.stableCount = 0
            self.resetSmoothing()
            DispatchQueue.main.async {
                self.isAnchored = false
                self.finger = nil
                self.reading = nil
                self.rectifiedImage = nil
                self.screenSizeText = ""
                self.status = "Point the phone at the touchscreen"
            }
        }
    }

    /// Re-read the anchored screen. Results arrive in `reading`.
    func readScreen() {
        visionQueue.async {
            guard self.anchor != nil else {
                self.publishStatus("Anchor the screen first")
                return
            }
            DispatchQueue.main.async { self.isReading = true }
            // A high-resolution still gives much sharper small labels than a video frame.
            self.session.captureHighResolutionFrame { frame, _ in
                self.visionQueue.async {
                    if let frame {
                        self.performRead(frame: frame)
                    } else {
                        self.wantsReadFromNextFrame = true
                    }
                }
            }
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !busy else { return }
        busy = true
        visionQueue.async { [weak self] in
            self?.process(frame)
            self?.arQueue.async { self?.busy = false }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            break
        case .notAvailable:
            publishStatus("Tracking not available")
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: publishStatus("Moving too fast. Hold the phone steadier.")
            case .insufficientFeatures: publishStatus("Too dark or too plain. Add light or move back a little.")
            case .initializing, .relocalizing: break
            @unknown default: break
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        publishStatus("Camera error: \(error.localizedDescription)")
    }

    // MARK: Per-frame processing (visionQueue)

    private func process(_ frame: ARFrame) {
        frameIndex += 1
        let geometry = FrameGeometry(frame: frame)

        if let last = lastFrameTime, frame.timestamp > last {
            let instant = 1 / (frame.timestamp - last)
            smoothedFPS = smoothedFPS == 0 ? instant : smoothedFPS * 0.9 + instant * 0.1
        }
        lastFrameTime = frame.timestamp

        let lookForScreen = anchor == nil && (wantsAnchorNow || frameIndex % 3 == 0)
        let detection = detectors.detect(pixelBuffer: frame.capturedImage, wantScreen: lookForScreen)

        if lookForScreen {
            updateCandidate(detection.screen, frame: frame, geometry: geometry)
        }

        var fingerState: FingerState?
        if let anchor, let tip = detection.fingertip {
            fingerState = locateFinger(tip, on: anchor, frame: frame, geometry: geometry)
        }
        if fingerState == nil { resetSmoothing() }
        onFinger?(fingerState)

        if wantsReadFromNextFrame, anchor != nil {
            wantsReadFromNextFrame = false
            performRead(frame: frame)
        }

        // The UI does not need more than about 20 updates a second; guidance uses onFinger.
        guard frame.timestamp - lastPublishTime > 0.05 else { return }
        lastPublishTime = frame.timestamp

        var newOverlay = Overlay()
        if let anchor {
            newOverlay.anchored = anchor.corners.compactMap { geometry.project($0) }.map(FrameGeometry.portrait(fromRaw:))
        } else if let candidate = lastCandidate {
            newOverlay.candidate = candidate.corners.map(FrameGeometry.portrait(fromRaw:))
        }
        if let tip = detection.fingertip {
            newOverlay.fingertip = FrameGeometry.portrait(fromRaw: tip.point)
        }
        let fps = smoothedFPS
        let aspect = geometry.portraitAspect
        DispatchQueue.main.async {
            self.overlay = newOverlay
            self.finger = fingerState
            self.framesPerSecond = fps
            self.portraitAspect = aspect
        }
    }

    private func updateCandidate(_ candidate: ScreenCandidate?, frame: ARFrame, geometry: FrameGeometry) {
        if let candidate {
            if let last = lastCandidate, candidate.maxCornerDistance(to: last) < 0.03 {
                stableCount += 1
            } else {
                stableCount = 1
            }
            lastCandidate = candidate
        } else {
            stableCount = 0
            lastCandidate = nil
        }

        let stableEnough = autoAnchor && stableCount >= 4
        guard stableEnough || wantsAnchorNow else { return }
        let forced = wantsAnchorNow
        wantsAnchorNow = false

        let outline = lastCandidate ?? .centerOfView
        guard let newAnchor = makeAnchor(from: outline, frame: frame, geometry: geometry) else {
            stableCount = 0
            if forced { publishStatus("Could not measure the surface. Hold steady about 40 centimetres away and try again.") }
            return
        }
        anchor = newAnchor
        resetSmoothing()
        let usedFallback = lastCandidate == nil
        let size = String(format: "%.0f by %.0f cm", newAnchor.width * 100, newAnchor.height * 100)
        DispatchQueue.main.async {
            self.isAnchored = true
            self.screenSizeText = size
            self.status = usedFallback
                ? "Anchored to the middle of the view (no outline found)"
                : "Screen anchored"
        }
    }

    /// Measures the screen plane from points just inside the outline, then finds where the
    /// outline's corners sit on that plane.
    private func makeAnchor(from outline: ScreenCandidate, frame: ARFrame, geometry: FrameGeometry) -> ScreenAnchor? {
        let corners = outline.corners
        let centroid = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        // Sample inside the outline so measurements land on the glass, not the bezel or the wall behind.
        let inset = corners.map { CGPoint(x: $0.x + ($0.x.distance(to: centroid.x)) * 0.2,
                                          y: $0.y + ($0.y.distance(to: centroid.y)) * 0.2) }
        let surface = inset.compactMap { surfacePoint(atRaw: $0, frame: frame, geometry: geometry) }
        guard surface.count == 4 else { return nil }

        let cross = simd_cross(surface[2] - surface[0], surface[3] - surface[1])
        guard simd_length(cross) > 1e-6 else { return nil }
        let planeNormal = simd_normalize(cross)
        let planePoint = (surface[0] + surface[1] + surface[2] + surface[3]) / 4

        var world: [simd_float3] = []
        for corner in corners {
            let ray = geometry.ray(throughRaw: corner)
            let denom = simd_dot(ray.direction, planeNormal)
            guard abs(denom) > 1e-5 else { return nil }
            let t = simd_dot(planePoint - ray.origin, planeNormal) / denom
            guard t > 0 else { return nil }
            world.append(ray.origin + ray.direction * t)
        }
        return ScreenAnchor(topLeft: world[0], topRight: world[1], bottomRight: world[2], bottomLeft: world[3],
                            cameraPosition: geometry.cameraPosition, createdAt: frame.timestamp)
    }

    /// World position of the real surface seen at an image point: ARKit raycast first, raw LiDAR depth second.
    private func surfacePoint(atRaw p: CGPoint, frame: ARFrame, geometry: FrameGeometry) -> simd_float3? {
        let query = frame.raycastQuery(from: p, allowing: .estimatedPlane, alignment: .any)
        if let hit = session.raycast(query).first {
            return simd_make_float3(hit.worldTransform.columns.3)
        }
        if let depthData = frame.sceneDepth,
           let depth = DepthSampler.depth(in: depthData, atRaw: p, radius: 2, percentile: 0.5) {
            return geometry.unproject(raw: p, depth: depth)
        }
        return nil
    }

    private func locateFinger(_ tip: FingertipDetection, on anchor: ScreenAnchor,
                              frame: ARFrame, geometry: FrameGeometry) -> FingerState? {
        var uv: CGPoint?
        var hover: Float?
        var method = FingerState.Method.ray

        // Preferred: real 3D fingertip from LiDAR, dropped straight down onto the glass.
        // This removes parallax, so the reported spot is where the finger will actually land.
        if let depthData = frame.sceneDepth,
           let depth = DepthSampler.depth(in: depthData, atRaw: tip.point, radius: 1, percentile: 0.2) {
            let backOfFinger = geometry.unproject(raw: tip.point, depth: depth)
            let located = anchor.locate(backOfFinger)
            let padHeight = located.height - fingerThickness
            // Ignore readings that put the finger well behind the glass or implausibly far in front.
            if padHeight > -0.03, padHeight < 0.30 {
                uv = located.uv
                hover = max(0, padHeight)
                method = .lidar
            }
        }

        // Fallback: where the camera's line of sight through the fingertip meets the glass.
        if uv == nil {
            let ray = geometry.ray(throughRaw: tip.point)
            guard let hit = anchor.intersect(rayOrigin: ray.origin, direction: ray.direction) else { return nil }
            uv = anchor.locate(hit).uv
        }
        guard let uv else { return nil }

        // Light smoothing to take out jitter without adding noticeable lag.
        let rawUV = simd_float2(Float(uv.x), Float(uv.y))
        let filteredUV = smoothedUV.map { $0 * 0.5 + rawUV * 0.5 } ?? rawUV
        smoothedUV = filteredUV
        if let hover {
            smoothedHover = smoothedHover.map { $0 * 0.6 + hover * 0.4 } ?? hover
        } else {
            smoothedHover = nil
        }

        return FingerState(uv: CGPoint(x: CGFloat(filteredUV.x), y: CGFloat(filteredUV.y)),
                           hoverMeters: smoothedHover, method: method,
                           confidence: tip.confidence, timestamp: frame.timestamp)
    }

    private func resetSmoothing() {
        smoothedUV = nil
        smoothedHover = nil
    }

    // MARK: Reading (visionQueue, then ocrQueue)

    private func performRead(frame: ARFrame) {
        guard let anchor else {
            DispatchQueue.main.async { self.isReading = false }
            return
        }
        let geometry = FrameGeometry(frame: frame)
        guard let image = reader.rectify(pixelBuffer: frame.capturedImage, anchor: anchor, geometry: geometry) else {
            DispatchQueue.main.async {
                self.isReading = false
                self.status = "The whole screen is not in view. Move the phone back a little."
            }
            return
        }
        let aspect = anchor.aspectRatio
        ocrQueue.async {
            let started = Date()
            let elements = self.reader.readText(in: image)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let reading = ScreenReading(elements: elements, source: .onDeviceText, readAt: Date(), aspectRatio: aspect)
            DispatchQueue.main.async {
                self.reading = reading
                self.rectifiedImage = UIImage(cgImage: image)
                self.isReading = false
                self.status = "Read \(elements.count) labels in \(ms) ms"
            }
        }
    }

    private func publishStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }
}
