//
//  UISessionSupervisorTests.swift
//  HarnessTests
//
//  Covers the step-level UI session registry (`UISessionSupervisor`) end
//  to end against a fake `UXDriving` / preparer — no WebKit, no xcodebuild:
//  lifecycle (start/observe/act/end), concurrency cap, idle teardown,
//  relative-artifact_dir rejection, macOS acceptance + target validation +
//  start-timeout default + teardown-terminates policy, artifact writing
//  (CLEAN PNG + jsonl rows, marked image never on disk), tool-arg
//  validation/mapping, and the cross-repo tool-name + schema contract.
//

import Testing
import Foundation
import CoreGraphics
@testable import Harness
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Fakes

/// Records teardown calls from the fake adapter.
private actor TeardownProbe {
    private(set) var teardownCount = 0
    func recordTeardown() { teardownCount += 1 }
}

/// Fake driver: writes the CLEAN bytes to disk on capture, returns
/// configurable marked bytes + annotation, and records executed tool calls.
private actor FakeUXDriver: UXDriving {
    let pointSize: CGSize
    let pixelSize: CGSize
    let cleanPNG: Data
    let markedPNG: Data?
    let annotation: String?
    let execDetail: String?
    /// Structured marks the fake driver reports alongside the annotation.
    /// Defaulted so the pre-existing tests are untouched.
    let marks: [InteractiveMark]
    /// Visible page text the fake driver reports (web-shaped drivers only).
    let pageText: String?
    /// The (already-redacted) frame URL a web-shaped driver reports.
    let frameURL: String?
    private(set) var executed: [ToolCall] = []
    var executeError: (any Error)?

    init(
        pointSize: CGSize,
        pixelSize: CGSize,
        cleanPNG: Data,
        markedPNG: Data?,
        annotation: String?,
        execDetail: String?,
        marks: [InteractiveMark] = [],
        pageText: String? = nil,
        frameURL: String? = nil
    ) {
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        self.cleanPNG = cleanPNG
        self.markedPNG = markedPNG
        self.annotation = annotation
        self.execDetail = execDetail
        self.marks = marks
        self.pageText = pageText
        self.frameURL = frameURL
    }

    func screenshot(into url: URL) async throws -> ScreenshotMetadata {
        try cleanPNG.write(to: url, options: .atomic)   // driver writes the CLEAN frame
        return ScreenshotMetadata(
            pixelSize: pixelSize,
            pointSize: pointSize,
            markedImageData: markedPNG,
            markedAnnotationText: annotation,
            marks: marks,
            pageText: pageText,
            frameURL: frameURL
        )
    }

    func execute(_ call: ToolCall) async throws {
        if let executeError { throw executeError }
        executed.append(call)
    }

    func setExecuteError(_ error: (any Error)?) { executeError = error }

    func relaunchForNewLeg() async throws {}
    func lastExecutionDetail() async -> String? { execDetail }
}

/// Fake adapter — only `toolNames()` + `teardown` matter to the supervisor.
private struct FakePlatformAdapter: PlatformAdapter {
    let kind: PlatformKind
    let names: [String]
    let probe: TeardownProbe

    func prepare(
        _ request: RunRequest,
        runID: UUID,
        continuation: AsyncThrowingStream<RunEvent, any Error>.Continuation
    ) async throws -> RunSession {
        throw UISessionError.prepareFailed("FakePlatformAdapter.prepare should not be called")
    }
    func teardown(_ session: RunSession) async { await probe.recordTeardown() }
    func toolDefinitions(cacheControl: Bool) -> [[String: Any]] { [] }
    func toolNames() -> [String] { names }
    func systemPromptContext(deviceLabel: String) async throws -> String { "" }
}

/// Closure-backed preparer so each test builds exactly the session it wants.
private struct FakeUISessionPreparer: UISessionPreparing {
    let build: @Sendable (UISessionConfig, UUID) async throws -> PreparedUISession
    func prepare(_ config: UISessionConfig, sessionID: UUID) async throws -> PreparedUISession {
        try await build(config, sessionID)
    }
}

// MARK: - Helpers

private enum UISessionTestSupport {

    static func solidPNG(width: Int, height: Int, color: NSColor) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func pixelDimensions(_ data: Data) -> (Int, Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    /// Center-pixel color of a PNG, in sRGB.
    static func centerColor(_ data: Data) -> NSColor? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
            .usingColorSpace(.sRGB)
    }

    static func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uisession-test-\(UUID().uuidString)", isDirectory: true)
    }

    /// A per-test default artifact root (temp dir) for sessions started
    /// WITHOUT an explicit `artifact_dir`. Injected into every supervisor so
    /// a suite run never litters the real `~/Library/Application Support/
    /// Harness/runs/ui-sessions/`. Cleaned up by the caller's `defer`.
    static func tempArtifactRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uisession-artifacts-\(UUID().uuidString)", isDirectory: true)
    }

    /// A preparer whose sessions all share one driver + adapter + probe.
    static func preparer(
        platform: PlatformKind,
        label: String,
        driver: FakeUXDriver,
        pointSize: CGSize,
        adapter: FakePlatformAdapter
    ) -> FakeUISessionPreparer {
        FakeUISessionPreparer { _, _ in
            let session = RunSession(
                kind: platform, driver: driver, pointSize: pointSize,
                bundleIdentifier: nil, appBundleURL: nil, displayLabel: label,
                credentialLabel: nil, credentialUsername: nil
            )
            return PreparedUISession(session: session, adapter: adapter)
        }
    }
}

// MARK: - Lifecycle

@Suite("UISessionSupervisor — lifecycle")
struct UISessionLifecycleTests {

    @Test("start → observe (marked) → act → observe → end drives the fake driver and writes CLEAN artifacts")
    func fullLifecycle() async throws {
        let dir = UISessionTestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clean = UISessionTestSupport.solidPNG(width: 100, height: 100, color: .red)
        let marked = UISessionTestSupport.solidPNG(width: 100, height: 100, color: .green)
        let annotation = "MARKS — you MUST call tap_mark(id):\n  1 → \"Submit\" (button)"
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 100, height: 100),
            pixelSize: CGSize(width: 100, height: 100),
            cleanPNG: clean, markedPNG: marked,
            annotation: annotation, execDetail: "scrolled 0 → 100 (12%)"
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let sup = UISessionSupervisor(
            preparer: UISessionTestSupport.preparer(
                platform: .web, label: "example.com", driver: driver,
                pointSize: CGSize(width: 100, height: 100), adapter: adapter
            ),
            defaultArtifactRoot: artifactRoot
        )

        // start
        let info = try await sup.start(UISessionConfig(
            platform: .web, artifactDirPath: dir.path, webURL: "https://example.com",
            viewportWidth: 100, viewportHeight: 100
        ))
        #expect(info.platform == .web)
        #expect(info.displayLabel == "example.com")
        #expect(info.pointSize == CGSize(width: 100, height: 100))
        #expect(info.idleSeconds == 0)

        // observe (marked)
        let obs1 = try await sup.observe(id: info.id, clean: false)
        #expect(obs1.imageIsMarked)
        #expect(obs1.markCount == 1)
        #expect(obs1.markTable == annotation)
        #expect(obs1.screenshotRef == "steps/001.png")
        #expect(obs1.lastExecutionDetail == nil)   // plain observe has no action detail
        // Returned image is the MARKED frame (green center).
        let c1 = UISessionTestSupport.centerColor(obs1.imageData)
        #expect((c1?.greenComponent ?? 0) > (c1?.redComponent ?? 1) + 0.3)

        // CLEAN frame on disk equals the driver's clean bytes; marked never written.
        let disk1 = dir.appendingPathComponent("steps/001.png")
        #expect(FileManager.default.fileExists(atPath: disk1.path))
        #expect(try Data(contentsOf: disk1) == clean)
        let markedSibling = dir.appendingPathComponent("steps/001.marked.png")
        #expect(!FileManager.default.fileExists(atPath: markedSibling.path))

