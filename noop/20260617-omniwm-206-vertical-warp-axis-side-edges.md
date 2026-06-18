# OmniWM issue #206 — "Second monitor left/right sides inaccessible (warp)" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/206>
Scope of this doc: determine whether the symptom reproduces in nehir — with the
**vertical** Warp Axis on a 2-monitor setup, moving the mouse to the left/right
sides of the second monitor teleports it to the main screen (i.e. the warp fires
on the wrong, horizontal, axis) — and whether any fix is needed.

All file/line references were verified against worktree `worktree-calm-meadow-6229`
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

> **Filed under `discovery/noop/`** — nehir's monitor-warp is **strictly
> axis-dispatched**: the vertical path tests only the vertical (`y`) edges, the
> horizontal path tests only the horizontal (`x`) edges, and a cross-axis
> predicate gates entry on the matching axis only. So with a vertical warp axis,
> crossing the left/right sides of any monitor does **not** warp — the exact
> opposite of #206. The bug does not reproduce; no fix to port.

---

## TL;DR

- **nehir never tests the horizontal (`x`) edges under a vertical warp axis.**
  `mouseWarpAttemptVerticalWarp` checks only `location.y` (top/bottom); the
  horizontal (`x`) sides are ignored. There is no shared "any edge" path that
  could mis-fire on the wrong axis.
- **Verdict:** 🟢 **Fixed.** The wrong-axis warp described in #206 cannot occur.

## Issue context

- **State:** closed `not_planned` (labeled `bug`); no merged fix, no diff to port.
- **Symptom (verbatim):** "I have connected 2nd monitor, have vertical Warp Axis
  setting on. When I move mouse on it sides mouse teleports to main screen."
  (i.e. left/right edge crossing of the 2nd monitor wrongly triggers an
  inter-monitor warp under a vertical axis.)

## Provenance: is this nehir's code?

Yes. nehir ships a first-class, axis-aware monitor-warp subsystem:

- `MouseWarpAxis` — `Sources/Nehir/Core/Config/MouseWarpAxis.swift:3`
  (`.horizontal` / `.vertical`), including axis-correct monitor ordering
  (`sortedMonitors`, `primaryCoordinate`/`secondaryCoordinate`).
- `MouseWarpHandler` — `Sources/Nehir/Core/Controller/MouseWarpHandler.swift`,
  the edge-crossing detector and warper, enabled via
  `WMController.syncMouseWarpPolicy` (multi-monitor only).
- Settings: `mouseWarpAxis` (`SettingsStore.swift:40`, default `.horizontal`) and
  `mouseWarpMonitorOrder` (`SettingsStore.swift:36`).

## The code in question

**The dispatch is by axis — only one axis's attempt ever runs:**

```swift
// Sources/Nehir/Core/Controller/MouseWarpHandler.swift:269
switch axis {
case .horizontal:
    let attemptedWarp = mouseWarpAttemptHorizontalWarp(from: currentMonitor, sourceIndex: currentIndex, location: location, in: effectiveOrder, monitors: monitors, margin: margin)
case .vertical:
    let attemptedWarp = mouseWarpAttemptVerticalWarp(from: currentMonitor, sourceIndex: currentIndex, location: location, in: effectiveOrder, monitors: monitors, margin: margin)
}
```

**Vertical path tests ONLY `location.y` (top/bottom) — `location.x` is never
read:**

```swift
// Sources/Nehir/Core/Controller/MouseWarpHandler.swift:430  (mouseWarpAttemptVerticalWarp)
let frame = sourceMonitor.frame

if location.y >= frame.maxY - margin {            // top edge only
    let upperIndex = sourceIndex - 1
    ...
    mouseWarpToMonitor(named: effectiveOrder[upperIndex], edge: .bottom, transferRatio: xRatio, axis: .vertical, ...)
    return true
}
if location.y <= frame.minY + margin {            // bottom edge only
    let lowerIndex = sourceIndex + 1
    ...
    mouseWarpToMonitor(named: effectiveOrder[lowerIndex], edge: .top, transferRatio: xRatio, axis: .vertical, ...)
    return true
}
return false
```

**Horizontal path, for contrast, tests ONLY `location.x`:**

```swift
// Sources/Nehir/Core/Controller/MouseWarpHandler.swift:386  (mouseWarpAttemptHorizontalWarp)
if location.x <= frame.minX + margin { ... edge: .right ... }   // left edge only
if location.x >= frame.maxX - margin { ... edge: .left  ... }   // right edge only
```

**Cross-axis predicate also keyed to the matching axis:**

```swift
// Sources/Nehir/Core/Controller/MouseWarpHandler.swift:339  (mouseWarpLocationCrossedAxis)
switch axis {
case .horizontal: location.x < monitor.frame.minX || location.x >= monitor.frame.maxX
case .vertical:   location.y < monitor.frame.minY || location.y >= monitor.frame.maxY
}
```

## Why the bug does not apply (nehir is axis-correct)

1. **No wrong-axis edge can fire.** Under `.vertical`, the only attempt function
   invoked is `mouseWarpAttemptVerticalWarp`, whose two guards are purely on
   `location.y` (`MouseWarpHandler.swift:436` and `:448`). Moving the cursor to
   the left/right sides of the second monitor changes `location.x` only; neither
   guard can be satisfied, so `mouseWarpToMonitor` is never called and no warp
   occurs. This is precisely the behavior #206 expects (no teleport on the
   sides).

2. **The cross-axis predicate reinforces it.** `mouseWarpLocationCrossedAxis`
   returns `true` for `.vertical` only when `location.y` exits the frame
   (`MouseWarpHandler.swift:344`), so the "monitor changed via axis crossing"
   bookkeeping that short-circuits the handler likewise ignores horizontal
   crossings.

3. **Nothing to port.** The issue is `not_planned` with no upstream fix, and
   nehir's axis split is the correct structure; there is no shared edge path to
   "fix."

## Recommendation

**Do nothing / do not port.** Keep the axis-dispatched attempt functions as the
owner for correct warp behavior. If a future report shows a vertical-axis warp
firing on a horizontal crossing, the investigation target is a regression that
re-introduced a shared/axis-agnostic edge check in `MouseWarpHandler` — not a
missing guard, which is already in place.

## Suggested tests

- Two monitors, `mouseWarpAxis = .vertical`: drive the cursor to `x = frame.minX
  + 1` and `x = frame.maxX - 1` (left/right sides) of the second monitor; assert
  `mouseWarpToMonitor` is never called and the cursor is not warped.
- Same setup: drive the cursor to `y = frame.maxY - 1` (top edge) of the lower
  monitor; assert it warps to the upper monitor at `edge: .bottom`. This locks in
  that vertical warps still work on the correct axis.
