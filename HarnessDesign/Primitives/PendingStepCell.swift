//
//  PendingStepCell.swift
//
//  Skeleton/in-flight version of `StepFeedCell`. Sits at the top of the
//  step feed in `RunSessionView` whenever a step is being processed but
//  the model hasn't returned a tool call yet. Replaces the "0 steps,
//  staring at a green pill" dead-air period with a live phase indicator
//  + elapsed timer + contextual sub-text.
//
//  Visual shape mirrors `StepFeedCell` so the timeline reads
//  continuously — same gutter width, same body padding. The gutter shows
//  a pulsing dot instead of a step number; the body shows two skeleton
//  bars (observation + intent placeholders) and a status row with the
//  phase label + a contextual sub-text.
//

import SwiftUI

// MARK: - Skeleton shimmer primitive

/// Single-purpose shimmer rect for use inside loading states. Honors
/// `.accessibilityReduceMotion` — when reduce-motion is on the rect
/// pulses opacity instead of sliding a gradient across.
public struct Skeleton: View {

    public var height: CGFloat
    public var widthRatio: CGFloat
    public var cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1.0

    public init(height: CGFloat = 12, widthRatio: CGFloat = 1.0, cornerRadius: CGFloat = 4) {
        self.height = height
        self.widthRatio = min(max(widthRatio, 0.1), 1.0)
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * widthRatio
            // Base rect + shimmer overlay, both clipped to the SAME
            // RoundedRectangle shape. The earlier implementation applied
            // `.mask` to the offset shimmer rect itself, which made the
            // mask travel WITH the shimmer instead of clipping it — the
            // bright stripe escaped left of the bar on every loop. The
            // `.clipShape` here is the durable fix because it's bound
            // to the container, not the moving child.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.harnessLineSoft)
                if !reduceMotion {
                    LinearGradient(
                        stops: [
                            .init(color: Color.harnessLineSoft.opacity(0), location: 0.0),
                            .init(color: Color.harnessLine.opacity(0.8), location: 0.5),
                            .init(color: Color.harnessLineSoft.opacity(0), location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w * 0.4)
                    .offset(x: phase * w)
                }
            }
            .frame(width: w, height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .frame(height: height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.4
            }
        }
        .accessibilityHidden(true)
        // Reduce-motion fallback: a gentle opacity pulse on the base rect.
        .opacity(reduceMotion ? pulsingOpacity : 1.0)
    }

    @State private var pulsingOpacity: Double = 1.0
}

// MARK: - Public phase enum mirror

/// Mirrors `StepPhase` from the app target without importing it into the
/// design system (keeps HarnessDesign free of app-only types). The
/// RunSession view converts the typed enum into this string-keyed
/// version when configuring the cell.
public enum PendingStepCellPhase: String, Sendable, Hashable {
    case capturing
    case encoding
    case thinking
    case executing
}

// MARK: - Pending step cell

public struct PendingStepCell: View {

    public var stepNumber: Int
    public var phase: PendingStepCellPhase
    public var phaseStartedAt: Date
    /// Phase-agnostic sub-text — typically a "why is this slow" hint
    /// resolved by the caller (e.g. "First request — Ollama is loading
    /// the model into RAM"). Pass `nil` to hide the sub-row.
    public var subText: String?
    /// User-facing model name to show in the "Waiting for X" label.
    /// Pass the display name (e.g. "Qwen3-VL 8B"), not the raw model id.
    public var modelDisplayName: String

    public init(
        stepNumber: Int,
        phase: PendingStepCellPhase,
        phaseStartedAt: Date,
        subText: String? = nil,
        modelDisplayName: String
    ) {
        self.stepNumber = stepNumber
        self.phase = phase
        self.phaseStartedAt = phaseStartedAt
        self.subText = subText
        self.modelDisplayName = modelDisplayName
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Gutter mirrors StepFeedCell so the timeline rail reads
            // continuously into the pending row.
            VStack(spacing: 4) {
                Text(String(format: "%02d", stepNumber))
                    .font(HFont.mono)
                    .foregroundStyle(Color.harnessAccent)
                    .monospacedDigit()
                Rectangle()
                    .fill(Color.harnessLineStrong)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                // Skeleton bars stand in for observation + intent until
                // the model returns. Two lines for observation, one for
                // intent — matches the typical aspect of a real step.
                VStack(alignment: .leading, spacing: 4) {
                    Skeleton(height: 11, widthRatio: 0.92)
                    Skeleton(height: 11, widthRatio: 0.68)
                }
                Skeleton(height: 12, widthRatio: 0.55)

                // Status row — phase label + animated dot + elapsed timer.
                statusRow
                if let subText, !subText.isEmpty {
                    Text(subText)
                        .font(HFont.caption)
                        .foregroundStyle(Color.harnessText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.harnessAccent.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.harnessAccent.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(stepNumber) in progress, \(phaseLabel)"))
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            PulsingDot()
            Text(phaseLabel)
                .font(HFont.row)
                .foregroundStyle(Color.harnessText2)
            Spacer(minLength: 0)
            // Live elapsed counter — re-renders via TimelineView so we
            // don't need a ViewModel-side timer ticking just for this.
            TimelineView(.periodic(from: phaseStartedAt, by: 1.0)) { ctx in
                Text(Self.elapsedString(from: phaseStartedAt, now: ctx.date))
                    .font(HFont.mono(11))
                    .foregroundStyle(Color.harnessText3)
                    .monospacedDigit()
            }
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .capturing: return "Capturing screen…"
        case .encoding:  return "Compressing screenshot…"
        case .thinking:  return "Waiting for \(modelDisplayName)…"
        case .executing: return "Executing tool…"
        }
    }

    /// Elapsed time formatted compactly. Sub-minute reads as `0:24`;
    /// crosses minutes cleanly (`1:05`).
    private static func elapsedString(from start: Date, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(start)))
        let m = secs / 60
        let s = secs % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Pulsing accent dot

/// 6pt accent dot that scales + fades on a 1.2s loop. Respects
/// reduce-motion (static, full-opacity).
private struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 1.0

    var body: some View {
        Circle()
            .fill(Color.harnessAccent)
            .frame(width: 6, height: 6)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    scale = 1.6
                    opacity = 0.4
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Capturing") {
    PendingStepCell(
        stepNumber: 1,
        phase: .capturing,
        phaseStartedAt: Date().addingTimeInterval(-0.4),
        modelDisplayName: "Opus 4.7"
    )
    .frame(width: 360)
    .padding()
    .background(Color.harnessBg)
}

#Preview("Thinking — local cold-start") {
    PendingStepCell(
        stepNumber: 1,
        phase: .thinking,
        phaseStartedAt: Date().addingTimeInterval(-32),
        subText: "First request — Ollama is loading the model into RAM. Subsequent steps will be 5–10× faster.",
        modelDisplayName: "Qwen3-VL 8B (vision + GUI)"
    )
    .frame(width: 360)
    .padding()
    .background(Color.harnessBg)
}

#Preview("Thinking — cloud") {
    PendingStepCell(
        stepNumber: 14,
        phase: .thinking,
        phaseStartedAt: Date().addingTimeInterval(-2),
        modelDisplayName: "Opus 4.7"
    )
    .frame(width: 360)
    .padding()
    .background(Color.harnessBg)
}
