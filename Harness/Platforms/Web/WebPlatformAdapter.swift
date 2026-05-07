//
//  WebPlatformAdapter.swift
//  Harness
//
//  Drives the web run path: open the start URL in an embedded
//  `WKWebView`, hand RunCoordinator a `WebDriver` session.
//
//  No build step. The "system under test" is the web app at
//  `Application.webStartURL`; the viewport size comes from
//  `webViewportWidthPt` / `webViewportHeightPt` (CSS pixels).
//

import Foundation
import AppKit
import WebKit
import os

struct WebPlatformAdapter: PlatformAdapter {

    static let logger = Logger(subsystem: "com.harness.app", category: "WebPlatformAdapter")

    let kind: PlatformKind = .web
    let services: PlatformAdapterServices

    /// Settle delay after the first navigation's `didFinish`. WKWebView
    /// fires `didFinish` once the document parser is done, but lazy-loaded
    /// images, web-fonts, and JS-driven layout shifts can land a little
    /// later — without this wait the first screenshot regularly captures
    /// a half-painted page. Subsequent navigates inside the run aren't
    /// padded; the agent can always issue `wait` if it needs more time.
    private static let firstLoadSettleDelay: Duration = .milliseconds(1500)

    init(services: PlatformAdapterServices) {
        self.services = services
    }

    func prepare(
        _ request: RunRequest,
        runID: UUID,
        continuation: AsyncThrowingStream<RunEvent, any Error>.Continuation
    ) async throws -> RunSession {
        guard let urlString = request.webStartURL, !urlString.isEmpty,
              let startURL = URL(string: urlString) else {
            throw WebPlatformAdapterError.missingStartURL
        }
        let viewportW = request.webViewportWidthPt ?? 1280
        let viewportH = request.webViewportHeightPt ?? 1600
        let initialViewport = CGSize(width: viewportW, height: viewportH)
        // If the live mirror has already measured its canvas in a previous
        // run, prefer those dimensions for the WKWebView so the very first
        // screenshot fills the column without letterbox. Falls back to
        // the configured viewport when the registry is empty (first run
        // after launch).
        let preferredViewport = await MainActor.run { LiveWebMirror.canvasSize } ?? initialViewport

        // Construct + load on the main actor.
        let controller: WebViewWindowController = await MainActor.run {
            WebViewWindowController(viewport: preferredViewport)
        }
        await MainActor.run {
            controller.webView.load(URLRequest(url: startURL))
        }
        let nav = await MainActor.run { controller.navigationDelegate }
        await nav.awaitNextLoad(timeout: .seconds(20))
        // Give the page a moment to paint past `didFinish`. See note above.
        try? await Task.sleep(for: Self.firstLoadSettleDelay)

        // Synthesise a SimulatorRef so the existing UI events keep firing
        // — same trick MacOSPlatformAdapter uses.
        let pseudoSim = SimulatorRef(
            udid: "web-\(startURL.host ?? "localhost")",
            name: startURL.host ?? "Web",
            runtime: "Web",
            pointSize: preferredViewport,
            scaleFactor: 1.0
        )
        continuation.yield(.simulatorReady(pseudoSim))

        let driver = WebDriver(
            controller: controller,
            startURL: startURL,
            viewport: preferredViewport
        )
        // Publish the driver so the live mirror can call `resize` when
        // the canvas dimensions change.
        await MainActor.run { LiveWebMirror.activeDriver = driver }

        // Hold the controller alive for the run duration via a small
        // wrapper. RunSession stores `any UXDriving`; the controller
        // is owned by the driver, which the session retains.
        return RunSession(
            kind: .web,
            driver: driver,
            pointSize: preferredViewport,
            bundleIdentifier: nil,
            appBundleURL: nil,
            displayLabel: startURL.host ?? "Web"
        )
    }

    func teardown(_ session: RunSession) async {
        await MainActor.run { LiveWebMirror.activeDriver = nil }
        // Close the WebView's hosting window.
        if let driver = session.driver as? WebDriver {
            await driver.closeUnderlyingWindow()
        }
    }

    func toolDefinitions(cacheControl: Bool) -> [[String: Any]] {
        ToolSchema.webToolDefinitions(cacheControl: cacheControl)
    }

    func toolNames() -> [String] { ToolSchema.webToolNames }

    func systemPromptContext(deviceLabel: String) async throws -> String {
        if let library = services.promptLibrary as? PromptLibrary {
            if let bundleURL = library.bundle.url(forResource: "web", withExtension: "md", subdirectory: "PROMPTS/platforms"),
               let text = try? String(contentsOf: bundleURL, encoding: .utf8) {
                return text
            }
        }
        return Self.fallbackContext
    }

    private static let fallbackContext = """
    OVERRIDE — PLATFORM CONTEXT.

    You are testing a web application running in an embedded browser. Coordinates are in CSS pixels (top-left origin within the viewport).

    What you can do:
    - tap (left click), double_tap, right_click on any element.
    - type into the focused field.
    - key_shortcut for page-level keyboard shortcuts (browser-chrome shortcuts like Cmd+L don't work — that's a runtime limit, not a UX problem).
    - scroll inside scrollable regions.
    - navigate to a new URL, browser back / forward / refresh.

    There is no native menu bar to interact with — everything in scope is on the page.
    """
}

enum WebPlatformAdapterError: Error, Sendable, LocalizedError {
    case missingStartURL

    var errorDescription: String? {
        switch self {
        case .missingStartURL:
            return "Web Application is missing a start URL. Edit the Application and set 'Start URL'."
        }
    }
}

