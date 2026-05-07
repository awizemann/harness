//
//  WebMirrorView.swift
//

import SwiftUI

/// Mirror primitive for the web platform — a flat panel with a thin
/// browser-style chrome (back/forward/refresh glyphs, URL pill, loading
/// indicator) above the screenshot. No device bezel: the screenshot fits
/// the whole panel below the chrome at the WKWebView's CSS-pixel aspect
/// ratio so a 1280×1600 viewport actually uses the full middle column.
///
/// Like `SimulatorMirrorView`, clicks on the screen area are translated
/// from view-local coordinates back into CSS-pixel space and forwarded
/// via `onTapForward`. Clicks on the chrome row are ignored.
struct WebMirrorView: View {
    @Binding var image: NSImage?
    var lastTapPoint: CGPoint? = nil
    /// Logical CSS-pixel viewport the WKWebView is rendering at. The
    /// production wiring resizes this to match the screen-area canvas
    /// (so the snapshot fills the column 1:1); the configured value is
    /// just the initial hint until the canvas is measured.
    var viewport: CGSize = .init(width: 1280, height: 1600)
    var currentURL: String? = nil
    var isLoading: Bool = false
    /// Callback invoked when the user clicks on the screen area. The point
    /// is in CSS-pixel space (matches the agent's coordinate system).
    var onTapForward: ((CGPoint) -> Void)? = nil
    /// Callback fired with the measured screen-area dimensions whenever
    /// they change. The session view-model uses this to ask the live
    /// `WebDriver` to resize so the next snapshot fills the canvas with
    /// no letterbox. nil for replay (where the canvas size is fixed by
    /// the saved screenshot).
    var onCanvasMeasured: ((CGSize) -> Void)? = nil

    @State private var tapOpacity: Double = 0
    @State private var tapScale: CGFloat = 0.6
    @State private var renderedTap: CGPoint?

    private static let chromeHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            chrome
            screenArea
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .fill(Color.harnessPanel)
        )
        .harnessHairlineBorder()
        .onChange(of: lastTapPoint) { _, new in
            guard let new else { return }
            renderedTap = new
            tapOpacity = 1.0; tapScale = 0.6
            withAnimation(.easeOut(duration: 0.15)) { tapScale = 1.0 }
            withAnimation(Theme.motion.tapDotFade) { tapOpacity = 0 }
        }
        .accessibilityLabel("Web mirror")
        .accessibilityHint(currentURL ?? "")
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack(spacing: Theme.spacing.s) {
            chromeGlyphs
            urlPill
            loadingSlot
        }
        .padding(.horizontal, Theme.spacing.s)
        .frame(height: Self.chromeHeight)
        .background(Color.harnessPanel2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.harnessLine).frame(height: 0.5)
        }
    }

    private var chromeGlyphs: some View {
        HStack(spacing: Theme.spacing.xs) {
            Image(systemName: "chevron.left")
            Image(systemName: "chevron.right")
            Image(systemName: "arrow.clockwise")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.harnessText4)
    }

    private var urlPill: some View {
        HStack(spacing: 6) {
            Image(systemName: lockSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(lockColor)
            Text(currentURL ?? "—")
                .font(HFont.mono)
                .foregroundStyle(Color.harnessText2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.spacing.s)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(Capsule().fill(Color.harnessPanel))
        .overlay(Capsule().stroke(Color.harnessLine, lineWidth: 0.5))
        .help(currentURL ?? "")
    }

    @ViewBuilder
    private var loadingSlot: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 16, height: 16)
    }

    private var lockSymbol: String {
        guard let url = currentURL?.lowercased() else { return "globe" }
        if url.hasPrefix("https://") { return "lock.fill" }
        if url.hasPrefix("http://") { return "lock.open" }
        return "globe"
    }

    private var lockColor: Color {
        guard let url = currentURL?.lowercased() else { return .harnessText4 }
        if url.hasPrefix("https://") { return .harnessAccent }
        return .harnessText4
    }

    // MARK: - Screen area

    private var screenArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.harnessBg2
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZStack {
                        Color(red: 0.98, green: 0.97, blue: 0.95)
                        Image(systemName: "globe")
                            .font(.system(size: 44))
                            .foregroundStyle(Color.harnessText4)
                    }
                }
                if let p = renderedTap {
                    let scaleX = geo.size.width / max(viewport.width, 1)
                    let scaleY = geo.size.height / max(viewport.height, 1)
                    Circle()
                        .strokeBorder(Color.harnessAccent, lineWidth: 2)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.harnessAccent.opacity(0.30)))
                        .position(x: p.x * scaleX, y: p.y * scaleY)
                        .opacity(tapOpacity)
                        .scaleEffect(tapScale)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "webMirror")
            .contentShape(Rectangle())
            .gesture(onTapForward.map { handler in
                DragGesture(minimumDistance: 0, coordinateSpace: .named("webMirror"))
                    .onEnded { drag in
                        // Canvas == viewport, so view-local coordinates
                        // map 1:1 to CSS pixels.
                        let pt = CGPoint(
                            x: drag.location.x * (viewport.width / max(geo.size.width, 1)),
                            y: drag.location.y * (viewport.height / max(geo.size.height, 1))
                        )
                        handler(pt)
                    }
            })
            .onAppear { onCanvasMeasured?(geo.size) }
            .onChange(of: geo.size) { _, new in onCanvasMeasured?(new) }
        }
    }

}

#Preview("WebMirrorView — loaded") {
    WebMirrorView(
        image: .constant(nil),
        viewport: CGSize(width: 1280, height: 1600),
        currentURL: "https://example.com/some/long/path/that/should/truncate/middle",
        isLoading: false
    )
    .frame(width: 720, height: 800)
    .padding()
    .background(Color.harnessBg)
}

#Preview("WebMirrorView — loading") {
    WebMirrorView(
        image: .constant(nil),
        viewport: CGSize(width: 1280, height: 1600),
        currentURL: "https://news.ycombinator.com",
        isLoading: true
    )
    .frame(width: 720, height: 800)
    .padding()
    .background(Color.harnessBg)
}
