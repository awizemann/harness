//
//  ActionsViewModelTests.swift
//  HarnessTests
//
//  Round-trips for the Actions library section's view-model: action CRUD,
//  chain CRUD with ordered steps, drag-to-reorder, delete-rule on Action
//  nullifying chain steps, broken-step detection, "in N chains" lookup, and
//  archived hiding.
//
//  Uses `RunHistoryStore.inMemory()` so the SwiftData container vanishes
//  with each test.
//

import Testing
import Foundation
@testable import Harness

@MainActor
@Suite("ActionsViewModel")
struct ActionsViewModelTests {

    // MARK: Action CRUD

    @Test("create / update / archive / delete on actions round-trips through reload")
    func actionCRUDRoundTrip() async throws {
        let h = try await Harness.makeHarness()

        // Create
        let created = try await h.vm.createAction(
            name: "add milk",
            promptText: "open the list and add an item called milk",
            notes: "smoke-test the add flow"
        )
        await h.vm.reload()
        #expect(h.vm.actions.contains(where: { $0.id == created.id }))

        // Update
        let edited = ActionSnapshot(
            id: created.id,
            name: "add milk to my shopping list",
            promptText: created.promptText,
            notes: created.notes,
            createdAt: created.createdAt,
            lastUsedAt: created.lastUsedAt,
            archivedAt: nil
        )
        try await h.vm.updateAction(edited)
        await h.vm.reload()
        let afterUpdate = h.vm.actions.first(where: { $0.id == created.id })
        #expect(afterUpdate?.name == "add milk to my shopping list")

        // Archive
        await h.vm.archiveAction(id: created.id)
        let withArchived = try await h.store.actions(includeArchived: true)
        let archived = withArchived.first(where: { $0.id == created.id })
        #expect(archived?.archivedAt != nil)

        // Delete
        await h.vm.deleteAction(id: created.id)
        await h.vm.reload()
        #expect(!h.vm.actions.contains(where: { $0.id == created.id }))
    }

