---
title: Development Setup & First Clone
type: note
permalink: harness/core/development-setup-first-clone
tags: [setup, dependencies, workflow]
source_paths: [CONTRIBUTING.md, README.md, scripts/build-detached.sh, Harness/Services/SimulatorDriver.swift]
source_sha: 0f314a201100eb3e00b943712ea5906fa4cf9d24
created: 2026-06-16
updated: 2026-06-16
reviewed: 2026-07-23
reviewed_by: audit:claude-code (background)
---

## Observations
- [requirement] macOS 14+, Xcode 16+ (Swift 6 strict concurrency), Homebrew. #system
- [requirement] xcodegen for generating Harness.xcodeproj from project.yml: brew install xcodegen. (idb_companion is NO LONGER required — replaced by WebDriverAgent in the Phase 5 idb→WDA migration; see Harness/Services/SimulatorDriver.swift, WDARunner.swift.) #dependencies
- [requirement] Anthropic API key (stored in macOS Keychain on first run). Optional: OpenAI, Google, Ollama endpoint. #credentials
- [workflow] First clone: git clone, cd harness, git submodule update --init --recursive (vendors appium/WebDriverAgent), xcodegen generate, open Harness.xcodeproj. #git #xcodegen
- [workflow] Xcode project generated from project.yml via xcodegen. After pulling changes touching sources or resources, re-run 'xcodegen generate'. Harness.xcodeproj/ is gitignored. #xcodegen
- [fact] First run builds WebDriverAgent against simulator's iOS runtime (~1–2 min). Result cached under ~/Library/Application Support/Harness/wda-build/<iOS-version>/ and reused on subsequent runs. #wda #caching
- [workflow] scripts/build-detached.sh (no args) builds into isolated DerivedData and launches a decoupled, visually-distinct dev copy; quits prior dev copies but spares /tmp agent test copies. The standard build-and-run path for local dogfooding. #build

## Relations
- relates_to [[Contributing Rules & Public Surfaces Sync]]
