//
//  SimulatorDriverCoordinateTests.swift
//  HarnessTests
//
//  The off-by-2x test that defends Harness's most likely visual bug
//  (per `standards/12-simulator-control.md §4`). Pixel→point conversion
//  happens in exactly one place — `SimulatorDriver.toPoints` — and this
//  test pins that contract.
//

import Testing
import Foundation
@testable import Harness

@Suite("SimulatorDriver — coordinate scaling")
struct SimulatorDriverCoordinateTests {

    @Test("Pixel-space (1200, 2400) at scale 3.0 → point-space (400, 800)")
    func pixelToPointAtScale3() {
        let result = SimulatorDriver.toPoints(CGPoint(x: 1200, y: 2400), scaleFactor: 3.0)
        #expect(result == CGPoint(x: 400, y: 800))
    }

    @Test("Pixel-space (1290, 2796) at scale 3.0 → (430, 932)")
    func iphone16ProBottomRight() {
        let result = SimulatorDriver.toPoints(CGPoint(x: 1290, y: 2796), scaleFactor: 3.0)
        #expect(result == CGPoint(x: 430, y: 932))
    }

    @Test("Scale 2.0 device — (750, 1334) → (375, 667)")
    func iphone8AtScale2() {
        let result = SimulatorDriver.toPoints(CGPoint(x: 750, y: 1334), scaleFactor: 2.0)
        #expect(result == CGPoint(x: 375, y: 667))
    }

    @Test("Origin (0,0) is invariant")
    func origin() {
        let result = SimulatorDriver.toPoints(.zero, scaleFactor: 3.0)
        #expect(result == .zero)
    }

    @Test("Zero scale factor is treated as identity (defensive)")
    func zeroScaleNoCrash() {
        let result = SimulatorDriver.toPoints(CGPoint(x: 100, y: 200), scaleFactor: 0)
        #expect(result == CGPoint(x: 100, y: 200))
    }

    @Test("Device metrics fall back sensibly for unknown names")
    func unknownDeviceFallback() {
        let (size, scale) = SimulatorDriver.devicePointMetrics(forName: "Mystery iPhone")
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(scale > 0)
    }

    @Test("iPhone 16 Pro Max metrics resolve")
    func iphone16ProMaxMetrics() {
        let (size, scale) = SimulatorDriver.devicePointMetrics(forName: "iPhone 16 Pro Max")
        #expect(size == CGSize(width: 440, height: 956))
        #expect(scale == 3.0)
    }

    @Test("iPhone SE metrics resolve at scale 2")
    func iphoneSEMetrics() {
        let (size, scale) = SimulatorDriver.devicePointMetrics(forName: "iPhone SE (3rd generation)")
        #expect(size == CGSize(width: 375, height: 667))
        #expect(scale == 2.0)
    }
}
