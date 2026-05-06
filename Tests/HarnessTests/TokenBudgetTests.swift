//
//  TokenBudgetTests.swift
//  HarnessTests
//
//  Sanity-checks the per-model token-budget lookup table that replaced
//  the legacy `model == .opus47 ? 250_000 : 1_000_000` ternary. The
//  goal isn't to lock specific numbers in stone — those will move as
//  pricing shifts — but to prevent regressions like "Opus's default
//  exceeds its hard ceiling" or "a model has no budget configured."
//

import Testing
import Foundation
@testable import Harness

@Suite("AgentModel — token-budget table")
struct AgentModelTokenBudgetTests {

    @Test("Every model has a non-zero default token budget")
    func everyModelHasDefault() {
        for model in AgentModel.allCases {
            #expect(model.defaultTokenBudget > 0,
                    "\(model.displayName) has no default token budget")
        }
    }

    @Test("Default ≤ max for every model")
    func defaultDoesNotExceedMax() {
        for model in AgentModel.allCases {
            #expect(model.defaultTokenBudget <= model.maxTokenBudget,
                    "\(model.displayName) default (\(model.defaultTokenBudget)) > max (\(model.maxTokenBudget))")
        }
    }

    @Test("Opus 4.7 stays the most conservative — protects against premium-tier blowouts")
    func opusStaysConservative() {
        // Opus default should be ≤ every other model's default. If
        // pricing ever inverts this, re-evaluate the Stepper bounds in
        // Compose Run.
        let opus = AgentModel.opus47.defaultTokenBudget
        for model in AgentModel.allCases where model != .opus47 {
            #expect(opus <= model.defaultTokenBudget,
                    "Opus default (\(opus)) > \(model.displayName) default (\(model.defaultTokenBudget))")
        }
    }

    @Test("Resolution: per-run override wins over model default")
    @MainActor
    func perRunOverrideWins() {
        let vm = makeVM()
        vm.model = .haiku45
        vm.tokenBudgetOverride = 500_000
        #expect(vm.resolvedTokenBudget == 500_000)
    }

    @Test("Resolution: nil override falls back to model default")
    @MainActor
    func nilOverrideFallsBack() {
        let vm = makeVM()
        vm.model = .haiku45
        vm.tokenBudgetOverride = nil
        #expect(vm.resolvedTokenBudget == AgentModel.haiku45.defaultTokenBudget)
    }

    @Test("Resolution: override clamps to model.maxTokenBudget")
    @MainActor
    func overrideClampsToMax() {
        // Set an override well above Opus's hard ceiling, then point
        // the model at Opus — the resolved budget must clamp.
        let vm = makeVM()
        vm.tokenBudgetOverride = 50_000_000
        vm.model = .opus47
        #expect(vm.resolvedTokenBudget == AgentModel.opus47.maxTokenBudget)
    }

    @MainActor
    private func makeVM() -> GoalInputViewModel {
        GoalInputViewModel(
            processRunner: FakeProcessRunner(),
            toolLocator: FakeToolLocator(),
            xcodeBuilder: FakeXcodeBuilder()
        )
    }
}