        // act: tap_mark(1) reaches the driver as .tapMark(1); auto-observe increments the step.
        let obs2 = try await sup.act(id: info.id, tool: "tap_mark", inputData: Data(#"{"id":1}"#.utf8))
        #expect(obs2.screenshotRef == "steps/002.png")
        #expect(obs2.lastExecutionDetail == "scrolled 0 → 100 (12%)")
        let calls = await driver.executed
        #expect(calls.count == 1)
        #expect(calls.first?.tool == .tapMark)
        if case .tapMark(let mid) = calls.first?.input { #expect(mid == 1) } else { Issue.record("expected .tapMark") }

        // observe clean → unmarked red frame
        let obs3 = try await sup.observe(id: info.id, clean: true)
        #expect(!obs3.imageIsMarked)
        #expect(obs3.screenshotRef == "steps/003.png")
        let c3 = UISessionTestSupport.centerColor(obs3.imageData)
        #expect((c3?.redComponent ?? 0) > (c3?.greenComponent ?? 1) + 0.3)

        // steps.jsonl has one row per observation (3), each valid JSON.
        let jsonlURL = dir.appendingPathComponent("steps.jsonl")
        let lines = try String(contentsOf: jsonlURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        let row2 = try #require(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(row2["tool"] as? String == "tap_mark")
        #expect(row2["screenshot"] as? String == "steps/002.png")

        // list shows one session.
        let open = await sup.list()
        #expect(open.count == 1)
        #expect(open.first?.id == info.id)

        // end is idempotent; teardown runs exactly once.
        let end1 = await sup.end(id: info.id)
        #expect(end1.wasOpen)
        #expect(await sup.list().isEmpty)
        let end2 = await sup.end(id: info.id)
        #expect(!end2.wasOpen)
        #expect(end2.message == "already closed")
        #expect(await probe.teardownCount == 1)
    }

    @Test("observe downscales the returned image to point size (pixel 120×60 → point 60×30)")
    func downscaleToPointSize() async throws {
        let dir = UISessionTestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clean = UISessionTestSupport.solidPNG(width: 120, height: 60, color: .red)
        let marked = UISessionTestSupport.solidPNG(width: 120, height: 60, color: .green)
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 60, height: 30),
            pixelSize: CGSize(width: 120, height: 60),
            cleanPNG: clean, markedPNG: marked, annotation: nil, execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .web, label: "web", driver: driver,
            pointSize: CGSize(width: 60, height: 30), adapter: adapter
        ), defaultArtifactRoot: artifactRoot)
        let info = try await sup.start(UISessionConfig(
            platform: .web, artifactDirPath: dir.path, webURL: "https://x.example",
            viewportWidth: 60, viewportHeight: 30
        ))
        let obs = try await sup.observe(id: info.id, clean: false)
        let dims = UISessionTestSupport.pixelDimensions(obs.imageData)
        #expect(dims?.0 == 60)
        #expect(dims?.1 == 30)
        // No marks → markTable nil, and the helper note stands in on the MCP side.
        #expect(obs.markTable == nil)
        #expect(obs.markCount == 0)
        _ = await sup.end(id: info.id)
    }

    @Test("no artifact_dir → CLEAN frame lands under the default artifact root (per-session subdir)")
    func tempArtifactRoot() async throws {
        let clean = UISessionTestSupport.solidPNG(width: 40, height: 40, color: .blue)
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 40, height: 40), pixelSize: CGSize(width: 40, height: 40),
            cleanPNG: clean, markedPNG: nil, annotation: nil, execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
        // Inject a temp default root: proves the fallback resolves to
        // <defaultArtifactRoot>/<id>, and keeps the frame out of the real
        // Application Support runs dir. (Production nil → <runs>/ui-sessions.)
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .web, label: "web", driver: driver,
            pointSize: CGSize(width: 40, height: 40), adapter: adapter
        ), defaultArtifactRoot: artifactRoot)
        let info = try await sup.start(UISessionConfig(platform: .web, webURL: "https://x.example",
                                                       viewportWidth: 40, viewportHeight: 40))
        let expectedRoot = artifactRoot
            .appendingPathComponent(info.id.uuidString, isDirectory: true)

        _ = try await sup.observe(id: info.id, clean: false)
        let diskURL = expectedRoot.appendingPathComponent("steps/001.png")
        #expect(FileManager.default.fileExists(atPath: diskURL.path))
        _ = await sup.end(id: info.id)
    }
}

// MARK: - Guards (cap / validation / rejection)

@Suite("UISessionSupervisor — guards")
struct UISessionGuardTests {

