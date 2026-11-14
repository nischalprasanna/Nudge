import ARKit
import RealityKit
import SwiftUI

/// Test screen for the perception pipeline: shows the camera with the detected screen outline
/// and fingertip, live fingertip numbers, and the text read from the screen.
struct PerceptionTestView: View {
    @StateObject private var pipeline = PerceptionPipeline()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ARPreview(session: pipeline.session)
                    .accessibilityHidden(true)
                OverlayCanvas(overlay: pipeline.overlay, imageAspect: pipeline.portraitAspect)
                    .accessibilityHidden(true)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                Text(pipeline.status)
                    .font(.headline)
                    .accessibilityLabel("Status: \(pipeline.status)")

                Text(fingerText)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel(fingerSpoken)

                Text(infoText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(pipeline.isAnchored ? "Re-anchor" : "Anchor now") { pipeline.anchorNow() }
                        .accessibilityHint("Pins the screen in place using what the camera sees now")
                    Button("Read screen") { pipeline.readScreen() }
                        .disabled(!pipeline.isAnchored || pipeline.isReading)
                        .accessibilityHint("Reads all text on the anchored screen")
                    Button("Reset") { pipeline.clearAnchor() }
                        .accessibilityHint("Forgets the anchored screen")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let reading = pipeline.reading {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if let image = pipeline.rectifiedImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 120)
                                    .accessibilityHidden(true)
                            }
                            ForEach(reading.elements) { element in
                                Text("\(element.label)   (\(Int(element.center.x * 100)), \(Int(element.center.y * 100)))")
                                    .font(.system(.footnote, design: .monospaced))
                                    .accessibilityLabel("\(element.label), \(Int(element.center.x * 100)) percent across, \(Int(element.center.y * 100)) percent down")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding()
        }
        .navigationTitle("Perception test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { pipeline.start() }
        .onDisappear { pipeline.stop() }
        .onChange(of: pipeline.status) { _, newValue in
            UIAccessibility.post(notification: .announcement, argument: newValue)
        }
    }

    private var fingerText: String {
        guard let finger = pipeline.finger else { return "Finger: not seen" }
        let u = Int((finger.uv.x * 100).rounded())
        let v = Int((finger.uv.y * 100).rounded())
        let hover = finger.hoverMeters.map { String(format: "%.0f mm", $0 * 1000) } ?? "n/a"
        return "Finger: x \(u)%  y \(v)%  hover \(hover)  [\(finger.method.rawValue)]"
    }

    private var fingerSpoken: String {
        guard let finger = pipeline.finger else { return "Finger not seen" }
        let hover = finger.hoverMeters.map { "\(Int($0 * 1000)) millimetres above the glass" } ?? "height unknown"
        return "Finger \(Int(finger.uv.x * 100)) percent across, \(Int(finger.uv.y * 100)) percent down, \(hover)"
    }

    private var infoText: String {
        var parts = [String(format: "%.0f updates/s", pipeline.framesPerSecond)]
        parts.append(pipeline.hasLiDAR ? "LiDAR on" : "No LiDAR")
        if !pipeline.screenSizeText.isEmpty { parts.append("Screen \(pipeline.screenSizeText)") }
        return parts.joined(separator: " · ")
    }
}

/// Live camera preview driven by the pipeline's AR session.
private struct ARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion,
                              .disableGroundingShadows, .disableFaceMesh, .disableHDR,
                              .disableCameraGrain, .disableAREnvironmentLighting]
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Draws the screen outline and fingertip over the preview.
private struct OverlayCanvas: View {
    let overlay: PerceptionPipeline.Overlay
    /// Width divided by height of the upright camera image.
    let imageAspect: CGFloat

    var body: some View {
        Canvas { context, size in
            // The preview fills the view and crops the overflow, so map points the same way.
            let scale = max(size.width / imageAspect, size.height)
            let imageWidth = imageAspect * scale
            let imageHeight = scale
            let offsetX = (size.width - imageWidth) / 2
            let offsetY = (size.height - imageHeight) / 2
            func place(_ p: CGPoint) -> CGPoint {
                CGPoint(x: offsetX + p.x * imageWidth, y: offsetY + p.y * imageHeight)
            }
            func outline(_ points: [CGPoint], color: Color) {
                guard points.count == 4 else { return }
                var path = Path()
                path.move(to: place(points[0]))
                for point in points.dropFirst() { path.addLine(to: place(point)) }
                path.closeSubpath()
                context.stroke(path, with: .color(color), lineWidth: 4)
                // Mark the top-left corner so orientation mistakes are obvious.
                let corner = place(points[0])
                context.fill(Path(ellipseIn: CGRect(x: corner.x - 7, y: corner.y - 7, width: 14, height: 14)),
                             with: .color(color))
            }
            outline(overlay.candidate, color: .yellow)
            outline(overlay.anchored, color: .green)
            if let tip = overlay.fingertip {
                let p = place(tip)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)),
                               with: .color(.red), lineWidth: 4)
            }
        }
    }
}
