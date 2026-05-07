//
//  PlatformAdapter.swift
//  Harness
//
//  The per-platform façade `RunCoordinator` talks to. Each adapter owns
//  the lifecycle (build → launch → drive → teardown), the agent's tool
//  schema, and the system-prompt context block for its platform. The
//  coordinator stays platform-neutral.
//
//  Adapter registry: `PlatformAdapterFactory.make(for:request:container:)`
//  picks the right adapter based on `RunRequest.platformKind`. Today we
//  ship `IOSPlatformAdapter` (Phase 1+2), `MacOSPlatformAdapter` (Phase 2),
//  and `WebPlatformAdapter` (Phase 3, WKWebView).
//

import Foundation
import SwiftUI

/// Result of preparing a run — what RunCoordinator needs to drive the
/// per-step loop. Sendable + value-type so it crosses actor boundaries
/// without ceremony.
struct RunSession: Sendable {
    let kind: PlatformKind
    /// The driver that handles per-step `screenshot` / `execute` /
    /// `relaunchForNewLeg`. Lives for the lifetime of the run.
    let driver: any UXDriving
    /// Logical/point size of the canvas the agent sees. Used by
    /// `RunCoordinator` to downscale screenshots before sending to Claude
    /// (matching the canvas dimensions keeps coordinate maths trivial).
    let pointSize: CGSize
    /// Bundle identifier when relevant (iOS / macOS app). `nil` for web.
    /// Logged on `run_started` for replay diagnostics.
    let bundleIdentifier: String?
    /// On-disk path of the built / chosen artifact. iOS: `.app` bundle;
    /// macOS: the `.app` bundle (built or pre-existing); web: `nil`.
    let appBundleURL: URL?
    /// Short human label for the target — used in the live-run header
    /// ("iPhone 16 Pro · iOS 26", "TextEdit", "example.com").
    let displayLabel: String
    /// V5 — the public-safe identity of the credential staged for this
    /// run, OR nil if no credential was staged. The `password` is
    /// **deliberately absent** from this struct: only the driver knows
    /// the password value, and only for as long as the run lives. The
    /// label and username are safe to log (`run_started`) and safe to
    /// substitute into the system prompt's `{{CREDENTIALS}}` block.
    let credentialLabel: String?
    let credentialUsername: String?
}

/// Per-platform façade. Stateless — instantiated fresh per run. The
/// instance retains its dependencies (services, builders, etc.) so
/// `prepare(...)` can mutate them as needed.
protocol PlatformAdapter: Sendable {
    var kind: PlatformKind { get }

    /// Build (if applicable), launch, and stage the system-under-test for
    /// driving. Yields `RunEvent`s on the continuation as it goes
    /// (`buildStarted`, `buildCompleted`, `simulatorReady`, etc.) so the
    /// UI mirrors progress.
    func prepare(
        _ request: RunRequest,
        runID: UUID,
        continuation: AsyncThrowingStream<RunEvent, any Error>.Continuation
    ) async throws -> RunSession

    /// Reverse of `prepare`. Always called once at the end of a run, even
    /// on cancellation/failure — implementations must be idempotent.
    func teardown(_ session: RunSession) async

    /// Tool definitions for this platform, in canonical order. The last
    /// entry gets a `cache_control` ephemeral marker when `cacheControl`
    /// is true (Anthropic prompt cache).
    func toolDefinitions(cacheControl: Bool) -> [[String: Any]]

    /// Tool names this platform accepts (canonical order). Used by
    /// `AgentLoop` to validate model output and to render the `Tool-Schema`
    /// CI consistency test.
    func toolNames() -> [String]

    /// The text injected into `{{PLATFORM_CONTEXT}}` of the system
    /// prompt. Tells the model what kind of UI it's looking at and what
    /// gestures / metaphors apply. Loaded as a bundle resource at
    /// runtime — implementations defer to `PromptLibrary`.
    func systemPromptContext(deviceLabel: String) async throws -> String
}

/// Factory for the three platform adapters. Construction takes the
/// shared services from `AppContainer` so each adapter can wire its own
/// concrete dependencies — see `IOSPlatformAdapter`, `MacOSPlatformAdapter`,
/// `WebPlatformAdapter`.
enum PlatformAdapterFactory {
    /// Build the adapter that matches `request.platformKind`. Throws
    /// `PlatformAdapterFactoryError.notImplemented` for kinds whose
    /// adapter hasn't shipped yet (cleaner than crashing — the run-start
    /// path can surface a helpful message).
    static func make(
        for request: RunRequest,
        services: PlatformAdapterServices
    ) throws -> any PlatformAdapter {
        switch request.platformKind {
        case .iosSimulator:
            return IOSPlatformAdapter(services: services)
        case .macosApp:
            return MacOSPlatformAdapter(services: services)
        case .web:
            return WebPlatformAdapter(services: services)
        }
    }
}

enum PlatformAdapterFactoryError: Error, Sendable, LocalizedError {
    case notImplemented(kind: PlatformKind)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let kind):
            return "Harness can't drive \(kind.displayName) yet — \(kind.availabilityNote ?? "stay tuned")."
        }
    }
}

/// The slice of services + dependencies a platform adapter needs.
/// `RunCoordinator` constructs one of these from `AppContainer` and hands
/// it to the factory; each adapter only reads what it needs.
struct PlatformAdapterServices: Sendable {
    let processRunner: any ProcessRunning
    let toolLocator: any ToolLocating
    let xcodeBuilder: any XcodeBuilding
    let simulatorDriver: any SimulatorDriving
    let promptLibrary: any PromptLoading
    /// V5 — needed to resolve the run's pre-staged credential at
    /// `prepare()` time. The DB lookup gives us label + username; the
    /// Keychain read gives us the password. Together they form the
    /// `CredentialBinding` the driver caches for the run's lifetime.
    let keychain: any KeychainStoring
    let runHistory: any RunHistoryStoring
}

extension PlatformAdapterServices {
    /// Resolve `request.credentialID` to a fully-populated
    /// `CredentialBinding` (DB lookup + Keychain read), or `nil` when no
    /// credential is staged or any lookup fails. The agent path treats a
    /// nil binding as "no credential available" — the run still proceeds
    /// and the agent can emit `auth_required` friction if needed.
    ///
    /// We **soft-fail** on lookup error rather than throw: a Keychain
    /// glitch shouldn't take down a whole run that might not even need
    /// the credential. The error is logged at the call site if useful.
    func resolveCredentialBinding(for request: RunRequest) async -> CredentialBinding? {
        guard let credentialID = request.credentialID else { return nil }
        do {
            guard let snapshot = try await runHistory.credential(id: credentialID) else { return nil }
            guard let password = try keychain.readPassword(
                applicationID: snapshot.applicationID,
                credentialID: snapshot.id
            ) else { return nil }
            return CredentialBinding(
                id: snapshot.id,
                label: snapshot.label,
                username: snapshot.username,
                password: password
            )
        } catch {
            return nil
        }
    }
}
