//
//  SimulatorMirrorView.swift
//

import SwiftUI

/// Renders an `NSImage` letterboxed inside a subtle device-bezel hint.
/// Animates a fading dot at `lastTapPoint` whenever it changes.
///
/// **Click-to-tap forwarding:** if `onTapForward` is non-nil, clicks on the
/// mirror are translated from view-local coordinates into device-point
/// coordinates and handed back to the caller, who is expected to fire
/// `idb tap` on the simulator. Clicks on the surrounding letterbox /
/// bezel are ignored.
struct SimulatorMirrorView: View {
    @Binding var image: NSImage?
    var lastTapPoint: CGPoint? = nil
    var deviceSize: CGSize = .init(width: 393, height: 852)   // iPhone 16 Pro
    /// Callback invoked when the user clicks on the mirror's screen area.
    /// The point is in **device-point space** (matches `idb tap` units).
    var onTapForward: ((CGPoint) -> Void)? = nil

    @State private var tapOpacity: Double = 0
    @State private var tapScale: CGFloat = 0.6
    @State private var renderedTap: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let aspect = deviceSize.width / deviceSize.height
            let frame = SimulatorMirrorView.fitFrame(in: geo.size, aspect: aspect)

            ZStack {
                Color.clear
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high)
                    } else {
                        Color(red: 0.98, green: 0.97, blue: 0.95)
                            .overlay(Image(systemName: "iphone").font(.system(size: 44)).foregroundStyle(Color.harnessText4))
                    }
                    if let p = renderedTap {
                        let scale = frame.width / deviceSize.width
                        Circle()
                            .strokeBorder(Color.harnessAccent, lineWidth: 2)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.harnessAccent.opacity(0.30)))
                            .position(x: p.x * scale, y: p.y * scale)
                            .opacity(tapOpacity)
                            .scaleEffect(tapScale)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: 30))
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 38)
                        .fill(Color.black.opacity(0.92))
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 16)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 38)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .frame(width: frame.width + 16, height: frame.height + 16)
                // Forward clicks on the screen area to idb. We attach the
                // gesture to the inner ZStack so the rounded-bezel frame
                // can still be hit-tested in the surrounding letterbox area
                // (where we intentionally do nothing).
                .contentShape(Rectangle())
                .gesture(onTapForward.map { handler in
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("mirror"))
                        .onEnded { drag in
                            if let pt = SimulatorMirrorView.devicePoint(
                                fromMirrorLocation: drag.location,
                                viewSize: geo.size,
                                deviceSize: deviceSize
                            ) {
                                handler(pt)
                            }
                        }
                })
            }
            .coordinateSpace(name: "mirror")
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: lastTapPoint) { _, new in
            guard let new else { return }
            renderedTap = new
            tapOpacity = 1.0; tapScale = 0.6
            withAnimation(.easeOut(duration: 0.15)) { tapScale = 1.0 }
            withAnimation(.easeOut(duration: 0.8)) { tapOpacity = 0 }
        }
        .accessibilityLabel("Simulator mirror")
        .accessibilityHint(lastTapPoint.map { "Last tap at \(Int($0.x)), \(Int($0.y))" } ?? "")
    }

    /// Compute the rendered screen rect within a view of the given size,
    /// preserving the device's aspect ratio inside an 8pt letterbox margin.
    static func fitFrame(in size: CGSize, aspect: CGFloat) -> CGRect {
        let availW = size.width - 16
        let availH = size.height - 16
        if availW / availH > aspect {
            let h = availH; let w = h * aspect
            return CGRect(x: (size.width - w) / 2, y: 8, width: w, height: h)
        } else {
            let w = availW; let h = w / aspect
            return CGRect(x: 8, y: (size.height - h) / 2, width: w, height: h)
        }
    }

    /// Hit-test a mouse click in the mirror's local coordinate space and
    /// return the corresponding **device-point** coordinate. Clicks on the
    /// surrounding letterbox / bezel return nil.
    static func devicePoint(
        fromMirrorLocation location: CGPoint,
        viewSize: CGSize,
        deviceSize: CGSize
    ) -> CGPoint? {
        let aspect = deviceSize.width / max(deviceSize.height, 1)
        let frame = fitFrame(in: viewSize, aspect: aspect)
        guard frame.contains(location), frame.width > 0, frame.height > 0 else {
            return nil
        }
        let dx = location.x - frame.minX
        let dy = location.y - frame.minY
        let pointX = dx * deviceSize.width / frame.width
        let pointY = dy * deviceSize.height / frame.height
        return CGPoint(x: pointX, y: pointY)
    }
}

#Preview {
    SimulatorMirrorView(image: .constant(nil), lastTapPoint: CGPoint(x: 200, y: 400))
        .frame(width: 480, height: 720)
        .background(Color.harnessBg2)
}
