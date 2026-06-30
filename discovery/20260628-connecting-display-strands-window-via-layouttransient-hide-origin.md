# Discovery: connecting a display strands a workspace-1 window on it

Status: root cause found and source-confirmed. The capture exposes a real
user-visible bug — an external app window renders on a newly-connected display
while still assigned to its original workspace — plus, separately, a trace-fidelity
limitation in the viewport-mutation audit this branch added. The user-visible bug
is a **new trigger** (external-display connect) for the transient-park-onto-
neighbour defect already characterised in
`discovery/20260625-park-invisible-horizontal-second-monitor.md`; this doc adds
the topology-change angle and the per-capture evidence, it does not re-derive the
strategy.

Validated against the `patch/unrecorded-viewport-offset-mutation-attribution`
branch on 2026-06-28. Source paths are repository-relative.

## Summary

Connecting an external display (DELL P2423D, placed to the left at
`frame=(-2560.0, -111.0, 2560.0, 1440.0)`) triggered a relayout on workspace 1
that hid one of its tiled Helium windows (pid 13175, windowId 353) via the
`.layoutTransient` hide path. The hide origin resolver parked it at
`x = -971`, which is **inside** the newly-connected display's frame
(`-2560..0`). macOS accepted the move (the coordinate is "on a display," so the
offscreen clamp never fires), and the window rendered fully on the external
display. It remained there in the end-of-capture state, visible but no longer
tracked by Nehir's managed set.

This is the maintainer's stated symptom verbatim — "helium is displayed on second
display while it still assigned on ws 1." It is not a workspace-attribution or
focus bug; the window stays assigned to workspace 1. It is a **hide-origin
targeting bug**: the `.layoutTransient` park formula computes the target from the
*owning* monitor's frame only, ignoring every other monitor, so a park onto the
"left" edge lands on whatever monitor now occupies the space to the left.

The same capture separately shows the viewport-offset-mutation audit (the feature
this branch added) collapse two intermediate offset mutations into one trace
record. That is a trace-fidelity limitation, not a cause of the user-visible bug,
and is documented in the second half of this doc.

## Primary finding — hide-origin strands a window on a connected display

### Evidence (inlined)

External display connection:

```text
event=topology_changed displays=2 plan=topology=1->2 visible_assignments=1 restore_refresh=topology
-- Monitor Topology (end of capture) --
ID(displayId: 1) isMain=true  name=Built-in Retina Display frame=(0.0, 0.0, 2056.0, 1329.0)
ID(displayId: 3)              name=DELL P2423D          frame=(-2560.0, -111.0, 2560.0, 1440.0)
```

Workspace UUIDs: `workspace=1 id=3EE87D81-...062D`, `workspace=6 id=AE84439A-...2476`.

The hide sequence for the workspace-1 Helium window (windowId 353) at the
connection moment:

```text
hideOrigin.resolve experiment=physicalEdge1pt reason=layoutTransient side=left
    placement=(2056,32) result=(-971,32) frame=(181,32 972x1226)
    monitorFrame=(0,0 2056x1329) visibleFrame=(0,0 2056x1290)
hidePlan.apply id=353 requestedOrigin=(-971,32) frameSize=972x1226
SkyLight.move id=353 displayHint=1 appKitOrigin=(-971,32)
    heuristicTransform=display=3 appKit=-2560,-111,2560,1440 ...
                       display=1 appKit=0,0,2056,1329 ...
hidePlan.final id=353 requested=(-971,32 972x1226) observed=(-971,32 972x1226) fallback=YES verified=false
```

End-of-capture state — the window is stranded on display 3, unmanaged:

```text
-- Visible Unmanaged WindowServer Windows --
windowId=353 pid=13175 owner=Helium frame={{-971.0, 83.0}, {972.0, 1226.0}}
```

Three facts make the mechanism unambiguous:

1. The park **succeeded** (`observed=(-971,32)` equals `requested=(-971,32)`).
   This is *not* a reconciliation or frame-leak issue — Nehir did not fail to
   move the window or undo its own move. Nehir moved it exactly where the
   resolver told it to.
2. The resolver computed `-971` from `monitor.frame.minX - width + reveal` =
   `0 - 972 + 1`, against workspace 1's *own* monitor (display 1, frame
   `0..2056`). It never consulted the fact that display 3 now occupies
   `-2560..0`.
