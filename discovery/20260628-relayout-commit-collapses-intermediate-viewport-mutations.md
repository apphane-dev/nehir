# Discovery: a relayout commit collapses intermediate viewport offset mutations

Status: root cause found. The trace proves an unrecorded viewport offset step
inside a single relayout commit, and the source proves *why* it is unrecorded:
two offset mutations land on the same planning `ViewportState` copy, and both
the audit slot and the trace observer only retain the last one. Not yet a fix
plan.

Validated against the `patch/unrecorded-viewport-offset-mutation-attribution`
branch on 2026-06-28 (the branch that introduced the `lastViewportMutation*`
audit). Source paths below are repository-relative.

## Summary

A runtime trace captured on 2026-06-27 while connecting an external display
shows workspace 1 collapse from 2 tiled columns to a single (lone) window. The
emitted viewport trace for that workspace has exactly three committed records
across the transition:

```text
22:15:13Z columns=3 currentOffset=-1177.2 lastViewportMutation=endGesturePreservingCurrentOffset.static (animating=false)
22:15:54Z columns=2 currentOffset=-173.2  lastViewportMutation=removeWindow.shiftActiveColumn   (animating=false)
22:15:55Z columns=1 currentOffset=-408.0  lastViewportMutation=resetViewportForCenteredLoneWindow (animating=false)
```

The final record carries:

```text
lastViewportMutationBeforeCurrentOffset=830.8
lastViewportMutationAfterCurrentOffset=-408.0
```

`830.8` never appears as a committed `currentOffset` on any emitted record. The
offset jumped from `-173.2` (the last visible value) to `830.8`, then to
`-408.0`, but the `-173.2 -> 830.8` step has no trace record and no surviving
attribution. `animating=false` and `gesture=false` throughout, so the gap is
not an animation/gesture whose trace the observer deliberately suppresses.

The source shows the missing step is `removeWindow.shiftActiveColumn`, and
shows why it is invisible: the column-removal rebase and the lone-window reset
both mutate the same planning `ViewportState` inside one `buildRelayoutPlan`
pass. The per-mutation audit keeps only the last attribution, and the offset
observer emits only one record per commit. The intermediate rebase is recorded
momentarily and then overwritten on the same copy before it is ever committed,
so it leaves no trace line and its `830.8` value survives only as the reset's
`before`.

## Evidence from the trace

### Topology: external display connected

End-of-capture monitor topology:

```text
ID(displayId: 1) isMain=true  name=Built-in Retina Display frame=(0.0, 0.0, 2056.0, 1329.0)
ID(displayId: 3)               name=DELL P2423D          frame=(-2560.0, -111.0, 2560.0, 1440.0)
```

The connection event:

```text
event=topology_changed displays=2 plan=topology=1->2 visible_assignments=1 restore_refresh=topology
```

Workspace UUIDs used below: `workspace=1 id=3EE87D81-95D5-4DD9-8FD9-642AC048062D`,
`workspace=6 id=AE84439A-35C7-4F50-ABAF-EEA01CB72476`.

### Ghostty becomes the lone window of workspace 6 on the external display

```text
event=window_admitted token=WindowToken(pid: 18524, windowId: 1699) workspace=AE84439A ... mode=tiling
event=managed_replacement_metadata_changed token=WindowToken(pid: 18524, windowId: 1699) workspace=AE84439A monitor=Optional(ID(displayId: 3))
```

End-state workspace 6 layout (single column, ghostty only, on the DELL):

```text
workspace=6 id=AE84439A c0[...]{w1699:selected{cur=-2552,-79,2544,1346}}
```

### Workspace 1 collapses to a lone window (the buggy viewport transition)

Committed viewport records for workspace 1 across the relayout, with the
`lastViewportMutation*` audit fields (verbosity path that emits them was on):

```text
22:15:13Z columns=3 activeColumnIndex=2 currentOffset=-1177.2 currentViewStart=830.8
           lastViewportMutation=endGesturePreservingCurrentOffset.static
           lastViewportMutationAgeMs=... (animating=false gesture=false)

22:15:54Z columns=2 activeColumnIndex=1 currentOffset=-173.2 currentViewStart=830.8
           reason=relayout.viewportOffsetChanged
           lastViewportMutation=removeWindow.shiftActiveColumn
           lastViewportMutationBeforeCurrentOffset=-1177.2
           lastViewportMutationAfterCurrentOffset=-173.2
           lastViewportMutationAgeMs=4.2 (animating=false gesture=false)

22:15:55Z columns=1 activeColumnIndex=0 currentOffset=-408.0 currentViewStart=-408.0
           reason=relayout.viewportOffsetChanged
           lastViewportMutation=resetViewportForCenteredLoneWindow
           lastViewportMutationBeforeCurrentOffset=830.8
           lastViewportMutationAfterCurrentOffset=-408.0
           lastViewportMutationAgeMs=28.8 (animating=false gesture=false)
```

