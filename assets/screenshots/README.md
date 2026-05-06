# Landing-page screenshots

Capture spec lives in the marketing-site plan. Naming: `{name}.png` (light) and `{name}-dark.png` (dark). Same dimensions per pair; capture at 1440×900 logical with the same window size for both variants.

| Filename                  | Screen          | Notes |
|---------------------------|-----------------|-------|
| `runsession-hero.png`     | RunSession      | Mid-run on the demo iOS app, simulator mirror visible, step feed has 3 prior steps, tap-coordinate overlay rendered. |
| `target-ios.png`          | RunSession      | iOS run, sign-up flow mid-keystroke, persona chip visible. |
| `target-macos.png`        | RunSession      | macOS app run, step feed shows a click. |
| `target-web.png`          | RunSession      | Web run via WKWebView at 1280×800, friction event just fired. |
| `goal-input.png`          | GoalInput       | All fields filled with a real, vivid goal sentence. |
| `friction-report.png`     | FrictionReport  | 4–6 grouped friction cards covering 2–3 different friction kinds. |
| `run-replay.png`          | RunReplay       | Scrubber mid-drag, step detail panel open. |
| `run-history.png`         | RunHistory      | 8–12 rows, mixed verdicts, one filter pill active, search query in the box. |
| `first-run-wizard.png`    | FirstRunWizard  | API-key step with the tooling-check rail green. |

Plus a `-dark.png` for each. Run `pngquant --quality=80-95 *.png` once captured to keep page weight under ~5 MB.

No real client UI, real bundle IDs, or API key prefixes in any frame.
