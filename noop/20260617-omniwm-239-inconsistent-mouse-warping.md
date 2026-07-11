# BarutSRB/OmniWM#239 — "Inconsistent mouse warping (multi-mon)" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/239>
Scope of this doc: determine whether the symptom reproduces in nehir — on two
identical 2560×1440 HiDPI monitors, slowly crossing the boundary lands the warped
cursor "lower than expected" main→secondary and "sometimes higher" — and whether
any fix is needed.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

> **Filed under `discovery/noop/`** — nehir warps via a **normalized-ratio
> transfer**: the cursor's relative position along the non-crossing axis is
> mapped from source frame to destination frame and clamped. For the reporter's
> identical monitors this reduces to an **exact 1:1** landing (destination y ==
> source y), so the "lower/higher than expected" inconsistency cannot occur.
> OmniWM's symptom is the signature of a buggy/absolute mapping that nehir does not
> have. No fix to port.

---

## TL;DR

- **nehir computes a normalized ratio on the non-crossing axis and reapplies it
  to the destination frame, then clamps.** For two identical monitors the ratio
  math collapses to `dest == source`, i.e. no vertical drift — the cursor lands
  exactly where it left, which is the consistent, expected behavior BarutSRB/OmniWM#239 wants.
- **Verdict:** 🟢 **Fixed.** The reported inconsistency does not reproduce.

## Issue context

- **State:** closed `not_planned`; no merged fix, no diff to port.
- **Symptom (verbatim):** "Where both monitors are 2560x1440 with HiDPI, mouse
  warping is inconsistent across the monitor boundary. … slowing it down
  sometimes the mouse will show up lower than expected when transitioning from
  main -> secondary, and sometimes it will show up higher than expected."
- **Expected:** "work how MacOS would natively handle this transition" — i.e.
  proportional, consistent positional transfer.

## Provenance: is this nehir's code?

Yes — same subsystem as BarutSRB/OmniWM#206 (`MouseWarpHandler`, axis-dispatched). The
transfer-ratio and destination computation are in
`Sources/Nehir/Core/Controller/MouseWarpHandler.swift`:
`mouseWarpCalculateYRatio`/`mouseWarpCalculateXRatio`,
`mouseWarpDestinationPoint(on:edge:transferRatio:axis:margin:)`, and
`mouseWarpClampMappedCoordinate`.

## The code in question

**The ratio is the cursor's normalized position on the non-crossing axis:**

```swift
// Sources/Nehir/Core/Controller/MouseWarpHandler.swift  (mouseWarpCalculateYRatio / XRatio)
private func mouseWarpCalculateYRatio(_ point: CGPoint, in frame: CGRect) -> CGFloat {
    guard frame.height > 0 else { return 0.5 }
    return (frame.maxY - point.y) / frame.height
}
private func mouseWarpCalculateXRatio(_ point: CGPoint, in frame: CGRect) -> CGFloat {
    guard frame.width > 0 else { return 0.5 }
    return (point.x - frame.minX) / frame.width
}
```

**The destination reapplies that ratio to the destination frame and clamps
(horizontal axis → y is the transferred coordinate):**

```swift
// Sources/Nehir/Core/Controller/MouseWarpHandler.swift  (mouseWarpDestinationPoint, .horizontal)
let clampedRatio = min(max(transferRatio, 0), 1)
...
let y = mouseWarpClampMappedCoordinate(
    frame.maxY - (clampedRatio * frame.height),   // ← destination y from ratio
    minCoordinate: frame.minY,
    maxCoordinate: frame.maxY
)
return CGPoint(x: x, y: y)

// Sources/Nehir/Core/Controller/MouseWarpHandler.swift  (mouseWarpClampMappedCoordinate)
guard minCoordinate < maxCoordinate else { return minCoordinate }
return min(max(value, minCoordinate), maxCoordinate.nextDown)   // keep strictly inside the frame
```

**The ratio is fed from the cursor's live position at the crossing
(`mouseWarpAttemptHorizontalWarp`):**

```swift
// Sources/Nehir/Core/Controller/MouseWarpHandler.swift
let yRatio = mouseWarpCalculateYRatio(location, in: frame)
mouseWarpToMonitor(named: effectiveOrder[rightIndex], edge: .left, transferRatio: yRatio, axis: .horizontal, ...)
```

## Why the bug does not apply (nehir is a clean ratio transfer)

1. **For identical monitors the transfer is exact.** With source and destination
   frames sharing `minY`/`maxY`/`height` (two 2560×1440 panels at the same
   vertical extent), substituting the ratio:
   `yRatio = (maxY − point.y)/height`, and
   `destY = maxY − yRatio·height = maxY − (maxY − point.y) = point.y`.
   The cursor lands at **exactly** the same `y` it had on the source — there is
   no "lower" or "higher" drift. This is the consistent behavior BarutSRB/OmniWM#239 asks for.

2. **Non-identical monitors get correct proportional transfer.** When the
   destination frame differs, `destY = destMaxY − yRatio·destHeight` maps the
   relative vertical position proportionally — the macOS-like behavior the
   reporter wants — rather than an absolute copy or an off-by-margin jump.

3. **Edge/margin effects do not perturb the transferred axis.** The `margin`
   offsets only the *entry* coordinate on the crossing axis (e.g. `x` for a
   horizontal warp: `x = frame.minX + margin + 1`); the transferred coordinate
   (`y`) is derived purely from the ratio and clamped strictly inside the frame
   (`mouseWarpClampMappedCoordinate` → `… maxCoordinate.nextDown`). So there is
   no margin-induced vertical inconsistency.

4. **Nothing to port.** The issue is `not_planned` with no upstream fix, and
   nehir's ratio transfer is the correct structure for the requested behavior.

## Recommendation

**Do nothing / do not port.** Keep the normalized-ratio transfer as the owner for
consistent warping. If a future report shows vertical drift between identical
monitors, the investigation target is a regression that replaced the ratio math
with an absolute/margin-based mapping in `MouseWarpHandler` — not a missing
guard.

## Suggested tests

- Two identical frames (same minX/maxX/minY/maxY): for a set of source `point.y`
  values across the height, assert `mouseWarpDestinationPoint(...).y == point.y`
  (within float epsilon), locking in exact 1:1 transfer.
- Two frames of differing heights: assert the destination `y` equals
  `destMaxY − ((srcMaxY − point.y)/srcHeight)·destHeight` (proportional), and
  that it is strictly within `[destMinY, destMaxY)` after the clamp.
