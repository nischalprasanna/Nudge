import ARKit
import RealityKit
import SwiftUI

/// Live camera preview driven by the pipeline's AR session.
struct ARPreview: UIViewRepresentable {
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

/// Draws the screen outline, the current target and the fingertip over the preview.
struct OverlayCanvas: View {
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
            if let target = overlay.target {
                let p = place(target)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44)),
                               with: .color(.yellow), lineWidth: 6)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                             with: .color(.yellow))
            }
            if let tip = overlay.fingertip {
                let p = place(tip)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)),
                               with: .color(.red), lineWidth: 4)
            }
        }
    }
}
