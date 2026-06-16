# macOS Driver

The macOS run path. Drives a native `.app` via `CGEvent` for input and `CGWindowListCreateImage` for capture. Set-of-Mark scaffolding via the **AX (Accessibility) API** — same numbered-badge contract as [Web-Driver](Web-Driver) and [iOS-Driver](iOS-Driver).

| File | Role |
|---|---|
| `Harness/Platforms/MacOS/MacOSPlatformAdapter.swift` | `PlatformAdapter` lifecycle: launch the bundle (or attach to an already-running app), drive, terminate-or-leave on teardown. |
| `Harness/Platforms/MacOS/MacAppDriver.swift` | The actor that captures windows, posts CGEvents, runs the AX probe, and dispatches `tap_mark`. |
| `Harness/Platforms/MarkRenderer.swift` | Shared with web and iOS. |

## Lifecycle

```
MacOSPlatformAdapter.prepare(_:runID:continuation:)
  1. Resolve bundle URL (request.macAppBundlePath OR LaunchServices lookup)
  2. NSWorkspace.openApplication(bundleURL, activates: true)
  3. Wait briefly for the app's main window to materialise
                                                   → simulatorReady (pseudo)
  4. Return RunSession{ driver: MacAppDriver(bundleIdentifier, appBundleURL), ... }
```

The "simulator" in `RunSession` is a synthesized `SimulatorRef` so the existing event shape carries display labels and viewport hints. There's no actual simulator on macOS.

## Screenshot pipeline

`MacAppDriver.screenshot(into:)` per agent step:

```
1. ensureFront()                          # bring SUT to the front
2. findFrontWindow()                      # CGWindowList query for the app's frontmost window
3. probeInteractiveElements(pid, windowOrigin, windowSize)  → [InteractiveMark] (point space, window-local)
   (cached on the actor as lastMarks)
4. CGWindowListCreateImage(window)        # native-resolution capture
5. Encode PNG → write to disk (unmarked)
6. If marks empty: return ScreenshotMetadata with no overlay.
7. Otherwise: MarkRenderer.draw(on:NSImage(from PNG), marks:, markSpaceSize: pointSize)
   The renderer scales rects from window points → image pixels.
8. Encode the marked image, dump alongside the unmarked PNG if HARNESS_DUMP_MARKED=1
9. Return ScreenshotMetadata{ pixelSize, pointSize, markedImageData, markedAnnotationText }
```

## Set-of-Mark probe (AX API)

`MacAppDriver.probeInteractiveElements(pid:windowOrigin:windowSize:)` walks the AX tree of the focused (or main) window via `AXUIElementCreateApplication(pid)` and friends.

### Probe selector

Actionable AX roles. The set mixes `kAX...Role` constants from HIServices and string literals for roles AppKit defines at runtime (`AXLink`, `AXSecureTextField`, `AXSearchField`, `AXStepper`, `AXSwitch`).

| Category | Roles |
|---|---|
| Buttons + menus | AXButton, AXMenuButton, AXPopUpButton, AXMenuItem, AXMenuBarItem |
| Text input | AXTextField, AXTextArea, AXComboBox, AXSecureTextField, AXSearchField |
| Selection | AXCheckBox, AXRadioButton, AXSlider, AXIncrementor, AXStepper, AXSwitch |
| Disclosure | AXDisclosureTriangle |
| Visual | AXColorWell, AXImage, AXLink |
| Lists | AXRow, AXCell |
| Tabs | AXTabGroup |

Container roles (`AXWindow`, `AXGroup`, `AXSplitGroup`, `AXScrollArea`, `AXToolbar`, `AXLayoutArea`, `AXList`, `AXOutline`, `AXTable`, `AXSheet`, `AXDrawer`, `AXMenu`, `AXMenuBar`) are walked instead of marked.

### Coordinate conversion

AX returns rects in **global screen** coordinates (top-left origin). The probe subtracts `windowOrigin` to produce window-local coordinates (the same point space `MacAppDriver.execute` uses for `tap` / `scroll`), then intersects with the window bounds to drop elements that overflow scroll areas off-screen.

