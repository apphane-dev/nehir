# Nehir issue #108 (follow-up) — PiP still bounces back on cross-monitor drag because the drag re-anchor fix is gated on `globalSticky`, not `sticky` — Discovery

**Status:** discovery — open. Follow-up to `completed/20260624-nehir-108-pip-disappears-and-snaps-back-on-workspace-switch.md` (merged `ade7cd07`). The original two symptoms (PiP disappears on workspace switch; PiP snaps back) were the subject of that fix. This doc covers the **residual** symptom the reporter (`dagrlx` / "dagr1x") still hits on the RC builds: a PiP dragged from the external monitor to the MacBook **intermittently bounces back to the external monitor**.

Source issue: https://github.com/apphane-dev/nehir/issues/108
Reporter browser: Vivaldi (YouTube PiP). Two displays, "Displays have separate Spaces" ON.

Source citations verified against `guria/nehir` main at `b50500bb` ("Add experimental Dock Shield for side fixed-Dock setups"). Line numbers drift — re-verify before implementing. Runtime evidence is inlined from the reporter's two RC captures (both 2026-06-28), attached to the issue:

- `runtime-trace-1782606465358-1782606483190.log` — **sticky option enabled** (the bounce reproduces).
- `runtime-trace-1782606676945-1782606719571.log` — "after deleting all rules" (the move **succeeds**).

Below these are called **T1 (sticky/bounce)** and **T2 (norules/success)**.

---

## TL;DR

- **What the user experiences now.** With a browser PiP open, dragging it from the
  external monitor onto the MacBook **snaps it back to the external monitor** — but
  only *sometimes*. The reporter's own words: *"if I create the PIP window and don't
  switch workspaces, when I try to move the PIP to the other monitor, the window
  bounces back … [but if I] switched workspaces on the same monitor, and then moved
  the PIP to the other monitor. It worked; there was no bounce. Then … the bounce
  didn't occur [again]."* Visibility across workspace switches now works (the `ade7cd07`
  fix's Lever 1). The **cross-monitor drag** is what still fails, intermittently.

