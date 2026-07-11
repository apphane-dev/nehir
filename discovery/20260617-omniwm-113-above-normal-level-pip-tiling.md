# OmniWM PR BarutSRB/OmniWM#113 — "fix: skip above-normal-level windows from tiling (e.g. PiP)" — Discovery

Groom 2026-07-07: substantially resolved — PiP is now detected by window-server level (app-agnostic, level > 0 and < 20) and given sticky defaults (9ef0ae82, ade7cd07; see completed/20260626-pip-common-defaults-no-special-mode.md); re-verify the exact floating-classifier framing against current PiP handling (verified against main 7a025b78).

Source PR: https://github.com/BarutSRB/OmniWM/pull/113
Merge state: **closed without merge** (`merged: false`, `merged_at: null`) —
evaluate the concept, not a verbatim patch.
Scope of this doc: determine whether Picture-in-Picture / above-normal-level
windows get tiled in nehir, and whether the PR's level-based fix is safe to port.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Line numbers
drift — re-verify before implementing.

---

## TL;DR

- **nehir only partially mitigates this.** A built-in rule floats PiP windows for **Firefox and Zen Browser only**, matched on **exact English title** `^Picture-in-Picture$` (`WindowRuleEngine.swift:604`). Chrome / Safari / Edge / Brave / Arc / Vivaldi and **non-English-locale** PiP have no rule and fall through to the AX-button heuristic, which the PR author empirically showed classifies PiP as a standard managed window → **tiled**. The root cause — **no window-level discrimination** — is still present: `windowServer.level` is available in `WindowRuleFacts` but is consulted by exactly one classifier branch (CleanShot, `level == 103`).
- **Verdict:** 🟡 **Partial.** The bug reproduces for un-enumerated browsers/locales; adapt the PR's level concept as a **classification-level floating rule**, do **not** port its blanket `level > 0` admission skip (it would regress nehir's deliberately-included level-3/8 floating-window support).

## Provenance: is this nehir's code?

Yes. The two paths the PR touches both exist in nehir, renamed `OmniWM` → `Nehir`:

| PR site (OmniWM) | nehir equivalent | Location |
|---|---|---|
| `AXEventHandler.swift` new-window handler (admission) | created-window retry loop → `prepareCreateCandidate` | `AXEventHandler.swift:864`-`AXEventHandler.swift:893`, `AXEventHandler.swift:2561` |
| `LayoutRefreshController.swift` full-discovery loop | `buildFullRefreshExecutionPlan` enumeration loop | `LayoutRefreshController.swift:1143`-`LayoutRefreshController.swift:1170` |

The single existing level-based classification and the title-based PiP rule live in:

- CleanShot overlay (level 103 only): `WindowRuleEngine.swift:469`-`WindowRuleEngine.swift:483`.
- Built-in browser PiP rule: `WindowRuleEngine.swift:604`-`WindowRuleEngine.swift:625`.
- AX-button heuristic (no level input): `AXWindow.swift:631`-`AXWindow.swift:690`.

## The code in question

### nehir's discovery enumerator deliberately includes level 3 and level 8

```swift
// Sources/Nehir/Core/SkyLight/SkyLight.swift:484
guard parentId == 0 else { continue }

let level = windowIteratorGetLevel(iterator)
guard level == 0 || level == 3 || level == 8 else { continue }   // floating + modal admitted
```

PiP overlays live at `kCGFloatingWindowLevel` = **3** (and some browsers use higher
custom levels). nehir enumerates them, so discovery is not the filtering layer.

### nehir has exactly one level-based classifier, and it is CleanShot-only

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:469
private func cleanShotRecordingOverlayDecision(...) -> WindowDecision? {
    guard facts.ax.bundleId == Self.cleanShotBundleId,
          facts.ax.subrole == (kAXStandardWindowSubrole as String),
          facts.windowServer?.level == 103           // ← the ONLY level branch anywhere
    else { return nil }
    ...
    return WindowDecision(disposition: .floating, source: .builtInRule(...), ...)
}
```

`ffgrep` for `level` over `Sources/Nehir/Core/Rules/WindowRuleEngine.swift` returns
only this line (`WindowRuleEngine.swift:475`). The level stored as metadata
(`LayoutRefreshController.swift:1324`, `WMController.swift:3105`,
`AXEventHandler.swift:2990`) is never used as a disposition input elsewhere.

### The built-in PiP rule is bundle-id + exact-English-title, not level

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:604
let pipRules: [AppRule] = [
    AppRule(bundleId: "org.mozilla.firefox", titleRegex: "^Picture-in-Picture$", layout: .float),
    AppRule(bundleId: "app.zen-browser.zen",  titleRegex: "^Picture-in-Picture$", layout: .float)
]
...
CompiledRule(rule: rule, source: .builtIn("browserPictureInPicture"),
             titleRegex: try! NSRegularExpression(pattern: rule.titleRegex ?? ""),
             order: pipOffset + index)
```

Coverage is locked by `builtInPictureInPictureRuleEnablesTitleReevaluation`
(`WindowRuleEngineTests.swift:525`-`WindowRuleEngineTests.swift:545`), and the
title-fetch timing is handled by a created-window retry that holds the window
out of the workspace until the title resolves
(`AXEventHandlerTests.swift:447`-`AXEventHandlerTests.swift:471`,
`createdPictureInPictureWindowRetriesWhenTitleIsInitiallyMissing`).

`DefaultFloatingApps` (`DefaultFloatingApps.swift:3`-`DefaultFloatingApps.swift:13`)
contains **no browsers** — so Chrome/Safari/Edge/etc. PiP is not floated by the
default-floating set either.

