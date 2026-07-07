# Stale floating entry lingers in the bar after its AX surface is destroyed — Discovery

Groom 2026-07-07: still applicable — the rescan-time reap of a dead-handle floating entry (phantom pill after surface close) is not confirmed landed; the related liveness work (`7a025b78` / `completed/20260707-verify-liveness-before-honoring-ax-destroy.md`) targets the inverse cold-start spurious-destroy case, and `07ce4168` reconciles stale *hidden-window* frames rather than dead-handle floating entries. Re-verify against current source before acting.

Discovery (2026-06-28). After closing Vivaldi's Picture-in-Picture overlay
(video returned to in-page playback in the browser), Nehir's **managed entry for
the PiP persisted as a phantom**: the workspace bar kept showing a floating
window for Vivaldi, but no PiP was visible on screen. The entry's underlying AX
element was dead — every live frame read returned `nil` — yet the entry, the bar
pill, and a cached "last applied" frame all survived until the reporter reset
Nehir's runtime state, at which point the phantom disappeared from the bar.

The root gap is a **missing rescan-time reap**: Nehir removes a tracked window
only from three triggers, none of which fired for this Chromium-embedded surface
when it was closed. There is no periodic check that drops a tracked floating
window whose AX element has gone unreadable, so the bar keeps rendering a pill
from cached geometry that is never revalidated against a live frame read.

This is the **close** end of the same PiP's lifecycle; the **open** end (PiP
opens offscreen, never admitted on creation) is documented separately in
[`20260628-chromium-pip-opens-offscreen-never-create-seen.md`](20260628-chromium-pip-opens-offscreen-never-create-seen.md).
The two are independent: this one is about reclaim on close, that one is about
admission on open.

All code citations verified against the main Nehir source tree at `9ef0ae82` on
2026-06-26 (`git log -1 --format='%h %s' main` → `9ef0ae82 Add sticky PiP
defaults and ignore app rules`). Line numbers will drift.

---

## TL;DR

- **Symptom.** Workspace bar shows a floating-window pill for Vivaldi after the
  PiP was closed. Nothing is visible on screen at the pill's position.
- **What it is.** A stale managed entry, `WindowToken(pid: 13892, windowId:
  2274)`, `mode=floating`. Its AX element is dead: `liveAXFrame=nil`, while
  every other managed window in the same dump has a live frame.
- **Why the bar shows it.** The bar pill is rendered from cached geometry
  (`floatingBarProjectionFrame` = `resolvedFloatingFrame ??
  desiredState.floatingFrame ?? observedState.frame ?? metadata.frame`) — never
  a live frame read — so a dead-handle entry still projects at its last known
  frame.
- **Why it persists.** Nehir reaps a tracked window only from (1) an
  `kAXUIElementDestroyed` AX notification, (2) the one-shot post-create
  lifecycle verification, or (3) app termination. Chromium closed the PiP
  without emitting the destroy notification, so none fired; and there is no
  rescan-time reap to catch the dead handle.
- **Confirmed runtime-state-held.** Resetting Nehir's runtime state made the
  phantom disappear from the bar — i.e. it lived in in-memory runtime state, not
  in persisted config, and a fresh rescan/discovery from a clean state did not
  re-admit it.

---

## Topology / initial state

Single display, `ID(displayId: 1)`, notch, frame `(0.0, 0.0, 2056.0, 1329.0)`,
visible frame `(0.0, 0.0, 2056.0, 1290.0)`. Workspace bar enabled.

Active workspace `BC5D5EC7-3E7F-43AD-B643-F2CF47C69FB8`. Managed focus on the
tiled Vivaldi browser window `WindowToken(pid: 13892, windowId: 2249)`;
`nonManaged=true` (a Nehir Diagnostics panel, `windowId=3450`, had taken focus).

App: Vivaldi (`com.vivaldi.Vivaldi`, pid `13892`). The PiP (`2274`) had been
open earlier and admitted (see the sibling discovery); the user then closed it,
returning the video to in-page playback. No PiP was visible.

---

## What the evidence proves

### 1. The PiP entry is a phantom: dead AX handle, cached geometry

