---
title: AI Integration: Models, Providers, & Local Inference
type: note
permalink: harness/ai/ai-integration-models-providers-local-inference
tags:
- ai
- providers
- inference
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: Harness/Services/ClaudeClient.swift, standards/07-ai-integration.md, README.md
---

## Observations
- [provider] Anthropic: Opus 4.7, Sonnet 4.6, Haiku 4.5. Each model has justified default token budget and hard ceiling, configurable globally in Settings and per-run in Compose Run. #anthropic
- [provider] OpenAI: GPT-5 Mini, GPT-4.1 Nano. Same per-model token-budget flexibility. #openai
- [provider] Google Gemini: 2.5 Flash, Flash Lite. Same per-model token-budget flexibility. #gemini
- [provider] Local Mac via Ollama (new v0.5): runs vision LLM at http://127.0.0.1:11434. Curated picker: Qwen3-VL 8B (GUI-trained, recommended), Gemma 4 Vision 9B, Llama 3.2 Vision 11B, plus Custom local model field sent verbatim to Ollama. Screenshots never leave machine; runs cost $0; work offline. #ollama
- [implementation] Each provider has its own Keychain entry. Swap mid-session without restart. ClaudeClient wraps Anthropic SDK. Per-provider parser for tool-call extraction. Per-provider prompt caching markers. #integration
- [feature] Unlimited steps: toggle in Settings, Compose Run, or Application defaults. Token budget + cycle detector remain safety rails. #budgets
- [trade-off] Local Ollama trade-offs: ~5-10× slower per step than cloud, lower friction-event quality than cloud-class models. Documented in standards/07-ai-integration.md §12 and wiki Local-vs-Cloud-Models page. #trade-offs
- [feature] Settings card for Local Mac provider shows: server reachability pill, base URL field, copy-paste Ollama install commands. First-run wizard adds 'Or run fully local' card. Native /api/chat endpoint honors options.num_ctx. #ux

## Relations
- supersedes [[AI Integration: Models, Providers, and Inference]]
