# Hiro issue #391 — "Valve Steam client cannot be tiled" — Discovery

Source issue: <https://github.com/BarutSRB/Hiro/issues/391>
Filed against: `BarutSRB/Hiro` (upstream of nehir — see `NOTICE.md`;
nehir is a fork of `BarutSRB/OmniWM`, which was renamed to Hiro).
Scope of this doc: determine whether the issue applies to nehir, whether it is an
AX-classification gap, and whether it overlaps the workspace-bleed / stale-live-frame
class already investigated in sibling docs.

All file/line references were verified against worktree `worktree-calm-meadow-6229`
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace").
Re-verify before implementing; line numbers drift.

> **Filed under `discovery/noop/`** — #391 reports **two** symptoms, and neither owns
> a new repo action:
> - **Symptom A — "stays floating, cannot be viewed in overview, cannot be tiled."**
>   This is **expected, conservative classification**, not a nehir bug. nehir's
>   `heuristicDisposition` deliberately sends non-standard-AX windows to `.floating`;
>   Steam's custom-chrome window trips it. The remedy is a user **tile** rule
>   (or a `forceTile` manual override), which nehir already supports — the reporter's
>   `com.valvesoftware.steam` rule set the *workspace* but not the *tile* action.
> - **Symptom B — "I can see the steam window in the background behind the tiles" on
>   other workspaces.** This is **real in nehir, but a duplicate** of the
>   workspace-inactive stale-live-frame family already owned by
>   `20260616-workspace-inactive-stale-live-frame.md` and the upstream-symptom record
>   `noop/20260616-hiro-235-window-bleed-different-workspace.md`. Floating windows
>   park through the *same* `.workspaceInactive` hide path and hit the *same*
>   skip-already-hidden / `layoutTransient`-only reconciliation gaps; Steam adds no
>   new root cause.
>
> Porting any upstream diff would at best be a no-op (A is config, B is already
> tracked); weakening the heuristic to auto-tile Steam would **regress** by tiling
> real dialogs/panels. The fix work for B lives in the sibling docs.

---

## TL;DR

- **#391 is two findings, both previously owned.** The "can't tile" half is by-design
  AX classification; the "leaks across workspaces" half is the workspace-inactive
  stale-live-frame bug nehir already captured live (Telegram `windowId=159`, live at
  `x=1050..2056` on active workspace 1 while `hidden=workspaceInactive`).
- **Verdict:** 🟡 **Partial / Duplicate.** The leak reproduces in nehir but is the same
  root cause as the workspace-inactive family; the tile failure is expected behavior.
- **Upstream state:** #391 was **closed `completed` by BarutSRB on 2026-06-15 with no
  fix commit, no linked PR, and zero comments** (verified via the GitHub issues/timeline
  APIs). Its resolution is therefore not evidence of a fix — like #235, it reads as a
  stale-issue sweep. The nehir behavior is unaffected by the closure.

## Provenance: is this nehir's code?

Yes. `NOTICE.md` states nehir forks `BarutSRB/OmniWM`, renamed upstream to Hiro. Every
symbol #391's two symptoms depend on exists in nehir at HEAD:

| Issue concern | Nehir symbol | Definition site |
| --- | --- | --- |
| Top-level window admission gate | `AXWindowService.shouldTreatAsTopLevelWindow` | `Sources/Nehir/Core/Ax/AXWindow.swift:313` |
| Floating-vs-managed heuristic | `AXWindowService.heuristicDisposition` | `Sources/Nehir/Core/Ax/AXWindow.swift:631` |
| Heuristic reason enum | `AXWindowHeuristicReason` | `Sources/Nehir/Core/Ax/AXWindow.swift:144` |
| Disposition fallback chain | `WindowRuleEngine.decision` | `Sources/Nehir/Core/Rules/WindowRuleEngine.swift:318` |
| User-rule `.tile`→`.managed` | `WindowRuleEngine.explicitDecision` / `fallbackDecisionForMatchedUserRule` | `Sources/Nehir/Core/Rules/WindowRuleEngine.swift:455` |
| `forceTile` manual override → `.managed` | `WMController.decisionApplyingManualOverride` | `Sources/Nehir/Core/Controller/WMController.swift:1405` |
| Inactive-workspace hide (tiled **and** floating) | `LayoutRefreshController.hideWorkspace` | `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2142` |
| Workspace-inactive park → screen edge | `hideWindow` → `resolveHideOperation` → `liveFrameHideOrigin` | `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2472` |
| Window scan admission loop | `AppAXContext` per-element `shouldTreatAsTopLevelWindow` guard | `Sources/Nehir/Core/Ax/AppAXContext.swift:422` |

