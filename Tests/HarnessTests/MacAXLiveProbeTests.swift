//
//  MacAXLiveProbeTests.swift
//  HarnessTests
//
//  LIVE macOS accessibility tests. These launch a real SwiftUI app and probe
//  its real AX tree — the only way to know the label chain matches what
//  AppKit and SwiftUI actually publish, rather than what a fixture tree says
//  they publish. Every fixture shape in `MacMarkProbeTests` was written from
//  what this app reports; if SwiftUI's AX surface changes, these fail first
//  and the fixture trees get corrected.
//
//  Opt-in, for two honest reasons:
//   * the fixture app has to be built (`HarnessMCP/fixtures/macos-app/
//     build-fixture.sh`), and no CI runner should be forced to;
//   * reading another process's AX tree needs the Accessibility grant, which
//     attaches to whatever process runs the tests.
//
//  Both are checked and SKIPPED rather than failed — a missing grant is a
//  machine fact, not a regression. Run them with:
//
//      HarnessMCP/fixtures/macos-app/build-fixture.sh
//      xcodebuild … test -only-testing:HarnessTests/MacAXLiveProbeTests
//
//  The app path is auto-discovered from the repo checkout and can be
//  overridden with `HARNESS_MACOS_FIXTURE_APP`.
//
//  Nothing here steals focus: the app is launched non-activating and driven
//  through AX actions only, which is the same containment the macOS session
//  backend holds to.
//

import Testing
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import Harness

@Suite("MacMarkProbe — live AX probe against a real SwiftUI app", .serialized)
struct MacAXLiveProbeTests {

    // MARK: - Harnessing