### Bounding the walk

- Max depth 24
- Max 1500 nodes visited
- Final cap of 80 marks per screenshot

Pathological trees (deeply nested Catalyst apps, AppKit apps with `kAXChildrenAttribute` returning hundreds of decorative grouping elements) are bounded by these caps. The remaining elements are sorted top-to-bottom then left-to-right.

### Label resolution

In priority order:
1. `kAXTitleAttribute` — button text, link text, menu item label
2. `kAXValueAttribute` — current text-field content
3. `kAXDescriptionAttribute` — accessible description on icon buttons
4. `kAXHelpAttribute` — tooltip
5. `kAXIdentifierAttribute` — developer-set identifier (last resort)

Empty strings are skipped. Whitespace-trimmed and clipped to 80 chars.

## tap_mark dispatch

`MacAppDriver.dispatchMarkClick(id:info:)`:

1. Resolves `id` against `lastMarks`. Stale → `MacDriverError.unknownMark(id:)`; retry-hint surfaces to the model.
2. Viewport-clips the rect (4pt inset, same as iOS / web).
3. Posts a left-click via `postClick` at the clipped midpoint (the same CGEvent path `tap` uses).

`HARNESS_DUMP_MARKED=1` writes:

```
[MacAX] tap_mark(8) label="Remind Me Later" role=button rect=(237,353,133,30) → click(303,368)
```

## Settle gate

Same approach as iOS — **screenshot dHash stability** (`MacAppDriver.awaitWindowStable`). Per-tool profiles:

| Tool family | idleMs | minMs | maxMs |
|---|---:|---:|---:|
| tap / doubleTap / tapMark / rightClick / fillCredential | 250 | 250 | 2000 |
| scroll | 400 | 400 | 3000 |
| keyShortcut | 350 | 350 | 2500 |
| type / others | — | — | — (no settle) |

The gate captures + hashes the front window directly via `CGWindowListCreateImage`. Capture errors are non-fatal; the gate times out at `maxMs`.

## Permissions

The macOS driver needs **two** per-binary permissions:

1. **Screen Recording** — for `CGWindowListCreateImage`. Without it, screen capture returns a blank image.
2. **Accessibility** — for AX attribute pulls. Without it, every probe returns 0 marks.

macOS surfaces the system prompt on first attempt to capture / probe. `HarnessRunner.checkMacPermissions` runs pre-flight when `--platform macos` is set; it prints a friendly heads-up + requests the permissions before the run starts, so the user gets one expected dialog rather than one mid-step.

Per-binary means the GUI app's grants don't help the CLI binary. After granting once, subsequent CLI runs are silent.

## tap_mark vs tap

Same recommendation as iOS: prefer `tap_mark` when a mark is visible. The macOS platform context at `docs/PROMPTS/platforms/macos.md` and the per-turn user-message reminders both push agents toward marks.

## Diagnostic env vars

| Variable | Effect |
|---|---|
| `HARNESS_DUMP_MARKED=1` | Writes `step-NNN.marked.png` + logs tap_mark resolution + click result to stderr. |

## Failure modes worth knowing

- **Window not found**: app launched but no visible window yet (cold start, splash screen). The next screenshot retry usually resolves it.
- **Probe returns []**: no AX permission, or the focused window's tree is collapsed (Catalyst app with custom drawing). Verify with macOS's `Accessibility Inspector` to confirm AX actually exposes targets.
- **Coordinate drift**: AX returns rects valid at probe time; if the window resizes between probe and click, the cached rect is stale. Currently we don't re-probe — agents see the discrepancy in the next turn's screenshot.

## Cross-references

- [HarnessCLI](HarnessCLI) — `--platform macos --app-path /Applications/Some.app`
- [Web-Driver](Web-Driver) and [iOS-Driver](iOS-Driver) — same Set-of-Mark contract on different runtimes
- [Agent-Loop](Agent-Loop), [Tool-Schema](Tool-Schema)
- `docs/PROMPTS/platforms/macos.md` — the macOS platform-context block