    private func webSupervisor(
        cap probe: TeardownProbe = TeardownProbe(),
        artifactRoot: URL = UISessionTestSupport.tempArtifactRoot()
    ) -> UISessionSupervisor {
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 50, height: 50), pixelSize: CGSize(width: 50, height: 50),
            cleanPNG: UISessionTestSupport.solidPNG(width: 50, height: 50, color: .gray),
            markedPNG: nil, annotation: nil, execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
        // Fresh probe/driver per prepare isn't needed for these guards.
        return UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .web, label: "web", driver: driver,
            pointSize: CGSize(width: 50, height: 50), adapter: adapter
        ), defaultArtifactRoot: artifactRoot)
    }

    @Test("concurrent-session cap of 2 is enforced")
    func capEnforced() async throws {
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let sup = webSupervisor(artifactRoot: artifactRoot)
        _ = try await sup.start(UISessionConfig(platform: .web, webURL: "https://a.example"))
        _ = try await sup.start(UISessionConfig(platform: .web, webURL: "https://b.example"))
        await #expect(throws: UISessionError.self) {
            _ = try await sup.start(UISessionConfig(platform: .web, webURL: "https://c.example"))
        }
        #expect(await sup.list().count == 2)
        await sup.shutdownAll()
    }

    @Test("concurrent starts can't overshoot the cap across the prepare await")
    func concurrentStartsRespectCap() async throws {
        let probe = TeardownProbe()
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        // Preparer sleeps so the three starts overlap at the prepare await —
        // without the pending-start reservation, all three would slip past
        // the cap check (which straddles the await).
        let sup = UISessionSupervisor(preparer: FakeUISessionPreparer { _, _ in
            try await Task.sleep(for: .milliseconds(60))
            let driver = FakeUXDriver(
                pointSize: CGSize(width: 20, height: 20), pixelSize: CGSize(width: 20, height: 20),
                cleanPNG: UISessionTestSupport.solidPNG(width: 20, height: 20, color: .gray),
                markedPNG: nil, annotation: nil, execDetail: nil
            )
            let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
            let session = RunSession(
                kind: .web, driver: driver, pointSize: CGSize(width: 20, height: 20),
                bundleIdentifier: nil, appBundleURL: nil, displayLabel: "web",
                credentialLabel: nil, credentialUsername: nil
            )
            return PreparedUISession(session: session, adapter: adapter)
        }, defaultArtifactRoot: artifactRoot)
        async let a = try? sup.start(UISessionConfig(platform: .web, webURL: "https://a.example"))
        async let b = try? sup.start(UISessionConfig(platform: .web, webURL: "https://b.example"))
        async let c = try? sup.start(UISessionConfig(platform: .web, webURL: "https://c.example"))
        let results = await [a, b, c]
        #expect(results.compactMap { $0 }.count == 2)   // exactly two admitted
        #expect(await sup.list().count == 2)
        await sup.shutdownAll()
    }

    @Test("relative artifact_dir is rejected")
    func relativeArtifactDirRejected() async {
        let sup = webSupervisor()
        await #expect(throws: UISessionError.self) {
            _ = try await sup.start(UISessionConfig(
                platform: .web, artifactDirPath: "relative/evidence",
                webURL: "https://a.example"
            ))
        }
    }

    @Test("macOS is no longer deferred — an app_path session starts and drives the fake driver")
    func macosAccepted() async throws {
        let dir = UISessionTestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 1280, height: 800), pixelSize: CGSize(width: 1280, height: 800),
            cleanPNG: UISessionTestSupport.solidPNG(width: 40, height: 40, color: .gray),
            markedPNG: nil, annotation: nil, execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .macosApp, names: ToolSchema.macOSToolNames, probe: probe)
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .macosApp, label: "MyMacApp", driver: driver,
            pointSize: CGSize(width: 1280, height: 800), adapter: adapter
        ), defaultArtifactRoot: artifactRoot)
        // Prebuilt app_path (absolute) — the preferred QA flow — is accepted.
        let info = try await sup.start(UISessionConfig(
            platform: .macosApp, artifactDirPath: dir.path,
            macAppPath: "/tmp/MyMacApp.app"
        ))
        #expect(info.platform == .macosApp)
        #expect(info.displayLabel == "MyMacApp")
        // Ending the session tears the adapter down exactly once (the real
        // adapter's teardown quits the SUT — see MacOSAdapterTeardownTests).
        let end = await sup.end(id: info.id)
        #expect(end.wasOpen)
        #expect(await probe.teardownCount == 1)
    }

    @Test("macOS project_path + scheme (build-from-source) is also accepted")
    func macosProjectSchemeAccepted() async throws {
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 800, height: 600), pixelSize: CGSize(width: 800, height: 600),
            cleanPNG: UISessionTestSupport.solidPNG(width: 20, height: 20, color: .gray),
            markedPNG: nil, annotation: nil, execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .macosApp, names: ToolSchema.macOSToolNames, probe: probe)
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .macosApp, label: "Built", driver: driver,
            pointSize: CGSize(width: 800, height: 600), adapter: adapter
        ), defaultArtifactRoot: artifactRoot)
        let info = try await sup.start(UISessionConfig(
            platform: .macosApp,
            macProjectPath: "/abs/App.xcodeproj", macScheme: "App"
        ))
        #expect(info.platform == .macosApp)
        await sup.shutdownAll()
    }

    @Test("macOS with neither app_path nor project+scheme is rejected before prepare")
    func macosMissingTarget() async {
        let sup = webSupervisor()
        await #expect(throws: UISessionError.self) {
            _ = try await sup.start(UISessionConfig(platform: .macosApp))
        }
        // project_path without a scheme is still insufficient.
        await #expect(throws: UISessionError.self) {
            _ = try await sup.start(UISessionConfig(platform: .macosApp, macProjectPath: "/abs/App.xcodeproj"))
        }
    }

    @Test("macOS app_path must be absolute")
    func macosRelativeAppPathRejected() async {
        let sup = webSupervisor()
        await #expect(throws: UISessionError.self) {
            _ = try await sup.start(UISessionConfig(platform: .macosApp, macAppPath: "relative/MyApp.app"))
        }
    }

    @Test("web without a url is rejected before prepare")
    func webMissingURL() async {
        let sup = webSupervisor()
        await #expect(throws: UISessionError.self) {
            _ = try await sup.start(UISessionConfig(platform: .web))
        }
    }

    @Test("act on an unknown session id throws sessionNotFound")
    func actUnknownSession() async {
        let sup = webSupervisor()
        await #expect(throws: UISessionError.self) {
            _ = try await sup.act(id: UUID(), tool: "tap_mark", inputData: Data(#"{"id":1}"#.utf8))
        }
    }

    @Test("end on an unknown session id is a calm success")
    func endUnknownSession() async {
        let sup = webSupervisor()
        let result = await sup.end(id: UUID())
        #expect(!result.wasOpen)
        #expect(result.message == "already closed")
    }

    // MARK: - W32: a session that DIED reads differently from one that never was

    @Test("observing an id that was never a session says exactly that")
    func unknownIDIsNamedAsUnknown() async {
        let sup = webSupervisor()
        let id = UUID()
        do {
            _ = try await sup.observe(id: id, clean: false)
            Issue.record("expected a throw")
        } catch let error as UISessionError {
            guard case .sessionNotFound = error else {
                Issue.record("expected sessionNotFound, got \(error)")
                return
            }
            let message = error.errorDescription ?? ""
            #expect(message.contains("has ever been open"))
            // The engine-child case: a caller holding an id from before a
            // harness-mcp restart needs to be told the process is the reason.
            #expect(message.contains("harness-mcp restarted"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("observing a session that was ENDED names the closure, not a missing id")
    func endedSessionIsNamedAsEnded() async throws {
        let sup = try await UISessionGuardTests.startedWebSupervisor()
        let id = try #require(await sup.list().first?.id)
        _ = await sup.end(id: id)
        do {
            _ = try await sup.observe(id: id, clean: false)
            Issue.record("expected a throw")
        } catch let error as UISessionError {
            guard case .sessionEnded(let endedID, let reason, _) = error else {
                Issue.record("expected sessionEnded, got \(error)")
                return
            }
            #expect(endedID == id)
            #expect(reason == "end_ui_session")
            #expect((error.errorDescription ?? "").contains("closed"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("a session reclaimed by the idle watchdog says the watchdog took it")
    func sweptSessionNamesTheWatchdog() async throws {
        let sup = try await UISessionGuardTests.startedWebSupervisor(idleTimeoutSeconds: 600)
        let id = try #require(await sup.list().first?.id)
        _ = await sup.sweepIdle(now: Date().addingTimeInterval(700))
        do {
            _ = try await sup.act(id: id, tool: "tap_mark", inputData: Data(#"{"id":1}"#.utf8))
            Issue.record("expected a throw")
        } catch let error as UISessionError {
            guard case .sessionEnded(_, let reason, _) = error else {
                Issue.record("expected sessionEnded, got \(error)")
                return
            }
            #expect(reason.contains("idle watchdog"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// A supervisor with one live fake web session, for the death-vs-absence
    /// tests above.
    static func startedWebSupervisor(idleTimeoutSeconds: Int = 0) async throws -> UISessionSupervisor {
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 30, height: 30), pixelSize: CGSize(width: 30, height: 30),
            cleanPNG: UISessionTestSupport.solidPNG(width: 30, height: 30, color: .black),
            markedPNG: nil, annotation: nil, execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: TeardownProbe())
        let sup = UISessionSupervisor(
            preparer: UISessionTestSupport.preparer(
                platform: .web, label: "web", driver: driver,
                pointSize: CGSize(width: 30, height: 30), adapter: adapter
            ),
            idleTimeoutSeconds: idleTimeoutSeconds,
            defaultArtifactRoot: UISessionTestSupport.tempArtifactRoot()
        )
        _ = try await sup.start(UISessionConfig(platform: .web, webURL: "https://a.example"))
        return sup
    }
}

// MARK: - Idle teardown (deterministic)

@Suite("UISessionSupervisor — idle teardown")
struct UISessionIdleTests {

    @Test("sweepIdle tears down a session idle past the timeout, and leaves a fresh one")
    func idleSweep() async throws {
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 30, height: 30), pixelSize: CGSize(width: 30, height: 30),
            cleanPNG: UISessionTestSupport.solidPNG(width: 30, height: 30, color: .black),
            markedPNG: nil, annotation: nil, execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let sup = UISessionSupervisor(
            preparer: UISessionTestSupport.preparer(
                platform: .web, label: "web", driver: driver,
                pointSize: CGSize(width: 30, height: 30), adapter: adapter
            ),
            idleTimeoutSeconds: 600,
            defaultArtifactRoot: artifactRoot
        )
        let info = try await sup.start(UISessionConfig(platform: .web, webURL: "https://a.example"))

        // Not yet idle → no teardown.
        let none = await sup.sweepIdle(now: Date())
        #expect(none.isEmpty)
        #expect(await sup.list().count == 1)

        // 700s later → idle past 600 → torn down exactly once.
        let torn = await sup.sweepIdle(now: Date().addingTimeInterval(700))
        #expect(torn == [info.id])
        #expect(await sup.list().isEmpty)
        #expect(await probe.teardownCount == 1)
    }

    @Test("idleTimeoutSeconds == 0 disables the sweeper")
    func idleDisabled() async throws {
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 30, height: 30), pixelSize: CGSize(width: 30, height: 30),
            cleanPNG: UISessionTestSupport.solidPNG(width: 30, height: 30, color: .black),
            markedPNG: nil, annotation: nil, execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let sup = UISessionSupervisor(
            preparer: UISessionTestSupport.preparer(
                platform: .web, label: "web", driver: driver,
                pointSize: CGSize(width: 30, height: 30), adapter: adapter
            ),
            idleTimeoutSeconds: 0,
            defaultArtifactRoot: artifactRoot
        )
        _ = try await sup.start(UISessionConfig(platform: .web, webURL: "https://a.example"))
        let torn = await sup.sweepIdle(now: Date().addingTimeInterval(100_000))
        #expect(torn.isEmpty)
        #expect(await sup.list().count == 1)
        await sup.shutdownAll()
    }
}

// MARK: - Tool-arg validation + mapping

@Suite("UISessionSupervisor — act_ui tool validation & mapping")
struct UISessionActMappingTests {

    /// Returns the temp artifact root as the last tuple element so the
    /// caller can `defer`-clean it — keeps started sessions out of the real
    /// Application Support runs dir.
    private func webSession() async throws -> (UISessionSupervisor, UUID, FakeUXDriver, URL) {
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 80, height: 80), pixelSize: CGSize(width: 80, height: 80),
            cleanPNG: UISessionTestSupport.solidPNG(width: 80, height: 80, color: .white),
            markedPNG: UISessionTestSupport.solidPNG(width: 80, height: 80, color: .green),
            annotation: "MARKS:\n  1 → \"x\" (button)", execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .web, label: "web", driver: driver,
            pointSize: CGSize(width: 80, height: 80), adapter: adapter
        ), defaultArtifactRoot: artifactRoot)
        let info = try await sup.start(UISessionConfig(platform: .web, webURL: "https://a.example"))
        return (sup, info.id, driver, artifactRoot)
    }

    @Test("meta tools are rejected by act_ui")
    func metaRejected() async throws {
        let (sup, id, _, artifactRoot) = try await webSession()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        for meta in ["read_screen", "note_friction", "mark_goal_done"] {
            await #expect(throws: UISessionError.self) {
                _ = try await sup.act(id: id, tool: meta, inputData: Data("{}".utf8))
            }
        }
        _ = await sup.end(id: id)
    }

    @Test("a tool not in the platform vocabulary is rejected (swipe on web)")
    func unsupportedRejected() async throws {
        let (sup, id, _, artifactRoot) = try await webSession()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        await #expect(throws: UISessionError.self) {
            _ = try await sup.act(id: id, tool: "swipe",
                                  inputData: Data(#"{"x1":0,"y1":0,"x2":1,"y2":1}"#.utf8))
        }
        _ = await sup.end(id: id)
    }

    @Test("tap_mark / navigate / scroll / type map to the right ToolInput")
    func mapsInputs() async throws {
        let (sup, id, driver, artifactRoot) = try await webSession()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        _ = try await sup.act(id: id, tool: "tap_mark", inputData: Data(#"{"id":7}"#.utf8))
        _ = try await sup.act(id: id, tool: "navigate", inputData: Data(#"{"url":"https://z.example"}"#.utf8))
        _ = try await sup.act(id: id, tool: "scroll", inputData: Data(#"{"x":1,"y":2,"dx":0,"dy":300}"#.utf8))
        _ = try await sup.act(id: id, tool: "type", inputData: Data(#"{"text":"hi"}"#.utf8))

        let calls = await driver.executed
        #expect(calls.count == 4)
        if case .tapMark(let m) = calls[0].input { #expect(m == 7) } else { Issue.record("tap_mark") }
        if case .navigate(let u) = calls[1].input { #expect(u == "https://z.example") } else { Issue.record("navigate") }
        if case .scroll(let x, let y, let dx, let dy) = calls[2].input {
            #expect(x == 1); #expect(y == 2); #expect(dx == 0); #expect(dy == 300)
        } else { Issue.record("scroll") }
        if case .type(let t) = calls[3].input { #expect(t == "hi") } else { Issue.record("type") }
        _ = await sup.end(id: id)
    }

    @Test("scroll_into_view is a web act and reaches the driver as .scrollIntoView")
    func scrollIntoViewMapsAndIsWebOnly() async throws {
        let (sup, id, driver, artifactRoot) = try await webSession()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        _ = try await sup.act(id: id, tool: "scroll_into_view", inputData: Data(#"{"id":4}"#.utf8))
        let calls = await driver.executed
        if case .scrollIntoView(let m) = calls.last?.input {
            #expect(m == 4)
        } else {
            Issue.record("expected .scrollIntoView")
        }
        _ = await sup.end(id: id)
    }

    @Test("scroll_into_view is refused on macOS rather than silently no-oping")
    func scrollIntoViewRejectedOnMac() async throws {
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 80, height: 80), pixelSize: CGSize(width: 80, height: 80),
            cleanPNG: UISessionTestSupport.solidPNG(width: 80, height: 80, color: .white),
            markedPNG: nil, annotation: nil, execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .macosApp, names: ToolSchema.macOSToolNames, probe: probe)
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .macosApp, label: "mac", driver: driver,
            pointSize: CGSize(width: 80, height: 80), adapter: adapter
        ), defaultArtifactRoot: artifactRoot)
        let info = try await sup.start(UISessionConfig(platform: .macosApp, macAppPath: "/tmp/x.app"))
        await #expect(throws: UISessionError.self) {
            _ = try await sup.act(id: info.id, tool: "scroll_into_view", inputData: Data(#"{"id":1}"#.utf8))
        }
        _ = await sup.end(id: info.id)
    }

    @Test("the driver's redacted frame URL reaches the observation and the payload")
    func frameURLReachesTheObservation() async throws {
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 80, height: 80), pixelSize: CGSize(width: 80, height: 80),
            cleanPNG: UISessionTestSupport.solidPNG(width: 80, height: 80, color: .white),
            markedPNG: nil, annotation: nil, execDetail: nil,
            frameURL: "https://drop-help.com/dashboard?…"
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .web, label: "web", driver: driver,
            pointSize: CGSize(width: 80, height: 80), adapter: adapter
        ), defaultArtifactRoot: artifactRoot)
        let info = try await sup.start(UISessionConfig(platform: .web, webURL: "https://drop-help.com"))
        let obs = try await sup.observe(id: info.id, clean: false)
        #expect(obs.frameURL == "https://drop-help.com/dashboard?…")
        let payload = UIObservationPayload.structuredContent(obs)
        #expect(payload["frame_url"] as? String == "https://drop-help.com/dashboard?…")
        _ = await sup.end(id: info.id)
    }

    @Test("a failed driver.execute surfaces actionFailed + the error detail")
    func failedActionSurfaced() async throws {
        let (sup, id, driver, artifactRoot) = try await webSession()
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        await driver.setExecuteError(UISessionError.prepareFailed("boom"))
        let obs = try await sup.act(id: id, tool: "tap_mark", inputData: Data(#"{"id":1}"#.utf8))
        #expect(obs.actionFailed)
        #expect(obs.lastExecutionDetail?.contains("error:") == true)
        _ = await sup.end(id: id)
    }
}

// MARK: - Schema / contract invariants (extends the Tool-Schema test pattern)

@Suite("UI session tool contract")
struct UISessionContractTests {

    @Test("the session tool names are exactly the cross-repo contract")
    func toolNameContract() {
        // The original five are a FROZEN cross-repo contract; the sixth is
        // purely additive (a client that doesn't know it never calls it).
        #expect(Set(UISessionTool.allCases.map(\.rawValue)) == [
            "start_ui_session", "observe_ui", "act_ui", "end_ui_session", "list_ui_sessions",
            "export_ui_session_state"
        ])
    }

    @Test("meta-tool set matches the non-action ToolKinds")
    func metaToolSet() {
        #expect(UIToolPolicy.metaTools == [
            ToolKind.readScreen.rawValue,
            ToolKind.noteFriction.rawValue,
            ToolKind.markGoalDone.rawValue
        ])
    }

    @Test("every non-meta tool each platform advertises maps via LLMShared.toolCall")
    func everyAdvertisedActionToolMaps() throws {
        for names in [ToolSchema.webToolNames, ToolSchema.iOSToolNames, ToolSchema.macOSToolNames] {
            for name in names where !UIToolPolicy.metaTools.contains(name) {
                // Empty input is enough — LLMShared defaults every field.
                let call = try LLMShared.toolCall(name: name, inputData: Data("{}".utf8))
                #expect(call.tool.rawValue == name,
                        "act_ui must be able to map advertised tool '\(name)'")
            }
        }
    }

    @Test("UIToolPolicy.validate rejects meta + off-platform, accepts in-vocab actions")
    func policyValidation() {
        // Meta → rejected.
        #expect(throws: UISessionError.self) {
            try UIToolPolicy.validate(tool: "mark_goal_done", allowed: ToolSchema.webToolNames)
        }
        // Off-platform (swipe is iOS-only) → rejected on web.
        #expect(throws: UISessionError.self) {
            try UIToolPolicy.validate(tool: "swipe", allowed: ToolSchema.webToolNames)
        }
        // In-vocab action → accepted (no throw).
        #expect(throws: Never.self) {
            try UIToolPolicy.validate(tool: "tap_mark", allowed: ToolSchema.webToolNames)
        }
    }
}

// MARK: - Start-timeout defaults (per-platform contract)

@Suite("UISessionSupervisor — start-timeout defaults")
struct UISessionStartTimeoutTests {

    @Test("per-platform start-timeout defaults are web 120 · iOS 900 · macOS 600")
    func defaults() {
        #expect(UISessionSupervisor.defaultStartTimeout(for: .web) == 120)
        #expect(UISessionSupervisor.defaultStartTimeout(for: .iosSimulator) == 900)
        #expect(UISessionSupervisor.defaultStartTimeout(for: .macosApp) == 600)
    }
}

// MARK: - macOS adapter teardown-terminates policy (seam-level, no live app)

// Minimal no-op fakes so `PlatformAdapterServices` can be built for the
// macOS adapter — teardown never touches services, so these are never
// exercised beyond construction.
private struct TeardownNoopKeychain: KeychainStoring {
    func read(service: String, account: String) throws -> Data? { nil }
    func write(_ data: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

private struct TeardownNoopSimulatorDriver: SimulatorDriving {
    func listDevices() async throws -> [SimulatorRef] { [] }
    func boot(_ ref: SimulatorRef) async throws {}
    func install(_ appBundle: URL, on ref: SimulatorRef) async throws {}
    func launch(bundleID: String, on ref: SimulatorRef) async throws {}
    func terminate(bundleID: String, on ref: SimulatorRef) async throws {}
    func erase(_ ref: SimulatorRef) async throws {}
    func screenshot(_ ref: SimulatorRef, into url: URL) async throws -> URL { url }
    func screenshotImage(_ ref: SimulatorRef) async throws -> NSImage { NSImage() }
    func tap(at point: CGPoint, on ref: SimulatorRef) async throws {}
    func doubleTap(at point: CGPoint, on ref: SimulatorRef) async throws {}
    func swipe(from: CGPoint, to: CGPoint, duration: Duration, on ref: SimulatorRef) async throws {}
    func type(_ text: String, on ref: SimulatorRef) async throws {}
    func pressButton(_ button: SimulatorButton, on ref: SimulatorRef) async throws {}
    func startInputSession(_ ref: SimulatorRef) async throws {}
    func endInputSession() async {}
    func cleanupWDA(udid: String) async {}
    func probeInteractiveElements(_ ref: SimulatorRef) async -> [InteractiveMark] { [] }
    func tapMark(id: Int, on ref: SimulatorRef) async throws {}
}

@Suite("MacOSPlatformAdapter — teardown terminates the SUT")
struct MacOSAdapterTeardownTests {

    private func services() throws -> PlatformAdapterServices {
        let processRunner = ProcessRunner()
        return PlatformAdapterServices(
            processRunner: processRunner,
            toolLocator: ToolLocator(processRunner: processRunner),
            xcodeBuilder: XcodeBuilder(processRunner: processRunner, toolLocator: ToolLocator(processRunner: processRunner)),
            simulatorDriver: TeardownNoopSimulatorDriver(),
            promptLibrary: PromptLibrary(),
            keychain: TeardownNoopKeychain(),
            runHistory: try RunHistoryStore.inMemory()
        )
    }

    /// A macOS RunSession whose driver targets a bundle id that is NOT
    /// running, so `terminateApp()` takes its idempotent no-op path — the
    /// policy (does teardown attempt a quit?) is exercised without a live app.
    private func macSession() -> RunSession {
        let bundleID = "com.harness.tests.nonexistent-\(UUID().uuidString)"
        // pid -1 is never a live process, so `terminateApp()` takes its
        // idempotent no-op path (NSRunningApplication(processIdentifier:) → nil).
        let driver = MacAppDriver(bundleIdentifier: bundleID, appBundleURL: nil, processIdentifier: -1)
        return RunSession(
            kind: .macosApp, driver: driver, pointSize: CGSize(width: 100, height: 100),
            bundleIdentifier: bundleID, appBundleURL: nil,
            displayLabel: "Test", credentialLabel: nil, credentialUsername: nil
        )
    }

    @Test("the ui-session preparer's adapter carries terminatesOnTeardown; GUI default is false")
    func flag() throws {
        #expect(try MacOSPlatformAdapter(services: services()).terminatesOnTeardown == false)
        #expect(try MacOSPlatformAdapter(services: services(), terminatesOnTeardown: true).terminatesOnTeardown == true)
    }

    @Test("teardown is a safe no-op when terminatesOnTeardown is false (GUI run leaves the app open)")
    func guiTeardownDoesNotThrow() async throws {
        let adapter = MacOSPlatformAdapter(services: try services(), terminatesOnTeardown: false)
        await adapter.teardown(macSession())   // no crash, no attempt to quit
    }

    @Test("session teardown attempts termination and is idempotent when the app is already gone")
    func sessionTeardownIdempotent() async throws {
        let adapter = MacOSPlatformAdapter(services: try services(), terminatesOnTeardown: true)
        let session = macSession()
        // Two teardowns back-to-back (mirrors end + shutdownAll racing): the
        // driver's terminate → force-terminate machinery no-ops when the
        // bundle id isn't running, so neither call throws or hangs.
        await adapter.teardown(session)
        await adapter.teardown(session)
    }
}

// MARK: - Structured observation (MCP structuredContent source data)

@Suite("UISessionSupervisor — structured marks reach the observation")
struct UISessionStructuredObservationTests {

    private func driverMarks() -> [InteractiveMark] {
        [
            InteractiveMark(id: 1, rect: CGRect(x: 4, y: 8, width: 40, height: 20),
                            role: "button", inputType: nil, label: "Submit"),
            InteractiveMark(id: 2, rect: CGRect(x: 4, y: 40, width: 60, height: 20),
                            role: "a", inputType: nil, label: "Docs")
        ]
    }

    /// Stands up a supervisor over a fake web driver carrying structured
    /// marks + page text. Returns the supervisor and the started session.
    private func startedSession(
        marks: [InteractiveMark],
        pageText: String?,
        dir: URL,
        artifactRoot: URL
    ) async throws -> (UISessionSupervisor, UISessionInfo) {
        let clean = UISessionTestSupport.solidPNG(width: 100, height: 100, color: .red)
        let marked = UISessionTestSupport.solidPNG(width: 100, height: 100, color: .green)
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 100, height: 100),
            pixelSize: CGSize(width: 100, height: 100),
            cleanPNG: clean, markedPNG: marks.isEmpty ? nil : marked,
            annotation: marks.isEmpty ? nil : MarkRenderer.describe(marks),
            execDetail: nil,
            marks: marks,
            pageText: pageText
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: TeardownProbe())
        let sup = UISessionSupervisor(
            preparer: UISessionTestSupport.preparer(
                platform: .web, label: "example.com", driver: driver,
                pointSize: CGSize(width: 100, height: 100), adapter: adapter
            ),
            defaultArtifactRoot: artifactRoot
        )
        let info = try await sup.start(UISessionConfig(
            platform: .web, artifactDirPath: dir.path, webURL: "https://example.com",
            viewportWidth: 100, viewportHeight: 100
        ))
        return (sup, info)
    }

    @Test("observe carries the driver's marks and page text through to the observation")
    func observeCarriesStructuredData() async throws {
        let dir = UISessionTestSupport.tempDir()
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: artifactRoot)
        }
        let marks = driverMarks()
        let (sup, info) = try await startedSession(
            marks: marks, pageText: "Submit\nDocs", dir: dir, artifactRoot: artifactRoot
        )

        let obs = try await sup.observe(id: info.id, clean: false)
        #expect(obs.marks == marks)
        #expect(obs.markCount == 2)
        #expect(obs.pageText == "Submit\nDocs")

        // …and the encoded MCP payload agrees with the prose table's ids.
        let payload = UIObservationPayload.structuredContent(obs)
        let encoded = try #require(payload["marks"] as? [[String: Any]])
        #expect(encoded.map { $0["id"] as? Int } == [1, 2])
        #expect(encoded.first?["label"] as? String == "Submit")
        #expect(payload["page_text"] as? String == "Submit\nDocs")

        await sup.shutdownAll()
    }

    @Test("act's auto-observe carries the same structured data as observe")
    func actCarriesStructuredData() async throws {
        let dir = UISessionTestSupport.tempDir()
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: artifactRoot)
        }
        let marks = driverMarks()
        let (sup, info) = try await startedSession(
            marks: marks, pageText: "Submit\nDocs", dir: dir, artifactRoot: artifactRoot
        )

        let obs = try await sup.act(id: info.id, tool: "tap_mark", inputData: Data(#"{"id":1}"#.utf8))
        #expect(obs.marks == marks)
        #expect(obs.pageText == "Submit\nDocs")
        #expect(UIObservationPayload.structuredContent(obs)["step"] as? Int == obs.stepIndex)

        await sup.shutdownAll()
    }

    @Test("a driver with no marks and no page text yields an empty, still-valid payload")
    func noMarksNoText() async throws {
        let dir = UISessionTestSupport.tempDir()
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: artifactRoot)
        }
        let (sup, info) = try await startedSession(
            marks: [], pageText: nil, dir: dir, artifactRoot: artifactRoot
        )

        let obs = try await sup.observe(id: info.id, clean: false)
        #expect(obs.marks.isEmpty)
        #expect(obs.markCount == 0)
        #expect(obs.pageText == nil)

        let payload = UIObservationPayload.structuredContent(obs)
        #expect((payload["marks"] as? [[String: Any]])?.isEmpty == true)
        #expect(payload["page_text"] == nil)
        // Still serializable — the empty case must not produce a broken result.
        #expect(JSONSerialization.isValidJSONObject(payload))

        await sup.shutdownAll()
    }

    @Test("mark count falls back to the prose table when a driver supplies no structured marks")
    func markCountFallback() async throws {
        // Guards the pre-existing contract: a driver that only fills
        // `markedAnnotationText` (older shape) still reports a mark count.
        let dir = UISessionTestSupport.tempDir()
        let artifactRoot = UISessionTestSupport.tempArtifactRoot()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: artifactRoot)
        }
        let clean = UISessionTestSupport.solidPNG(width: 100, height: 100, color: .red)
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 100, height: 100),
            pixelSize: CGSize(width: 100, height: 100),
            cleanPNG: clean, markedPNG: nil,
            annotation: "MARKS —\n  1 → \"Submit\" (button)\n  2 → \"Docs\" (a)",
            execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: TeardownProbe())
        let sup = UISessionSupervisor(
            preparer: UISessionTestSupport.preparer(
                platform: .web, label: "example.com", driver: driver,
                pointSize: CGSize(width: 100, height: 100), adapter: adapter
            ),
            defaultArtifactRoot: artifactRoot
        )
        let info = try await sup.start(UISessionConfig(
            platform: .web, artifactDirPath: dir.path, webURL: "https://example.com",
            viewportWidth: 100, viewportHeight: 100
        ))
        let obs = try await sup.observe(id: info.id, clean: false)
        #expect(obs.markCount == 2)
        #expect(obs.marks.isEmpty)

        await sup.shutdownAll()
    }
}