    @Test("createAction rejects empty name or empty prompt")
    func createActionValidation() async throws {
        let h = try await Harness.makeHarness()
        do {
            _ = try await h.vm.createAction(name: "  ", promptText: "x", notes: "")
            #expect(Bool(false), "Expected validation error for empty name")
        } catch is ActionsError {
            // Expected.
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
        do {
            _ = try await h.vm.createAction(name: "name", promptText: " ", notes: "")
            #expect(Bool(false), "Expected validation error for empty prompt")
        } catch is ActionsError {
            // Expected.
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: Chain CRUD

    @Test("create chain with two ordered steps preserves ordering across reload")
    func chainCRUDRoundTrip() async throws {
        let h = try await Harness.makeHarness()
        let a1 = try await h.vm.createAction(name: "a1", promptText: "p1", notes: "")
        let a2 = try await h.vm.createAction(name: "a2", promptText: "p2", notes: "")

        let steps = [
            ActionChainStepSnapshot(id: UUID(), index: 0, actionID: a1.id, preservesState: false),
            ActionChainStepSnapshot(id: UUID(), index: 1, actionID: a2.id, preservesState: true)
        ]
        let chain = try await h.vm.createChain(
            name: "two-step",
            notes: "smoke",
            steps: steps
        )
        await h.vm.reload()

        let stored = try #require(h.vm.chains.first(where: { $0.id == chain.id }))
        #expect(stored.steps.count == 2)
        #expect(stored.steps[0].actionID == a1.id)
        #expect(stored.steps[0].preservesState == false)
        #expect(stored.steps[1].actionID == a2.id)
        #expect(stored.steps[1].preservesState == true)
        #expect(stored.steps[0].index == 0)
        #expect(stored.steps[1].index == 1)
    }

    @Test("Reordering steps via updateChain persists the new order")
    func chainStepReorder() async throws {
        let h = try await Harness.makeHarness()
        let a1 = try await h.vm.createAction(name: "a1", promptText: "p1", notes: "")
        let a2 = try await h.vm.createAction(name: "a2", promptText: "p2", notes: "")
        let a3 = try await h.vm.createAction(name: "a3", promptText: "p3", notes: "")

        let initial = [
            ActionChainStepSnapshot(id: UUID(), index: 0, actionID: a1.id, preservesState: true),
            ActionChainStepSnapshot(id: UUID(), index: 1, actionID: a2.id, preservesState: true),
            ActionChainStepSnapshot(id: UUID(), index: 2, actionID: a3.id, preservesState: true)
        ]
        let chain = try await h.vm.createChain(name: "three", notes: "", steps: initial)
        await h.vm.reload()

        // Swap step 0 and step 2 — the VM normalizes indices on save.
        let stored = try #require(h.vm.chains.first(where: { $0.id == chain.id }))
        var swapped = stored.steps
        swapped.swapAt(0, 2)
        let updated = ActionChainSnapshot(
            id: stored.id,
            name: stored.name,
            notes: stored.notes,
            createdAt: stored.createdAt,
            lastUsedAt: stored.lastUsedAt,
            archivedAt: stored.archivedAt,
            steps: swapped
        )
        try await h.vm.updateChain(updated)
        await h.vm.reload()

        let after = try #require(h.vm.chains.first(where: { $0.id == chain.id }))
        #expect(after.steps.count == 3)
        #expect(after.steps[0].actionID == a3.id)
        #expect(after.steps[1].actionID == a2.id)
        #expect(after.steps[2].actionID == a1.id)
        // Indices are renumbered to match array order.
        #expect(after.steps.map(\.index) == [0, 1, 2])
    }

    @Test("Deleting an Action nullifies actionID on every referencing chain step")
    func deleteActionNullifiesChainSteps() async throws {
        let h = try await Harness.makeHarness()
        let x = try await h.vm.createAction(name: "x", promptText: "px", notes: "")
        let y = try await h.vm.createAction(name: "y", promptText: "py", notes: "")

        let steps = [
            ActionChainStepSnapshot(id: UUID(), index: 0, actionID: x.id, preservesState: true),
            ActionChainStepSnapshot(id: UUID(), index: 1, actionID: y.id, preservesState: true)
        ]
        let chain = try await h.vm.createChain(name: "xy", notes: "", steps: steps)

        await h.vm.deleteAction(id: x.id)
        await h.vm.reload()

        let after = try #require(h.vm.chains.first(where: { $0.id == chain.id }))
        // The step that pointed at x has its actionID cleared by the store's
        // delete rule; the step that pointed at y is untouched.
        #expect(after.steps.count == 2)
        let xStep = after.steps[0]
        let yStep = after.steps[1]
        #expect(xStep.actionID == nil)
        #expect(yStep.actionID == y.id)
    }

    @Test("brokenStepCount returns the number of steps whose action was deleted")
    func brokenStepCountDetectsDeletedReferences() async throws {
        let h = try await Harness.makeHarness()
        let x = try await h.vm.createAction(name: "x", promptText: "px", notes: "")
        let y = try await h.vm.createAction(name: "y", promptText: "py", notes: "")

        let steps = [
            ActionChainStepSnapshot(id: UUID(), index: 0, actionID: x.id, preservesState: true),
            ActionChainStepSnapshot(id: UUID(), index: 1, actionID: y.id, preservesState: true)
        ]
        _ = try await h.vm.createChain(name: "xy", notes: "", steps: steps)

        // Sanity: nothing broken before delete.
        let before = try #require(h.vm.chains.first)
        #expect(h.vm.brokenStepCount(in: before) == 0)

        await h.vm.deleteAction(id: x.id)
        await h.vm.reload()

        let after = try #require(h.vm.chains.first)
        // x's step now has actionID = nil after the store's delete-rule fired,
        // which the VM treats as "blank" rather than "broken." Confirm the
        // count interpretation matches the spec: a step pointing at a
        // missing-but-non-nil id is broken, a step pointing at nil is not.
        #expect(after.steps[0].actionID == nil)
        #expect(h.vm.brokenStepCount(in: after) == 0)

        // Now construct a chain that retains a stale id (simulating a
        // historical state where a step's row points at a deleted Action
        // but the nullification didn't run) and verify the count.
        let staleSteps = [
            ActionChainStepSnapshot(
                id: UUID(),
                index: 0,
                actionID: UUID(), // a UUID that doesn't exist in `actions`
                preservesState: true
            ),
            ActionChainStepSnapshot(
                id: UUID(),
                index: 1,
                actionID: y.id,
                preservesState: true
            )
        ]
        let stale = ActionChainSnapshot(
            id: UUID(),
            name: "stale",
            notes: "",
            createdAt: .now,
            lastUsedAt: .now,
            archivedAt: nil,
            steps: staleSteps
        )
        // Build a snapshot directly and ask the VM for the count without
        // persisting — `brokenStepCount` is a pure function over the VM's
        // current `actions` list.
        #expect(h.vm.brokenStepCount(in: stale) == 1)
    }

    @Test("chainsReferencing returns only chains that touch the given action")
    func chainsReferencingReturnsCorrectChains() async throws {
        let h = try await Harness.makeHarness()
        let x = try await h.vm.createAction(name: "x", promptText: "px", notes: "")
        let y = try await h.vm.createAction(name: "y", promptText: "py", notes: "")
        let z = try await h.vm.createAction(name: "z", promptText: "pz", notes: "")

        let xChain = try await h.vm.createChain(
            name: "uses x",
            notes: "",
            steps: [
                ActionChainStepSnapshot(id: UUID(), index: 0, actionID: x.id, preservesState: true)
            ]
        )
        _ = try await h.vm.createChain(
            name: "uses y only",
            notes: "",
            steps: [
                ActionChainStepSnapshot(id: UUID(), index: 0, actionID: y.id, preservesState: true)
            ]
        )
        _ = try await h.vm.createChain(
            name: "uses z only",
            notes: "",
            steps: [
                ActionChainStepSnapshot(id: UUID(), index: 0, actionID: z.id, preservesState: true)
            ]
        )

        await h.vm.reload()
        let referencingX = h.vm.chainsReferencing(actionID: x.id)
        #expect(referencingX.count == 1)
        #expect(referencingX.first?.id == xChain.id)
    }

    // MARK: Archived hiding

    @Test("Archived actions stay hidden from the default listing but reappear when included")
    func archivedActionsHiddenFromDefaultListing() async throws {
        let h = try await Harness.makeHarness()
        let toArchive = try await h.vm.createAction(name: "vintage", promptText: "stuff", notes: "")
        await h.vm.archiveAction(id: toArchive.id)
        await h.vm.reload()

        let defaultList = h.vm.filteredActions(search: "", includeArchived: false)
        #expect(!defaultList.contains(where: { $0.id == toArchive.id }))

        let withArchived = h.vm.filteredActions(search: "", includeArchived: true)
        #expect(withArchived.contains(where: { $0.id == toArchive.id }))
    }
}

// MARK: - Test harness wiring

@MainActor
private struct Harness {
    let store: any RunHistoryStoring
    let vm: ActionsViewModel

    static func makeHarness() async throws -> Harness {
        let store = try RunHistoryStore.inMemory()
        let vm = ActionsViewModel(store: store)
        return Harness(store: store, vm: vm)
    }
}