3. `-971` is on display 3, so the window is not offscreen, so the macOS
   offscreen-position clamp (documented in `docs/window-parking-and-offscreen-clamp.md`) does
   not fire. `SkyLight.move` resolved it onto display 3
   (`heuristicTransform=display=3`).

### Source — the `.layoutTransient` result ignores all other monitors

`Sources/Nehir/Core/Controller/LayoutRefreshController.swift`

- `:2981` `liveFrameHideOrigin(...)`.
- `:3027` computes the overlap-aware placement:

```swift
let placement = HiddenWindowPlacementResolver.placement(
    for: frame.size,
    requestedEdge: requestedEdge,
    ...,
    monitor: hiddenPlacementMonitor,
    monitors: resolvedHiddenPlacementMonitors   // knows about display 3
)
```

- `:3040-3060` then **discards** `placement` and computes `result` from the own
  monitor's frame only, parking on the *requested* edge:

```swift
// ...comment: "explicit 1pt parking on the physical screen edge ... not a
//             complete WindowServer hide primitive"
let reveal: CGFloat = Self.hiddenWindowEdgeRevealEpsilon
let result: CGPoint = switch orientation {
case .horizontal:
    switch requestedEdge {                 // ← requestedEdge, ignores placement.resolvedEdge
    case .minimum:
        CGPoint(x: monitor.frame.minX - frame.width + reveal, y: orthogonalOrigin)   // 0 - 972 + 1 = -971
    case .maximum:
        CGPoint(x: monitor.frame.maxX - reveal, y: orthogonalOrigin)
    }
...
}
```

`resolvedHiddenPlacementMonitors` (the full monitor list, including display 3) is
available in scope but is **never read** by the `result` formula. `placement` is
computed solely to populate the trace string (`:3064`). The neighbouring-monitor
overlap data that the `.workspaceInactive` path uses (see below) is right there
and unused.

### Contrast — the `.workspaceInactive` path already solves this

`Sources/Nehir/Core/Layout/SideHiding.swift`

- `:78` `physicalScreenEdgeOrigin(...)` (used by `.workspaceInactive` /
  `.scratchpad` via `liveFrameHideOrigin :2988-3006`) **does** minimise
  `overlapArea` across every monitor in the `monitors:` list, tries both sides ×
  multiple vertical lanes, and commits the lowest-overlap origin. On this exact
  topology it would score the left park (`x=-971`) as ~971px overlap with display
  3 and the right park (`x=2055`) as zero overlap, and pick the right edge.
  Workspace-inactive windows therefore do not strand on a connected display;
  `.layoutTransient` windows do.

This is the same path-split documented in
`discovery/20260625-park-invisible-horizontal-second-monitor.md` §A.3/A.4. The
predecessor doc covers the **stable two-monitor, scroll-towards-neighbour**
trigger in full. What this capture adds is the **topology-change** trigger: the
display connects, workspace 1 collapses toward a lone window, a column is hidden
`.layoutTransient` `side=left`, and the park target — computed *after* Nehir
already knows about display 3 — lands on display 3 because the formula never
looks past the own monitor.

## Can the user-visible bug be fixed? — honest ceiling

**Reduced, yes; reached zero, no — not without the virtual-display spike.** This
is the clamp ceiling, not a coordinate bug we can arithmetic our way past. See
`discovery/20260625-park-invisible-horizontal-second-monitor.md` §B/§D for the
full strategy; the parts that bear on *this* capture:

- **Cheap reduction (doable now):** if the requested hide edge borders another
  display, park on the source monitor's non-neighbour edge using the overlap
  resolver's alternate edge. For this capture, `side=left` no longer parks at
  `x=-971` (inside display 3); it parks at the source display's opposite edge
  (`x=2055` for the built-in display spanning `0..2056`). This can visibly pop
  the hidden column to the other side of the source display and can still leave a
  clamp strip, but it avoids moving the window into another display/Space region.
  Same-direction row-edge parking was tried and rejected by the real repro trace:
  a workspace-1 window parked at `x=-3531` with `hidden:left` was later logged as
  a normal workspace-6/display-3 tile.