The audit chain is continuous *except* for one gap: between the
`-173.2` record and the `resetViewportForCenteredLoneWindow` record the offset
was `830.8`, but no record names the mutation that produced `830.8`, and
`830.8` is never a committed `currentOffset`. The reset's
`lastViewportMutationBeforeCurrentOffset=830.8` is the only place it appears.

Note `currentViewStart=830.8` on the `-173.2` record: `currentViewStart` is the
projected view position `activeColumnX + currentOffset` (see source below), so
`830.8 = 1004.0 + (-173.2)`, i.e. `830.8` is exactly the active column's
left-edge X (`1004.0`, column 1 in the 2-column layout) minus the active
column's X after collapse (`0.0`, column 0) added to the old offset:
`-173.2 + (1004.0 - 0.0) = 830.8`. That delta is the column-removal rebase.

## Source validation

### The rebase that produces `830.8`

`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift`

- `:411` `removeColumnByIdx(...)`.
- `:434` `let offset = columnX(at: removedIdx + 1, columns: cols, gaps: gaps) - columnX(at: removedIdx, columns: cols, gaps: gaps)` — the removed column's outer width. For the 2->1 collapse with `removedIdx=0`, this is `columnX(1) - columnX(0) = 1004.0 - 0.0 = 1004.0`.
- `:474-478` the `removedIdx < activeIdx` branch (here `0 < 1`):

```swift
} else if removedIdx < activeIdx {
    state.withRecordedViewportMutation(reason: "removeWindow.shiftActiveColumn") { state in
        state.activeColumnIndex = activeIdx - 1
        state.viewOffsetPixels.offset(delta: Double(offset))
    }
    ...
}
```

So the rebase is `viewOffsetPixels.offset(delta: 1004.0)`: `-173.2 + 1004.0 = 830.8`,
`activeColumnIndex` `1 -> 0`. This is exactly the missing step. It *is* wrapped
in `withRecordedViewportMutation`, so on the planning copy it momentarily sets
`lastViewportMutation = removeWindow.shiftActiveColumn` with
`before.currentOffset = -173.2`, `after.currentOffset = 830.8`.

### The reset that overwrites it, in the same pass

`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift`

- `:342` `buildRelayoutPlan(...)`; `:348` `var state = snapshot.viewportState` — the single planning copy used for the whole pass.
- `:359` `let removal = processWindowRemovals(pass:..., state: &state, ...)` — runs `removeColumnByIdx` and applies the `+1004.0` rebase above.
- `:383` `let selection = resolveSelection(pass:..., state: &state, ...)` — same `state`.
- `:596-620` `resolveSelection` detects the lone window (`usesCenteredLoneWindow`) and calls `resetViewportForCenteredLoneWindow(geometry:..., state: &state)`.
- `:824-829` `resetViewportForCenteredLoneWindow` calls
  `state.setStaticViewOffsetPixels(geometry?.centerOffset ?? 0, reason: "resetViewportForCenteredLoneWindow")`, i.e. `830.8 -> -408.0` on the same copy.

So both mutations target the same `inout ViewportState` during one
`buildRelayoutPlan` pass, and the resulting `state` is embedded in the
`WorkspaceLayoutPlan` and committed as a single patch.

### Why only the last mutation's attribution survives

`Sources/Nehir/Core/Layout/Niri/ViewportState.swift`

- `:223-244` `withRecordedViewportMutation(...)`:

```swift
guard isViewportMutationAuditEnabled else { mutate(&self); return }
let before = viewportMutationSnapshot()
mutate(&self)
let after = viewportMutationSnapshot()
guard before != after else { return }
...
lastViewportMutationBefore = before
lastViewportMutationAfter = after
```

`lastViewportMutationBefore`/`After` are a single slot. The second call
(the reset) overwrites the values the first call (the rebase) wrote. After the
pass, the copy carries only `resetViewportForCenteredLoneWindow`,
`before=830.8`, `after=-408.0`. The rebase's `before=-173.2 / after=830.8` is
gone.

### Why only one trace record is emitted per commit

`Sources/Nehir/Core/Workspace/WorkspaceManager.swift` — inside
`updateNiriViewportState` (the single live-write path that every committed
planning copy funnels through), the offset observer gate (around `:3620`):

