//
//  UIObservationPayloadTests.swift
//  HarnessTests
//
//  Covers the MCP `structuredContent` encoding for a UI-session observation
//  (`UIObservationPayload`): mark round-trip with geometry, the empty mark
//  table, marks with degenerate / missing geometry, page_text presence and
//  capping, JSON-serializability of the whole payload, and agreement between
//  the encoder and the declared `outputSchema`.
//
//  Pure value-level tests — no WebKit, no MCP process, no simulator.
//

import Testing
import Foundation
import CoreGraphics
@testable import Harness

// MARK: - Helpers

private enum PayloadTestSupport {

    static func mark(
        _ id: Int,
        _ label: String,
        _ role: String = "button",
        rect: CGRect,
        inputType: String? = nil
    ) -> InteractiveMark {
        InteractiveMark(id: id, rect: rect, role: role, inputType: inputType, label: label)
    }

    static func observation(
        marks: [InteractiveMark],
        pointSize: CGSize = CGSize(width: 1280, height: 800),
        pageText: String? = nil,
        markTable: String? = nil,
        step: Int = 1,
        sessionID: UUID = UUID()
    ) -> UIObservation {
        UIObservation(
            sessionID: sessionID,
            platform: .web,
            displayLabel: "example.com",
            pointSize: pointSize,
            imageData: Data(),
            imageIsMarked: !marks.isEmpty,
            markTable: markTable,
            markCount: marks.count,
            marks: marks,
            pageText: pageText,
            stepIndex: step,
            screenshotRef: String(format: "steps/%03d.png", step),
            lastExecutionDetail: nil,
            actionFailed: false
        )
    }