#if canImport(AppKit)
@Suite("MacAppDriver — SUT window resolution binds to the launched pid")
struct MacAppDriverPidScopingTests {

    /// Build a CGWindowList-shaped row the way `selectFrontWindow` reads it.
    private func windowRow(ownerPID: Int, windowNumber: Int, w: CGFloat, h: CGFloat) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowNumber as String: windowNumber,
            kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": w, "Height": h] as [String: CGFloat]
        ]
    }

    @Test("picks the window owned by the launched pid, ignoring a same-bundle-id stranger's window")
    func picksOwnPidOverStranger() {
        let sutPID: pid_t = 4242
        let strangerPID = 9999   // the developer's own copy of the same app
        // Stranger's window is listed FIRST (topmost) — a bundle-id match would
        // wrongly grab it; a pid match must skip past it to the SUT's window.
        let rows: [[String: Any]] = [
            windowRow(ownerPID: strangerPID, windowNumber: 1, w: 800, h: 600),
            windowRow(ownerPID: Int(sutPID), windowNumber: 2, w: 640, h: 480)
        ]
        let info = MacAppDriver.selectFrontWindow(rows: rows, pid: sutPID)
        #expect(info?.ownerPID == Int(sutPID))
        #expect(info?.windowNumber == 2)
    }

    @Test("returns nil when only a same-bundle-id stranger has a window (SUT has none)")
    func nilWhenOnlyStrangerHasWindow() {
        let rows = [windowRow(ownerPID: 9999, windowNumber: 1, w: 800, h: 600)]
        #expect(MacAppDriver.selectFrontWindow(rows: rows, pid: 4242) == nil)
    }

    @Test("rejects sub-threshold (chrome/shadow) windows owned by the launched pid")
    func rejectsTinyWindows() {
        let sutPID: pid_t = 4242
        let rows = [windowRow(ownerPID: Int(sutPID), windowNumber: 7, w: 20, h: 20)]
        #expect(MacAppDriver.selectFrontWindow(rows: rows, pid: sutPID) == nil)
    }
}
#endif

