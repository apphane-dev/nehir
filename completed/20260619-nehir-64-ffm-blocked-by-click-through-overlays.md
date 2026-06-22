# Nehir #64 — Focus-follows-mouse blocked by third-party click-through "Borders" overlays

Discovery (2026-06-19) for GitHub issue **#64 — "Focus follow mouse not
working"** (labels: `bug`, `help wanted`).

**Verdict: shipped.** Fixed in commit `56573ba2` on `main` (2026-06-19, "Fix focus-follows-mouse blocked by click-through overlays (#64)") by reconciling the two CGEvent fields (the geometrically-topmost window number vs. the event-handling window number): when they diverge (topmost is click-through) the event-handling window is preferred, so a click-through overlay no longer suppresses FFM. Interactive overlays (Ghostty Quick terminal) keep both fields equal and still suppress FFM. Moved from `discovery/` to `completed/`.

The rest of this document is the original investigation (2026-06-19) kept as the durable record of the root-cause analysis; its earlier "still broken" verdict is superseded by the shipped fix above.

Discovery (2026-06-19) for GitHub issue **#64 — "Focus follow mouse not
working"** (labels: `bug`, `help wanted`).

---

## The reported bug (inlined)

Issue body: *"Focus follows mouse is not working. It is enabled but it is doing
nothing."*

Maintainer (@Guria, OWNER) root-caused it in the issue thread (decisive; no
network needed to act on this):

> "It turns out Focus Follows Mouse is being blocked by a third-party application
> called **Borders**. The app creates overlay windows on top of each tile, and
> Nehir currently treats those overlays as unmanaged windows that should suppress
> FFM. As a result, Nehir never resolves a valid target window under the pointer
> and FFM does nothing. [...] Decorative, click-through overlay windows should
> not prevent Focus Follows Mouse from working. I'll work on making the FFM
> occlusion logic ignore these kinds of overlays so that external border
> utilities don't interfere with focus tracking."

Reporter confirmed FFM works again once the external Borders app is quit, and
that **Nehir's own built-in Borders feature does not trigger this.** That last
contrast is the key to the fix (see "Why built-in Borders is fine").

---

## How a mouse-move becomes "FFM is occluded" (current source, verified)

The event tap reads a window number off each `CGEvent` and threads it through
FFM's occlusion decision. The chain:

1. **Event tap reads the window-under-pointer.**
   `MouseEventHandler.swift:1993` (inside the tap dispatch) →
   `windowUnderPointer(from:)` at `MouseEventHandler.swift:2067`:

   ```swift
   private nonisolated static func windowUnderPointer(from event: CGEvent) -> Int? {
       let directWindow = Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
       if directWindow > 0 { return directWindow }                       // ← (A)

       let eventHandlingWindow = Int(
           event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
       )
       return eventHandlingWindow > 0 ? eventHandlingWindow : nil        // ← (B) only if (A) ≤ 0
   }
   ```

   `mouseEventWindowUnderMousePointer` is the **geometrically topmost** window
   under the pointer, regardless of whether it handles events. For an on-screen
   overlay that value is the overlay's own window number and is `> 0`, so branch
   **(A)** returns immediately and the event-handling-aware field **(B)** is
   **never consulted.**

2. **The number is carried to FFM.**
   `receiveTapMouseMoved(at:windowUnderPointer:)` (`MouseEventHandler.swift:474`)
   → `handleMouseMovedFromTap(at:windowUnderPointer:)` (`:817`)
   → `handleFocusFollowsMouse(at:windowUnderPointer:)` (`:1189`)
   → `resolveFocusFollowsMouseTarget(at:windowUnderPointer:...)` (`:1260`).

3. **FFM's occlusion block treats that window as occluding if it is "unmanaged".**
   `MouseEventHandler.swift:1272`:

   ```swift
   if isFloatingWindowCoveringPointer(at: location, in: wsId)
       || hasVisibleFloatingWindowOverNiriLayout(in: wsId)
       || controller.unmanagedWindowServerWindowCovers(
           point: location,
           windowUnderPointer: windowUnderPointer,
           allowWindowServerSnapshotFallback: allowWindowServerSnapshotFallback
       )
   {
       return nil   // ← FFM suppressed
   }
   ```

4. **`unmanagedWindowServerWindowCovers` short-circuits on the window number.**
   `WMController.swift:2606`:

   ```swift
   func unmanagedWindowServerWindowCovers(point: CGPoint, windowUnderPointer: Int? = nil,
                                          allowWindowServerSnapshotFallback: Bool = true) -> Bool {
       let trackedWindowIds = Set(workspaceManager.trackedWindowIdsForDebug())
       if let windowUnderPointer, windowUnderPointer > 0 {
           return isUnmanagedWindowServerWindow(windowId: windowUnderPointer, trackedWindowIds: trackedWindowIds)
       }
       guard allowWindowServerSnapshotFallback else { return false }
       return unmanagedWindowServerWindowFramesProvider(trackedWindowIds).contains { $0.contains(point) }
   }
   ```

