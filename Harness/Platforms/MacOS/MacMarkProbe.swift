//
//  MacMarkProbe.swift
//  Harness
//
//  The Set-of-Mark element probe for macOS AX sessions, as a PURE function
//  over a snapshot of the app's accessibility tree. `MacAppDriver` takes the
//  live snapshot (the only part that needs `AXUIElement`) and hands it here;
//  everything that decides *what gets marked and what we call it* lives in
//  this file, against plain values, so the test suite can pin it with
//  fixture trees instead of asserting on a re-implementation. That mirrors
//  how `WebMarkProbe` is testable against real fixture pages.
//
//  The probe answers the same question the web probe does — *could the agent
//  act on this right now, and what do we call it?* — with the macOS answers:
//
//  1. **Scoped** (W24) — marks come from the AX subtree that corresponds to
//     the CAPTURED frame (the front window, or the sheet / popover / menu on
//     top of it), and every rect is reported in THAT frame's coordinate
//     space. A background window's controls are not in the frame, so they
//     are not in the table; nothing can be marked at coordinates that don't
//     exist in the image the guide will publish.
//  2. **Unique** (W21) — one mark per element. The AX graph is not a tree:
//     a menu is reachable both as a child of its owning control and as a
//     child of the window, and the old walk emitted every item twice with
//     identical label, role AND rect, which made every macOS menu item
//     unaddressable by a resolver that (correctly) refuses on ambiguity.
//  3. **Named** (W19) — a chain that never yields an empty string, plus the
//     `label_source` that produced it (macOS reported no provenance at all
//     before). When AX gives nothing — the SwiftUI `TextField` case, which
//     exposes neither title nor value — the probe associates the visible
//     sibling `AXStaticText` that a human reads as the field's label, and
//     says so with `label_source: "adjacent-text"` so a consumer can weigh
//     an inferred name differently from an authored one.
//
//  And it sweeps the same subtree's static text into `page_text` (W20) so
//  `text_visible`-style assertions have something to assert against.
//

import CoreGraphics
import Foundation

// MARK: - Snapshot

/// One node of a captured accessibility tree — the pure input this probe
/// works over. Every field is a plain value read once from the live
/// `AXUIElement`; nothing here talks to the AX API.
///
/// `identity` is the live element's `CFHash`, which is stable for the
/// lifetime of the element and equal for two references to the SAME
/// element — the property the de-duplication in `probe` relies on.
struct AXSnapshotNode: Sendable, Equatable {
    var identity: UInt64
    var role: String
    var subrole: String?
    /// `AXTitle` — the authored name, when the control has one.
    var title: String?
    /// `AXValue`, when it is string-valued. On a text field this is the
    /// field's CONTENT, not a name; the label chain treats it accordingly.
    var value: String?
    /// `AXDescription` — AppKit's home for `accessibilityLabel`.
    var axDescription: String?
    /// `AXHelp` — tooltip prose.
    var help: String?
    /// `AXPlaceholderValue`.
    var placeholder: String?
    /// `AXIdentifier` — a developer-supplied test hook.
    var identifier: String?
    /// The resolved text of `AXTitleUIElement`, the platform's OWN
    /// "this element over there is my label" pointer. When an app sets it,
    /// it beats any inference we could make.
    var titleElementText: String?
    var enabled: Bool
    /// Bounding rect in GLOBAL screen points (top-left origin), or nil when
    /// the element reports no geometry.
    var rect: CGRect?
    var children: [AXSnapshotNode]

    init(
        identity: UInt64,
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        axDescription: String? = nil,
        help: String? = nil,
        placeholder: String? = nil,
        identifier: String? = nil,
        titleElementText: String? = nil,
        enabled: Bool = true,
        rect: CGRect? = nil,
        children: [AXSnapshotNode] = []
    ) {
        self.identity = identity
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.axDescription = axDescription
        self.help = help
        self.placeholder = placeholder
        self.identifier = identifier
        self.titleElementText = titleElementText
        self.enabled = enabled
        self.rect = rect
        self.children = children
    }
}

// MARK: - Probe

enum MacMarkProbe {

    /// Cap on returned marks — same as web / iOS. Past this, badges overlap
    /// into illegibility for a small vision model.
    static let markCap = 80

    /// Placeholder for an element with no derivable name at all. Rendered as
    /// e.g. `unlabelled textField`. NEVER an empty string: an empty label is
    /// unaddressable — a resolver can't key on it and an agent can't name it
    /// in a flow. Parity with `WebMarkProbe.synthesizedLabelPrefix` (W15).
    static let synthesizedLabelPrefix = "unlabelled "

