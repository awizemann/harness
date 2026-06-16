---
title: Development Setup & First Clone
type: note
permalink: harness/core/development-setup-first-clone
tags:
- setup
- dependencies
- workflow
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: CONTRIBUTING.md, README.md
---

## Observations
- [requirement] macOS 14+, Xcode 16+ (Swift 6 strict concurrency), Homebrew. #system
- [requirement] idb_companion for simulator control: brew tap facebook/fb && brew install idb-companion. #dependencies
- [requirement] Anthropic API key (stored in macOS Keychain on first run). Optional: OpenAI, Google, Ollama endpoint. #credentials
- [workflow] First clone: git clone, cd harness, git submodule update --init --recursive (vendors appium/WebDriverAgent), brew install xcodegen, xcodegen generate, open Harness.xcodeproj. #git #xcodegen
- [workflow] Xcode project generated from project.yml via xcodegen. After pulling changes touching sources or resources, re-run 'xcodegen generate'. Harness.xcodeproj/ is gitignored. #xcodegen
- [fact] First run builds WebDriverAgent against simulator's iOS runtime (~1–2 min). Result cached under ~/Library/Application Support/Harness/wda-build/<iOS-version>/ and reused on subsequent runs. #wda #caching

## Relations
- extends [[Contributing-md Guidelines]]
