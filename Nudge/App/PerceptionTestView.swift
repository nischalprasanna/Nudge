import SwiftUI

/// Test screen for the perception pipeline: shows the camera with the detected screen outline
/// and fingertip, live fingertip numbers, and the text read from the screen.
struct PerceptionTestView: View {
    @StateObject private var pipeline = PerceptionPipeline()
    @State private var markerMessage = ""
    @AppStorage("marker.on") private var markerOn = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ARPreview(session: pipeline.session)
                    .accessibilityHidden(true)
                OverlayCanvas(overlay: pipeline.overlay, imageAspect: pipeline.portraitAspect)
                    .accessibilityHidden(true)
                // Where to hold the fingernail marker when teaching Nudge its colour.
                Circle()
                    .strokeBorder(Theme.signal, lineWidth: 3)
                    .frame(width: 44, height: 44)
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

                // Fingernail marker: hold it in the yellow circle and save its colour.
                Text(markerMessage.isEmpty ? pipeline.markerInfo : markerMessage)
                    .font(.footnote.weight(.semibold))
                HStack(spacing: 12) {
                    Button("Use colour in circle") {
                        pipeline.learnMarkerColor { message in
                            markerMessage = message
                            UIAccessibility.post(notification: .announcement, argument: message)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { markerMessage = "" }
                        }
                    }
                    .accessibilityHint("Hold the marker on your fingernail in the middle of the camera view, then press this")
                    Button(markerOn ? "Marker off" : "Marker on") {
                        markerOn.toggle()
                        pipeline.loadMarkerSetting()
                    }
                    .accessibilityHint("Switches fingernail marker tracking on or off")
                }
                .buttonStyle(.bordered)

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