// MARK: - Session-state injection / export (web-only capabilities)

@Suite("UISessionSupervisor — session state")
struct UISessionStateCapabilityTests {

    private static let secret = "COOKIE-VALUE-THAT-MUST-NEVER-BE-LOGGED"

    private static func webState() -> WebSessionState {
        WebSessionState(cookies: [
            WebSessionCookie(name: "sid", value: secret, domain: ".example.com")
        ])
    }

    /// A supervisor whose preparer records the config it was handed, so we
    /// can assert the state actually reaches the adapter layer.
    private static func supervisor(
        platform: PlatformKind,
        seen: ConfigProbe,
        root: URL
    ) -> UISessionSupervisor {
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 10, height: 10),
            pixelSize: CGSize(width: 10, height: 10),
            cleanPNG: UISessionTestSupport.solidPNG(width: 10, height: 10, color: .red),
            markedPNG: nil, annotation: nil, execDetail: nil
        )
        let names: [String] = {
            switch platform {
            case .web:          return ToolSchema.webToolNames
            case .iosSimulator: return ToolSchema.iOSToolNames
            case .macosApp:     return ToolSchema.macOSToolNames
            }
        }()
        let adapter = FakePlatformAdapter(kind: platform, names: names, probe: probe)
        let preparer = FakeUISessionPreparer { config, _ in
            await seen.record(config)
            let session = RunSession(
                kind: platform, driver: driver, pointSize: CGSize(width: 10, height: 10),
                bundleIdentifier: nil, appBundleURL: nil, displayLabel: "fake",
                credentialLabel: nil, credentialUsername: nil
            )
            return PreparedUISession(session: session, adapter: adapter)
        }
        return UISessionSupervisor(preparer: preparer, idleTimeoutSeconds: 0, defaultArtifactRoot: root)
    }

    @Test("session_state reaches the preparer untouched for a web session")
    func webSessionStateReachesPreparer() async throws {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = ConfigProbe()
        let sup = Self.supervisor(platform: .web, seen: seen, root: root)

        let info = try await sup.start(UISessionConfig(
            platform: .web, webURL: "https://example.com",
            webSessionState: Self.webState(), webVisible: true
        ))
        let config = try #require(await seen.last)
        #expect(config.webSessionState?.cookies.first?.value == Self.secret)
        #expect(config.webVisible)
        _ = await sup.end(id: info.id)
    }

    @Test("a web session started WITHOUT session_state stays a fresh user")
    func freshUserByDefault() async throws {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = ConfigProbe()
        let sup = Self.supervisor(platform: .web, seen: seen, root: root)

        let info = try await sup.start(UISessionConfig(platform: .web, webURL: "https://example.com"))
        let config = try #require(await seen.last)
        #expect(config.webSessionState == nil, "the fresh-user invariant must be the default")
        #expect(!config.webVisible)
        _ = await sup.end(id: info.id)
    }

    @Test("session_state on a native platform is rejected, not silently dropped")
    func nativeRejectsSessionState() async {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = ConfigProbe()
        let sup = Self.supervisor(platform: .macosApp, seen: seen, root: root)

        await #expect(throws: UISessionError.self) {
            _ = try await sup.start(UISessionConfig(
                platform: .macosApp, webSessionState: Self.webState(),
                macAppPath: "/tmp/Fake.app"
            ))
        }
    }

    @Test("visible:true on a native platform is rejected")
    func nativeRejectsVisible() async {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = ConfigProbe()
        let sup = Self.supervisor(platform: .macosApp, seen: seen, root: root)

        await #expect(throws: UISessionError.self) {
            _ = try await sup.start(UISessionConfig(
                platform: .macosApp, webVisible: true, macAppPath: "/tmp/Fake.app"
            ))
        }
    }

    // MARK: - W26: env / launch_args (WB-23)

    @Test("env / launch_args on a NON-macOS session are rejected, not dropped")
    func nonMacRejectsLaunchParameters() async {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sup = Self.supervisor(platform: .web, seen: ConfigProbe(), root: root)

        // A caller that thinks it enabled an app's fixture mode and got the
        // user's real data deserves the error — the same rule `session_state`
        // holds on a native platform, in the other direction.
        for config in [
            UISessionConfig(platform: .web, webURL: "https://example.com",
                            macLaunchEnvironment: ["MODE": "fixture"]),
            UISessionConfig(platform: .web, webURL: "https://example.com",
                            macLaunchArguments: ["--fixture"])
        ] {
            await #expect(throws: UISessionError.self) { _ = try await sup.start(config) }
        }
    }

    @Test("An empty env / launch_args on another platform is not an error")
    func emptyLaunchParametersAreHarmless() async throws {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sup = Self.supervisor(platform: .web, seen: ConfigProbe(), root: root)
        // Nothing was asked for, so nothing is being silently dropped.
        let info = try await sup.start(UISessionConfig(
            platform: .web, webURL: "https://example.com",
            macLaunchEnvironment: [:], macLaunchArguments: []
        ))
        _ = await sup.end(id: info.id)
    }

    @Test("A macOS session carries env / launch_args through to the preparer")
    func macCarriesLaunchParameters() async throws {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = ConfigProbe()
        let sup = Self.supervisor(platform: .macosApp, seen: seen, root: root)
        let info = try await sup.start(UISessionConfig(
            platform: .macosApp, macAppPath: "/tmp/Fake.app",
            macLaunchEnvironment: ["HARNESS_FIXTURE_MODE": "on"],
            macLaunchArguments: ["--fixture"]
        ))
        let config = try #require(await seen.last)
        #expect(config.macLaunchEnvironment == ["HARNESS_FIXTURE_MODE": "on"])
        #expect(config.macLaunchArguments == ["--fixture"])
        _ = await sup.end(id: info.id)
    }

    @Test("A launch parameter the exec contract cannot carry is refused")
    func invalidLaunchParametersRefused() {
        // These are not shell-escaping checks — there is no shell on this
        // path. They are the pairs `execve` cannot represent at all, which a
        // launch API given them either truncates or drops WHOLE, silently.
        #expect(throws: UISessionError.self) {
            try UISessionSupervisor.validateLaunchParameters(env: ["": "x"], args: nil)
        }
        #expect(throws: UISessionError.self) {
            try UISessionSupervisor.validateLaunchParameters(env: ["A=B": "x"], args: nil)
        }
        #expect(throws: UISessionError.self) {
            try UISessionSupervisor.validateLaunchParameters(env: ["A": "x\0y"], args: nil)
        }
        #expect(throws: UISessionError.self) {
            try UISessionSupervisor.validateLaunchParameters(env: nil, args: [""])
        }
        // Shell metacharacters are ORDINARY here: nothing expands them, and
        // refusing them would be theatre that blocks a legitimate value.
        #expect(throws: Never.self) {
            try UISessionSupervisor.validateLaunchParameters(
                env: ["SCARF_HOME": "/tmp/a b; echo $(whoami)"],
                args: ["--flag=a b", "--json={\"k\":1}"]
            )
        }
    }

    @Test("An invalid env key is named in the error — the VALUE never is")
    func launchParameterErrorsDoNotLeakValues() {
        do {
            try UISessionSupervisor.validateLaunchParameters(env: ["A=B": "s3cret-token"], args: nil)
            Issue.record("expected a throw")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("A=B"))
            #expect(!message.contains("s3cret-token"))
        }
    }

    // MARK: - Launch settle (WB-23)

    @Test("The settle returns as soon as the field is clear")
    func settleReturnsOnQuiet() async {
        var polls = 0
        let cleared = await MacLaunchSettle.awaitQuiet(
            stillRunning: { polls += 1; return polls <= 3 },
            sleep: { _ in }
        )
        #expect(cleared)
        #expect(polls == 4)
    }

    @Test("A process that never exits times out — and says so rather than blocking")
    func settleTimesOutHonestly() async {
        var slept = 0
        let cleared = await MacLaunchSettle.awaitQuiet(
            maxWaitMs: 500, pollIntervalMs: 100,
            stillRunning: { true },
            sleep: { _ in slept += 1 }
        )
        // FALSE, not a hang: a stranger's copy of the same app may run
        // forever, and refusing to start beside it would be worse than
        // starting. The caller relaunches either way; the log says which.
        #expect(cleared == false)
        #expect(slept == 5)
    }

    @Test("An already-quiet field costs nothing")
    func settleDoesNotSleepWhenAlreadyQuiet() async {
        var slept = 0
        let cleared = await MacLaunchSettle.awaitQuiet(
            stillRunning: { false },
            sleep: { _ in slept += 1 }
        )
        #expect(cleared)
        #expect(slept == 0)
    }

    @Test("export on a non-web session names the capability and the platform")
    func exportRejectedOnNative() async throws {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = ConfigProbe()
        let sup = Self.supervisor(platform: .macosApp, seen: seen, root: root)
        let info = try await sup.start(UISessionConfig(platform: .macosApp, macAppPath: "/tmp/Fake.app"))

        do {
            _ = try await sup.exportWebSessionState(id: info.id)
            Issue.record("expected a throw")
        } catch let error as UISessionError {
            let message = error.localizedDescription
            #expect(message.contains("export_ui_session_state"))
            #expect(message.contains("macOS") || message.contains("Mac"))
        }
        _ = await sup.end(id: info.id)
    }

    @Test("export on an unknown session id is a sessionNotFound, not a crash")
    func exportUnknownSession() async {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = ConfigProbe()
        let sup = Self.supervisor(platform: .web, seen: seen, root: root)
        await #expect(throws: UISessionError.self) {
            _ = try await sup.exportWebSessionState(id: UUID())
        }
    }

    @Test("a web session driven by a non-WebKit driver reports that honestly")
    func exportUnavailableDriver() async throws {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = ConfigProbe()
        let sup = Self.supervisor(platform: .web, seen: seen, root: root)
        let info = try await sup.start(UISessionConfig(platform: .web, webURL: "https://example.com"))

        do {
            _ = try await sup.exportWebSessionState(id: info.id)
            Issue.record("expected a throw")
        } catch let error as UISessionError {
            #expect(error.localizedDescription.contains("does not expose"))
        }
        _ = await sup.end(id: info.id)
    }

    @Test("no steps.jsonl row is written by an export attempt")
    func exportWritesNoArtifacts() async throws {
        let dir = UISessionTestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = ConfigProbe()
        let sup = Self.supervisor(platform: .web, seen: seen, root: dir)
        let info = try await sup.start(UISessionConfig(
            platform: .web, artifactDirPath: dir.path, webURL: "https://example.com"
        ))
        _ = try? await sup.exportWebSessionState(id: info.id)

        let jsonl = dir.appendingPathComponent("steps.jsonl")
        let contents = (try? String(contentsOf: jsonl, encoding: .utf8)) ?? ""
        #expect(!contents.contains(Self.secret))
        #expect(contents.isEmpty, "an export is not an observation and must append no row")
        _ = await sup.end(id: info.id)
    }
}

