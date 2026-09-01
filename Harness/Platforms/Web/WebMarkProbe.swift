//
//  WebMarkProbe.swift
//  Harness
//
//  The Set-of-Mark (V6) element probe for web sessions, as a standalone
//  JavaScript source. `WebDriver.probeInteractiveElements()` evaluates it
//  right before every snapshot; keeping it out of the driver lets the test
//  suite run the SAME source against fixture pages in a real WKWebView
//  (`WebMarkProbeTests`) instead of asserting on a re-implementation.
//
//  The probe answers one question per candidate element: *could the agent
//  actually act on this right now, and what do we call it?* Three filters
//  and one naming chain make up that answer —
//
//  1. **Rendered** — visibility/display/opacity, `disabled`, a real rect
//     that intersects the viewport.
//  2. **Interactable** (W14, drop-help shakedown) — not `pointer-events:
//     none`, not inside an `inert` subtree, and not painted over by
//     something else (hit-test probe). While a modal dialog is open, the
//     dimmed background is excluded outright: only the modal's own
//     contents and whatever paints ABOVE it (toasts) stay in the table.
//     A modal is one the page DECLARED (`aria-modal`, `<dialog>.showModal`)
//     or, failing that, an unmistakable overlay shape (W31b).
//  3. **Named** (W15) — the accessible-name chain never yields an empty
//     string; every mark carries a usable label plus the `label_source`
//     that produced it, and a synthesized placeholder is made unique on
//     the frame so two nameless controls can't collide.
//
//  The same modal decision also scopes `page_text` (`pageTextJS`, W31a):
//  text an agent cannot see because a modal covers it must not satisfy a
//  text assertion. Both entry points share one prelude — the modal rule
//  is written once, so the two cannot drift.
//

import Foundation

enum WebMarkProbe {
    /// Cap on returned marks. With anchor inclusion (nav links, in-text
    /// links, footer link grids) an article-heavy page can produce 200+;
    /// past a point they overlap onto the same badge column and degrade
    /// legibility for a small vision model. The cap keeps the
    /// most-likely-actionable elements (top-of-page nav + above-the-fold
    /// content) badged; the rest get badged once the agent scrolls.
    static let markCap = 80

    /// Placeholder label given to an element with no derivable name at
    /// all. Rendered as e.g. `unlabelled button`. NEVER an empty string:
    /// an empty label is unaddressable — a downstream resolver can't key
    /// on it and the agent can't name it in a flow (W15).
    static let synthesizedLabelPrefix = "unlabelled "

    /// Window-global the mark walk parks its element list on, in the exact
    /// order (and slice) of the marks it returned, so `scroll_into_view(id)`
    /// can address mark *N* without re-walking the DOM or mutating it
    /// (WB-17 W7/W34). A page navigation wipes it, which is the honest
    /// answer: those ids belong to the frame that is gone.
    static let elementRegistryKey = "__harnessMarkElements"

    // MARK: - Shared prelude

    /// Helpers used by BOTH the mark walk and the page-text read: tree
    /// traversal, rendering, and — the reason this is shared at all — the
    /// modal decision. `modal` is in scope for everything after it.
    private static let preludeJS: String = #"""
      // Targets where pixel precision matters. `a[href]` is included
      // because nav links in SPAs (Next.js Link, React Router Link,
      // etc.) all render as anchors — excluding them leaves the
      // top-of-page navigation un-marked, forcing the agent to fall
      // back to `tap(x, y)`. For local sub-10B vision models that
      // see a downscaled screenshot, those raw coordinates frequently
      // land on a neighbour nav item (verified with Qwen3-VL 8B at
      // 768-wide vs 1280-wide viewport). Anchor inclusion is what
      // makes `tap_mark` actually usable for navigation.
      //
      // Decorative anchors (empty href, anchor jumps, javascript:
      // pseudo-protocols) stay excluded — they'd badge map markers
      // and footer scroll-to-top arrows without buying real value.
      const SELECTOR = [
        'input:not([type="hidden"]):not([type="button"]):not([type="submit"]):not([type="reset"])',
        'textarea',
        'select',
        'button',
        'input[type="button"]',
        'input[type="submit"]',
        'input[type="reset"]',
        'a[href]:not([href=""]):not([href="#"]):not([href^="javascript:"])',
        '[role="link"]',
        '[role="button"]',
        '[role="checkbox"]',
        '[role="radio"]',
        '[role="textbox"]',
        '[role="combobox"]',
        '[role="searchbox"]',
        '[role="switch"]',
        '[role="menuitem"]',
        '[role="tab"]',
        '[contenteditable=""]',
        '[contenteditable="true"]'
      ].join(', ');

      const vw = window.innerWidth, vh = window.innerHeight;

      const norm = (s) => String(s == null ? '' : s).trim().replace(/\s+/g, ' ');

      // ---- tree helpers (shadow-DOM aware) -------------------------------

