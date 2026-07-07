# OmniWM issue #349 — "Hidden window bleeds into view (multi-monitor)" — Discovery

Source issue: https://github.com/BarutSRB/OmniWM/issues/349
Proposed fix (upstream PR): https://github.com/BarutSRB/OmniWM/pull/364 — "Clamp visible
frames to monitor bounds" (**unmerged upstream**). PR #364's commit message names #349.
Sibling items in the bleed family: #235 (bleed **across workspaces**, see
`noop/20260616-omniwm-235-window-bleed-different-workspace.md`) and #364. This doc keeps to
the **multi-monitor / monitor-bounds** angle; #235's workspace-lifecycle mechanism is
cross-referenced only where root causes touch.

Scope of this doc: determine whether the multi-monitor bleed in #349 applies to nehir,
and whether PR #364's `clampVisibleFramesToMonitorBounds` is needed / safe to port.

All file/line references were verified against the Nehir source tree at
`7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace"). Re-verify
before implementing; line numbers drift.

---

> **Filed under `discovery/noop/`** — the verdict is ⚪ **Won't port / Not applicable**: the
> symptom #349 photographs (a parked/"hidden" window's strip rendering on the *other*
> monitor) and the symptom PR #364 guards against (a *visible* tiled frame overhanging into
> a neighbouring monitor) are both already prevented in nehir by an earlier, stronger
> mechanism than PR #364's clamp. It owns no repo action: PR #364 is not ported, and no
> invariant test is mandated here. The doc is retained for the upstream-symptom record and
> the bleed-family cross-reference (#235). It is the deduped survivor of three concurrent
> drafts — `…-monitor-bounds-clamp-redundant.md` and `…-hidden-window-bleed-multi-monitor.md`
> (singular) were removed as strict/overlapping subsets; the stale-live-frame triage from
> the former is folded in below.

## TL;DR

- **The symptom #349 photographs — a parked/"hidden" window's strip rendering on the
  *other* monitor — and the symptom PR #364 guards against — a *visible* tiled frame
  overhanging into a neighbouring monitor — are both already prevented in nehir by an
  earlier, stronger mechanism than PR #364's clamp: a column whose rendered rect
  overflows its owning monitor into a neighbour is reclassified `.hidden` *at
  classification time*, so the overhanging frame is never emitted into `framePool` at all.**
- **PR #364's `clampVisibleFramesToMonitorBounds` does NOT exist in nehir**
  (`ffgrep` for the symbol across `Sources/Nehir` returns nothing). Porting it is
  **redundant** and would actively **conflict** with nehir's design: it clamps to
  `monitor.frame` (full screen incl. menu bar) where nehir lays out against
  `monitor.visibleFrame`; it `removeValue`s windows from `framePool` on a null
  intersection, which silently drops them from the layout diff rather than parking them;
  and it deliberately skips the very hidden windows the reporter photographed.
- **#349 is a DISTINCT mechanism from nehir's stale-live-frame discoveries.** PR #364
  targets an unclamped *visible* (tiled) frame that overhangs a monitor edge; nehir's
  `20260616-stale-live-frame-on-stably-hidden-column.md` /
  `20260616-workspace-inactive-stale-live-frame.md` are about a window nehir *believes is
  hidden* whose **live AX frame is stale and still on-screen** — a state/cache desync, not
  a geometry overhang. (Comparison table below.)
- **Verdict:** ⚪ **Won't port / Not applicable.** The visible-frame overhang is prevented
  upstream of any clamp by `containerVisibilityState` →
  `overflowEdgeIntersectingNeighboringMonitor` (`NiriLayout.swift:357` / `:378` / `:406`);
  the hidden-window strip is handled by `HiddenWindowPlacementResolver`
  (`SideHiding.swift:71`).

## Provenance: is this nehir's code?

Yes — confirmed independently by symbol search and source read.

- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Animation.swift:228` — nehir's
  `calculateCombinedLayoutUsingPools` is the 1:1 counterpart of OmniWM's
  `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Animation.swift` that PR #364 edits.
  The patched return site is `return (framePool, hiddenPool)` at `:265`; the clamp would be
  inserted just before it (`:264`).
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:357` — `containerVisibilityState`, the
  per-column visibility verdict, is the pipeline the issue is really about.
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:406` —
  `overflowEdgeIntersectingNeighboringMonitor`, the multi-monitor guard.
- `git log -S "overflowEdgeIntersectingNeighboringMonitor"` → present since `9a46877
  "Initial Nehir import"`. The guard is **nehir baseline, not a backport of PR #364**.

The multi-monitor model: each monitor runs its own `calculateCombinedLayoutUsingPools`
keyed on its own `monitor`, but every resulting frame lives in **one global macOS
coordinate space**. macOS does **not** clip a window to a single display, so a frame
straddling monitor 1's right edge physically renders on whichever monitor owns those
global coordinates — that is the bleed. The layout layer must therefore keep each visible
frame inside its owning monitor.

