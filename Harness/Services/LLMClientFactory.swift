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

import Foundation

enum LLMClientFactory {
    /// Construct a fresh `LLMClient` for the given provider. The client
    /// reads its API key from `keychain` on first `step(_:)`.
    static func client(
        for provider: ModelProvider,
        keychain: any KeychainStoring
    ) -> any LLMClient {
        switch provider {
        case .anthropic:
            return ClaudeClient(keychain: keychain)
        case .openai:
            return OpenAIClient(keychain: keychain)
        case .google:
            return GeminiClient(keychain: keychain)
        }
    }
}