      // True when `node` is `target` or a descendant of it, crossing open
      // shadow boundaries via the host chain. `Node.contains` stops at a
      // shadow root, which would make every custom-element-hosted control
      // look unrelated to its own host.
      function withinDeep(node, target) {
        let n = node, guard = 0;
        while (n && guard++ < 400) {
          if (n === target) return true;
          if (n.parentElement) { n = n.parentElement; continue; }
          const p = n.parentNode;
          if (p && p.host) { n = p.host; continue; }
          n = p && p.nodeType === 1 ? p : null;
        }
        return false;
      }

      // Nearest ancestor matching `sel`, crossing open shadow boundaries.
      function closestDeep(el, sel) {
        let n = el, guard = 0;
        while (n && guard++ < 400) {
          try {
            if (n.closest) {
              const hit = n.closest(sel);
              if (hit) return hit;
              // Nothing at this level; hop out of the shadow root, if any.
              const root = n.getRootNode ? n.getRootNode() : null;
              n = root && root.host ? root.host : null;
              continue;
            }
          } catch (e) {}
          return null;
        }
        return null;
      }

      function rendered(el) {
        try {
          const cs = window.getComputedStyle(el);
          if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') return false;
          const r = el.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        } catch (e) { return false; }
      }

      // Where `el` sits in the paint order, as the pair a CSS painter would
      // compare: the z-index of its nearest positioned ancestor-or-self that
      // establishes one, and that ancestor itself (for the document-order
      // tiebreak).
      function stackRank(el) {
        let n = el, guard = 0;
        while (n && n.nodeType === 1 && guard++ < 400) {
          let cs = null;
          try { cs = window.getComputedStyle(n); } catch (e) { break; }
          const zi = parseInt(cs.zIndex, 10);
          if (!isNaN(zi) && cs.position !== 'static') return { z: zi, node: n };
          const root = n.getRootNode ? n.getRootNode() : null;
          n = n.parentElement || (root && root.host) || null;
        }
        return { z: 0, node: el };
      }

      // ---- modal layer ---------------------------------------------------

      // The topmost open modal the page DECLARED, or null. A modal makes
      // everything behind it inert by definition — `<dialog>.showModal()`
      // literally does, and the aria-modal convention asserts the same.
      // Non-modal `<dialog open>` (from `.show()`) does NOT qualify: the
      // page around it stays live. Last in document order wins, which
      // matches the usual stacking of portal-rendered dialogs.
      function declaredModal() {
        let found = null;
        let nodes = [];
        try {
          nodes = document.querySelectorAll('dialog[open], [aria-modal="true"]');
        } catch (e) { nodes = []; }
        for (const n of nodes) {
          if (n.tagName === 'DIALOG') {
            let isModal = true;
            try { if (n.matches(':modal') === false) isModal = false; } catch (e) { isModal = true; }
            if (!isModal) continue;
          } else if (norm(n.getAttribute('aria-modal')) !== 'true') {
            continue;
          }
          if (!rendered(n)) continue;
          found = n;
        }
        return found;
      }

      // Alpha of an element's own background-color: 0 for `transparent`,
      // 1 for an opaque colour, the fraction for a translucent one.
      //
      // This must NOT assume `rgb()` / `rgba()`. WebKit serializes a
      // computed `background-color` in whatever space the author wrote, and
      // Tailwind v4 — which is where the literal `bg-black/50` in the
      // comment below comes from — compiles its `/opacity` modifier to
      // `color-mix(in oklab, …)`, computing to `oklab(… / 0.5)` or
      // `color(srgb … / 0.5)`. A parser that only knew `rgba()` would read
      // every such overlay as alpha 0, which fails BOTH the dimming test
      // and the content-box test — the W31b rule would be quietly inert on
      // the exact stack that motivated it.
      //
      // So: pull the alpha out of any functional notation — the `/ <alpha>`
      // slash form of CSS Color 4, or a 4th comma-separated component for
      // the legacy forms — and default to 1 (OPAQUE) for a colour we can
      // read but not decompose. Defaulting to 0 would be the unsafe guess
      // in both directions; only an explicit `transparent` / zero alpha is
      // treated as nothing there.
      const ALPHA_UNKNOWN = 1;
      function alphaOf(color) {
        const c = String(color || '').trim().toLowerCase();
        if (!c || c === 'transparent' || c === 'none') return 0;
        const m = c.match(/^[a-z-]+\(([\s\S]*)\)$/);
        if (!m) return ALPHA_UNKNOWN;              // a keyword or a hex triplet
        const args = m[1];
        const parse = (token) => {
          const t = String(token).trim();
          if (!t) return NaN;
          if (t.endsWith('%')) {
            const pct = parseFloat(t);
            return isNaN(pct) ? NaN : pct / 100;
          }
          const n = parseFloat(t);
          return isNaN(n) ? NaN : n;
        };
        const slash = args.split('/');
        if (slash.length === 2) {
          const a = parse(slash[1]);
          return isNaN(a) ? ALPHA_UNKNOWN : a;
        }
        const commas = args.split(',');
        if (commas.length === 4) {
          const a = parse(commas[3]);
          return isNaN(a) ? ALPHA_UNKNOWN : a;
        }
        return ALPHA_UNKNOWN;
      }

