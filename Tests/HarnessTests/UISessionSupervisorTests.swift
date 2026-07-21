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
    private(set) var executed: [ToolCall] = []
    var executeError: (any Error)?

    init(
        pointSize: CGSize,
        pixelSize: CGSize,
        cleanPNG: Data,
        markedPNG: Data?,
        annotation: String?,
        execDetail: String?
    ) {
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        self.cleanPNG = cleanPNG
        self.markedPNG = markedPNG
        self.annotation = annotation
        self.execDetail = execDetail
    }

    func screenshot(into url: URL) async throws -> ScreenshotMetadata {
        try cleanPNG.write(to: url, options: .atomic)   // driver writes the CLEAN frame
        return ScreenshotMetadata(
            pixelSize: pixelSize,
            pointSize: pointSize,
            markedImageData: markedPNG,
            markedAnnotationText: annotation
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
        let sup = UISessionSupervisor(
            preparer: UISessionTestSupport.preparer(
                platform: .web, label: "example.com", driver: driver,
                pointSize: CGSize(width: 100, height: 100), adapter: adapter
            )
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
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .web, label: "web", driver: driver,
            pointSize: CGSize(width: 60, height: 30), adapter: adapter
        ))
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

    @Test("no artifact_dir → CLEAN frame lands under the runs root")
    func tempArtifactRoot() async throws {
        let clean = UISessionTestSupport.solidPNG(width: 40, height: 40, color: .blue)
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 40, height: 40), pixelSize: CGSize(width: 40, height: 40),
            cleanPNG: clean, markedPNG: nil, annotation: nil, execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .web, label: "web", driver: driver,
            pointSize: CGSize(width: 40, height: 40), adapter: adapter
        ))
        let info = try await sup.start(UISessionConfig(platform: .web, webURL: "https://x.example",
                                                       viewportWidth: 40, viewportHeight: 40))
        let expectedRoot = HarnessPaths.runsDir
            .appendingPathComponent("ui-sessions", isDirectory: true)
            .appendingPathComponent(info.id.uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: expectedRoot) }

        _ = try await sup.observe(id: info.id, clean: false)
        let diskURL = expectedRoot.appendingPathComponent("steps/001.png")
        #expect(FileManager.default.fileExists(atPath: diskURL.path))
        _ = await sup.end(id: info.id)
    }
}

// MARK: - Guards (cap / validation / rejection)

@Suite("UISessionSupervisor — guards")
struct UISessionGuardTests {

    private func webSupervisor(cap probe: TeardownProbe = TeardownProbe()) -> UISessionSupervisor {
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
        ))
    }

    @Test("concurrent-session cap of 2 is enforced")
    func capEnforced() async throws {
        let sup = webSupervisor()
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
        })
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
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .macosApp, label: "MyMacApp", driver: driver,
            pointSize: CGSize(width: 1280, height: 800), adapter: adapter
        ))
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
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .macosApp, label: "Built", driver: driver,
            pointSize: CGSize(width: 800, height: 600), adapter: adapter
        ))
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
        let sup = UISessionSupervisor(
            preparer: UISessionTestSupport.preparer(
                platform: .web, label: "web", driver: driver,
                pointSize: CGSize(width: 30, height: 30), adapter: adapter
            ),
            idleTimeoutSeconds: 600
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
        let sup = UISessionSupervisor(
            preparer: UISessionTestSupport.preparer(
                platform: .web, label: "web", driver: driver,
                pointSize: CGSize(width: 30, height: 30), adapter: adapter
            ),
            idleTimeoutSeconds: 0
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

    private func webSession() async throws -> (UISessionSupervisor, UUID, FakeUXDriver) {
        let probe = TeardownProbe()
        let driver = FakeUXDriver(
            pointSize: CGSize(width: 80, height: 80), pixelSize: CGSize(width: 80, height: 80),
            cleanPNG: UISessionTestSupport.solidPNG(width: 80, height: 80, color: .white),
            markedPNG: UISessionTestSupport.solidPNG(width: 80, height: 80, color: .green),
            annotation: "MARKS:\n  1 → \"x\" (button)", execDetail: nil
        )
        let adapter = FakePlatformAdapter(kind: .web, names: ToolSchema.webToolNames, probe: probe)
        let sup = UISessionSupervisor(preparer: UISessionTestSupport.preparer(
            platform: .web, label: "web", driver: driver,
            pointSize: CGSize(width: 80, height: 80), adapter: adapter
        ))
        let info = try await sup.start(UISessionConfig(platform: .web, webURL: "https://a.example"))
        return (sup, info.id, driver)
    }

    @Test("meta tools are rejected by act_ui")
    func metaRejected() async throws {
        let (sup, id, _) = try await webSession()
        for meta in ["read_screen", "note_friction", "mark_goal_done"] {
            await #expect(throws: UISessionError.self) {
                _ = try await sup.act(id: id, tool: meta, inputData: Data("{}".utf8))
            }
        }
        _ = await sup.end(id: id)
    }

    @Test("a tool not in the platform vocabulary is rejected (swipe on web)")
    func unsupportedRejected() async throws {
        let (sup, id, _) = try await webSession()
        await #expect(throws: UISessionError.self) {
            _ = try await sup.act(id: id, tool: "swipe",
                                  inputData: Data(#"{"x1":0,"y1":0,"x2":1,"y2":1}"#.utf8))
        }
        _ = await sup.end(id: id)
    }

    @Test("tap_mark / navigate / scroll / type map to the right ToolInput")
    func mapsInputs() async throws {
        let (sup, id, driver) = try await webSession()

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

    @Test("a failed driver.execute surfaces actionFailed + the error detail")
    func failedActionSurfaced() async throws {
        let (sup, id, driver) = try await webSession()
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

    @Test("the five session tool names are exactly the cross-repo contract")
    func toolNameContract() {
        #expect(Set(UISessionTool.allCases.map(\.rawValue)) == [
            "start_ui_session", "observe_ui", "act_ui", "end_ui_session", "list_ui_sessions"
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
        let driver = MacAppDriver(bundleIdentifier: bundleID, appBundleURL: nil)
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
