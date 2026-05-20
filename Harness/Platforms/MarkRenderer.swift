//
//  MarkRenderer.swift
//  Harness
//
//  Shared Set-of-Mark utilities used by every platform driver that
//  scaffolds interactive targets onto the LLM-bound screenshot
//  (web today, iOS + macOS next). Two pieces:
//
//    - `InteractiveMark` — Sendable value-type carrying a target's
//      bounding rect (in the platform's natural coordinate space:
//      CSS pixels for web, simulator points for iOS, window points
//      for macOS) plus its accessible label and role.
//
//    - `MarkRenderer.draw(on:marks:markSpaceSize:)` — composites
//      numbered badges + outlines onto a copy of the input image.
//      `markSpaceSize` is the size the mark rects are in; the
//      function internally scales rects to the image's actual size
//      so iOS / macOS can pass point-space marks while the image is
//      at native pixel resolution.
//
//  The same renderer feeds the same `WebDriver.describeMarks(_:)`
//  text annotation for every platform — `tap_mark(id)` semantics are
//  identical across surfaces.
//

import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// One numbered Set-of-Mark entry. Built per-screenshot by the active
/// platform driver, kept on the driver actor for the duration of the
/// next tool call, and looked up by id when the agent emits
/// `tap_mark(id:)`.
///
/// `rect` is in the platform's natural coordinate space:
/// - web: CSS pixels (`window.innerWidth`-sized viewport)
/// - iOS: simulator points (e.g., 440×956 on iPhone 17 Pro Max)
/// - macOS: window points
///
/// `id` is 1-based to match the badge text drawn on the snapshot.
struct InteractiveMark: Sendable, Equatable {
    let id: Int
    let rect: CGRect
    /// Source-platform role identifier. Web: `a`, `button`, etc.
    /// iOS: `XCUIElementTypeButton`, etc. macOS: `AXButton`, etc.
    /// Surfaced in the annotation text for the model.
    let role: String
    /// Optional finer-grained role hint (web's HTML `type` attribute,
    /// iOS / macOS leave it nil today).
    let inputType: String?
    /// Accessible human-readable label. Empty when no label could be
    /// resolved.
    let label: String
}

enum MarkRenderer {