      function bgAlpha(el) {
        try { return alphaOf(window.getComputedStyle(el).backgroundColor); }
        catch (e) { return 0; }
      }

      function coversViewport(r) {
        return r.width >= vw * 0.9 && r.height >= vh * 0.9
            && r.left <= vw * 0.05 && r.top <= vh * 0.05;
      }

      // Does `el` contain a control that is actually LIVE — i.e. one the
      // user could click? `pointer-events` is inherited, so a portal
      // wrapper marked `pointer-events: none` with a `pointer-events: auto`
      // card inside it (the shape Radix / Headless UI render) has live
      // controls, while a decorative veil's do not. That distinction is
      // what separates a dialog from scenery; a bare `querySelector` would
      // conflate them.
      function hasLiveControl(el) {
        let nodes = [];
        try { nodes = el.querySelectorAll ? el.querySelectorAll(SELECTOR) : []; } catch (e) { return false; }
        let guard = 0;
        for (const c of nodes) {
          if (guard++ > 200) break;
          try {
            if (window.getComputedStyle(c).pointerEvents === 'none') continue;
          } catch (e) { continue; }
          if (!rendered(c)) continue;
          return true;
        }
        return false;
      }

      // W31b — the drop-help delete-confirmation dialog.
      //
      // The W14 filter keys on what the page DECLARES: `aria-modal="true"`
      // or a `<dialog>` in the top layer. drop-help's "Add New Site" dialog
      // says so; its delete-confirm — a plain React portal of
      // `<div class="fixed inset-0 z-50 bg-black/50 flex items-center …">`
      // wrapping a card — says nothing at all, so the dimmed dashboard
      // behind it kept every mark.
      //
      // Rather than invent semantics, recognise the SHAPE, and only the
      // unmistakable one. Every clause below is a guardrail; a candidate
      // must satisfy all of them:
      //
      //   1. NO declared modal exists. A page that names its modal is
      //      always taken at its word — this heuristic can never override,
      //      widen or second-guess the W14 behaviour, including the
      //      scrim-wrapper case where the declared dialog is the right
      //      answer and its wrapper is not.
      //   2. `position: fixed`. A sticky header, an ordinary layout
      //      container and an in-flow hero are all excluded outright.
      //   3. It covers ≥90% of the viewport in BOTH axes and starts at the
      //      top-left region — a toast, a dropdown and a side panel are out.
      //   4. It DIMS: its own background-colour alpha, or a full-viewport
      //      descendant's, is strictly between 0 and 1. This is the
      //      load-bearing clause — a scrim is translucent by definition,
      //      and a fully OPAQUE full-screen layer needs no help from this
      //      rule because the occlusion hit-test already drops everything
      //      it covers. That asymmetry is what keeps an opaque full-screen
      //      app shell (the obvious false positive) out: it isn't
      //      translucent, so it isn't a scrim, and its content is not
      //      swallowed. Nothing weaker counts — a `backdrop-filter` alone
      //      is a decorative treatment, not a barrier.
      //   5. It holds at least one LIVE control (see `hasLiveControl` —
      //      `pointer-events: none` scenery does not count) AND a CONTENT
      //      BOX: a rendered descendant, at least 40×40, no more than 75%
      //      of the viewport's area, with an opaque-ish background of its
      //      own, CENTRED in the viewport, holding a live control of its
      //      own. That is a dialog card. A decorative tint layer, a
      //      translucent loading veil, a table-of-contents rail and an
      //      edge-pinned cookie bar all fail one half or the other.
      //
      // NOT a clause: a positive z-index. It was one, and it excluded the
      // plainest hand-rolled modal there is — `position: fixed; inset: 0;
      // background: rgba(0,0,0,.5)` with no z-index at all, stacked by
      // document order. The five clauses above already describe something
      // that blocks the page; requiring the author to have ALSO lifted it
      // only lost real dialogs.
      //
      //      Note the overlay ITSELF may be `pointer-events: none` — that
      //      is the Radix / Headless UI portal shape, a full-viewport
      //      wrapper that lets clicks through with a `pointer-events: auto`
      //      card inside it. It is also the shape that produced the bug:
      //      because the wrapper passes clicks, the occlusion hit-test
      //      reaches the dashboard behind it and every background control
      //      stayed marked. So the liveness test is applied to the CONTROLS,
      //      where it means something, not to the wrapper.
      //
      // Last qualifying candidate in document order wins, matching
      // `declaredModal`. What happens NEXT is unchanged: the same
      // aria-hidden / paints-above / occlusion rules run against it, so
      // this adds no new way to drop an element — only a new way to
      // recognise the layer those rules were written for.
      //
      // KNOWN LIMITS, stated rather than papered over. This rule covers a
      // scrim and its card in ONE element — the hand-rolled and Tailwind
      // shapes — and deliberately not:
      //   * an overlay whose dim lives on a SIBLING scrim (a wrapper with
      //     no background of its own). Widening the dimming clause to
      //     "some scrim exists somewhere" would start guessing, and a wrong
      //     modal is worse than no modal — it makes real controls
      //     unaddressable. In practice the big library that renders this
      //     shape (Radix, and shadcn/ui on top of it) sets `aria-modal` on
      //     its content, so `declaredModal` already has it;
      //   * a dim expressed as `opacity` on an opaque background, or as a
      //     `background-image` gradient rather than a background-COLOR;
      //   * an overlay inside a shadow root or portalled outside <body> —
      //     the candidate scan is a plain `body *` query, unlike the
      //     shadow-aware traversals elsewhere in this file.
      // Each of those degrades to the pre-W31b behaviour (no modal
      // recognised), never to a wrong one.
      function contentBox(el) {
        let nodes = [];
        try { nodes = el.querySelectorAll('*'); } catch (e) { return null; }
        let guard = 0;
        for (const d of nodes) {
          if (guard++ > 600) break;
          if (!rendered(d)) continue;
          const r = d.getBoundingClientRect();
          if (r.width < 40 || r.height < 40) continue;
          if (r.width * r.height > vw * vh * 0.75) continue;
          if (bgAlpha(d) < 0.5) continue;
          // Where a dialog sits. A card pinned to an edge is a sidebar, a
          // table of contents, a cookie bar or a hero CTA — all of which
          // can otherwise satisfy every other clause, and none of which
          // should delete the rest of the page from the observation.
          const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
          if (cx < vw * 0.2 || cx > vw * 0.8) continue;
          if (cy < vh * 0.2 || cy > vh * 0.8) continue;
          if (!hasLiveControl(d)) continue;
          return d;
        }
        return null;
      }

