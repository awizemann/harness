//
//  RunReplayView.swift
//  Harness
//

import SwiftUI

struct RunReplayView: View {

    let runID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var vm = RunReplayViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            mainBody
            Divider()
            scrubber
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await vm.load(runID: runID) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let m = vm.meta {
                    Text(m.goal).font(.body.weight(.medium)).lineLimit(2)
                    HStack(spacing: 8) {
                        if let v = vm.verdict { VerdictPill(verdict: PreviewVerdict(v)) }
                        Text(m.persona).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder
    private var mainBody: some View {
        if let err = vm.loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 32))
                Text("Couldn't load run").font(.headline)
                Text(err).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.steps.isEmpty {
            // Run logged a `runStarted` row but never reached `step_started` —
            // typical for runs that crashed during build/install or were stopped
            // before the first agent decision. Show what we know instead of
            // spinning forever.
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No steps recorded for this run.").font(.headline)
                if let summary = vm.meta.flatMap({ _ in
                    vm.summary.isEmpty ? nil : vm.summary
                }) {
                    Text(summary)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    Text("The run may have crashed before reaching the first step, or its events.jsonl is missing.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                screenshotPane
                    .layoutPriority(1)
                stepDetail
                    .frame(minWidth: 320, idealWidth: 380)
            }
        }
    }

    private var screenshotPane: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let img = vm.currentScreenshot {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            } else {
                Text("Screenshot missing").foregroundStyle(.secondary)
            }
        }
    }

    private var stepDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let step = vm.currentStep {
                Text("Step \(step.n) of \(vm.steps.count)")
                    .font(.headline)
                if !step.observation.isEmpty {
                    block("Observation", text: step.observation, italic: true)
                }
                if !step.intent.isEmpty {
                    block("Intent", text: step.intent, italic: false)
                }
                HStack(spacing: 8) {
                    Text(step.toolKind).font(.system(.body, design: .monospaced))
                    if let arg = step.toolArg {
                        Text(arg).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                if !step.frictionEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Friction").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(step.frictionEvents) { f in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.harnessWarning)
                                VStack(alignment: .leading) {
                                    Text(f.kind.rawValue).font(.caption.weight(.medium))
                                    Text(f.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Spacer()
            if !vm.summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summary").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(vm.summary).font(.callout)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func block(_ label: String, text: String, italic: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
        // got truncated) parse to zero steps; SwiftUI's Slider asserts on a
        // zero-width range with a positive step (`0...0` with `step: 1`),
        // which used to crash this view on load.
        if vm.steps.isEmpty {
            EmptyView()
        } else if vm.steps.count == 1 {
            // Single-step replay: show the count, skip the slider entirely.
            HStack(spacing: 12) {
                Text("Step 1/1")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        } else {
            HStack(spacing: 12) {
                Button { vm.step(forward: false) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(vm.currentStepIndex == 0)
                Button { vm.step(forward: true) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(vm.currentStepIndex >= vm.steps.count - 1)
                Slider(
                    value: Binding(
                        get: { Double(min(max(0, vm.currentStepIndex), vm.steps.count - 1)) },
                        set: { vm.currentStepIndex = max(0, min(Int($0), vm.steps.count - 1)) }
                    ),
                    in: 0...Double(vm.steps.count - 1),
                    step: 1
                )
                Text("\(vm.currentStepIndex + 1)/\(vm.steps.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}
