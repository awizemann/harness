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
        } else if vm.steps.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var scrubber: some View {
        HStack(spacing: 12) {
            Button { vm.step(forward: false) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(vm.currentStepIndex == 0)
            Button { vm.step(forward: true) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(vm.currentStepIndex >= vm.steps.count - 1)
            Slider(
                value: Binding(
                    get: { Double(vm.currentStepIndex) },
                    set: { vm.currentStepIndex = Int($0) }
                ),
                in: 0...Double(max(0, vm.steps.count - 1)),
                step: 1
            )
            Text("\(vm.currentStepIndex + 1)/\(vm.steps.count)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
