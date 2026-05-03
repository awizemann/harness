//
//  RunSessionView.swift
//  Harness
//

import SwiftUI

struct RunSessionView: View {

    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @State private var vm: RunSessionViewModel?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                Color.clear.onAppear {
                    self.vm = RunSessionViewModel(container: container)
                }
            }
        }
        .onChange(of: coordinator.activeRunID) {
            vm?.startIfPending()
        }
        .task {
            vm?.startIfPending()
        }
    }

    @ViewBuilder
    private func content(vm: RunSessionViewModel) -> some View {
        if case .idle = vm.status {
            EmptyRunState()
        } else if case .failed = vm.status, vm.runError != nil {
            FailureView(vm: vm)
        } else {
            HSplitView {
                LeftRail(vm: vm)
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                ZStack(alignment: .bottom) {
                    SimulatorMirrorView(
                        image: Binding(get: { vm.liveImage }, set: { vm.liveImage = $0 }),
                        lastTapPoint: vm.lastTapPoint,
                        deviceSize: vm.request?.simulator.pointSize ?? CGSize(width: 393, height: 852)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                    if case .awaitingApproval = vm.status, let pending = vm.pendingApproval {
                        ApprovalCardWrapper(pending: pending,
                                            onApprove: vm.approve,
                                            onSkip: vm.skip,
                                            onReject: { vm.reject(note: "User rejected") })
                            .frame(maxWidth: 460)
                            .padding(.bottom, 24)
                    }
                }
                .layoutPriority(1)
                StepFeedRail(vm: vm)
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
            }
            .navigationTitle("Active Run")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if case .completed = vm.status {
                        Button {
                            if let runID = vm.request?.id {
                                coordinator.openReplay(runID: runID)
                            }
                        } label: {
                            Label("Open Replay", systemImage: "play.rectangle")
                        }
                    } else {
                        Button(role: .destructive) {
                            vm.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .keyboardShortcut(".", modifiers: [.command])
                    }
                }
            }
        }
    }
}

// MARK: - Left rail

private struct LeftRail: View {
    @Bindable var vm: RunSessionViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusBlock
            if let req = vm.request {
                metaBlock(req: req)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STATUS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusLabel).font(.body.weight(.medium))
            }
            if vm.elapsedSeconds > 0 {
                Text("Elapsed \(elapsed)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Friction events: \(vm.frictionFeed.count)").font(.caption).foregroundStyle(.secondary)
            if let err = vm.runError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func metaBlock(req: GoalRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REQUEST").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            row("Project", req.project.displayName)
            row("Scheme", req.project.scheme)
            row("Sim", "\(req.simulator.name) · \(req.simulator.runtime)")
            row("Model", req.model.displayName)
            row("Mode", req.mode == .stepByStep ? "Step-by-step" : "Autonomous")
            row("Persona", req.persona)
                .lineLimit(3)
            row("Goal", req.goal).lineLimit(5)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }

    private var statusLabel: String {
        switch vm.status {
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .building: return "Building…"
        case .launching: return "Launching simulator…"
        case .running: return "Running"
        case .awaitingApproval: return "Awaiting approval"
        case .completed(let v): return "Completed: \(v.rawValue)"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch vm.status {
        case .idle: return .secondary
        case .starting, .building, .launching: return .orange
        case .running: return Color.harnessAccent
        case .awaitingApproval: return .yellow
        case .completed(let v):
            switch v {
            case .success: return .green
            case .failure: return .red
            case .blocked: return .orange
            }
        case .failed: return .red
        }
    }

    private var elapsed: String {
        let m = vm.elapsedSeconds / 60
        let s = vm.elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Step feed rail

private struct StepFeedRail: View {
    @Bindable var vm: RunSessionViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("STEP FEED").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(vm.feed.count)").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(vm.feed) { step in
                            StepFeedCell(step: step)
                                .id(step.n)
                        }
                        ForEach(vm.frictionFeed) { f in
                            FrictionRow(event: f).id("f-\(f.id)")
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                }
                .onChange(of: vm.feed.count) {
                    if let last = vm.feed.last {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.n, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct FrictionRow: View {
    let event: PreviewFrictionEvent
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harnessWarning)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Step \(event.stepN)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FrictionTag(kind: event.kind)
                }
                Text(event.detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.harnessWarning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.harnessWarning.opacity(0.30), lineWidth: 0.5)
        )
    }
}

// MARK: - Approval card (wraps the design primitive with our PendingApproval)

private struct ApprovalCardWrapper: View {
    let pending: RunSessionViewModel.PendingApproval
    let onApprove: () -> Void
    let onSkip: () -> Void
    let onReject: () -> Void
    var body: some View {
        ApprovalCard(
            stepNumber: pending.stepIndex,
            actionDescription: pending.toolCall.intent.isEmpty
                ? pending.description
                : pending.toolCall.intent,
            toolCall: PreviewToolCall(pending.toolCall),
            onApprove: onApprove,
            onSkip: onSkip,
            onReject: onReject
        )
    }
}

// MARK: - Failure state

private struct FailureView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var vm: RunSessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run failed").font(.title3.weight(.semibold))
                    if let req = vm.request {
                        Text(req.project.displayName)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            ScrollView {
                Text(vm.runError ?? "Unknown error.")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            }
            .frame(maxHeight: 320)

            if let recovery = vm.recoveryHint, !recovery.isEmpty {
                Text(recovery)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.harnessAccent.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.harnessAccent.opacity(0.25), lineWidth: 0.5)
                    )
            }

            HStack(spacing: 8) {
                if let logURL = vm.buildLogURL,
                   FileManager.default.fileExists(atPath: logURL.path) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    } label: {
                        Label("Reveal build log", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        NSWorkspace.shared.open(logURL)
                    } label: {
                        Label("Open log", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("New Run") {
                    coordinator.selectedSection = .newRun
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Active Run — Failed")
    }
}

// MARK: - Empty state

private struct EmptyRunState: View {
    @Environment(AppCoordinator.self) private var coordinator
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No run in flight").font(.title3.weight(.medium))
            Text("Compose a goal under New Run, then click Start.")
                .font(.callout).foregroundStyle(.secondary)
            Button("New Run") { coordinator.selectedSection = .newRun }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
