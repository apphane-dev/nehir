# Require axis dominance when picking the directional adjacent monitor

Verified against main `3056bee8` on 2026-07-14. **Re-verify line numbers before
editing; they drift.**

**Status:** planned.
**Symptom:** With two displays stacked roughly vertically but **horizontally
offset** (e.g. a laptop below and to the left of an external), a horizontal
directional command (focus/move monitor left/right) at a workspace edge can jump
to the display that is really *above/below*, because that display also has a
nonzero horizontal offset. Reported upstream as
`BarutSRB/OmniWM#457` (stacked-monitor focus across edge) and fixed by commits
`e1ec597c` / `17f4872d`.
**Desired behavior:** a left/right command only considers a monitor whose
horizontal offset dominates its vertical offset (and vice-versa for up/down). A
diagonally-offset stacked monitor is not eligible for the perpendicular axis.

Root cause and cross-references: see
[`discovery/20260714-upstream-post-roadmap-candidates.md`](../discovery/20260714-upstream-post-roadmap-candidates.md).

## Root cause (inline recap — confirmed in source)

`WorkspaceManager.adjacentMonitor(from:direction:wrapAround:)` filters candidate
monitors purely on the **sign** of the offset delta:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3714-3723
let directional = others.filter { candidate in
    let delta = monitorDelta(from: current, to: candidate)
    switch direction {
    case .left:  return delta.dx < 0
    case .right: return delta.dx > 0
    case .up:    return delta.dy > 0
    case .down:  return delta.dy < 0
    }
}
```

Any monitor with a nonzero horizontal component is eligible for left/right even
when its vertical component is much larger (it is really above/below). The
subsequent `bestMonitor(in:...)` only *ranks* the already-eligible set
(`WorkspaceManager.swift:3807-3832`), so it cannot reject a wrongly-eligible
stacked display.

## Fix — add axis-dominance to the eligibility filter

This is the exact upstream change (`e1ec597c`), one guard per case: the
requested-axis delta magnitude must be at least the perpendicular-axis
magnitude.

### Step 1 — gate on axis dominance

File: `Sources/Nehir/Core/Workspace/WorkspaceManager.swift`, function
`adjacentMonitor(from:direction:wrapAround:)`, the `directional` filter
(~`:3714-3723`).

```swift
let directional = others.filter { candidate in
    let delta = monitorDelta(from: current, to: candidate)
    switch direction {
    case .left:  return delta.dx < 0 && abs(delta.dx) >= abs(delta.dy)
    case .right: return delta.dx > 0 && abs(delta.dx) >= abs(delta.dy)
    case .up:    return delta.dy > 0 && abs(delta.dy) >= abs(delta.dx)
    case .down:  return delta.dy < 0 && abs(delta.dy) >= abs(delta.dx)
    }
}
```

Notes:
- `>=` (not `>`) so a perfectly diagonal (`|dx| == |dy|`) monitor stays eligible
  on both axes, matching upstream; the tie is then resolved by the existing
  `bestMonitor` ranking.
- Leave the `wrapAround` branch, `bestMonitor`, `wrappedMonitor`, and
  `monitorDelta` untouched — the fix is only the eligibility predicate.

### Step 2 — regression test

File: `Tests/NehirTests/WorkspaceManagerTests.swift` — co-locate with the
existing `adjacentMonitorPrefersClosestDirectionalCandidate` (`:702`) and
`adjacentMonitorWrapsToOppositeExtremeWhenNoDirectionalCandidate` (`:717`) tests;
reuse their monitor-construction helpers.

Add a test named e.g. `adjacentMonitorIgnoresVerticallyStackedOffsetMonitor`:

- Build two monitors: `current` at the bottom-left, `stackedAbove` positioned
  mostly **above** but with a smaller horizontal offset (so `|dy| > |dx| > 0` —
  the exact diagonal-offset condition; e.g. current origin `(0, 0)` size
  `1512×982`, other origin `(300, 1000)` size `1920×1080`, giving a positive
  `dx` and a larger positive/negative `dy` depending on Nehir's y convention —
  compute from `monitorDelta` so the vertical magnitude dominates).
- Assert `adjacentMonitor(from: current.id, direction: .right)` is **nil**
  (or, with `wrapAround: false`, not the stacked monitor) — today it wrongly
  returns the stacked monitor.
- Assert `adjacentMonitor(from: current.id, direction: .up)` **does** return the
  stacked monitor (dominant axis is vertical), proving the guard did not break
  legitimate up/down routing.

Confirm the sign of `dy` against `monitorDelta`'s convention before hard-coding
expectations (Nehir's coordinate y-orientation determines whether "above" is
`dy > 0` or `< 0`). Keep the existing two tests unchanged and green — they use
axis-clean layouts and must still pass.

## Do-not-touch fences

- Do **not** modify `monitorDelta`, `bestMonitor`, `wrappedMonitor`, or the
  `wrapAround` fallback.
- Do **not** change `adjacentMonitor`'s signature or its callers
  (`WorkspaceNavigationHandler.swift:264`, `:1027`).
- Do **not** touch any other file. This change is one source file plus one test
  addition (and a changeset).

## Gate

- **Between steps (fast):** `mise run build`. Optionally `mise run format:check`
  + `mise run lint`.
- **Once at the end (full):** `mise run check`. The new test must pass and the
  existing `WorkspaceManagerTests` / `WorkspaceNavigationHandlerTests` must stay
  green.

## Changeset (required — user-visible bug fix)

```bash
mise run changeset patch "Stop directional monitor focus/move from jumping to a vertically stacked but horizontally offset display when moving left/right at a workspace edge"
```

## Commit message shape

```
Require axis dominance for directional adjacent-monitor selection

adjacentMonitor accepted any display with a nonzero offset on the requested
axis, so a vertically stacked but horizontally offset monitor was eligible for
left/right and could be chosen at a workspace edge. Require the requested-axis
delta to be at least the perpendicular delta before a monitor is a directional
candidate.

Ports BarutSRB/OmniWM@e1ec597c (and its coverage in @17f4872d); addresses
BarutSRB/OmniWM#457.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

## Completion token

On success, after the full gate is green, print exactly:

`PLAN_DONE_directional_monitor_axis_dominance`
