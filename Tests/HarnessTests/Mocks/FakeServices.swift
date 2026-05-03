//
//  FakeServices.swift
//  HarnessTests
//
//  In-memory fakes for the boundary services so the agent loop can be
//  exercised end-to-end without xcodebuild, simctl, or idb.
//

import Foundation
@testable import Harness

#if canImport(AppKit)
import AppKit
#endif

// MARK: - FakeXcodeBuilder

actor FakeXcodeBuilder: XcodeBuilding {
    let bundleID: String
    var destinationsResult: [XcodeBuilder.Destination] = [
        XcodeBuilder.Destination(platform: "iOS Simulator", arch: nil, name: "iPhone 16 Pro")
    ]

    init(bundleID: String = "com.example.fake") { self.bundleID = bundleID }

    func destinations(project: URL, scheme: String) async throws -> [XcodeBuilder.Destination] {
        return destinationsResult
    }

    func build(project: URL, scheme: String, runID: UUID) async throws -> BuildResult {
        // Fabricate an empty .app bundle inside the run dir so anything that
        // tries to access it later doesn't hard-fail.
        try HarnessPaths.prepareRunDirectory(for: runID)
        let products = HarnessPaths.derivedData(for: runID)
            .appendingPathComponent("Build/Products/Debug-iphonesimulator", isDirectory: true)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let app = products.appendingPathComponent("\(scheme).app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        return BuildResult(
            appBundle: app,
            bundleIdentifier: bundleID,
            duration: .milliseconds(120),
            logPath: HarnessPaths.buildLog(for: runID)
        )
    }
}

// MARK: - FakeSimulatorDriver

actor FakeSimulatorDriver: SimulatorDriving {

    /// Each call to `screenshot` writes one of these PNG payloads (round-robin)
    /// and yields it. Test fixtures provide enough payloads to cover every step.
    private let pngs: [Data]
    private var pngIndex = 0

    private(set) var taps: [CGPoint] = []
    private(set) var typed: [String] = []
    private(set) var swipes: [(CGPoint, CGPoint)] = []
    private(set) var bootCalls = 0
    private(set) var installCalls = 0
    private(set) var launchCalls = 0
    private(set) var screenshotCalls = 0
    private(set) var cleanupWDACalls: [String] = []
    private(set) var startInputSessionCalls = 0
    private(set) var endInputSessionCalls = 0
    /// In-test ordering log — useful when verifying lifecycle order
    /// (cleanupWDA → boot → install → launch → startInputSession → … → endInputSession).
    private(set) var lifecycleEvents: [String] = []

    init(pngs: [Data]) {
        self.pngs = pngs
    }

    nonisolated static func solidColorPNG(red: UInt8, green: UInt8, blue: UInt8, size: Int = 100) -> Data {
        // Build a tiny solid-color PNG — enough that the dHash differs across colors.
        #if canImport(AppKit)
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.lockFocus()
        NSColor(red: CGFloat(red)/255.0, green: CGFloat(green)/255.0, blue: CGFloat(blue)/255.0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        nsImage.unlockFocus()
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return png
        #else
        return Data()
        #endif
    }

    func listDevices() async throws -> [SimulatorRef] { [] }
    func boot(_ ref: SimulatorRef) async throws {
        bootCalls += 1
        lifecycleEvents.append("boot")
    }
    func install(_ appBundle: URL, on ref: SimulatorRef) async throws {
        installCalls += 1
        lifecycleEvents.append("install")
    }
    func launch(bundleID: String, on ref: SimulatorRef) async throws {
        launchCalls += 1
        lifecycleEvents.append("launch")
    }
    func terminate(bundleID: String, on ref: SimulatorRef) async throws { }
    func erase(_ ref: SimulatorRef) async throws { }
    func cleanupWDA(udid: String) async {
        cleanupWDACalls.append(udid)
        lifecycleEvents.append("cleanup")
    }

    func startInputSession(_ ref: SimulatorRef) async throws {
        startInputSessionCalls += 1
        lifecycleEvents.append("startInputSession")
    }

    func endInputSession() async {
        endInputSessionCalls += 1
        lifecycleEvents.append("endInputSession")
    }

    func screenshot(_ ref: SimulatorRef, into url: URL) async throws -> URL {
        screenshotCalls += 1
        let data = pngs.isEmpty ? Data() : pngs[pngIndex % pngs.count]
        pngIndex += 1
        try data.write(to: url, options: [.atomic])
        return url
    }

    func screenshotImage(_ ref: SimulatorRef) async throws -> NSImage {
        let url = HarnessPaths.appSupport.appendingPathComponent("tmp-fake-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await screenshot(ref, into: url)
        return NSImage(data: try Data(contentsOf: url)) ?? NSImage()
    }

    func tap(at point: CGPoint, on ref: SimulatorRef) async throws { taps.append(point) }
    func doubleTap(at point: CGPoint, on ref: SimulatorRef) async throws { taps.append(point); taps.append(point) }
    func swipe(from: CGPoint, to: CGPoint, duration: Duration, on ref: SimulatorRef) async throws { swipes.append((from, to)) }
    func type(_ text: String, on ref: SimulatorRef) async throws { typed.append(text) }
    func pressButton(_ button: SimulatorButton, on ref: SimulatorRef) async throws { }
}
