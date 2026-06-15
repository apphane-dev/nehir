# Viewport jumps on main screen when toggling Ghostty Quick Terminal — Discovery

Discovery (2026-06-15). The user reports that the **viewport position on the main
screen changes with no obvious reason while interacting with the secondary
screen**. The cause: toggling **Ghostty's Quick Terminal** (an *unmanaged*
overlay window) activates the Ghostty app, which Nehir resolves to its *managed*
main window and then **reveals that window's column** — scrolling a workspace
viewport the user never addressed.

**This is not a multi-monitor bug.** The reproduction happened on a two-monitor
setup, but the root path is monitor-count-independent (see [Single-display
manifestations](#single-display-manifestations)). On one display the same code
still runs and still mutates a viewport that the user did not target — it is
just observed differently (a deferred jump on a hidden workspace, or a live
scroll on the visible one). Any fix that only checks "is this off the
interaction monitor?" is a multi-monitor band-aid and leaves the single-display
case broken; the real fix must recognise the unmanaged overlay sibling.

The evidence below is reproduced inline from the runtime trace that first
exposed this; the log itself is machine-local and should not be relied on.

This is the **viewport-reveal** sibling of the already-planned **FFM** fix
(`docs/plans/discovery/20260615-ffm-suppress-over-unmanaged-overlay-windows.md`). Both have
the same root actor (the Quick Terminal's unmanaged overlay) but travel through
different code: FFM via `MouseEventHandler`, this one via
`AXEventHandler.handleAppActivation` → `handleManagedAppActivation` →
`engine.scrollToReveal`. The v0.1.1 fix ("suppressed unintended same-app
activation across workspaces") does not cover this path (see
[Why the v0.1.1 guard misses it](#why-the-v011-guard-misses-it)).

All line numbers reference commit `442e2aa`; re-verify before implementing.

---

## TL;DR

- **Symptom.** While the user is on display 2 (DELL), opening Ghostty's Quick
  Terminal makes the **display 1 viewport scroll** to a different column, with no
  input directed at display 1. In one reproduction the target workspace isn't
  even visible, so the jump surfaces the next time it is shown.
  (Multi-monitor reproduction only; the underlying path reproduces on one display
  too — see [Single-display manifestations](#single-display-manifestations).)
- **Mechanism.** Quick Terminal opens → Ghostty (`pid 897`) becomes frontmost →
  `handleAppActivation(pid: 897)` (`AXEventHandler.swift:1268`) →
  `resolveFocusedAXWindowRef` (`:3771`) returns the **managed main window
  `w2314`** (Ghostty keeps its AX *focused window* on the main terminal, not the
  overlay) → `handleManagedAppActivation` (`:1656`) → `confirmManagedFocus` on
  workspace 1 / display 1 → the reveal block (`:1790`) calls
  `engine.scrollToReveal` (`:1827`) because `isFFM == false` and
  `preserveActiveViewport == false` → `applySessionPatch` (`:1856`) bakes the new
  animating viewport offset into workspace 1's state.
- **Two independent gaps.**
  1. The reveal is computed and written for a workspace whose **monitor is not
     the interaction monitor**, driven by an **external app activation** — no
     user intent toward that workspace.
  2. The viewport state is mutated (`scrollToReveal` + `applySessionPatch`) even
     when `isWorkspaceActive == false`; the `isWorkspaceActive` check at `:1863`
     only gates the *relayout* and `startScrollAnimation`, not the offset write.
     So an inactive workspace silently inherits a wrong, animating target.
- **Why v0.1.1 doesn't catch it.** The only same-app suppression on this path,
  `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
  (`:1233`), fires only when the **currently-focused managed window is the same
  pid** as the activated app. Here the focused app is Helium (`pid 33418`), the
  activated app is Ghostty (`pid 897`) — different apps — so the guard returns
  `false`.
- **Fix.** The real fix is to **detect the unmanaged overlay sibling**: when
  resolving the focused AX window, if the app's topmost on-screen window is an
  unmanaged, non-tracked overlay (not the resolved managed token), treat the
  activation as non-managed and skip the reveal — works on any monitor count.
  Two supporting changes: stop persisting animating viewport targets for
  non-active workspaces (covers single-display case 1); and, as a cheaper
  partial guard for multi-monitor only, skip the reveal when the activation is
  an external/native app switch and the window's monitor ≠ interaction monitor.
  See [Recommendations](#recommendations).

---

## How the bug manifests (reproduction evidence)

Topology across both traces: display 1 (main, Built-in) and display 2 (DELL).
Ghostty (`pid 897`) owns **two** windows: the managed main terminal `w2314`
(workspace 1, display 1) and the **unmanaged** Quick Terminal `windowId=101`
(visible in "Visible Unmanaged WindowServer Windows", `activationPolicy=regular`,
floating layer — see the FFM plan for its `CGWindowLayer` values).

### Reproduction A — deferred jump on an inactive workspace

At capture start the user is on display 2:

```log
interactionWorkspace=BDC7449B-… (workspace 6, display 2)
interactionMonitor=ID(displayId: 2)
observedManagedFocus=WindowToken(pid: 33418, windowId: 1692)   // Helium
```

Workspace 1 (display 1) viewport is parked showing the right-hand columns:
`currentViewStart=3186.1` (columns 2/3 — VSCode). It is **not** the active
currently the active workspace on its monitor (workspace 2 / Telegram is visible on
display 1): `workspace=1 … visible=false`.

Event log when the Quick Terminal is toggled:

```log
#3 managed_focus_confirmed token=WindowToken(pid: 897, windowId: 2314)
   workspace=86AD…(ws 1) monitor=Optional(displayId: 1)   ← Ghostty confirmed on display 1
```

Viewport trace for workspace 1:

```log
ax_focus_confirm_before_activate token=w2314 isFFM=false preserveActiveViewport=false
   isGesture=false wasAnimating=false … currentViewStart=3186.1 targetViewStart=3186.1
ax_focus_confirm_reveal_candidate token=w2314 columnIndex=1
   visibility=clipped(minimum) viewStart=3186.1            ← Ghostty's column is off-screen left
ax_focus_confirm_reveal_result token=w2314 columnIndex=1 isFFM=false didReveal=true   ← reveal fired
ax_focus_confirm_skip_relayout token=w2314 isWorkspaceActive=false isFFM=false
   isAnimating=true currentViewStart=3185.3 targetViewStart=1259.5   ← viewport retargeted!
```

`3186.1 → 1259.5`: workspace 1's viewport offset is retargeted to scroll **left**
and bring the Ghostty column into view. `didReveal=true`, `isAnimating=true`,
yet `isWorkspaceActive=false`. Because the workspace is not active,
`startScrollAnimation` is skipped (`:1863`), but the **animating target is
already persisted** via `applySessionPatch` (`:1856`). The next time workspace 1
becomes visible it will snap/scroll to that wrong target.

### Reproduction B — live jump on the visible workspace

Here workspace 1 **is** the active/visible workspace on display 1, so the same
path produces a viewport that animates live on screen while the user is on
display 2:

```log
focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication   ← app switch
…
ax_focus_confirm_* token=WindowToken(pid: 897, windowId: 2314) workspace=1 …
   preserveActiveViewport=true isGesture=false wasAnimating=true
   currentOffset=-362.9 targetOffset=-362.9
```

(The `preserveActiveViewport=true` here is incidental — workspace 1 happened to
still be mid-animation from the prior gesture; the reveal path still runs and
re-anchors the animation to the Ghostty column.) The trigger is explicitly
`source=.workspaceDidActivateApplication`, i.e. macOS telling Nehir "Ghostty got
activated", not a Nehir-issued focus command.

---

## Root cause (with citations)

### 1. App activation resolves to the managed sibling, not the overlay

`AXEventHandler.swift:1268` `handleAppActivation(pid:)`:

```swift
let axRef = resolveFocusedAXWindowRef(pid: pid)            // :3771
…
if let entry = controller.workspaceManager.entry(for: token) { … // entry = w2314 on ws 1
```

`resolveFocusedAXWindowRef` reads the app's AX `focused window` attribute. The
Quick Terminal overlay is **not** reported as the AX-focused window — Ghostty
keeps that pointing at the main terminal (`w2314`). So the activation is
attributed to the managed window on display 1, not the overlay the user actually
opened on display 2. (Contrast: the `getpid()` branch at `:1305` correctly
enters non-managed focus for Nehir's own overlay UI; an unmanaged *app-owned*
overlay has no equivalent branch.)

### 2. The same-app suppression does not apply

`AXEventHandler.swift:1233` `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`:

```swift
guard !isWorkspaceActive else { return false }
guard let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
      focusedToken != observedEntry.token,
      focusedToken.pid == observedEntry.pid,        // ← requires SAME pid
      …
else { return false }
return true
```

This is the v0.1.1 "unintended same-app activation across workspaces" guard. It
suppresses only when the **frontmost managed window is the same app** as the one
being activated (e.g. two Ghostty tiles on two workspaces). In the reported
scenario the focused app is Helium (`pid 33418`), the activated app is Ghostty
(`pid 897`) — `33418 != 897` — so the guard returns `false` and the activation
proceeds. There is no guard for "*the activation originated from an unmanaged
sibling window*" or "*the resolved window is on a monitor the user is not
interacting with*".

### 3. The reveal mutates viewport state with no interaction-monitor / intent check

`AXEventHandler.swift:1656` `handleManagedAppActivation`, reveal block:

```swift
let monitorId = controller.workspaceManager.monitorId(for: wsId)   // :1677  (ws 1 → display 1)
…
let preserveActiveViewport = state.viewOffsetPixels.isGesture
    || state.viewOffsetPixels.isAnimating                            // :1754
…
if !isFFM, !preserveActiveViewport, let column = …, let columnIndex = …, let monitor = … {
    …
    let didReveal = engine.scrollToReveal(                          // :1827
        columnIndex: columnIndex, isFFM: isFFM, state: &state, …
    )                                                               // re-anchors viewport to the column
}                                                                   // NO interaction-monitor check
…
_ = controller.workspaceManager.applySessionPatch(                  // :1856  bakes it in UNCONDITIONALLY
    .init(workspaceId: wsId, viewportState: state, …)
)
if isWorkspaceActive, !isFFM {                                      // :1863  gates ONLY relayout + animation start
    controller.layoutRefreshController.requestRefresh(reason: .layoutCommand)
    if state.viewOffsetPixels.isAnimating {
        controller.layoutRefreshController.startScrollAnimation(for: wsId)
    }
}
```

Two facts combine into the bug:

- **No intent check before `scrollToReveal`.** Nothing compares `monitorId`
  (where the revealed window lives) against `workspaceManager.interactionMonitorId`
  (where the user actually is), nor asks whether the activation was a deliberate
  Nehir focus command vs. an external/native app switch (`source ==
  .workspaceDidActivateApplication`, lease owner `.nativeAppSwitch`).
- **`applySessionPatch` runs regardless of `isWorkspaceActive`.** The
  `isWorkspaceActive` gate at `:1863` protects only the *relayout* and
  `startScrollAnimation`. The viewport offset/target write at `:1827`/`:1856`
  happens first, so a non-active workspace still inherits a wrong, animating
  target — which is what reproduction A shows (`isWorkspaceActive=false`,
  `isAnimating=true`, `targetViewStart=1259.5`).

Net effect: an external app activation that resolves to a managed window on a
non-interaction monitor is treated as a deliberate focus of that window, and its
column is revealed on a workspace the user never addressed.

---

## Why the v0.1.1 guard misses it

The v0.1.1 changelog item reads:

> Fixed focus recovery after closing windows and **suppressed unintended
> same-app activation across workspaces**.

That fix lives in `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
(`:1233`) and is keyed on **same `pid`**: it stops "app X's window on workspace A
steals activation from app X's window on workspace B". The reported case is
structurally different:

| | v0.1.1 case | Reported case |
|---|---|---|
| Focused app | Ghostty (`897`) | Helium (`33418`) |
| Activated app | Ghostty (`897`) | Ghostty (`897`) |
| Same pid? | **yes** → suppressed | **no** → not suppressed |
| Origin | managed window on another ws | **unmanaged overlay** (Quick Terminal) on another monitor |
| Damage | focus stolen | **viewport scrolled** on a 3rd workspace |

The guard's predicate cannot express "the activation came from an unmanaged
sibling window" or "the resolved managed window is off the interaction monitor".
Both are new conditions this discovery asks to encode.

---

## Single-display manifestations

The reproduction above uses two monitors, but **the bug is not
monitor-count-specific**. Everything up to `scrollToReveal` depends only on
*which window the AX focused-window attribute points at*, which is an app
quirk (Ghostty keeps it on the main terminal, not the overlay), not a topology
quirk. On a single display the same path still runs and still mutates a
viewport the user did not target. What changes is only how it is observed:

1. **Ghostty's main window is on a non-visible workspace** (`isWorkspaceActive
   = false`). The reveal still runs and `applySessionPatch` (`:1856`) still
   persists an animating viewport target onto that hidden workspace (the offset
   write is not gated on `isWorkspaceActive`). The user sees nothing live, but
   the next time they switch to that workspace it jumps/scrolls to the Ghostty
   column instead of staying where they left it. **Same bug, deferred.**
2. **Ghostty's main window is on the visible workspace, but its column is
   scrolled off-screen.** The viewport scrolls live to bring the Ghostty column
   into view. The user opened the *overlay*, not the main window, so this scroll
   is still unintended — but it is the harder-to-notice variant because the
   workspace was already visible.
3. **Ghostty's column is already in view.** `scrollToReveal` is a no-op; no
   observable effect (the bug is latent).

This is decisive for the fix choice below. An **interaction-monitor** check
(`monitorId != interactionMonitorId`) is a no-op on a single display — the
window's monitor always equals the interaction monitor — so it cannot address
cases 1 or 2. Only the **unmanaged-overlay-sibling detection** (and, for case 1,
the "don't persist animating targets for non-active workspaces" guard) covers
the single-display scenarios.

---

## Recommendations

### Primary fix: detect the unmanaged overlay sibling (works on any monitor count)

The semantically correct fix is to recognise that the activation's *real* key
window is an unmanaged overlay (the Quick Terminal). When `handleAppActivation`
resolves the focused AX window, cross-check the app's **topmost on-screen
CGWindowList entry for that pid**: if it is an unmanaged, non-tracked,
non-desktop window at a positive layer that is **not** the resolved managed
token, treat the activation as non-managed (enter non-managed focus, do not
reveal) — analogous to the `getpid()` branch at `:1305`. This:

- closes the viewport bug for *all* overlay-bearing apps, on **both single- and
  multi-monitor** setups (the interaction-monitor heuristic cannot);
- is the same detection the FFM plan needs (`unmanagedWindowServerWindowCovers`
  broadened to `layer >= 0`), so the two plans share one source of truth for
  "is there an unmanaged overlay for this pid/window";
- removes the reliance on Ghostty's AX-focused-window quirk.

### Multi-monitor band-aid (cheap, partial): interaction-monitor + intent guard

If the primary fix is not landed first, a narrower guard in
`handleManagedAppActivation` wraps the reveal block (`:1790`) so that
`scrollToReveal` is **skipped** when the activation is an external/native app
switch and the revealed window's monitor is not the interaction monitor:

```swift
let isExternalActivation = source == .workspaceDidActivateApplication   // and/or lease .nativeAppSwitch
let isOffInteractionMonitor = monitorId.map { $0 != (controller.workspaceManager.interactionMonitorId ?? $0) } ?? false

if !isFFM, !preserveActiveViewport, !(isExternalActivation && isOffInteractionMonitor),
   let column = …, let columnIndex = …, let monitor = … {
    … scrollToReveal …
}
```

A deliberate Nehir focus command (hotkey, click-to-focus, FFM) still reveals
normally — those originate *on* the interaction monitor or are explicit
requests. Only background app activations that resolve to a managed window on a
different monitor are suppressed. **Caveat: this guard is a no-op on a
single-display setup** (the window's monitor always equals the interaction
monitor), so it addresses only the multi-monitor reproduction and does not
replace the primary fix — see [Single-display manifestations](#single-display-manifestations).

### Defense-in-depth: don't persist animating targets for non-active workspaces

Independent of which reveal fix is chosen, stop letting `applySessionPatch`
(`:1856`) bake an animating target into a non-active workspace. Either move the
`scrollToReveal`/offset write behind `isWorkspaceActive`, or at minimum clear
`isAnimating`/snap `current == target` when `!isWorkspaceActive` before
`applySessionPatch`. Today the `ax_focus_confirm_skip_relayout` path leaves
`isAnimating=true` and a changed `targetViewStart` in the persisted state, which
is a latent footgun for *any* future reveal on an inactive workspace, not just
this bug — including single-display case 1 above.

### Tests to add

In `Tests/NehirTests/` (mirror the existing same-app-suppression tests for the
new conditions):

- **Cross-monitor activation does not retarget viewport.** Two monitors; focused
  app = app A on display 2; activate app B (`source =
  .workspaceDidActivateApplication`) which owns a managed window on display 1
  whose column is off-screen. Assert display 1's viewport offset/target is
  unchanged and `didReveal == false`.
- **Non-active workspace reveal does not persist animating target.** Same setup
  but the target workspace is not the active one on its monitor; assert the
  patched viewport state has `isAnimating == false` and unchanged offsets.
- **Deliberate focus still reveals.** Focus the same off-screen column via a
  Nehir focus command (hotkey/click) on the interaction monitor; assert
  `didReveal == true` and the viewport retargets (guards the primary fix against
  over-suppression).
- (Follow-up) **Unmanaged overlay sibling → non-managed activation.** Synthetic
  CGWindowList snapshot with a positive-layer, non-tracked, ≥80px entry for the
  pid on top; assert the activation is treated as non-managed and no managed
  focus/reveal occurs.

## Files touched

- `Sources/Nehir/Core/Controller/AXEventHandler.swift` — add the
  interaction-monitor + intent guard in `handleManagedAppActivation` (`:1790`);
  narrow the non-active-workspace viewport write (`:1856`); (follow-up) unmanaged
  sibling detection in `handleAppActivation` (`:1268`).
- `Tests/NehirTests/` — cross-monitor reveal suppression test, non-active
  workspace no-animating-target test, deliberate-focus-still-reveals regression,
  (follow-up) overlay-sibling test.
- `.changeset/<timestamp>-fixed-viewport-jump-on-quick-terminal-activation.md` —
  `patch`, user-visible summary.

## Relationship to the FFM plan

Same actor (Ghostty Quick Terminal), two symptoms, two code paths:

| Plan | Path | Symptom | Guard location |
|---|---|---|---|
| `20260615-ffm-suppress-over-unmanaged-overlay-windows` | `MouseEventHandler` FFM | focus stolen *behind* the overlay | `WMController.unmanagedWindowServerWindowCovers` (`layer >= 0`) |
| this discovery | `AXEventHandler` app-activation → reveal | **viewport scrolls** on a non-interaction workspace | `handleManagedAppActivation` reveal block |

The follow-up "detect the unmanaged sibling" is the natural merge point: one
predicate ("is the app's real key window an unmanaged overlay?") feeds both the
FFM occlusion check and the app-activation classification, so the two fixes
should be coordinated rather than landed with divergent heuristics.