/// Captures the last `UISessionConfig` a preparer received.
private actor ConfigProbe {
    private(set) var last: UISessionConfig?
    func record(_ config: UISessionConfig) { last = config }
}

// MARK: - Credentials in UI sessions (WB-14)

@Suite("UISessionSupervisor — credentials")
struct UISessionCredentialTests {

    private static let password = "PASSWORD-THAT-MUST-NEVER-BE-LOGGED-8821"

    /// A supervisor over a fake driver that records what it was asked to do.
    /// `executeError` lets a test stand in for the real driver's
    /// `credentialUnavailable` throw without WebKit / a simulator.
    private static func makeSupervisor(
        platform: PlatformKind,
        seen: ConfigProbe,
        root: URL,
        driver: FakeUXDriver
    ) -> UISessionSupervisor {
        let names: [String] = {
            switch platform {
            case .web:          return ToolSchema.webToolNames
            case .iosSimulator: return ToolSchema.iOSToolNames
            case .macosApp:     return ToolSchema.macOSToolNames
            }
        }()
        let adapter = FakePlatformAdapter(kind: platform, names: names, probe: TeardownProbe())
        let preparer = FakeUISessionPreparer { config, _ in
            await seen.record(config)
            let session = RunSession(
                kind: platform, driver: driver, pointSize: CGSize(width: 10, height: 10),
                bundleIdentifier: nil, appBundleURL: nil, displayLabel: "fake",
                // Public-safe identity only — a session carries no password here.
                credentialLabel: "free user", credentialUsername: "qa@example.com"
            )
            return PreparedUISession(session: session, adapter: adapter)
        }
        return UISessionSupervisor(preparer: preparer, idleTimeoutSeconds: 0, defaultArtifactRoot: root)
    }

