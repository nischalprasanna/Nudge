import ARKit
import RealityKit
import SwiftUI

/// Live camera preview driven by the pipeline's AR session.
struct ARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> UIView {
        #if targetEnvironment(simulator)
        // The simulator has no camera. Show a plain backdrop so layouts can still be checked.
        let view = UIView()
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)
        return view
        #else
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion,
                              .disableGroundingShadows, .disableFaceMesh, .disableHDR,
                              .disableCameraGrain, .disableAREnvironmentLighting]
        return view
        #endif
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Draws what Nudge sees over the camera: the screen's corners, the button to press, and the fingertip.
struct OverlayCanvas: View {
    let overlay: PerceptionPipeline.Overlay
    /// Width divided by height of the upright camera image.
    let imageAspect: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || overlay.target == nil)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                draw(in: &context, size: size, time: time)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        // The preview fills the view and crops the overflow, so map points the same way.
        let scale = max(size.width / imageAspect, size.height)
        let imageWidth = imageAspect * scale
        let imageHeight = scale
        let offsetX = (size.width - imageWidth) / 2
        let offsetY = (size.height - imageHeight) / 2
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: offsetX + p.x * imageWidth, y: offsetY + p.y * imageHeight)
        }

        // The screen: four corner brackets. Dim while still deciding, bright once anchored.
        func brackets(_ points: [CGPoint], color: Color, width: CGFloat) {
            guard points.count == 4 else { return }
            let corners = points.map(place)
            var path = Path()
            for index in 0..<4 {
                let corner = corners[index]
                let next = corners[(index + 1) % 4]
                let previous = corners[(index + 3) % 4]
                func toward(_ other: CGPoint) -> CGPoint {
                    let length = max(hypot(other.x - corner.x, other.y - corner.y), 1)
                    let reach = min(length * 0.22, 34)
                    return CGPoint(x: corner.x + (other.x - corner.x) / length * reach,
                                   y: corner.y + (other.y - corner.y) / length * reach)
                }
                path.move(to: toward(previous))
                path.addLine(to: corner)
                path.addLine(to: toward(next))
            }
            // A dark edge underneath keeps the brackets visible on a bright screen.
            context.stroke(path, with: .color(.black.opacity(0.55)),
                           style: StrokeStyle(lineWidth: width + 3, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        brackets(overlay.candidate, color: Theme.paper.opacity(0.7), width: 3)
        brackets(overlay.anchored, color: Theme.signal, width: 5)

        // The button to press: a small dot on its exact middle, with a thin ring so it can be
        // found at a glance. Small on purpose: a big ring hid the key and its neighbours.
        if let target = overlay.target {
            let p = place(target)
            let beat = CGFloat((time * 1.6).truncatingRemainder(dividingBy: 1))
            let outer = 9 + beat * 12
            context.stroke(Path(ellipseIn: CGRect(x: p.x - outer, y: p.y - outer, width: outer * 2, height: outer * 2)),
                           with: .color(Theme.signal.opacity(Double(1 - beat) * 0.9)), lineWidth: 2)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                         with: .color(.black.opacity(0.6)))
            context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                         with: .color(Theme.signal))
        }

        // The fingertip: solid ring when seen, dashed when estimated from depth alone.
        if let tip = overlay.fingertip {
            let p = place(tip)
            // A thin ring with a centre point, so it is clear exactly where Nudge thinks the finger is.
            let ring = Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20))
            context.stroke(ring, with: .color(.black.opacity(0.55)), lineWidth: 5)
            context.stroke(ring, with: .color(Theme.paper),
                           style: StrokeStyle(lineWidth: 2.5, dash: overlay.fingertipEstimated ? [5, 5] : []))
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(Theme.paper))
        }
    }
}