      // Translucency ONLY — a backdrop-filter on its own is not evidence of
      // a modal. A full-viewport `backdrop-filter: blur(12px)` layer is a
      // common decorative treatment behind a scrolling article, and
      // accepting it would delete that article from `page_text`. Clause 5's
      // whole argument is about translucency; the rule now implements
      // exactly that argument and nothing wider.
      function dims(el) {
        const a = bgAlpha(el);
        if (a > 0 && a < 1) return true;
        let nodes = [];
        try { nodes = el.querySelectorAll('*'); } catch (e) { return false; }
        let guard = 0;
        for (const d of nodes) {
          if (guard++ > 600) break;
          if (!rendered(d)) continue;
          if (!coversViewport(d.getBoundingClientRect())) continue;
          const da = bgAlpha(d);
          if (da > 0 && da < 1) return true;
        }
        return false;
      }

      function overlayModal() {
        let nodes = [];
        try { nodes = document.querySelectorAll('body *'); } catch (e) { return null; }
        let found = null, guard = 0;
        for (const n of nodes) {
          // Rect first: it is the cheap test after layout has been flushed,
          // and it rejects all but a handful of elements on a real page —
          // `getComputedStyle` on every node of a large document is the one
          // way this rule could cost a capture anything measurable.
          const r = n.getBoundingClientRect();
          if (!coversViewport(r)) continue;
          // The budget counts REAL WORK, not iterations. Counting every
          // node would stop the scan partway through a large document —
          // and React portals append to the END of <body>, so the overlay
          // is the last thing we would reach. A long table would silently
          // turn the modal rule off on exactly the pages where a wrong
          // `page_text` costs the most.
          if (guard++ > 200) break;
          let cs = null;
          try { cs = window.getComputedStyle(n); } catch (e) { continue; }
          if (cs.position !== 'fixed') continue;
          if (!rendered(n)) continue;
          if (!hasLiveControl(n)) continue;
          if (!dims(n)) continue;
          if (!contentBox(n)) continue;
          found = n;
        }
        return found;
      }

      const modal = declaredModal() || overlayModal();

      // Does `el` paint ABOVE the open modal? Toasts, nested popovers and
      // notification rails do — they're still actionable and belong in the
      // table. The dimmed page behind the modal does not, EVEN IF nothing
      // physically covers a given control (a `pointer-events: none` scrim
      // leaves every background button hit-testable while making the whole
      // page unusable), which is why this is a stacking question and not
      // only an occlusion one.
      //
      // A `<dialog>` opened with `showModal()` lives in the top layer, above
      // every ordinary stacking context: nothing outside it paints above it.
      function paintsAbove(el, m) {
        try { if (m.tagName === 'DIALOG' && m.matches(':modal')) return false; } catch (e) {}
        const a = stackRank(el), b = stackRank(m);
        if (a.z !== b.z) return a.z > b.z;
        // Equal z-index: later in document order wins.
        try {
          return !!(b.node.compareDocumentPosition(a.node) & Node.DOCUMENT_POSITION_FOLLOWING);
        } catch (e) { return false; }
      }
    """#

    // MARK: - Marks

    /// The probe. Returns an array of
    /// `{x, y, w, h, role, type, label, label_source}` dicts in reading
    /// order, and parks the matching element list on
    /// `window.__harnessMarkElements` for `scroll_into_view`.
    static var js: String { "(() => {\n" + preludeJS + "\n" + marksJS + "\n})();" }

    /// Raw string literal: the body is JavaScript, backslashes and `\(`
    /// included, and must not be read as Swift interpolation.
    private static let marksJS: String = #"""
      const out = [];
      const seen = new WeakSet();

