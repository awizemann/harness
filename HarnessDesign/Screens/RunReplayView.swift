//
//  RunReplayView.swift
//

import SwiftUI

@MainActor final class RunReplayViewModel: ObservableObject {
    @Published var run: PreviewRun
    @Published var currentIndex: Int = 4
    @Published var isPlaying = false
    @Published var speed: String = "1"
    @Published var lastTapPoint: CGPoint?
    @Published var image: NSImage?

    init(run: PreviewRun = .mock) { self.run = run }
    var current: PreviewStep { run.steps[currentIndex] }
    var frictionIndices: Set<Int> {
        Set(run.steps.enumerated().compactMap { $0.element.friction != nil ? $0.offset : nil })
    }
}

struct RunReplayView: View {
    @StateObject var vm = RunReplayViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                stage
                feed
            }
            .frame(maxHeight: .infinity)
            controls
        }
        .background(Color.harnessBg)
    }

    private var stage: some View {
        VStack(spacing: 0) {
            SimulatorMirrorView(image: $vm.image, lastTapPoint: vm.lastTapPoint)
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.harnessBg2)
            VStack(alignment: .leading, spacing: 6) {
                Text(vm.current.observation).font(HFont.observation).foregroundStyle(Color.harnessText3).lineSpacing(2)
                Text(vm.current.intent).font(HFont.body).foregroundStyle(Color.harnessText).lineSpacing(2)
                HStack(spacing: 6) {
                    ToolCallChip(kind: vm.current.action.kind, arg: vm.current.action.arg)
                    if let f = vm.current.friction { FrictionTag(kind: f.kind) }
                    Spacer()
                    Text("Step \(vm.current.n) · 00:14").font(HFont.mono).foregroundStyle(Color.harnessText4)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.harnessPanel)
            .overlay(alignment: .top) { Rectangle().fill(Color.harnessLine).frame(height: 0.5) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.harnessLine).frame(width: 0.5) }
    }

    private var feed: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Steps").font(HFont.headline)
                Text("\(vm.run.steps.count) total").font(HFont.micro)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.harnessPanel2))
                Spacer()
                Text("read-only").font(HFont.mono).foregroundStyle(Color.harnessText4)
            }
            .padding(.horizontal, 14).frame(height: 38)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.harnessLine).frame(height: 0.5) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(vm.run.steps.enumerated()), id: \.offset) { i, step in
                        StepFeedCell(step: step, current: i == vm.currentIndex)
                    }
                }
            }
        }
        .frame(width: 360)
        .background(Color.harnessPanel)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Button { vm.currentIndex = max(0, vm.currentIndex - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(SecondaryButtonStyle())
                Button { vm.isPlaying.toggle() } label: { Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(SecondaryButtonStyle())
                Button { vm.currentIndex = min(vm.run.steps.count - 1, vm.currentIndex + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Text("\(String(format: "%02d", vm.currentIndex + 1)) / \(String(format: "%02d", vm.run.steps.count)) · 00:14")
                .font(HFont.mono).foregroundStyle(Color.harnessText3).frame(minWidth: 110, alignment: .leading)
            TimelineScrubber(stepCount: vm.run.steps.count,
                             frictionIndices: vm.frictionIndices,
                             current: $vm.currentIndex)
            SegmentedToggle(options: [
                .init("1", "1×"), .init("2", "2×"), .init("4", "4×"),
            ], selection: $vm.speed)
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
        .background(Color.harnessBg3)
        .overlay(alignment: .top) { Rectangle().fill(Color.harnessLine).frame(height: 0.5) }
    }
}

#Preview("Replay") { RunReplayView().frame(width: 1180, height: 760).preferredColorScheme(.dark) }
