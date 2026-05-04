//
//  PromptLibrary.swift
//  Harness
//
//  Loads the canonical prompt markdown files bundled at build time as folder
//  resources. Per `standards/07-ai-integration.md §2`, `docs/PROMPTS/*.md` is
//  the single source of truth — no Swift-string copies of these files exist.
//
//  The `project.yml` resource block:
//
//      resources:
//        - path: docs/PROMPTS
//          type: folder
//
//  copies the directory into the .app's Resources/PROMPTS/ at build time.
//

import Foundation
import os

protocol PromptLoading: Sendable {
    /// The system prompt with `{{PERSONA}}`, `{{GOAL}}`, etc. unsubstituted.
    /// `ClaudeClient` performs the substitution.
    func systemPrompt() throws -> String
    /// Default persona text (used when the user picks "default").
    func defaultPersona() throws -> String
    /// The friction-vocab markdown — for surfacing in the friction-report UI.
    func frictionVocab() throws -> String
    /// Raw markdown for `persona-defaults.md`. Used by the Persona seeder
    /// to refresh built-in entries on every launch.
    func personaDefaults() throws -> String
}

enum PromptLibraryError: Error, Sendable {
    case resourceMissing(name: String)
    case decodingFailed(name: String)

    var localizedDescription: String {
        switch self {
        case .resourceMissing(let n): return "Prompt resource missing: \(n).md"
        case .decodingFailed(let n): return "Prompt resource failed to decode: \(n).md"
        }
    }
}

struct PromptLibrary: PromptLoading {

    private static let logger = Logger(subsystem: "com.harness.app", category: "PromptLibrary")

    /// The bundle that hosts the prompt resources. Production: `Bundle.main`.
    /// Tests can inject a fixture bundle.
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func systemPrompt() throws -> String {
        try load("system-prompt")
    }

    func defaultPersona() throws -> String {
        // The persona-defaults.md file is structured; for now extract the
        // "first-time user" block. The richer picker UI in Phase 3 parses
        // each section out as its own option.
        let full = try load("persona-defaults")
        return Self.extractDefaultPersona(from: full) ?? "A curious first-time user who reads labels but doesn't have the manual."
    }

    func frictionVocab() throws -> String {
        try load("friction-vocab")
    }

    func personaDefaults() throws -> String {
        try load("persona-defaults")
    }

    // MARK: Private

    private func load(_ stem: String) throws -> String {
        // xcodegen's `type: folder` ships the directory as a Bundle subdirectory.
        // Try the subdirectory path first; fall back to the bundle root for tests.
        let candidates: [(String, String?)] = [
            (stem, "PROMPTS"),
            (stem, nil)
        ]
        for (name, sub) in candidates {
            if let url = bundle.url(forResource: name, withExtension: "md", subdirectory: sub),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        Self.logger.error("Prompt resource missing: \(stem, privacy: .public).md")
        throw PromptLibraryError.resourceMissing(name: stem)
    }

    /// Pull the "## first-time user" section from persona-defaults.md.
    /// Falls back to nil; caller has a hard-coded fallback string.
    static func extractDefaultPersona(from full: String) -> String? {
        let lines = full.components(separatedBy: "\n")
        var collecting = false
        var collected: [String] = []
        for line in lines {
            if line.hasPrefix("## first-time user") {
                collecting = true
                continue
            }
            if collecting {
                if line.hasPrefix("## ") || line.hasPrefix("---") {
                    break
                }
                collected.append(line)
            }
        }
        let trimmed = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parse `## title\n<body>\n---` blocks out of a markdown document.
    ///
    /// - Title matches the first `## …` line (heading text trimmed).
    /// - Body is every line up to the next `## ` or `---` divider, trimmed.
    /// - Empty bodies are dropped.
    ///
    /// Used for Persona seeding from `docs/PROMPTS/persona-defaults.md` and
    /// also serves as the "Start from a built-in" picker source in the
    /// Personas create sheet. Lives here (not on `RunHistoryStore`) so any
    /// caller can reuse it without going through the actor.
    nonisolated public static func parseMarkdownSections(_ text: String) -> [(title: String, body: String)] {
        var out: [(title: String, body: String)] = []
        var currentTitle: String?
        var currentBody: [String] = []

        func flush() {
            if let title = currentTitle {
                let body = currentBody.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    out.append((title: title, body: body))
                }
            }
            currentTitle = nil
            currentBody = []
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("---") {
                flush()
                continue
            }
            if currentTitle != nil {
                currentBody.append(line)
            }
        }
        flush()
        return out
    }

    /// Convenience: load and parse `persona-defaults.md` into `(title, body)`
    /// pairs ready for seeding or display. Throws if the resource is missing.
    func personaDefaultSections() throws -> [(title: String, body: String)] {
        let raw = try load("persona-defaults")
        return Self.parseMarkdownSections(raw)
    }
}