    /// Composite numbered badges + outlines onto a copy of `image`.
    ///
    /// Each mark gets a 2pt accent outline around its bounding rect
    /// plus a green pill badge floating just above the rect carrying
    /// the 1-based id in 22pt bold. The badge floats above (not over)
    /// the element so it doesn't obscure the element's label text —
    /// a problem we hit empirically with Qwen3-VL 8B reading "icles"
    /// instead of "Articles" because the badge covered the first few
    /// characters.
    ///
    /// - Parameters:
    ///   - image: source screenshot. Returned image is a copy with
    ///     overlay applied; original is unmodified.
    ///   - marks: marks to draw. Empty list returns the original
    ///     image unchanged (no overlay).
    ///   - markSpaceSize: the coordinate space `marks[i].rect` is in.
    ///     For web this equals `image.size` (CSS pixels). For iOS /
    ///     macOS the image is typically larger (pixel resolution)
    ///     while marks are in point space; the renderer scales rects
    ///     by `image.size / markSpaceSize` before drawing.
    ///
    /// Returns the marked copy. PNG / JPEG encoding happens at the
    /// call site.
    nonisolated static func draw(
        on image: NSImage,
        marks: [InteractiveMark],
        markSpaceSize: CGSize
    ) -> NSImage {
        guard !marks.isEmpty else { return image }
        let size = image.size
        guard markSpaceSize.width > 0, markSpaceSize.height > 0 else { return image }
        // Scale factor from mark-space coords to image-space coords.
        // Web: 1×. iOS at scaleFactor=3: 3×.
        let sx = size.width / markSpaceSize.width
        let sy = size.height / markSpaceSize.height

        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }
        // Base layer: the original snapshot. NSImage.draw handles its
        // own orientation, so this lands the page right-side-up.
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return result }
        // The accent + supporting colors come from HarnessDesign so the
        // overlay reads as part of the app rather than dev-tool clutter.
        let accent = NSColor(red: 0.07, green: 0.58, blue: 0.42, alpha: 1.0)   // harnessAccent (light)
        let badgeBG = accent.cgColor
        let badgeFG = NSColor.white
        let outline = accent.withAlphaComponent(0.85).cgColor

        for mark in marks {
            // Scale mark rect into image coords.
            let scaled = CGRect(
                x: mark.rect.minX * sx,
                y: mark.rect.minY * sy,
                width: mark.rect.width * sx,
                height: mark.rect.height * sy
            )
            // Translate top-left-origin (CSS / iOS point space) to
            // bottom-left-origin (CGContext y-up) for drawing. The
            // element's top-edge is at NSImage y = `size.height - top`;
            // CGRect's origin is its bottom-left, so the rect's
            // NSImage y is `size.height - bottom`.
            let outlineRect = CGRect(
                x: scaled.minX,
                y: size.height - scaled.maxY,
                width: scaled.width,
                height: scaled.height
            )
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(2.0)
            ctx.stroke(outlineRect)

            // Number badge floating just above the element so it
            // doesn't obscure the element's first characters.
            // Sizing tuned for legibility after the LLM-side downscale
            // — see comment block in WebDriver's call site for the
            // empirical motivation.
            let labelText = "\(mark.id)"
            let font = NSFont.systemFont(ofSize: 22, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: badgeFG
            ]
            let textSize = (labelText as NSString).size(withAttributes: attrs)
            let pad: CGFloat = 6
            let badgeW = max(32, textSize.width + 2 * pad)
            let badgeH: CGFloat = 30
            // Float the badge just above the element's top-edge.
            // Clamped inside the image when the element is right at
            // the viewport top.
            let preferredY = size.height - scaled.minY + 4
            let badgeY = min(preferredY, size.height - badgeH - 2)
            let badgeRect = CGRect(
                x: scaled.minX,
                y: badgeY,
                width: badgeW,
                height: badgeH
            )
            ctx.setFillColor(badgeBG)
            ctx.fill(badgeRect)
            let textPoint = CGPoint(
                x: badgeRect.minX + pad,
                y: badgeRect.minY + (badgeH - textSize.height) / 2
            )
            (labelText as NSString).draw(at: textPoint, withAttributes: attrs)
        }
        return result
    }

    /// Render the mark cache into a compact text block the agent loop
    /// injects into the per-turn user message. Each mark gets one line
    /// of `id → "label" (role[/inputType])` so the model can map
    /// intent → id by label without re-reading the badge numbers from
    /// the image. Crucial for small vision models — without it they
    /// reliably anchor on stale ids ("id 6 must still be Articles
    /// because it was Articles last turn") across page transitions
    /// where the numbering shifts.
    ///
    /// Header phrasing is intentionally strong (`MUST` and explicit
    /// re-numbering rule) — empirically, milder phrasing produced
    /// hallucinated id reuse on Qwen3-VL 8B.
    static func describe(_ marks: [InteractiveMark]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(marks.count + 2)
        lines.append("MARKS — you MUST call `tap_mark(id)` using one of the ids below to click any of these elements. Never invent or remember an id from a prior turn — these ids are valid ONLY for the screenshot attached to THIS turn:")
        for mark in marks {
            let roleHint: String = {
                if let t = mark.inputType, !t.isEmpty { return "\(mark.role)/\(t)" }
                return mark.role
            }()
            let label = mark.label.isEmpty ? "(no label)" : "\"\(mark.label)\""
            lines.append("  \(mark.id) → \(label) (\(roleHint))")
        }
        return lines.joined(separator: "\n")
    }

    /// PNG-encode an `NSImage`. Shared by every driver's screenshot
    /// pipeline so disk writes go through one routine.
    nonisolated static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