      // ---- occlusion -----------------------------------------------------

      // Deepest hit-test result at a viewport point, drilling through open
      // shadow roots (`document.elementFromPoint` stops at the host).
      function deepElementFromPoint(x, y) {
        let hit = null;
        try { hit = document.elementFromPoint(x, y); } catch (e) { return null; }
        let guard = 0;
        while (hit && hit.shadowRoot && guard++ < 12) {
          let inner = null;
          try { inner = hit.shadowRoot.elementFromPoint(x, y); } catch (e) { inner = null; }
          if (!inner || inner === hit) break;
          hit = inner;
        }
        return hit;
      }

      // Is `el` the thing a click at one of its own points would reach?
      //
      // The probe is deliberately generous, because a FALSE DROP is worse
      // than a false keep — it makes a real control unaddressable:
      //   * up to seven points are tried (centre first, then quarter points
      //     and edge midpoints), so an element half-covered by a sticky
      //     header or a floating action bar still passes on an uncovered
      //     point;
      //   * points are taken inside the rect's INTERSECTION with the
      //     viewport, so a partially-offscreen element is probed where it
      //     is actually visible;
      //   * a hit on a DESCENDANT counts (the common case: the button's own
      //     label span / icon is what's topmost);
      //   * a hit on an ANCESTOR counts too — that pattern means "el isn't
      //     painted at this exact point" (an inline gap, a transparent
      //     wrapper), not that something else is on top — EXCEPT when the
      //     ancestor also contains the open modal. That shape is a scrim /
      //     portal wrapper enclosing both the dialog and the page behind it,
      //     and accepting it would let the dimmed background survive.
      function unoccluded(el, r) {
        const left = Math.max(0, r.left), top = Math.max(0, r.top);
        const right = Math.min(vw, r.right), bottom = Math.min(vh, r.bottom);
        if (right - left <= 0 || bottom - top <= 0) return true; // nothing to probe
        const inset = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
        const cx = (left + right) / 2, cy = (top + bottom) / 2;
        const pad = 2;
        const points = [
          [cx, cy],
          [inset(left + (right - left) * 0.25, left, right - 1), inset(top + (bottom - top) * 0.25, top, bottom - 1)],
          [inset(left + (right - left) * 0.75, left, right - 1), inset(top + (bottom - top) * 0.75, top, bottom - 1)],
          [inset(left + pad, left, right - 1), cy],
          [inset(right - pad, left, right - 1), cy],
          [cx, inset(top + pad, top, bottom - 1)],
          [cx, inset(bottom - pad, top, bottom - 1)]
        ];
        for (const p of points) {
          const x = p[0], y = p[1];
          if (x < 0 || y < 0 || x >= vw || y >= vh) continue;
          const hit = deepElementFromPoint(x, y);
          if (!hit) continue;
          if (withinDeep(hit, el)) return true;
          if (withinDeep(el, hit) && !(modal && withinDeep(modal, hit))) return true;
        }
        return false;
      }

      // ---- accessible name ------------------------------------------------

      // Accessible-name resolution, in the order a screen reader (and
      // any stable automation resolver) would take it. The historical
      // order put `placeholder` SECOND, which meant a properly-labelled
      // form field — `<label for="name">Your Name *</label>` with
      // `placeholder="John Doe"` — surfaced as "John Doe". Resolvers
      // downstream then keyed on SAMPLE DATA, which changes whenever the
      // designer edits the placeholder, and that sample text leaked into
      // published guide alt text (W1, drop-help shakedown).
      //
      // Priority: aria-label -> aria-labelledby (resolved) -> associated
      // <label for> / wrapping <label> -> placeholder -> title -> value ->
      // visible text -> img alt -> svg <title> -> raw textContent -> test id
      // -> name attribute -> a synthesized "unlabelled <role>" placeholder.
      // Each mark reports WHICH rule won as `label_source`, so a client can
      // prefer the stable sources, treat `placeholder`/`value` as weak
      // signals, and treat `synthesized` as "this control has no name —
      // address it by position or fix the page".
      function labelledByText(el) {
        const ids = norm(el.getAttribute ? el.getAttribute('aria-labelledby') : '');
        if (!ids) return '';
        const root = (el.getRootNode && el.getRootNode()) || document;
        const parts = [];
        for (const id of ids.split(' ')) {
          if (!id) continue;
          let node = null;
          try { node = root.getElementById ? root.getElementById(id) : null; } catch (e) {}
          if (!node) { try { node = document.getElementById(id); } catch (e) {} }
          if (node) parts.push(norm(node.innerText || node.textContent));
        }
        return norm(parts.filter(Boolean).join(' '));
      }

