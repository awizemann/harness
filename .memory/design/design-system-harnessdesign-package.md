---
title: Design System & HarnessDesign Package
type: note
permalink: harness/design/design-system-harnessdesign-package
tags:
- design_system
- tokens
- ui
source_sha: 898ebd9c030f8959ac46c7690487f267692a728c
source_paths: HarnessDesign/, standards/05-design-system.md
---

## Observations
- [harness_design_scope] HarnessDesign is a separate Swift Package included in the main app target (not a separate product target). Contains: design system tokens (Theme.*, HFont.*, Color.harness*), primitives (Button, TextField, Card, ListView, etc.), and screen layout components. Every feature view consumes from HarnessDesign; no raw .padding(12) / color literals / cornerRadius: 8 allowed. #tokens #package
- [token_categories] Theme.* for spacing/sizing. HFont.* for typography (weights, sizes). Color.harness* for semantic colors (brand, status, error, etc.). All values defined once in HarnessDesign/Sources; apps reference symbolic names. Design-system unification enforced by standards/05-design-system.md + audit checklist. #tokens #semantic
- [primitive_components] HarnessDesign exports reusable primitives: PrimaryButton, SecondaryButton, TextField (with focus state), Card, ListView (with selection state), VerdictPill, FrictionTag, StatusBadge, etc. Each primitive documents its variant via enum (e.g., VerdictPill.success / .failure / .blocked). Previews show all variants; no surprises at integration time. #primitives #reusable
- [mappers_layer] Harness/Domain/Mappers.swift adapts production Verdict / ToolKind / FrictionKind / ToolCall to the HarnessDesign Preview* placeholder types the primitives consume. Cheap conversion at the binding layer; lets primitives stay decoupled from the domain model. #adapter #decoupling

## Relations
- implements [[Architecture & Design Decisions]]
- governs [[CONTRIBUTING.md Guidelines]]
