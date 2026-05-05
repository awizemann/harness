//
//  GoalInputView.swift
//

import SwiftUI

@MainActor final class GoalInputViewModel: ObservableObject {
    @Published var projectName  = "ListApp.xcodeproj"
    @Published var projectMeta  = "Debug · built 2m ago"
    @Published var simulator    = "iPhone 16 Pro"
    @Published var simulatorMeta = "iOS 18.4 · most recent"
    @Published var persona      = "First-time user, never seen this app"
    @Published var goal         = "I'm a first-time user. Try to add 'milk' to my list and mark it done."
    @Published var mode: RunMode = .stepByStep
    @Published var stepBudget   = 40
    @Published var model        = "Claude Opus 4.7"
    enum RunMode: Hashable { case stepByStep, autonomous }
    var canStart: Bool { !goal.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct GoalInputView: View {
    @StateObject var vm = GoalInputViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Describe the user test.").font(HFont.title)
                    Text("Write a goal the way a real user would describe what they want — in plain words, not button names.")
                        .font(HFont.body).foregroundStyle(Color.harnessText3)
                }

                HStack(spacing: 14) {
                    PickerField(symbol: "folder.fill", title: "Xcode Project", name: vm.projectName, sub: vm.projectMeta)
                    PickerField(symbol: "iphone", title: "Simulator", name: vm.simulator, sub: vm.simulatorMeta)
                }

                PersonaGoalForm(persona: $vm.persona, goal: $vm.goal)

                ModeTiles(mode: $vm.mode)

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Step budget").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.harnessText2)
                        HStack { Stepper("", value: $vm.stepBudget, in: 5...200).labelsHidden(); Text("5 – 200 steps").font(HFont.caption).foregroundStyle(Color.harnessText3) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.harnessText2)
                        Menu(vm.model) { Button("Claude Opus 4.7") {}; Button("Claude Sonnet 4.6") {} }
                            .menuStyle(.borderlessButton).font(HFont.row)
                    }
                }

                HStack {
                    Text("Will boot a fresh simulator and rebuild ListApp before the run.")
                        .font(HFont.caption).foregroundStyle(Color.harnessText3)
                    Spacer()
                    Button {} label: { HStack(spacing: 6) { Image(systemName: "play.fill"); Text("Start Run"); Text("⌘↵").font(HFont.mono).opacity(0.8) } }
                        .buttonStyle(AccentButtonStyle(size: .large))
                        .disabled(!vm.canStart)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(36)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.harnessBg)
    }
}

private struct PickerField: View {
    let symbol: String, title: String, name: String, sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.harnessText2)
            HStack(spacing: 10) {
                ZStack { RoundedRectangle(cornerRadius: 4).fill(Color.harnessAccentSoft); Image(systemName: symbol).foregroundStyle(Color.harnessAccent).font(.system(size: 10)) }
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.harnessText)
                    Text(sub).font(HFont.mono).foregroundStyle(Color.harnessText4)
                }
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Color.harnessText4)
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.harnessPanel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.harnessLineStrong, lineWidth: 0.5))
        }
    }
}

private struct ModeTiles: View {
    @Binding var mode: GoalInputViewModel.RunMode
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.harnessText2)
            HStack(spacing: 10) {
                tile(.stepByStep, label: "Step-by-step",
                     sub: "Approve each agent action before it runs.", kbd: "Space approve · ⇧Space reject")
                tile(.autonomous, label: "Autonomous",
                     sub: "Let the agent run end-to-end. You can stop or pause.", kbd: "⌘. stop · ⌘P pause")
            }
        }
    }
    @ViewBuilder
    private func tile(_ value: GoalInputViewModel.RunMode, label: String, sub: String, kbd: String) -> some View {
        let on = mode == value
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().stroke(on ? Color.harnessAccent : Color.harnessLineStrong, lineWidth: 1)
                    .background(Circle().fill(on ? Color.harnessAccent : Color.clear).padding(2.5))
                    .frame(width: 12, height: 12)
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.harnessText)
            }
            Text(sub).font(HFont.caption).foregroundStyle(Color.harnessText3)
            Text(kbd).font(HFont.mono).foregroundStyle(Color.harnessText4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.harnessAccentSoft : Color.harnessPanel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.harnessAccent.opacity(0.5) : Color.harnessLineStrong, lineWidth: on ? 1 : 0.5))
        .onTapGesture { mode = value }
    }
}

#Preview("Light + Dark") {
    HStack(spacing: 24) {
        GoalInputView().frame(width: 720, height: 760).preferredColorScheme(.dark)
        GoalInputView().frame(width: 720, height: 760).preferredColorScheme(.light)
    }
    .padding().background(Color.gray.opacity(0.3))
}
