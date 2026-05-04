//
//  GoalInputViewModelTests.swift
//  HarnessTests
//
//  Build-request semantics for the redesigned Compose Run form. The view
//  itself is heavy on token chrome; the VM logic worth testing is the
//  payload assembly (single action vs chain), the auto-name fallback,
//  and the inheritance-vs-override toggle.
//

import Testing
import Foundation
@testable import Harness

@Suite("GoalInputViewModel — buildRequest")
struct GoalInputViewModelTests {

    @Test("Single-action picks the chosen action's prompt as the goal")
    @MainActor
    func buildRequestFromActionPrefersSourceGoal() async throws {
        let vm = makeVM()
        let action = ActionSnapshot(
            id: UUID(),
            name: "Add milk",
            promptText: "Add milk to my list and mark it done.",
            notes: "",
            createdAt: .now,
            lastUsedAt: .now,
            archivedAt: nil
        )
        let persona = makePersona()
        vm.actions = [action]
        vm.personas = [persona]
        vm.source = .action
        vm.selectedActionID = action.id
        vm.selectedPersonaID = persona.id
        loadActiveApplication(vm: vm)

        let request = vm.buildRequest(simulator: makeSimulator())
        let unwrapped = try #require(request)

        #expect(unwrapped.goal == action.promptText)
        if case .singleAction(let actionID, let goal) = unwrapped.payload {
            #expect(actionID == action.id)
            #expect(goal == action.promptText)
        } else {
            Issue.record("expected .singleAction payload")
        }
    }

    @Test("Chain payload assembles legs in declared order with action denormalized")
    @MainActor
    func buildRequestFromChainAssemblesLegs() async throws {
        let vm = makeVM()
        let actionA = ActionSnapshot(
            id: UUID(), name: "Sign up", promptText: "Create an account.",
            notes: "", createdAt: .now, lastUsedAt: .now, archivedAt: nil
        )
        let actionB = ActionSnapshot(
            id: UUID(), name: "Add item", promptText: "Add 'milk' to the list.",
            notes: "", createdAt: .now, lastUsedAt: .now, archivedAt: nil
        )
        let chain = ActionChainSnapshot(
            id: UUID(),
            name: "Onboarding flow",
            notes: "",
            createdAt: .now,
            lastUsedAt: .now,
            archivedAt: nil,
            steps: [
                ActionChainStepSnapshot(id: UUID(), index: 0, actionID: actionA.id, preservesState: false),
                ActionChainStepSnapshot(id: UUID(), index: 1, actionID: actionB.id, preservesState: true)
            ]
        )
        let persona = makePersona()
        vm.actions = [actionA, actionB]
        vm.chains = [chain]
        vm.personas = [persona]
        vm.source = .chain
        vm.selectedChainID = chain.id
        vm.selectedPersonaID = persona.id
        loadActiveApplication(vm: vm)

        let request = vm.buildRequest(simulator: makeSimulator())
        let unwrapped = try #require(request)

        if case .chain(let chainID, let legs) = unwrapped.payload {
            #expect(chainID == chain.id)
            #expect(legs.count == 2)
            #expect(legs[0].actionID == actionA.id)
            #expect(legs[0].actionName == "Sign up")
            #expect(legs[0].preservesState == false)
            #expect(legs[1].actionID == actionB.id)
            #expect(legs[1].actionName == "Add item")
            #expect(legs[1].preservesState == true)
        } else {
            Issue.record("expected .chain payload")
        }
        // Denormalized goal mirrors the first leg.
        #expect(unwrapped.goal == "Create an account.")
    }

    @Test("Empty runName falls back to '<source name> · <date>' placeholder")
    @MainActor
    func runNameFallsBackToPlaceholder() async throws {
        let vm = makeVM()
        let action = ActionSnapshot(
            id: UUID(), name: "Cancel sub", promptText: "Cancel the subscription.",
            notes: "", createdAt: .now, lastUsedAt: .now, archivedAt: nil
        )
        let persona = makePersona()
        vm.actions = [action]
        vm.personas = [persona]
        vm.source = .action
        vm.selectedActionID = action.id
        vm.selectedPersonaID = persona.id
        loadActiveApplication(vm: vm)
        vm.runName = ""   // empty → auto-name kicks in

        let request = vm.buildRequest(simulator: makeSimulator())
        let unwrapped = try #require(request)
        #expect(unwrapped.name.hasPrefix("Cancel sub · "))
    }

    @Test("Inherited Application defaults flow into the request when overrides are off")
    @MainActor
    func inheritedDefaultsApply() async throws {
        let vm = makeVM()
        let action = ActionSnapshot(
            id: UUID(), name: "X", promptText: "Y",
            notes: "", createdAt: .now, lastUsedAt: .now, archivedAt: nil
        )
        let persona = makePersona()
        vm.actions = [action]
        vm.personas = [persona]
        vm.source = .action
        vm.selectedActionID = action.id
        vm.selectedPersonaID = persona.id

        let app = makeApplication(
            modelRaw: AgentModel.sonnet46.rawValue,
            modeRaw: RunMode.autonomous.rawValue,
            stepBudget: 75
        )
        await vm.loadFromActiveApplication(app)
        // Don't toggle overrideDefaults — the defaults from the
        // Application should land in the request.

        let request = vm.buildRequest(simulator: makeSimulator())
        let unwrapped = try #require(request)
        #expect(unwrapped.model == .sonnet46)
        #expect(unwrapped.mode == .autonomous)
        #expect(unwrapped.stepBudget == 75)
    }

