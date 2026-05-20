//
//  LLMClientFactory.swift
//  Harness
//
//  Picks the right `LLMClient` for a run's chosen `ModelProvider`. Lets
//  `AppContainer.makeRunCoordinator(for:)` stay provider-agnostic — pass
//  it a `RunRequest` and the factory hands back the matching client.
//
//  Each client manages its own running token usage (per-run, reset
//  between runs) so the factory hands back a *fresh instance* per
//  request. That matches `AgentLoop`'s per-run lifecycle and keeps the
//  cycle detector / cache hit rate clean.
//
//  Local Mac dispatch (`.local`) goes through `OllamaClient`, which
//  speaks Ollama's native `/api/chat` endpoint. The original OpenAI-
//  compatible shortcut (target `/v1/chat/completions` against the same
//  Ollama port) hit a real ceiling — Ollama's OpenAI-compat layer
//  silently drops the `options` field that controls `num_ctx`, so
//  every request got truncated against the 4096-token default. Native
//  API honours `options.num_ctx`, `keep_alive`, deterministic seeds,
//  and other Ollama-specific knobs we'll likely want over time. LM
//  Studio users — who don't speak Ollama's native API — currently get
//  best-effort behaviour via the same OpenAIClient path; a follow-up
//  to detect server type at probe time and dispatch accordingly is on
//  the roadmap.
//

import Foundation

enum LLMClientFactory {

    /// Default Ollama address. Kept here (not buried in `OpenAIClient`)
    /// so the Settings UI and the factory share a single source of truth.
    /// Uses `127.0.0.1` (not `localhost`) on purpose — Ollama binds to
    /// IPv4 only by default, and macOS's dual-stack resolution can pick
    /// `::1` first when "localhost" is used, which then hangs on a
    /// connection-refused for the IPv6 attempt before falling back. See
    /// `AppState.localBaseURL` for the full reasoning.
    static let defaultLocalBaseURL = URL(string: "http://127.0.0.1:11434")!

    /// Construct a fresh `LLMClient` for the given provider. The client
    /// reads its API key from `keychain` on first `step(_:)`.
    ///
    /// - Parameters:
    ///   - localBaseURL: only consulted when `provider == .local`. Defaults
    ///     to `defaultLocalBaseURL` (Ollama). Pass the user's persisted
    ///     URL from `AppState.localBaseURL` when calling for a real run.
    ///   - modelNameOverride: only consulted when `provider == .local`
    ///     and the picked `AgentModel` is `.customLocal`. The user's
    ///     typed model tag (e.g. `qwen2.5-vl:7b`) from
    ///     `AppState.localCustomModelName`.
    static func client(
        for provider: ModelProvider,
        keychain: any KeychainStoring,
        localBaseURL: URL? = nil,
        modelNameOverride: String? = nil
    ) -> any LLMClient {
        switch provider {
        case .anthropic:
            return ClaudeClient(keychain: keychain)
        case .openai:
            return OpenAIClient(keychain: keychain)
        case .google:
            return GeminiClient(keychain: keychain)
        case .local:
            return OllamaClient(
                baseURL: localBaseURL ?? defaultLocalBaseURL,
                modelNameOverride: modelNameOverride
            )
        }
    }
}
