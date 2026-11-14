import ARKit
import os
import Combine
import UIKit
import simd

/// Owns the AR session and turns camera frames into three things:
/// an anchored screen, a live fingertip position on that screen, and on-demand text readings.
///
/// Threading: ARKit delivers frames on `arQueue`. Vision work runs on `visionQueue`, and a frame
/// is dropped if the previous one is still being processed, so tracking never falls behind.
/// Text reading runs on its own queue so it never stalls fingertip tracking.
final class PerceptionPipeline: NSObject, ObservableObject, ARSessionDelegate, @unchecked Sendable {

    /// 2D points for drawing over the camera preview, in portrait image coordinates (origin top-left).
    struct Overlay: Equatable {
        var candidate: [CGPoint] = []
        var anchored: [CGPoint] = []
        var fingertip: CGPoint?
        /// True when the fingertip was not seen directly and its position comes from LiDAR alone.
        var fingertipEstimated = false
        var target: CGPoint?
    }

    // MARK: Published state (main thread)

    @Published private(set) var status = "Starting camera"
    @Published private(set) var isAnchored = false
    @Published private(set) var finger: FingerState?
    @Published private(set) var reading: ScreenReading?
    @Published private(set) var rectifiedImage: UIImage?
    @Published private(set) var isReading = false
    @Published private(set) var overlay = Overlay()
    @Published private(set) var hasLiDAR = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var portraitAspect: CGFloat = 0.75
    @Published private(set) var screenSizeText = ""
    /// Whether the fingernail marker is in use and in view, for the test screen.
    @Published private(set) var markerInfo = "Marker: off"
    /// How to move the phone so the control panel sits in the middle of the view. Only
    /// meaningful while no screen is anchored.
    @Published private(set) var searchHint = SearchHint.none
    /// What the screen search can see right now, for the line under the camera view.
    @Published private(set) var searchInfo = ""
    /// Physical size of the anchored screen in metres.
    @Published private(set) var screenSize: CGSize?

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
    private let handFinder = DepthHandFinder()
    /// Use LiDAR alone to place the hand when the camera cannot see the fingertip.
    /// Off: on the phone it overrode correct but low-confidence fingertips with the knuckle or
    /// another part of the hand, which made the pointer jump. Tracking was steadier without it.
    var usesDepthFallback = false
    /// Test tool: keeps camera frames while guiding, for measuring tracking changes on a Mac.
    let recorder = TrackRecorder()
    private var loggedFormats = false
    private let reader = ScreenReader()

    /// Only touched on `arQueue`.
    private var busy = false

    // Everything below is only touched on `visionQueue`.
    private var anchor: ScreenAnchor?
    private var lastCandidate: ScreenCandidate?
    private var stableCount = 0
    private var frameIndex = 0
    private var wantsAnchorNow = false
    private var forcedAnchorNeedsText = false
    private var acceptsTextlessOutlines = false
    /// Outlines that were read and found not to be a touchscreen, with when (system uptime).
    private var rejected: [(anchor: ScreenAnchor, at: TimeInterval)] = []
    private var lastSearchInfo = ""
    private var rawHint = SearchHint.none
    private var rawHintRun = 0
    private var publishedHint = SearchHint.none
    /// The screen area with no hand in front of it, for `ScreenChangeFinder`, and which of its
    /// pixels were in the camera's view when it was taken.
    private var reference: ScreenChangeFinder.Sample?
    private var referenceValid: [Bool] = []
    private var wantsReference = false
    private let changeFinder = ScreenChangeFinder()
    /// Use the screen-change finder when the camera's hand tracker has no confident fingertip.
    /// Off since the afternoon of 14 November: in live use its position wandered, and the
    /// testers preferred the hand tracker on its own, as it was the night before.
    var usesScreenChangeFinder = false
    /// How far beyond the screen's edges the finder looks, as a fraction of the screen's size.
    /// A hand reaching in is picked up before it is over the screen itself.
    private static let sampleMargin: Float = 0.3
    /// Frames in which the finger came from the hand tracker, from the screen-change finder, or
    /// was not found, since the current target was set.
    private let counts = OSAllocatedUnfairLock(initialState: (tracker: 0, outline: 0, missing: 0))
    // Fingernail marker. When it is switched on, it is the only thing used to place the finger.
    private let markerFinder = MarkerFinder()
    private var markerOn = false
    private var markerColor: MarkerFinder.Color?
    /// Marker-coloured things that were on the screen with no hand in view (a green Start key,
    /// say), as positions on the screen. They are not the marker.
    private var markerDecoys: [CGPoint] = []
    private var lastMarkerUV: CGPoint?
    private var wantsMarkerColor: ((MarkerFinder.Color?) -> Void)?
    private var lastMarkerInfo = ""
    private var pendingExpansion: (up: Float, down: Float, sides: Float, done: (Bool) -> Void)?
    private var anchorBeforeExpansion: ScreenAnchor?
    private var wantsReadFromNextFrame = false
    private var smoothedUV: simd_float2?
    private var smoothedHover: Float?
    private var lastFrameTime: TimeInterval?
    private var smoothedFPS: Double = 0
    private var lastPublishTime: TimeInterval = 0
    private var targetUV: CGPoint?
    /// True when the anchor came from a detected outline (not the middle-of-view fallback).
    private var anchorFromOutline = false
    private var movedCandidate: ScreenCandidate?
    private var movedCount = 0
    private var stableRun: [ScreenCandidate] = []
    /// Running estimate of how far LiDAR places the screen from the anchored plane (metres).
    private var surfaceOffset: Float?
    /// Where the camera's hand tracker last saw a hand (raw image coordinates), and when.
    private var lastHandBox: CGRect?
    private var lastHandTime: TimeInterval = 0
    private var depthHandStreak = 0
    private var lastFingerTime: TimeInterval = 0
    private var validationCompletions: [(Bool) -> Void] = []
    private var readCompletions: [(ScreenReading?, CGImage?) -> Void] = []

    // MARK: Lifecycle

