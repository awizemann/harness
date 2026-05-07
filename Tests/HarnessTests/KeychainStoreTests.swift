//
//  KeychainStoreTests.swift
//  HarnessTests
//
//  Smoke tests for the keychain wrapper. We use a unique service name per test
//  run (UUID) so concurrent CI runs and developer-machine entries don't collide.
//

import Testing
import Foundation
@testable import Harness

@Suite("KeychainStore")
struct KeychainStoreTests {

    @Test("Round-trip write → read → delete")
    func roundtrip() throws {
        let store = KeychainStore()
        let service = "com.harness.tests.\(UUID().uuidString)"
        let account = "default"
        let payload = Data("hello-keychain".utf8)

        defer { try? store.delete(service: service, account: account) }

        // Empty initially.
        let empty = try store.read(service: service, account: account)
        #expect(empty == nil)

        // Write + read.
        try store.write(payload, service: service, account: account)
        let read = try store.read(service: service, account: account)
        #expect(read == payload)

        // Overwrite (uses SecItemUpdate path).
        let updated = Data("updated".utf8)
        try store.write(updated, service: service, account: account)
        let read2 = try store.read(service: service, account: account)
        #expect(read2 == updated)

        // Delete.
        try store.delete(service: service, account: account)
        let post = try store.read(service: service, account: account)
        #expect(post == nil)
    }

    @Test("Empty / whitespace API key write rejected")
    func rejectsEmptyAnthropicKey() throws {
        struct LocalKeychain: KeychainStoring {
            // This local stub never persists — we just want to confirm the
            // convenience extension's validation. Forward to a real store would
            // also work, but isolating here keeps the test pure.
            func read(service: String, account: String) throws -> Data? { nil }
            func write(_ data: Data, service: String, account: String) throws { /* no-op */ }
            func delete(service: String, account: String) throws { /* no-op */ }
        }
        let store = LocalKeychain()
        do {
            try store.writeAnthropicAPIKey("   ")
            Issue.record("expected throw on whitespace-only key")
        } catch {
            // ok
        }
    }

    // MARK: - Per-Application credentials (V5)

    @Test("Credential password round-trip uses per-credential account keying")
    func credentialPasswordRoundtrip() throws {
        // Use an in-memory stub instead of the live keychain so the test
        // can verify the (service, account) keying convention without
        // contaminating the developer's keychain. The real SecItem path
        // is exercised by the API-key roundtrip test above.
        // Single-threaded test stub — `@unchecked Sendable` so `nonisolated`
        // mutation is acceptable without serialising. The KeychainStoring
        // protocol requires Sendable but a real implementation talks to
        // SecItem which is its own synchronisation domain.
        final class StubKeychain: KeychainStoring, @unchecked Sendable {
            var store: [String: Data] = [:]
            func read(service: String, account: String) throws -> Data? {
                store["\(service)|\(account)"]
            }
            func write(_ data: Data, service: String, account: String) throws {
                store["\(service)|\(account)"] = data
            }
            func delete(service: String, account: String) throws {
                store.removeValue(forKey: "\(service)|\(account)")
            }
        }
        let stub = StubKeychain()
        let appID = UUID()
        let credID = UUID()

        // Initially absent.
        #expect(try stub.readPassword(applicationID: appID, credentialID: credID) == nil)

        // Write + read.
        try stub.writePassword("hunter2", applicationID: appID, credentialID: credID)
        #expect(try stub.readPassword(applicationID: appID, credentialID: credID) == "hunter2")

        // The shared credentials service is namespaced.
        let expectedAccount = "\(appID.uuidString):\(credID.uuidString)"
        #expect(stub.store["com.harness.credentials|\(expectedAccount)"] == Data("hunter2".utf8))

        // A different (app, cred) pair has its own slot.
        let otherCredID = UUID()
        try stub.writePassword("apples", applicationID: appID, credentialID: otherCredID)
        #expect(try stub.readPassword(applicationID: appID, credentialID: credID) == "hunter2")
        #expect(try stub.readPassword(applicationID: appID, credentialID: otherCredID) == "apples")

        // Delete is idempotent.
        try stub.deletePassword(applicationID: appID, credentialID: credID)
        try stub.deletePassword(applicationID: appID, credentialID: credID)
        #expect(try stub.readPassword(applicationID: appID, credentialID: credID) == nil)
        // The other credential is untouched by a sibling delete.
        #expect(try stub.readPassword(applicationID: appID, credentialID: otherCredID) == "apples")
    }

    @Test("Empty / whitespace credential password is rejected")
    func rejectsEmptyCredentialPassword() throws {
        final class StubKeychain: KeychainStoring, @unchecked Sendable {
            func read(service: String, account: String) throws -> Data? { nil }
            func write(_ data: Data, service: String, account: String) throws {
                Issue.record("write should not be reached on empty input")
            }
            func delete(service: String, account: String) throws {}
        }
        let stub = StubKeychain()
        let appID = UUID()
        let credID = UUID()
        do {
            try stub.writePassword("   ", applicationID: appID, credentialID: credID)
            Issue.record("expected throw on whitespace-only password")
        } catch {
            // ok
        }
    }
}
