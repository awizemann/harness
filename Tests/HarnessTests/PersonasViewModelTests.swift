//
//  PersonasViewModelTests.swift
//  HarnessTests
//
//  Round-trips for the Personas library section's view-model: built-in
//  seeding idempotency, custom create + reload, duplicate-of-built-in,
//  archive flow, built-in delete protection, and parser coverage against
//  the bundled `persona-defaults.md`.
//
//  Uses `RunHistoryStore.inMemory()` so the SwiftData container vanishes
//  with each test.
//

import Testing
import Foundation
@testable import Harness

@MainActor
@Suite("PersonasViewModel")
struct PersonasViewModelTests {

    // MARK: Seeding

    @Test("seedBuiltInPersonasIfNeeded is idempotent across calls and stamps isBuiltIn")
    func seedingIdempotent() async throws {
        let h = try await Harness.makeHarness()
        let markdown = Self.fixtureMarkdown()
        try await h.store.seedBuiltInPersonasIfNeeded(from: markdown)
        try await h.store.seedBuiltInPersonasIfNeeded(from: markdown)
        try await h.store.seedBuiltInPersonasIfNeeded(from: markdown)

        await h.vm.reload()
        let count = h.vm.personas.count
        // Three sections in fixture markdown.
        #expect(count == 3)
        #expect(h.vm.personas.allSatisfy { $0.isBuiltIn })
    }

    // MARK: Custom create

    @Test("Creating a custom persona round-trips through reload with the right fields")
    func customCreateRoundTrip() async throws {
        let h = try await Harness.makeHarness()
        let snapshot = try await h.vm.create(
            name: "anxious commuter",
            blurb: "rushed",
            promptText: "you are rushed and tap fast"
        )
        await h.vm.reload()

        let stored = h.vm.personas.first(where: { $0.id == snapshot.id })
        #expect(stored?.name == "anxious commuter")
        #expect(stored?.blurb == "rushed")
        #expect(stored?.promptText == "you are rushed and tap fast")
        #expect(stored?.isBuiltIn == false)
    }

    @Test("create rejects empty name or empty prompt")
    func createValidation() async throws {
        let h = try await Harness.makeHarness()
        do {
            _ = try await h.vm.create(name: "  ", blurb: "x", promptText: "y")
            #expect(Bool(false), "Expected validation error for empty name")
        } catch is PersonasError {
            // Expected.
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
        do {
            _ = try await h.vm.create(name: "name", blurb: "x", promptText: " ")
            #expect(Bool(false), "Expected validation error for empty prompt")
        } catch is PersonasError {
            // Expected.
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: Duplicate

    @Test("duplicate(_:) clones a built-in into an editable copy with fresh UUID and (copy) suffix")
    func duplicateBuiltInProducesEditableCopy() async throws {
        let h = try await Harness.makeHarness()
        try await h.store.seedBuiltInPersonasIfNeeded(from: Self.fixtureMarkdown())
        await h.vm.reload()

        let source = try #require(h.vm.personas.first(where: { $0.isBuiltIn }))

        let copy = try await h.vm.duplicate(source)
        #expect(copy.id != source.id)
        #expect(copy.isBuiltIn == false)
        #expect(copy.name == "\(source.name) (copy)")
        #expect(copy.promptText == source.promptText)
        #expect(copy.blurb == source.blurb)

        // List grew by one and contains the copy.
        let after = h.vm.personas
        #expect(after.contains(where: { $0.id == copy.id }))
        // Original is untouched.
        #expect(after.contains(where: { $0.id == source.id && $0.isBuiltIn }))
    }

    // MARK: Archive

    @Test("Archiving hides from default fetch but reappears with includeArchived")
    func archiveHidesFromDefaultFetch() async throws {
        let h = try await Harness.makeHarness()
        let snapshot = try await h.vm.create(
            name: "to archive",
            blurb: "",
            promptText: "anything"
        )

        await h.vm.archive(id: snapshot.id)

        // Default fetch (active only) excludes it.
        let active = try await h.store.personas(includeArchived: false)
        #expect(!active.contains(where: { $0.id == snapshot.id }))

        // includeArchived: true brings it back.
        let withArchived = try await h.store.personas(includeArchived: true)
        let stored = withArchived.first(where: { $0.id == snapshot.id })
        #expect(stored != nil)
        #expect(stored?.archivedAt != nil)
    }

    // MARK: Built-in delete protection
    //
    // Decision: the VM treats `delete(id:)` on a built-in as a logged no-op
    // rather than throwing. This keeps the UI binding fire-and-forget and
    // avoids surfacing an error for a path the user shouldn't have been
    // able to reach. The seeded persona stays in the store either way.

    @Test("delete(id:) on a built-in persona is a no-op — the row stays")
    func cannotDeleteBuiltIn() async throws {
        let h = try await Harness.makeHarness()
        try await h.store.seedBuiltInPersonasIfNeeded(from: Self.fixtureMarkdown())
        await h.vm.reload()

        let builtIn = try #require(h.vm.personas.first(where: { $0.isBuiltIn }))

        await h.vm.delete(id: builtIn.id)

        // It's still there.
        await h.vm.reload()
        #expect(h.vm.personas.contains(where: { $0.id == builtIn.id }))
    }

    // MARK: Parser

    @Test("parseMarkdownSections handles the bundled persona-defaults.md")
    func parseMarkdownSectionsHandlesPersonaDefaults() throws {
        let url = try #require(Self.locatePersonaDefaultsFile())
        let raw = try String(contentsOf: url, encoding: .utf8)

        let sections = PromptLibrary.parseMarkdownSections(raw)
        // The actual file should ship at least 4 sections (verify before
        // asserting against this number — the fixture in this project today
        // ships 6).
        #expect(sections.count >= 4, "Expected ≥4 H2 sections, got \(sections.count)")
        #expect(sections.allSatisfy { !$0.title.isEmpty })
        #expect(sections.allSatisfy { !$0.body.isEmpty })
    }

    @Test("Filter by search hits name, blurb, or prompt text")
    func filterByNeedle() async throws {
        let h = try await Harness.makeHarness()
        try await h.store.seedBuiltInPersonasIfNeeded(from: Self.fixtureMarkdown())
        await h.vm.reload()

        let needle = "explore"
        let hits = h.vm.filtered(search: needle, includeArchived: false)
        // At least one of our fixtures mentions exploring.
        #expect(!hits.isEmpty)
    }

    // MARK: Fixtures

    /// Three-section fixture with deliberate variety: quotes, multi-paragraph
    /// body, and a body with no period (forces firstSentence fallback).
    private static func fixtureMarkdown() -> String {
        """
        # Default Personas

        ---

        ## first-time user

        A curious first-time user. They explore.

        ---

        ## power user

        Knows the app inside out and moves fast.

        Reads two paragraphs of body — the parser keeps both.

        ---

        ## minimalist

        prefers tiny copy without much explanation
        """
    }

    private static func locatePersonaDefaultsFile() -> URL? {
        // The HarnessTests bundle is colocated under Tests/HarnessTests; walk
        // up to the repo root and into docs/PROMPTS.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            let candidate = url
                .appendingPathComponent("docs", isDirectory: true)
                .appendingPathComponent("PROMPTS", isDirectory: true)
                .appendingPathComponent("persona-defaults.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Test harness wiring

@MainActor
private struct Harness {
    let store: any RunHistoryStoring
    let vm: PersonasViewModel

    static func makeHarness() async throws -> Harness {
        let store = try RunHistoryStore.inMemory()
        let vm = PersonasViewModel(store: store)
        return Harness(store: store, vm: vm)
    }
}
