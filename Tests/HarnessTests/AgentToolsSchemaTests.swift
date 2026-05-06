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

// MARK: - Multi-provider shape translators

@Suite("ToolSchema — provider shape translators")
struct ToolSchemaShapesTests {

    @Test("Anthropic shape preserves canonical names + cache marker on last only")
    func anthropicShapeBasic() {
        let canonical = ToolSchema.canonical(platform: .iosSimulator)
        let shaped = ToolSchema.anthropicShape(canonical, cacheLast: true)
        #expect(shaped.count == canonical.count)
        for (i, def) in shaped.enumerated() {
            #expect((def["name"] as? String) == canonical[i].name)
            #expect((def["description"] as? String) == canonical[i].description)
            #expect(def["input_schema"] != nil)
            // Cache marker only on the last entry.
            let hasCache = (def["cache_control"] as? [String: String]) != nil
            #expect(hasCache == (i == shaped.count - 1))
        }
    }

    @Test("Anthropic shape with cacheLast=false drops every cache marker")
    func anthropicShapeNoCacheMarkers() {
        let shaped = ToolSchema.anthropicShape(
            ToolSchema.canonical(platform: .iosSimulator),
            cacheLast: false
        )
        for def in shaped {
            #expect(def["cache_control"] == nil)
        }
    }

    @Test("OpenAI shape wraps each tool in {type:function, function:{...}}")
    func openAIShapeWraps() {
        let canonical = ToolSchema.canonical(platform: .iosSimulator)
        let shaped = ToolSchema.openAIShape(canonical)
        #expect(shaped.count == canonical.count)
        for (i, def) in shaped.enumerated() {
            #expect((def["type"] as? String) == "function")
            let function = def["function"] as? [String: Any]
            #expect(function != nil)
            #expect((function?["name"] as? String) == canonical[i].name)
            #expect((function?["description"] as? String) == canonical[i].description)
            #expect(function?["parameters"] != nil)
        }
    }

    @Test("OpenAI shape never emits cache_control (Anthropic-specific)")
    func openAIShapeNoCacheMarkers() {
        let shaped = ToolSchema.openAIShape(
            ToolSchema.canonical(platform: .iosSimulator)
        )
        for def in shaped {
            #expect(def["cache_control"] == nil)
            // Also verify the inner `function` object has no cache markers.
            let function = def["function"] as? [String: Any]
            #expect(function?["cache_control"] == nil)
        }
    }

    @Test("Anthropic and OpenAI shapes carry the same tool name set")
    func bothShapesAgreeOnNames() {
        let canonical = ToolSchema.canonical(platform: .iosSimulator)
        let anthropic = ToolSchema.anthropicShape(canonical, cacheLast: false)
        let openai = ToolSchema.openAIShape(canonical)

        let anthropicNames = Set(anthropic.compactMap { $0["name"] as? String })
        let openaiNames = Set(openai.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        })
        #expect(anthropicNames == openaiNames)
    }

    @Test("Per-platform canonical sets advertise platform-specific tools")
    func canonicalPerPlatform() {
        let ios = Set(ToolSchema.canonical(platform: .iosSimulator).map(\.name))
        let mac = Set(ToolSchema.canonical(platform: .macosApp).map(\.name))
        let web = Set(ToolSchema.canonical(platform: .web).map(\.name))

        // iOS-only gestures.
        #expect(ios.contains("swipe"))
        #expect(ios.contains("press_button"))
        #expect(!mac.contains("swipe"))
        #expect(!mac.contains("press_button"))

        // macOS adds right-click + scroll + key shortcut.
        #expect(mac.contains("right_click"))
        #expect(mac.contains("scroll"))
        #expect(mac.contains("key_shortcut"))

        // Web adds navigation tools.
        #expect(web.contains("navigate"))
        #expect(web.contains("back"))
        #expect(web.contains("forward"))
        #expect(web.contains("refresh"))
        #expect(!ios.contains("navigate"))
    }
}

// MARK: - LLMShared tool-call decoding

@Suite("LLMShared — toolCall decode")
struct LLMSharedToolCallTests {

    @Test("Tap input decodes coordinates + observation/intent")
    func tapDecode() throws {
        let json = #"{"x":120,"y":240,"observation":"see button","intent":"sign in"}"#
        let call = try LLMShared.toolCall(name: "tap", inputData: Data(json.utf8))
        #expect(call.tool == .tap)
        #expect(call.observation == "see button")
        #expect(call.intent == "sign in")
        if case let .tap(x, y) = call.input {
            #expect(x == 120)
            #expect(y == 240)
        } else {
            Issue.record("expected .tap input variant")
        }
    }

    @Test("Unknown tool name throws unknownTool")
    func unknownToolThrows() {
        let json = #"{"observation":"x","intent":"y"}"#
        #expect(throws: LLMError.self) {
            _ = try LLMShared.toolCall(name: "frobnicate", inputData: Data(json.utf8))
        }
    }

    @Test("Non-object input throws invalidToolCall")
    func nonObjectInputThrows() {
        let json = "[1,2,3]"
        #expect(throws: LLMError.self) {
            _ = try LLMShared.toolCall(name: "tap", inputData: Data(json.utf8))
        }
    }

    @Test("String-encoded coordinates coerce to Int")
    func stringCoordsCoerce() throws {
        // Some providers (and historically Claude) occasionally emit
        // numbers as strings in tool inputs. The decoder coerces.
        let json = #"{"x":"100","y":"200","observation":"","intent":""}"#
        let call = try LLMShared.toolCall(name: "tap", inputData: Data(json.utf8))
        if case let .tap(x, y) = call.input {
            #expect(x == 100)
            #expect(y == 200)
        } else {
            Issue.record("expected .tap input variant")
        }
    }

    @Test("note_friction decodes kind + detail")
    func noteFrictionDecode() throws {
        let json = #"{"kind":"dead_end","detail":"button does nothing"}"#
        let call = try LLMShared.toolCall(name: "note_friction", inputData: Data(json.utf8))
        if case let .noteFriction(kind, detail) = call.input {
            #expect(kind == .deadEnd)
            #expect(detail == "button does nothing")
        } else {
            Issue.record("expected .noteFriction input variant")
        }
    }

    @Test("mark_goal_done decodes verdict + summary + flag")
    func markGoalDoneDecode() throws {
        let json = #"""
        {"verdict":"success","summary":"signed in","friction_count":2,"would_real_user_succeed":true,"observation":"","intent":""}
        """#
        let call = try LLMShared.toolCall(name: "mark_goal_done", inputData: Data(json.utf8))
        if case let .markGoalDone(verdict, summary, count, wrus) = call.input {
            #expect(verdict == .success)
            #expect(summary == "signed in")
            #expect(count == 2)
            #expect(wrus == true)
        } else {
            Issue.record("expected .markGoalDone input variant")
        }
    }
}