      function associatedLabelText(el) {
        // `el.labels` is the spec-correct answer for form controls: it
        // covers BOTH `<label for=…>` and a wrapping `<label>`.
        let labels = null;
        try { labels = el.labels; } catch (e) {}
        if (labels && labels.length) {
          const texts = [];
          for (const l of labels) texts.push(norm(l.innerText || l.textContent));
          const joined = norm(texts.filter(Boolean).join(' '));
          if (joined) return joined;
        }
        // Non-form controls (a [role="textbox"] div, a custom element)
        // have no `.labels`; look the `for=` association up by id, then
        // fall back to a wrapping <label>.
        try {
          if (el.id) {
            const root = (el.getRootNode && el.getRootNode()) || document;
            const sel = 'label[for="' + (window.CSS && CSS.escape ? CSS.escape(el.id) : el.id) + '"]';
            const byFor = (root.querySelector ? root.querySelector(sel) : null)
              || document.querySelector(sel);
            if (byFor) {
              const t = norm(byFor.innerText || byFor.textContent);
              if (t) return t;
            }
          }
        } catch (e) {}
        try {
          const wrapping = el.closest ? el.closest('label') : null;
          if (wrapping) {
            const t = norm(wrapping.innerText || wrapping.textContent);
            if (t) return t;
          }
        } catch (e) {}
        return '';
      }

      // Icon-only controls: the alt text of a contained <img>, or the
      // <title> of a contained inline <svg> — both are real accessible
      // names the historical chain simply never looked at, which is how a
      // dialog's close button ended up with `label: ""` (W15).
      function imgAltText(el) {
        try {
          if (el.matches && el.matches('img[alt]')) {
            const own = norm(el.getAttribute('alt'));
            if (own) return own;
          }
          const img = el.querySelector ? el.querySelector('img[alt]') : null;
          if (img) return norm(img.getAttribute('alt'));
        } catch (e) {}
        return '';
      }

      function svgTitleText(el) {
        try {
          const t = el.querySelector ? el.querySelector('svg title, svg desc') : null;
          if (t) return norm(t.textContent);
          const svg = el.querySelector ? el.querySelector('svg[aria-label]') : null;
          if (svg) return norm(svg.getAttribute('aria-label'));
        } catch (e) {}
        return '';
      }

      // Test hooks. Not an accessible name, but a deliberate, stable
      // identifier the page's own authors maintain — far better than no
      // label at all, and honestly labelled as `testid` so a consumer can
      // weigh it.
      function testIDText(el) {
        const attrs = ['data-testid', 'data-test-id', 'data-test', 'data-cy', 'data-action'];
        for (const a of attrs) {
          const v = norm(el.getAttribute ? el.getAttribute(a) : '');
          if (v) return v;
        }
        return '';
      }

      // A close glyph IS text content — ✕ / × / ✖ / a lone x — and reads as
      // a label to a human looking at the screenshot. We keep the glyph out
      // of the mark table (a resolver keyed on "✕" is hostile to type and
      // easy to mis-transcribe) and report the word instead, with
      // `label_source: "glyph"` so nobody mistakes it for authored copy.
      const CLOSE_GLYPH = /^[×✕✖✗✘❌╳⨯ｘxX]$/;
      function glyphAware(text, source) {
        if (CLOSE_GLYPH.test(text)) return { label: 'Close', source: 'glyph' };
        return { label: text, source: source };
      }

      function roleOf(el) {
        return el.getAttribute('role') || el.tagName.toLowerCase();
      }

      // A SECRET field: its `value` must never become a label. WebKit renders
      // `<input type="password">` as bullets but `el.value` is still the
      // PLAINTEXT, so the value fallback below would otherwise carry a typed
      // password into the mark table, `structuredContent.marks`, and the
      // agent's context — the one place the credential path guarantees it
      // cannot reach.
      function isSecretField(el) {
        const type = (el.getAttribute && el.getAttribute('type') || '').toLowerCase();
        if (type === 'password') return true;
        const auto = (el.getAttribute && el.getAttribute('autocomplete') || '').toLowerCase();
        return auto.indexOf('password') !== -1;
      }

      // W15 (WB-17) — a discriminator for a control nothing can name.
      //
      // "unlabelled button" is uniform: two icon-only buttons on one screen
      // produce the same string, and a resolver keyed on it matches both.
      // A synthesized label therefore takes the nearest DELIBERATE name an
      // ancestor carries — an `aria-label`, a `data-testid`, a `title` on
      // the row / card / toolbar the control sits in — as a parenthetical.
      // Ancestors only, at most five levels, first hit wins: that is a pure
      // function of the DOM, so two runs against an unchanged page produce
      // the same string.
      //
      // `label_source` stays `synthesized`. The label is still a
      // placeholder, and a consumer must keep treating it as "this control
      // has no name" — a discriminator makes it addressable, not authored.
      function synthesizedContext(el) {
        let n = el.parentElement, guard = 0;
        while (n && guard++ < 5) {
          if (n.getAttribute) {
            const v = norm(n.getAttribute('aria-label'))
                   || norm(n.getAttribute('data-testid'))
                   || norm(n.getAttribute('title'));
            if (v) return v.length > 32 ? v.slice(0, 31) + '…' : v;
          }
          n = n.parentElement;
        }
        return '';
      }