    func start() {
        loadMarkerSetting()
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
        recorder.begin()
        if !loggedFormats {
            loggedFormats = true
            let formats = ARWorldTrackingConfiguration.supportedVideoFormats.map {
                "\($0.captureDeviceType.rawValue.replacingOccurrences(of: "AVCaptureDeviceTypeBuiltIn", with: "")) \(Int($0.imageResolution.width))x\(Int($0.imageResolution.height))@\($0.framesPerSecond)"
            }
            DebugLog.add("camera: using \(Int(config.videoFormat.imageResolution.width))x\(Int(config.videoFormat.imageResolution.height)); offered: \(formats.joined(separator: ", "))")
        }
        session.delegate = self
        session.delegateQueue = arQueue
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        status = "Point the phone at the touchscreen"
    }

    func stop() {
        session.pause()
        recorder.end()
    }

    // MARK: Commands (call from any thread)

    /// Anchor right now using the current outline, or the middle of the view if none is detected.
    /// With `requireText`, it waits instead until there are labels to anchor to: an outline
    /// holding text, or text in the middle of the view.
    func anchorNow(requireText: Bool = false) {
        visionQueue.async {
            self.anchor = nil
            self.wantsAnchorNow = true
            self.forcedAnchorNeedsText = requireText
        }
    }

    /// After a few seconds without finding an outline that holds labels, the task lets any
    /// steady outline through. Whether it really is a touchscreen is then settled by reading it.
    func setRelaxedSearch(_ relaxed: Bool) {
        visionQueue.async { self.acceptsTextlessOutlines = relaxed }
    }

    /// The current outline turned out not to be a touchscreen (nothing readable on it). Drop it
    /// and do not pick the same outline again for a few seconds.
    func rejectAnchor() {
        visionQueue.async {
            if let anchor = self.anchor {
                self.rejected.append((anchor, ProcessInfo.processInfo.systemUptime))
                if self.rejected.count > 6 { self.rejected.removeFirst() }
            }
        }
        clearAnchor()
    }

    /// Widens the anchored rectangle within its own plane, as fractions of its size: upward
    /// (where a display usually is), downward and to both sides. Each side is taken as far as
    /// asked or as far as the camera's view allows. Returns false if nothing could be added.
    /// The detected outline is often just the block of keys; the display that shows whether a
    /// press worked sits outside it.
    func expandAnchor(up: Float, down: Float, sides: Float) async -> Bool {
        await withCheckedContinuation { continuation in
            visionQueue.async {
                self.pendingExpansion = (up, down, sides, { done in
                    DispatchQueue.main.async { continuation.resume(returning: done) }
                })
            }
        }
    }

    /// Goes back to the rectangle as it was before `expandAnchor`.
    func revertExpansion() {
        visionQueue.async {
            guard let earlier = self.anchorBeforeExpansion else { return }
            self.anchorBeforeExpansion = nil
            self.adopt(earlier, status: nil)
        }
    }

    func clearRejections() {
        visionQueue.async { self.rejected = [] }
    }

    func clearAnchor() {
        visionQueue.async {
            self.anchor = nil
            self.wantsAnchorNow = false
            self.lastCandidate = nil
            self.stableCount = 0
            self.movedCandidate = nil
            self.movedCount = 0
            self.stableRun = []
            self.resetSmoothing()
            DispatchQueue.main.async {
                self.isAnchored = false
                self.finger = nil
                self.reading = nil
                self.rectifiedImage = nil
                self.screenSizeText = ""
                self.screenSize = nil
                self.status = "Point the phone at the touchscreen"
            }
        }
    }