    /// Longest `page_text` handed back, in Characters. Same cap the web
    /// driver uses, so a consumer sees one contract across platforms.
    static let pageTextCap = 20_000

    /// AX roles treated as actionable tap targets. A mix of `kAX…Role`
    /// constants and string literals for roles HIServices ships no constant
    /// for (`AXLink`, defined by AppKit at runtime).
    static let actionableRoles: Set<String> = [
        "AXButton",
        "AXMenuButton",
        "AXPopUpButton",
        "AXMenuItem",
        "AXMenuBarItem",
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXCheckBox",
        "AXRadioButton",
        "AXSlider",
        "AXIncrementor",
        "AXDisclosureTriangle",
        "AXColorWell",
        "AXImage",
        "AXRow",
        "AXCell",
        "AXTabGroup",
        "AXLink",
        "AXSecureTextField",
        "AXSearchField",
        "AXStepper",
        "AXSwitch"
    ]

    /// Roles whose `AXValue` is the control's CONTENT rather than its name.
    /// For these the value is the weakest possible label — it changes the
    /// moment the user types, and a resolver keyed on it is born stale — so
    /// the chain reaches for the adjacent visible label FIRST and only falls
    /// back to content if nothing else exists. (This is the macOS shape of
    /// the W1 finding that moved `placeholder` down the web chain.)
    static let textEntryRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"
    ]

    /// Roles that hold text we sweep into `page_text`.
    static let staticTextRoles: Set<String> = ["AXStaticText", "AXHeading"]

    /// Roles that present ON TOP of the window that owns them. When one is
    /// visible inside the captured frame, the frame belongs to IT and the
    /// rest of the window is background (the macOS shape of the web probe's
    /// modal rule).
    static let overlayRoles: Set<String> = ["AXSheet", "AXPopover", "AXMenu", "AXDrawer"]

    /// Minimum on-screen size for a mark. Below this a badge can't be
    /// placed legibly and the target can't be clicked reliably.
    static let minimumMarkExtent: CGFloat = 16

    // MARK: Result

    struct Result: Sendable, Equatable {
        var marks: [InteractiveMark]
        var pageText: String?
    }

    /// A hit-test seam: given a point in GLOBAL screen space, the identity of
    /// the element the app would route a click there to (or nil when the
    /// probe can't tell). Supplied live by `MacAppDriver` via
    /// `AXUIElementCopyElementAtPosition`; supplied synthetically by tests.
    typealias HitTest = (CGPoint) -> UInt64?

    /// Run the probe.
    ///
    /// - Parameters:
    ///   - roots: candidate AX roots (the app's windows, plus its focused /
    ///     main window). The one whose geometry matches `frame` is chosen;
    ///     see `selectRoot`.
    ///   - frame: the CAPTURED window's rect in global screen points. Every
    ///     returned rect is in this frame's space (origin at its top-left),
    ///     because this is the image the marks will be drawn on and the
    ///     guide will publish.
    ///   - hitTest: optional occlusion probe. When supplied, a candidate
    ///     whose own point routes to an unrelated element is dropped — that
    ///     is a control behind the front sheet / popover, or the hidden pane
    ///     of a tab view. When nil, occlusion filtering is skipped entirely
    ///     (never guessed).
    static func probe(
        roots: [AXSnapshotNode],
        frame: CGRect,
        hitTest: HitTest? = nil,
        cap: Int = markCap
    ) -> Result {
        guard let root = selectRoot(roots: roots, frame: frame) else {
            return Result(marks: [], pageText: nil)
        }
        // A sheet / popover / menu inside the chosen root owns the frame.
        let scoped = frontOverlay(in: root, frame: frame) ?? root

        var candidates: [Candidate] = []
        var texts: [TextItem] = []
        var visited: Set<UInt64> = []
        walk(
            node: scoped,
            frame: frame,
            ancestry: [],
            depth: 0,
            visited: &visited,
            candidates: &candidates,
            texts: &texts
        )

        // Label association — computed across ALL candidates at once so a
        // static text can label at most one control (see `associateLabels`).
        let labels = associateLabels(candidates: candidates, texts: texts)

        // Reading order, then the identical-mark collapse, then the cap.
        var ordered = candidates.enumerated().map { (i, c) in (index: i, candidate: c) }
        ordered.sort { a, b in
            if abs(a.candidate.rect.minY - b.candidate.rect.minY) >= 1 {
                return a.candidate.rect.minY < b.candidate.rect.minY
            }
            if abs(a.candidate.rect.minX - b.candidate.rect.minX) >= 1 {
                return a.candidate.rect.minX < b.candidate.rect.minX
            }
            return a.index < b.index
        }

        var seenKeys: Set<String> = []
        var marks: [InteractiveMark] = []
        for entry in ordered {
            let c = entry.candidate
            // Occlusion (optional), evaluated LAZILY in reading order: a
            // control a click at its own point would not reach isn't
            // actionable, whatever the tree says. Doing it here rather than
            // over every candidate means an app with 200 candidates and an
            // 80-mark cap pays for at most the marks it actually emits —
            // each check is an IPC round trip to the target app.
            if let hitTest, !reachable(c, frame: frame, hitTest: hitTest) { continue }
            let resolved = labels[c.identity] ?? Label(text: synthesized(for: c.role), source: "synthesized")
            // W21 — collapse marks that are indistinguishable to a resolver:
            // same role, same label, same rect. Identity de-duplication in
            // the walk catches the same ELEMENT twice; this catches two
            // distinct elements the agent could never tell apart anyway.
            let key = "\(c.role)|\(resolved.text)|\(Int(c.rect.minX.rounded()))|\(Int(c.rect.minY.rounded()))|\(Int(c.rect.width.rounded()))|\(Int(c.rect.height.rounded()))"
            if seenKeys.contains(key) { continue }
            seenKeys.insert(key)
            marks.append(
                InteractiveMark(
                    id: marks.count + 1,
                    rect: c.rect,
                    role: shortRole(c.role),
                    inputType: nil,
                    label: resolved.text,
                    labelSource: resolved.source
                )
            )
            if marks.count >= cap { break }
        }

        return Result(marks: marks, pageText: pageText(texts: texts))
    }

    // MARK: Root selection (W24)

    /// Pick the AX root that corresponds to the captured frame.
    ///
    /// The capture side resolves the front window from the CoreGraphics
    /// window list; the AX side has its own idea of "focused window" and the
    /// two disagree exactly when it matters — a popover is a separate CG
    /// window while `AXFocusedWindow` still points at the main window. That
    /// disagreement is what put main-window-space rects on a popover frame.
    /// Matching by geometry makes the frame the authority.
    ///
    /// Falls back to the first root with any overlap, then to the first root
    /// at all, so a probe never returns nothing merely because an app models
    /// its windows unusually — the rect conversion + clip in `walk` still
    /// keeps every reported rect inside the frame.
    static func selectRoot(roots: [AXSnapshotNode], frame: CGRect) -> AXSnapshotNode? {
        guard !roots.isEmpty else { return nil }
        // Score by how much of the FRAME a root covers — not by IoU. A
        // popover is a small window inside a large one: by IoU the main
        // window wins (it overlaps everything), by containment the popover
        // does, and containment is the question we're actually asking. Among
        // roots that contain the frame, the SMALLEST one is the overlay.
        var best: (node: AXSnapshotNode, containment: CGFloat, area: CGFloat)?
        for root in roots {
            guard let r = root.rect else { continue }
            let inter = r.intersection(frame)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            let containment = (inter.width * inter.height) / max(1, frame.width * frame.height)
            let area = r.width * r.height
            let better: Bool
            if let best {
                if abs(containment - best.containment) > 0.05 {
                    better = containment > best.containment
                } else {
                    better = area < best.area
                }
            } else {
                better = true
            }
            if better { best = (root, containment, area) }
        }
        guard let best else { return nil }
        if best.containment >= 0.9 { return best.node }
        // The frame is NOT (mostly) inside any root we can see — an overlay
        // window the app doesn't advertise in `AXWindows`. Return the root
        // only if it holds an overlay that DOES cover the frame; otherwise
        // refuse. Clipping a background window's controls into this frame
        // would produce marks whose rects point at the overlay's pixels and
        // whose targets are behind it: a wrong table, which is worse than an
        // empty one (the caller can see empty and re-observe).
        return frontOverlay(in: best.node, frame: frame) != nil ? best.node : nil
    }

    /// The deepest visible sheet / popover / menu inside `root` that covers
    /// (most of) the captured frame, or nil. When one exists, the rest of
    /// the window behind it is background — the macOS analogue of the web
    /// probe's `topModal`.
    static func frontOverlay(in root: AXSnapshotNode, frame: CGRect) -> AXSnapshotNode? {
        var found: AXSnapshotNode?
        var foundDepth = -1
        func recurse(_ node: AXSnapshotNode, depth: Int) {
            if depth > 24 { return }
            if overlayRoles.contains(node.role), let r = node.rect {
                let inter = r.intersection(frame)
                if !inter.isNull, inter.width > 0, inter.height > 0 {
                    // Require the overlay to actually own the frame: at least
                    // 60% of the captured area. A small inline popover on a
                    // full-window capture does NOT turn the window into
                    // background — the window is still what the human sees.
                    let coverage = (inter.width * inter.height) / max(1, frame.width * frame.height)
                    // DEEPEST wins: a menu opened from inside a sheet is what
                    // the frame shows, and scoping to the sheet instead would
                    // suppress the menu's own items as sub-controls.
                    if coverage >= 0.6, depth > foundDepth {
                        found = node
                        foundDepth = depth
                    }
                }
            }
            for child in node.children { recurse(child, depth: depth + 1) }
        }
        recurse(root, depth: 0)
        return found
    }

    // MARK: Walk

    struct Candidate: Sendable {
        var identity: UInt64
        var role: String
        /// Frame-local, clipped rect (what gets reported).
        var rect: CGRect
        /// Global rect, unclipped — used for hit-testing.
        var globalRect: CGRect
        var node: AXSnapshotNode
        /// Root→parent identity chain, for the common-ancestor guardrail.
        var ancestry: [UInt64]
        /// Every identity in this element's own subtree, for occlusion.
        var subtree: Set<UInt64>
    }

    struct TextItem: Sendable {
        var identity: UInt64
        var text: String
        var rect: CGRect
        var ancestry: [UInt64]
        /// True when this text lives INSIDE an actionable control (a button's
        /// own caption). Such text is that control's name, never a neighbour's.
        var insideControl: Bool
        /// Reading-order sequence, for `page_text`.
        var order: Int
    }

    private static func walk(
        node: AXSnapshotNode,
        frame: CGRect,
        ancestry: [UInt64],
        depth: Int,
        insideControl: Bool = false,
        suppressCandidates: Bool = false,
        visited: inout Set<UInt64>,
        candidates: inout [Candidate],
        texts: inout [TextItem]
    ) {
        if depth > 24 { return }
        // NOTE: the candidate cap is applied where candidates are APPENDED,
        // not here. Bailing out of the whole walk at 200 candidates would
        // silently truncate `page_text` to an arbitrary prefix of the window
        // — with none of the trailing `…` that marks an honest truncation.
        if texts.count >= 2000 { return }
        // W21 — the AX graph is not a tree. The same element is reachable by
        // more than one path (a menu hangs off both its owning control and
        // the window), and the old walk emitted it once per path. Visiting an
        // element at most once per probe is the fix at the root.
        // Keyed on the SUPPRESSION STATE too: the same element reachable
        // both under an already-marked container (suppressed) and directly
        // under the window (not) must still get its chance to be a mark —
        // keying on identity alone makes that depend on which path the walk
        // happened to take first. The (role, label, rect) collapse below
        // keeps the table free of the duplicates this allows through.
        let visitKey = node.identity &* 2 &+ (suppressCandidates ? 1 : 0)
        if visited.contains(visitKey) { return }
        visited.insert(visitKey)

        var childInsideControl = insideControl
        var childSuppress = suppressCandidates

        if staticTextRoles.contains(node.role), let global = node.rect {
            let local = localRect(global, frame: frame)
            if let local, let text = normalizedText(node.value ?? node.title ?? node.axDescription) {
                texts.append(
                    TextItem(
                        identity: node.identity,
                        text: text,
                        rect: local,
                        ancestry: ancestry,
                        insideControl: insideControl,
                        order: texts.count
                    )
                )
            }
        }

        // Text inside ANY actionable element belongs to that element, whether
        // or not this walk chose to badge it. Deciding this inside the
        // candidacy branch would leave a nested button's caption free to be
        // adopted as a NEIGHBOUR's label — the exact false association the
        // whole guardrail set exists to prevent.
        if actionableRoles.contains(node.role) { childInsideControl = true }

        if !suppressCandidates,
           actionableRoles.contains(node.role), node.enabled, let global = node.rect,
           let local = localRect(global, frame: frame),
           local.width >= minimumMarkExtent, local.height >= minimumMarkExtent,
           candidates.count < 200 {
            candidates.append(
                Candidate(
                    identity: node.identity,
                    role: node.role,
                    rect: local,
                    globalRect: global,
                    node: node,
                    ancestry: ancestry,
                    subtree: subtreeIdentities(node)
                )
            )
            // The OUTERMOST actionable wins the badge — a row that contains a
            // button gets one mark, not two (unchanged from the pre-W19
            // walk, which returned here outright). We keep DESCENDING now
            // only to collect text: a row's caption is what names it, and
            // `page_text` must see text nested under controls.
            childSuppress = true
        }
        // An overlay is PRESENTED on top of whatever owns it — a pop-up
        // button's menu is not "part of the button" the way a row's caption
        // is part of the row. Reset the outermost-wins suppression at an
        // overlay boundary, or a menu opened from a marked control would
        // contribute no items at all.
        if overlayRoles.contains(node.role) { childSuppress = false }

        let nextAncestry = ancestry + [node.identity]
        for child in node.children {
            walk(
                node: child,
                frame: frame,
                ancestry: nextAncestry,
                depth: depth + 1,
                insideControl: childInsideControl,
                suppressCandidates: childSuppress,
                visited: &visited,
                candidates: &candidates,
                texts: &texts
            )
            if texts.count >= 2000 { return }
        }
    }

    /// Global → frame-local, clipped to the frame. Returns nil when the
    /// element has no visible intersection with the captured frame — which
    /// is precisely how a background window's controls leave the table (W24).
    static func localRect(_ global: CGRect, frame: CGRect) -> CGRect? {
        let inter = global.intersection(frame)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return nil }
        return CGRect(
            x: inter.minX - frame.minX,
            y: inter.minY - frame.minY,
            width: inter.width,
            height: inter.height
        )
    }

    private static func subtreeIdentities(_ node: AXSnapshotNode) -> Set<UInt64> {
        var out: Set<UInt64> = []
        var stack = [node]
        var guardCount = 0
        while let n = stack.popLast(), guardCount < 4000 {
            guardCount += 1
            if !out.insert(n.identity).inserted { continue }
            stack.append(contentsOf: n.children)
        }
        return out
    }

    /// Would a click at this control's own point reach it? Accepts a hit on
    /// the element, on one of its descendants (the usual case — the button's
    /// label is what's topmost) or on one of its ancestors (the element
    /// simply doesn't paint at that exact point). Anything else means
    /// something unrelated is on top: another window behind the front
    /// popover, or the hidden pane of a tab view.
    ///
    /// Generous by design — a FALSE DROP makes a real control unaddressable,
    /// which is worse than a stale row. Several points are tried, and an
    /// unavailable hit test (nil) counts as reachable.
    private static func reachable(_ c: Candidate, frame: CGRect, hitTest: HitTest) -> Bool {
        let r = c.globalRect.intersection(frame)
        guard !r.isNull, r.width > 0, r.height > 0 else { return true }
        let points: [CGPoint] = [
            CGPoint(x: r.midX, y: r.midY),
            CGPoint(x: r.minX + min(4, r.width / 4), y: r.midY),
            CGPoint(x: r.maxX - min(4, r.width / 4), y: r.midY),
            CGPoint(x: r.midX, y: r.minY + min(4, r.height / 4)),
            CGPoint(x: r.midX, y: r.maxY - min(4, r.height / 4))
        ]
        var sawAnswer = false
        for p in points {
            guard let hit = hitTest(p) else { continue }
            sawAnswer = true
            if c.subtree.contains(hit) { return true }
            if c.ancestry.contains(hit) { return true }
        }
        // No usable answer anywhere → don't drop on a guess.
        return !sawAnswer
    }

    // MARK: Labels (W19)

    struct Label: Sendable, Equatable {
        var text: String
        var source: String
    }

    /// Resolve every candidate's label, using adjacent static text only for
    /// the ones AX could not name.
    ///
    /// Association guardrails — a WRONG label is worse than an honest
    /// `unlabelled textField`, so every one of these must hold:
    ///
    ///  * the control has NO AX-native name (title, `AXTitleUIElement`,
    ///    description, help, placeholder). Inference never overrides the app;
    ///  * the text is short enough to be a field label (≤ 60 chars) and is
    ///    not itself inside some control (a button's caption names that
    ///    button, not its neighbour);
    ///  * the text sits LEFT of the control on the same row (≤ 120pt gap,
    ///    ≥ 50% vertical overlap) or immediately ABOVE it (≤ 16pt gap,
    ///    left-aligned within 12pt or ≥ 50% horizontal overlap). The
    ///    horizontal budget is generous because a real form lays labels out
    ///    in a fixed-width column while AX reports the TEXT's intrinsic
    ///    width, so a 90pt label column shows up as a ~70pt gap;
    ///  * NOTHING actionable sits between the two. A generous distance is
    ///    only safe with this: the moment another control intervenes, the
    ///    text belongs to that one (or to nobody), not to this one;
    ///  * the two share a common ancestor within 3 levels of the control —
    ///    "same row / same form field group", not "somewhere on screen";
    ///  * each static text labels AT MOST ONE control. Two fields cannot
    ///    both be "Host": the nearer one wins and the other stays honestly
    ///    unlabelled;
    ///  * the winner must be strictly nearer than the runner-up (by more
    ///    than 2pt) — a tie is ambiguous, and ambiguity refuses.
    static func associateLabels(candidates: [Candidate], texts: [TextItem]) -> [UInt64: Label] {
        var out: [UInt64: Label] = [:]
        var needsAdjacent: [Candidate] = []

        for c in candidates {
            if let native = nativeLabel(c.node) {
                out[c.identity] = native
            } else {
                needsAdjacent.append(c)
            }
        }

        // Texts eligible to act as a label for someone.
        let controlIdentities = Set(candidates.map(\.identity))
        let eligible = texts.filter { t in
            !t.insideControl
                && !controlIdentities.contains(t.identity)
                && t.text.count <= 60
                && t.text.rangeOfCharacter(from: .letters) != nil
        }

        // Score every (control, text) pair that passes the geometry +
        // ancestry gates, then assign greedily by ascending distance so a
        // text can only ever name one control.
        // `order` is the control's reading-order position: the tiebreaker
        // that keeps assignment DETERMINISTIC. Without it, two controls
        // equidistant from two different texts would be resolved in
        // dictionary-iteration order, and the same screen could label
        // differently between two runs of the same flow.
        struct Pairing {
            var control: UInt64
            var order: Int
            var controlRect: CGRect
            var textIdentity: UInt64
            var text: String
            var rank: Int
            var distance: CGFloat
        }
        /// Ascending: nearer first, then left-of before above, then reading
        /// order. Total and stable.
        func precedes(_ a: Pairing, _ b: Pairing) -> Bool {
            if a.rank != b.rank { return a.rank < b.rank }
            if a.distance != b.distance { return a.distance < b.distance }
            if a.controlRect.minY != b.controlRect.minY { return a.controlRect.minY < b.controlRect.minY }
            if a.controlRect.minX != b.controlRect.minX { return a.controlRect.minX < b.controlRect.minX }
            return a.order < b.order
        }
        var pairings: [Pairing] = []
        // Identity, not rect: a container and its only child routinely
        // report the SAME rect, and excluding by rect would let the child
        // stop counting as an obstacle for its own container.
        let obstacles = candidates.map { (identity: $0.identity, rect: $0.rect) }
        for (order, c) in needsAdjacent.enumerated() {
            for t in eligible {
                guard sharesNearAncestor(control: c, text: t) else { continue }
                guard let (rank, distance) = adjacency(control: c.rect, text: t.rect) else { continue }
                guard !isBlocked(control: c, text: t, rank: rank, obstacles: obstacles) else { continue }
                pairings.append(Pairing(
                    control: c.identity, order: order, controlRect: c.rect,
                    textIdentity: t.identity, text: t.text, rank: rank, distance: distance
                ))
            }
        }
        // Ambiguity refusal: if a control's two best candidates are
        // effectively equidistant in the same direction, refuse both.
        var byControl: [UInt64: [Pairing]] = [:]
        for p in pairings { byControl[p.control, default: []].append(p) }
        var accepted: [Pairing] = []
        for control in needsAdjacent {
            guard let list = byControl[control.identity] else { continue }
            let sorted = list.sorted(by: precedes)
            guard let first = sorted.first else { continue }
            if sorted.count > 1 {
                let second = sorted[1]
                if second.rank == first.rank,
                   second.distance - first.distance <= 2,
                   second.text != first.text {
                    continue    // ambiguous — stay honestly unlabelled
                }
            }
            accepted.append(first)
        }

        // The mirror of the per-control refusal: one text, two equally good
        // claimants. Greedy assignment would hand it to whichever sorts
        // first and leave the other unlabelled — one of the two would be
        // WRONG, and nothing in the output would say which. A header
        // centred over two side-by-side fields is exactly this shape.
        var byText: [UInt64: [Pairing]] = [:]
        for p in accepted { byText[p.textIdentity, default: []].append(p) }
        var contested: Set<UInt64> = []
        for (textID, list) in byText where list.count > 1 {
            let sorted = list.sorted(by: precedes)
            if sorted[1].rank == sorted[0].rank, sorted[1].distance - sorted[0].distance <= 2 {
                contested.insert(textID)
            }
        }

        var usedTexts: Set<UInt64> = []
        for p in accepted.sorted(by: precedes) where !contested.contains(p.textIdentity) {
            guard !usedTexts.contains(p.textIdentity), out[p.control] == nil else { continue }
            usedTexts.insert(p.textIdentity)
            out[p.control] = Label(text: trimLabelPunctuation(p.text), source: "adjacent-text")
        }

        // Whatever adjacency couldn't name falls through the weak tail: the
        // control's OWN visible text (a table row's caption — the macOS shape
        // of the web chain's `text` rule), then the developer's identifier,
        // then the control's content, then a synthesized placeholder. Never
        // an empty string.
        for c in needsAdjacent where out[c.identity] == nil {
            if let own = containedText(control: c, texts: texts) {
                out[c.identity] = own
                continue
            }
            out[c.identity] = weakLabel(c.node) ?? Label(text: synthesized(for: c.role), source: "synthesized")
        }
        return out
    }

    /// The AX-native part of the chain: everything the app itself said.
    /// Returns nil when the app said nothing usable, which is the ONLY
    /// condition under which adjacency is allowed to speak.
    static func nativeLabel(_ node: AXSnapshotNode) -> Label? {
        // A secure field's value is the plaintext on some AppKit paths; it
        // must never become a label, in the mark table, the structured
        // marks, or the agent's context. Same rule the web probe enforces.
        let secure = node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField"
        if let v = normalizedText(node.title) { return Label(text: cap(v), source: "ax-title") }
        if let v = normalizedText(node.titleElementText) { return Label(text: cap(v), source: "ax-title-element") }
        if let v = normalizedText(node.axDescription) { return Label(text: cap(v), source: "ax-description") }
        if let v = normalizedText(node.help) { return Label(text: cap(v), source: "ax-help") }
        if secure { return Label(text: "Password", source: "secure-field") }
        if let v = normalizedText(node.placeholder) { return Label(text: cap(v), source: "ax-placeholder") }
        // For a control whose AXValue is a NAME (a pop-up button's current
        // selection, a menu item's title-ish value) the value is a fine
        // label. For a text-entry control it is the user's content, which
        // moves under the resolver's feet — those wait for adjacency first.
        if !textEntryRoles.contains(node.role), let v = normalizedText(node.value) {
            return Label(text: cap(v), source: "value")
        }
        return nil
    }

    /// The control's own visible text, in reading order, joined — what a
    /// human reads off the control itself. This is how an unlabelled
    /// `AXRow` ("Production server · 22") becomes addressable at all.
    /// Capped at three fragments so a whole table row of columns doesn't
    /// become an 80-character label.
    static func containedText(control: Candidate, texts: [TextItem]) -> Label? {
        let inside = texts
            .filter { $0.ancestry.contains(control.identity) }
            .sorted { a, b in
                if abs(a.rect.minY - b.rect.minY) >= 1 { return a.rect.minY < b.rect.minY }
                return a.rect.minX < b.rect.minX
            }
            .prefix(3)
            .map(\.text)
        guard !inside.isEmpty else { return nil }
        let joined = inside.joined(separator: " ")
        guard let normalized = normalizedText(joined) else { return nil }
        return Label(text: cap(normalized), source: "text")
    }

    /// The tail of the chain, tried only after adjacency has had its turn.
    static func weakLabel(_ node: AXSnapshotNode) -> Label? {
        if let v = normalizedText(node.identifier) { return Label(text: cap(v), source: "ax-identifier") }
        let secure = node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField"
        if !secure, let v = normalizedText(node.value) { return Label(text: cap(v), source: "value") }
        return nil
    }

    /// `(rank, distance)` for an acceptable label position, or nil.
    /// Rank 0 = left-of on the same row (the SwiftUI `Form` / `LabeledContent`
    /// shape); rank 1 = directly above (the `VStack` shape). Left wins ties.
    static func adjacency(control: CGRect, text: CGRect) -> (rank: Int, distance: CGFloat)? {
        // Left-of, same row.
        let horizontalGap = control.minX - text.maxX
        if horizontalGap >= -2, horizontalGap <= 120 {
            let overlap = min(control.maxY, text.maxY) - max(control.minY, text.minY)
            let minHeight = min(control.height, text.height)
            if minHeight > 0, overlap >= minHeight * 0.5 {
                return (0, max(0, horizontalGap))
            }
        }
        // Directly above.
        let verticalGap = control.minY - text.maxY
        if verticalGap >= -2, verticalGap <= 16 {
            let leftAligned = abs(control.minX - text.minX) <= 12
            let overlap = min(control.maxX, text.maxX) - max(control.minX, text.minX)
            let minWidth = min(control.width, text.width)
            if leftAligned || (minWidth > 0 && overlap >= minWidth * 0.5) {
                return (1, max(0, verticalGap))
            }
        }
        return nil
    }

    /// Is there another marked control BETWEEN the text and this one? If so
    /// the text is not this control's label — it is the intervening
    /// control's, or nobody's. This is what makes the generous horizontal
    /// budget safe: distance alone would let a label jump the field it
    /// actually belongs to and name the next one along.
    static func isBlocked(
        control: Candidate,
        text: TextItem,
        rank: Int,
        obstacles: [(identity: UInt64, rect: CGRect)]
    ) -> Bool {
        let gap: CGRect
        if rank == 0 {
            let x = min(text.rect.maxX, control.rect.minX)
            let width = max(0, control.rect.minX - text.rect.maxX)
            guard width > 1 else { return false }
            gap = CGRect(x: x, y: control.rect.minY + 1, width: width, height: max(1, control.rect.height - 2))
        } else {
            let y = min(text.rect.maxY, control.rect.minY)
            let height = max(0, control.rect.minY - text.rect.maxY)
            guard height > 1 else { return false }
            gap = CGRect(x: control.rect.minX + 1, y: y, width: max(1, control.rect.width - 2), height: height)
        }
        for o in obstacles where o.identity != control.identity {
            let hit = o.rect.intersection(gap)
            if !hit.isNull, hit.width > 1, hit.height > 1 { return true }
        }
        return false
    }

    /// How far above the control the two chains first meet.
    static let maxAncestorDistance = 3

    /// "Same parent / same row" — the control and the text must meet at an
    /// ancestor no more than `maxAncestorDistance` levels above the control.
    ///
    /// Measured as the COMMON PREFIX of the two root→parent chains, not as
    /// set membership: a shallow tree (`[window, group]`, which is what a
    /// plain SwiftUI form actually produces) puts the walk root inside any
    /// "last three ancestors" set, and every text in the frame shares the
    /// root — so a membership test silently passes everything and leaves
    /// geometry as the only guard. Meeting AT the walk root is never near
    /// enough on its own; it is what "somewhere else on screen" looks like.
    static func sharesNearAncestor(control: Candidate, text: TextItem) -> Bool {
        var common = 0
        while common < control.ancestry.count,
              common < text.ancestry.count,
              control.ancestry[common] == text.ancestry[common] {
            common += 1
        }
        guard common > 0 else { return false }
        // Meeting only at the walk root, with the control nested below it,
        // is the "different section" case the guard exists to refuse.
        if common == 1 && control.ancestry.count > 1 { return false }
        return control.ancestry.count - common <= maxAncestorDistance
    }

    static func synthesized(for role: String) -> String {
        synthesizedLabelPrefix + shortRole(role)
    }

    /// Strip the trailing colon a form label usually carries, so
    /// `Host:` resolves the same way `Host` does.
    static func trimLabelPunctuation(_ s: String) -> String {
        var out = s
        while let last = out.last, last == ":" || last == "*" || last == " " {
            out.removeLast()
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? s : cap(trimmed)
    }

    static func normalizedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0 == "\n" || $0 == "\t" || $0 == " " || $0 == "\r" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    static func cap(_ s: String) -> String {
        s.count > 80 ? String(s.prefix(77)) + "…" : s
    }

    /// `AXButton` → `button`, matching the iOS / web role formatting.
    static func shortRole(_ raw: String) -> String {
        let body = raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
        guard let first = body.first else { return body }
        return first.lowercased() + body.dropFirst()
    }

    // MARK: page_text (W20)

    /// Roll the scoped subtree's static text up into one string, in reading
    /// order, so `text_visible` / `for_text` assertions have a text surface
    /// on macOS instead of silently degrading to searching control labels.
    ///
    /// Scoped by construction: `texts` only ever contains nodes the walk
    /// reached inside the captured frame, so a sheet's `page_text` is the
    /// sheet's text — not the window behind it.
    static func pageText(texts: [TextItem]) -> String? {
        guard !texts.isEmpty else { return nil }
        let ordered = texts.sorted { a, b in
            if abs(a.rect.minY - b.rect.minY) >= 1 { return a.rect.minY < b.rect.minY }
            if abs(a.rect.minX - b.rect.minX) >= 1 { return a.rect.minX < b.rect.minX }
            return a.order < b.order
        }
        var lines: [String] = []
        var seen: Set<String> = []
        for t in ordered {
            // The same string reachable at the same place twice adds nothing;
            // the same string in two PLACES is real repetition and is kept.
            let key = "\(t.text)|\(Int(t.rect.minY.rounded()))|\(Int(t.rect.minX.rounded()))"
            if seen.contains(key) { continue }
            seen.insert(key)
            lines.append(t.text)
        }
        var joined = lines.joined(separator: "\n")
        if joined.count > pageTextCap {
            joined = String(joined.prefix(pageTextCap - 1)) + "…"
        }
        return joined.isEmpty ? nil : joined
    }
}
