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

    /// Mirror primitive selection. Web runs use the flat `WebMirrorView`
    /// with browser chrome; everything else keeps the device-bezel
    /// `SimulatorMirrorView`. User-tap forwarding is wired only on
    /// platforms where `simulatorDriver` can route taps (iOS today) —
    /// web tap forwarding would need to plumb through `WebDriver`, which
    /// isn't surfaced to this view-model.
    @ViewBuilder
    private func mirror(vm: RunSessionViewModel) -> some View {
        switch vm.request?.platformKind {
        case .web:
            WebMirrorView(
                image: Binding(get: { vm.liveImage }, set: { vm.liveImage = $0 }),
                lastTapPoint: vm.lastTapPoint,
                viewport: vm.webActiveViewport
                    ?? vm.request?.simulator.pointSize
                    ?? CGSize(width: 1280, height: 1600),
                currentURL: vm.webCurrentURL,
                isLoading: vm.webIsLoading,
                onTapForward: nil,
                onCanvasMeasured: { vm.handleWebCanvasMeasured($0) }
            )
        default:
            SimulatorMirrorView(
                image: Binding(get: { vm.liveImage }, set: { vm.liveImage = $0 }),
                lastTapPoint: vm.lastTapPoint,
                deviceSize: vm.request?.simulator.pointSize ?? CGSize(width: 393, height: 852),
                onTapForward: { point in
                    vm.userForwardedTap(at: point)
                }
            )
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
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
                ZStack(alignment: .bottom) {
                    mirror(vm: vm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(Theme.spacing.l)
                        .overlay(alignment: .topTrailing) {
                            if let kind = vm.statusKind {
                                StatusChip(kind: kind)
                                    .padding(Theme.spacing.l)
                            }
                        }
                    if case .awaitingApproval = vm.status, let pending = vm.pendingApproval {
                        ApprovalCardWrapper(pending: pending,
                                            onApprove: vm.approve,
                                            onSkip: vm.skip,
                                            onReject: { vm.reject(note: "User rejected") })
                            .frame(maxWidth: 460)
                            .padding(.bottom, Theme.spacing.xl)
                    }
                }
                .layoutPriority(1)
                StepFeedRail(vm: vm)
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    BreadcrumbBar(vm: vm)
                }
                ToolbarItem(placement: .primaryAction) {
                    RunNameChip(vm: vm)
                }
                ToolbarItem(placement: .primaryAction) {
                    if case .completed = vm.status {
                        Button {
                            if let runID = vm.request?.id {
                                coordinator.openReplay(runID: runID)
                            }
                        } label: {
                            Label("Open Replay", systemImage: "play.rectangle")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Toolbar widgets

/// Breadcrumb shown in the toolbar's principal slot:
/// `Live Session / <project> / <simulator>`. Mirrors the design's chrome.
private struct BreadcrumbBar: View {
    @Bindable var vm: RunSessionViewModel
    var body: some View {
        HStack(spacing: Theme.spacing.s) {
            Text("Live Session")
                .font(.headline)
                .foregroundStyle(Color.harnessText)
            if let req = vm.request {
                separator
                Text(req.project.displayName)
                    .font(.callout)
                    .foregroundStyle(Color.harnessText3)
                separator
                Text(req.simulator.name)
                    .font(.callout)
                    .foregroundStyle(Color.harnessText3)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var separator: some View {
        Text("/")
            .font(.callout)
            .foregroundStyle(Color.harnessText4)
    }
}

/// Pill in the toolbar's primary-action slot showing the run's display
/// name (or the current leg's action name as a chain progresses).
private struct RunNameChip: View {
    @Bindable var vm: RunSessionViewModel
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
            Text(vm.runDisplayName)
                .font(HFont.caption)
                .lineLimit(1)
        }
        .foregroundStyle(Color.harnessText2)
        .padding(.horizontal, Theme.spacing.s)
        .frame(height: 22)
        .background(
            Capsule().fill(Color.harnessPanel2)
        )
        .overlay(
            Capsule().stroke(Color.harnessLine, lineWidth: 0.5)
        )
        .help(vm.runDisplayName)
    }
}

// MARK: - Left rail

private struct LeftRail: View {
    @Bindable var vm: RunSessionViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing.l) {
                    if !vm.currentGoal.isEmpty {
                        goalBlock
                    }
                    if let req = vm.request, !req.persona.isEmpty {
                        personaBlock(persona: req.persona)
                    }
                    if vm.isChainRun {
                        ChainProgressBlock(legs: vm.legProgress, currentIndex: vm.currentLegIndex)
                    }
                    if let req = vm.request {
                        statsGrid(req: req)
                        modeBlock(req: req)
                        metaBlock(req: req)
                    }
                    if let err = vm.runError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Color.harnessFailure)
                    }
                }
                .padding(Theme.spacing.l)
            }
            Divider()
            actionButtons
                .padding(Theme.spacing.m)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Goal & Persona

    private var goalBlock: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            metaKey("GOAL")
            Text(vm.currentGoal)
                .font(.callout.italic())
                .foregroundStyle(Color.harnessText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func personaBlock(persona: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            metaKey("PERSONA")
            Text(persona)
                .font(.callout)
                .foregroundStyle(Color.harnessText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Stats grid (2x2)

    private func statsGrid(req: GoalRequest) -> some View {
        let frictionColor: Color = vm.frictionFeed.isEmpty
            ? Color.harnessText
            : Color.harnessWarning
        let costTotal = vm.totalCost.total
        return Grid(horizontalSpacing: 0.5, verticalSpacing: 0.5) {
            GridRow {
                statCell(
                    "STEP",
                    value: req.hasStepBudget
                        ? "\(vm.feed.count)/\(req.stepBudget)"
                        : "\(vm.feed.count)/∞"
                )
                statCell("ELAPSED", value: elapsedLabel)
            }
            GridRow {
                statCell("FRICTION", value: "\(vm.frictionFeed.count)", color: frictionColor)
                statCell("MODEL", value: req.model.displayName)
            }
            // Cost lands once the run completes — token totals only flow on
            // the final `runCompleted` event today. Live token-tracking is
            // tracked in docs/DESIGN_BACKLOG.md.
            if costTotal > 0 {
                GridRow {
                    statCell("COST", value: vm.totalCost.formattedTotal, color: .harnessAccent)
                    statCell("TOKENS", value: tokenSummary)
                }
            }
        }
        .background(Color.harnessLine)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.panel)
                .stroke(Color.harnessLine, lineWidth: 0.5)
        )
    }

    private var tokenSummary: String {
        let total = vm.totalTokenUsage.inputTokens
            + vm.totalTokenUsage.outputTokens
            + vm.totalTokenUsage.cacheReadInputTokens
            + vm.totalTokenUsage.cacheCreationInputTokens
        if total >= 10_000 {
            return String(format: "%.1fk", Double(total) / 1_000.0)
        }
        return "\(total)"
    }

    private func statCell(_ label: String, value: String, color: Color = .harnessText) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            metaKey(label)
            Text(value)
                .font(HFont.monoStat)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.spacing.m)
        .padding(.vertical, Theme.spacing.s)
        .background(Color.harnessPanel)
    }

    // MARK: Mode

    private func modeBlock(req: GoalRequest) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            metaKey("MODE")
            HStack(spacing: 6) {
                Image(systemName: req.mode == .autonomous ? "arrow.right.circle" : "hand.point.up")
                    .font(.system(size: 10, weight: .semibold))
                Text(req.mode == .stepByStep ? "Step-by-step" : "Autonomous")
                    .font(HFont.caption)
            }
            .foregroundStyle(Color.harnessAccent)
            .padding(.horizontal, Theme.spacing.s)
            .frame(height: 22)
            .background(Capsule().fill(Color.harnessAccentSoft))
        }
    }

    // MARK: Sub-meta list

    private func metaBlock(req: GoalRequest) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s) {
            metaRow("Project", req.project.displayName)
            metaRow("Scheme", req.project.scheme)
            metaRow("Device", "\(req.simulator.name) · \(req.simulator.runtime)")
            metaRow("Started", startedLabel)
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.spacing.s) {
            Text(label)
                .font(HFont.caption)
                .foregroundStyle(Color.harnessText3)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(HFont.caption)
                .foregroundStyle(Color.harnessText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    // MARK: Action buttons (Stop / future Pause)

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: Theme.spacing.s) {
            if case .completed = vm.status {
                // Run is done — no destructive action surface here. The
                // Replay button lives in the toolbar's primary action slot.
                EmptyView()
            } else {
                Button(role: .destructive) {
                    vm.stop()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        Text("Stop run")
                        Spacer()
                        Text("⌘.")
                            .font(HFont.mono)
                            .foregroundStyle(Color.harnessText4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(".", modifiers: [.command])
            }
        }
    }

    // MARK: Helpers

    private func metaKey(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Color.harnessText3)
    }

    private var elapsedLabel: String {
        let m = vm.elapsedSeconds / 60
        let s = vm.elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var startedLabel: String {
        guard let when = vm.startedAtForDisplay else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let calendar = Calendar.current
        if calendar.isDateInToday(when) {
            return "today, " + formatter.string(from: when)
        }
        if calendar.isDateInYesterday(when) {
            return "yesterday, " + formatter.string(from: when)
        }
        let day = DateFormatter()
        day.dateFormat = "MMM d"
        return "\(day.string(from: when)), \(formatter.string(from: when))"
    }
}

// MARK: - Chain progress block

private struct ChainProgressBlock: View {
    let legs: [RunSessionViewModel.LegProgress]
    let currentIndex: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s) {
            HStack {
                Text("CHAIN")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.harnessText3)
                Spacer()
                Text("\(doneCount)/\(legs.count)")
                    .font(HFont.mono)
                    .foregroundStyle(Color.harnessText3)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(legs.enumerated()), id: \.element.id) { idx, leg in
                    LegRow(
                        leg: leg,
                        position: idx + 1,
                        isCurrent: currentIndex == idx
                    )
                    if idx < legs.count - 1 {
                        Rectangle()
                            .fill(Color.harnessLineSoft)
                            .frame(height: 0.5)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.panel)
                    .fill(Color.harnessPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.panel)
                    .stroke(Color.harnessLine, lineWidth: 0.5)
            )
        }
    }

    private var doneCount: Int {
        legs.reduce(0) { acc, leg in
            switch leg.status {
            case .done, .skipped: return acc + 1
            case .pending, .running: return acc
            }
        }
    }
}

