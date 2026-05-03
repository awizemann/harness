//
//  SimctlParseTests.swift
//  HarnessTests
//
//  Verifies SimulatorDriver.parseSimctlList handles the modern simctl JSON
//  shape and filters non-iOS / unavailable devices.
//

import Testing
import Foundation
@testable import Harness

@Suite("simctl JSON parsing")
struct SimctlParseTests {

    @Test("Parses iOS devices and humanizes runtime label")
    func happyPath() throws {
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
              {
                "udid": "B8C5A8F1-0000-0000-0000-AAAAAAAAAAAA",
                "name": "iPhone 16 Pro",
                "isAvailable": true,
                "state": "Shutdown"
              },
              {
                "udid": "B8C5A8F1-0000-0000-0000-BBBBBBBBBBBB",
                "name": "iPhone SE (3rd generation)",
                "isAvailable": true,
                "state": "Shutdown"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.tvOS-18-4": [
              {
                "udid": "TVOS-1111",
                "name": "Apple TV",
                "isAvailable": true,
                "state": "Shutdown"
              }
            ]
          }
        }
        """
        let data = Data(json.utf8)
        let refs = try SimulatorDriver.parseSimctlList(data)
        // tvOS row excluded; both iOS rows present.
        #expect(refs.count == 2)
        let names = refs.map(\.name).sorted()
        #expect(names == ["iPhone 16 Pro", "iPhone SE (3rd generation)"])
        // Runtime label humanized.
        for r in refs {
            #expect(r.runtime.contains("iOS"))
        }
    }

    @Test("Filters unavailable devices")
    func skipsUnavailable() throws {
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
              {
                "udid": "AVAIL",
                "name": "iPhone 16 Pro",
                "isAvailable": true
              },
              {
                "udid": "GONE",
                "name": "iPhone 12 mini",
                "isAvailable": false
              }
            ]
          }
        }
        """
        let refs = try SimulatorDriver.parseSimctlList(Data(json.utf8))
        #expect(refs.count == 1)
        #expect(refs.first?.udid == "AVAIL")
    }

    @Test("Empty / malformed JSON returns empty list, doesn't throw")
    func malformedReturnsEmpty() throws {
        let refs = try SimulatorDriver.parseSimctlList(Data("{}".utf8))
        #expect(refs.isEmpty)
    }
}