## The code in question

### 1. nehir's layout return — no clamp (this is where PR #364 would insert)

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Animation.swift:228
func calculateCombinedLayoutUsingPools(
    in workspaceId: WorkspaceDescriptor.ID, monitor: Monitor, gaps: LayoutGaps,
    state: ViewportState, workingArea: WorkingAreaContext? = nil,
    animationTime: TimeInterval? = nil
) -> (frames: [WindowToken: CGRect], hiddenHandles: [WindowToken: HideSide]) {
    framePool.removeAll(keepingCapacity: true)
    hiddenPool.removeAll(keepingCapacity: true)
    …
    calculateLayoutInto(                          // :249
        frames: &framePool, hiddenHandles: &hiddenPool, …,
        monitorFrame: monitor.visibleFrame,        // :254  ← layout basis is VISIBLE frame
        screenFrame: monitor.frame,                // :255
        …)
    return (framePool, hiddenPool)                 // :265  ← PR #364 inserts clamp here
}
```

PR #364 (NOT in nehir — `ffgrep clampVisibleFramesToMonitorBounds` is empty) adds, between
`:263` and `:265`:

```swift
// PR #364 — verbatim from https://github.com/BarutSRB/OmniWM/pull/364.diff
clampVisibleFramesToMonitorBounds(monitor.frame)
…
private func clampVisibleFramesToMonitorBounds(_ monitorBounds: CGRect) {
    var toRemove: [WindowToken] = []
    var toUpdate: [(WindowToken, CGRect)] = []
    for (token, frame) in framePool where hiddenPool[token] == nil {   // visible only
        let clamped = frame.intersection(monitorBounds)
        if clamped.isNull {
            toRemove.append(token)                 // ← drops the window entirely
        } else if clamped != frame {
            toUpdate.append((token, clamped))
        }
    }
    for token in toRemove { framePool.removeValue(forKey: token) }
    for (token, rect) in toUpdate { framePool[token] = rect }
}
```

So, as in pre-fix OmniWM, a tiled frame is never intersected with monitor bounds *after*
layout. The question is whether anything **earlier** already keeps visible frames inside
their owner.

### 2. nehir's earlier guard — classify an overflowing column as hidden

In `calculateLayoutInto`, each column's rect is decided by `containerVisibilityState`,
and only a `.visible` verdict emits an unclamped frame:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:266
switch containerVisibilityState(
    for: visibilityRect, viewportFrame: workingFrame,
    fallback: idx == 0 ? .minimum : .maximum, orientation: orientation,
    hiddenPlacementMonitor: hiddenPlacementMonitor,
    hiddenPlacementMonitors: hiddenPlacementMonitors
) {
case .visible:                                     // :272
    renderedContainerRect = visibilityRect         // :273 — unclamped, reached ONLY when no neighbour-overflow
case let .hidden(hiddenEdge):                      // :274
    for window in containerWindowNodes[idx] {
        hiddenHandles[window.token] = hiddenEdge.encodedHideSide  // → hiddenPool, NOT framePool
    }
    renderedContainerRect = hiddenRenderedContainerRect(…)
}
```

The verdict itself is the mitigation:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:357-388
private func containerVisibilityState(…) -> ContainerVisibilityState {
    let defaultHideEdge = hiddenEdge(…)
    guard containerIntersectsViewport(renderedRect, viewportFrame: viewportFrame, orientation: orientation)
    else { return .hidden(defaultHideEdge) }                                    // :376 fully offscreen → park

    if let overflowEdge = overflowEdgeIntersectingNeighboringMonitor(          // :378  THE KEY
        renderedRect, viewportFrame: viewportFrame, orientation: orientation,
        hiddenPlacementMonitor: hiddenPlacementMonitor,
        hiddenPlacementMonitors: hiddenPlacementMonitors)
    {
        return .hidden(overflowEdge)                                            // :385 overflow lands on a neighbour → HIDE whole column
    }
    return .visible                                                              // :387 only reached when no neighbour overflow
}
```

`overflowEdgeIntersectingNeighboringMonitor` (`NiriLayout.swift:406`) slices the part of
the column that sticks out past `viewportFrame` and, for every **non-owning** monitor
(`ownsViewport` at `:515` excludes the layout's own monitor), tests
`overflowRegion.rect.intersects(otherMonitor.frame)`:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:406-428 (abridged)
for overflowRegion in overflowRegions {
    for otherMonitor in hiddenPlacementMonitors
    where !ownsViewport(otherMonitor, hiddenPlacementMonitor: …, viewportFrame: viewportFrame) {
        if overflowRegion.rect.intersects(otherMonitor.frame) {
            return overflowRegion.edge
        }
    }
}
return nil
```