private struct LegRow: View {
    let leg: RunSessionViewModel.LegProgress
    let position: Int
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing.s) {
            statusGlyph
                .frame(width: 16, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Leg \(position)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrent ? Color.harnessAccent : Color.harnessText3)
                    if !leg.preservesState && position > 1 {
                        Text("· reinstall")
                            .font(HFont.micro)
                            .foregroundStyle(Color.harnessText4)
                    }
                }
                Text(leg.actionName)
                    .font(.callout)
                    .foregroundStyle(Color.harnessText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.spacing.m)
        .padding(.vertical, Theme.spacing.s)
        .background(isCurrent ? Color.harnessAccentSoft : Color.clear)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch leg.status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(Color.harnessText4)
        case .running:
            Image(systemName: "circle.dotted")
                .foregroundStyle(Color.harnessAccent)
                .symbolEffect(.pulse, options: .repeating)
        case .done(let verdict):
            switch verdict {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.harnessSuccess)
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.harnessFailure)
            case .blocked:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.harnessBlocked)
            }
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(Color.harnessText4)
        }
    }
}

// MARK: - Step feed rail

private struct StepFeedRail: View {
    @Bindable var vm: RunSessionViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Step Feed")
                    .font(HFont.headline)
                    .foregroundStyle(Color.harnessText)
                Spacer()
                Text("\(vm.feed.count) steps")
                    .font(HFont.micro)
                    .foregroundStyle(Color.harnessText3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.harnessPanel2))
            }
            .padding(.horizontal, Theme.spacing.m)
            .padding(.top, Theme.spacing.m)
            .padding(.bottom, Theme.spacing.s)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.harnessLine).frame(height: 0.5)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.spacing.s) {
                        ForEach(vm.feed) { step in
                            StepFeedCell(step: step)
                                .id(step.n)
                        }
                        ForEach(vm.frictionFeed) { f in
                            FrictionRow(event: f).id("f-\(f.id)")
                        }
                    }
                    .padding(.horizontal, Theme.spacing.s)
                    .padding(.vertical, Theme.spacing.m)
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
        HStack(alignment: .top, spacing: Theme.spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harnessWarning)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.spacing.s) {
                    Text("Step \(event.stepN)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FrictionTag(kind: event.kind)
                }
                Text(event.detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.button)
                .fill(Color.harnessWarning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.button)
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
        VStack(alignment: .leading, spacing: Theme.spacing.l) {
            HStack(spacing: Theme.spacing.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.harnessWarning)
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
                    .padding(Theme.spacing.m)
                    .textSelection(.enabled)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.button)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.button)
                            .stroke(Color.harnessLine, lineWidth: 0.5)
                    )
            }
            .frame(maxHeight: 320)

            if let recovery = vm.recoveryHint, !recovery.isEmpty {
                Text(recovery)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.spacing.m)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.button)
                            .fill(Color.harnessAccent.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.button)
                            .stroke(Color.harnessAccent.opacity(0.25), lineWidth: 0.5)
                    )
            }

            HStack(spacing: Theme.spacing.s) {
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
        .padding(Theme.spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Active Run — Failed")
    }
}

// MARK: - Empty state

private struct EmptyRunState: View {
    @Environment(AppCoordinator.self) private var coordinator
    var body: some View {
        EmptyStateView(
            symbol: "play.circle",
            title: "No run in flight",
            subtitle: "Compose a goal under New Run, then click Start.",
            ctaTitle: "New Run",
            onCta: { coordinator.selectedSection = .newRun }
        )
    }
}