- **True zero:** requires the virtual-display approach (#17), gated on the
  unverified hypothesis H1 in
  `discovery/20260621-virtual-display-park-offscreen-windows.md`. No coordinate
  trick defeats the macOS clamp; only parking *inside* new (virtual) display
  space is known to.
- **Reconciliation prerequisites do not apply to this capture.** The park here
  succeeded (`observed==requested`), so the B.1 reconciliation fixes
  (`planned/20260625-inactive-workspace-frame-writes-leak.md` and the two
  stale-live-frame discoveries) — which fix cases where Nehir fails to move or
  undoes a move — are not on the critical path for *this* symptom. They remain
  mandatory for the broader hide-correctness story.

So: the defect is fully understood and a strict improvement is cheap, but per the
clamp-doc pitfall no doc may claim the strand-on-connected-display is "fixed"
until the source-monitor non-neighbour-edge reduction is validated in the real
repro or a Separate-Spaces-native park primitive is proven.

## Separate Spaces follow-up — 1px seam parking is not reachable by geometry alone

A live no-Nehir probe on 2026-06-28 refined the strategy for users with
**Displays have separate Spaces** enabled. The important result is that geometry
and native Space ownership can disagree, but only until the window centre crosses
the display seam.

Probe topology:

```text
SLSGetSpaceManagementMode = 1
Built-in Retina Display: frame=(0,0,2056,1329), active native Space 5
DELL P2423D:             frame=(-2560,-111,2560,1440), active native Space 65
```

A sacrificial Helium window had `windowId=2882`, `pid=13175`,
`frame=(-1198,39 1224x1226)`, and `SLSCopySpacesForWindows=[5]`. This proves
that, with Separate Spaces enabled, a window may geometrically straddle the seam
while remaining owned by the source display's native Space. Moving that same
window via AX produced this threshold:

```text
x=-1    -> spaces=[5]
x=-8    -> spaces=[5]
x=-16   -> spaces=[5]
x=-32   -> spaces=[5]
x=-64   -> spaces=[5]
x=-128  -> spaces=[5]
x=-256  -> spaces=[5]
x=-512  -> spaces=[5]
x=-612  -> spaces=[5]
x=-613  -> spaces=[65]
x=-971  -> spaces=[65]
x=-1223 -> spaces=[65]
```

For a `1224px`-wide window, `x=-612` places the centre exactly on the seam
(`x + width/2 = 0`) and remains source-owned; `x=-613` crosses the centre one
pixel into the neighbour and flips to the neighbour Space. Therefore a desired
"1px visible on the source display only" park (`x = -width + 1`, here
`x=-1223`) is **not reachable by geometry-only AX movement**. It lands in
`spaces=[65]`, which is the wrong display/Space for this bug.

Additional live probes tried the obvious non-geometry escape hatches:

```text
SLSMoveWindowsToManagedSpace / CGSMoveWindowsToManagedSpace: returned/called but spaces stayed [65]
SLSAddWindowsToSpaces + SLSRemoveWindowsFromSpaces: returned success but spaces stayed [65]
SLSSpaceSetCompatID + SLSSetWindowListWorkspace (Sonoma 14.5+ workaround): SLSSetWindowListWorkspace returned 1006; spaces stayed [65]
CGSMoveWorkspaceWindowList: returned 1006; spaces stayed [65]
CGSSpaceAddWindowsAndRemoveFromSpaces: called but spaces stayed [65]
AX resize to width=2: AX returned success, observed size remained 1224x1226
SLSSetWindowAlpha / SLSSetWindowOpacity: returned success, CG alpha remained 1
SLSSetWindowShape with a 1px strip: returned success, captured window alpha bounds were unchanged
Direct SLSMoveWindow from the probe process: returned success but did not move the app window
```

Implication: the ideal Separate-Spaces-native target remains: keep the hidden
window on its source native Space while allowing deep seam geometry. But the live
evidence says Nehir cannot get to the 1px seam position with plain frame writes,
and the later real-repro trace showed same-direction row-edge parking can be
adopted into workspace 6. Until a working native-Space reassignment primitive and
logical-workspace guard exist, row-edge parking is rejected. The current degraded
reduction parks on the source monitor's non-neighbour edge when the requested
edge borders another display.

## Secondary finding — the offset-mutation audit collapses intermediate steps

The branch this capture was taken on (`patch/unrecorded-viewport-offset-mutation-
attribution`) added a per-mutation audit: `ViewportState.lastViewportMutation*`
and a `relayout.viewportOffsetChanged` trace record. The capture shows a
limitation of that audit. **This did not cause the user-visible bug above** — the
two findings co-occur in one relayout under unrelated mechanisms — but it is
worth recording because it makes the trace misleading when debugging real
viewport behaviour.

### Evidence (inlined)

Committed viewport records for workspace 1 across the collapse:

```text
22:15:13Z columns=3 activeColumnIndex=2 currentOffset=-1177.2
           lastViewportMutation=endGesturePreservingCurrentOffset.static  (animating=false)

22:15:54Z columns=2 activeColumnIndex=1 currentOffset=-173.2
           reason=relayout.viewportOffsetChanged
           lastViewportMutation=removeWindow.shiftActiveColumn
           lastViewportMutationBeforeCurrentOffset=-1177.2
           lastViewportMutationAfterCurrentOffset=-173.2          (age 4.2ms)

22:15:55Z columns=1 activeColumnIndex=0 currentOffset=-408.0
           reason=relayout.viewportOffsetChanged
           lastViewportMutation=resetViewportForCenteredLoneWindow
           lastViewportMutationBeforeCurrentOffset=830.8
           lastViewportMutationAfterCurrentOffset=-408.0           (age 28.8ms)
```

`830.8` never appears as a committed `currentOffset` on any record. The offset
went `-173.2 -> 830.8 -> -408.0`, but the `-173.2 -> 830.8` step has no record
and no surviving attribution; `830.8` shows up only as the reset's `before`.
`animating=false` throughout, so the gap is not an animation the observer
deliberately suppresses.

### Source — two mutations, one planning copy, one audit slot

`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift`

- `:342` `buildRelayoutPlan`; `:348` `var state = snapshot.viewportState` — the
  single planning copy for the whole pass.
- `:359` `processWindowRemovals` -> `removeColumnByIdx`
  (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:411`). At
  `:434` `offset = columnX(removedIdx+1) - columnX(removedIdx)`; for the 2->1
  collapse with `removedIdx=0` this is `1004.0`. The `removedIdx(0) < activeIdx(1)`
  branch (`:474-478`) applies `viewOffsetPixels.offset(+1004.0)` -> `-173.2 +
  1004.0 = 830.8`, recorded as `removeWindow.shiftActiveColumn`.
- `:383` `resolveSelection` -> `:620` `resetViewportForCenteredLoneWindow` ->
  `:829` `setStaticViewOffsetPixels(centerOffset)` -> `830.8 -> -408.0`,
  recorded as `resetViewportForCenteredLoneWindow`, overwriting the slot.

`Sources/Nehir/Core/Layout/Niri/ViewportState.swift`

- `:223-244` `withRecordedViewportMutation` stores one snapshot; the second call
  overwrites the first.

`Sources/Nehir/Core/Workspace/WorkspaceManager.swift`

- `:3612-3617` the offset-mutation observer diffs the *previously committed*
  target against the *newly committed* target and fires once per commit. The
  intermediate `830.8` existed only on the planning copy and was never committed,
  so it is never traced.

### Fix direction (trace fidelity only)

Make every recorded mutation attributable even when superseded in the same
commit: either emit a trace record from inside `withRecordedViewportMutation` at
mutation time (architecturally hard — `ViewportState` is a value type deep in the
layout layer with no handle to the trace recorder), or replace the single audit
slot with a short ring buffer flushed per-commit through the existing observer
choke point. The invariant to enforce: every offset change through
`withRecordedViewportMutation` stays visible in the trace even if a later
mutation in the same commit overwrites it.

## Reproduction topology

- Built-in display (display 1, frame `0..2056`) plus one external display
  connected to its left (display 3, frame `-2560..0`).
- An app tiled in workspace 1 such that connecting the external display collapses
  workspace 1 toward a lone window and forces one of its columns to be hidden
  `.layoutTransient` `side=left` (here: Helium, with a Ghostty window that gets
  reassigned to workspace 6 on the external display).
- Connect the external display.
- Observe: the hidden workspace-1 window parks at `x = -971` and renders on
  display 3; end-state shows it as a visible unmanaged window on display 3 while
  still assigned to workspace 1.