5. **`isUnmanagedWindowServerWindow` only checks "not mine".**
   `WMController.swift:2623`:

   ```swift
   private func isUnmanagedWindowServerWindow(windowId: Int, trackedWindowIds: Set<Int>) -> Bool {
       guard !trackedWindowIds.contains(windowId) else { return false }
       guard !ownedWindowRegistry.contains(windowNumber: windowId) else { return false }
       return true
   }
   ```

   The external Borders overlay is a separate process: it is not in
   `trackedWindowIds` (Nehir-managed app windows) and not in
   `ownedWindowRegistry` (Nehir's own UI surfaces). So this returns **`true`** →
   step 3 suppresses FFM → **FFM does nothing over every tile the overlay covers.
   That is exactly #64.**

### Why built-in Borders is fine (the maintainer's contrast)

Nehir's own border windows are registered as Nehir-owned surfaces
(`OwnedWindowRegistry`, registered by the surface coordinator as
`.passthrough`/`.border` surfaces; see `WMController.swift:184` and the
`ownedWindowRegistry.contains(windowNumber:)` guard at `:2625`). So for the
built-in border, step 5 hits `ownedWindowRegistry.contains(...) == true` and
returns `false` — it is correctly excluded from occlusion. The external app
cannot be in that registry (different process), so it falls through to "is
unmanaged" → occluding. The bug is therefore specifically about *external,
non-tracked, non-owned* overlays that do not actually receive clicks.

---

## Why the completed FFM-overlay fix does not cover this

`completed/20260615-ffm-suppress-over-unmanaged-overlay-windows.md` shipped an
FFM-occlusion fix for **Ghostty's Quick terminal**. Its final design reads
`mouseEventWindowUnderMousePointer` (falling back to
`mouseEventWindowUnderMousePointerThatCanHandleThisEvent`) in the event tap and
treats FFM as occluded when the topmost window number is neither Nehir-managed
nor a Nehir surface — i.e. **exactly the code path traced above.**

That fix is correct for the Quick terminal because the Quick terminal **is an
interactive overlay**: it handles mouse events, so both CGEvent fields report the
same window number, and FFM *should* be suppressed over it. The fix's
field-priority (`mouseEventWindowUnderMousePointer` first, `ThatCanHandle…` only
as a `> 0` fallback) was chosen to detect *interactive* overlays at non-zero
layers. But that same priority is precisely why a **click-through** overlay
(decorative, `ignoresMouseEvents`, does not handle events) is misclassified:

- The overlay is geometrically topmost → `mouseEventWindowUnderMousePointer` (A)
  returns it (> 0) → branch (A) returns.
- `mouseEventWindowUnderMousePointerThatCanHandleThisEvent` (B) — the field that
  *would* skip a click-through overlay and report the tile beneath — is never
  reached.

In other words: **the completed fix treats "geometrically overlaps pointer" and
"will receive the click" as the same thing.** For #64 they differ, and the code
picks the wrong one. There is **no `ignoresMouseEvents` / click-through /
event-handling check anywhere in `WMController`'s occlusion logic** (verified:
the only `ThatCanHandleThisEvent` reference in the whole module is the fallback
at `MouseEventHandler.swift:2072`).

### Sibling discovery (stale-queued moves) shares the seam, not the cause

