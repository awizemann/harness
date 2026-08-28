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
//  3. **Named** (W15) — the accessible-name chain never yields an empty
//     string; every mark carries a usable label plus the `label_source`
//     that produced it.
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

    /// The probe. Returns an array of
    /// `{x, y, w, h, role, type, label, label_source}` dicts in reading
    /// order. Raw string literal: the body is JavaScript, backslashes and
    /// `\(` included, and must not be read as Swift interpolation.
    static let js: String = #"""
    (() => {
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
      const out = [];
      const seen = new WeakSet();
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

      // ---- modal layer ---------------------------------------------------

      function rendered(el) {
        try {
          const cs = window.getComputedStyle(el);
          if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') return false;
          const r = el.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        } catch (e) { return false; }
      }

      // The topmost open modal, or null. A modal makes everything behind it
      // inert by definition — `<dialog>.showModal()` literally does, and the
      // aria-modal convention asserts the same. Non-modal `<dialog open>`
      // (from `.show()`) does NOT qualify: the page around it stays live.
      // Last in document order wins, which matches the usual stacking of
      // portal-rendered dialogs.
      function topModal() {
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

      const modal = topModal();

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
        return { label: '\#(synthesizedLabelPrefix)' + roleOf(el), source: 'synthesized' };
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
        if (label.length > 80) label = label.slice(0, 77) + '…';
        const inputType = el.getAttribute('type') || null;
        out.push({
          x: Math.round(r.left),
          y: Math.round(r.top),
          w: Math.round(r.width),
          h: Math.round(r.height),
          role: role,
          type: inputType,
          label: label,
          label_source: labelSource
        });
      }

      collect(document);
      // Reading order: top-to-bottom, then left-to-right. The
      // agent's prompt assumes this, and it makes runs easier
      // to skim by ID.
      out.sort((a, b) => (a.y - b.y) || (a.x - b.x));
      const CAP = \#(markCap);
      return out.length > CAP ? out.slice(0, CAP) : out;
    })();
    """#
}