    /// Round-trip through JSONSerialization — proves the payload is actually
    /// wire-legal (the MCP writer would drop the whole response otherwise).
    static func roundTrip(_ payload: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - Marks

@Suite("UIObservationPayload — marks")
struct UIObservationPayloadMarkTests {

    @Test("marks round-trip with id, label, role, and rect in point space")
    func marksRoundTrip() throws {
        let id = UUID()
        let obs = PayloadTestSupport.observation(
            marks: [
                PayloadTestSupport.mark(1, "Sign in", "a", rect: CGRect(x: 24, y: 16, width: 72, height: 32)),
                PayloadTestSupport.mark(2, "Email", "input", rect: CGRect(x: 40, y: 120, width: 300, height: 44), inputType: "email")
            ],
            pointSize: CGSize(width: 1280, height: 800),
            step: 3,
            sessionID: id
        )

        let json = try PayloadTestSupport.roundTrip(UIObservationPayload.structuredContent(obs))

        #expect(json["session_id"] as? String == id.uuidString)
        #expect(json["step"] as? Int == 3)

        let size = try #require(json["point_size"] as? [String: Any])
        #expect(size["width"] as? Int == 1280)
        #expect(size["height"] as? Int == 800)

        let marks = try #require(json["marks"] as? [[String: Any]])
        #expect(marks.count == 2)

        let first = marks[0]
        #expect(first["id"] as? Int == 1)
        #expect(first["label"] as? String == "Sign in")
        #expect(first["role"] as? String == "a")
        let rect = try #require(first["rect"] as? [String: Any])
        #expect(rect["x"] as? Int == 24)
        #expect(rect["y"] as? Int == 16)
        #expect(rect["width"] as? Int == 72)
        #expect(rect["height"] as? Int == 32)

        // Order is the driver's reading order — preserved, not re-sorted.
        #expect(marks[1]["id"] as? Int == 2)
        #expect(marks[1]["label"] as? String == "Email")
    }

    @Test("empty mark table encodes as an empty array, never a missing key")
    func emptyMarks() throws {
        let obs = PayloadTestSupport.observation(marks: [], markTable: nil)
        let json = try PayloadTestSupport.roundTrip(UIObservationPayload.structuredContent(obs))

        let marks = try #require(json["marks"] as? [[String: Any]])
        #expect(marks.isEmpty)
        // A consumer can always read `marks` and `point_size` without branching.
        #expect(json["point_size"] != nil)
        #expect(json["page_text"] == nil)
    }

    @Test("a mark with zero / missing geometry still encodes a complete rect")
    func degenerateGeometry() throws {
        let obs = PayloadTestSupport.observation(
            marks: [PayloadTestSupport.mark(1, "", "div", rect: .zero)]
        )
        let json = try PayloadTestSupport.roundTrip(UIObservationPayload.structuredContent(obs))
        let mark = try #require((json["marks"] as? [[String: Any]])?.first)

        // Label is present-but-empty rather than absent — the caller shouldn't
        // have to branch on key presence for the common field.
        #expect(mark["label"] as? String == "")
        let rect = try #require(mark["rect"] as? [String: Any])
        #expect(rect["x"] as? Int == 0)
        #expect(rect["y"] as? Int == 0)
        #expect(rect["width"] as? Int == 0)
        #expect(rect["height"] as? Int == 0)
    }

    @Test("non-finite geometry collapses to 0 instead of taking the whole result down")
    func nonFiniteGeometry() throws {
        // JSONSerialization refuses NaN/∞ outright, so an unguarded rect would
        // fail the ENTIRE tools/call response, not just this mark.
        let bad = InteractiveMark(
            id: 1,
            rect: CGRect(x: CGFloat.nan, y: .infinity, width: 10, height: 10),
            role: "button", inputType: nil, label: "x"
        )
        let obs = PayloadTestSupport.observation(marks: [bad])
        let json = try PayloadTestSupport.roundTrip(UIObservationPayload.structuredContent(obs))
        let rect = try #require(((json["marks"] as? [[String: Any]])?.first)?["rect"] as? [String: Any])
        #expect(rect["x"] as? Int == 0)
        #expect(rect["y"] as? Int == 0)
        #expect(rect["width"] as? Int == 10)
    }

    @Test("fractional geometry survives as a number rather than being rounded away")
    func fractionalGeometry() throws {
        let obs = PayloadTestSupport.observation(
            marks: [PayloadTestSupport.mark(1, "half", rect: CGRect(x: 10.5, y: 0, width: 1, height: 1))]
        )
        let json = try PayloadTestSupport.roundTrip(UIObservationPayload.structuredContent(obs))
        let rect = try #require(((json["marks"] as? [[String: Any]])?.first)?["rect"] as? [String: Any])
        let x = try #require((rect["x"] as? NSNumber)?.doubleValue)
        #expect(abs(x - 10.5) < 0.0001)
    }
}

// MARK: - page_text

@Suite("UIObservationPayload — page_text")
struct UIObservationPayloadPageTextTests {

    @Test("page_text is included when the driver supplied it")
    func pageTextIncluded() throws {
        let obs = PayloadTestSupport.observation(marks: [], pageText: "Welcome\nSign in")
        let json = try PayloadTestSupport.roundTrip(UIObservationPayload.structuredContent(obs))
        #expect(json["page_text"] as? String == "Welcome\nSign in")
    }

    @Test("page_text is OMITTED, not null, when the platform has no text roll-up")
    func pageTextOmitted() throws {
        // iOS / macOS sessions land here. Absent means "we didn't look",
        // which is a different claim from "the screen has no text".
        let obs = PayloadTestSupport.observation(marks: [], pageText: nil)
        let json = try PayloadTestSupport.roundTrip(UIObservationPayload.structuredContent(obs))
        #expect(json.keys.contains("page_text") == false)
    }

    @Test("empty page text is treated as absent")
    func pageTextEmpty() throws {
        let obs = PayloadTestSupport.observation(marks: [], pageText: "")
        let json = try PayloadTestSupport.roundTrip(UIObservationPayload.structuredContent(obs))
        #expect(json.keys.contains("page_text") == false)
    }

    @Test("normalization collapses blank runs to one separator and strips edge whitespace")
    func normalization() throws {
        // A run of blank lines collapses to a SINGLE blank line — browsers
        // emit long blank runs from layout gaps, but one blank line is real
        // paragraph structure worth keeping. Leading/trailing blanks go.
        let raw = "  Welcome  \n\n\n   \nSign in\t\n\n"
        let text = try #require(WebDriver.normalizePageText(raw, cap: 1000))
        #expect(text == "Welcome\n\nSign in")
    }

    @Test("adjacent content lines keep their single newline")
    func normalizationAdjacentLines() throws {
        let text = try #require(WebDriver.normalizePageText("Welcome\nSign in", cap: 1000))
        #expect(text == "Welcome\nSign in")
    }

    @Test("all-whitespace text normalizes to nil rather than an empty string")
    func normalizationEmpty() {
        #expect(WebDriver.normalizePageText("   \n\n \t ", cap: 1000) == nil)
    }

    @Test("text longer than the cap is truncated to the cap plus an ellipsis marker")
    func capping() throws {
        let raw = String(repeating: "a", count: 500)
        let text = try #require(WebDriver.normalizePageText(raw, cap: 100))
        #expect(text.count == 101)          // 100 chars + the truncation marker
        #expect(text.hasSuffix("…"))
        #expect(text.hasPrefix(String(repeating: "a", count: 100)))
    }

    @Test("text at or under the cap is returned whole, with no marker")
    func cappingNoop() throws {
        let raw = String(repeating: "b", count: 100)
        let text = try #require(WebDriver.normalizePageText(raw, cap: 100))
        #expect(text == raw)
        #expect(!text.hasSuffix("…"))
    }

    @Test("the shipped cap is the documented 20k")
    func shippedCap() {
        #expect(WebDriver.pageTextCap == 20_000)
    }
}

// MARK: - outputSchema

@Suite("UIObservationPayload — outputSchema")
struct UIObservationPayloadSchemaTests {

    @Test("outputSchema is wire-legal JSON and describes an object")
    func schemaSerializes() throws {
        let schema = try PayloadTestSupport.roundTrip(UIObservationPayload.outputSchema())
        #expect(schema["type"] as? String == "object")
        #expect(schema["properties"] as? [String: Any] != nil)
    }

    @Test("every required schema key is actually emitted by the encoder")
    func requiredKeysAreEmitted() throws {
        let schema = UIObservationPayload.outputSchema()
        let required = try #require(schema["required"] as? [String])
        // Worst case for the encoder: no marks, no page text.
        let payload = UIObservationPayload.structuredContent(
            PayloadTestSupport.observation(marks: [], pageText: nil)
        )
        for key in required {
            #expect(payload[key] != nil, "outputSchema requires '\(key)' but the encoder omits it")
        }
    }

    @Test("page_text is described but NOT required — iOS and macOS omit it")
    func pageTextOptionalInSchema() throws {
        let schema = UIObservationPayload.outputSchema()
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["page_text"] != nil)
        let required = try #require(schema["required"] as? [String])
        #expect(!required.contains("page_text"))
    }

    @Test("every key the encoder emits is described in the schema")
    func emittedKeysAreDescribed() throws {
        let properties = try #require(UIObservationPayload.outputSchema()["properties"] as? [String: Any])
        // Richest case: marks plus page text.
        let payload = UIObservationPayload.structuredContent(
            PayloadTestSupport.observation(
                marks: [PayloadTestSupport.mark(1, "Go", rect: CGRect(x: 1, y: 2, width: 3, height: 4))],
                pageText: "hello"
            )
        )
        for key in payload.keys {
            #expect(properties[key] != nil, "encoder emits '\(key)' with no schema entry")
        }
    }

    @Test("the mark item schema names exactly the fields a mark encodes")
    func markItemSchemaMatches() throws {
        let properties = try #require(UIObservationPayload.outputSchema()["properties"] as? [String: Any])
        let marksSchema = try #require(properties["marks"] as? [String: Any])
        let items = try #require(marksSchema["items"] as? [String: Any])
        let itemProps = try #require(items["properties"] as? [String: Any])

        let encoded = UIObservationPayload.markJSON(
            PayloadTestSupport.mark(1, "Go", rect: CGRect(x: 1, y: 2, width: 3, height: 4))
        )
        #expect(Set(encoded.keys) == Set(itemProps.keys))
        #expect(Set(try #require(items["required"] as? [String])) == Set(encoded.keys))
    }
}