Concrete: two monitors with touching frames — M1 `frame=(0,0,2000,1000)`,
`visibleFrame=(0,37,2000,963)` — and M2 `frame=(2000,0,2000,1000)`. A workspace on M1
scrolled so one wide column renders at `x=1500..2500`: against M1's
`viewportFrame.maxX=2000` its right overflow slice `x=2000..2500` intersects M2's frame
→ the column is `.hidden`, its windows go to `hiddenHandles`/`hiddenPool`, and they are
parked rather than left bleeding. Because `renderedContainerRect = visibilityRect`
(`:273`) is reached only when that test returns `nil`, every frame a `.visible` column
emits is already inside the owner; windows are laid out within their container rect.

### 3. Hidden windows (the reporter's literal symptom) park to minimise cross-monitor overlap

The screenshot shows a **hidden/parked** window's strip bleeding across — not a visible
tiled window. nehir places those via an overlap-minimising resolver:

```swift
// Sources/Nehir/Core/Layout/SideHiding.swift:71  enum HiddenWindowPlacementResolver
//   physicalScreenEdgeOrigin(for size:requestedSide:targetY:baseReveal:scale:monitor:monitors:)
…
// The live frame can still be on the source display when a window is assigned
// directly to an inactive workspace on another display. Try nearby vertical
// parking lanes too, otherwise preserving that source-display Y can leave a
// large strip visible on an adjacent monitor.                                  // :102-103
let yCandidates = verticalParkingCandidates(for: size, targetY: targetY, monitor: monitor, monitors: monitors) // :104
…
let overlap = overlapArea(for: candidateFrame, monitor: monitor, monitors: monitors) // :260 def
```

That comment describes the exact #349 failure mode and is nehir's deliberate guard. The
resolver scores each candidate side × vertical lane by `overlapArea` against **all**
monitors and commits the minimum-overlap origin. PR #364 does nothing for these windows —
it filters `where hiddenPool[token] == nil`.

## Why it doesn't apply (and the fix is unsafe to port)

1. **The visible-frame overhang is prevented before any visible frame is produced.** A
   `.visible` verdict (`NiriLayout.swift:387`) is reachable only if
   `overflowEdgeIntersectingNeighboringMonitor` returns `nil`; a visible column therefore
   provably does not spill onto a neighbour, and frames laid out inside it are bounded.
   PR #364's clamp would be a **no-op** in nehir's normal side-by-side multi-monitor
   arrangement — the condition it guards never arises.

2. **The hidden-window strip (the literal report) is handled by a different path.**
   `HiddenWindowPlacementResolver` tries both hide edges and multiple vertical parking
   lanes, scoring each with `overlapArea` (`SideHiding.swift:260`) against every monitor.
   PR #364 explicitly **excludes** `hiddenPool` windows, so even in OmniWM it cannot address
   the reporter's photographed symptom.

3. **Porting the helper as-is introduces three real hazards:**
   - **Wrong bounds basis.** The PR clamps to `monitor.frame` (full screen, incl. the
     menu-bar strip); nehir lays out against `monitor.visibleFrame`
     (`NiriLayoutEngine+Animation.swift:254`). Clamping to `monitor.frame` would permit
     frames into the menu-bar strip — the opposite of what the layout intends.
   - **Drops windows instead of parking them.** `framePool.removeValue(forKey: token)` on
     a null intersection removes the window from `framePool` but never adds it to
     `hiddenHandles`. Downstream, `layoutDiff` does
     `guard let frame = frames[token] else { continue }` (`NiriLayoutHandler.swift:931`)
     — a window in neither map is skipped entirely: no `.hide`, no frame change, so it is
     left at a **stale** frame. That is the bug, not the fix. nehir's correct behaviour is
     classify-and-park, never drop.
   - **Clamp can't reason about neighbours.** `intersection(monitorBounds)` clips to the
     *owning* monitor, but bleed is a *neighbour*-monitor phenomenon. nehir's classifier
     inspects neighbour frames directly (`NiriLayout.swift:406`), which is exact where the
     PR is heuristic.

4. **Single-monitor is moot.** With one monitor there is no `otherMonitor` whose frame the
   overflow slice can intersect, so an edge-overflowing column stays `.visible` — but there
   is no second display to bleed onto; it is merely clipped by the screen edge. This
   matches the reporter's own caveat ("i dont really tried with one monitor").

## Distinction from the stale-live-frame discoveries (the triage question)

The triage asked whether #349 is the SAME root cause as "a stale/live frame drawn for a
window not on the active monitor." It is **not**:

| | OmniWM #349 / PR #364 | nehir stale-live-frame discoveries |
|---|---|---|
| Window's logical state at layout time | **Visible** (tiled column) | **Hidden** (`layoutTransient` or `workspaceInactive`) |
| What is wrong | Computed **visible frame** geometrically overhangs the monitor edge | **Live AX frame** is stale / never advanced to the park slot |
| Layer | Layout geometry (no monitor-bounds clamp) | State/cache desync + park-write failure |
| Where the fix lives | `calculateCombinedLayoutUsingPools` post-pass clamp | `resolveHideOperation` reconciliation / hide-park robustness |
| Does the other's fix help? | Clamp skips `hiddenPool` windows → useless for stale frames | Reconciliation only runs on transitions → useless for an unclamped *visible* frame |

The shared thing is only the **user-visible symptom** ("a hidden/inactive-looking window's
pixels appear on another monitor"). nehir's overflow→hide ensures the *layout-geometry*
half of that symptom cannot happen; any remaining occurrence in nehir is the
*stale-live-frame* half, owned by `20260616-stale-live-frame-on-stably-hidden-column.md`
and `20260616-workspace-inactive-stale-live-frame.md`.

## Relationship to the bleed family (#235, #364)

The catalog groups three items by symptom — a "hidden" window's pixels appearing where
they should not. Their **mechanisms differ**, so they must not share a fix:

- **#349 (this doc) / #364** — a **geometry** problem: a frame straddling a monitor
  boundary in global coordinate space. Addressed in nehir by neighbour-overflow
  classification (`NiriLayout.swift:378`) + overlap-minimised parking (`SideHiding.swift`).
- **#235** — a **workspace visibility / lifecycle** problem (bleed *across workspaces*,
  not monitors). Filed under `noop/` as a duplicate of the workspace-inactive
  stale-live-frame discovery. Do **not** fold its fix into a monitor-bounds clamp; if nehir
  ever shows a #235-style symptom, route it to workspace visibility work, not PR #364.

## Recommendation

- **Do not port PR #364.** Unmerged upstream, redundant with nehir's
  `overflowEdgeIntersectingNeighboringMonitor` guard, and its semantics (clamp to
  `monitor.frame`, drop on null intersection) conflict with nehir's basis
  (`monitor.visibleFrame`, park-don't-drop).
- **No repo action mandated here.** nehir's invariant — "a tiled column whose rendered
  rect overflows its owning monitor into a neighbouring monitor's frame is classified
  `.hidden`, never emitted as a visible frame" — already holds at the visibility verdict
  (`NiriLayout.swift:357`). It is not asserted via a post-hoc clamp.
- **Residual edge case to monitor:** if a hidden window is larger than every parking lane,
  `HiddenWindowPlacementResolver` still commits the minimum-overlap origin, so a sliver
  could remain in an extreme case. PR #364 cannot help (hidden windows excluded). If #349
  ever reproduces in nehir, investigate the resolver path (parking policy / guaranteed
  gap), not a visible-frame clamp.
- **If a multi-monitor bleed is reproduced**, capture the offending window's hidden reason,
  its `lastApplied` frame, and its live AX frame, and check whether it is a
  parked-but-stale window (the stale-live-frame family) rather than an unclamped visible
  frame.

## Suggested tests (not mandated — no repo action)

These would lock in nehir's *own* mitigation (not PR #364's clamp):

1. **Neighbour-overflow column is hidden, not clipped.** Two fake monitors with touching
   frames (M1 `frame=(0,0,2000,1000)`, M2 `frame=(2000,0,2000,1000)`), a workspace on M1
   with one wide column. Scroll so the column's rendered rect is `x=1500..2500` (overhangs
   M2). Assert the column's windows are in `hiddenHandles`, **absent** from `frames`, and
   that `frames` contains no rect intersecting M2's frame.
2. **In-monitor column stays visible and bounded.** Same fixture; scroll so the column is
   `x=500..1500` (fully inside M1). Assert the window is in `frames` and its frame lies
   entirely within M1's `visibleFrame`.
3. **Single-monitor overflow does not hide.** One monitor; scroll a column past the right
   edge (`maxX > monitor.frame.maxX`). Assert it stays `.visible` (no neighbour to trigger
   the hide) — documents that the hide is specifically a *multi-monitor* behaviour, not a
   general edge clamp.
4. **Hidden windows never carry a frame into a neighbour.** Construct a layout where a
   column is hidden via neighbour-overflow; assert its hidden tokens are excluded from
   `frames` and that `HiddenWindowPlacementResolver` returns an origin with
   `overlapArea(…) == 0` against all other monitors when geometry permits.
5. **No window is dropped from the diff.** For a window whose computed frame lies outside
   `monitor.frame`, assert `layoutDiff` still emits either a `.hide` directive or a frame
   change — never silence. (This is the regression PR #364's `removeValue` would
   introduce.)
