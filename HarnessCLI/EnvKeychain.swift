//
//  EnvKeychain.swift
//  HarnessCLI
//
//  `KeychainStoring` shim used by HarnessCLI. Reads provider API keys
//  from environment variables FIRST, then falls back to the real
//  macOS Keychain (the same store the GUI app writes via its Settings
//  UI) for any provider whose env var isn't set.
//
//  Why both:
//  - **Env vars** are zero-friction in headless / CI / tmux contexts
//    and let the user override what's stored in the Keychain on a
//    per-invocation basis (handy for testing with a throwaway key).
//  - **Keychain fallback** so dev iteration doesn't require the user
//    to duplicate keys they've already stored via the GUI app's
//    Settings. The first read by the CLI binary prompts macOS for
//    permission to access the Keychain item; once granted, the item's
//    ACL remembers the CLI binary and subsequent reads are silent.
//
//  Writes and deletes are no-ops here — the CLI is read-only against
//  credentials. The GUI app remains the one place that writes keys
//  to the Keychain.
//

import Foundation

struct EnvKeychain: KeychainStoring, Sendable {

    /// Lookup map keyed by `"<service>|<account>"`. Only API-key entries
    /// (one per provider) are populated; per-Application credential reads
    /// always return nil so `WebDriver.fill_credential` cleanly degrades
    /// to "no credential staged."
    private let envKeys: [String: Data]
    /// Real macOS Keychain — consulted when the env-var path didn't
    /// have an entry for the requested `(service, account)`. nil means
    /// "skip the fallback entirely" (used by tests / CI).
    private let systemFallback: KeychainStore?

    init(envKeys: [String: Data], systemFallback: KeychainStore? = KeychainStore()) {
        self.envKeys = envKeys
        self.systemFallback = systemFallback
    }

    /// Build the env half of the keychain by reading the three provider
    /// env vars. The Keychain fallback is added unconditionally — the
    /// CLI lets `KeychainStore` decide whether an entry exists.
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
        // Fall back to the real macOS Keychain. macOS prompts the user
        // the first time this CLI binary tries to access an item; once
        // granted, the item's ACL remembers the binary and subsequent
        // reads are silent. Errors from the Keychain (entry missing,
        // user denied permission, etc.) propagate as the caller expects.
        return try systemFallback?.read(service: service, account: account)
    }

    func write(_ data: Data, service: String, account: String) throws {
        // No-op: the CLI never persists keys. The GUI app handles writes
        // via its Settings UI and the real `KeychainStore`.
    }

    func delete(service: String, account: String) throws {
        // No-op (see `write`).
    }
}
