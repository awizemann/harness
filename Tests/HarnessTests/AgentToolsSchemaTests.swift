//
//  AgentToolsSchemaTests.swift
//  HarnessTests
//
//  Sanity-checks the model-facing tool schema. The full byte-for-byte agreement
//  with `wiki/Tool-Schema.md` is enforced by a Phase 2 test that parses the
//  markdown; today we just verify the runtime shape is well-formed.
//

import Testing
import Foundation
@testable import Harness

@Suite("AgentTools schema")
struct AgentToolsSchemaTests {

    @Test("All ToolKind cases have a definition")
    func everyToolKindHasDefinition() {
        let definedNames = Set(ToolSchema.allToolNames)
        let kindNames = Set(ToolKind.allCases.map(\.rawValue))
        #expect(definedNames == kindNames)
    }

    @Test("Each definition has name, description, input_schema with required[] non-empty")
    func definitionShape() {
        let defs = ToolSchema.toolDefinitions(cacheControl: false)
        #expect(defs.count == ToolKind.allCases.count)
        for def in defs {
            #expect((def["name"] as? String)?.isEmpty == false)
            #expect((def["description"] as? String)?.isEmpty == false)
            let schema = def["input_schema"] as? [String: Any]
            #expect(schema != nil)
            let required = schema?["required"] as? [String]
            #expect(required != nil && required!.isEmpty == false)
        }
    }

    @Test("Action tools require observation + intent")
    func reasoningFieldsRequired() {
        let defs = ToolSchema.toolDefinitions(cacheControl: false)
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

    @Test("note_friction kinds match FrictionKind user-emitted values")
    func frictionKindEnumMatches() {
        let defs = ToolSchema.toolDefinitions(cacheControl: false)
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

    @Test("mark_goal_done verdicts match Verdict enum")
    func verdictEnumMatches() {
        let defs = ToolSchema.toolDefinitions(cacheControl: false)
        let md = defs.first(where: { ($0["name"] as? String) == "mark_goal_done" })
        let props = (md?["input_schema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let verdictEnum = ((props["verdict"] as? [String: Any])?["enum"] as? [String]) ?? []
        let allVerdicts = Set(Verdict.allCases.map(\.rawValue))
        #expect(Set(verdictEnum) == allVerdicts)
    }

    @Test("press_button enum matches SimulatorButton")
    func pressButtonEnumMatches() {
        let defs = ToolSchema.toolDefinitions(cacheControl: false)
        let pb = defs.first(where: { ($0["name"] as? String) == "press_button" })
        let props = (pb?["input_schema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let buttonEnum = ((props["button"] as? [String: Any])?["enum"] as? [String]) ?? []
        let all = Set(SimulatorButton.allCases.map(\.rawValue))
        #expect(Set(buttonEnum) == all)
    }

    @Test("Cache control is applied only with the flag")
    func cacheControlGate() {
        let withCache = ToolSchema.toolDefinitions(cacheControl: true)
        let withoutCache = ToolSchema.toolDefinitions(cacheControl: false)
        #expect((withCache.last?["cache_control"] as? [String: String]) != nil)
        #expect(withoutCache.last?["cache_control"] == nil)
    }
}