    @Test("Overrides win when the user adjusts model + budget")
    @MainActor
    func overriddenDefaultsWin() async throws {
        let vm = makeVM()
        let action = ActionSnapshot(
            id: UUID(), name: "X", promptText: "Y",
            notes: "", createdAt: .now, lastUsedAt: .now, archivedAt: nil
        )
        let persona = makePersona()
        vm.actions = [action]
        vm.personas = [persona]
        vm.source = .action
        vm.selectedActionID = action.id
        vm.selectedPersonaID = persona.id

        let app = makeApplication(
            modelRaw: AgentModel.sonnet46.rawValue,
            modeRaw: RunMode.autonomous.rawValue,
            stepBudget: 40
        )
        await vm.loadFromActiveApplication(app)
        // User overrides each control.
        vm.overrideDefaults = true
        vm.model = .opus47
        vm.mode = .stepByStep
        vm.stepBudget = 120

        let request = vm.buildRequest(simulator: makeSimulator())
        let unwrapped = try #require(request)
        #expect(unwrapped.model == .opus47)
        #expect(unwrapped.mode == .stepByStep)
        #expect(unwrapped.stepBudget == 120)
    }

    @Test("Chain with a broken-link step doesn't pass canStart")
    @MainActor
    func chainWithBrokenStepGated() async throws {
        let vm = makeVM()
        let action = ActionSnapshot(
            id: UUID(), name: "X", promptText: "Y",
            notes: "", createdAt: .now, lastUsedAt: .now, archivedAt: nil
        )
        let chain = ActionChainSnapshot(
            id: UUID(),
            name: "Broken",
            notes: "",
            createdAt: .now,
            lastUsedAt: .now,
            archivedAt: nil,
            steps: [
                ActionChainStepSnapshot(id: UUID(), index: 0, actionID: action.id, preservesState: false),
                // Broken link — actionID nil after a delete.
                ActionChainStepSnapshot(id: UUID(), index: 1, actionID: nil, preservesState: false)
            ]
        )
        let persona = makePersona()
        vm.actions = [action]
        vm.chains = [chain]
        vm.personas = [persona]
        vm.source = .chain
        vm.selectedChainID = chain.id
        vm.selectedPersonaID = persona.id
        loadActiveApplication(vm: vm)

        #expect(vm.canStart == false)
    }

    // MARK: - Helpers

    @MainActor
    private func makeVM() -> GoalInputViewModel {
        GoalInputViewModel(
            processRunner: FakeProcessRunner(),
            toolLocator: FakeToolLocator(),
            xcodeBuilder: FakeXcodeBuilder()
        )
    }

    @MainActor
    private func loadActiveApplication(vm: GoalInputViewModel) {
        // Synchronous shim — set the picker fields directly so canStart's
        // project / scheme / iOS-sim-compat gate passes.
        vm.picker.projectURL = URL(fileURLWithPath: "/tmp/Sample.xcodeproj")
        vm.picker.projectDisplayName = "Sample"
        vm.picker.availableSchemes = ["Sample"]
        vm.picker.selectedScheme = "Sample"
        vm.picker.schemeDestinations = [
            XcodeBuilder.Destination(platform: "iOS Simulator", arch: "arm64", name: "iPhone 16 Pro")
        ]
        vm.simulatorUDID = "FAKE-UDID"
    }

    private func makePersona() -> PersonaSnapshot {
        PersonaSnapshot(
            id: UUID(),
            name: "First-time user",
            blurb: "Never seen this app",
            promptText: "You are using this app for the first time.",
            isBuiltIn: true,
            createdAt: .now,
            lastUsedAt: .now,
            archivedAt: nil
        )
    }

    private func makeSimulator() -> SimulatorRef {
        SimulatorRef(
            udid: "FAKE-UDID",
            name: "iPhone 16 Pro",
            runtime: "iOS 18.4",
            pointSize: CGSize(width: 430, height: 932),
            scaleFactor: 3.0
        )
    }

    private func makeApplication(
        modelRaw: String = AgentModel.opus47.rawValue,
        modeRaw: String = RunMode.stepByStep.rawValue,
        stepBudget: Int = 40
    ) -> ApplicationSnapshot {
        ApplicationSnapshot(
            id: UUID(),
            name: "Sample",
            createdAt: .now,
            lastUsedAt: .now,
            archivedAt: nil,
            projectPath: "/tmp/Sample.xcodeproj",
            projectBookmark: nil,
            scheme: "Sample",
            defaultSimulatorUDID: "FAKE-UDID",
            defaultSimulatorName: "iPhone 16 Pro",
            defaultSimulatorRuntime: "iOS 18.4",
            defaultModelRaw: modelRaw,
            defaultModeRaw: modeRaw,
            defaultStepBudget: stepBudget
        )
    }
}
