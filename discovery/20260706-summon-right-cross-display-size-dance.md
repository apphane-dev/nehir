# Discovery: cross-display Summon Right reveals the moved window at a different monitor size

Groom 2026-07-07: still applicable — the cross-display size-reconciliation "dance" during Summon Right reveal remains open; distinct from the in-flight admission/drop work in `planned/20260706-summon-right-empty-active-workspace.md` (`9cbc7db5` shipped the active-workspace target, not the size reconciliation) (verified against main 7a025b78).

Status: root cause found and source-confirmed. This is a follow-up to the
Summon Right active-workspace work, not a replacement for
`planned/20260706-summon-right-empty-active-workspace.md`. The earlier plan fixes
admission/drop behavior; this discovery covers the remaining visible "dance" when
Summon Right moves a window between displays with different working sizes.

All source references were verified against the `fix/summon-right-display-verify`
source tree on 2026-07-06. Re-verify before editing; line numbers drift. Source
paths are repository-relative.

## Summary

A cross-workspace Summon Right can now reach the correct target workspace and
monitor, but a cross-display summon still visibly resizes/repositions the moved
window during the reveal. The capture topology is asymmetric:

```text
ID(displayId: 1) isMain=true  frame=(0.0, 0.0, 2056.0, 1329.0) visibleFrame=(0.0, 0.0, 2056.0, 1290.0) name=Built-in Retina Display
ID(displayId: 2)              frame=(-1171.0, 1329.0, 2560.0, 1440.0) visibleFrame=(-1171.0, 1329.0, 2560.0, 1410.0) name=DELL P2423D
```

The selected window starts on the built-in display and is summoned to the DELL
workspace. Its source live/replacement frame is still sized for the built-in
workspace (`1011x1251` in the first summon), but the target DELL workspace wants
a different frame (`2035x1371` when the target is a lone-window workspace, then
`840x1371` when the target becomes a proportional multi-column workspace). The
visible dance is this cross-monitor size reconciliation happening as part of the
visible reveal/scroll instead of being completed before the window is shown.

## Evidence (inlined)

First summon, moving window 1573 from workspace
`30C80640-8093-49E6-9911-D1019A87762B` to workspace
`673CE44F-EE06-4600-BDB3-01B18A6EA910`:

```text
2026-07-06T19:23:50Z summonRight.dispatch handle=WindowToken(pid: 89691, windowId: 1573) sourceWorkspace=30C80640-8093-49E6-9911-D1019A87762B targetWorkspace=673CE44F-EE06-4600-BDB3-01B18A6EA910 focusedToken=nil
2026-07-06T19:23:50Z summonRight.moved token=WindowToken(pid: 89691, windowId: 1573) sourceWorkspace=30C80640-8093-49E6-9911-D1019A87762B targetWorkspace=673CE44F-EE06-4600-BDB3-01B18A6EA910 columnsAfterMove=1
```

Immediately after the move, the target workspace is a lone-window workspace on
DELL. The spring classifier shows the visible target frame and the old source
frame in the same record:

```text
workspace=6 id=673CE44F-EE06-4600-BDB3-01B18A6EA910 reason=spring_frame_classification token=WindowToken(pid: 89691, windowId: 1573)
visibilityClass=hiddenToVisible currentFrame={{-1070.0,1336.0},{2035.0,1371.0}}
viewport={{-1163.0,1336.0},{2544.0,1371.0}}
layout=c0[x=0.0,cached=840.0,override=2035.0,spec=prop:0.3333]{w1573:selected{cur=-1139,1336,2035,1371,target=-311,1336,2035,1371,live=-1010,7,1011,1251,replacement=-55,7,1011,1251,hidden:left}}
```

Important details:

- `live=-1010,7,1011,1251` and `replacement=-55,7,1011,1251` are built-in-display
  dimensions/coordinates for the selected source window.
- The target frame on DELL is `2035x1371`, a different size. That width comes from
  the target workspace's lone-window layout override (`override=2035.0`), not
  from the proportional cached width (`cached=840.0`, `spec=prop:0.3333`).
- The record is already `visibilityClass=hiddenToVisible`, so the user can see the
  cross-monitor resize/reveal as the window transitions onto the DELL workspace.

A second sample after more summons shows the other side of the same mechanism:
when the target workspace has four proportional columns, the same earlier window
is now `840x1371` instead of `2035x1371`:

```text
workspace=6 id=673CE44F-EE06-4600-BDB3-01B18A6EA910 reason=spring_frame_classification token=WindowToken(pid: 89691, windowId: 1573)
visibilityClass=visible currentFrame={{-1263.0,1336.0},{840.0,1371.0}}
viewport={{-1163.0,1336.0},{2544.0,1371.0}}
layout=c0[x=0.0,cached=840.0,override=nil,spec=prop:0.3333]{w1573{cur=-1205,1336,840,1371,target=-2010,1336,840,1371,live=-1157,1336,840,1371,replacement=-738,-1378,840,1371}}
```

And the fourth summoned window has the source-display size in its live/replacement
fields while the target proportional DELL column wants `840x1371`:

```text
layout=... c3[x=2538.0,cached=840.0,override=nil,spec=prop:0.3333]{w9386:selected{cur=1333,1336,840,1371,target=535,1336,840,1371,last=14,7,1011,1251,live=14,7,1011,1251,replacement=1031,7,1011,1251}}
```

So the bug is not that Summon Right chooses the wrong workspace after the
admission fix. It chooses the target workspace and frames on the target monitor,
but the cross-monitor move exposes the source-sized frame until the target-sized
frame is applied/revealed.

