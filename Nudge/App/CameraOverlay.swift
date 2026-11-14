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

        // The button to press: a ring with a second ring breathing outward.
        if let target = overlay.target {
            let p = place(target)
            let beat = CGFloat((time * 1.6).truncatingRemainder(dividingBy: 1))
            let outer = 24 + beat * 22
            context.stroke(Path(ellipseIn: CGRect(x: p.x - outer, y: p.y - outer, width: outer * 2, height: outer * 2)),
                           with: .color(Theme.signal.opacity(Double(1 - beat) * 0.8)), lineWidth: 3)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 25, y: p.y - 25, width: 50, height: 50)),
                           with: .color(.black.opacity(0.55)), lineWidth: 9)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 25, y: p.y - 25, width: 50, height: 50)),
                           with: .color(Theme.signal), lineWidth: 6)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                         with: .color(Theme.signal))
        }

        // The fingertip: solid ring when seen, dashed when estimated from depth alone.
        if let tip = overlay.fingertip {
            let p = place(tip)
            let ring = Path(ellipseIn: CGRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30))
            context.stroke(ring, with: .color(.black.opacity(0.55)), lineWidth: 7)
            context.stroke(ring, with: .color(Theme.paper),
                           style: StrokeStyle(lineWidth: 4, dash: overlay.fingertipEstimated ? [5, 5] : []))
        }
    }
}