From the `-- Managed Windows --` runtime dump, four entries were present. Three
have live AX frames; **only `2274` has `liveAXFrame=nil`**:

```text
WindowToken(pid: 13175, windowId: 353)  … liveAXFrame={{1044.0, 32.0}, {972.0, 1226.0}} …   ← live
WindowToken(pid: 13175, windowId: 2882) … liveAXFrame={{2055.0, 32.0}, {972.0, 1226.0}} …  ← live
WindowToken(pid: 13892, windowId: 2249) … liveAXFrame={{40.0, 32.0}, {972.0, 1226.0}} …     ← live (the tiled browser)

WindowToken(pid: 13892, windowId: 2274) workspace=BC5D5EC7-… mode=floating phase=floating hidden=nil layout=standard
  observedFrame={{924.0, 860.0}, {764.0, 430.0}}
  liveAXFrame=nil                                   ← DEAD — fresh AX read returns nothing
  observedVisible=true observedFocused=false
  desiredFloating={{924.0, 860.0}, {764.0, 430.0}}
  replacementFrame={{924.0, 39.0}, {764.0, 430.0}}
  barFloating=accepted(userAddressable)
  barFrame={{924.0, 860.0}, {764.0, 430.0}}
  bundleId=com.vivaldi.Vivaldi role=AXWindow subrole=AXStandardWindow windowLevel=3
  transientWindowServerEvidence=false degradedWindowServerChildEvidence=false
```

`liveAXFrame` is computed at dump time as a fresh read:
`try? AXWindowService.frame(entry.axRef)` (`WorkspaceManager.swift:426`). `nil`
means the AX element backing `2274` is unreadable — i.e. the handle is dead.
`2274` is the only entry in the dump for which this is true.

The AX window-state record shows Nehir still *believes* it placed the window
successfully and is unaware of a problem:

```text
windowId=2274 lastApplied={{924.0, 860.0}, {764.0, 430.0}} pending=nil failure=nil
            retryBudget=nil forceApply=false observerRequest=nil inactiveWorkspace=false
```

`failure=nil` — no recorded frame-write failure. The dead handle is invisible
to the frame-write accounting because Nehir is not trying to write to it (it is
floating, already "applied").

### 2. The reconcile trace shows the phantom failing to take focus, then going non-managed

The reconcile trace records repeated attempts to focus `2274` that never
confirm, after which focus falls through to the tiled browser and then to a
non-managed panel:

```text
#467 05:29:51  managed_focus_requested token=…2274  pending=…2274     ← requested
#470 05:29:53  managed_focus_requested token=…2274  pending=…2274     ← re-requested, still pending
#473 05:29:55  managed_focus_confirmed token=…2249                    ← focus fell through to the tiled browser
#475 05:30:34  non_managed_focus_changed active=true … non_managed=true  ← and then to a non-managed panel
```

There is **no** `managed_focus_confirmed` for `2274` and **no**
`window_removed` for `2274` anywhere in the trace. The entry simply sits there,
unfocusable and unremoved.

### 3. The bar pill is rendered from cached geometry, not a live read

