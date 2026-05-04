//
//  RunReplayView.swift
//  Harness
//

import SwiftUI

struct RunReplayView: View {

    let runID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(AppCoordinator.self) private var coordinator
    @State private var vm = RunReplayViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            mainBody
            Divider()
            scrubber
        }
        .background(Color.harnessBg)
        .task {
            // Honor a pending "jump to step" anchor (set by the friction
            // report) exactly once. Cleared by the coordinator after read so
            // a future replay open doesn't accidentally re-seek.
            if let step = coordinator.replayJumpToStep {
                vm.anchorStep = step
                coordinator.replayJumpToStep = nil
            }
            await vm.load(runID: runID)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                if let m = vm.meta {
                    Text(m.goal).font(.body.weight(.medium)).lineLimit(2)
                    HStack(spacing: Theme.spacing.s) {
                        if let v = vm.verdict { VerdictPill(verdict: PreviewVerdict(v)) }
                        Text(m.persona).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.spacing.l)
        .padding(.vertical, Theme.spacing.m)
    }

    @ViewBuilder
    private var mainBody: some View {
        if let err = vm.loadError {
            EmptyStateView(
                symbol: "exclamationmark.triangle",
                title: "Couldn't load run",
                subtitle: err
            )
        } else if vm.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.steps.isEmpty {
            // Run logged a `runStarted` row but never reached `step_started` —
            // typical for runs that crashed during build/install or were stopped
            // before the first agent decision. Show what we know instead of
            // spinning forever.
            EmptyStateView(
                symbol: "doc.text.magnifyingglass",
                title: "No steps recorded for this run.",
                subtitle: vm.summary.isEmpty
                    ? "The run may have crashed before reaching the first step, or its events.jsonl is missing."
                    : vm.summary
            )
        } else {
            HSplitView {
                screenshotPane
                    .layoutPriority(1)
                stepDetail
                    .frame(minWidth: 320, idealWidth: 380)
            }
            .padding(Theme.spacing.m)
        }
    }

    private var screenshotPane: some View {
        PanelContainer {
            ZStack {
                Color.harnessBg2
                if let img = vm.currentScreenshot {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(Theme.spacing.l)
                } else {
                    Text("Screenshot missing").foregroundStyle(Color.harnessText3)
                }
            }
        }
    }

    private var stepDetail: some View {
        PanelContainer {
            VStack(alignment: .leading, spacing: Theme.spacing.m) {
                if let step = vm.currentStep {
                    Text("Step \(step.n) of \(vm.steps.count)")
                        .font(HFont.headline)
                    if !step.observation.isEmpty {
                        block("Observation", text: step.observation, italic: true)
                    }
                    if !step.intent.isEmpty {
                        block("Intent", text: step.intent, italic: false)
                    }
                    if let chipKind = previewToolKind(for: step.toolKind) {
                        ToolCallChip(kind: chipKind, arg: step.toolArg)
                    } else if !step.toolKind.isEmpty {
                        Text(step.toolKind)
                            .font(HFont.mono)
                            .foregroundStyle(Color.harnessText2)
                    }
                    if !step.frictionEvents.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.spacing.s) {
                            Text("Friction")
                                .font(HFont.caption)
                                .foregroundStyle(Color.harnessText3)
                            ForEach(step.frictionEvents) { f in
                                VStack(alignment: .leading, spacing: 4) {
                                    FrictionTag(kind: PreviewFrictionKind(f.kind))
                                    Text(f.detail)
                                        .font(.caption)
                                        .foregroundStyle(Color.harnessText3)
                                }
                            }
                        }
                    }
                }
                Spacer()
                if !vm.summary.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                        Text("Summary")
                            .font(HFont.caption)
                            .foregroundStyle(Color.harnessText3)
                        Text(vm.summary).font(.callout)
                    }
                }
            }
            .padding(Theme.spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func block(_ label: String, text: String, italic: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            Text(label.uppercased())
                .font(HFont.caption)
                .foregroundStyle(Color.harnessText3)
            if italic {
                Text(text).font(.callout).italic()
            } else {
                Text(text).font(.callout)
            }
        }
    }

    @ViewBuilder
    private var scrubber: some View {
        // Don't render the scrubber when there's nothing to scrub. Old runs
        // that crashed before any step landed (or runs whose events.jsonl
        // got truncated) parse to zero steps; the scrubber primitive divides
        // by `stepCount - 1` and would NaN on a single-step run.
        if vm.steps.isEmpty {
            EmptyView()
        } else if vm.steps.count == 1 {
            HStack(spacing: Theme.spacing.m) {
                Text("Step 1/1")
                    .font(HFont.mono)
                    .foregroundStyle(Color.harnessText3)
                Spacer()
            }
            .padding(Theme.spacing.m)
        } else {
            HStack(spacing: Theme.spacing.m) {
                Button { vm.step(forward: false) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(vm.currentStepIndex == 0)
                Button { vm.step(forward: true) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(vm.currentStepIndex >= vm.steps.count - 1)
                TimelineScrubber(
                    stepCount: vm.steps.count,
                    frictionIndices: vm.frictionStepIndices,
                    legBoundaries: vm.legBoundaryIndices,
                    current: $vm.currentStepIndex
                )
                Text("\(vm.currentStepIndex + 1)/\(vm.steps.count)")
                    .font(HFont.mono)
                    .foregroundStyle(Color.harnessText3)
            }
            .padding(.horizontal, Theme.spacing.m)
            .padding(.vertical, Theme.spacing.s)
        }
    }

    /// Map the raw tool name string from the JSONL row to the preview kind.
    /// Returns `nil` for unknown / non-action tool kinds (e.g., `note_friction`,
    /// `mark_goal_done`) so the view can fall back to plain text rendering.
    private func previewToolKind(for raw: String) -> PreviewToolKind? {
        switch raw {
        case "tap", "double_tap": return .tap
        case "type":              return .type
        case "swipe":             return .swipe
        case "wait", "read_screen": return .wait
        case "mark_goal_done":    return .complete
        default:                  return nil
        }
    }
}