    /// The built fixture app, or nil when it hasn't been built.
    static var fixtureApp: URL? {
        if let override = ProcessInfo.processInfo.environment["HARNESS_MACOS_FIXTURE_APP"] {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let root = HarnessGeneratedRepoRoot.path
        guard !root.isEmpty else { return nil }
        let url = URL(fileURLWithPath: root)
            .appendingPathComponent("HarnessMCP/fixtures/macos-app/build/HarnessMacFixture.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var runnable: Bool { fixtureApp != nil && AXIsProcessTrusted() }

    /// A launched fixture app, terminated on `close()`. Launched
    /// non-activating and as a NEW instance, so a stray copy of the fixture
    /// can never be the thing under test.
    final class LaunchedApp {
        let pid: pid_t
        init?(_ url: URL) async {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.createsNewApplicationInstance = true
            guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg) else {
                return nil
            }
            pid = app.processIdentifier
        }
        func close() {
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
    }

    /// Wait for the app's window to exist and settle, then return its global
    /// rect — the same rect the driver captures and scopes marks to.
    static func frontFrame(pid: pid_t, timeout: TimeInterval = 10) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
               let info = MacAppDriver.selectFrontWindow(rows: rows, pid: pid) {
                return info.bounds
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    /// Snapshot + probe exactly as `MacAppDriver.probeFrame` does, minus the
    /// hit test (an AX hit test needs no extra grant, but a background test
    /// process gets flakier answers than a driven session does, and the
    /// probe's contract is that an unknown hit test drops nothing).
    static func probe(pid: pid_t, frame: CGRect) -> MacMarkProbe.Result {
        let app = AXUIElementCreateApplication(pid)
        var budget = MacAXSnapshot.Budget()
        var roots: [AXSnapshotNode] = []
        if let windows = axAttribute(app, kAXWindowsAttribute) as? [AXUIElement] {
            for w in windows {
                if let node = MacAXSnapshot.capture(element: w, frame: frame, depth: 0, budget: &budget) {
                    roots.append(node)
                }
            }
        }
        return MacMarkProbe.probe(roots: roots, frame: frame)
    }

    static func axAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    /// Depth-first search of the LIVE tree for an element matching `match`.
    static func findElement(
        pid: pid_t,
        match: (_ role: String, _ title: String, _ description: String) -> Bool
    ) -> AXUIElement? {
        func recurse(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            if depth > 20 { return nil }
            let role = (axAttribute(e, kAXRoleAttribute) as? String) ?? ""
            let title = (axAttribute(e, kAXTitleAttribute) as? String) ?? ""
            let desc = (axAttribute(e, kAXDescriptionAttribute) as? String) ?? ""
            if match(role, title, desc) { return e }
            guard let kids = axAttribute(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            for k in kids { if let hit = recurse(k, depth + 1) { return hit } }
            return nil
        }
        return recurse(AXUIElementCreateApplication(pid), 0)
    }

    // MARK: - W19: labels, live

    @Test("Live SwiftUI TextFields take their visible sibling labels", .enabled(if: MacAXLiveProbeTests.runnable))
    func liveAdjacentLabels() async throws {
        let launched = await LaunchedApp(Self.fixtureApp!)
        let app = try #require(launched, "the fixture app failed to launch")
        defer { app.close() }
        let resolved = await Self.frontFrame(pid: app.pid)
        let frame = try #require(resolved, "the fixture window never appeared")
        try? await Task.sleep(for: .milliseconds(600))

        let result = Self.probe(pid: app.pid, frame: frame)
        let fields = result.marks.filter { $0.role == "textField" }
        #expect(fields.count >= 4)

        // The three unlabelled rows recover their on-screen labels — the
        // exact shape that made Scarf's Add-Server sheet unauthorable.
        for expected in ["Host", "Port", "Identity file"] {
            let mark = fields.first { $0.label == expected }
            #expect(mark != nil, "no field labelled \(expected); got \(fields.map(\.label))")
            #expect(mark?.labelSource == "adjacent-text")
        }
        // The field the app DID name keeps the app's name.
        let named = fields.first { $0.label == "Server nickname" }
        #expect(named != nil)
        #expect(named?.labelSource == "ax-description")
    }

    @Test("No live mark is unlabelled, and every one carries provenance", .enabled(if: MacAXLiveProbeTests.runnable))
    func liveNeverEmpty() async throws {
        let launched = await LaunchedApp(Self.fixtureApp!)
        let app = try #require(launched, "the fixture app failed to launch")
        defer { app.close() }
        let resolved = await Self.frontFrame(pid: app.pid)
        let frame = try #require(resolved, "the fixture window never appeared")
        try? await Task.sleep(for: .milliseconds(600))

        let result = Self.probe(pid: app.pid, frame: frame)
        #expect(!result.marks.isEmpty)
        #expect(result.marks.allSatisfy { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(result.marks.allSatisfy { ($0.labelSource ?? "").isEmpty == false })
    }

    @Test("The Port field's typed content never becomes its label", .enabled(if: MacAXLiveProbeTests.runnable))
    func liveContentIsNotALabel() async throws {
        let launched = await LaunchedApp(Self.fixtureApp!)
        let app = try #require(launched, "the fixture app failed to launch")
        defer { app.close() }
        let resolved = await Self.frontFrame(pid: app.pid)
        let frame = try #require(resolved, "the fixture window never appeared")
        try? await Task.sleep(for: .milliseconds(600))

        // The fixture's Port field is pre-filled with "22" — the exact case
        // the shakedown called out, where the content is all a resolver has.
        let result = Self.probe(pid: app.pid, frame: frame)
        #expect(!result.marks.contains { $0.label == "22" })
        #expect(result.marks.contains { $0.label == "Port" })
    }

    // MARK: - W20: page_text, live

    @Test("Live page_text carries the window's visible text", .enabled(if: MacAXLiveProbeTests.runnable))
    func livePageText() async throws {
        let launched = await LaunchedApp(Self.fixtureApp!)
        let app = try #require(launched, "the fixture app failed to launch")
        defer { app.close() }
        let resolved = await Self.frontFrame(pid: app.pid)
        let frame = try #require(resolved, "the fixture window never appeared")
        try? await Task.sleep(for: .milliseconds(600))

        let text = Self.probe(pid: app.pid, frame: frame).pageText
        #expect(text != nil)
        // A success state rendered as prose — unassertable before W20.
        #expect(text?.contains("Fixture ready") == true)
        #expect((text?.count ?? 0) <= MacMarkProbe.pageTextCap)
    }

    // MARK: - W24: rect space, live

    @Test("Every live rect is inside the captured frame's own space", .enabled(if: MacAXLiveProbeTests.runnable))
    func liveRectsAreFrameLocal() async throws {
        let launched = await LaunchedApp(Self.fixtureApp!)
        let app = try #require(launched, "the fixture app failed to launch")
        defer { app.close() }
        let resolved = await Self.frontFrame(pid: app.pid)
        let frame = try #require(resolved, "the fixture window never appeared")
        try? await Task.sleep(for: .milliseconds(600))

        let result = Self.probe(pid: app.pid, frame: frame)
        #expect(!result.marks.isEmpty)
        for mark in result.marks {
            #expect(mark.rect.minX >= 0 && mark.rect.minY >= 0,
                    "mark \(mark.id) '\(mark.label)' has a negative origin: \(mark.rect)")
            #expect(mark.rect.maxX <= frame.width + 1 && mark.rect.maxY <= frame.height + 1,
                    "mark \(mark.id) '\(mark.label)' at \(mark.rect) escapes the \(frame.size) frame")
        }
        // For this to be a real proof, frame-local and global rects have to
        // differ — i.e. the window must NOT be at the screen origin. It
        // never is in practice (a launched window is placed by the window
        // server, and the menu bar alone pushes y past 0), and if it somehow
        // were, this test would be proving nothing and should say so.
        #expect(frame.minX != 0 || frame.minY != 0,
                "window at the screen origin — frame-local and global rects coincide, so this test proves nothing")
    }

    // MARK: - W21: menu de-duplication, live

    @Test("A live open menu marks each item exactly once", .enabled(if: MacAXLiveProbeTests.runnable))
    func liveMenuIsNotDoubled() async throws {
        let launched = await LaunchedApp(Self.fixtureApp!)
        let app = try #require(launched, "the fixture app failed to launch")
        defer { app.close() }
        let resolved = await Self.frontFrame(pid: app.pid)
        _ = try #require(resolved, "the fixture window never appeared")
        try? await Task.sleep(for: .milliseconds(600))

        // Open the menu through AX — no pointer moves, no focus is stolen.
        let foundMenuButton: AXUIElement? = Self.findElement(pid: app.pid, match: { role, title, _ in
            (role == "AXMenuButton" || role == "AXPopUpButton") && title == "Servers"
        })
        let menuButton = try #require(foundMenuButton, "no Servers menu button in the live AX tree")
        #expect(AXUIElementPerformAction(menuButton, kAXPressAction as CFString) == .success)
        try? await Task.sleep(for: .milliseconds(900))

        // The open menu is its own window; the probe scopes to whatever
        // frame the capture side resolved.
        let menuResolved = await Self.frontFrame(pid: app.pid, timeout: 3)
        let menuFrame = try #require(menuResolved, "no front frame after opening the menu")
        let result = Self.probe(pid: app.pid, frame: menuFrame)

        // Whatever the menu contributes, no item may appear twice — that is
        // the whole W21 failure: identical label, role AND rect, which no
        // resolver can disambiguate and no ordinal can order.
        let keys = result.marks.map { "\($0.role)|\($0.label)|\(Int($0.rect.minX))|\(Int($0.rect.minY))" }
        #expect(Set(keys).count == keys.count, "duplicate marks in the table: \(keys)")
        // Present FIRST, then unique — a uniqueness assertion over an empty
        // table is vacuously true, and an empty menu table would be its own
        // (different) regression.
        for item in ["Open in new window", "ScarfBox", "Manage Servers…"] {
            let hits = result.marks.filter { $0.label == item }
            #expect(hits.count == 1, "'\(item)' appeared \(hits.count)× in \(result.marks.map(\.label))")
        }
        // …and the window behind the menu is not in the menu's frame.
        #expect(!result.marks.contains { $0.label == "Add server" })

        // Close it again so the app quits cleanly.
        if let menu = Self.findElement(pid: app.pid, match: { role, _, _ in role == "AXMenu" }) {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
    }

    // MARK: - W24: overlay scoping, live

    @Test("With a sheet open, the window behind it is not in the table", .enabled(if: MacAXLiveProbeTests.runnable))
    func liveSheetScoping() async throws {
        let launched = await LaunchedApp(Self.fixtureApp!)
        let app = try #require(launched, "the fixture app failed to launch")
        defer { app.close() }
        let resolved = await Self.frontFrame(pid: app.pid)
        let frame = try #require(resolved, "the fixture window never appeared")
        try? await Task.sleep(for: .milliseconds(600))

        // Sanity: the background control IS marked before the sheet opens.
        let before = Self.probe(pid: app.pid, frame: frame)
        #expect(before.marks.contains { $0.label == "Add server" })

        let foundAddButton: AXUIElement? = Self.findElement(pid: app.pid, match: { role, title, desc in
            role == "AXButton" && (title == "Add server" || desc == "Add server")
        })
        let addButton = try #require(foundAddButton, "no Add server button in the live AX tree")
        #expect(AXUIElementPerformAction(addButton, kAXPressAction as CFString) == .success)
        try? await Task.sleep(for: .milliseconds(1200))

        let sheetResolved = await Self.frontFrame(pid: app.pid, timeout: 3)
        let sheetFrame = try #require(sheetResolved, "no front frame after opening the sheet")
        let after = Self.probe(pid: app.pid, frame: sheetFrame)
        // The sheet's own control is addressable…
        #expect(after.marks.contains { $0.label == "Cancel" },
                "sheet controls missing; got \(after.marks.map(\.label))")
        // …and the button that opened it — behind the sheet — is not.
        #expect(!after.marks.contains { $0.label == "Add server" },
                "background control survived the sheet: \(after.marks.map(\.label))")
        #expect(after.pageText?.contains("Add a remote server") == true)

        if let cancel = Self.findElement(pid: app.pid, match: { role, title, desc in
            role == "AXButton" && (title == "Cancel" || desc == "Cancel")
        }) {
            _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
        }
    }
}
