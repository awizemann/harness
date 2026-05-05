//
//  RunSessionView.swift
//

import SwiftUI

@MainActor final class RunSessionViewModel: ObservableObject {
    @Published var run: PreviewRun
    @Published var currentImage: NSImage?
    @Published var lastTapPoint: CGPoint?
    @Published var status: StatusKind = .awaiting
    @Published var awaitingApproval: Bool = true
    init(run: PreviewRun = .mock) { self.run = run }
}

struct RunSessionView: View {
    @StateObject var vm = RunSessionViewModel()

    var body: some View {
        HStack(spacing: 0) {
            railLeft
            center
            railRight
        }
        .background(Color.harnessBg)
    }

    private var railLeft: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("Goal") { Text(vm.run.goal).font(HFont.row).foregroundStyle(Color.harnessText) }
            section("Persona") { Text(vm.run.persona).font(HFont.caption).foregroundStyle(Color.harnessText2) }
            statGrid
            section("Mode") {
                HStack {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                    Text(vm.run.mode).font(HFont.micro)
                }
                .foregroundStyle(Color.harnessAccent)
                .padding(.horizontal, 7).frame(height: 18)
                .background(Capsule().fill(Color.harnessAccentSoft))
            }
            row("Project", vm.run.project)
            row("Scheme", vm.run.scheme)
            row("Device", vm.run.device)
            row("Started", vm.run.startedAt)
            Spacer()
            VStack(spacing: 6) {
                Button {} label: { HStack { Image(systemName: "stop.fill"); Text("Stop run"); Spacer(); Text("⌘.").font(HFont.mono).opacity(0.7) } }
                    .buttonStyle(SecondaryButtonStyle(tone: .danger, fullWidth: true))
                    .keyboardShortcut(".", modifiers: .command)
                Button {} label: { HStack { Image(systemName: "pause.fill"); Text("Pause"); Spacer(); Text("⌘P").font(HFont.mono).opacity(0.7) } }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            }
            .padding(12)
            .overlay(alignment: .top) { Rectangle().fill(Color.harnessLine).frame(height: 0.5) }
        }
        .frame(width: 224)
        .background(Color.harnessPanel)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.harnessLine).frame(width: 0.5) }
    }

    private var statGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 0.5), GridItem(.flexible(), spacing: 0.5)]
        return LazyVGrid(columns: cols, spacing: 0.5) {
            stat("Step", "\(vm.run.steps.count)/\(vm.run.stepBudget)")
            stat("Elapsed", vm.run.elapsed)
            stat("Friction", "\(vm.run.friction.count)", warn: !vm.run.friction.isEmpty)
            stat("Model", "Opus 4.7", small: true)
        }
        .background(Color.harnessLine)
    }

    private var center: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                SimulatorMirrorView(image: $vm.currentImage, lastTapPoint: vm.lastTapPoint)
                    .padding(24)
                StatusChip(kind: vm.status).padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.harnessBg2)
    }

    private var railRight: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Step Feed").font(HFont.headline)
                Text("\(vm.run.steps.count) steps").font(HFont.micro).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.harnessPanel2))
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 38)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.harnessLine).frame(height: 0.5) }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(vm.run.steps.enumerated()), id: \.offset) { i, step in
                        StepFeedCell(step: step, current: !vm.awaitingApproval && i == vm.run.steps.count - 1)
                    }
                    if vm.awaitingApproval, let last = vm.run.steps.last {
                        ApprovalCard(stepNumber: last.n + 1,
                                     actionDescription: "Tap the row body to dismiss the swipe and return to base list state.",
                                     toolCall: .init(kind: .tap, arg: "(180, 218)"))
                    }
                }
            }
        }
        .frame(width: 360)
        .background(Color.harnessPanel)
        .overlay(alignment: .leading) { Rectangle().fill(Color.harnessLine).frame(width: 0.5) }
    }

    @ViewBuilder
    private func section<C: View>(_ key: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key).metaKeyStyle(); content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.harnessLine).frame(height: 0.5) }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(HFont.caption).foregroundStyle(Color.harnessText3); Spacer(); Text(v).font(HFont.mono).foregroundStyle(Color.harnessText) }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.harnessLineSoft).frame(height: 0.5) }
    }
    private func stat(_ label: String, _ value: String, warn: Bool = false, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).metaKeyStyle()
            Text(value).font(small ? HFont.row : HFont.monoStat)
                .foregroundStyle(warn ? Color.harnessWarning : Color.harnessText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.harnessPanel)
    }
}

#Preview("Awaiting") {
    let vm = RunSessionViewModel(); vm.awaitingApproval = true; vm.status = .awaiting
    return RunSessionView(vm: vm).frame(width: 1200, height: 760).preferredColorScheme(.dark)
}
