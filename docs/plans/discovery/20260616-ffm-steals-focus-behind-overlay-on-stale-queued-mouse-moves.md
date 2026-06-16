# FFM steals focus to the tile behind a foreground overlay on stale-queued mouse moves

Discovery (2026-06-16). While an unmanaged overlay (the user's "quick terminal")
is in the foreground, focus-follows-mouse keeps **stealing focus to the niri
tiles behind it**, ping-ponging between two adjacent columns as the pointer
crosses their boundary. The completed FFM-overlay fix
(`docs/plans/completed/20260615-ffm-suppress-over-unmanaged-overlay-windows.md`)
does **not** cover this case: that fix's follow-up migrated FFM to the
`mouseEventWindowUnderMousePointer` fast-path but left FFM's *fallback* on the
legacy `layer == 0` WindowServer snapshot, and never gave FFM the broadened
`layer >= 0` overlay probe that the **trackpad-gesture** path independently grew.
Ordinary continuous pointer motion then defeats the fast-path entirely, because
the mouse-move coalescer re-reads the live pointer location and **discards the
window number** (`windowUnderPointer: nil`) on every stale queued event — and in
this capture *every* drained mouse-move (333/333) was stale.

Evidence below is reproduced inline from the runtime trace
`runtime-trace-1781562633992-1781562640078.log` (capture header `nehir v253be4*`,
2026-06-15T22:30:33Z). The log itself is machine-local and should not be relied
on. Code line numbers reference the working tree at commit `98f2429`; re-verify
before implementing.

This is the **focus-steal** sibling of
`docs/plans/discovery/20260615-viewport-reveal-from-unmanaged-overlay-activation.md`
(same actor — a foreground unmanaged overlay — different code path: that one is
`AXEventHandler` app-activation → viewport reveal; this one is
`MouseEventHandler` focus-follows-mouse).

---

## TL;DR

- **Symptom.** Single display; the quick-terminal overlay is up in the
  foreground; `focusFollowsMouse=true`. As the pointer moves across the seam
  between the two visible tiled columns (Helium `w6496` at screen `x≈18..1024`
  and Teams `w3270` at `x≈1032..2038`), FFM fires `ffm.activate reason=hoverTarget`
  **16 times** over 6 s, toggling `confirmedManagedFocus` between `w6496` and
  `w3270` — focus is yanked to the tile behind the overlay instead of being left
  on the overlay.
- **Proof the overlay is on screen and detectable.** The trackpad-gesture path,
  in the same capture, emitted `gesture.skip reason=unmanagedOverlay
  loc=(1219.8,1270.4) windowUnderPointer=nil snapshotProbe=true` — i.e. the
  broadened `layer >= 0` overlay probe saw the overlay and suppressed the
  gesture. FFM never logged a suppression reason (`ffm.skip` entries are only
  `noTarget`/`duplicatePending`/`debounce`).
- **Two independent gaps, either sufficient to cause the bug.**
  1. **Stale-queue mouse-move replay discards the window number.**
     `replayQueuedMouseMoved` → `currentPointerPayload(forQueuedMouseMove:)`
     (`MouseEventHandler.swift:770`) re-reads the live location via
     `mouseLocationProvider()` and rebuilds the payload with
     `windowUnderPointer: nil` (`:781`) whenever the queued location is stale
     relative to the current pointer — i.e. on essentially every event during
     continuous motion (333/333 in this capture). The FFM fast-path can never
     run, because it has no `mouseEventWindowUnderMousePointer` to read once the
     `CGEvent` is gone.
  2. **FFM's occlusion fallback is blind to non-layer-0 overlays.** With
     `windowUnderPointer == nil`, `resolveFocusFollowsMouseTarget`
     (`:1260`) falls back through `unmanagedWindowServerWindowCovers`
     (`WMController.swift:2377`) to `visibleUnmanagedWindowServerFrames`
     (`WMController.swift:2345`), which still filters `guard layer == 0`
     (`:2357`). The quick terminal runs at `NSWindow.Level.floating` (layer 3) /
     `.popUpMenu` (101) — so it is excluded and the occlusion check returns
     `false`. FFM then hit-tests the tile behind and activates it.
- **Why the completed fix misses it.** Its follow-up replaced the *broad*
  WindowServer snapshot with the `mouseEventWindowUnderMousePointer` fast-path,
  precisely to avoid per-move `CGWindowListCopyWindowInfo` cost. But (a) that
  fast-path only runs when a usable window number is carried, and the stale-queue
  replay throws it away; and (b) when no number is available, FFM falls back to
  the old `layer == 0` snapshot, **not** the broadened `layer >= 0` overlay probe
  that the gesture path was given in parallel. The two paths diverged; FFM never
  inherited the broadened probe.
- **Fix.** Make FFM's occlusion symmetric with the gesture path: when
  `windowUnderPointer` is absent, run the broadened overlay probe
  (`unmanagedOverlayWindowServerWindowCovers`, already implemented) instead of
  the `layer == 0` fallback. Independently, stop silently nulling the window
  number on stale queued moves — carry the original event's window number forward
  (it is the window that was under the pointer for that event) and only override
  the *location*. See [Recommendations](#recommendations).

---

## How the bug manifests (reproduction evidence)

Topology: single monitor `ID(displayId: 1)` (Built-in Retina, 2056×1329),
`focusFollowsMouse=true`, `moveMouseToFocusedWindow=true`. Workspace 1
(`F14BB5EA-…`) is the only visible workspace: 5 columns, `activeColumnIndex=3`,
viewport `currentOffset=-1022.0`, so the two on-screen tiles are:

| Column | Window | bundleId | liveAXFrame (screen) |
|---|---|---|---|
| c2 (index 2) | `w6496` | `net.imput.helium` | `{{18.0, 0.0}, {1006.0, 1280.0}}` → x 18..1024 |
| c3 (index 3, selected) | `w3270` | `com.microsoft.teams2` | `{{1032.0, 0.0}, {1006.0, 1280.0}}` → x 1032..2038 |

There is an 8 px seam between them (`1024 < x < 1032`). An unmanaged overlay (the
quick terminal) is in the foreground — **not** enumerated in the trace's
"Visible Unmanaged WindowServer Windows" section (which shows `none`), because
that section is produced by the layer-0-restricted debug dump
(`visibleUnmanagedWindowServerDebugDump`, `WMController.swift:2482`
`guard layer == 0`): the same blindness that causes the bug also makes the
overlay invisible in the dump. The gesture path proves the overlay is present.

### FFM ping-pong (the focus steal)

The trace's `## Mouse focus trace` shows the pointer traversing the seam around
`x≈1020..1046, y≈910..1130`. As it crosses, FFM re-targets on each side:

```log
mouseMove.replay staleQueued queued=(1045.0,1132.7) current=(1047.9,1132.7)
mouseMove.replay staleQueued queued=(1042.0,1132.3) current=(1045.0,1132.7)
ffm.skip reason=noTarget loc=(1031.6,1130.8) confirmed=WindowToken(pid: 49025, windowId: 3270) pending=nil   ← in the 8px seam
ffm.skip reason=noTarget loc=(1030.2,1130.5) confirmed=WindowToken(pid: 49025, windowId: 3270) pending=nil
...
ffm.activate reason=hoverTarget loc=(1023.8,1128.4) target=WindowToken(pid: 33418, windowId: 6496) confirmed=WindowToken(pid: 49025, windowId: 3270) …   ← crossed into Helium
mouseMove.replay staleQueued queued=(1020.2,1127.5) current=(1022.5,1128.1)
...
ffm.activate reason=hoverTarget loc=(1042.8,1123.7) target=WindowToken(pid: 49025, windowId: 3270) confirmed=WindowToken(pid: 33418, windowId: 6496) …   ← crossed back into Teams
```

Across the 6 s capture this pattern produces **16 `ffm.activate` events** (8 →
`w6496`, 8 → `w3270`), each mirrored downstream by `managed_focus_requested` /
`managed_focus_confirmed` toggling `confirmedManagedFocus` between the two tiles.
The overlay is never the target — focus is always stolen to the tile behind it.

Critically, **every FFM evaluation is driven by a stale-queued replay**: the
capture contains exactly 333 `mouseMove.replay staleQueued` lines and 333 total
`mouseMove` lines (100%), i.e. *no* drained mouse-move carried a fresh
`CGEvent`. The `MouseEventHandler` counters bear out the volume:
`queuedTransientEvents` 7174→7838, `drainedTransientEvents` 7139→7784 over the
capture.

### Proof the overlay is detectable (gesture path, same capture)

```log
gesture.skip reason=unmanagedOverlay loc=(1219.8,1270.4) windowUnderPointer=nil snapshotProbe=true
```

The trackpad-gesture handler suppressed because its broadened overlay probe saw
the unmanaged overlay — with the same `windowUnderPointer == nil` condition that
FFM had. The asymmetry is the bug.

---

## Root cause (with citations)

### Gap 1 — stale-queued mouse-move replay discards the window number

`MouseEventHandler.swift:749` `replayQueuedMouseMoved`:

```swift
let currentPayload = currentPointerPayload(forQueuedMouseMove: payload)
…
handleMouseMovedFromTap(
    at: currentPayload.location,
    windowUnderPointer: currentPayload.windowUnderPointer   // ← nil when stale (see below)
)
```

`MouseEventHandler.swift:770` `currentPointerPayload(forQueuedMouseMove:)`:

```swift
let currentLocation = mouseLocationProvider()               // re-reads a bare CGPoint; no CGEvent
guard currentLocation.x.isFinite, currentLocation.y.isFinite else { return payload }
guard !pointsApproximatelyEqual(payload.location, currentLocation, tolerance: …) else {
    return payload                                          // fresh: keep original windowUnderPointer
}
return .init(location: currentLocation, windowUnderPointer: nil)   // ← STALE: window number thrown away
```

When the queued location no longer matches the live pointer (the overwhelmingly
common case during continuous motion — 333/333 here), the replay rebuilds the
payload from `mouseLocationProvider()` (a `CGPoint`, no `CGEvent`), so the
overlay's `mouseEventWindowUnderMousePointer` is irrecoverable. The downstream
`handleFocusFollowsMouse(at:windowUnderPointer: nil)` (`:1189`) and
`resolveFocusFollowsMouseTarget(at:windowUnderPointer: nil)` (`:1260`) are then
forced onto the occlusion fallback.

> Note: the original `windowUnderPointer` for the *queued* event was the window
> under the pointer at enqueue time. Discarding it is unnecessary — the window
> identity is stable enough for an occlusion decision even when the sub-pixel
> location has advanced. Only the location needs refreshing.

### Gap 2 — FFM's occlusion fallback is blind to non-layer-0 overlays

`MouseEventHandler.swift:1260` `resolveFocusFollowsMouseTarget`, occlusion block:

```swift
if isFloatingWindowCoveringPointer(at: location, in: wsId)
    || hasVisibleFloatingWindowOverNiriLayout(in: wsId)
    || controller.unmanagedWindowServerWindowCovers(
        point: location,
        windowUnderPointer: windowUnderPointer,                          // nil here
        allowWindowServerSnapshotFallback: allowWindowServerSnapshotFallback   // true (default)
    )
{
    return nil   // suppressed
}
```

`WMController.swift:2377` `unmanagedWindowServerWindowCovers`:

```swift
let trackedWindowIds = Set(workspaceManager.trackedWindowIdsForDebug())
if let windowUnderPointer, windowUnderPointer > 0 {                       // skipped — nil
    return isUnmanagedWindowServerWindow(windowId: windowUnderPointer, trackedWindowIds: trackedWindowIds)
}
guard allowWindowServerSnapshotFallback else { return false }             // true → fall through
return unmanagedWindowServerWindowFramesProvider(trackedWindowIds).contains { $0.contains(point) }
```

`unmanagedWindowServerWindowFramesProvider` defaults to
`visibleUnmanagedWindowServerFrames` (`WMController.swift:182`), which filters
`guard layer == 0 else { return nil }` (`:2357`). A quick-terminal overlay at
`.floating` (3) / `.popUpMenu` (101) is excluded → the snapshot returns an empty
frame set → `contains` is `false` → **FFM is not suppressed** → it proceeds to
`engine.hitTestFocusableWindow(point:in:)` and activates the tile behind.

### The gesture path does not have this gap

`MouseEventHandler.swift:1428` (inside `handleGestureEvent`):

```swift
let shouldProbeWindowServerOverlay = snapshot.windowUnderPointer == nil
    && state.gesturePhase == .idle
    && phase != .ended && phase != .cancelled
    && activeTouchCount > 0
let isOverUnmanagedOverlay = controller.unmanagedWindowServerWindowCovers(
    point: location,
    windowUnderPointer: snapshot.windowUnderPointer,
    allowWindowServerSnapshotFallback: false                             // fast-path only
) || (shouldProbeWindowServerOverlay && controller.unmanagedOverlayWindowServerWindowCovers(point: location))
```

The gesture handler ORs in the broadened probe —
`unmanagedOverlayWindowServerWindowCovers` (`WMController.swift:2400`) →
`visibleUnmanagedOverlayWindowServerWindowCovers` (`:2415`), which filters
`guard layer >= 0 else { continue }` (`:2433`) and excludes only system chrome by
activation policy (see the completed plan's note #3). That probe saw the overlay
in this capture and produced `gesture.skip reason=unmanagedOverlay …
snapshotProbe=true`. FFM has no such OR-branch.

---

## Why the completed FFM-overlay fix misses it

The completed plan's headline fix ("broaden `layer == 0` → `layer >= 0`") was
**superseded** (per its own status banner) by a "low-overhead replacement": read
`CGEventField.mouseEventWindowUnderMousePointer` in the mouse event tap and
treat FFM as occluded when the event's topmost window is neither a Nehir-tracked
managed window nor an owned Nehir surface. That migration left two loose ends
that this trace exposes:

1. **The fast-path is bypassed by coalescing.** `windowUnderPointer(from:)`
   (`MouseEventHandler.swift:2067`) reads the field off the live `CGEvent` — but
   the event is only available in the tap. By the time a *coalesced/stale*
   mouse-move is drained on the main actor, `currentPointerPayload` rebuilds the
   payload from a bare `CGPoint` and nulls the window number (`:781`). The
   fast-path never runs for those events, and during continuous motion they are
   essentially *all* of them (333/333 here). The plan explicitly tried to avoid
   per-move `CGWindowListCopyWindowInfo`, so it did not give FFM a cheap fallback
   for the no-window-number case — unlike the gesture path, which got exactly
   that (the broadened `unmanagedOverlayWindowServerWindowCovers` probe).

2. **The legacy fallback was never broadened for FFM.** When FFM *does* fall
   back, it goes through `unmanagedWindowServerWindowCovers` →
   `visibleUnmanagedWindowServerFrames`, which still has the original
   `layer == 0` restriction (`:2357`). The broadened predicate
   (`visibleUnmanagedOverlayWindowServerWindowCovers`, `:2433` `layer >= 0`)
   was added only behind `unmanagedOverlayWindowServerWindowCovers`, and that
   function is called **only** from the gesture path (`:1437`). So the two
   overlay-suppression paths diverged: gesture learned to see floating/popup
   overlays; FFM did not.

In short: the completed fix closed the *direct-dispatch* overlay case (a fresh
event whose `mouseEventWindowUnderMousePointer` points at the overlay) but left
open the *coalesced/stale-dispatch* case (no usable window number → layer-0
fallback → overlay invisible). This trace is the latter.

---

## Recommendations

### Primary fix: make FFM occlusion symmetric with the gesture path (broadened probe when no window number)

In `resolveFocusFollowsMouseTarget` (`MouseEventHandler.swift:1260`), mirror the
gesture disjunction. When `windowUnderPointer` is absent, consult the broadened
overlay probe instead of the `layer == 0` snapshot. Sketch:

```swift
let resolvedWindowUnderPointer = windowUnderPointer
let isOccluded =
    isFloatingWindowCoveringPointer(at: location, in: wsId)
    || hasVisibleFloatingWindowOverNiriLayout(in: wsId)
    || controller.unmanagedWindowServerWindowCovers(
        point: location,
        windowUnderPointer: resolvedWindowUnderPointer,
        allowWindowServerSnapshotFallback: false                 // never use the layer-0 fallback
    )
    || ((resolvedWindowUnderPointer == nil) && controller.unmanagedOverlayWindowServerWindowCovers(point: location))
```

This reuses the already-implemented, already-tested
`unmanagedOverlayWindowServerWindowCovers` (it already excludes Nehir's own
pass-through border surfaces and system chrome via activation policy — see the
completed plan's notes #1 and #3), so it needs no new predicate. It also keeps
FFM off the per-move `CGWindowListCopyWindowInfo` hot path **except** when the
event genuinely lacks a window number — i.e. exactly the stale-queue case, which
is rarer than every-move once Gap 2 below is fixed.

### Gap 2 (independent): stop discarding the window number on stale queued moves

In `currentPointerPayload(forQueuedMouseMove:)` (`MouseEventHandler.swift:770`),
carry the queued event's `windowUnderPointer` forward instead of nulling it:

```swift
// was: return .init(location: currentLocation, windowUnderPointer: nil)
return .init(location: currentLocation, windowUnderPointer: payload.windowUnderPointer)
```

The window-under-pointer identity for a given event is stable for an occlusion
decision even when the pointer has advanced a few pixels; only the *location*
needs refreshing to the live value (which is what the stale check already
intends). With this, fresh-event mouse-moves keep their fast-path window number
through coalescing, and the broadened probe from the primary fix becomes a true
last-resort fallback rather than the common path.

### Optional: share one occlusion helper

FFM, the gesture path, and `markRecentFloatingPointerInteractionIfNeeded`
(`:1347`) each inline their own occlusion logic against two controller methods.
Once the primary fix lands, the three call sites will all want "is this point
occluded by an unmanaged overlay, given an optional window-under-pointer?" —
consider extracting a single
`controller.pointIsOccludedByUnmanagedOverlay(point:windowUnderPointer:)` that
encodes "fast-path if number present, else broadened probe, never layer-0
fallback", so the symmetry cannot drift again. (Do **not** route through the
legacy `unmanagedWindowServerWindowFramesProvider`/`visibleUnmanagedWindowServerFrames`
— its `layer == 0` filter is the footgun. If nothing else still needs it, retire
it; otherwise leave it for the debug dump only.)

### Risk note: overlay-coverage geometry

`unmanagedOverlayWindowServerWindowCovers` is a bounds-containment check, so it
suppresses FFM only over the overlay's *frame*, not screen-wide. That is the
desired behaviour: when the pointer is genuinely over the quick terminal, FFM is
suppressed; when it is over a tile the overlay does not cover, FFM correctly
fires. The reported symptom is the overlay-covered case, which this fix targets.
(If the overlay is a small dropdown that does not cover the seam being hovered,
FFM firing there is correct and out of scope.)

---

## Tests to add

In `Tests/NehirTests/MouseEventHandlerTests.swift` (extend the existing
FFM-overlay tests; the broadened-probe unit tests already exist for the gesture
path and can be reused):

- **FFM suppresses over an overlay when the mouse-move carries no window number.**
  Pointer over a non-tracked, layer-3 window (and a layer-101 variant) above a
  tile; drain the mouse-move through the stale-queue replay path (so
  `windowUnderPointer == nil`); assert `confirmedManagedFocusToken` stays on the
  previously-focused tile and `activeFocusRequestToken` stays nil. This is the
  direct regression for this trace.
- **FFM suppresses over an overlay when the mouse-move carries the overlay's
  window number.** Same geometry but feed `windowUnderPointer = <overlay id>`;
  assert suppression (guards the fast-path; should already pass — confirms the
  fix did not regress direct dispatch).
- **FFM still activates a tile when no overlay is present.** Same pointer motion
  across a two-column seam with no overlay; assert FFM re-targets normally
  (guards the fix against over-suppression / the seam-hover case).
- **Stale-queued replay preserves the window number.** Unit-style: enqueue a
  mouse-move with a known `windowUnderPointer`, advance the live pointer so the
  payload is stale, and assert the replayed payload still carries that window
  number (regression for Gap 2).
- (Reuse) the existing `visibleUnmanagedOverlayWindowServerWindowCovers` unit
  tests (layer ∈ {0,3,101,25}, system-chrome exclusion) already cover the
  predicate the primary fix depends on.

## Files touched

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` — broaden the FFM
  occlusion block in `resolveFocusFollowsMouseTarget` (`:1260`) to OR in
  `unmanagedOverlayWindowServerWindowCovers` when `windowUnderPointer` is nil;
  stop nulling `windowUnderPointer` in `currentPointerPayload(forQueuedMouseMove:)`
  (`:770`/`:781`); (optional) extract a shared `pointIsOccludedByUnmanagedOverlay`
  helper used by the FFM, gesture (`:1433`), and
  `markRecentFloatingPointerInteractionIfNeeded` (`:1347`) call sites.
- `Sources/Nehir/Core/Controller/WMController.swift` — no predicate change needed
  (the broadened `unmanagedOverlayWindowServerWindowCovers` already exists at
  `:2400`); optionally retire the layer-0 `visibleUnmanagedWindowServerFrames`
  (`:2345`) / `unmanagedWindowServerWindowFramesProvider` (`:182`) from the FFM
  path if the shared helper replaces all call sites, or leave it for the debug
  dump only.
- `Tests/NehirTests/MouseEventHandlerTests.swift` — the four tests above.
- `.changeset/<timestamp>-fixed-ffm-stealing-focus-behind-overlay-on-stale-mouse-moves.md`
  — `patch`, user-visible summary.

## Relationship to sibling docs

Same actor (a foreground unmanaged overlay), three symptoms, three code paths —
the unmanaged-overlay detection should converge on one predicate:

| Doc | Path | Symptom | Guard location |
|---|---|---|---|
| `completed/20260615-ffm-suppress-over-unmanaged-overlay-windows` | `MouseEventHandler` FFM (direct dispatch) | focus stolen behind overlay (fresh event) | `mouseEventWindowUnderMousePointer` fast-path — **does not cover coalesced/stale moves** |
| **this discovery** | `MouseEventHandler` FFM (coalesced/stale dispatch) | focus stolen behind overlay (no window number) | `resolveFocusFollowsMouseTarget` occlusion block + `currentPointerPayload` window-number retention |
| `20260615-viewport-reveal-from-unmanaged-overlay-activation` | `AXEventHandler` app-activation → reveal | viewport scrolls on a non-interaction workspace | `handleManagedAppActivation` reveal block |

The natural merge point (called out in both sibling docs) is one predicate:
"is the pointer's / activation's real key surface an unmanaged overlay?" The
broadened `unmanagedOverlayWindowServerWindowCovers` (bounds + activation-policy)
already implements the pointer variant; this discovery just wires FFM's
fallback to it and stops the coalescer from throwing away the fast-path input.
