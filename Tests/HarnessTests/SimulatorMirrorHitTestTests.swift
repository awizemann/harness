//
//  SimulatorMirrorHitTestTests.swift
//  HarnessTests
//
//  Pins the coordinate-conversion math used to forward user mouse clicks on
//  the mirror to `idb tap` in device-point space. Same kind of off-by-2x /
//  letterbox-aware bug that bit us before — better unit-tested than visually
//  caught.
//

import Testing
import Foundation
import CoreGraphics
@testable import Harness

@Suite("SimulatorMirrorView — click-to-tap hit-test math")
struct SimulatorMirrorHitTestTests {

    // MARK: fitFrame

    @Test("Fit-frame computes a centered, aspect-preserving rect with 8pt letterbox")
    func fitFrameCentered() {
        // 1000×1000 view, device aspect 0.5 (tall). The screen rect should
        // be centered horizontally with 8pt letterbox top/bottom — actually
        // since we're tall, height fits, width derives.
        let frame = SimulatorMirrorView.fitFrame(
            in: CGSize(width: 1000, height: 1000),
            aspect: 0.5
        )
        // availH = 984, availW = 984. availW/availH = 1.0 > 0.5, so
        // height drives: h = 984, w = h * 0.5 = 492.
        #expect(frame.size == CGSize(width: 492, height: 984))
        // Centered horizontally: x = (1000 - 492) / 2 = 254.
        #expect(frame.minX == 254)
        #expect(frame.minY == 8)
    }

    // MARK: devicePoint

    @Test("Click in the center of the mirror maps to the device's center")
    func centerClick() {
        let view = CGSize(width: 1000, height: 1000)
        let device = CGSize(width: 440, height: 956)  // iPhone 17 Pro Max
        let result = SimulatorMirrorView.devicePoint(
            fromMirrorLocation: CGPoint(x: 500, y: 500),
            viewSize: view,
            deviceSize: device
        )
        // Center of view ≈ center of device. Allow 1pt tolerance for the
        // letterbox math.
        let pt = try? #require(result)
        #expect(abs(pt!.x - 220) <= 1)
        #expect(abs(pt!.y - 478) <= 1)
    }

    @Test("Click on the letterbox area returns nil")
    func letterboxIgnored() {
        let view = CGSize(width: 1000, height: 1000)
        let device = CGSize(width: 440, height: 956)
        // Click at the very top-left corner of the view — outside the
        // 8pt letterbox AND outside the screen rect.
        let result = SimulatorMirrorView.devicePoint(
            fromMirrorLocation: CGPoint(x: 4, y: 4),
            viewSize: view,
            deviceSize: device
        )
        #expect(result == nil)
    }

    @Test("Top-left of the rendered screen maps to (0, 0) device-space")
    func topLeftCorner() {
        let view = CGSize(width: 1000, height: 1000)
        let device = CGSize(width: 440, height: 956)
        // Compute the screen rect ourselves.
        let aspect = device.width / device.height
        let frame = SimulatorMirrorView.fitFrame(in: view, aspect: aspect)
        // Click at the top-left of the rendered screen rect.
        let result = SimulatorMirrorView.devicePoint(
            fromMirrorLocation: CGPoint(x: frame.minX + 0.5, y: frame.minY + 0.5),
            viewSize: view,
            deviceSize: device
        )
        let pt = try? #require(result)
        #expect((pt?.x ?? -1) >= 0)
        #expect((pt?.y ?? -1) >= 0)
        #expect((pt?.x ?? 999) < 1)
        #expect((pt?.y ?? 999) < 1)
    }

    @Test("Bottom-right of the rendered screen maps to ≈ device width/height")
    func bottomRightCorner() {
        let view = CGSize(width: 1000, height: 1000)
        let device = CGSize(width: 440, height: 956)
        let aspect = device.width / device.height
        let frame = SimulatorMirrorView.fitFrame(in: view, aspect: aspect)
        let result = SimulatorMirrorView.devicePoint(
            fromMirrorLocation: CGPoint(x: frame.maxX - 0.5, y: frame.maxY - 0.5),
            viewSize: view,
            deviceSize: device
        )
        let pt = try? #require(result)
        #expect(abs(pt!.x - device.width) <= 1)
        #expect(abs(pt!.y - device.height) <= 1)
    }

    @Test("Different device aspect ratios produce different mappings")
    func varyingAspect() {
        let view = CGSize(width: 800, height: 800)

        // iPhone SE (3rd gen): 375 × 667
        let se = SimulatorMirrorView.devicePoint(
            fromMirrorLocation: CGPoint(x: 400, y: 400),
            viewSize: view,
            deviceSize: CGSize(width: 375, height: 667)
        )
        // iPhone 17 Pro Max: 440 × 956
        let pro = SimulatorMirrorView.devicePoint(
            fromMirrorLocation: CGPoint(x: 400, y: 400),
            viewSize: view,
            deviceSize: CGSize(width: 440, height: 956)
        )

        // Center of the view → center of each device. Different sizes →
        // different point coordinates.
        #expect(se != nil && pro != nil)
        if let se, let pro {
            #expect(abs(se.x - 187.5) <= 1)
            #expect(abs(se.y - 333.5) <= 1)
            #expect(abs(pro.x - 220) <= 1)
            #expect(abs(pro.y - 478) <= 1)
            #expect(se != pro)
        }
    }
}
