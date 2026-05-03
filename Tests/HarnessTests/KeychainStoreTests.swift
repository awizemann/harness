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
}
