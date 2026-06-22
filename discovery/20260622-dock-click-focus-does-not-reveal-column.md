# Clicking a Dock icon to focus a tiled window does not scroll the viewport to its column — Discovery

Discovery (2026-06-22). When the user switches focus by **clicking a Dock icon**
for an app whose managed window is tiled in an off-screen column, the workspace
**viewport does not scroll** to bring that column into view. The Dock activation
is delivered as a `workspaceDidActivateApplication` event, which Nehir classifies
as a `native_app_switch` while Nehir is already/still in **non-managed focus**
(in the captured sequence, re-entered by a Ghostty overlay fallback just before
the Dock clicks). A guard that was written to stop an *unmanaged overlay*
(Ghostty Quick Terminal) from dragging the managed-focus anchor around then uses
that bare `isNonManagedFocusActive` flag to silently drop the Dock activation
*before* the managed-focus confirmation / `scrollToReveal` path runs — so the
newly activated window's column is never revealed.

This is the **inverse** of `discovery/20260615-viewport-reveal-from-unmanaged-overlay-activation.md`:
that doc is about an *unwanted* reveal fired by an overlay sibling; this one is
about a *wanted* reveal that is suppressed for ordinary Dock-driven app
switches. Both live in the same function (`handleAppActivation` →
`handleManagedAppActivation`), on opposite sides of the same guard.

All code citations were verified against the main Nehir source tree at
`aff8a9a2` on 2026-06-22 (`git log -1 --format='%h %s'` → `aff8a9a2 Keep
transient popup surfaces out of managed activation`). Line numbers will drift.

---

## TL;DR

- **Symptom.** One display, one visible workspace with 7 columns. The viewport
  is parked on the rightmost column (Finder). The user clicks Dock icons for
  VSCode / Telegram / Helium — apps tiled in columns further left — and the
  viewport **never moves**. The app is activated by macOS, but Nehir's managed
  focus anchor stays on Finder and the viewport offset is unchanged.
- **Evidence shape.** The capture's `## Niri viewport trace` section is
  literally `viewport trace empty`; the per-workspace counter is
  `viewportTraceRecords=0` at both start and end. Every Dock-click activation
  emits only `activation_source_observed pid=… source=workspaceDidActivateApplication`
  and then nothing — no `focus_confirmed`, no `create_placement_resolved`, no
  reveal trace, no relayout.
- **Mechanism.** `handleAppActivation` (`AXEventHandler.swift:1795`) begins a
  `.nativeAppSwitch` lease for every external `workspaceDidActivateApplication`
  (`:1840-1846`). In this capture the session is also already/still in
  `isNonManagedFocusActive == true` (re-entered by a Ghostty
  `non_managed_fallback_entered` just before the Dock-click sequence). When a
  Dock activation resolves to a managed window,
  `shouldSuppressManagedActivationWhileNonManagedFocusAnchored` (`:1624`) fires
  — its `overlayFocusIsActive` predicate is just
  `controller.workspaceManager.isNonManagedFocusActive || hasVisibleSamePidOverlayWindow(…)`
  (`:1639-1640`), so the bare sticky non-managed-focus state (with no overlay
  for the activated app present at all) is enough to suppress. The call site
  returns silently (`:1898`, also `:1996` and `:2212`), so
  `handleManagedAppActivation` (`:2275`) and its `engine.scrollToReveal`
  (`:2459`) are never reached.
- **Why the guard over-fires.** The guard's own comment says it exists for
  "an unmanaged overlay (for example Ghostty Quick Terminal) [that] owns native
  focus" (`:1643-1647`). But the predicate does not actually require an overlay
  for the *activated app* to be present — `isNonManagedFocusActive` alone
  satisfies it. Once any fallback/overlay leaves that flag true, ordinary Dock /
  Cmd-Tab activations are conflated with overlay ownership and get suppressed.
