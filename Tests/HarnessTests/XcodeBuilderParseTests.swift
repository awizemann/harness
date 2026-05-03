//
//  XcodeBuilderParseTests.swift
//  HarnessTests
//
//  Pure-parsing tests for the heuristics that map xcodebuild output back into
//  typed BuildFailures and Destination rows. Doesn't shell out — exercises the
//  string-parsing in isolation.
//

import Testing
import Foundation
@testable import Harness

@Suite("XcodeBuilder — output parsers")
struct XcodeBuilderParseTests {

    // MARK: iOS Simulator detection

    @Test("Recognizes the 'no iOS Simulator destination' xcodebuild diagnostic")
    func recognizesIOSSimulatorMissing() {
        let log = """
        xcodebuild: error: Unable to find a destination matching the provided destination specifier:
                { generic:1, platform:iOS Simulator }

            Available destinations for the "scarf" scheme:
                { platform:macOS, arch:arm64, id:00008112-0001798C1A31401E, name:My Mac }
                { platform:macOS, arch:x86_64, id:00008112-0001798C1A31401E, name:My Mac }
                { platform:macOS, name:Any Mac }
        """
        #expect(XcodeBuilder.looksLikeIOSSimulatorMissing(log))
    }

    @Test("Doesn't false-positive on unrelated xcodebuild errors")
    func noFalsePositiveOnSigningError() {
        let log = "error: Signing for \"X\" requires a development team."
        #expect(!XcodeBuilder.looksLikeIOSSimulatorMissing(log))
    }

    @Test("Available destinations parser pulls out platform names")
    func extractsAvailablePlatforms() {
        let log = """
        xcodebuild: error: Unable to find a destination matching the provided destination specifier:
                { generic:1, platform:iOS Simulator }

            Available destinations for the "scarf" scheme:
                { platform:macOS, arch:arm64, id:00008112-0001798C1A31401E, name:My Mac }
                { platform:macOS, arch:x86_64, id:00008112-0001798C1A31401E, name:My Mac }
                { platform:macOS, name:Any Mac }
        """
        let parsed = XcodeBuilder.parseAvailableDestinations(log)
        #expect(parsed == ["macOS"])
    }

    // MARK: -showdestinations parser

    @Test("Parses iPhone Simulator + Mac destinations from -showdestinations output")
    func parsesShowDestinations() {
        let log = """
        Available destinations for the "Sample" scheme:
                { platform:iOS Simulator, id:B8C5A8F1-1234, OS:18.4, name:iPhone 16 Pro }
                { platform:iOS Simulator, id:B8C5A8F1-5678, OS:18.4, name:iPhone SE (3rd generation) }
                { platform:macOS, arch:arm64, id:00008112-001, name:My Mac }
                { platform:iOS, id:00008110-002, name:Alan's iPhone }
                { platform:iOS Simulator, name:Any iOS Simulator Device }
        """
        let dests = XcodeBuilder.parseDestinations(log)
        // Dedupes by platform+name.
        let names = dests.map { "\($0.platform)|\($0.name ?? "")" }.sorted()
        #expect(names.contains("iOS Simulator|iPhone 16 Pro"))
        #expect(names.contains("iOS Simulator|iPhone SE (3rd generation)"))
        #expect(names.contains("macOS|My Mac"))

        // Compatibility predicate works.
        #expect(dests.contains(where: { $0.supportsIOSSimulator }))
    }

    @Test("Mac-only scheme has no iOS Simulator destinations")
    func macOnlyScheme() {
        let log = """
        Available destinations for the "scarf" scheme:
                { platform:macOS, arch:arm64, name:My Mac }
                { platform:macOS, arch:x86_64, name:My Mac }
                { platform:macOS, name:Any Mac }
        """
        let dests = XcodeBuilder.parseDestinations(log)
        #expect(!dests.contains(where: { $0.supportsIOSSimulator }))
        #expect(dests.allSatisfy { $0.platform == "macOS" })
    }

    @Test("Empty / non-destination output yields empty list")
    func emptyParse() {
        #expect(XcodeBuilder.parseDestinations("").isEmpty)
        #expect(XcodeBuilder.parseDestinations("nothing here").isEmpty)
    }
}