`discovery/20260616-ffm-steals-focus-behind-overlay-on-stale-queued-mouse-moves.md`
addresses the *focus-steal* twin (FFM firing through an interactive overlay on
coalesced mouse-moves that lost their window number). Its recommended fix is to
wire FFM's fallback to the broadened overlay probe
(`unmanagedOverlayWindowServerWindowCovers`, `WMController.swift:2629`, which
filters `layer >= 0` at `:2662` and excludes system chrome by activation policy
at `:2689`). That broadened probe would **also** misclassify the Borders overlay
as occluding (it is layer ≥ 0, ≥ 80 px, owned by a `.regular`-policy app), so it
is **not** a fix for #64 — it would in fact make #64 *more* consistent. The two
discoveries are complementary, not substitutes (see "Relationship to sibling
docs").

---

## The decisive signal: click-through vs interactive

| Overlay | Handles events? | `mouseEventWindowUnderMousePointer` | `…ThatCanHandleThisEvent` | Should occlude FFM? |
|---|---|---|---|---|
| Ghostty Quick terminal | **yes** | Quick terminal id | Quick terminal id (same) | **yes** |
| External "Borders" app | **no** (click-through) | Borders overlay id | tile id beneath (or 0) | **no** |
| Nehir built-in border | no (passthrough) | border id | tile id beneath | **no** (also excluded via `ownedWindowRegistry`) |

The two CGEvent fields **diverge exactly when the topmost window is
click-through.** That divergence is the robust, OS-provided signal that no
`CGWindowListCopyWindowInfo` predicate can reproduce (the WindowServer snapshot
does not expose `ignoresMouseEvents`).

---

## Plan (minimal, tight)

**Goal.** FFM (and, for consistency, the other two occlusion call sites) must
key the occlusion decision on the *event-handling-capable* window, not the
geometrically-topmost window, so that click-through decorative overlays become
transparent to focus tracking while interactive overlays (Ghostty Quick
terminal) still suppress FFM.

### Change 1 — prefer the event-handling window number (primary fix)

In `windowUnderPointer(from:)` (`MouseEventHandler.swift:2067`), flip the field
priority so a click-through overlay does not win:

```swift
private nonisolated static func windowUnderPointer(from event: CGEvent) -> Int? {
    let eventHandlingWindow = Int(
        event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
    )
    if eventHandlingWindow > 0 { return eventHandlingWindow }                  // click-aware first

    let directWindow = Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
    return directWindow > 0 ? directWindow : nil                               // fallback for events/owners that leave (B) unset
}
```

Effect for #64: over a Borders-decorated tile, `(B)` reports the tile beneath
(the overlay is click-through), the tile is Nehir-tracked →
`isUnmanagedWindowServerWindow` returns `false` → FFM is **not** suppressed →
FFM fires on the real tile. For Ghostty Quick terminal, `(B)` reports the Quick
terminal (it handles events) → still unmanaged → still suppressed → **no
regression.**

**Seam points (exact, re-verify):**
- `Sources/Nehir/Core/Controller/MouseEventHandler.swift:2067` —
  `windowUnderPointer(from:)` (single source of the window number for the whole
  event-tap path; called at `:1993` for mouse-moved and `:2196` for the
  synthetic/secondary dispatch).

**Conservative variant (if event-tap field reliability is a concern):** read
both fields and reconcile explicitly — if `direct > 0 && canHandle > 0 &&
direct != canHandle`, the topmost window is click-through, so return `canHandle`
(the real target); otherwise return whichever is `> 0`, preferring `canHandle`:

```swift
let direct = Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
let canHandle = Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))
if direct > 0, canHandle > 0, direct != canHandle { return canHandle }   // topmost is click-through
return canHandle > 0 ? canHandle : (direct > 0 ? direct : nil)
```

This makes the divergence itself the test and keeps a `direct` fallback for
owners that populate only the geometric field. Recommended over the bare flip if
there is any doubt that `(B)` is populated on all macOS versions / event types.

### Change 2 — preserve the window number across stale-queue coalescing (enables Change 1 on every move)

`currentPointerPayload(forQueuedMouseMove:)` (`MouseEventHandler.swift:770`)
nulls the window number whenever a queued move is stale relative to the live
pointer (`return .init(location: currentLocation, windowUnderPointer: nil)` at
`:781`). When that happens, `resolveFocusFollowsMouseTarget` is forced onto the
snapshot fallback, Change 1 never runs, and the snapshot path (see Change 3) has
no click-through signal at all. Carry the queued event's window number forward
(only the location needs refreshing):

```swift
// MouseEventHandler.swift:781
return .init(location: currentLocation, windowUnderPointer: payload.windowUnderPointer)
```

This is the same edit called for by the sibling discovery's "Gap 2"; landing it
here is what makes Change 1 actually fire on continuous pointer motion rather
than only on fresh (un-coalesced) events.

### Change 3 — snapshot fallback cannot detect click-through (guardrail / scope note)

When the window number truly is absent (synthetic dispatch, non-event-tap
refresh), FFM falls back to `unmanagedWindowServerWindowFramesProvider` →
`visibleUnmanagedWindowServerFrames` (`WMController.swift:2574`, filters
`guard layer == 0` at `:2586`) or, via the broadened probe,
`visibleUnmanagedOverlayWindowServerWindowCovers` (`:2644`, `layer >= 0` at
`:2662`, `.regular`-policy gate at `:2689`). **Neither snapshot path can detect
click-through**, because `CGWindowListCopyWindowInfo` does not expose
`ignoresMouseEvents`. The Borders overlay (layer ≥ 0, ≥ 80 px, `.regular` owner)
would be reported as occluding by the broadened probe.

Implication: Changes 1 + 2 are the actual fix for #64 (the event-tap path is the
one the maintainer reproduced). Change 3 is a **non-goal** here: do **not**
attempt to special-case the snapshot path for click-through (it is unsolvable
from the snapshot alone), and do **not** weaken the broadened overlay probe
(that would regress the Ghostty Quick-terminal / stale-queue cases). If a residual
edge case appears where the number is genuinely unavailable over a Borders
overlay, the acceptable trade-off is to keep FFM firing (better to focus than to
freeze), i.e. have the snapshot fallback treat an unresolvable case as
*not* occluding — but only pursue that if a real repro shows it is needed.

