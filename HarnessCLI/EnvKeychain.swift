//
//  EnvKeychain.swift
//  HarnessCLI
//
//  In-memory `KeychainStoring` shim that reads provider API keys from
//  environment variables instead of the macOS Keychain. The cloud LLM
//  clients (`ClaudeClient`, `OpenAIClient`, `GeminiClient`) only need
//  read access — they fetch the key once on first `step(_:)` — so writes
//  and deletes are no-ops here.
//
//  Why not just use `KeychainStore`?
//  - The Keychain is per-app-signature; the CLI binary has a different
//    code-signing identity than the GUI app, so a key the user has
//    already stored via the Settings UI is invisible to the CLI without
//    re-entry. Env vars are zero-friction in a shell-based dev loop.
//  - Headless dev runs in CI / under tmux are spared the security
//    prompt the Keychain pops up.
//

import Foundation

struct EnvKeychain: KeychainStoring, Sendable {

    /// Lookup map keyed by `"<service>|<account>"`. Only API-key entries
    /// (one per provider) are populated; per-Application credential reads
    /// always return nil so `WebDriver.fill_credential` cleanly degrades
    /// to "no credential staged."
    private let keys: [String: Data]

    init(keys: [String: Data]) {
        self.keys = keys
    }

    /// Build a fresh keychain by reading the three provider env vars.
    /// Missing/empty vars are silently dropped — they'll surface as
    /// `LLMError.missingAPIKey` from the matching client when the run
    /// actually starts, with a tighter error message than this layer
    /// could produce.
    static func fromEnvironment() -> EnvKeychain {
        let env = ProcessInfo.processInfo.environment
        var keys: [String: Data] = [:]

        let providers: [(envVar: String, provider: ModelProvider)] = [
            ("ANTHROPIC_API_KEY", .anthropic),
            ("OPENAI_API_KEY",    .openai),
            ("GOOGLE_API_KEY",    .google)
        ]
        for entry in providers {
            guard let raw = env[entry.envVar],
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
            else { continue }
            let service = KeychainStore.keychainService(for: entry.provider)
            let account = KeychainStore.keychainAccount
            keys["\(service)|\(account)"] = data
        }
        return EnvKeychain(keys: keys)
    }

    func read(service: String, account: String) throws -> Data? {
        keys["\(service)|\(account)"]
    }

    func write(_ data: Data, service: String, account: String) throws {
        // No-op: the CLI never persists keys. The GUI app handles writes
        // via its Settings UI and the real `KeychainStore`.
    }

    func delete(service: String, account: String) throws {
        // No-op (see `write`).
    }
}
