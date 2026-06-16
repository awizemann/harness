# Local vs Cloud Models — same goal, same site, three models

A reproducible head-to-head benchmark of three vision models running the **same goal**, **same persona**, **same site**, **same viewport** through Harness. Captured 2026-05-20 via [HarnessCLI](HarnessCLI) against `https://alanwizemann.com`.

The purpose: pick the right model class for a given debugging or testing job. Local is private and free. Cloud is faster and better at synthesis. The differences are concrete and measurable.

## Setup

Identical inputs across all three runs:

- **URL**: `https://alanwizemann.com`
- **Goal**: *"Find Alan's most recent article and tell me what it's about in your own words"*
- **Persona**: "A curious first-time user who has never seen this app before. You read labels carefully and try to figure things out from what's on screen..."
- **Viewport**: 1280 × 1600 CSS pixels
- **Max steps**: 15 (none of the runs hit this cap)

Each run was driven by `harness-cli` with `HARNESS_DUMP_MARKED=1` for full diagnostics. The Anthropic runs read the API key from the local macOS Keychain via [EnvKeychain](HarnessCLI#diagnostic-env-vars)'s system fallback.

```bash
harness-cli \
  --url https://alanwizemann.com \
  --goal "Find Alan's most recent article and tell me what it's about in your own words" \
  --persona "A curious first-time user..." \
  --provider <anthropic|local> \
  --model <claude-opus-4-7|claude-sonnet-4-6|qwen3-vl:8b> \
  --viewport-width 1280 \
  --viewport-height 1600 \
  --output ./test-run-<name> \
  --max-steps 15
```

## Results

| Model | Steps | Wall-clock | Output tokens | Date read correctly? |
|---|---:|---:|---:|:---:|
| **Qwen3-VL 8B** *(local, Ollama)* | 3 | ~15.5 min | 1926 | ❌ (said 2023; actual 2026) |
| **Claude Opus 4.7** *(Anthropic)* | 4 | ~1.8 min | 1340 | ✅ |
| **Claude Sonnet 4.6** *(Anthropic)* | 5 | ~38 s | 1354 | ✅ |

All three reached `verdict: success` and called `mark_goal_done` with a real summary. All three chose the same first move (`tap_mark(6)` → Articles) and the same article (`tap_mark(32)` → "Tech Is Dumb Out of the Gate", May 14 2026).

## What each model wrote

### Qwen3-VL 8B (local, Ollama)

> "I found Alan Wizemann's most recent article, 'Tech Is Dumb Out of the Gate' (dated May 14, **2023**). The article discusses how automation in warehouses unexpectedly changed workers' roles from sorting cases to becoming subject matter experts who trained the systems. It challenges assumptions about automation replacing jobs, showing how the implementation actually created new expertise opportunities."

Local captures the article's main idea but lacks specifics. The model misread the publication year — at the LLM-side downscale (768pt long-edge for local models, see [Web-Driver](Web-Driver)) small date text is at the legibility floor.

### Claude Opus 4.7 (Anthropic)

> "...Alan's broader point is that technology is 'dumb out of the gate': a new system doesn't understand the shortcuts, relationships, and judgment that experienced employees have built up over years. The right question when introducing AI isn't 'how many roles can we eliminate' but 'what are people doing now that they shouldn't have to do, and where could their judgment be redirected.' Replacing headcount with AI, he argues, is a choice — not an inevitable outcome of the tech — and often the wrong one, especially in relationship-driven businesses."

Opus pulls out the article's thesis verbatim and reads the surrounding argument. Strong synthesis, full date.

### Claude Sonnet 4.6 (Anthropic)

> "Alan's most recent article is 'Tech Is Dumb Out of the Gate,' published May 14, 2026. In it, Alan argues that new technology and automation systems start out 'dumb' — they lack the real-world, contextual knowledge that experienced workers have built up over years. He illustrates this with a story about a warehouse worker at **Southern Glazer's** who sorted broken cases by hand. When automation was introduced, everyone assumed the worker would lose his job. Instead, the opposite happened: he became the subject matter expert who trained the system, improved its routing and staging logic, and was put in charge of redesigning operations... The human in the loop isn't a limitation on the technology — it's what makes the technology worth the investment."

Sonnet matches Opus's thesis grasp AND adds the company name ("Southern Glazer's") — a small chip in the article body Opus didn't include. Most thorough summary at the fastest wall-clock.

## What to use, when

| Use case | Recommendation |
|---|---|
| Iterating on agent loop / prompts / driver code | **Local (Qwen3-VL 8B).** Free, private, runs while offline. The model's slower inference is actually useful for debugging — you have time to read screenshots between steps. |
| Daily smoke tests in CI | **Sonnet 4.6.** 38 seconds per goal, cheap on Anthropic's prompt cache, summaries usable as friction-report fodder. |
| High-quality UX critique / nuanced friction analysis | **Opus 4.7.** Slightly slower than Sonnet, slightly more expensive, but the qualitative depth on subtle UX cues is noticeable. |
| Cross-model regression testing | **All three, sequentially.** When changing the agent loop or web driver, run the same goal across providers. Local catches "did the navigation actually fire" issues that cloud's better recovery would mask; Sonnet sanity-checks throughput; Opus surfaces edge cases the other two miss. |

## Why the local path works at all

For most of v0.3 development, sub-10B local vision models couldn't complete this run. The same Qwen3-VL 8B against this exact site was looping in scroll-land at the 14-step mark in our pre-2026-05-18 baseline. The changes that made it usable, in order of impact:

1. **Set-of-Mark probe expansion** — anchor links (`a[href]`) now get badges. Eliminates coordinate-emission failures on nav.
2. **Mark-list annotation** in every turn's user message — model matches intent → id by label, not by visual recall.
3. **SPA route-transition settle gate** — `awaitDOMSettled` requires a `childList` mutation before resolving when the URL changed.
4. **Tighter history compaction for local models** (3 turns vs 6 for cloud) — prevents inference-time blowup as the conversation grows.
5. **Scroll progress feedback** — when scrolls don't move the page, the model sees an objective signal instead of relying on visual diff.

See [Web-Driver](Web-Driver) for the implementation details and [Agent-Loop](Agent-Loop) for how the loop wires it all together.

## Notes

- **Step count isn't quality**: Qwen finished in 3 steps but with a worse summary (it summarized from the article preview text, never scrolled to read the body). Sonnet took 5 steps because it scrolled the article body twice; that's *why* its summary names "Southern Glazer's".
- **Wall-clock dominates inference time, not settle**: Qwen's 15 minutes is almost entirely Ollama inference latency on Apple Silicon at the typical ~5s/token rate it sustains with 6-12K tokens of context. The settle gates add < 10s/step on average for cloud, < 12s/step for local.
- **Token budgets** above (set by `AgentModel.defaultTokenBudget`) are per-run input ceilings; none of the three runs came close to hitting theirs. Opus has the tightest default (250k input tokens) since it's the most expensive; Sonnet and Qwen sit at 1M.

## Reproducing

```bash
# Build
xcodegen generate
xcodebuild -project Harness.xcodeproj -scheme HarnessCLI build

# Locate
CLI="$(xcodebuild -project Harness.xcodeproj -scheme HarnessCLI \
        -showBuildSettings build 2>/dev/null \
        | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')/harness-cli"

# Local
HARNESS_DUMP_MARKED=1 "$CLI" \
  --url https://alanwizemann.com \
  --goal "Find Alan's most recent article and tell me what it's about in your own words" \
  --persona "A curious first-time user..." \
  --provider local --model qwen3-vl:8b \
  --viewport-width 1280 --viewport-height 1600 \
  --output ./test-run-local --max-steps 15

# Cloud (reads ANTHROPIC_API_KEY from env, falling back to macOS Keychain)
"$CLI" \
  --url https://alanwizemann.com \
  --goal "Find Alan's most recent article and tell me what it's about in your own words" \
  --persona "A curious first-time user..." \
  --provider anthropic --model claude-sonnet-4-6 \
  --viewport-width 1280 --viewport-height 1600 \
  --output ./test-run-sonnet --max-steps 15
```

Outputs include the per-step `step-NNN.png` (and `.marked.png` when `HARNESS_DUMP_MARKED=1`) plus `events.jsonl` — every screenshot the model saw, every tool it called, the WebDriver-side click result. Diff two runs cleanly with `diff <(jq -c '. | {step, kind, tool, verdict}' run-a/events.jsonl) <(jq -c '. | {step, kind, tool, verdict}' run-b/events.jsonl)`.
