//
//  MacMarkProbeTests.swift
//  HarnessTests
//
//  Pins the macOS AX mark probe (WB-17 Phase A) against fixture trees.
//  `MacMarkProbe` is a pure function over an `AXSnapshotNode` snapshot
//  precisely so these can be real assertions rather than a second
//  implementation of the walk: the driver's only remaining job is reading
//  the live tree into those values.
//
//  The four findings under test, from the Scarf macOS shakedown:
//
//   * **W19** — SwiftUI `TextField`s expose no AX title AND no value, so a
//     seven-field form came back with seven `label: ""` marks and no flow
//     could be authored past the first click. The probe now associates the
//     visible sibling `AXStaticText`, and says it inferred it.
//   * **W21** — menu items appeared TWICE with identical label, role and
//     rect, which makes every macOS menu item unaddressable by a resolver
//     that refuses on ambiguity.
//   * **W20** — no `page_text`, so a success state rendered as text could
//     not be asserted at all.
//   * **W24** — background-window marks survived a front popover, at
//     main-window coordinates that do not exist in the captured frame.
//
//  The adversarial half matters as much as the happy half: a WRONG label is
//  worse than an honest `unlabelled textField`, so the association's
//  guardrails (distance, overlap, ancestry, exclusivity, tie-refusal) each
//  get a test that proves the probe REFUSES.
//

import Testing
import CoreGraphics
import Foundation
@testable import Harness

@Suite("MacMarkProbe — scoping, de-duplication, labels, page text")
struct MacMarkProbeTests {

    // MARK: - Fixture builders

    /// Monotonic identity source; identities only need to be distinct and
    /// equal-for-the-same-element, which is what `CFHash` gives us live.
    final class IDs {
        private var next: UInt64 = 1
        func take() -> UInt64 { defer { next += 1 }; return next }
    }

    static func window(
        _ ids: IDs,
        rect: CGRect,
        children: [AXSnapshotNode]
    ) -> AXSnapshotNode {
        AXSnapshotNode(identity: ids.take(), role: "AXWindow", rect: rect, children: children)
    }

    static func group(_ ids: IDs, rect: CGRect, children: [AXSnapshotNode]) -> AXSnapshotNode {
        AXSnapshotNode(identity: ids.take(), role: "AXGroup", rect: rect, children: children)
    }

    static func staticText(_ ids: IDs, _ text: String, rect: CGRect) -> AXSnapshotNode {
        AXSnapshotNode(identity: ids.take(), role: "AXStaticText", value: text, rect: rect)
    }

    /// A SwiftUI `TextField` as the AX tree actually reports it: a text
    /// field with NO title, NO description and NO value. This shape is the
    /// entire W19 finding.
    static func bareTextField(_ ids: IDs, rect: CGRect) -> AXSnapshotNode {
        AXSnapshotNode(identity: ids.take(), role: "AXTextField", rect: rect)
    }

    static func button(_ ids: IDs, title: String?, rect: CGRect) -> AXSnapshotNode {
        AXSnapshotNode(identity: ids.take(), role: "AXButton", title: title, rect: rect)
    }

    static let frame = CGRect(x: 100, y: 200, width: 600, height: 400)

    /// One labelled form row: `Host` at x=20 (frame-local), its field to the
    /// right on the same line. Coordinates are GLOBAL, as AX reports them.
    static func formRow(
        _ ids: IDs,
        label: String,
        y: CGFloat,
        fieldWidth: CGFloat = 200
    ) -> AXSnapshotNode {
        group(ids, rect: CGRect(x: 120, y: y, width: 400, height: 24), children: [
            staticText(ids, label, rect: CGRect(x: 120, y: y + 4, width: 60, height: 16)),
            bareTextField(ids, rect: CGRect(x: 190, y: y, width: fieldWidth, height: 24))
        ])
    }

    // MARK: - W19: adjacent-text association