- **Fix direction.** Either (a) let a Dock click that resolves to a *managed*
  window bypass stale non-managed overlay-anchor suppression so it runs the
  normal confirm + reveal path; or (b) narrow
  `shouldSuppressManagedActivationWhileNonManagedFocusAnchored` so the
  `isNonManagedFocusActive` term only counts when there is a *genuine* overlay
  (same-pid or a real key-window overlay), not merely stale non-managed state.
  See [Recommendations](#recommendations).

---

## Topology and initial state (inlined from the capture)

Single display, single visible workspace, 7 columns:

```
-- Monitor Topology --
ID(displayId: 1) isMain=true hasNotch=true frame=(0.0, 0.0, 2056.0, 1329.0) visibleFrame=(0.0, 87.0, 2056.0, 1203.0) name=Built-in Retina Display
```

```
-- Niri Viewports --
workspace=1 id=BC987D40-0233-4C3D-93F6-22BE72A9F6BB visible=true columns=7 activeColumnIndex=6
  currentOffset=949.6 targetOffset=949.6 currentViewStart=8874.4 targetViewStart=8874.4
  gesture=false animating=false selectedNode=NodeId(uuid: B07F8B6B-…) preferredFocus=WindowToken(pid: 23441, windowId: 4715)
```

So the viewport is settled on column index 6 (the rightmost column), whose window
is Finder `w4715` (`pid 23441`). `currentViewStart=8874.4 == targetViewStart=8874.4`,
`animating=false` — nothing is in flight.

Column → window map for workspace 1 (from `-- Niri Layout Decisions --`):

| column | x (layout) | window | pid | app |
|--------|-----------|--------|-----|-----|
| c0 | 0.0    | w4505 | 51140 | Slack |
| c1 | 1016.0 | w4558 | 57195 | Helium |
| c2 | 2946.4 | w2984 | 29271 | Telegram |
| c3 | 3962.4 | w4528 | 6731  | WhatsApp |
| c4 | 4978.4 | w537  | 57195 | Helium |
| c5 | 5994.4 | w4635 | 23546 | VS Code |
| c6 | 7924.8 | w4715 | 23441 | Finder (**selected**) |

Every column except c6 is off-screen left of the current viewport. Clicking the
Dock for any of Slack / Helium / Telegram / WhatsApp / VS Code should scroll the
viewport left to reveal that app's column.

Focus / interaction state at capture start:

```
-- Focus Targets --
interactionWorkspace=BC987D40-… wmCommandTarget=WindowToken(pid: 23441, windowId: 4715)
  wmCommandTargetSource=layoutSelection layoutSelection=WindowToken(pid: 23441, windowId: 4715)
  observedManagedFocus=WindowToken(pid: 23441, windowId: 4715) interactionMonitor=ID(displayId: 1) nonManaged=true
-- WorkspaceManager --
interaction current=ID(displayId: 1) previous=nil nonManaged=true appFullscreen=false lease=true
focus focused=23441:4715 pending=nil scratchpad=nil
-- Reconcile Snapshot --
focus-lease=native_app_switch
non-managed-focus=true
```

Two facts to hold onto: `nonManaged=true` / `non-managed-focus=true` for the
**entire** capture (also true at end-of-capture), and `focus-lease=native_app_switch`.

---

## What the user did, and what the trace shows

The user clicked Dock icons repeatedly for VS Code (`pid 23546`), Helium
(`pid 57195`) and Telegram (`pid 29271`). The create-focus trace for those
activations is — in full:

```
activation_source_observed pid=23546 source=workspaceDidActivateApplication
activation_source_observed pid=57195 source=workspaceDidActivateApplication
activation_source_observed pid=23546 source=workspaceDidActivateApplication
activation_source_observed pid=57195 source=workspaceDidActivateApplication
activation_source_observed pid=29271 source=workspaceDidActivateApplication
activation_source_observed pid=57195 source=workspaceDidActivateApplication
activation_source_observed pid=23546 source=workspaceDidActivateApplication
activation_source_observed pid=57195 source=workspaceDidActivateApplication
activation_source_observed pid=29271 source=workspaceDidActivateApplication
```

Each Dock click produces exactly one trace line and nothing else — no
`focus_confirmed`, no `create_placement_resolved`, no `relayout_activated_window`,
no viewport trace entry. For comparison, the *one* managed window that did get
confirmed in this capture was Finder `w4715` — and it produced the full chain:

```
activation_source_observed pid=23441 source=workspaceDidActivateApplication
non_managed_fallback_entered pid=23441 source=workspaceDidActivateApplication
create_seen window=4715
create_placement_resolved token=WindowToken(pid: 23441, windowId: 4715) …
candidate_tracked token=WindowToken(pid: 23441, windowId: 4715) …
relayout_activated_window token=WindowToken(pid: 23441, windowId: 4715) …
pending_focus_started request=49 token=WindowToken(pid: 23441, windowId: 4715) …
focus_confirmed token=WindowToken(pid: 23441, windowId: 4715) source=focusedWindowChanged
```

But Finder lives in column c6, which is *already* the viewport's anchor column,
so even its confirm could not move the viewport. The off-screen apps never got
that far. (The Finder churn — demoted to non-managed fallback then re-admitted —
is a separate window-rule flap, not the subject of this doc; the relevant point
is only that a confirmation chain *exists* and is reachable, but is not reached
for the Dock-clicked off-screen apps.)

Immediately before the repeated Dock activations, Ghostty's Quick Terminal path
re-enters non-managed focus:

```log
activation_source_observed pid=20314 source=focusedWindowChanged
window_decision token=WindowToken(pid: 20314, windowId: 328) context=focused_admission … source=builtInRule(ghosttyQuickTerminalOverlay) outcome=ignored …
prepare_create_rejected window=328 … reason=untracked_decision …
non_managed_fallback_entered pid=20314 source=focusedWindowChanged
```

After that, the lease churn confirms each Dock click is arriving as a native app
switch and re-arming the lease:

```
#1 event=focus_lease_changed owner=nil reason= … focus_lease=cleared
#2 event=focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication … lease=native_app_switch
#3 event=focus_lease_changed owner=nil … focus_lease=cleared
#4 event=focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication … lease=native_app_switch
   (… repeats for each click …)
```

And the decisive negative evidence — the viewport trace section, in full:

```
## Niri viewport trace
viewport trace empty
```

with the end-of-capture runtime counter still `viewportTraceRecords=0`. No
reveal candidate, no reveal result, no skip — the reveal block in
`handleManagedAppActivation` was simply never entered for any Dock-clicked app.

---

## Root cause (with citations)

### 1. A Dock click is classified as a native app switch while non-managed focus remains latched

`AXEventHandler.swift:1795` `handleAppActivation(pid:source:origin:)`. After
recording `activationSourceObserved`, it begins a `.nativeAppSwitch` lease for
any external `workspaceDidActivateApplication` that is not a focused-window
change and not Nehir's own pending managed request:

```swift
// AXEventHandler.swift:1838-1846
if source != .focusedWindowChanged, !isActivationForManagedRequest {
    controller.focusPolicyEngine.beginLease(
        owner: .nativeAppSwitch,
        reason: source.rawValue,
        suppressesFocusFollowsMouse: true,
        duration: 0.4
    )
}
```

The non-managed-focus state itself (`isNonManagedFocusActive`) is set true by
`enterNonManagedFocus` (`WorkspaceManager.swift:1836`), which reduces through
`StateReducer.nonManagedFocusChanged` to `focusSession.isNonManagedFocusActive = active`
(`StateReducer.swift:356-364`). Once any overlay or fallback path has entered
non-managed focus, the flag stays true until a *managed* focus is confirmed
(`StateReducer.managedFocusConfirmed` sets it back to false,
`StateReducer.swift:326-333`). In this capture it is true at the start, is
re-entered by the Ghostty overlay fallback above, and is still true at the end —
there is no managed confirmation for the Dock-clicked off-screen apps to clear it.

### 2. The overlay guard suppresses the managed activation using that flag alone

`AXEventHandler.swift:1624` `shouldSuppressManagedActivationWhileNonManagedFocusAnchored`:

```swift
// AXEventHandler.swift:1624-1652
private func shouldSuppressManagedActivationWhileNonManagedFocusAnchored(
    entry observedEntry: WindowModel.Entry,
    requestDisposition: ActivationRequestDisposition
) -> Bool {
    guard case .unrelatedNoRequest = requestDisposition,
          let controller,
          let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
          focusedToken != observedEntry.token,
          let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
          let focusedMonitorId = controller.workspaceManager.monitorId(for: focusedEntry.workspaceId),
          controller.workspaceManager.activeWorkspace(on: focusedMonitorId)?.id == focusedEntry.workspaceId
    else { return false }

    let overlayFocusIsActive = controller.workspaceManager.isNonManagedFocusActive
        || hasVisibleSamePidOverlayWindow(for: observedEntry)
    guard overlayFocusIsActive else { return false }

    // While an unmanaged overlay (for example Ghostty Quick Terminal) owns
    // native focus, macOS may report the app's regular managed window as the
    // focused AX window. The overlay should not move Nehir's managed
    // interaction/focus anchor away from the window the user was using before
    // the overlay appeared, even when both windows are on the same workspace.
    return true
}
```

For a Dock click on VS Code (`pid 23546`, `w4635`) every guard clause is
satisfied:

- `requestDisposition == .unrelatedNoRequest` — there is no pending Nehir focus
  request for a Dock click (✓);
- `confirmedManagedFocusToken` is Finder `w4715` (`pid 23441`), which is
  `!=` the observed VS Code token `w4635` (✓);
- Finder is on workspace 1, which is the active workspace on display 1 (✓);
- `overlayFocusIsActive` is true **purely from `isNonManagedFocusActive`** —
  `hasVisibleSamePidOverlayWindow(for: VSCode_entry)` is false here (no VS Code
  overlay exists), but the `||` short-circuits on the first term. **No overlay is
  actually present.**

So the function returns `true` and the call site returns silently:

```swift
// AXEventHandler.swift:1893-1900  (inside the `if let entry = …` branch of handleAppActivation)
if shouldSuppressManagedActivationWhileNonManagedFocusAnchored(
    entry: entry,
    requestDisposition: requestDisposition
) {
    return
}
```

(The same guard is applied at two further, structurally identical call sites —
`:1996` for the restored-native-fullscreen branch and `:2212` for the
freshly-tracked-window branch — so the suppression is uniform across how the
entry was found.)

### 3. The reveal that never runs

Because of the silent return above, `handleManagedAppActivation` (`:2275`) is
never called for the Dock-clicked window. That is the only place on this path
that computes and writes a viewport reveal:

```swift
// AXEventHandler.swift:2455-2473  (inside handleManagedAppActivation)
let didReveal = engine.scrollToReveal(
    columnIndex: columnIndex,
    isFFM: isFFM,
    state: &state,
    context: context,
    motion: controller.motionPolicy.snapshot(),
    scale: engine.displayScale(in: wsId)
)
```

This is the exact `scrollToReveal` call analyzed in the inverse-sibling discovery
(`20260615-viewport-reveal-from-unmanaged-overlay-activation.md`). There the
problem was that it *does* fire (for an overlay sibling) and scrolls a viewport
the user did not address; here the problem is that it *never* fires for a
deliberate Dock focus. Same reveal block, opposite failure mode, same root actor
(`shouldSuppressManagedActivationWhileNonManagedFocusAnchored` on one side,
nothing guarding it on the other).

### Why the other guards are not the cause

By elimination, for a Dock click on an already-tracked, on-active-workspace,
managed window the other early-return guards in `handleAppActivation` do not
fire:

- `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
  (`:1734`) begins with `guard !isWorkspaceActive else { return false }`. The
  workspace **is** active, so it returns `false`. (Its same-`pid` branch also
  does not apply: the focused pid `23441` ≠ the activated pid `23546`.)
- `shouldDeferInactiveNativeActivationBeforeCloseRecovery` (`:1709`) also
  requires `!isWorkspaceActive` → returns `false`.
- `shouldSuppressObservedActivationDuringWindowCloseRecovery` (`:1583`) requires
  an active `windowCloseFocusRecoveryContext`, which is absent here.

Only `shouldSuppressManagedActivationWhileNonManagedFocusAnchored` can return
`true` for this shape, and its `isNonManagedFocusActive` term is the one that
matches the capture's persistent `nonManaged=true`.

---

## The conflation, stated plainly

The guard's *intent* (per its comment) is: "an unmanaged overlay owns native
focus; do not let macOS re-pointing the AX focused window at the overlay's
managed sibling move our anchor." Its *implementation* is: "non-managed focus
is active, full stop." Those are only equivalent when non-managed focus was
entered *because of an overlay*. But `isNonManagedFocusActive` is also true for non-overlay residual states,
including:

- the residual state left by a quick-terminal toggle or fallback, even after the
  overlay closes, until a managed focus is confirmed (this capture);
- a Dock / Cmd-Tab native-switch sequence that arrives while that residual state
  is still true;
- any Nehir-internal `enterNonManagedFocus` call (e.g. the getpid/owned-UI
  branch at `AXEventHandler.swift:1822`, workspace navigation at
  `WorkspaceNavigationHandler.swift:165`).

For a Dock click whose resolved window is a genuine tracked managed window on
the active workspace, the user's intent is unambiguous: they asked for that
window. Treating that as "overlay is anchoring focus, do not move" is the bug.

A secondary aggravator is stickiness. `isNonManagedFocusActive` only clears on a
*managed* confirmation (`StateReducer.swift:326-333`). Because the guard
prevents exactly that confirmation, the state is self-sustaining: once a session
enters non-managed focus for any reason, every subsequent Dock click to a
different managed window re-confirms the decision not to reveal. The capture
shows this loop running indefinitely (`nonManaged=true` at start *and* end,
lease flapping `cleared`↔`native_app_switch` per click).

---

## Recommendations

### Primary fix: do not let sticky non-managed state suppress a Dock/Cmd-Tab switch to a *managed* window

The cleanest fix is upstream of the guard. A `workspaceDidActivateApplication`
that resolves (via `resolveFocusedAXWindowRef`) to a **tracked managed window on
the active workspace** is a real user focus change to that window, not an
overlay event. It should run the normal managed-confirmation path — which
already ends in `scrollToReveal` (`:2459`) and in
`focusSession.isNonManagedFocusActive = false` (`StateReducer.swift:326-333`), so
both the reveal and the stickiness are fixed in one move.

Concretely, in `handleAppActivation`, after the entry is resolved and *before*
the suppression guards, either:

- classify this resolved-to-managed external activation as allowed to bypass the
  overlay-anchor suppression, even if a `.nativeAppSwitch` lease is active; or
- pass an explicit "resolved-to-managed" signal into
  `shouldSuppressManagedActivationWhileNonManagedFocusAnchored` so it does not
  treat the activation as overlay-anchored unless an overlay is actually present.

Either way, the existing overlay suppression must still fire when the resolved
window is *not* the real key window (i.e. an overlay is actually on top) — which
is what the sibling discovery needs.

### Narrower fix: make `overlayFocusIsActive` actually require an overlay

If the primary fix is too invasive, tighten the predicate at `:1639-1640` so the
`isNonManagedFocusActive` term only counts when an overlay is genuinely present,
i.e. drop the bare-lease term and rely on `hasVisibleSamePidOverlayWindow(…)`
plus an explicit "key window is an unmanaged overlay" check (the same detection
the sibling FFM/reveal plans already call for). Something like:

```swift
let overlayFocusIsActive = hasVisibleSamePidOverlayWindow(for: observedEntry)
    || isResolvedKeyWindowAnUnmanagedOverlay(for: observedEntry)
```

Caveat: this relies on the overlay-detection predicate being complete; if it
misses a class of overlays, the original Quick-Terminal regression
(`20260615-viewport-reveal-from-unmanaged-overlay-activation.md`) re-opens. The
primary fix is preferred because it makes the decision on whether the resolved
window is managed, which is the property the user actually cares about.

### Defense-in-depth: stop the non-managed state from being self-sustaining

Independent of the above, the loop where `isNonManagedFocusActive` stays true
because the guard blocks the only thing that clears it is a latent footgun. At
minimum, a `workspaceDidActivateApplication` that resolves to a managed entry on
the active workspace should clear `isNonManagedFocusActive` (or confirm managed
focus) even if some other policy decides not to reveal — so the next interaction
starts from a correct anchor.

### Tests to add

In `Tests/NehirTests/`:

- **Dock click on an off-screen managed column reveals it.** One workspace,
  multiple columns, viewport parked on the rightmost column. Synthesize
  `handleAppActivation(pid:, source: .workspaceDidActivateApplication, origin:
  .external)` for a tracked managed window in a left column. Assert
  `focus_confirmed` for that token, `didReveal == true`, and the viewport
  target/offset retargets to that column.
- **Overlay sibling still suppresses (regression guard for the sibling fix).**
  Same setup but with a same-pid unmanaged overlay on top; assert the activation
  is treated as non-managed, no `focus_confirmed`, no reveal.
- **Cmd-Tab to a managed window reveals (parity with Dock).** Same as the Dock
  test with `source` reflecting a native app switch, to lock in that both native
  switch vectors are handled identically.
- **Sticky non-managed state clears on managed confirm.** Start from
  `isNonManagedFocusActive == true`, confirm managed focus for the activated
  token, assert `isNonManagedFocusActive == false` afterward.

---

## Files touched

- `Sources/Nehir/Core/Controller/AXEventHandler.swift` — in `handleAppActivation`
  (`:1795`), let a Dock/Cmd-Tab activation that resolves to a tracked managed
  window on the active workspace bypass stale overlay-anchor suppression
  (primary fix); and/or narrow
  `shouldSuppressManagedActivationWhileNonManagedFocusAnchored` (`:1624`,
  predicate at `:1639-1640`) so `overlayFocusIsActive` requires a real overlay.
- `Sources/Nehir/Core/Reconcile/StateReducer.swift` — no change expected for the
  primary fix (the existing `managedFocusConfirmed` at `:326-333` already clears
  the flag once the activation reaches confirmation); referenced here because it
  is the mechanism that clears `isNonManagedFocusActive`.
- `Tests/NehirTests/` — the four tests above.
- `.changeset/<timestamp>-dock-click-reveals-focused-column.md` — `patch`,
  user-facing summary (e.g. "Clicking a Dock icon to focus a tiled window now
  scrolls the workspace to bring its column into view").

---

## Relationship to adjacent discoveries

| Doc | Path | Symptom | Relation |
|---|---|---|---|
| `20260615-viewport-reveal-from-unmanaged-overlay-activation` | `handleManagedAppActivation` reveal block | viewport scrolls when it **should not** (overlay sibling) | **Inverse.** Same reveal block, opposite failure. That fix tightens *when to reveal*; this fix loosens *what is suppressed before reveal*. The shared primitive is "is the resolved key window a managed window the user meant to focus, or an overlay sibling?" — both fixes want that one predicate. |
| `20260616-omniwm-317-rapid-focus-revert-race` / `20260616-omniwm-379-focus-revert-grace-period` | focus lease / revert timing | focus flapping on rapid switches | Adjacent. The `native_app_switch` lease duration (`0.4`, `:1844`) and the stickiness discussed here overlap with lease/revert timing; a fix here should be checked against those revert behaviours. |

Coordinating the "is the key window an overlay?" predicate across the reveal
suppression (this doc), the overlay-reveal case (sibling doc), and the FFM
overlay occlusion check is the natural merge point — one source of truth for
"what did the user actually intend to focus."