### The heuristic that PiP escapes never sees the level

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift:631
static func heuristicDisposition(for facts: AXWindowFacts, ...) -> AXWindowHeuristicDisposition {
    ...
    if let subrole = facts.subrole, subrole != (kAXStandardWindowSubrole as String) {
        return AXWindowHeuristicDisposition(disposition: .floating, reasons: [.nonStandardSubrole])
    }
    if !facts.hasFullscreenButton { return ...(disposition: .floating, ...) }
    if facts.fullscreenButtonEnabled != true { return ...(disposition: .floating, ...) }
    return AXWindowHeuristicDisposition(disposition: .managed, reasons: [])   // ← PiP lands here
}
```

This is called from the rule-engine fallback (`WindowRuleEngine.swift:426`) with
**only `facts.ax`** — `AXWindowFacts` has no level field
(`AXWindow.swift:164`-`AXWindow.swift:172`). The PR's whole premise is that PiP
reports a **standard subrole with all buttons present**, so every branch above the
final `return ... .managed` is skipped and PiP is tiled. nehir's heuristic is the
same button-based logic, so a PiP window from any browser **not** in the two-rule
set reproduces the bug.

## Why this partially applies (and the PR's fix is unsafe to port verbatim)

**Where nehir already wins:** the PR author's own reproduction was **Zen Browser**
(`app.zen-browser.zen`); nehir's built-in rule covers both Zen and Firefox by exact
title, including the admission-time title-fetch retry, so those two cases do not tile.

**Where the bug still reproduces** (root cause = no level discrimination):

- **Chrome** (`com.google.Chrome`), **Edge** (`com.microsoft.edgemac`), **Brave**,
  **Arc** (`company.thebrowser.Browser`), **Vivaldi**, **Opera**, **Safari**
  (`com.apple.Safari`) — no built-in rule, not in `DefaultFloatingApps`; Safari PiP
  is only covered by an **inactive** `.toml.sample`
  (`AppRuleFileStore.swift:158`-`AppRuleFileStore.swift:165`, `titleSubstring =
  "Picture in Picture"`) that a user must rename to enable.
- **Localized titles** — `^Picture-in-Picture$` fails in non-English locales
  (Firefox/Zen ship translated PiP titles), so even the two covered browsers regress
  outside English.
- **Any above-normal overlay that is not browser PiP** (custom app overlays, some
  media-toolkit floats) — nothing discriminates them by level.

**Why the PR's diff must not be ported as-is.** The PR inserts `if windowInfo.level
> 0 { return }` at admission and `if info.level > 0 { continue }` in the discovery
loop. Both would be a regression in nehir:

1. nehir **deliberately enumerates and classifies** levels 3 (floating) and 8
   (modal) (`SkyLight.swift:487`) so it can **track** floating windows and surface
   them in the workspace bar (`WorkspaceBarDataSource.swift:70`,
   `WorkspaceManager.swift:2548`-`WorkspaceManager.swift:2577`). A blanket
   `level > 0` skip at admission would drop those windows entirely instead of
   classifying them as floating — the opposite of nehir's design.
2. The PR's insertion points sit **before** the rule engine, bypassing nehir's
   user/built-in rules, manual overrides, and managed-replacement metadata.

The robust discriminator the PR identifies (window-server level) is correct; the
fix should be a **classification** decision (`floating`, not `managed`) keyed off
`facts.windowServer?.level`, not an admission/exclusion skip.

## Recommendation

Own a nehir follow-up — **adapt, do not verbatim-port**:

1. Add a level-aware classifier in `WindowRuleEngine.decision` (between the
   `cleanShotRecordingOverlayDecision` branch at `WindowRuleEngine.swift:369` and
   the heuristic fallback at `WindowRuleEngine.swift:426`): a top-level
   (`parentId == 0`) window whose `facts.windowServer?.level` is above normal
   (`> 0`) and whose subrole is standard should return `.floating` with an
   explicit built-in-rule source (e.g. `"aboveNormalWindowLevel"`). This makes
   PiP app-agnostic and locale-proof, complementing rather than replacing the
   Firefox/Zen title rule.
2. Keep the existing `browserPictureInPicture` title rule — it is still useful for
   the title-fetch retry timing and for browsers whose PiP sits at level 0.
3. Do **not** add a `level > 0` skip in `prepareCreateCandidate`
   (`AXEventHandler.swift:2561`) or the discovery loop
   (`LayoutRefreshController.swift:1143`); those would exclude legitimate floating
   windows nehir tracks.
4. Note the edge case to test: some apps place genuinely document-like windows at
   level 3 (rare). The classifier should prefer `.floating` over `.unmanaged` so the
   window remains visible in the workspace bar rather than vanishing.

## Suggested tests

- A window with `windowServer.level == 3`, standard subrole, all buttons present,
  no matching user rule, and a **non-enumerated bundle id** (e.g. `com.google.Chrome`)
  → `decision.disposition == .floating`, `source == .builtInRule("aboveNormalWindowLevel")`,
  `trackedMode == .floating` (currently this returns `.managed`/`.tiled`).
- The same shape but `level == 0` → still `.managed` (regression guard: the level
  rule does not swallow normal windows).
- Firefox/Zen PiP with title `"Picture-in-Picture"` → still `.floating` via the
  existing `browserPictureInPicture` rule (the new level rule must not shadow it).
- A localized-title Firefox PiP (title ≠ `"Picture-in-Picture"`) at `level == 3` →
  `.floating` via the level rule (proves locale robustness, the gap the title rule
  leaves).
- A top-level floating window at `level == 3` is **admitted** and appears in
  `WorkspaceBarDataSource.workspaceBarItems` with `showFloatingWindows == true`
  (regression guard that the fix is classification, not exclusion).