      function resolveLabel(el) {
        const get = (a) => norm(el.getAttribute ? el.getAttribute(a) : '');
        let v = get('aria-label');
        if (v) return { label: v, source: 'aria-label' };
        v = labelledByText(el);
        if (v) return { label: v, source: 'labelledby' };
        v = associatedLabelText(el);
        if (v) return { label: v, source: 'label' };
        v = get('placeholder');
        if (v) return { label: v, source: 'placeholder' };
        v = get('title');
        if (v) return { label: v, source: 'title' };
        // Value is a last-resort label — but never a secret field's value.
        if (isSecretField(el)) return { label: 'Password', source: 'secure-field' };
        v = norm(el.value);
        if (v) return { label: v, source: 'value' };
        v = norm(el.innerText);
        if (v) return glyphAware(v, 'text');
        v = imgAltText(el);
        if (v) return { label: v, source: 'img-alt' };
        v = svgTitleText(el);
        if (v) return { label: v, source: 'svg-title' };
        // `textContent` catches what `innerText` drops: a glyph inside an
        // inline element the layout hid from the text roll-up, ::before-ish
        // markup, an <svg><text> label.
        v = norm(el.textContent);
        if (v) return glyphAware(v, 'text-content');
        // A descendant's title attribute (icon <span title="Close">).
        try {
          const titled = el.querySelector ? el.querySelector('[title]:not([title=""])') : null;
          if (titled) {
            v = norm(titled.getAttribute('title'));
            if (v) return { label: v, source: 'title' };
          }
        } catch (e) {}
        v = testIDText(el);
        if (v) return { label: v, source: 'testid' };
        v = get('name');
        if (v) return { label: v, source: 'name' };
        const base = '\#(synthesizedLabelPrefix)' + roleOf(el);
        const context = synthesizedContext(el);
        return { label: context ? base + ' (' + context + ')' : base, source: 'synthesized' };
      }

      // ---- walk -----------------------------------------------------------

      // Recursive walker that pierces open shadow roots. The flat
      // `document.querySelectorAll` misses inputs nested inside
      // custom elements (common on modern signin / payment forms).
      function collect(root) {
        // Direct matches at this level.
        let here;
        try {
          here = root.querySelectorAll ? root.querySelectorAll(SELECTOR) : [];
        } catch (e) {
          here = [];
        }
        for (const el of here) {
          if (!seen.has(el)) {
            seen.add(el);
            consider(el);
          }
        }
        // Recurse into every descendant's open shadow root. We can't
        // see closed shadow roots from JS at all — that's a platform
        // limit. Same with cross-origin iframes.
        const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
        for (const node of all) {
          if (node.shadowRoot) collect(node.shadowRoot);
        }
      }

      function consider(el) {
        const cs = window.getComputedStyle(el);
        if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') return;
        // `disabled` form controls aren't actionable; don't waste
        // a mark on them.
        if (el.disabled === true) return;
        // `pointer-events` is an inherited property, so this also catches an
        // ancestor that turned the whole subtree into scenery.
        if (cs.pointerEvents === 'none') return;
        // `inert` subtrees are removed from the tab order and ignore every
        // input event — the platform's own "this is background" marker.
        if (closestDeep(el, '[inert]')) return;
        const r = el.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) return;
        if (r.right <= 0 || r.bottom <= 0 || r.left >= vw || r.top >= vh) return;

        // W14 — while a modal is open, the page behind it is inert whether
        // or not the author said so. Only the modal's own contents and
        // whatever paints ABOVE the modal (a toast, a nested popover) are
        // actionable; the dimmed background's buttons are not, and leaving
        // them in the table collides their labels with the modal's own
        // (the drop-help "Add Site" duplicate that made an authored flow
        // born-broken).
        const inModal = modal ? withinDeep(el, modal) : false;
        if (modal && !inModal) {
          // Background hidden from the a11y tree by the modal's own opener.
          if (closestDeep(el, '[aria-hidden="true"]')) return;
          if (!paintsAbove(el, modal)) return;
          if (!unoccluded(el, r)) return;
        } else if (!modal) {
          if (!unoccluded(el, r)) return;
        }