## Source confirmation

### Summon Right currently moves first, then relies on the transition relayout

`Sources/Nehir/Core/Controller/WindowActionHandler.swift`

- `:618-628` calls `workspaceNavigationHandler.moveWindow(...)` for the
  cross-workspace summon path.
- `:636-647` inserts the moved node into the target column position.
- `:648-654` documents that Summon Right intentionally relies on `moveWindow`'s
  existing viewport preparation and avoids a second `ensureSelectionVisible`.
- `:662-668` commits the workspace transition and then starts the target
  workspace scroll animation.

This ordering fixed the earlier double-viewport-hop bug, but it still leaves no
cross-monitor size gate between "the window was transferred/reassigned" and "the
transition reveal/scroll is visible." The first visible frame can therefore carry
source-display dimensions or a just-computed target lone-window width.

### `moveWindow` prepares viewport state, not an atomic target-frame reveal

`Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift`

- `:918-932` transfers the engine node, reassigns the managed window to the
  target workspace, and calls `prepareMovedWindowTargetViewport(...)`.
- `:99-132` shows `prepareMovedWindowTargetViewport(...)` mutating Niri viewport
  state (`selectedNodeId`, `ensureSelectionVisible`, session patch + remembered
  focus). It does not force-apply the moved window's target AX frame before the
  window becomes visible on the target display.
- `:980-1012` shows the shared non-following move commit path used by
  workspace-bar moves. It has the same transfer/prepare/commit structure, so a
  cross-monitor bar move can have the same stale-size flash even if Summon Right
  is the path that made it obvious.

### The size change is expected from the layout model

`Sources/Nehir/Core/Layout/Niri/NiriLayout.swift`

- `:897-900` stores a `loneWindowLayoutWidthOverride` from the single-window
  canonical geometry when the workspace is in lone-window layout. That explains
  the first summon's `override=2035.0` on the DELL workspace.
- `:205-207` clears lone-window overrides once the layout has multiple
  containers. That explains why the same target workspace later reports
  `override=nil` and proportional `840.0` columns.

`Sources/Nehir/Core/Layout/Niri/NiriNode.swift`

- `:606-607` makes `effectiveViewportWidth` prefer
  `loneWindowLayoutWidthOverride` over `cachedWidth`, so the lone-window
  `2035.0` override legitimately beats the proportional `840.0` cached width.

The layout sizes are internally consistent. The bug is the transition timing:
cross-display summon makes the size reconciliation user-visible.

### There is already a reveal primitive that waits for the target frame

`Sources/Nehir/Core/Controller/LayoutRefreshController.swift`

- `:3357-3378` creates a pending reveal transaction with a concrete
  `targetFrame`.
- `:3641-3678` unsuppresses, calls `forceApplyNextFrame(for:)`, applies the
  target frame, and completes the reveal from the terminal observer.

That machinery is the right shape for this bug: a cross-monitor move should not
visibly reveal a moved window until its target-monitor frame has been force-applied
or at least until the transition knows that the first visible frame is the target
frame.

## Suggested fix shape

Prefer a shared cross-monitor move fix over a Summon Right-only patch.

1. Detect when a move changes the owning monitor / working frame. The minimum
   gate can compare `workspaceManager.monitor(for: sourceWorkspaceId)` and
   `workspaceManager.monitor(for: targetWorkspaceId)` around the shared move
   commit. Do not gate solely on workspace id; same-monitor workspace moves do
   not need the extra reveal path.
2. For cross-monitor moves, route the moved token through a target-frame reveal
   gate before visible scroll/focus handoff. Reuse the existing pending-reveal
   transaction shape: determine the target layout frame for the moved entry,
   suppress stale frame writes while the target is being established, call
   `forceApplyNextFrame(for:)`, apply the target frame, and only then clear the
   hidden/suppressed state and run the focus handoff.
3. Apply this at the shared move boundary used by Summon Right and
   `commitNonFollowingWindowMove`, not only inside the command-palette summon
   path. Otherwise workspace-bar cross-monitor moves retain the same class of
   stale-size flash.
4. Keep the previous Summon Right viewport simplification: do not reintroduce a
   second `ensureSelectionVisible` or duplicate session patch in
   `WindowActionHandler`. The earlier traces showed that duplicate viewport prep
   caused a separate hop; this discovery is about frame-size atomicity.
5. Validate with runtime traces before adding tests. The acceptance signal for
   this bug is visual/on-device: the first target-display frame for the summoned
   token should already have the target size (`2035x1371` for the empty/lone
   target case, `840x1371` for a proportional multi-column target), with no
   visible source-sized intermediate (`1011x1251`) on the target monitor and no
   window left suppressed/parked.

## Risks / watch-outs

- The pending-reveal path already has nuanced hidden-state handling. Do not guess
  a `layoutTransient` hide side ad hoc in the summon branch; a wrong side can
  park the window on the wrong edge or strand it on a neighbouring monitor.
- The target frame has to be captured after the target workspace's Niri state is
  final (after the moved node is inserted at the requested column position), but
  before the user-visible reveal/scroll begins.
- The empty-target and non-empty-target cases have different expected target
  widths (`loneWindowLayoutWidthOverride` vs proportional column width). A fix
  that hard-codes proportional width would regress the intended lone-window
  layout.
- If the implementation introduces a new transient-hidden state, ensure failure
  recovery clears suppression/hidden metadata. A failed AX frame write must not
  leave the summoned window invisible or unmanaged.