There is **no Steam-specific** or `valvesoftware` handling anywhere in nehir
(`ffgrep steam|valvesoftware` → no matches). Steam is treated by the general path.

---

## The code in question

### Symptom A — why Steam is classified `.floating` (and cannot tile)

Steam is first admitted only if it passes the top-level gate:

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift:313
static func shouldTreatAsTopLevelWindow(role: String?, subrole: String?) -> Bool {
    role == kAXWindowRole as String || subrole == kAXStandardWindowSubrole as String
}
```

The reporter's bundle-id rule placed Steam on a workspace, so Steam *does* pass this gate
(role `AXWindow`) and *is* tracked — confirming the window is discovered. The question is
then its **mode**, decided by `WindowRuleEngine.decision`. With no explicit `.tile` rule,
the chain bottoms out in the heuristic (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:405-413`):

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:405
let heuristic = AXWindowService.heuristicDisposition(for: facts.ax, sizeConstraints: facts.sizeConstraints)
return WindowDecision(disposition: heuristic.disposition, ...)
```

`heuristicDisposition` is a cascade of conservative floating gates; a window reaches
`.managed` **only** if it clears every one of them (`Sources/Nehir/Core/Ax/AXWindow.swift:631-684`):

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift:631
static func heuristicDisposition(for facts: AXWindowFacts, sizeConstraints: WindowSizeConstraints? = nil,
                                 overriddenWindowType: AXWindowType? = nil) -> AXWindowHeuristicDisposition {
    ...
    if facts.appPolicy == .accessory && !facts.hasCloseButton { return .floating, [.accessoryWithoutClose] }        // :659
    if !hasAnyButton && facts.subrole != kAXStandardWindowSubrole as String { return .floating, [.noButtonsOnNonStandardSubrole] } // :664
    if let subrole = facts.subrole, subrole != (kAXStandardWindowSubrole as String) { return .floating, [.nonStandardSubrole] }    // :669
    if !facts.hasFullscreenButton { return .floating, [.missingFullscreenButton] }                                   // :676
    if facts.fullscreenButtonEnabled != true { return .floating, [.disabledFullscreenButton] }                        // :680
    return .managed, []                                                                                              // :684
}
```

To be tiled, a window must therefore expose, via AX: attribute fetch success; a standard
subrole (or `nil`); **all** standard window buttons; **and** an **enabled** fullscreen
button. Steam's main window draws custom Chrome / webview chrome and is widely known to
the macOS-AX community to expose a non-standard subrole and/or to omit or disable the
standard traffic-light / fullscreen buttons. Steam accordingly trips one of
`.nonStandardSubrole` / `.missingFullscreenButton` / `.disabledFullscreenButton` /
`.noButtonsOnNonStandardSubrole` and lands at `.floating`. A floating window is excluded
from tiling and from the overview (which enumerates tiled columns), exactly matching the
report: *"stays floating … cannot be viewed in overview, and cannot be tiled."*

This is **deliberate**. The heuristic exists precisely to avoid tiling dialogs, panels,
and popups; every gate here exists to protect against mis-tiling genuine non-document
windows. nehir's classification is identical to upstream's.

**The override already exists.** A user rule whose layout action is `.tile` is mapped to
`.managed` directly (`WindowRuleEngine.swift:462`), and a `forceTile` manual override
forces `.managed` regardless of the heuristic (`WMController.swift:1413`):

```swift
// Sources/Nehir/Core/Controller/WMController.swift:1405
private func decisionApplyingManualOverride(_ decision: WindowDecision, manualOverride: ManualWindowOverride?) -> WindowDecision {
    guard let manualOverride, decision.disposition != .unmanaged else { return decision }
    return WindowDecision(disposition: manualOverride == .forceTile ? .managed : .floating, ...)
}
```