    /// Checks whether the current outline is still on a screen the camera can see, so a task
    /// can start straight away instead of searching again. False if there is no outline.
    func anchorStillValid(timeout: TimeInterval = 1.0) async -> Bool {
        await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ value: Bool) {
                // Always called on the main thread.
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            visionQueue.async {
                self.validationCompletions.append { value in finish(value) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Marks a point on the screen (normalized) to highlight in the overlay. Nil clears it.
    /// Reads the marker setting saved on the phone. Call after it changes.
    func loadMarkerSetting() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "marker.resetOnce") {
            defaults.set(true, forKey: "marker.resetOnce")
            defaults.set(false, forKey: "marker.on")
        }
        let on = defaults.bool(forKey: "marker.on")
        var color: MarkerFinder.Color?
        if defaults.object(forKey: "marker.cb") != nil {
            color = MarkerFinder.Color(cb: UInt8(clamping: defaults.integer(forKey: "marker.cb")),
                                       cr: UInt8(clamping: defaults.integer(forKey: "marker.cr")))
        }
        visionQueue.async {
            self.markerOn = on && color != nil
            self.markerColor = color
            self.lastMarkerUV = nil
        }
    }

    /// Takes the colour in the middle of the camera's view as the marker colour and saves it.
    /// The completion gets a sentence saying how it went.
    func learnMarkerColor(completion: @escaping (String) -> Void) {
        visionQueue.async {
            self.wantsMarkerColor = { color in
                var message = "I couldn't read the colour. Try again."
                if let color {
                    if color.strength < 22 {
                        message = "That colour is too close to grey or white to pick out. Use something bright: blue, pink, orange or green."
                    } else if color.looksLikeSkin {
                        message = "That colour is too close to skin. Use something that stands out from your finger."
                    } else {
                        let defaults = UserDefaults.standard
                        defaults.set(Int(color.cb), forKey: "marker.cb")
                        defaults.set(Int(color.cr), forKey: "marker.cr")
                        defaults.set(true, forKey: "marker.on")
                        message = "Marker colour saved. Tracking will follow the marker."
                    }
                }
                DispatchQueue.main.async {
                    self.loadMarkerSetting()
                    completion(message)
                }
            }
        }
    }

    func setTarget(_ uv: CGPoint?) {
        if uv != nil { counts.withLock { $0 = (0, 0, 0) } }
        visionQueue.async { self.targetUV = uv }
    }

    /// How the finger was found, frame by frame, since the current target was set.
    var trackingCounts: (tracker: Int, outline: Int, missing: Int) { counts.withLock { $0 } }

    /// Re-reads the anchored screen and waits for the result. Nil if the screen could not be read.
    func readScreenNow(timeout: TimeInterval = 6) async -> (reading: ScreenReading, image: CGImage)? {
        await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ value: (reading: ScreenReading, image: CGImage)?) {
                // Always called on the main thread.
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            readScreen { reading, image in
                if let reading, let image { finish((reading, image)) } else { finish(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Re-read the anchored screen. Results arrive in `reading` and, if given, in `completion` (main thread).
    func readScreen(completion: ((ScreenReading?, CGImage?) -> Void)? = nil) {
        visionQueue.async {
            if let completion { self.readCompletions.append(completion) }
            guard self.anchor != nil else {
                self.publishStatus("Anchor the screen first")
                self.finishRead(nil, nil)
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

        let findScreen = anchor == nil && (wantsAnchorNow || frameIndex % 3 == 0)
        // Once anchored, the outline is left alone so button positions stay put. It is only
        // re-checked (a few times a second, and never while guiding to a button) to notice
        // that the device itself has been moved.
        let trackScreen = anchor != nil && anchorFromOutline && targetUV == nil && frameIndex % 15 == 0
        let validate = !validationCompletions.isEmpty
        let detection = detectors.detect(pixelBuffer: frame.capturedImage,
                                         wantScreen: findScreen || trackScreen || validate)

        if validate {
            // Valid means: it came from a real outline, and the best outline in view right now
            // is in the same place.
            var valid = false
            if let anchor, anchorFromOutline, let best = detection.screens.first(where: \.hasText) {
                let projected = anchor.corners.compactMap { geometry.project($0) }
                if projected.count == 4 {
                    let outline = ScreenCandidate(topLeft: projected[0], topRight: projected[1],
                                                  bottomRight: projected[2], bottomLeft: projected[3], confidence: 1)
                    valid = best.maxCornerDistance(to: outline) < 0.06
                }
            }
            let completions = validationCompletions
            validationCompletions = []
            DispatchQueue.main.async { completions.forEach { $0(valid) } }
        }

        if findScreen {
            // Only an outline with labels inside it can be a touchscreen. Without that rule the
            // biggest rectangle in view wins, and that is often a desk, a door or a window.
            // Leave out outlines that were read a moment ago and had nothing on them.
            let now = ProcessInfo.processInfo.systemUptime
            rejected.removeAll { now - $0.at > 6 }
            let ruledOut: [ScreenCandidate] = rejected.compactMap { item in
                let projected = item.anchor.corners.compactMap { geometry.project($0) }
                guard projected.count == 4 else { return nil }
                return ScreenCandidate(topLeft: projected[0], topRight: projected[1],
                                       bottomRight: projected[2], bottomLeft: projected[3], confidence: 1)
            }
            let usable = detection.screens.filter { screen in
                !ruledOut.contains { $0.maxCornerDistance(to: screen) < 0.08 }
            }
            var candidate = usable.first(where: \.hasText)
            if candidate == nil, acceptsTextlessOutlines || (wantsAnchorNow && !forcedAnchorNeedsText) {
                candidate = usable.first
            }
            lastSearchInfo = "Outlines \(detection.screens.count), with text \(detection.screens.filter(\.hasText).count), text in middle \(detection.centerText)"

            // Aiming help. A hint has to hold for several looks in a row before it is passed on,
            // so a phone that is still moving does not produce a stream of contradictions.
            if let text = detection.text {
                let hint = SearchHint.from(text)
                rawHintRun = hint == rawHint ? rawHintRun + 1 : 1
                rawHint = hint
                if rawHintRun >= 4, hint != publishedHint {
                    publishedHint = hint
                    DispatchQueue.main.async { self.searchHint = hint }
                }
            }
            updateCandidate(candidate, centerText: detection.centerText, frame: frame, geometry: geometry)
        } else if trackScreen, detection.fingertip == nil {
            // Only while no hand is in view: a hand hides edges and gives misleading outlines.
            followScreen(detection.screens.filter(\.hasText), frame: frame, geometry: geometry)
        }

        if let request = pendingExpansion {
            pendingExpansion = nil
            request.done(expand(by: request, geometry: geometry))
        }

        var fingerState: FingerState?
        var pointerInImage = detection.fingertip?.point
        var pointerEstimated = false
        if let anchor {
            if let tip = detection.fingertip {
                fingerState = locateFinger(tip, on: anchor, frame: frame, geometry: geometry)
            }
            // When the camera's hand tracker sees a hand but not its fingertip (or only a shaky
            // guess at it), ask LiDAR which part of that hand is nearest the glass. Never without
            // a sighting of a hand: depth alone cannot tell a hand from a laptop's base or a handle.
            if let box = detection.handBox {
                lastHandBox = box
                lastHandTime = frame.timestamp
            }
            let weak = (detection.fingertip?.confidence ?? 0) < 0.5
            var depthHand: DepthHandFinder.Result?
            if usesDepthFallback, weak, let depthData = frame.sceneDepth,
               let searchBox = handSearchBox(at: frame.timestamp) {
                depthHand = handFinder.find(depthData: depthData, anchor: anchor, geometry: geometry,
                                            searchBox: searchBox)
            }
            // It has to hold for a few frames in a row before it is believed.
            depthHandStreak = depthHand == nil ? 0 : depthHandStreak + 1
            if let hand = depthHand, depthHandStreak >= 3 {
                var useDepth = fingerState == nil
                if let seen = fingerState {
                    // A shaky fingertip that LiDAR places somewhere else on the screen is a wrong guess.
                    let dx = Float(seen.uv.x - hand.uv.x) * anchor.width
                    let dy = Float(seen.uv.y - hand.uv.y) * anchor.height
                    useDepth = (dx * dx + dy * dy).squareRoot() > 0.03
                }
                if useDepth {
                    fingerState = makeFingerState(from: hand, timestamp: frame.timestamp)
                    pointerInImage = hand.imagePoint
                    pointerEstimated = true
                }
            }
        }
        if let learn = wantsMarkerColor {
            wantsMarkerColor = nil
            learn(colourAtCentre(of: frame.capturedImage))
        }
        if markerOn, let color = markerColor {
            // The marker is the only source when it is on. Mixing it with the other finders
            // would make the position jump between them.
            fingerState = nil
            pointerInImage = nil
            pointerEstimated = false
            var info = "Marker: on, not in view"
            if let seen = findMarker(frame.capturedImage, color: color, anchor: anchor, geometry: geometry) {
                pointerInImage = seen.point
                info = "Marker: in view (\(seen.count) samples)"
                if let anchor {
                    let tip = FingertipDetection(point: seen.point, confidence: 0.95, previousJoint: nil)
                    if var located = locateFinger(tip, on: anchor, frame: frame, geometry: geometry) {
                        located.method = .marker
                        fingerState = located
                        lastMarkerUV = located.uv
                    }
                }
            }
            if info != lastMarkerInfo {
                lastMarkerInfo = info
                DispatchQueue.main.async { self.markerInfo = info }
            }
        } else if lastMarkerInfo != "Marker: off" {
            lastMarkerInfo = "Marker: off"
            DispatchQueue.main.async { self.markerInfo = "Marker: off" }
        }

        if let anchor, usesScreenChangeFinder, !markerOn {
            if wantsReference {
                wantsReference = false
                captureReference(frame.capturedImage, anchor: anchor, geometry: geometry)
            } else if targetUV != nil, reference != nil {
                // While guiding: where does something newly cover the screen?
                let confident = fingerState != nil && (detection.fingertip?.confidence ?? 0) >= 0.5
                if let seen = outlineFinger(frame.capturedImage, anchor: anchor, geometry: geometry) {
                    var useOutline = !confident
                    if confident, let tracked = fingerState {
                        // The hand tracker is sure, but puts the finger somewhere the screen is
                        // not covered. What is actually in front of the screen wins.
                        let dx = Float(tracked.uv.x - seen.x) * anchor.width
                        let dy = Float(tracked.uv.y - seen.y) * anchor.height
                        useOutline = (dx * dx + dy * dy).squareRoot() > 0.03
                    }
                    if useOutline {
                        let rawUV = simd_float2(Float(seen.x), Float(seen.y))
                        let filtered = smoothedUV.map { $0 * 0.5 + rawUV * 0.5 } ?? rawUV
                        smoothedUV = filtered
                        fingerState = FingerState(uv: CGPoint(x: CGFloat(filtered.x), y: CGFloat(filtered.y)),
                                                  hoverMeters: nil, method: .outline, confidence: 0.5,
                                                  timestamp: frame.timestamp)
                        pointerInImage = geometry.project(anchor.world(u: filtered.x, v: filtered.y))
                        pointerEstimated = true
                    }
                }
            }
        }
        if let anchor, markerOn, wantsReference, let color = markerColor {
            // With no hand in view, note anything on the screen that is the marker's colour.
            wantsReference = false
            markerDecoys = markerBlobs(frame.capturedImage, color: color, anchor: anchor, geometry: geometry)
                .compactMap { blob -> CGPoint? in
                    let ray = geometry.ray(throughRaw: blob.point)
                    guard let hit = anchor.intersect(rayOrigin: ray.origin, direction: ray.direction) else { return nil }
                    return anchor.locate(hit).uv
                }
        }
        if let anchor, let targetUV, recorder.isOn {
            func pair(_ p: CGPoint?) -> Any { p.map { [$0.x, $0.y] as Any } ?? NSNull() }
            var info: [String: Any] = [
                "anchor": anchor.corners.flatMap { [$0.x, $0.y, $0.z] },
                "target": [targetUV.x, targetUV.y],
                "tip": pair(detection.fingertip?.point),
                "tipConfidence": detection.fingertip?.confidence ?? 0,
                "joint": pair(detection.fingertip?.previousJoint),
                "uv": pair(fingerState?.uv),
                "method": fingerState?.method.rawValue ?? "",
                "hover": fingerState?.hoverMeters.map { $0 as Any } ?? NSNull(),
            ]
            if let box = detection.handBox {
                info["handBox"] = [box.minX, box.minY, box.width, box.height]
            }
            recorder.record(frame: frame, info: info)
        }
        if targetUV != nil {
            let source = fingerState?.method
            counts.withLock {
                if source == nil { $0.missing += 1 } else if source == .outline { $0.outline += 1 } else { $0.tracker += 1 }
            }
        }

        // Keep the smoothing through a dropped frame or two; start afresh after a real gap.
        if fingerState != nil {
            lastFingerTime = frame.timestamp
        } else if frame.timestamp - lastFingerTime > 0.35 {
            resetSmoothing()
        }
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
        if let pointerInImage {
            newOverlay.fingertip = FrameGeometry.portrait(fromRaw: pointerInImage)
            newOverlay.fingertipEstimated = pointerEstimated
        }
        if let anchor, let targetUV,
           let raw = geometry.project(anchor.world(u: Float(targetUV.x), v: Float(targetUV.y))) {
            newOverlay.target = FrameGeometry.portrait(fromRaw: raw)
        }
        let fps = smoothedFPS
        let aspect = geometry.portraitAspect
        let info = anchor == nil ? lastSearchInfo : ""
        DispatchQueue.main.async {
            if self.searchInfo != info { self.searchInfo = info }
            self.overlay = newOverlay
            self.finger = fingerState
            self.framesPerSecond = fps
            self.portraitAspect = aspect
        }
    }

    private func updateCandidate(_ candidate: ScreenCandidate?, centerText: Int, frame: ARFrame, geometry: FrameGeometry) {
        if let candidate {
            if let last = lastCandidate, candidate.maxCornerDistance(to: last) < 0.025 {
                stableCount += 1
                stableRun.append(candidate)
                if stableRun.count > 8 { stableRun.removeFirst() }
            } else {
                stableCount = 1
                stableRun = [candidate]
            }
            lastCandidate = candidate
        } else {
            stableCount = 0
            lastCandidate = nil
            stableRun = []
        }

        // The same outline has to hold still for about half a second before it is trusted.
        let stableEnough = autoAnchor && stableCount >= 5
        guard stableEnough || wantsAnchorNow else { return }
        // Asked to anchor to the middle of the view, but there is nothing to read there yet: keep waiting.
        if !stableEnough, forcedAnchorNeedsText, lastCandidate == nil, centerText < 3 { return }
        let forced = wantsAnchorNow
        wantsAnchorNow = false

        // Average the recent sightings so one noisy frame does not skew the outline.
        let outline = ScreenCandidate.average(stableRun) ?? lastCandidate ?? .centerOfView
        guard let newAnchor = makeAnchor(from: outline, frame: frame, geometry: geometry) else {
            stableCount = 0
            if forced { publishStatus("Could not measure the surface. Hold steady about 40 centimetres away and try again.") }
            return
        }
        let usedFallback = lastCandidate == nil
        anchorFromOutline = !usedFallback
        movedCandidate = nil
        movedCount = 0
        adopt(newAnchor, status: usedFallback
              ? "Anchored to the middle of the view (no outline found)"
              : "Screen anchored")
    }

    private func expand(by request: (up: Float, down: Float, sides: Float, done: (Bool) -> Void),
                        geometry: FrameGeometry) -> Bool {
        guard let current = anchor else { return false }

        func grown(up: Float, down: Float, sides: Float) -> ScreenAnchor? {
            let corners = [current.world(u: -sides, v: -up), current.world(u: 1 + sides, v: -up),
                           current.world(u: 1 + sides, v: 1 + down), current.world(u: -sides, v: 1 + down)]
            // Every corner has to be in the camera's view, or the area cannot be read.
            for corner in corners {
                guard let raw = geometry.project(corner),
                      (0.0...1.0).contains(raw.x), (0.0...1.0).contains(raw.y) else { return nil }
            }
            return ScreenAnchor(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2],
                                bottomLeft: corners[3], cameraPosition: geometry.cameraPosition,
                                createdAt: current.createdAt)
        }

        // Add one side at a time, each as far as it will go, so a side that is hard up against
        // the edge of the picture does not stop the others.
        var up: Float = 0, down: Float = 0, sides: Float = 0
        let scales: [Float] = [1, 0.75, 0.5, 0.25]
        if let scale = scales.first(where: { grown(up: request.up * $0, down: down, sides: sides) != nil }) { up = request.up * scale }
        if let scale = scales.first(where: { grown(up: up, down: down, sides: request.sides * $0) != nil }) { sides = request.sides * scale }
        if let scale = scales.first(where: { grown(up: up, down: request.down * $0, sides: sides) != nil }) { down = request.down * scale }
        guard up + down + sides > 0, let wider = grown(up: up, down: down, sides: sides) else { return false }

        anchorBeforeExpansion = current
        // The wider area no longer matches any outline the camera detects, so it must not be
        // "corrected" back to one.
        anchorFromOutline = false
        adopt(wider, status: "Screen anchored (widened)")
        DebugLog.add(String(format: "anchor: widened up %.0f%%, down %.0f%%, sides %.0f%%", up * 100, down * 100, sides * 100))
        return true
    }

    /// Makes `newAnchor` the current anchor and tells the UI.
    private func adopt(_ newAnchor: ScreenAnchor, status: String?) {
        anchor = newAnchor
        reference = nil
        surfaceOffset = nil
        resetSmoothing()
        let size = String(format: "%.0f by %.0f cm", newAnchor.width * 100, newAnchor.height * 100)
        let metres = CGSize(width: CGFloat(newAnchor.width), height: CGFloat(newAnchor.height))
        DispatchQueue.main.async {
            self.isAnchored = true
            self.screenSize = metres
            self.screenSizeText = size
            if let status { self.status = status }
        }
    }

    /// Notices when the device has been moved and re-anchors to it. Small differences are
    /// deliberately ignored: adjusting the outline for every wobble made it flicker and shifted
    /// the buttons. Only a clear move, seen the same way several times in a row, is followed.
    private func followScreen(_ candidates: [ScreenCandidate], frame: ARFrame, geometry: FrameGeometry) {
        func reset() {
            movedCandidate = nil
            movedCount = 0
        }
        guard let current = anchor, let best = candidates.first else { return reset() }
        let projected = current.corners.compactMap { geometry.project($0) }
        guard projected.count == 4 else { return reset() }
        let currentOutline = ScreenCandidate(topLeft: projected[0], topRight: projected[1],
                                             bottomRight: projected[2], bottomLeft: projected[3], confidence: 1)

        // Still roughly where it was anchored: nothing to do.
        guard best.maxCornerDistance(to: currentOutline) > 0.10 else { return reset() }

        if let last = movedCandidate, best.maxCornerDistance(to: last) < 0.025 {
            movedCount += 1
        } else {
            movedCount = 1
        }
        movedCandidate = best
        guard movedCount >= 4 else { return }

        // Only follow an outline that is physically the same size as the anchored screen,
        // so the anchor cannot jump to some other rectangle in view.
        reset()
        guard let fresh = makeAnchor(from: best, frame: frame, geometry: geometry),
              abs(fresh.width - current.width) / current.width < 0.15,
              abs(fresh.height - current.height) / current.height < 0.15 else { return }
        adopt(fresh, status: "The screen moved. Following it.")
    }

    /// Measures the screen plane from points just inside the outline, then finds where the
    /// outline's corners sit on that plane.
    private func makeAnchor(from outline: ScreenCandidate, frame: ARFrame, geometry: FrameGeometry) -> ScreenAnchor? {
        let corners = outline.corners
        // Sample a grid inside the outline so measurements land on the glass, not the bezel or
        // the wall behind, and fit one plane through all of them. Many points average out the
        // noise that a handful of corner samples cannot.
        var surface: [simd_float3] = []
        let steps: [CGFloat] = [0.12, 0.31, 0.5, 0.69, 0.88]
        for s in steps {
            for t in steps {
                let top = CGPoint(x: corners[0].x + (corners[1].x - corners[0].x) * s,
                                  y: corners[0].y + (corners[1].y - corners[0].y) * s)
                let bottom = CGPoint(x: corners[3].x + (corners[2].x - corners[3].x) * s,
                                     y: corners[3].y + (corners[2].y - corners[3].y) * s)
                let p = CGPoint(x: top.x + (bottom.x - top.x) * t, y: top.y + (bottom.y - top.y) * t)
                if let point = surfacePoint(atRaw: p, frame: frame, geometry: geometry) {
                    surface.append(point)
                }
            }
        }
        guard surface.count >= 8, let plane = Self.fitPlane(surface, geometry: geometry) else { return nil }
        let planeNormal = plane.normal
        let planePoint = plane.point

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

    /// Least-squares plane through measured surface points, with outliers dropped.
    /// Works in camera space, where the screen is roughly face-on, so depth = a*x + b*y + c is well behaved.
    private static func fitPlane(_ world: [simd_float3], geometry: FrameGeometry) -> (point: simd_float3, normal: simd_float3)? {
        var points = world.map { simd_make_float3(geometry.worldToCamera * simd_float4($0.x, $0.y, $0.z, 1)) }

        func solve(_ pts: [simd_float3]) -> simd_float3? {
            var m = simd_float3x3()
            var rhs = simd_float3()
            for p in pts {
                let row = simd_float3(p.x, p.y, 1)
                m += simd_float3x3(columns: (row * row.x, row * row.y, row * row.z))
                rhs += row * p.z
            }
            guard abs(simd_determinant(m)) > 1e-12 else { return nil }
            return m.inverse * rhs
        }

        guard var coefficients = solve(points) else { return nil }
        // One pass of outlier rejection: drop points more than 1 cm off the first fit, then refit.
        let kept = points.filter { abs($0.x * coefficients.x + $0.y * coefficients.y + coefficients.z - $0.z) < 0.01 }
        if kept.count >= 6, kept.count < points.count, let refined = solve(kept) {
            coefficients = refined
            points = kept
        }

        let centroid = points.reduce(simd_float3(), +) / Float(points.count)
        let onPlane = simd_float3(centroid.x, centroid.y,
                                  coefficients.x * centroid.x + coefficients.y * centroid.y + coefficients.z)
        let normalCamera = simd_normalize(simd_float3(coefficients.x, coefficients.y, -1))
        let point = simd_make_float3(geometry.cameraTransform * simd_float4(onPlane.x, onPlane.y, onPlane.z, 1))
        let normal = simd_normalize(simd_make_float3(geometry.cameraTransform * simd_float4(normalCamera.x, normalCamera.y, normalCamera.z, 0)))
        return (point, normal)
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

        let ray = geometry.ray(throughRaw: tip.point)
        let rayHit = anchor.intersect(rayOrigin: ray.origin, direction: ray.direction)

        // Preferred: real 3D fingertip from LiDAR, dropped straight down onto the glass.
        // This removes parallax, so the reported spot is where the finger will actually land.
        if let depthData = frame.sceneDepth,
           let depth = DepthSampler.depth(in: depthData, atRaw: tip.point, radius: 1,
                                          percentile: 0.25, minimumConfidence: 0) {
            let backOfFinger = geometry.unproject(raw: tip.point, depth: depth)
            let located = anchor.locate(backOfFinger)

            // Height is measured against the screen as LiDAR sees it right beside the finger in
            // this same frame, not only against the anchored plane. The two can disagree by a
            // centimetre or two, and that disagreement would otherwise read as phantom height.
            let local = screenHeightNear(tip, anchor: anchor, depthData: depthData, geometry: geometry)
            if let local {
                surfaceOffset = surfaceOffset.map { $0 * 0.8 + local * 0.2 } ?? local
            }
            let padHeight = located.height - (surfaceOffset ?? 0) - fingerThickness

            if padHeight > 0.004, padHeight < 0.30 {
                uv = located.uv
                hover = padHeight
                method = .lidar
            } else if padHeight <= 0.004, padHeight > -0.04, let rayHit {
                // Depth says the fingertip is at the glass: it is touching, so there is no parallax.
                uv = anchor.locate(rayHit).uv
                hover = 0
                method = .lidar
            }
        }

        // Fallback: where the camera's line of sight through the fingertip meets the glass.
        // Height above the glass is unknown here.
        if uv == nil {
            guard let rayHit else { return nil }
            uv = anchor.locate(rayHit).uv
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

    /// How far LiDAR places the screen from the anchored plane, sampled just beyond the fingertip
    /// (in the direction the finger points, where there is screen and no hand). Nil if it cannot be measured.
    private func screenHeightNear(_ tip: FingertipDetection, anchor: ScreenAnchor,
                                  depthData: ARDepthData, geometry: FrameGeometry) -> Float? {
        guard let joint = tip.previousJoint else { return nil }
        let width = geometry.imageSize.width
        let height = geometry.imageSize.height
        var vx = (tip.point.x - joint.x) * width
        var vy = (tip.point.y - joint.y) * height
        let length = hypot(vx, vy)
        guard length > 2 else { return nil }
        vx /= length
        vy /= length

        var heights: [Float] = []
        // Three directions fanned around the pointing direction, two distances each
        // (about 2 and 3.5 cm beyond the fingertip at a typical working distance).
        for angle in [-0.7, 0.0, 0.7] as [CGFloat] {
            let dx = vx * cos(angle) - vy * sin(angle)
            let dy = vx * sin(angle) + vy * cos(angle)
            for reach in [0.045, 0.075] as [CGFloat] {
                let p = CGPoint(x: tip.point.x + dx * reach, y: tip.point.y + dy * reach * width / height)
                guard (0...1).contains(p.x), (0...1).contains(p.y),
                      let depth = DepthSampler.depth(in: depthData, atRaw: p, radius: 1, percentile: 0.5) else { continue }
                let located = anchor.locate(geometry.unproject(raw: p, depth: depth))
                // Only count samples that land on the anchored screen and are plausibly its surface.
                guard (0...1).contains(located.uv.x), (0...1).contains(located.uv.y),
                      abs(located.height) < 0.06 else { continue }
                heights.append(located.height)
            }
        }
        guard heights.count >= 3 else { return nil }
        heights.sort()
        return heights[heights.count / 2]
    }

    /// The part of the picture where LiDAR may look for the hand: around where the camera sees a
    /// hand now, or saw one within the last half second. Nil when no hand has been seen.
    private func handSearchBox(at timestamp: TimeInterval) -> CGRect? {
        guard let box = lastHandBox, timestamp - lastHandTime < 0.5 else { return nil }
        // Room for a fingertip the tracker could not make out, just beyond the joints it could.
        let pad = max(0.04, max(box.width, box.height) * 0.3)
        return box.insetBy(dx: -pad, dy: -pad)
    }

    // MARK: Fingernail marker

    /// Patches of marker colour in the camera picture, as points in the raw image (normalized).
    /// Only the area around the anchored screen is searched when there is one.
    private func markerBlobs(_ pixelBuffer: CVPixelBuffer, color: MarkerFinder.Color, anchor: ScreenAnchor?,
                             geometry: FrameGeometry) -> [(point: CGPoint, count: Int)] {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return [] }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return [] }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        var minX = 0, minY = 0, maxX = width - 1, maxY = height - 1
        if let anchor {
            // The screen and a generous margin around it, as it appears in the picture now.
            let margin: Float = 0.45
            let corners = [anchor.world(u: -margin, v: -margin), anchor.world(u: 1 + margin, v: -margin),
                           anchor.world(u: 1 + margin, v: 1 + margin), anchor.world(u: -margin, v: 1 + margin)]
                .compactMap { geometry.project($0) }
            if corners.count == 4 {
                minX = max(0, Int((corners.map(\.x).min() ?? 0) * CGFloat(width)))
                maxX = min(width - 1, Int((corners.map(\.x).max() ?? 1) * CGFloat(width)))
                minY = max(0, Int((corners.map(\.y).min() ?? 0) * CGFloat(height)))
                maxY = min(height - 1, Int((corners.map(\.y).max() ?? 1) * CGFloat(height)))
            }
        }
        let blobs = markerFinder.blobs(minX: minX, minY: minY, maxX: maxX, maxY: maxY, step: 2, marker: color,
                                       colour: { x, y in
                                           let pair = chromaBase.advanced(by: y * chromaStride + x * 2)
                                           return (pair.load(as: UInt8.self), pair.load(fromByteOffset: 1, as: UInt8.self))
                                       },
                                       luma: { x, y in lumaBase.load(fromByteOffset: (y * 2) * lumaStride + x * 2, as: UInt8.self) })
        return blobs.map { (CGPoint(x: CGFloat(($0.x + 0.5) / Float(width)), y: CGFloat(($0.y + 0.5) / Float(height))), $0.count) }
    }

    /// The marker itself: the patch nearest where it was last seen, else the largest, leaving
    /// out anything that was already on the screen before the hand came in.
    private func findMarker(_ pixelBuffer: CVPixelBuffer, color: MarkerFinder.Color, anchor: ScreenAnchor?,
                            geometry: FrameGeometry) -> (point: CGPoint, count: Int)? {
        var candidates: [(point: CGPoint, count: Int, uv: CGPoint?)] = []
        for blob in markerBlobs(pixelBuffer, color: color, anchor: anchor, geometry: geometry) {
            var uv: CGPoint?
            if let anchor {
                let ray = geometry.ray(throughRaw: blob.point)
                if let hit = anchor.intersect(rayOrigin: ray.origin, direction: ray.direction) { uv = anchor.locate(hit).uv }
                if let uv, markerDecoys.contains(where: {
                    hypot(Float($0.x - uv.x) * anchor.width, Float($0.y - uv.y) * anchor.height) < 0.012
                }) { continue }
            }
            candidates.append((blob.point, blob.count, uv))
        }
        guard !candidates.isEmpty else { return nil }
        if let anchor, let last = lastMarkerUV {
            let near = candidates.filter { candidate in
                guard let uv = candidate.uv else { return false }
                return hypot(Float(uv.x - last.x) * anchor.width, Float(uv.y - last.y) * anchor.height) < 0.06
            }
            if let best = near.max(by: { $0.count < $1.count }) { return (best.point, best.count) }
        }
        let best = candidates.max(by: { $0.count < $1.count })!
        return (best.point, best.count)
    }

    /// The typical colour of a small patch in the middle of the picture.
    private func colourAtCentre(of pixelBuffer: CVPixelBuffer) -> MarkerFinder.Color? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let reach = max(3, min(width, height) / 90)
        var cbs: [UInt8] = [], crs: [UInt8] = []
        for y in (height / 2 - reach)...(height / 2 + reach) {
            for x in (width / 2 - reach)...(width / 2 + reach) {
                cbs.append(chromaBase.load(fromByteOffset: y * stride + x * 2, as: UInt8.self))
                crs.append(chromaBase.load(fromByteOffset: y * stride + x * 2 + 1, as: UInt8.self))
            }
        }
        cbs.sort()
        crs.sort()
        return MarkerFinder.Color(cb: cbs[cbs.count / 2], cr: crs[crs.count / 2])
    }

    // MARK: Screen-change finder

    /// Takes a small picture of the screen and a margin around it, straightened out, by looking
    /// up where each point of the anchored rectangle falls in the camera image.
    private func sampleScreen(_ pixelBuffer: CVPixelBuffer, anchor: ScreenAnchor, geometry: FrameGeometry,
                              against reference: ScreenChangeFinder.Sample?)
        -> (sample: ScreenChangeFinder.Sample, valid: [Bool])? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let margin = Self.sampleMargin
        // About 1.5 mm per sample on a typical panel: enough for a finger, cheap enough for every frame.
        let width = 88
        let height = min(max(Int(Float(width) * anchor.height / max(anchor.width, 0.001)), 40), 170)
        if let reference, reference.width != width || reference.height != height { return nil }
        let count = width * height
        var sample = ScreenChangeFinder.Sample(width: width, height: height,
                                               y: [UInt8](repeating: 0, count: count),
                                               cb: [UInt8](repeating: 128, count: count),
                                               cr: [UInt8](repeating: 128, count: count))
        var valid = [Bool](repeating: false, count: count)
        let span = 1 + 2 * margin
        for row in 0..<height {
            let v = -margin + (Float(row) + 0.5) / Float(height) * span
            for column in 0..<width {
                let u = -margin + (Float(column) + 0.5) / Float(width) * span
                let index = row * width + column
                if let raw = geometry.project(anchor.world(u: u, v: v)),
                   raw.x >= 0, raw.x < 1, raw.y >= 0, raw.y < 1,
                   reference == nil || referenceValid[index] {
                    let px = min(Int(raw.x * CGFloat(lumaWidth)), lumaWidth - 1)
                    let py = min(Int(raw.y * CGFloat(lumaHeight)), lumaHeight - 1)
                    sample.y[index] = lumaBase.load(fromByteOffset: py * lumaStride + px, as: UInt8.self)
                    let cx = min(px / 2, chromaWidth - 1), cy = min(py / 2, chromaHeight - 1)
                    sample.cb[index] = chromaBase.load(fromByteOffset: cy * chromaStride + cx * 2, as: UInt8.self)
                    sample.cr[index] = chromaBase.load(fromByteOffset: cy * chromaStride + cx * 2 + 1, as: UInt8.self)
                    valid[index] = true
                } else if let reference {
                    // Out of the camera's view now, or when the reference was taken: call it unchanged.
                    sample.y[index] = reference.y[index]
                    sample.cb[index] = reference.cb[index]
                    sample.cr[index] = reference.cr[index]
                }
            }
        }
        return (sample, valid)
    }

    private func captureReference(_ pixelBuffer: CVPixelBuffer, anchor: ScreenAnchor, geometry: FrameGeometry) {
        guard let taken = sampleScreen(pixelBuffer, anchor: anchor, geometry: geometry, against: nil) else { return }
        reference = taken.sample
        referenceValid = taken.valid
    }

    /// Where the finger pad is over the screen (normalized, may fall outside 0...1), judged by
    /// what newly covers the screen. Nil when nothing hand-like does.
    private func outlineFinger(_ pixelBuffer: CVPixelBuffer, anchor: ScreenAnchor, geometry: FrameGeometry) -> CGPoint? {
        guard let reference,
              let now = sampleScreen(pixelBuffer, anchor: anchor, geometry: geometry, against: reference) else { return nil }
        let span = 1 + 2 * Self.sampleMargin
        guard let found = changeFinder.find(reference: reference, current: now.sample,
                                            physicalWidth: anchor.width * span,
                                            physicalHeight: anchor.height * span) else { return nil }
        return CGPoint(x: CGFloat(-Self.sampleMargin) + found.contact.x * CGFloat(span),
                       y: CGFloat(-Self.sampleMargin) + found.contact.y * CGFloat(span))
    }

    /// Turns a LiDAR-only hand position into the same form as a seen fingertip.
    private func makeFingerState(from hand: DepthHandFinder.Result, timestamp: TimeInterval) -> FingerState {
        // Steadier smoothing than for a seen fingertip: this estimate is coarser.
        let rawUV = simd_float2(Float(hand.uv.x), Float(hand.uv.y))
        let filteredUV = smoothedUV.map { $0 * 0.65 + rawUV * 0.35 } ?? rawUV
        smoothedUV = filteredUV
        let hover = max(0, hand.height - fingerThickness)
        smoothedHover = smoothedHover.map { $0 * 0.6 + hover * 0.4 } ?? hover
        return FingerState(uv: CGPoint(x: CGFloat(filteredUV.x), y: CGFloat(filteredUV.y)),
                           hoverMeters: smoothedHover, method: .depthHand,
                           confidence: 0.4, timestamp: timestamp)
    }

    private func resetSmoothing() {
        smoothedUV = nil
        smoothedHover = nil
    }

    // MARK: Reading (visionQueue, then ocrQueue)

    private func performRead(frame: ARFrame) {
        guard let anchor else {
            DispatchQueue.main.async { self.isReading = false }
            finishRead(nil, nil)
            return
        }
        let geometry = FrameGeometry(frame: frame)
        guard let image = reader.rectify(pixelBuffer: frame.capturedImage, anchor: anchor, geometry: geometry) else {
            DispatchQueue.main.async {
                self.isReading = false
                self.status = "The whole screen is not in view. Move the phone back a little."
            }
            finishRead(nil, nil)
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
                DebugLog.add("reader: \(image.width)x\(image.height) px from a \(Int(geometry.imageSize.width))-wide frame, \(elements.count) labels in \(ms) ms")
            }
            self.visionQueue.async { self.finishRead(reading, image) }
        }
    }

    /// Hands a finished (or failed) read to everyone waiting on it. Call on `visionQueue`.
    private func finishRead(_ reading: ScreenReading?, _ image: CGImage?) {
        // A read happens with the hand out of the way, so the next frame is a clean picture
        // of the screen to compare later ones against.
        if reading != nil { wantsReference = true }
        let completions = readCompletions
        readCompletions = []
        guard !completions.isEmpty else { return }
        DispatchQueue.main.async {
            completions.forEach { $0(reading, image) }
        }
    }

    private func publishStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }
}

#if targetEnvironment(simulator)
extension PerceptionPipeline {
    /// Simulator only: shows a fixed overlay so screen layouts can be checked without a camera.
    func setPreviewOverlay(_ overlay: Overlay) {
        self.overlay = overlay
    }
}
#endif
