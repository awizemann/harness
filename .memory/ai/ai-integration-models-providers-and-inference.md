---
title: AI Integration: Models, Providers, and Inference
type: note
permalink: harness/ai/ai-integration-models-providers-and-inference
tags:
- ai
- models
- inference
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: Harness/Services/ClaudeClient.swift, standards/07-ai-integration.md, docs/PROMPTS/, README.md
status: deprecated
---

## Observations
- [cloud_providers] Three cloud providers: Anthropic (Opus 4.7, Sonnet 4.6, Haiku 4.5), OpenAI (GPT-5 Mini, GPT-4.1 Nano), Google Gemini (2.5 Flash, Flash Lite). Each provider has its own Keychain entry. Swap mid-session without restart. Credentials stored per-provider in system Keychain with fallback env vars (ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY) for CLI. ClaudeClient wraps Anthropic SDK; providers rotated via strategy pattern. #providers #credentials
- [local_inference] New in v0.5: Local Mac inference via Ollama at http://127.0.0.1:11434. Curated picker: Qwen3-VL 8B (GUI-trained, recommended), Gemma 4 Vision 9B, Llama 3.2 Vision 11B, plus Custom local model field (sent verbatim to Ollama). Screenshots never leave the machine; runs cost $0; works offline. ~5-10× slower per step than cloud; lower friction-event quality. Talks native /api/chat endpoint (not OpenAI-compat shim) so options.num_ctx honored. Settings card shows server reachability pill, base URL field, install commands. First-run wizard adds 'Or run fully local' card. See standards/07-ai-integration.md §12 and Local-vs-Cloud-Models wiki page for head-to-head numbers. #local #ollama #offline
- [per_model_token_budgets] Every model has justified default + hard ceiling, configurable globally in Settings and per-run in Compose Run. Legacy 'Opus → 250k, else 1M' ternary eliminated. Per-step token usage tracked and emitted in events.jsonl. #budgets #control
- [unlimited_steps] Toggle in Settings, Compose Run, or Application defaults. When enabled, loops until mark_goal_done / cancel / budget. Token budget + cycle detector remain safety rails. Defaults off (reasonable max: 20–50 steps per run). #limits #safety
- [per_turn_behavior_reminders] System prompt includes per-turn behavior reminders (e.g., 'tap a text field first to focus it before calling type', 'prefer tap_mark when marks are available'). Reduces multi-tool / zero-tool / parse-failure responses. Parse-failure retry caps at 2 with corrective hint on retry. #prompting #error_recovery

## Relations
- implements [[Project Overview & Targets]]
- detailed_in [[standards/07-ai-integration.md]]
