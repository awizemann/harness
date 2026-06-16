//
//  EnvKeychain.swift
//  HarnessMCP
//
//  `KeychainStoring` shim used by HarnessMCP. Reads provider API keys
//  from environment variables FIRST, then falls back to the real macOS
//  Keychain (the same store the GUI app writes via its Settings UI) for
//  any provider whose env var isn't set.
//
//  This is a verbatim sibling of `HarnessCLI/EnvKeychain.swift` — each
//  development-time tool target keeps its own copy so it stays
//  self-contained (neither tool target links the other). The GUI app
//  remains the only writer of API keys; this shim is read-only for keys.
//
//  Per-Application credential passwords (the V5 `fill_credential` flow)
//  are written by HarnessMCP's `stage_credential` tool via the real
//  `KeychainStore` directly, NOT through this shim — `write`/`delete`
//  here remain no-ops, matching the CLI.
//

import Foundation

struct EnvKeychain: KeychainStoring, Sendable {

    /// Lookup map keyed by `"<service>|<account>"`. Only API-key entries
    /// (one per provider) are populated; per-Application credential reads
    /// fall through to the system Keychain so staged-credential runs work.
    private let envKeys: [String: Data]
    /// Real macOS Keychain — consulted when the env-var path didn't have an
    /// entry for the requested `(service, account)`. nil disables fallback.
    private let systemFallback: KeychainStore?

    init(envKeys: [String: Data], systemFallback: KeychainStore? = KeychainStore()) {
        self.envKeys = envKeys
        self.systemFallback = systemFallback
    }

    /// Build the env half by reading the three provider env vars. The
    /// Keychain fallback is added unconditionally.
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
        return EnvKeychain(envKeys: keys)
    }

    func read(service: String, account: String) throws -> Data? {
        if let env = envKeys["\(service)|\(account)"] {
            return env
        }
        // Fall back to the real macOS Keychain. macOS prompts the user the
        // first time this binary accesses an item; once granted, the
        // item's ACL remembers the binary and later reads are silent.
        return try systemFallback?.read(service: service, account: account)
    }

    func write(_ data: Data, service: String, account: String) throws {
        // No-op: API keys are owned by the GUI app's Settings UI. Credential
        // passwords are written via `KeychainStore` directly (see
        // `ToolHandlers.stageCredential`).
    }

    func delete(service: String, account: String) throws {
        // No-op (see `write`).
    }
}
