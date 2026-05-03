//
//  SimulatorMirrorView.swift
//

import SwiftUI

/// Renders an `NSImage` letterboxed inside a subtle device-bezel hint.
/// Animates a fading dot at `lastTapPoint` whenever it changes.
struct SimulatorMirrorView: View {
    @Binding var image: NSImage?
    var lastTapPoint: CGPoint? = nil
    var deviceSize: CGSize = .init(width: 393, height: 852)   // iPhone 16 Pro

    @State private var tapOpacity: Double = 0
    @State private var tapScale: CGFloat = 0.6
    @State private var renderedTap: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let aspect = deviceSize.width / deviceSize.height
            let frame = fitFrame(in: geo.size, aspect: aspect)

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
            }
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

    private func fitFrame(in size: CGSize, aspect: CGFloat) -> CGRect {
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
}

#Preview {
    SimulatorMirrorView(image: .constant(nil), lastTapPoint: CGPoint(x: 200, y: 400))
        .frame(width: 480, height: 720)
        .background(Color.harnessBg2)
}