    @Test("An unlabelled SwiftUI field takes the static text on its left, marked as inferred")
    func associatesLeftLabel() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.formRow(ids, label: "Host", y: 240),
            Self.formRow(ids, label: "Port", y: 280)
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        let fields = result.marks.filter { $0.role == "textField" }
        #expect(fields.count == 2)
        #expect(fields.map(\.label) == ["Host", "Port"])
        #expect(fields.allSatisfy { $0.labelSource == "adjacent-text" })
    }

    @Test("A label directly above its field is associated too (the VStack shape)")
    func associatesLabelAbove() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 120, y: 240, width: 300, height: 50), children: [
                Self.staticText(ids, "Identity file", rect: CGRect(x: 120, y: 240, width: 90, height: 16)),
                Self.bareTextField(ids, rect: CGRect(x: 120, y: 258, width: 240, height: 24))
            ])
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        let field = result.marks.first { $0.role == "textField" }
        #expect(field?.label == "Identity file")
        #expect(field?.labelSource == "adjacent-text")
    }

    @Test("A trailing colon is trimmed so `Host:` resolves like `Host`")
    func trimsTrailingColon() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.formRow(ids, label: "Host:", y: 240)
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.first { $0.role == "textField" }?.label == "Host")
    }

    @Test("An app-supplied AX name always beats the neighbouring text")
    func nativeLabelWins() {
        let ids = IDs()
        let field = AXSnapshotNode(
            identity: ids.take(),
            role: "AXTextField",
            axDescription: "Server hostname",
            rect: CGRect(x: 190, y: 240, width: 200, height: 24)
        )
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 120, y: 240, width: 400, height: 24), children: [
                Self.staticText(ids, "Host", rect: CGRect(x: 120, y: 244, width: 60, height: 16)),
                field
            ])
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        let mark = result.marks.first { $0.role == "textField" }
        #expect(mark?.label == "Server hostname")
        #expect(mark?.labelSource == "ax-description")
    }

    @Test("AXTitleUIElement — the platform's own label pointer — beats inference")
    func titleElementWins() {
        let ids = IDs()
        let field = AXSnapshotNode(
            identity: ids.take(),
            role: "AXTextField",
            titleElementText: "Projects directory",
            rect: CGRect(x: 190, y: 240, width: 200, height: 24)
        )
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 120, y: 240, width: 400, height: 24), children: [
                Self.staticText(ids, "Host", rect: CGRect(x: 120, y: 244, width: 60, height: 16)),
                field
            ])
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.first { $0.role == "textField" }?.labelSource == "ax-title-element")
        #expect(result.marks.first { $0.role == "textField" }?.label == "Projects directory")
    }

    // MARK: - W19 adversarial: the association must REFUSE

    @Test("A distant static text is NOT borrowed as a label")
    func refusesDistantText() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 120, y: 240, width: 460, height: 24), children: [
                // 240pt away — far past the same-row budget.
                Self.staticText(ids, "Host", rect: CGRect(x: 120, y: 244, width: 60, height: 16)),
                Self.bareTextField(ids, rect: CGRect(x: 360, y: 240, width: 200, height: 24))
            ])
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        let mark = result.marks.first { $0.role == "textField" }
        #expect(mark?.labelSource == "synthesized")
        #expect(mark?.label == "unlabelled textField")
    }

    @Test("Text in a different section can't reach across the tree, however close it looks")
    func refusesUnrelatedAncestor() {
        let ids = IDs()
        // Two sibling groups whose only common ancestor is the window, five
        // levels above the field. Geometrically adjacent, structurally not.
        let textSide = Self.group(ids, rect: CGRect(x: 120, y: 240, width: 60, height: 24), children: [
            Self.group(ids, rect: CGRect(x: 120, y: 240, width: 60, height: 24), children: [
                Self.group(ids, rect: CGRect(x: 120, y: 240, width: 60, height: 24), children: [
                    Self.group(ids, rect: CGRect(x: 120, y: 240, width: 60, height: 24), children: [
                        Self.staticText(ids, "Host", rect: CGRect(x: 120, y: 244, width: 60, height: 16))
                    ])
                ])
            ])
        ])
        let fieldSide = Self.group(ids, rect: CGRect(x: 190, y: 240, width: 200, height: 24), children: [
            Self.group(ids, rect: CGRect(x: 190, y: 240, width: 200, height: 24), children: [
                Self.group(ids, rect: CGRect(x: 190, y: 240, width: 200, height: 24), children: [
                    Self.group(ids, rect: CGRect(x: 190, y: 240, width: 200, height: 24), children: [
                        Self.bareTextField(ids, rect: CGRect(x: 190, y: 240, width: 200, height: 24))
                    ])
                ])
            ])
        ])
        let root = Self.window(ids, rect: Self.frame, children: [textSide, fieldSide])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.first { $0.role == "textField" }?.labelSource == "synthesized")
    }

    @Test("A label with a real form's column gap still reaches its field")
    func realFormColumnGapIsWithinBudget() {
        // Measured from the live fixture: a 90pt label column with a 29pt-wide
        // "Host" glyph run leaves a ~71pt gap between the text's own rect and
        // the field. A tight budget would refuse the very case W19 exists for.
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 124, y: 269, width: 470, height: 24), children: [
                Self.staticText(ids, "Host", rect: CGRect(x: 124, y: 273, width: 29, height: 16)),
                Self.bareTextField(ids, rect: CGRect(x: 224, y: 269, width: 220, height: 24))
            ])
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.first { $0.role == "textField" }?.label == "Host")
    }

    @Test("A label cannot jump over an intervening control to name the next one along")
    func lineOfSightBlocksTheJump() {
        let ids = IDs()
        // "Host" · [field A] · [field B]. Field B is within the horizontal
        // budget of "Host", but field A stands between them — so B stays
        // honestly unlabelled rather than stealing A's name.
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 120, y: 240, width: 460, height: 24), children: [
                Self.staticText(ids, "Host", rect: CGRect(x: 120, y: 244, width: 30, height: 16)),
                AXSnapshotNode(identity: ids.take(), role: "AXCheckBox", title: "Enabled",
                               rect: CGRect(x: 160, y: 240, width: 60, height: 24)),
                Self.bareTextField(ids, rect: CGRect(x: 230, y: 240, width: 120, height: 24))
            ])
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.first { $0.role == "textField" }?.labelSource == "synthesized")
    }

    @Test("One static text cannot label two fields — the nearer wins, the other stays honest")
    func textLabelsAtMostOneControl() {
        let ids = IDs()
        // BOTH fields are geometrically eligible for "Host": the near one at
        // a 10pt gap, the far one at 100pt — inside the budget, and with the
        // near field NOT between them vertically, so line-of-sight doesn't
        // decide it. Only the one-text-one-control rule can.
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 120, y: 240, width: 460, height: 60), children: [
                Self.staticText(ids, "Host", rect: CGRect(x: 120, y: 244, width: 60, height: 16)),
                Self.bareTextField(ids, rect: CGRect(x: 190, y: 240, width: 60, height: 24)),
                Self.bareTextField(ids, rect: CGRect(x: 280, y: 270, width: 60, height: 24))
            ])
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        let fields = result.marks.filter { $0.role == "textField" }
        #expect(fields.count == 2)
        // Exactly one field wins the text; deleting the exclusivity rule
        // would give BOTH the label "Host".
        #expect(fields.filter { $0.label == "Host" }.count == 1)
        #expect(fields.filter { $0.labelSource == "adjacent-text" }.count == 1)
    }

    @Test("One text with two equally good claimants labels NEITHER")
    func contestedTextLabelsNobody() {
        let ids = IDs()
        // A heading centred over two side-by-side fields: same direction,
        // same gap, two candidates. Handing it to whichever sorts first
        // would label one of them WRONG, with nothing in the output saying
        // which — so both stay honest.
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 120, y: 240, width: 300, height: 60), children: [
                Self.staticText(ids, "Address", rect: CGRect(x: 120, y: 240, width: 200, height: 16)),
                Self.bareTextField(ids, rect: CGRect(x: 120, y: 262, width: 90, height: 24)),
                Self.bareTextField(ids, rect: CGRect(x: 220, y: 262, width: 90, height: 24))
            ])
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        let fields = result.marks.filter { $0.role == "textField" }
        #expect(fields.count == 2)
        #expect(fields.allSatisfy { $0.labelSource == "synthesized" })
    }

    @Test("A shallow tree still refuses a text from a different section")
    func shallowTreeStillGuardsAncestry() {
        // The guard must not depend on the tree being deep. A plain SwiftUI
        // form produces `[window, group]` and nothing more; if "share an
        // ancestor" is read as set membership, the walk root is in every
        // chain and the guard passes everything.
        let ids = IDs()
        let sectionA = Self.group(ids, rect: CGRect(x: 120, y: 240, width: 60, height: 24), children: [
            Self.staticText(ids, "Host", rect: CGRect(x: 120, y: 244, width: 40, height: 16))
        ])
        let sectionB = Self.group(ids, rect: CGRect(x: 200, y: 240, width: 200, height: 24), children: [
            Self.bareTextField(ids, rect: CGRect(x: 200, y: 240, width: 200, height: 24))
        ])
        let root = Self.window(ids, rect: Self.frame, children: [sectionA, sectionB])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.first { $0.role == "textField" }?.labelSource == "synthesized")
    }

    @Test("A caption inside a control nested in a marked row is still not borrowable")
    func nestedCaptionIsNotBorrowable() {
        let ids = IDs()
        // The row wins the badge, so the button inside it is suppressed —
        // but the button's caption must STILL count as the button's own text
        // and never as the neighbouring field's label.
        let button = AXSnapshotNode(
            identity: ids.take(), role: "AXButton",
            rect: CGRect(x: 130, y: 244, width: 40, height: 16),
            children: [Self.staticText(ids, "Edit", rect: CGRect(x: 130, y: 244, width: 40, height: 16))]
        )
        let row = AXSnapshotNode(
            identity: ids.take(), role: "AXRow",
            rect: CGRect(x: 120, y: 240, width: 400, height: 24),
            children: [button, Self.bareTextField(ids, rect: CGRect(x: 190, y: 240, width: 200, height: 24))]
        )
        let root = Self.window(ids, rect: Self.frame, children: [row])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(!result.marks.contains { $0.label == "Edit" && $0.role == "textField" })
        // The row itself is the mark, named by the text it contains.
        #expect(result.marks.contains { $0.role == "row" })
    }

    @Test("page_text survives past the candidate cap")
    func pageTextIsNotTruncatedByTheMarkCap() {
        let ids = IDs()
        var children: [AXSnapshotNode] = []
        for i in 0..<210 {
            children.append(Self.button(ids, title: "B\(i)", rect: CGRect(x: 120, y: 200 + CGFloat(i), width: 40, height: 20)))
        }
        // Text AFTER the 200th candidate — a walk that bailed on the cap
        // would drop it silently, with no truncation marker.
        children.append(Self.staticText(ids, "Trailing status line", rect: CGRect(x: 120, y: 560, width: 200, height: 16)))
        let root = Self.window(ids, rect: Self.frame, children: children)
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.pageText?.contains("Trailing status line") == true)
    }

    @Test("Two coincident candidate labels are ambiguous — the probe refuses rather than guesses")
    func refusesAmbiguousTie() {
        let ids = IDs()
        let field = Self.bareTextField(ids, rect: CGRect(x: 240, y: 250, width: 120, height: 24))
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 120, y: 230, width: 400, height: 60), children: [
                // One immediately above, one immediately left, both flush.
                Self.staticText(ids, "Port", rect: CGRect(x: 240, y: 234, width: 60, height: 16)),
                Self.staticText(ids, "Host", rect: CGRect(x: 240, y: 234, width: 60, height: 16)),
                field
            ])
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.first { $0.role == "textField" }?.labelSource == "synthesized")
    }

    @Test("A button's own caption names that button, never the field beside it")
    func captionInsideAControlIsNotBorrowed() {
        let ids = IDs()
        let saveButton = AXSnapshotNode(
            identity: ids.take(),
            role: "AXButton",
            rect: CGRect(x: 120, y: 240, width: 60, height: 24),
            children: [Self.staticText(ids, "Save", rect: CGRect(x: 125, y: 244, width: 50, height: 16))]
        )
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 120, y: 240, width: 400, height: 24), children: [
                saveButton,
                Self.bareTextField(ids, rect: CGRect(x: 190, y: 240, width: 200, height: 24))
            ])
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.first { $0.role == "textField" }?.label != "Save")
        // The button, meanwhile, IS named by the caption it contains.
        let btn = result.marks.first { $0.role == "button" }
        #expect(btn?.label == "Save")
        #expect(btn?.labelSource == "text")
    }

    @Test("A secure field is never labelled with its own value")
    func secureFieldNeverLeaksValue() {
        let ids = IDs()
        let secure = AXSnapshotNode(
            identity: ids.take(),
            role: "AXSecureTextField",
            value: "hunter2-in-the-clear",
            rect: CGRect(x: 190, y: 240, width: 200, height: 24)
        )
        let root = Self.window(ids, rect: Self.frame, children: [secure])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        let mark = result.marks.first
        #expect(mark?.label == "Password")
        #expect(mark?.labelSource == "secure-field")
        #expect(result.marks.allSatisfy { !$0.label.contains("hunter2") })
    }

    @Test("A text field's own content is a last resort, never the first answer")
    func contentIsTheWeakestLabel() {
        let ids = IDs()
        let field = AXSnapshotNode(
            identity: ids.take(),
            role: "AXTextField",
            value: "22",
            rect: CGRect(x: 190, y: 240, width: 200, height: 24)
        )
        // With an adjacent label present, the label wins over the content.
        let labelled = Self.window(ids, rect: Self.frame, children: [
            Self.group(ids, rect: CGRect(x: 120, y: 240, width: 400, height: 24), children: [
                Self.staticText(ids, "Port", rect: CGRect(x: 120, y: 244, width: 60, height: 16)),
                field
            ])
        ])
        #expect(MacMarkProbe.probe(roots: [labelled], frame: Self.frame).marks.first?.label == "Port")

        // Alone, the content is better than nothing — and honestly sourced.
        let loneField = AXSnapshotNode(
            identity: ids.take(),
            role: "AXTextField",
            value: "22",
            rect: CGRect(x: 190, y: 240, width: 200, height: 24)
        )
        let bare = Self.window(ids, rect: Self.frame, children: [loneField])
        let mark = MacMarkProbe.probe(roots: [bare], frame: Self.frame).marks.first
        #expect(mark?.label == "22")
        #expect(mark?.labelSource == "value")
    }

    @Test("Every macOS mark carries a non-empty label and a label_source (parity with web)")
    func neverEmptyNeverUnsourced() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.bareTextField(ids, rect: CGRect(x: 120, y: 240, width: 100, height: 24)),
            Self.button(ids, title: nil, rect: CGRect(x: 120, y: 280, width: 40, height: 24)),
            Self.button(ids, title: "Save", rect: CGRect(x: 200, y: 280, width: 60, height: 24))
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.count == 3)
        #expect(result.marks.allSatisfy { !$0.label.isEmpty })
        #expect(result.marks.allSatisfy { ($0.labelSource ?? "").isEmpty == false })
    }

    // MARK: - W21: de-duplication

    @Test("A menu reachable through two parents yields ONE mark per item")
    func menuReachedTwiceIsMarkedOnce() {
        let ids = IDs()
        // The exact shape that produced six marks for three items: the same
        // AXMenu element hanging off both its owning pop-up button and the
        // window, so the walk visits every item twice.
        let menu = AXSnapshotNode(
            identity: ids.take(),
            role: "AXMenu",
            rect: CGRect(x: 100, y: 200, width: 200, height: 100),
            children: [
                AXSnapshotNode(identity: ids.take(), role: "AXMenuItem", title: "Open in new window",
                               rect: CGRect(x: 100, y: 200, width: 200, height: 24)),
                AXSnapshotNode(identity: ids.take(), role: "AXMenuItem", title: "ScarfBox",
                               rect: CGRect(x: 100, y: 230, width: 200, height: 24)),
                AXSnapshotNode(identity: ids.take(), role: "AXMenuItem", title: "Manage Servers…",
                               rect: CGRect(x: 100, y: 260, width: 200, height: 24))
            ]
        )
        let owner = AXSnapshotNode(
            identity: ids.take(),
            role: "AXPopUpButton",
            title: "Servers",
            rect: CGRect(x: 100, y: 200, width: 80, height: 24),
            children: [menu]
        )
        let root = Self.window(ids, rect: Self.frame, children: [owner, menu])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        let items = result.marks.filter { $0.role == "menuItem" }
        #expect(items.count == 3)
        #expect(Set(items.map(\.label)) == ["Open in new window", "ScarfBox", "Manage Servers…"])
    }

    @Test("Two distinct elements a resolver could never tell apart collapse to one mark")
    func indistinguishableTwinsCollapse() {
        let ids = IDs()
        let rect = CGRect(x: 120, y: 240, width: 120, height: 24)
        let root = Self.window(ids, rect: Self.frame, children: [
            // Different AX elements, identical role + label + rect.
            AXSnapshotNode(identity: ids.take(), role: "AXMenuItem", title: "Manage Servers…", rect: rect),
            AXSnapshotNode(identity: ids.take(), role: "AXMenuItem", title: "Manage Servers…", rect: rect)
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.count == 1)
    }

    @Test("Mark ids stay dense and 1-based after de-duplication")
    func idsAreDenseAfterCollapse() {
        let ids = IDs()
        let dup = CGRect(x: 120, y: 240, width: 120, height: 24)
        let root = Self.window(ids, rect: Self.frame, children: [
            AXSnapshotNode(identity: ids.take(), role: "AXMenuItem", title: "One", rect: dup),
            AXSnapshotNode(identity: ids.take(), role: "AXMenuItem", title: "One", rect: dup),
            AXSnapshotNode(identity: ids.take(), role: "AXMenuItem", title: "Two",
                           rect: CGRect(x: 120, y: 280, width: 120, height: 24))
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.map(\.id) == [1, 2])
    }

    // MARK: - W24: front-frame scoping and coordinate space

    @Test("Rects are reported in the CAPTURED frame's space, not the screen's")
    func rectsAreFrameLocal() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.button(ids, title: "Save", rect: CGRect(x: 140, y: 260, width: 60, height: 24))
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.first?.rect == CGRect(x: 40, y: 60, width: 60, height: 24))
    }

    @Test("A popover frame gets the popover's controls, in the popover's space")
    func popoverFrameScopesToThePopover() {
        let ids = IDs()
        let mainFrame = CGRect(x: 0, y: 0, width: 1863, height: 1388)
        let popoverFrame = CGRect(x: 400, y: 300, width: 474, height: 413)
        let mainWindow = Self.window(ids, rect: mainFrame, children: [
            Self.button(ids, title: "Behind me", rect: CGRect(x: 40, y: 40, width: 100, height: 24)),
            // A background control that happens to sit UNDER the popover —
            // clipping alone would keep it; scoping is what removes it.
            Self.button(ids, title: "Under the popover", rect: CGRect(x: 500, y: 400, width: 100, height: 24))
        ])
        let popover = AXSnapshotNode(
            identity: ids.take(),
            role: "AXPopover",
            rect: popoverFrame,
            children: [
                Self.button(ids, title: "Add server", rect: CGRect(x: 420, y: 320, width: 120, height: 24))
            ]
        )
        // The popover is its own CG window; AX reports it as a window too.
        let popoverWindow = AXSnapshotNode(
            identity: ids.take(), role: "AXWindow", rect: popoverFrame, children: [popover]
        )
        let result = MacMarkProbe.probe(roots: [mainWindow, popoverWindow], frame: popoverFrame)
        #expect(result.marks.map(\.label) == ["Add server"])
        #expect(result.marks.first?.rect == CGRect(x: 20, y: 20, width: 120, height: 24))
    }

    @Test("A sheet covering the window makes the window behind it background")
    func sheetOwnsTheFrame() {
        let ids = IDs()
        let windowFrame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let sheet = AXSnapshotNode(
            identity: ids.take(),
            role: "AXSheet",
            rect: CGRect(x: 0, y: 0, width: 600, height: 400),
            children: [
                Self.formRow(ids, label: "Name", y: 40)
            ]
        )
        let root = Self.window(ids, rect: windowFrame, children: [
            Self.button(ids, title: "Behind the sheet", rect: CGRect(x: 10, y: 350, width: 120, height: 24)),
            sheet
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: windowFrame)
        #expect(!result.marks.contains { $0.label == "Behind the sheet" })
        #expect(result.marks.contains { $0.label == "Name" })
    }

    @Test("Nothing outside the captured frame is ever marked")
    func offFrameControlsAreDropped() {
        let ids = IDs()
        let root = Self.window(ids, rect: CGRect(x: 0, y: 0, width: 2000, height: 1000), children: [
            Self.button(ids, title: "In frame", rect: CGRect(x: 120, y: 240, width: 60, height: 24)),
            Self.button(ids, title: "Off to the right", rect: CGRect(x: 1200, y: 240, width: 60, height: 24))
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.marks.map(\.label) == ["In frame"])
        #expect(result.marks.allSatisfy { Self.frame.width >= $0.rect.maxX && Self.frame.height >= $0.rect.maxY })
    }

    @Test("A control a click can't reach — the hidden pane of a tab view — is dropped")
    func occludedControlsAreDropped() {
        let ids = IDs()
        let visible = Self.button(ids, title: "Visible pane", rect: CGRect(x: 140, y: 260, width: 100, height: 24))
        let hidden = Self.button(ids, title: "Hidden pane", rect: CGRect(x: 140, y: 260, width: 100, height: 24))
        let root = Self.window(ids, rect: Self.frame, children: [visible, hidden])
        // Every point routes to the visible pane's button.
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame, hitTest: { _ in visible.identity })
        #expect(result.marks.map(\.label) == ["Visible pane"])
    }

    @Test("An unavailable hit test never drops anything — refusing to guess beats a false drop")
    func unknownHitTestKeepsEverything() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.button(ids, title: "Save", rect: CGRect(x: 140, y: 260, width: 60, height: 24))
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame, hitTest: { _ in nil })
        #expect(result.marks.map(\.label) == ["Save"])
    }

    @Test("A hit on the control's own descendant or ancestor counts as reachable")
    func descendantAndAncestorHitsCount() {
        let ids = IDs()
        let caption = Self.staticText(ids, "Save", rect: CGRect(x: 145, y: 264, width: 40, height: 16))
        let btn = AXSnapshotNode(
            identity: ids.take(), role: "AXButton", title: "Save",
            rect: CGRect(x: 140, y: 260, width: 60, height: 24), children: [caption]
        )
        let root = Self.window(ids, rect: Self.frame, children: [btn])
        // Topmost is the button's own label — the usual live answer.
        #expect(MacMarkProbe.probe(roots: [root], frame: Self.frame, hitTest: { _ in caption.identity })
            .marks.count == 1)
        // Topmost is the window — "the button doesn't paint at this point".
        #expect(MacMarkProbe.probe(roots: [root], frame: Self.frame, hitTest: { _ in root.identity })
            .marks.count == 1)
    }

    // MARK: - W20: page_text

    @Test("Static text in the frame becomes page_text, in reading order")
    func pageTextSweep() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.staticText(ids, "Health check passed", rect: CGRect(x: 120, y: 240, width: 200, height: 16)),
            Self.staticText(ids, "3 servers reachable", rect: CGRect(x: 120, y: 270, width: 200, height: 16))
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: Self.frame)
        #expect(result.pageText == "Health check passed\n3 servers reachable")
    }

    @Test("page_text is scoped to the front sheet — not the window behind it")
    func pageTextRespectsScoping() {
        let ids = IDs()
        let windowFrame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let sheet = AXSnapshotNode(
            identity: ids.take(), role: "AXSheet", rect: windowFrame,
            children: [Self.staticText(ids, "Add a remote server", rect: CGRect(x: 20, y: 20, width: 200, height: 16))]
        )
        let root = Self.window(ids, rect: windowFrame, children: [
            Self.staticText(ids, "Dashboard", rect: CGRect(x: 20, y: 370, width: 100, height: 16)),
            sheet
        ])
        let result = MacMarkProbe.probe(roots: [root], frame: windowFrame)
        #expect(result.pageText == "Add a remote server")
    }

    @Test("A frame with no text omits page_text rather than reporting an empty string")
    func noTextMeansNoKey() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.button(ids, title: "Save", rect: CGRect(x: 140, y: 260, width: 60, height: 24))
        ])
        #expect(MacMarkProbe.probe(roots: [root], frame: Self.frame).pageText == nil)
    }

    @Test("page_text is capped, with a trailing ellipsis marking the truncation")
    func pageTextIsCapped() {
        let ids = IDs()
        var children: [AXSnapshotNode] = []
        let line = String(repeating: "x", count: 500)
        for i in 0..<60 {
            children.append(Self.staticText(ids, line, rect: CGRect(x: 120, y: 200 + CGFloat(i) * 2, width: 400, height: 2)))
        }
        let root = Self.window(ids, rect: Self.frame, children: children)
        let text = MacMarkProbe.probe(roots: [root], frame: Self.frame).pageText
        #expect(text != nil)
        #expect((text?.count ?? 0) <= MacMarkProbe.pageTextCap)
        #expect(text?.hasSuffix("…") == true)
    }

    // MARK: - Ordering, caps, disabled controls

    @Test("Marks are in reading order — top to bottom, then left to right")
    func readingOrder() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.button(ids, title: "Third", rect: CGRect(x: 120, y: 320, width: 60, height: 24)),
            Self.button(ids, title: "Second", rect: CGRect(x: 300, y: 240, width: 60, height: 24)),
            Self.button(ids, title: "First", rect: CGRect(x: 120, y: 240, width: 60, height: 24))
        ])
        #expect(MacMarkProbe.probe(roots: [root], frame: Self.frame).marks.map(\.label)
            == ["First", "Second", "Third"])
    }

    @Test("Disabled controls and sub-16pt targets aren't marked")
    func filtersUnusableTargets() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            AXSnapshotNode(identity: ids.take(), role: "AXButton", title: "Disabled",
                           enabled: false, rect: CGRect(x: 120, y: 240, width: 60, height: 24)),
            AXSnapshotNode(identity: ids.take(), role: "AXButton", title: "Tiny",
                           rect: CGRect(x: 120, y: 280, width: 8, height: 8)),
            Self.button(ids, title: "Usable", rect: CGRect(x: 120, y: 320, width: 60, height: 24))
        ])
        #expect(MacMarkProbe.probe(roots: [root], frame: Self.frame).marks.map(\.label) == ["Usable"])
    }

    @Test("The mark cap is honoured")
    func capIsHonoured() {
        let ids = IDs()
        var children: [AXSnapshotNode] = []
        for i in 0..<40 {
            children.append(Self.button(ids, title: "B\(i)", rect: CGRect(x: 120, y: 200 + CGFloat(i) * 8, width: 60, height: 24)))
        }
        let root = Self.window(ids, rect: Self.frame, children: children)
        #expect(MacMarkProbe.probe(roots: [root], frame: Self.frame, cap: 10).marks.count == 10)
    }

    @Test("An empty root list yields nothing rather than crashing")
    func emptyRoots() {
        let result = MacMarkProbe.probe(roots: [], frame: Self.frame)
        #expect(result.marks.isEmpty)
        #expect(result.pageText == nil)
    }

    // MARK: - W15: the synthesized-label discriminator (WB-23)

    /// A control nothing can name: no title, no description, no help, no
    /// identifier, no caption, and — where the test places it — nothing
    /// adjacent to borrow. The traffic lights, in fixture form.
    static func namelessButton(_ ids: IDs, rect: CGRect) -> AXSnapshotNode {
        AXSnapshotNode(identity: ids.take(), role: "AXButton", rect: rect)
    }

    @Test("Two nameless controls do not answer to the same string")
    func synthesizedLabelsAreUnique() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.namelessButton(ids, rect: CGRect(x: 120, y: 210, width: 20, height: 20)),
            Self.namelessButton(ids, rect: CGRect(x: 150, y: 210, width: 20, height: 20)),
            Self.namelessButton(ids, rect: CGRect(x: 180, y: 210, width: 20, height: 20))
        ])
        let labels = MacMarkProbe.probe(roots: [root], frame: Self.frame).marks.map(\.label)
        #expect(labels == ["unlabelled button 1", "unlabelled button 2", "unlabelled button 3"])
        #expect(Set(labels).count == labels.count)
    }

    @Test("A lone nameless control keeps the plain placeholder — no gratuitous ordinal")
    func loneSynthesizedLabelIsUnnumbered() {
        let ids = IDs()
        let root = Self.window(ids, rect: Self.frame, children: [
            Self.namelessButton(ids, rect: CGRect(x: 120, y: 210, width: 20, height: 20)),
            Self.button(ids, title: "Save", rect: CGRect(x: 300, y: 210, width: 60, height: 24))
        ])
        let labels = MacMarkProbe.probe(roots: [root], frame: Self.frame).marks.map(\.label)
        #expect(labels.contains("unlabelled button"))
        #expect(!labels.contains { $0.hasPrefix("unlabelled button ") })
    }

    @Test("The nearest DELIBERATE ancestor name discriminates before the ordinal does")
    func synthesizedTakesAncestorContext() {
        let ids = IDs()
        var toolbar = Self.group(ids, rect: CGRect(x: 120, y: 210, width: 100, height: 24), children: [
            Self.namelessButton(ids, rect: CGRect(x: 120, y: 210, width: 20, height: 20))
        ])
        toolbar.title = "Toolbar"
        var sidebar = Self.group(ids, rect: CGRect(x: 300, y: 210, width: 100, height: 24), children: [
            Self.namelessButton(ids, rect: CGRect(x: 300, y: 210, width: 20, height: 20))
        ])
        sidebar.axDescription = "Sidebar"
        let root = Self.window(ids, rect: Self.frame, children: [toolbar, sidebar])
        let labels = MacMarkProbe.probe(roots: [root], frame: Self.frame).marks
            .filter { $0.labelSource == "synthesized" }
            .map(\.label)
        // Context alone separates them, so no ordinal is needed.
        #expect(labels == ["unlabelled button (Toolbar)", "unlabelled button (Sidebar)"])
    }

    @Test("Same context, two controls: the context stays and the ordinal breaks the tie")
    func contextPlusOrdinal() {
        let ids = IDs()
        var toolbar = Self.group(ids, rect: CGRect(x: 120, y: 210, width: 200, height: 24), children: [
            Self.namelessButton(ids, rect: CGRect(x: 120, y: 210, width: 20, height: 20)),
            Self.namelessButton(ids, rect: CGRect(x: 160, y: 210, width: 20, height: 20))
        ])
        toolbar.title = "Toolbar"
        let root = Self.window(ids, rect: Self.frame, children: [toolbar])
        let labels = MacMarkProbe.probe(roots: [root], frame: Self.frame).marks.map(\.label)
        #expect(labels == ["unlabelled button (Toolbar) 1", "unlabelled button (Toolbar) 2"])
    }

    @Test("The WINDOW's own title is not a discriminator")
    func windowTitleIsNotContext() {
        // The walk root names the FRAME, not the control: using it would
        // decorate every nameless control on screen identically — a longer
        // string that discriminates nothing.
        let ids = IDs()
        var root = Self.window(ids, rect: Self.frame, children: [
            Self.namelessButton(ids, rect: CGRect(x: 120, y: 210, width: 20, height: 20)),
            Self.namelessButton(ids, rect: CGRect(x: 150, y: 210, width: 20, height: 20))
        ])
        root.title = "Scarf"
        let labels = MacMarkProbe.probe(roots: [root], frame: Self.frame).marks.map(\.label)
        #expect(labels == ["unlabelled button 1", "unlabelled button 2"])
    }

    @Test("The discriminator never edits a name the app supplied")
    func discriminatorDoesNotTouchNamedControls() {
        let ids = IDs()
        var toolbar = Self.group(ids, rect: CGRect(x: 120, y: 210, width: 200, height: 24), children: [
            Self.button(ids, title: "Save", rect: CGRect(x: 120, y: 210, width: 60, height: 24)),
            Self.button(ids, title: "Save", rect: CGRect(x: 300, y: 210, width: 60, height: 24))
        ])
        toolbar.title = "Toolbar"
        let root = Self.window(ids, rect: Self.frame, children: [toolbar])
        let marks = MacMarkProbe.probe(roots: [root], frame: Self.frame).marks
            .filter { $0.role == "button" }
        // Two genuinely identical AUTHORED names stay identical: the app
        // said this, and decorating it would be the probe editing the app's
        // words. Only a placeholder is ours to disambiguate.
        #expect(marks.map(\.label) == ["Save", "Save"])
        #expect(marks.allSatisfy { $0.labelSource == "ax-title" })
    }

    @Test("A distant ancestor's name is out of reach")
    func contextIsBounded() {
        let ids = IDs()
        // Six nested groups between the named ancestor and the control —
        // one more than the budget.
        var nested = Self.group(ids, rect: CGRect(x: 120, y: 210, width: 40, height: 24), children: [
            Self.namelessButton(ids, rect: CGRect(x: 120, y: 210, width: 20, height: 20))
        ])
        for _ in 0..<5 {
            nested = Self.group(ids, rect: CGRect(x: 120, y: 210, width: 40, height: 24), children: [nested])
        }
        nested.title = "Far away"
        let root = Self.window(ids, rect: Self.frame, children: [nested])
        let labels = MacMarkProbe.probe(roots: [root], frame: Self.frame).marks.map(\.label)
        #expect(labels == ["unlabelled button"])
    }

    @Test("A very long ancestor name is truncated, not carried whole")
    func contextIsCapped() {
        let long = String(repeating: "context ", count: 20)
        let context = MacMarkProbe.synthesizedContext([nil, long])
        #expect(context != nil)
        #expect((context ?? "").count == MacMarkProbe.synthesizedContextCap)
        #expect((context ?? "").hasSuffix("…"))
    }

    @Test("The same tree probed twice yields the same labels")
    func discriminatorIsDeterministic() {
        let ids = IDs()
        var toolbar = Self.group(ids, rect: CGRect(x: 120, y: 210, width: 300, height: 24), children: [
            Self.namelessButton(ids, rect: CGRect(x: 120, y: 210, width: 20, height: 20)),
            Self.namelessButton(ids, rect: CGRect(x: 160, y: 210, width: 20, height: 20)),
            Self.namelessButton(ids, rect: CGRect(x: 200, y: 210, width: 20, height: 20))
        ])
        toolbar.title = "Toolbar"
        let root = Self.window(ids, rect: Self.frame, children: [toolbar])
        let first = MacMarkProbe.probe(roots: [root], frame: Self.frame).marks.map(\.label)
        let second = MacMarkProbe.probe(roots: [root], frame: Self.frame).marks.map(\.label)
        #expect(first == second)
    }

    @Test("A value is not a deliberate name")
    func valueIsNotContext() {
        // A container's AXValue is content, not a name — and a text field's
        // value moves the instant the user types. Keying a discriminator on
        // it would rename a control mid-flow.
        var node = AXSnapshotNode(identity: 1, role: "AXGroup", value: "typed text")
        #expect(MacMarkProbe.deliberateName(node) == nil)
        node.title = "Group"
        #expect(MacMarkProbe.deliberateName(node) == "Group")
    }

    // MARK: - Root selection

    @Test("The root matching the captured frame wins over the app's main window")
    func rootSelectionFollowsTheFrame() {
        let ids = IDs()
        let main = Self.window(ids, rect: CGRect(x: 0, y: 0, width: 1800, height: 1200), children: [])
        let menuFrame = CGRect(x: 500, y: 100, width: 144, height: 128)
        let menu = Self.window(ids, rect: menuFrame, children: [])
        #expect(MacMarkProbe.selectRoot(roots: [main, menu], frame: menuFrame)?.identity == menu.identity)
        #expect(MacMarkProbe.selectRoot(roots: [main, menu], frame: main.rect!)?.identity == main.identity)
    }
}