    private static func driver() -> FakeUXDriver {
        FakeUXDriver(
            pointSize: CGSize(width: 10, height: 10),
            pixelSize: CGSize(width: 10, height: 10),
            cleanPNG: UISessionTestSupport.solidPNG(width: 10, height: 10, color: .red),
            markedPNG: nil, annotation: nil, execDetail: nil
        )
    }

    @Test("credential_id reaches the preparer on every platform", arguments: [
        PlatformKind.web, .iosSimulator, .macosApp
    ])
    func credentialIDReachesPreparer(platform: PlatformKind) async throws {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = ConfigProbe()
        let sup = Self.makeSupervisor(platform: platform, seen: seen, root: root, driver: Self.driver())
        let credentialID = UUID()

        let config: UISessionConfig = {
            switch platform {
            case .web:
                return UISessionConfig(platform: .web, webURL: "https://example.com", credentialID: credentialID)
            case .iosSimulator:
                return UISessionConfig(
                    platform: .iosSimulator, credentialID: credentialID,
                    iosProjectPath: "/tmp/App.xcodeproj", iosScheme: "App",
                    iosSimulatorUDID: "UDID"
                )
            case .macosApp:
                return UISessionConfig(platform: .macosApp, credentialID: credentialID, macAppPath: "/tmp/Fake.app")
            }
        }()
        let info = try await sup.start(config)
        #expect(await seen.last?.credentialID == credentialID)
        _ = await sup.end(id: info.id)
    }