- **Root cause (source-baked).** The `ade7cd07` fix has an **inconsistent gate**
  between its two levers:
  - **Lever 1 (don't park across workspace switch)** was widened to the broad
    predicate `isStickyWindow(_:)` — `LayoutRefreshController.swift:2456`. This
    covers a PiP made sticky by a **user rule** or **manual sticky**, so it stays
    visible. ✅ (matches the user's "sticky keeps it visible" observation).
  - **Lever 2 (follow the display on a cross-monitor drag, don't re-clamp to the
    workspace's monitor)** was left on the **narrow** predicate
    `isGlobalStickyWindow(_:)` — the "follow last-frame monitor" branches in
    `resolvedFloatingFrame` (`WorkspaceManager.swift:3162`) and
    `updateFloatingGeometry` (`WorkspaceManager.swift:3120`). ❌
  - The reporter's PiP is **`sticky=true globalSticky=false`** in both captures. So
    Lever 1 keeps it visible, but Lever 2's `else` branch resolves
    `targetMonitor = monitor(for: entry.workspaceId)` = the PiP's **bound workspace's
    monitor = the external display**, and re-clamps the frame there. **That is the
    bounce.**

- **Why globalSticky is false.** `globalStickyWindowTokens` is populated only when
  macOS reports the window on *all* known Spaces (`isWindowOnAllKnownSpaces`,
  `knownSpaces > 1`). The reporter's Vivaldi PiP made sticky by a **Nehir rule** is
  not reported by SkyLight as an all-Spaces (`canJoinAllSpaces`) surface, so
  `globalSticky` never latches — only the rule/manual `sticky` flag does.

- **Why it's intermittent (T2 succeeds).** The bounce is decided by a race during the
  cross-display drag: crossing displays crosses a native Space boundary, so the PiP
  surface is **destroyed and re-admitted** mid-drag (`window_removed phase=destroyed`
  → `window_admitted`, windowId reused). On re-admission Nehir re-applies the resolved
  floating frame. If the entry's `workspaceId` has **not** re-anchored to a
  MacBook-display workspace yet, `monitor(for: entry.workspaceId)` is still the
  external monitor → snap-back (T1). If the destroy/re-admit happens to re-anchor the
  entry onto a MacBook-display workspace first, `monitor(for: entry.workspaceId)`
  becomes the MacBook → it sticks (T2). Same code, two outcomes, depending on drag
  timing — exactly the "sometimes bounces" the reporter describes.

- **Verdict:** 🟡 Real residual bug. One-line-conceptually fix: make Lever 2 use the
  same broad sticky predicate as Lever 1 (or, better, make **any** floating window
  follow the display its live frame is actually on during an active drag). Plus close
  the coherence gap so a sticky PiP's `workspaceId` re-anchors deterministically on a
  cross-monitor drag instead of via the destroy/re-admit race.

---

## Topology (identical in both captures)

- `ID(displayId: 2)` "LG FHD" — external, main, `frame=(0,0,1920,1080)`.
- `ID(displayId: 1)` "Built-in Retina Display" — MacBook, `frame=(1866,1080,1440,900)`.
- `displaySpacesMode=enabled`, `SpaceTopology mode=enabled activeSpaces=2 knownSpaces=2`,
  `globalSticky=0 sticky=0 nativeInactive=0` at both captures' start.
- 7 Nehir workspaces. The PiP is **Vivaldi windowId 2369** (`pid 1343`),
  `mode=floating`, `wsLevel=3`, `wsTags=0x100082c01`, `wsFrame ≈ 1152×648`
  (Vivaldi's PiP). Playing "Emergencia en Venezuela … - YouTube".

Note both captures also contain the same tiled Vivaldi main window (windowId 63),
KeePassXC (windowId 35), and Ghostty (windowId 2116) — none relevant here.

---

## The PiP is `sticky` but not `globalSticky` in BOTH captures

Every admission of windowId 2369 logs the same classification:

```text
# T1 (sticky) and T2 (norules) both:
… token=WindowToken(pid: 1343, windowId: 2369) bundleId=com.vivaldi.Vivaldi
  accepted reason=sticky … globalSticky=false sticky=true scratchpad=false
window_decision … windowId: 2369 … disposition=floating
  source=userRule(7365CBF4-…)   # T1
  source=userRule(4E5928BF-…)   # T2  ("deleted rules" still leaves a persisted match)
  outcome=trackedFloating wsTags=0x100082c01
```

`wsTags=0x100082c01` has the **document** bit (0x1) set and **no floating** bit (0x2),
so this is *not* the `transientWindowServerSurface` path — the PiP is floated purely by
a **user/persisted rule**, and its stickiness is the **rule `sticky` effect**, never
the macOS-all-Spaces auto-detect. Hence `globalSticky=false` throughout (99/99 metadata
events in T1, all of T2's pre-cross drag). This is the decisive fact: the reporter's
window is precisely the class Lever 2 does **not** cover.

---

## T1 — the bounce, event by event

The user drags the PiP from external (displayId 2) onto the MacBook (displayId 1). The
floating frames follow the cursor onto the MacBook (`x≈1838→1944, y≈1150→1109,
interaction=ID(displayId: 1)`), **but the entry's bound monitor never follows**:

```text
#349 managed_replacement_metadata_changed token=…2369 monitor=Optional(ID(displayId: 2))
     interaction=ID(displayId: 1)/prev=ID(displayId: 2)   ← window on MacBook, anchor still external
```

Mid-drag, crossing the display/Space boundary tears the surface down and back up:

```text
#377 managed_focus_cancelled …2369
#378 focus_lease_changed owner=window_close_focus_recovery
#379 event=window_removed token=…2369 phase=destroyed          ← PiP surface destroyed mid-drag
#384 event=window_admitted token=…2369 mode=floating           ← re-admitted (windowId reused)
#387 floating_geometry_updated …2369 frame=(1958,1116 …)       ← momentarily still near MacBook
#391 floating_geometry_updated …2369 frame=(768,401 1152×648)  ← BOUNCE: restored on external
#392 floating_geometry_updated …2369 frame=(768,401 …)
… (admit/remove/admit churn repeats, frame stays (768,401) on external)
```

`x=768` is inside the external monitor's `0–1920` range. Across the **entire** T1
capture the entry's monitor is `displayId 2` (99/99 `managed_replacement_metadata_changed`)
and its workspace is `94DC896B` (587/587 events) — **it never re-anchors**. So on every
re-admission `resolvedFloatingFrame` resolves the external monitor and clamps the PiP
back. This is the bounce the reporter sees when he *doesn't* switch workspaces first.

## T2 — the same drag, but it sticks

Same window, same drag onto the MacBook. Here the frames also cross onto displayId 1
(`x≈1916→2048, y≈968→1017`), and again there is a destroy/re-admit:

```text
#1065 event=window_removed token=…2369 phase=destroyed  workspace=5BC07634
#1067 event=window_admitted token=…2369 mode=floating   workspace=94DC896B
#1102 managed_replacement_metadata_changed token=…2369
      monitor=Optional(ID(displayId: 1)) … workspace=7E4A10C7   ← RE-ANCHORED to MacBook workspace
```

Once the entry's `workspaceId` is `7E4A10C7` (a workspace **on the MacBook display**),
`monitor(for: entry.workspaceId)` returns displayId 1, so the `else` branch no longer
pulls the frame back. The PiP settles at `frame=(2036,1227)` on the MacBook and stays
there to the end of the capture. **No bounce.** The only difference from T1 is that the
destroy/re-admit re-anchored the workspace to a MacBook workspace *before* the resolve —
a timing accident, not a deterministic guarantee.

---

## Root cause in source

### The gate mismatch

Park exemption (Lever 1) — **broad** predicate, so a rule-sticky PiP stays visible:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2451-2457
// Lever 1: an effective sticky window must never be parked offscreen when a
// workspace goes inactive …
if controller.workspaceManager.isStickyWindow(entry.token) {
    … continue   // not parked
}
```

Cross-monitor re-anchor (Lever 2) — **narrow** predicate, so a rule-sticky-but-not-
globalSticky PiP falls into the `else` and is clamped to its workspace's monitor:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3158-3169  (resolvedFloatingFrame)
let targetMonitor: Monitor?
if isGlobalStickyWindow(token) {                       // ← NARROW: false for this PiP
    targetMonitor = preferredMonitor
        ?? floatingState.lastFrame.center.monitorApproximation(in: monitors)  // follows display
} else {
    targetMonitor = preferredMonitor
        ?? monitor(for: entry.workspaceId)             // ← external monitor → SNAP BACK
        ?? floatingState.referenceMonitorId.flatMap { monitor(byId: $0) }
}
…
if let targetMonitor,
   floatingState.referenceMonitorId == targetMonitor.id || floatingState.normalizedOrigin == nil {
    return clampedFloatingFrame(floatingState.lastFrame, in: visibleFrame)   // clamps to external
}
```

The identical narrow gate is in the geometry writer:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3115-3120  (updateFloatingGeometry)
let resolvedReferenceMonitor = referenceMonitor
    ?? frame.center.monitorApproximation(in: monitors)
    ?? (isGlobalStickyWindow(token) ? nil : monitor(for: entry.workspaceId))  // ← narrow gate
```

The predicates (`WorkspaceManager.swift:3025-3037`):

```swift
func isGlobalStickyWindow(_ token) -> Bool { globalStickyWindowTokens.contains(token) }      // macOS all-Spaces only
func isStickyWindow(_ token) -> Bool { !isManualUnsticky && hasStickyWindowSource(token) }    // rule OR manual OR global
func hasStickyWindowSource(_ token) -> Bool {
    isGlobalStickyWindow(token) || isManualStickyWindow(token) || entry?.ruleEffects.sticky == true
}
```

So `isStickyWindow` is a strict superset of `isGlobalStickyWindow`. Lever 1 uses the
superset; Lever 2 uses the subset. The reporter's PiP lives in the gap
(`ruleEffects.sticky == true`, `globalSticky == false`) — visible but bounce-prone.

### Why the drag re-anchor of `workspaceId` is not deterministic

`updateFloatingGeometry` is called on every drag tick, but for the `else` (non-global)
path it recomputes `referenceMonitor` from the frame center first
(`frame.center.monitorApproximation`) — so *during* the pointer-driven drag the frame
does follow the cursor. The snap-back is applied by the **re-admission after the surface
is destroyed** (`window_removed phase=destroyed` → `window_admitted`), where the restore
path resolves `resolvedFloatingFrame` against the entry whose `workspaceId` is still the
external workspace. Nothing on the cross-monitor drag path re-anchors a
rule-sticky entry's `workspaceId` to the destination display's workspace; T2 only
re-anchored because the destroy/re-admit happened to re-key it onto `7E4A10C7`.

---

## Fix directions (no implementation in this pass)

1. **Unify the gate (minimal).** Replace `isGlobalStickyWindow(token)` with
   `isStickyWindow(token)` in both `resolvedFloatingFrame` (`WorkspaceManager.swift:3162`)
   and `updateFloatingGeometry` (`:3120`). Then any sticky PiP — rule, manual, or
   auto-global — follows the display its frame is actually on, matching Lever 1. This
   alone kills the reported bounce for the sticky case. Confirm it does not regress a
   sticky-but-intentionally-workspace-pinned window (there is currently no such concept,
   so likely safe).

2. **Better: re-anchor `workspaceId` on cross-monitor drag, deterministically.** When a
   tracked floating window's live frame moves onto a different monitor, re-bind its
   `workspaceId` to the active workspace on that monitor at drag-settle time (not via
   the destroy/re-admit race). This makes `monitor(for: entry.workspaceId)` correct for
   the `else` branch too and keeps the model coherent (see the bleed/drift invariants in
   `completed/20260624-…`'s coherence requirement). This also fixes ordinary (non-sticky)
   floating windows if they can ever be dragged across monitors while their workspace is
   the target monitor's.

3. **Investigate the mid-drag destroy/re-admit churn.** `window_removed phase=destroyed`
   during a cross-display drag (both captures) is what actually re-applies the stored
   frame. Confirm whether this is Vivaldi re-creating the PiP surface on the new Space
   (windowId reused) or Nehir's rescan dropping it transiently
   (`queryAllVisibleWindows` floating-only filter noted in the original discovery). If
   Nehir-side, suppressing the spurious remove would eliminate the restore trigger
   entirely, independent of the gate fix.

4. **Make PiP `globalSticky` when appropriate (orthogonal).** If Nehir's `sticky` rule
   effect actually set `collectionBehavior = .canJoinAllSpaces` on the window (or if the
   all-Spaces detector ran on it), the PiP would latch `globalSticky` and hit Lever 2's
   correct branch today. Worth checking whether the sticky effect is applied to the AX
   window at all, or only tracked internally. This would also help single-display, which
   the original discovery flagged as unsolved by Space-count.

---

## Suggested validation

1. **Rule-sticky PiP drag sticks.** Open a browser PiP on the external monitor, apply a
   `sticky` rule (do **not** rely on globalSticky). Drag to the MacBook. Assert the final
   `floating_geometry_updated` frame has `interaction=ID(displayId: 1)` with `x ≥ 1866`
   and there is **no** subsequent `frame=(…, x<1920, …)` restore — i.e. no bounce, even
   without switching workspaces first.
2. **Repeatability.** Repeat the drag 5× without switching workspaces; assert 0 bounces
   (today T1 shows the bounce specifically in the no-switch case).
3. **Workspace re-anchor is deterministic.** Assert the entry's `workspaceId` becomes a
   MacBook-display workspace on drag-settle regardless of the destroy/re-admit ordering.
4. **Non-sticky floating still clamps to its workspace monitor** (guard against widening
   the exemption too far), if such windows exist.

---

## Relationship to prior docs

- `completed/20260624-nehir-108-pip-disappears-and-snaps-back-on-workspace-switch.md`
  — the parent. Its Lever 1 (park exemption) shipped on the broad `isStickyWindow`; its
  Lever 2 (monitor follow) shipped on the narrow `isGlobalStickyWindow`. This doc is the
  gap between those two predicates, surfaced by a rule-sticky (not global-sticky) PiP.
- `completed/20260626-pip-common-defaults-no-special-mode.md` — the "treat PiP as a
  regular window with sticky default" direction the issue thread converged on; relevant
  to fix direction 4.

## Pointers to the original captures (for completeness)

- T1 (sticky/bounce): https://github.com/user-attachments/files/29426013/runtime-trace-1782606465358-1782606483190.log
- T2 (norules/success): https://github.com/user-attachments/files/29426015/runtime-trace-1782606676945-1782606719571.log