```swift
if let previousViewportState,
   !normalizedState.viewOffsetPixels.isGesture,
   abs(previousViewportState.viewOffsetPixels.target() - normalizedState.viewOffsetPixels.target()) > 0.5
{
    niriViewportOffsetMutationObserver?(workspaceId)
}
```

(An earlier version of this gate also required `!isAnimating`; that clause was
removed because it suppressed the focus-activation spring-retarget case — see
`discovery/20260628-relayout-path-recenters-fully-visible-unchanged-selection.md`.
The `.spring` collapses analyzed here commit with `animating=false`, so the
removal does not affect this finding.)

The observer compares the *previously committed* target (`-173.2`) against the
*newly committed* target (`-408.0`) and fires once, emitting one
`reason=relayout.viewportOffsetChanged` record (the observer is registered in
`WMController.init`, around `:363`, supplying that reason). It does not see the
intermediate `830.8` because that value only ever existed on the planning copy
and was never committed on its own.

### How the trace fields are derived (confirms `830.8` is a real offset)

`Sources/Nehir/Core/Controller/WMController.swift`

- `:2784` `currentOffset` reads `state.viewOffsetPixels.current()`.
- `:2750-2752` `lastViewportMutationBeforeCurrentOffset` reads
  `state.lastViewportMutationBefore.currentOffset`, which is
  `viewportMutationSnapshot().currentOffset` = `viewOffsetPixels.current()`
  captured at the moment the reset recorded itself (`ViewportState.swift:207-213`,
  `:235`).

So the reset's `before=830.8` is a genuine snapshot of
`viewOffsetPixels.current()` taken right after the rebase and right before the
reset — not a misread or a stale value.

## Root cause

Two independent granularities are coarser than the per-mutation audit assumes:

1. **The audit is a single slot.** `ViewportState.lastViewportMutation*` stores
   one mutation. When a relayout pass applies N offset mutations to the same
   planning copy, only the Nth survives; mutations 1..N-1 are overwritten in
   place.

2. **The trace observer fires once per commit, not once per mutation.** The
   `relayout.viewportOffsetChanged` observer in `updateNiriViewportState` diffs
   the previous committed offset against the new committed offset and emits a
   single record. Intermediate offset values that exist only on the planning
   copy are never committed and therefore never traced.

Combined, a multi-mutation relayout commit (rebase on column removal, then
lone-window centering) produces one trace record whose
`lastViewportMutationBeforeCurrentOffset` references a transient intermediate
value (`830.8`) that appears nowhere else. That is the "unrecorded viewport
offset mutation" the branch name describes: the mutation was wrapped and
momentarily recorded, but the record was collapsed away before commit, so the
trace shows a gap and a phantom `before` value.

This is not specific to display-connect. Any single `buildRelayoutPlan` pass
that both removes a column before the active column *and* then re-centers
(e.g. collapsing to a lone window, or any removal that triggers
`resetViewportForCenteredLoneWindow` / `ensureSelectionVisible` afterwards)
will collapse the rebase the same way.

## Fix direction (not yet implemented)

The goal is to make every intentional offset mutation attributable in the
trace, even when several land in one commit. Options:

- **Per-mutation trace emission on the planning copy.** Emit a
  `reason=...` viewport trace record from inside `withRecordedViewportMutation`
  (or at each recorded call site) at mutation time, not only at commit time.
  This makes the rebase (`removeWindow.shiftActiveColumn`, `-173.2 -> 830.8`)
  self-identifying regardless of what the next mutation on the same copy does.

- **Short mutation history instead of a single slot.** Replace
  `lastViewportMutation*` with a small ring buffer (or a per-pass list on the
  planning copy) so the rebase is not overwritten by the reset. The trace can
  then show `... -> removeWindow.shiftActiveColumn(-173.2->830.8) ->
  resetViewportForCenteredLoneWindow(830.8->-408.0)` as a chain.

Either way, the key invariant to enforce: *every* offset change that goes
through `withRecordedViewportMutation` must be visible in the trace even if a
later mutation in the same commit supersedes it.

## Reproduction topology

- Built-in display (display 1) + external display to its left (display 3,
  negative-x frame).
- One app tiled across multiple columns on workspace 1 (here Helium windows in
  columns 0..2, with a Ghostty window also admitted to workspace 1 before the
  external display connects).
- Connect the external display. Nehir assigns the Ghostty window to workspace 6
  on the external display and collapses workspace 1 toward its remaining tiled
  window.
- Observe workspace 1's viewport trace: the column collapse shows a single
  `relayout.viewportOffsetChanged` record whose
  `lastViewportMutationBeforeCurrentOffset` is the transient rebase value, with
  no intervening record naming the rebase.