    @Test("no credential_id stays nil — sessions are credential-free by default")
    func defaultsToNoCredential() async throws {
        let root = UISessionTestSupport.tempArtifactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = ConfigProbe()
        let sup = Self.makeSupervisor(platform: .web, seen: seen, root: root, driver: Self.driver())
        let info = try await sup.start(UISessionConfig(platform: .web, webURL: "https://example.com"))
        #expect(await seen.last?.credentialID == nil)
        _ = await sup.end(id: info.id)
    }

    @Test("act_ui(fill_credential, field: password) maps to the password slot")
    func fieldArgumentMapsThrough() async throws {
        let dir = UISessionTestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = ConfigProbe()
        let driver = Self.driver()
        let sup = Self.makeSupervisor(platform: .web, seen: seen, root: dir, driver: driver)
        let info = try await sup.start(UISessionConfig(
            platform: .web, artifactDirPath: dir.path, webURL: "https://example.com",
            credentialID: UUID()
        ))

        _ = try await sup.act(id: info.id, tool: "fill_credential",
                              inputData: Data(#"{"field":"password"}"#.utf8))
        _ = try await sup.act(id: info.id, tool: "fill_credential", inputData: Data("{}".utf8))

        let calls = await driver.executed
        #expect(calls.count == 2)
        if case .fillCredential(let field) = calls.first?.input {
            #expect(field == .password)
        } else {
            Issue.record("expected .fillCredential(.password)")
        }
        // Omitted field keeps the safe default (typing a username exposes nothing).
        if case .fillCredential(let field) = calls.last?.input {
            #expect(field == .username)
        } else {
            Issue.record("expected .fillCredential(.username)")
        }
        _ = await sup.end(id: info.id)
    }

    @Test("a fill_credential row in steps.jsonl carries the field and nothing else")
    func stepsJSONLRecordsOnlyTheField() async throws {
        let dir = UISessionTestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = ConfigProbe()
        let sup = Self.makeSupervisor(platform: .web, seen: seen, root: dir, driver: Self.driver())
        let info = try await sup.start(UISessionConfig(
            platform: .web, artifactDirPath: dir.path, webURL: "https://example.com",
            credentialID: UUID()
        ))
        _ = try await sup.act(id: info.id, tool: "fill_credential",
                              inputData: Data(#"{"field":"password"}"#.utf8))

        let contents = try String(contentsOf: dir.appendingPathComponent("steps.jsonl"), encoding: .utf8)
        #expect(contents.contains("fill_credential"))
        #expect(contents.contains("\"field\":\"password\""))
        #expect(!contents.contains(Self.password))
        let row = try #require(JSONSerialization.jsonObject(
            with: Data(contents.split(separator: "\n").map(String.init)[0].utf8)
        ) as? [String: Any])
        let input = try #require(row["input"] as? [String: Any])
        #expect(input.keys.sorted() == ["field"], "only the slot may be logged")
        _ = await sup.end(id: info.id)
    }

    @Test("fill_credential with no staged credential FAILS the step (never a silent ok)")
    func noCredentialIsAStepFailure() async throws {
        let dir = UISessionTestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = ConfigProbe()
        let driver = Self.driver()
        // What every real driver now throws when `credential` is nil.
        await driver.setExecuteError(UXDriverError.credentialUnavailable(field: .password))
        let sup = Self.makeSupervisor(platform: .web, seen: seen, root: dir, driver: driver)
        let info = try await sup.start(UISessionConfig(
            platform: .web, artifactDirPath: dir.path, webURL: "https://example.com"
        ))

        let obs = try await sup.act(id: info.id, tool: "fill_credential",
                                    inputData: Data(#"{"field":"password"}"#.utf8))
        #expect(obs.actionFailed, "the caller must see isError, not a green step")
        let detail = try #require(obs.lastExecutionDetail)
        #expect(detail.contains("no credential is staged"))
        #expect(detail.contains("stage_credential"))

        let contents = try String(contentsOf: dir.appendingPathComponent("steps.jsonl"), encoding: .utf8)
        #expect(contents.contains("no credential is staged"))
        #expect(!contents.contains("\"result\":\"ok\""))
        _ = await sup.end(id: info.id)
    }

    @Test("a fill failure reports the slot and never the value")
    func fillFailureIsRedacted() {
        let binding = CredentialBinding(
            id: UUID(), label: "free user", username: "qa@example.com", password: Self.password
        )
        let raw = "TypingError: could not insert \(Self.password) into <input> for qa@example.com"
        let error = UXDriverError.credentialFillFailed(
            field: .password, detail: binding.redacting(raw)
        )
        let message = error.localizedDescription
        #expect(!message.contains(Self.password))
        #expect(!message.contains("qa@example.com"))
        #expect(message.contains("«redacted»"))
        #expect(message.contains("password"))
    }

    @Test("redaction also catches the JS-escaped and per-character renderings")
    func redactionCoversDriverTransforms() {
        let secret = "pa\"ss\\word"
        let binding = CredentialBinding(
            id: UUID(), label: "l", username: "u@example.com", password: secret
        )
        // What a WebKit JS-exception echo would carry (WebDriver.jsEscape).
        let jsEcho = #"SyntaxError near "pa\"ss\\word""#
        #expect(!binding.redacting(jsEcho).contains("ss"))
        // What a WDA error body echoing `{"value": [...]}` would carry.
        let wdaEcho = "400: {\"value\":[" + secret.map { "\"\($0)\"" }.joined(separator: ",") + "]}"
        #expect(!binding.redacting(wdaEcho).contains("\"s\",\"s\""))
    }

    @Test("CredentialBinding.value(for:) reads the slot the field names")
    func bindingSlots() {
        let binding = CredentialBinding(
            id: UUID(), label: "free user", username: "qa@example.com", password: Self.password
        )
        #expect(binding.value(for: .username) == "qa@example.com")
        #expect(binding.value(for: .password) == Self.password)
    }
}
