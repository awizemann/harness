//
//  RunHistoryView.swift
//  Harness
//

import SwiftUI

struct RunHistoryView: View {

    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @State private var vm: RunHistoryViewModel?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                Color.clear.onAppear {
                    self.vm = RunHistoryViewModel(store: container.runHistory)
                }
            }
        }
    }

    @ViewBuilder
    private func content(vm: RunHistoryViewModel) -> some View {
        Group {
            if vm.isLoading && vm.runs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.runs.isEmpty {
                emptyState
            } else {
                List(vm.runs, id: \.id) { run in
                    HistoryRow(run: run)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            coordinator.openReplay(runID: run.id)
                        }
                        .contextMenu {
                            Button("Open Replay") {
                                coordinator.openReplay(runID: run.id)
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([run.runDirectoryURL])
                            }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                Task { await vm.delete(id: run.id) }
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await vm.reload() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No runs yet").font(.title3.weight(.medium))
            Text("Compose your first run under New Run.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryRow: View {
    let run: RunRecordSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VerdictDot(verdict: run.verdict)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(run.goal)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    if let v = run.verdict {
                        VerdictPill(verdict: PreviewVerdict(v))
                    }
                    Label("\(run.stepCount) steps", systemImage: "number")
                        .labelStyle(.titleAndIcon)
                        .font(.caption).foregroundStyle(.secondary)
                    if run.frictionCount > 0 {
                        Label("\(run.frictionCount) friction", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Color.harnessWarning)
                    }
                    Text(run.displayName).font(.caption).foregroundStyle(.tertiary)
                    Text(run.simulatorName).font(.caption).foregroundStyle(.tertiary)
                }
                Text(run.persona)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatted(run.createdAt))
                    .font(.caption).foregroundStyle(.secondary)
                if let completedAt = run.completedAt {
                    let interval = Int(completedAt.timeIntervalSince(run.createdAt))
                    Text("\(interval)s")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}

private struct VerdictDot: View {
    let verdict: Verdict?
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }
    var color: Color {
        switch verdict {
        case .success: return .green
        case .failure: return .red
        case .blocked: return .orange
        case .none: return .secondary
        }
    }
}