The reporter set a `com.valvesoftware.steam` rule and got workspace assignment ("I was
able to force it to spawn in specific workspace (like workspace 2)") but never set the
rule's layout action to **tile** — so the heuristic still classified it floating.
Symptom A is a configuration gap, not a nehir defect.

### Symptom B — why the (floating) Steam window leaks across workspaces

Once floating on, say, workspace 2, Steam must be parked when workspace 2 is inactive.
`hideInactiveWorkspaces` iterates **all** entries on each inactive workspace — tiled and
floating alike — and parks each through `hideWorkspace`:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2124  (hideInactiveWorkspaces)
for snapshot in workspaceEntries where !activeWorkspaceIds.contains(snapshot.workspace.id) {
    ...
    hideWorkspace(snapshot.entries, monitor: monitor, preferredSide: preferredSide, ...)
}
```

`hideWorkspace` has **no `.mode == .floating` filter**, so floating windows take the same
hide path as tiled ones:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2142
private func hideWorkspace(_ entries: [WindowModel.Entry], monitor: Monitor, preferredSide: HideSide, ...) {
    for entry in entries {
        guard controller.workspaceManager.layoutReason(for: entry.token) != .nativeFullscreen else { continue }
        controller.axManager.markWindowInactive(entry.windowId)
        if let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) {   // :2156  skip-already-hidden
            traceWorkspaceInactiveVisibleDriftIfNeeded(entry, monitor: monitor, ...)
            continue                                                                         // ← no park plan if metadata present
        }
        hideWindow(entry, monitor: monitor, side: preferredSide, reason: .workspaceInactive, ...)   // :2164
    }
}
```

`hideWindow` routes everything through `resolveHideOperation`, again with **no** floating
gate (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2472`), and the
`.workspaceInactive` reason resolves to a **physical-screen-edge park** (mostly off-screen,
a ~1px reveal) rather than a compositor-level hide — identical to the tiled case. (The
floating-specific branches in this file — `shouldUsePendingRevealTransaction` at `:2693`,
`restoreWindowFromHiddenState` at `:2983` — are on the **reveal/restore** path, not the
hide path, so they do not change how a floating window is parked.)

That means a floating Steam window is subject to the *exact* two gaps the sibling docs
already pinned for tiled windows:

1. **`hideWorkspace` skips already-hidden windows without re-verifying the live frame**
   (`LayoutRefreshController.swift:2156-2167`). The drift detection
   (`traceWorkspaceInactiveVisibleDriftIfNeeded`, `workspaceInactiveVisibleDriftLine`)
   nehir added **only logs** — the skip branch still `continue`s, issuing no park plan.
   A Steam window whose `hiddenState` says parked but whose live AX frame is on-screen is
   left on-screen.
2. **The live-AX reconciliation is `reason == .layoutTransient`-only**
   (`resolveHideOperation`, `LayoutRefreshController.swift:2386-2404`, per the #235 doc).
   Even if `resolveHideOperation` were reached for a `.workspaceInactive` window, the gate
   excludes that reason, so a drifted parked window is treated as `.alreadyHidden`.

The result is the report's symptom B verbatim: a window assigned to workspace 2 is partly
or wholly visible behind the tiles of another, active workspace. The dedicated
floating-restore helpers (`restoreWorkspaceInactiveFloatingWindows`,
`hasWorkspaceInactiveFloatingWindows`, `workspaceInactiveFloatingRestoreFrame` at
`LayoutRefreshController.swift:2044-2076`) confirm that floating windows are *intended* to
participate in this hide/restore cycle — and therefore inherit the same failure.

---

## Why this applies / doesn't

**Symptom A — does not apply as a defect (⚪).** nehir classifies non-standard-AX windows
as floating on purpose. Steam trips the same conservative gates any custom-chrome app
trips. nehir has a first-class override path (`.tile` rule / `forceTile`). The reporter's
own experiment proves nehir *sees* Steam (the bundle-id workspace rule worked); the
remaining step is configuring the tile action. There is no nehir bug to fix, and weakening
the heuristic to auto-tile Steam would regress genuine dialogs/panels. nehir's behavior
matches upstream exactly.

**Symptom B — applies, but as a duplicate (🔴 dup).** The cross-workspace leak is real in
nehir and the failure mode is identical whether the window is tiled (the Telegram capture)
or floating (Steam): `hidden != nil` + live AX frame intersecting the active monitor. Steam
is a *floating* instance of the workspace-inactive stale-live-frame family, not a new cause.
The capture already on file — Telegram `windowId=159` live at
`liveAXFrame={{1050.0,0.0},{1006.0,1280.0}}` (x-range `1050..2056`) on active workspace 1
while `hidden=workspaceInactive`, `observedVisible=false` — is the same invariant violation
Steam exhibits. The two repair gaps (skip-already-hidden; `layoutTransient`-only
reconciliation) are shared.

## Relationship to the sibling discoveries

| Aspect | #391 Steam (this doc) | `workspace-inactive-stale-live-frame` (nehir) | `#235` (upstream umbrella) |
| --- | --- | --- | --- |
| Window mode | **floating** | tiled (Telegram) | tiled + scratchpad |
| Hide reason | `.workspaceInactive` | `.workspaceInactive` | `.workspaceInactive` (+ `.layoutTransient` overscroll) |
| Park target | screen edge (`physicalScreenEdgeOrigin`) | screen edge (`x≈2055`) | screen edge |
| Shared invariant | `hidden != nil` + live AX on-screen | same | same |
| Why it sticks | skip-already-hidden; reconciliation `layoutTransient`-only | same | same |
| "Can't tile" half | expected classification (this doc, ⚪) | n/a | n/a |

Steam is the floating column of this family. It adds no new root cause and owns no
separate repo action; the fix work lives under
`20260616-workspace-inactive-stale-live-frame.md` (see its Recommendations) and the
upstream-symptom record `noop/20260616-hiro-235-window-bleed-different-workspace.md`.

## Recommendation

**No new repo action for #391.**

1. **Symptom A — document the user fix, do not change the classifier.** When Steam (or any
   custom-chrome app) must tile, the user sets a rule with layout action **Tile** for
   `com.valvesoftware.steam`, or applies a `forceTile` manual override. The heuristic must
   stay conservative; auto-tiling on bundle id would be a regression risk for other apps.
   (If desired, this is a docs/UX item — e.g. a hint when a user rule sets only a workspace —
   not a code change under `Sources/`.)
2. **Symptom B — implement the workspace-inactive family's fixes; they close Steam's leak
   too.** From `20260616-workspace-inactive-stale-live-frame.md`:
   - In `hideWorkspace` (`LayoutRefreshController.swift:2156-2167`), when
     `hiddenState != nil`, compare the live AX frame to the expected edge origin (the
     comparison `workspaceInactiveVisibleDriftLine` already computes) and, on drift past
     `parkTolerance`, issue the park plan `hideWindow(reason:.workspaceInactive)` would —
     instead of `continue`-ing. This applies to floating windows identically.
   - Generalize the stale-cached live-AX reconciliation in `resolveHideOperation`
     (`LayoutRefreshController.swift:2386-2404`) beyond `reason == .layoutTransient` to
     include `.workspaceInactive` / `.scratchpad`.
   - Do not clear `workspaceInactive` hidden state without writing a frame or activating
     the workspace (the `executeHiddenReveal` `.none` path).

   As with #235, a unit test can prove a park **plan is issued** for a drifted
   already-hidden floating window; whether WindowServer finally renders it hidden is the
   separate, still-open offscreen-clamp problem noted in `docs/offscreen-clamp-fix.md`.

## Suggested tests

(Deferred to the workspace-inactive sibling doc, which owns the action.) The relevant
regression for Steam specifically is the floating variant: build a controller state with
one monitor, workspace 1 active, workspace 2 inactive, and a **floating** window on
workspace 2 whose metadata is `hidden=workspaceInactive` but whose live AX frame
intersects the active monitor. After `hideWorkspace` runs, assert a park plan toward the
screen-edge origin is issued for that window rather than skipped — the floating analogue
of the test `noop/20260616-hiro-235-window-bleed-different-workspace.md` recommends.