        const role = roleOf(el);
        const resolved = resolveLabel(el);
        let label = resolved.label;
        const labelSource = resolved.source;
        // Drop big, label-less interactive containers. They tend
        // to be invisible wrapper "buttons" that span a section
        // (e.g. a `<div role="button">` covering a whole hero
        // card with no text or aria-label of its own). Marking
        // them produces a badge floating over otherwise-empty
        // page area, which small vision models then misread as
        // "content I should click" — see the badge-11 misfire on
        // alanwizemann.com that drove this filter in. Small
        // label-less elements (icon buttons under 48×48) keep
        // their badge; their position is meaningful even without
        // a label and they're typically genuinely clickable.
        const big = r.width >= 200 || r.height >= 100;
        if (labelSource === 'synthesized' && big) return;
        const inputType = el.getAttribute('type') || null;
        out.push({
          el: el,
          mark: {
            x: Math.round(r.left),
            y: Math.round(r.top),
            w: Math.round(r.width),
            h: Math.round(r.height),
            role: role,
            type: inputType,
            label: label,
            label_source: labelSource
          }
        });
      }

      collect(document);
      // Reading order: top-to-bottom, then left-to-right. The
      // agent's prompt assumes this, and it makes runs easier
      // to skim by ID.
      out.sort((a, b) => (a.mark.y - b.mark.y) || (a.mark.x - b.mark.x));
      const CAP = \#(markCap);
      const kept = out.length > CAP ? out.slice(0, CAP) : out;

      // W15 — make a synthesized placeholder unique on THIS frame. Any
      // synthesized label still shared after the ancestor-context pass gets
      // its 1-based rank in reading order appended ("unlabelled button 2"),
      // so no two nameless controls answer to the same string. Run after
      // the sort and the cap, so the number a client sees is a position in
      // the table it was actually handed — and, being a pure function of
      // reading order, identical across runs on an unchanged page.
      const collisions = {};
      for (const o of kept) {
        if (o.mark.label_source !== 'synthesized') continue;
        collisions[o.mark.label] = (collisions[o.mark.label] || 0) + 1;
      }
      const ranks = {};
      for (const o of kept) {
        if (o.mark.label_source !== 'synthesized') continue;
        const base = o.mark.label;
        if (collisions[base] < 2) continue;
        ranks[base] = (ranks[base] || 0) + 1;
        o.mark.label = base + ' ' + ranks[base];
      }

      // Length cap LAST. Capping before the pass above would leave an
      // ordinal stranded after an ellipsis ("unlabelled button (very long
      // te… 2") and push the label past the cap it was just given.
      for (const o of kept) {
        if (o.mark.label.length > 80) o.mark.label = o.mark.label.slice(0, 77) + '…';
      }

      // Park the elements for `scroll_into_view(id)`: index i is mark id
      // i + 1. A window global, never a DOM mutation — a page's own React
      // tree is not ours to write attributes into. It holds at most `CAP`
      // references and is REPLACED on every probe (which runs before every
      // capture), so it cannot grow, and it pins nothing beyond one frame's
      // worth of elements.
      try { window['\#(elementRegistryKey)'] = kept.map((o) => o.el); } catch (e) {}
      return kept.map((o) => o.mark);
    """#

    // MARK: - Page text (W31a)

    /// Visible text of the frame, scoped by the SAME modal rule the marks
    /// are (W31a). With a modal open, `document.body.innerText` still rolls
    /// up the whole dimmed page behind it — so a text assertion could pass
    /// on copy the agent physically cannot see and a human reviewer would
    /// never find. This reads the modal's own text instead, plus anything
    /// painting above it, matching the mark table exactly — including where
    /// that means nothing: nothing paints above a `<dialog>` opened with
    /// `showModal()`, because it lives in the top layer, so for that one
    /// kind of modal the second root is always empty. Same rule, same
    /// answer as the marks; that is the point.
    ///
    /// Returns the raw string; whitespace normalization and the length cap
    /// stay in `WebDriver.normalizePageText`.
    static var pageTextJS: String { "(() => {\n" + preludeJS + "\n" + pageTextBodyJS + "\n})();" }

    private static let pageTextBodyJS: String = #"""
      function textOf(el) {
        try { return el.innerText || el.textContent || ''; } catch (e) { return ''; }
      }

      if (!modal) {
        const el = document.body || document.documentElement;
        return el ? textOf(el) : '';
      }

      // The modal's own text, plus each layer painting above it. Candidates
      // are limited to body's children and grandchildren — where portals,
      // toast rails and notification stacks actually render — so this stays
      // a bounded scan rather than a whole-document sweep.
      const roots = [modal];
      let candidates = [];
      try { candidates = document.querySelectorAll('body > *, body > * > *'); } catch (e) { candidates = []; }
      for (const c of candidates) {
        if (c === modal) continue;
        if (withinDeep(c, modal) || withinDeep(modal, c)) continue;
        if (!rendered(c)) continue;
        if (!paintsAbove(c, modal)) continue;
        // Skip a candidate already covered by one we took.
        let nested = false;
        for (const r of roots) { if (withinDeep(c, r)) { nested = true; break; } }
        if (nested) continue;
        roots.push(c);
      }
      const parts = [];
      for (const r of roots) {
        const t = textOf(r);
        if (t) parts.push(t);
      }
      return parts.join('\n');
    """#
}
