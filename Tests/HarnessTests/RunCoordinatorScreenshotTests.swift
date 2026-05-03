//
//  RunCoordinatorScreenshotTests.swift
//  HarnessTests
//
//  Pins the screenshot-resize math: the JPEG sent to Claude must be at
//  exactly the device's point dimensions, so image-space coordinates the
//  model emits map directly to point coordinates idb consumes.
//
//  This is the "agent's taps land in the wrong spot" regression test.
//  Pre-fix: screenshots were downscaled to a fixed 1024-wide image and
//  the model emitted coordinates up to 657 on a 440-wide device — taps
//  fired by idb were on the dead edge of the screen / outside it.
//  Post-fix: the JPEG is exactly 440 × 956 and the model can read
//  coordinates straight off the image.
//

import Testing
import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import Harness

@Suite("RunCoordinator — screenshot scaling for the LLM call")
struct RunCoordinatorScreenshotTests {

    @Test("downscaleJPEG returns an image at exactly the device's point dimensions")
    func downscaleMatchesDevicePointSize() throws {
        // iPhone 17 Pro Max: 440 × 956 points, 3x scale → 1320 × 2868 pixels.
        let pixelImage = Self.makeSolidColorPNG(
            size: NSSize(width: 1320, height: 2868),
            color: .blue
        )

        let resized = try #require(
            RunCoordinator.downscaleJPEG(pixelImage,
                                          toPointSize: CGSize(width: 440, height: 956))
        )

        let rep = try #require(NSBitmapImageRep(data: resized))
        #expect(rep.pixelsWide == 440,
                "Image must be exactly 440 px wide so model coords map 1:1 to points; got \(rep.pixelsWide).")
        #expect(rep.pixelsHigh == 956,
                "Image must be exactly 956 px tall; got \(rep.pixelsHigh).")
    }

    @Test("Returns nil for undecodable input data")
    func nilOnGarbageInput() {
        let result = RunCoordinator.downscaleJPEG(
            Data([0xDE, 0xAD, 0xBE, 0xEF]),
            toPointSize: CGSize(width: 440, height: 956)
        )
        #expect(result == nil)
    }

    @Test("Different device dimensions produce different output sizes")
    func multipleDeviceSizes() throws {
        let pixelImage = Self.makeSolidColorPNG(
            size: NSSize(width: 1320, height: 2868),
            color: .red
        )

        let pro = try #require(RunCoordinator.downscaleJPEG(
            pixelImage, toPointSize: CGSize(width: 402, height: 874))
        )
        let proMax = try #require(RunCoordinator.downscaleJPEG(
            pixelImage, toPointSize: CGSize(width: 440, height: 956))
        )
        let se = try #require(RunCoordinator.downscaleJPEG(
            pixelImage, toPointSize: CGSize(width: 375, height: 667))
        )

        let proRep = try #require(NSBitmapImageRep(data: pro))
        let proMaxRep = try #require(NSBitmapImageRep(data: proMax))
        let seRep = try #require(NSBitmapImageRep(data: se))

        #expect(proRep.pixelsWide == 402)
        #expect(proRep.pixelsHigh == 874)
        #expect(proMaxRep.pixelsWide == 440)
        #expect(proMaxRep.pixelsHigh == 956)
        #expect(seRep.pixelsWide == 375)
        #expect(seRep.pixelsHigh == 667)
    }

    // MARK: Helpers

    private static func makeSolidColorPNG(size: NSSize, color: NSColor) -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return png
    }
}
