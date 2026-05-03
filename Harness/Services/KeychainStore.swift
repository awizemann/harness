//
//  KeychainStore.swift
//  Harness
//
//  Thin wrapper over Security.framework. Used for the Anthropic API key
//  (service `com.harness.anthropic`, account `default`) and generic enough
//  for future credential surfaces.
//
//  We use the legacy macOS keychain (no `kSecUseDataProtectionKeychain`)
//  because the data-protection keychain requires the
//  `keychain-access-groups` entitlement which itself requires a Developer
//  Team for signing. With proper Apple Development signing (team set in
//  project.yml), the legacy keychain's per-app ACL is stable across
//  Debug rebuilds — the user clicks "Always Allow" once per app version
//  and never again. With ad-hoc signing the ACL hash changes per build
//  and prompts every time; if you hit that, set DEVELOPMENT_TEAM in
//  project.yml or sign the build with a real cert.
//
//  Per `standards/03-subprocess-and-filesystem.md §11`, the API key is
//  fetched on ClaudeClient init and never persisted to disk or logged.
//

import Foundation
import Security
import os

protocol KeychainStoring: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// Production implementation backed by `SecItem*` (legacy macOS keychain).
struct KeychainStore: KeychainStoring {

    private static let logger = Logger(subsystem: "com.harness.app", category: "KeychainStore")

    init() {}

    func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            Self.logger.error("Keychain read failed: \(status, privacy: .public)")
            throw KeychainError.unhandled(status: status)
        }
    }

    func write(_ data: Data, service: String, account: String) throws {
        // Try update first; if not found, add.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Self.logger.error("Keychain add failed: \(addStatus, privacy: .public)")
                throw KeychainError.unhandled(status: addStatus)
            }
        default:
            Self.logger.error("Keychain update failed: \(updateStatus, privacy: .public)")
            throw KeychainError.unhandled(status: updateStatus)
        }
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            Self.logger.error("Keychain delete failed: \(status, privacy: .public)")
            throw KeychainError.unhandled(status: status)
        }
    }
}

enum KeychainError: Error, Sendable, LocalizedError {
    case unhandled(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            // SecCopyErrorMessageString gives a readable line for most codes.
            if let cf = SecCopyErrorMessageString(status, nil) {
                return "Keychain error: \(cf as String) (\(status))"
            }
            return "Keychain error \(status)."
        }
    }
}

// MARK: - Convenience for the Anthropic API key

extension KeychainStoring {
    /// Stable identifier for the Anthropic API key entry.
    static var anthropicService: String { "com.harness.anthropic" }
    static var anthropicAccount: String { "default" }

    /// Fetch the Anthropic API key as a UTF-8 string. Returns nil if absent.
    func readAnthropicAPIKey() throws -> String? {
        guard let data = try read(service: Self.anthropicService, account: Self.anthropicAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Write the Anthropic API key. Trims whitespace; rejects empty strings.
    func writeAnthropicAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            throw KeychainError.unhandled(status: errSecParam)
        }
        try write(data, service: Self.anthropicService, account: Self.anthropicAccount)
    }

    func deleteAnthropicAPIKey() throws {
        try delete(service: Self.anthropicService, account: Self.anthropicAccount)
    }
}