The bar projection for floating entries is decided and framed from caches:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2778-2784
private func floatingBarProjectionFrame(for entry: WindowModel.Entry) -> CGRect? {
    resolvedFloatingFrame(for: entry.token)
        ?? entry.desiredState.floatingFrame
        ?? entry.observedState.frame
        ?? entry.managedReplacementMetadata?.frame
}
```

Every fallback is a stored value; none is a live `AXWindowService.frame` read.
`barProjectionDecision` returns `accepted(userAddressable)` for `2274` because
its cached metadata still looks like a standard floating window (the dump shows
`barFloating=accepted(userAddressable)`). So the bar keeps drawing a pill at
the cached `(924.0, 860.0)` even though there is no live surface there. That is
the "bar shows it, I don't see it" symptom.

### 4. Reclaim did not fire from any of the three triggers

Nehir removes a tracked window via `removeTrackedWindow`
(`WorkspaceManager.swift:3224`), reached from exactly three sources:

1. **`kAXUIElementDestroyed` AX notification.** Observed in
   `AppAXContext.swift` (`:112` declaration, `:297` invocation, `:914`/`:919`
   dispatch) and wired to `handleRemoved` at `ServiceLifecycleManager.swift:83-86`:
   ```swift
   AppAXContext.onWindowDestroyed = { [weak controller] pid, windowId in
       guard let controller else { return }
       controller.axEventHandler.handleRemoved(pid: pid, winId: windowId)
   }
   ```
2. **Post-create lifecycle verification**, which reaps when the window is gone
   from the WindowServer:
   ```swift
   // Sources/Nehir/Core/Controller/AXEventHandler.swift:1297-1320 (key checks at :1307, :1314)
   self.resolveWindowInfo(windowId) == nil   // → warm, then handleRemoved
   ```
   This runs **once**, a short delay after creation.
3. **App termination** (`ServiceLifecycleManager` `onAppTerminated`).

For the closed PiP, **none fired**: Chromium closed the embedded surface without
emitting `kAXUIElementDestroyed` for that handle (the session's AX notification
trace was empty for `2274`); the post-create verification had long since
completed; and Vivaldi did not terminate. There is no fourth trigger.

### 5. Confirmed: the phantom is runtime-state-held

The reporter reset Nehir's runtime state and the phantom pill disappeared from
the bar. This proves:

- The entry lived in **in-memory runtime state**, not in persisted window
  config or the restore catalog.
- A fresh rescan/discovery from a clean state did **not** re-admit `2274`
  (because the surface is genuinely gone — there is nothing to admit), so the
  phantom was purely the stale leftover.

---

## Root-cause surface

### Why the rescan does not reap

The full-rescan reconcile loop builds a `decisionBasedRemovals` set and reaps
only those:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1472-1477
for token in decisionBasedRemovals {
    controller.nativeFullscreenPlaceholderManager.remove(token)
    controller.cleanupScratchpadWindowResourcesIfNeeded(for: token)
    controller.axManager.removeWindowState(pid: token.pid, windowId: token.windowId)
    _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
    controller.clearKeyboardFocusTarget(matching: token)
}
```

