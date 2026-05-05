//
//  AgentToolsSchemaTests.swift
//  HarnessTests
//
//  Sanity-checks the model-facing tool schema. The full byte-for-byte agreement
//  with `https://github.com/awizemann/harness/wiki/Tool-Schema` is enforced by a Phase 2 test that parses the
//  markdown; today we just verify the runtime shape is well-formed.
//

import Testing
import Foundation
@testable import Harness

@Suite("AgentTools schema")
struct AgentToolsSchemaTests {

    /// Phase 2: ToolKind got macOS / web variants. The iOS schema is
    /// still the canonical reference; per-platform schemas advertise
    /// their own subsets. These tests assert the iOS schema's well-
    /// formedness; macOS / web schemas have their own suites below.
    private static let iOSToolKinds: Set<ToolKind> = [
        .tap, .doubleTap, .swipe, .type, .pressButton,
        .wait, .readScreen, .noteFriction, .markGoalDone
    ]

    @Test("iOS schema names match the iOS ToolKind subset")
    func iOSSchemaCoversItsKinds() {
        let definedNames = Set(ToolSchema.iOSToolNames)
        let iosNames = Set(Self.iOSToolKinds.map(\.rawValue))
        #expect(definedNames == iosNames)
    }

    @Test("Each iOS schema 'name' field equals its ToolKind rawValue")
    func schemaNamesMatchToolKindRawValues() {
        // This is the test that would have caught the Phase-1 ToolKind
        // rawValue bug: previously ToolKind defaulted to Swift-identifier
        // raw values (`noteFriction`, `doubleTap`, ...) but the schema's
        // `name` fields were snake_case. Round-trip parse failed for 5/9
        // tools.
        let defs = ToolSchema.iOSToolDefinitions(cacheControl: false)
        let schemaNames = Set(defs.compactMap { $0["name"] as? String })
        let iosRaw = Set(Self.iOSToolKinds.map(\.rawValue))
        #expect(schemaNames == iosRaw,
                "iOS schema names \(schemaNames.sorted()) must equal iOS ToolKind rawValues \(iosRaw.sorted()).")
    }

    @Test("ToolKind(rawValue:) round-trips every snake_case name from the iOS schema")
    func toolKindRoundTrip() {
        let defs = ToolSchema.iOSToolDefinitions(cacheControl: false)
        for def in defs {
            guard let name = def["name"] as? String else {
                Issue.record("definition missing name field")
                continue
            }
            #expect(ToolKind(rawValue: name) != nil,
                    "ToolKind(rawValue: \"\(name)\") returned nil — Claude calls this tool by name and we'd fail the request.")
        }
    }

    @Test("Each iOS definition has name, description, input_schema with required[] non-empty")
    func definitionShape() {
        let defs = ToolSchema.iOSToolDefinitions(cacheControl: false)
        #expect(defs.count == Self.iOSToolKinds.count)
        for def in defs {
            #expect((def["name"] as? String)?.isEmpty == false)
            #expect((def["description"] as? String)?.isEmpty == false)
            let schema = def["input_schema"] as? [String: Any]
            #expect(schema != nil)
            let required = schema?["required"] as? [String]
            #expect(required != nil && required!.isEmpty == false)
        }
    }

    // MARK: - Phase 2: macOS schema sanity

    @Test("macOS schema names match the macOSToolNames manifest")
    func macOSSchemaCoversItsKinds() {
        let defs = ToolSchema.macOSToolDefinitions(cacheControl: false)
        let names = Set(defs.compactMap { $0["name"] as? String })
        #expect(names == Set(ToolSchema.macOSToolNames))
    }

    @Test("macOS schema does NOT advertise iOS-only swipe / press_button")
    func macOSDropsIOSGestures() {
        let names = Set(ToolSchema.macOSToolNames)
        #expect(!names.contains(ToolKind.swipe.rawValue))
        #expect(!names.contains(ToolKind.pressButton.rawValue))
    }

    @Test("macOS schema includes right_click, scroll, key_shortcut")
    func macOSExtensionsPresent() {
        let names = Set(ToolSchema.macOSToolNames)
        #expect(names.contains(ToolKind.rightClick.rawValue))
        #expect(names.contains(ToolKind.scroll.rawValue))
        #expect(names.contains(ToolKind.keyShortcut.rawValue))
    }

    @Test("All ToolKind cases used in any platform schema round-trip via ToolKind(rawValue:)")
    func everyToolKindRoundTrips() {
        for kind in ToolKind.allCases {
            #expect(ToolKind(rawValue: kind.rawValue) == kind)
        }
    }

    @Test("iOS action tools require observation + intent")
    func reasoningFieldsRequired() {
        let defs = ToolSchema.iOSToolDefinitions(cacheControl: false)
        let actionTools: Set<String> = [
            "tap", "double_tap", "swipe", "type", "press_button", "wait", "read_screen"
        ]
        for def in defs {
            guard let name = def["name"] as? String, actionTools.contains(name) else { continue }
            let required = (def["input_schema"] as? [String: Any])?["required"] as? [String] ?? []
            #expect(required.contains("observation"), "tool \(name) missing observation requirement")
            #expect(required.contains("intent"), "tool \(name) missing intent requirement")
        }
    }

    @Test("note_friction kinds match FrictionKind user-emitted values (iOS schema)")
    func frictionKindEnumMatches() {
        let defs = ToolSchema.iOSToolDefinitions(cacheControl: false)
        let nf = defs.first(where: { ($0["name"] as? String) == "note_friction" })
        let props = (nf?["input_schema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let kindEnum = ((props["kind"] as? [String: Any])?["enum"] as? [String]) ?? []
        // The agent-emitted subset (excludes agent_blocked which is loop-synthesized).
        let userEmittedKinds: Set<String> = [
            FrictionKind.deadEnd.rawValue,
            FrictionKind.ambiguousLabel.rawValue,
            FrictionKind.unresponsive.rawValue,
            FrictionKind.confusingCopy.rawValue,
            FrictionKind.unexpectedState.rawValue
        ]
        #expect(Set(kindEnum) == userEmittedKinds)
    }

    @Test("mark_goal_done verdicts match Verdict enum (iOS schema)")
    func verdictEnumMatches() {
        let defs = ToolSchema.iOSToolDefinitions(cacheControl: false)
        let md = defs.first(where: { ($0["name"] as? String) == "mark_goal_done" })
        let props = (md?["input_schema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let verdictEnum = ((props["verdict"] as? [String: Any])?["enum"] as? [String]) ?? []
        let allVerdicts = Set(Verdict.allCases.map(\.rawValue))
        #expect(Set(verdictEnum) == allVerdicts)
    }

    @Test("press_button enum matches SimulatorButton (iOS schema)")
    func pressButtonEnumMatches() {
        let defs = ToolSchema.iOSToolDefinitions(cacheControl: false)
        let pb = defs.first(where: { ($0["name"] as? String) == "press_button" })
        let props = (pb?["input_schema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let buttonEnum = ((props["button"] as? [String: Any])?["enum"] as? [String]) ?? []
        let all = Set(SimulatorButton.allCases.map(\.rawValue))
        #expect(Set(buttonEnum) == all)
    }

    @Test("Cache control is applied only with the flag (iOS schema)")
    func cacheControlGate() {
        let withCache = ToolSchema.iOSToolDefinitions(cacheControl: true)
        let withoutCache = ToolSchema.iOSToolDefinitions(cacheControl: false)
        #expect((withCache.last?["cache_control"] as? [String: String]) != nil)
        #expect(withoutCache.last?["cache_control"] == nil)
    }
}