### Why this cannot regress the completed fix or the built-in border

- **Ghostty Quick terminal (interactive overlay):** handles events → `(B)`
  returns the Quick terminal → still classified unmanaged → still suppresses FFM.
  No behaviour change. (Add a regression test for this.)
- **Nehir's own built-in border:** excluded via `ownedWindowRegistry.contains`
  (`WMController.swift:2625`), independent of the field priority. Unaffected.
- **System chrome / Notification Center:** already excluded by the `.regular`
  activation-policy gate (`:2689`) in the broadened probe, and by the fact that
  this change only touches the event-tap window-number resolution, not the
  snapshot predicate. Unaffected.

---

## Tests to add / extend

In `Tests/NehirTests/MouseEventHandlerTests.swift` (extend the existing
FFM-overlay suite; the window-number plumbing is already testable since
`handleMouseMovedFromTap(at:windowUnderPointer:)` takes the number directly):

- **New** `focusFollowsMouseFiresThroughClickThroughOverlay` — pointer over a
  Nehir-managed tile, with an external overlay's window number supplied as
  `windowUnderPointer`, *and* the tile's window number supplied as the
  `ThatCanHandleThisEvent` value (inject via the event / a test seam in
  `windowUnderPointer(from:)`). Assert FFM targets the tile, not suppressed.
  This is the direct regression for #64.
- **Keep-green** `focusFollowsMouseSuppressesOverInteractiveOverlay`
  (Ghostty-equivalent): `windowUnderPointer == canHandle == <overlay id>`,
  overlay not tracked/owned → assert FFM suppressed. Guards the completed fix
  against the priority flip.
- **Keep-green** `focusFollowsMouseNotSuppressedByOwnedPassthroughBorder`:
  built-in border window number is in `ownedWindowRegistry` → assert FFM fires
  on the tile beneath. Guards the built-in-border contrast.
- **New** unit-style for the field-priority reconciliation in
  `windowUnderPointer(from:)` (extract to a pure helper taking `(direct,
  canHandle)` if needed for testability): `direct != canHandle && both > 0` →
  returns `canHandle`; `canHandle == 0 && direct > 0` → returns `direct`;
  both `0` → `nil`.
- **Reuse** the existing `visibleUnmanagedOverlayWindowServerWindowCovers`
  predicate tests (layer ∈ {0, 3, 101, 25}, system-chrome exclusion) — they
  confirm Change 3 is left untouched.

## Files touched (planned)

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` — flip/reconcile field
  priority in `windowUnderPointer(from:)` (`:2067`); preserve `windowUnderPointer`
  in `currentPointerPayload(forQueuedMouseMove:)` (`:781`, shared with sibling
  discovery).
- `Sources/Nehir/Core/Controller/WMController.swift` — **no predicate change
  required** (the occlusion call sites at `MouseEventHandler.swift:1272`,
  `:1347`, `:1433` already route through `unmanagedWindowServerWindowCovers`,
  which is correct once the *input* window number is click-aware).
- `Tests/NehirTests/MouseEventHandlerTests.swift` — tests above.
- `.changeset/<timestamp>-fixed-ffm-blocked-by-click-through-overlays.md` —
  `patch`, user-visible summary: "Focus-follows-mouse now works alongside
  external click-through border/overlay utilities (e.g. the standalone Borders
  app) instead of being suppressed by them."

---

## Relationship to sibling docs

Three symptoms, one actor (a foreground unmanaged overlay), three code paths.
They share the window-number seam and should converge, but each needs its own
input correction:

| Doc | Path | Symptom | Input correction |
|---|---|---|---|
| `completed/20260615-ffm-suppress-over-unmanaged-overlay-windows` | FFM, interactive overlay (fresh event) | focus stolen behind Quick terminal | shipped — reads geometric field, correct *only* for interactive overlays |
| `discovery/20260616-ffm-steals-focus-behind-overlay-on-stale-queued-mouse-moves` | FFM, interactive overlay (coalesced move) | focus stolen behind Quick terminal | wire fallback to broadened probe + keep window number on stale moves |
| **this discovery (#64)** | FFM, **click-through** overlay | FFM does nothing under Borders | key occlusion on `ThatCanHandleThisEvent`, not the geometric field (+ keep window number) |

The natural merge point (called out in all three) is one helper:
"given a `CGEvent`/snapshot, what is the *click-receiving* surface under the
pointer, and is it an unmanaged overlay?" `windowUnderPointer(from:)` is the
right home for that decision; the occlusion predicates in `WMController` should
remain layer/ownership/policy based and simply receive a click-corrected window
number.