`decisionBasedRemovals` is fed by explicit decision-based removals in the
per-window reconcile pass — it is **not** fed by "this window's AX handle is
dead" or "this window is gone from the WindowServer." When a dead-handle entry
is re-evaluated, the rule engine just marks it deferred and keeps it:

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:578-594
if !facts.ax.attributeFetchSucceeded {
    …
    return WindowDecision(
        disposition: .undecided,
        …
        deferredReason: .attributeFetchFailed   // ← keeps the entry; does not remove it
    )
}
```

So on every rescan the dead `2274` is re-classified as
`deferred=attributeFetchFailed` and survives. There is no path from
"persistently unreadable AX handle" to removal.

### What the post-create verification *already* knows how to check

The one-shot post-create verification reaps using
`resolveWindowInfo(windowId) == nil` (WindowServer-gone). That predicate is
exactly what a rescan-time reap would want — it just is not run periodically,
only once after creation. The gap is not "we don't know how to tell a window is
gone"; it is "we only ask once."

---

## Fix directions (no implementation in this pass)

### Direction A — Rescan-time reap for WindowServer-gone tracked windows

In the full-rescan reconcile loop, add tracked-but-WindowServer-gone windows to
the removal set using the same predicate the post-create verification already
trusts:

```swift
if controller.axEventHandler.resolveWindowInfo(UInt32(entry.windowId)) == nil {
    // gone from the WindowServer → reap (same predicate as post-create verification)
}
```

feeding the existing `decisionBasedRemovals` reap block
(`LayoutRefreshController.swift:1472-1477`).

- Pro: same predicate Nehir already uses to decide "this window is truly gone";
  conservative (a genuinely-alive managed window is always in the WindowServer,
  so no false-positive reaps); cures the phantom entry and the phantom bar pill
  in one move (removing the entry drops the pill).
- Con: needs an N-strikes / debounce so a transiently-unreadable WindowServer
  snapshot (during display reconfig, brief AX stalls) does not drop a live
  window. The post-create verification does not debounce because it runs once;
  a rescan-time check runs often and must.
- **Caveat — may not fully cover this case.** It is not confirmed from the dump
  whether `resolveWindowInfo(2274)` was `nil` at the moment of the phantom
  (Chromium may keep the surface's WindowServer entry alive briefly after the
  AX element dies). If the WindowServer entry lingered, Direction A alone would
  not have reaped `2274`; Direction B would be needed.

### Direction B — Rescan-time reap for persistently-unreadable AX handles

Complement Direction A with a dead-AX-handle reap: a tracked window whose
`try? AXWindowService.frame(entry.axRef)` read returns `nil` across N
consecutive rescans (and which is not in a known-transient state) is reaped.
This directly targets the `liveAXFrame=nil` signal the dump exposes.

- Pro: catches exactly this case (dead AX, possibly-living WindowServer entry);
  the signal (`liveAXFrame=nil`) is already computed for the runtime debug dump,
  so it is cheap to evaluate.
- Con: an AX read can transiently fail for a live window (attribute fetch
  races, app main-thread stalls). Requires N-strikes and a grace window, and
  care around windows that legitimately have no readable frame yet
  (newly-created, fullscreen transitions).

### Direction C — Stop projecting the bar pill from a dead handle

Independently of reclaim, the bar projection can refuse to draw a floating pill
whose live AX read is `nil`. `floatingBarProjectionFrame`
(`WorkspaceManager.swift:2778`) and/or `barProjectionDecision` would add a
fresh-read freshness check so a stale entry stops polluting the bar even before
reclaim catches up.

- Pro: smallest, safest change; the phantom pill disappears immediately even if
  reclaim is debouncing; the live-read is already a concept elsewhere in the
  codebase.
- Con: does not remove the entry (focus churn, restore-catalog noise continue);
  adds a per-projection AX read to the bar refresh path (cheapness should be
  confirmed — the dump already computes it, but the bar refreshes frequently).

### Recommendation

Direction C is the cheapest visible-symptom fix and is safe to land first.
Direction A is the proper structural reclaim but needs debounce and must be
validated against the "is `resolveWindowInfo(2274)` actually nil?" question
above. Direction B is the belt-and-suspenders for the case where the
WindowServer entry lingers. A pragmatic sequencing: C now (kill the phantom
pill), then A (reap WindowServer-gone) with debounce, then B only if a residual
dead-handle case survives A.

---

## What is still unknown

- **Was `resolveWindowInfo(2274)` nil at the phantom moment?** The runtime dump
  exposes `liveAXFrame` (AX read) but not the WindowServer-entry presence
  directly. If Chromium keeps the WindowServer entry alive after the AX element
  dies, Direction A alone will not reap and Direction B is required. A capture
  that logs both `resolveWindowInfo` and `liveAXFrame` for the closing PiP would
  settle which predicate to reap on.
- **How often does Chromium close an embedded surface without
  `kAXUIElementDestroyed`?** This PiP is one instance; whether it generalizes to
  other Chromium-embedded surfaces (other PiP providers, in-page popovers) is
  not surveyed.
- **Whether the dead handle ever self-heals.** The phantom persisted for at
  least ~40 s of reconcile activity in the dump (events `#467`→`#476`); it did
  not self-correct. A longer observation would confirm it is permanent without
  intervention.

---

## Relationship to other discoveries

- **Sibling (open end of the same lifecycle):**
  [`20260628-chromium-pip-opens-offscreen-never-create-seen.md`](20260628-chromium-pip-opens-offscreen-never-create-seen.md).
  Same surface (`2274`), same session: PiP opens offscreen and is admitted late
  (only on focus). That is an admission bug; this is a reclaim bug. Independent
  fix surfaces.
- **Adjacent:**
  [`20260622-rescued-floating-auxiliary-windows-leak-into-workspace-bar.md`](20260622-rescued-floating-auxiliary-windows-leak-into-workspace-bar.md).
  Both surface as "the workspace bar shows a floating window the user does not
  expect," but for opposite reasons: that doc is *over*-admission of tiny
  transient surfaces; this one is *under*-reclaim of a dead surface. Direction C
  here (freshness-check the bar pill) and the size/transience gate proposed
  there are complementary bar-projection guards.
