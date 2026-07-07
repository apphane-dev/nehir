# OmniWM issue #246 — "Windows overlapping after focus move" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/246>
Scope of this doc: determine whether the issue applies to nehir,
and whether the suggested fix is safe to port.

All file/line references were verified against the Nehir source tree
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace").
Re-verify before implementing; line numbers drift.

> **Filed under `discovery/noop/`** — #246 applies by inspection, but it owns no
> new action: it is another upstream face of the stale-hidden-column / wrong-parked
> live AX frame family already owned by
> `discovery/20260616-stale-live-frame-on-stably-hidden-column.md`,
> with cross-workspace overlap already catalogued in
> `noop/20260616-omniwm-235-window-bleed-different-workspace.md`.
> Implementing that sibling discovery's invariant closes this issue; #246 only
> adds the "focus right after full-column-width" reproduction.

---

## TL;DR

- **#246's reported overlap is a stale hide/re-hide failure during Niri horizontal
  focus navigation, not a separate tiling model.** Upstream linked it to #235 and
  pushed `739a96e` ("fix: eliminate window bleed across workspaces and columns"),
  which re-applies hidden frames from authoritative hide requests and adds
  planning-width geometry for animated width changes. nehir still has the old
  transition-only hide path and no `planningWidth` / verified-hide-origin tracking.
- **Verdict:** 🔴 **Open / Applies**, but **deduped to noop** because the fix is
  already owned by the stale-live-frame sibling discovery.

## Provenance: is this nehir's code?

Yes. The symbols named by the upstream fix and reproduction exist in nehir:

- The full-width command path exists: `toggleColumnFullWidth` is dispatched by
  `CommandHandler` and handled by `NiriLayoutHandler.toggleColumnFullWidth` at
  `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1329`.
- The "move to the next window to the right" path exists as `focusUpOrRight`,
  routed through combined Niri navigation at
  `Sources/Nehir/Core/Controller/CommandHandler.swift:284` and
  `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:340`.
- Hidden columns are still emitted as `.hide(token, side:)` only when the hidden
  side changes, at `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:910-915`.
- nehir's `LayoutVisibilityChange` still lacks upstream's `LayoutHideRequest` payload;
  it is only `case hide(WindowToken, side: HideSide)` at
  `Sources/Nehir/Core/Layout/LayoutBoundary.swift:67-70`.
- Upstream's `planningWidth`, `lastVerifiedHideOrigin`, `hiddenOriginForComparison`,
  `handleFreshFrameEvent`, and `discardHiddenTracking` symbols were searched for in
  `Sources/Nehir` and are **not found**.

## Upstream issue summary

The issue body says that when the reporter toggled full column width and moved to
the next window to the right, the newly focused window overlapped the previous one.
The report was edited to emphasize that simply moving right reproduced it "always"
and did not self-correct while moving through windows. It was filed on latest macOS.

The first comment linked #235 as possibly relevant. The maintainer replied that a fix
was in progress, then linked `BarutSRB/OmniWM@739a96e` as the pushed fix. The issue was
later closed `not_planned` during a v0.4.8 cleanup, not because this individual report
was proven fixed.

That commit's relevant diff does two things nehir does not yet do:

1. It changes hidden visibility changes from `hide(token, side)` to `hide(LayoutHideRequest)`
   carrying the hidden frame, compares it with `lastVerifiedHideOrigin`, and re-hides even
   when the offscreen side did not change.
2. It adds `NiriContainer.planningWidth = targetWidth ?? cachedWidth` and migrates viewport
   planning readers to use that target width during animated width changes.

## The code in question

### 1. The reported focus-right path exists and performs Niri layout navigation

```swift
// Sources/Nehir/Core/Controller/CommandHandler.swift:284-291
private func focusUpOrRightInNiri() {
    executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps in
        engine.focusUpOrRight(
            currentSelection: currentNode,
            in: wsId,
            motion: motion,
            state: &state,
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:340-357
func focusUpOrRight(
    currentSelection: NiriNode,
    in workspaceId: WorkspaceDescriptor.ID,
    motion: MotionSnapshot,
    state: inout ViewportState,
    workingFrame: CGRect,
    gaps: CGFloat
) -> NiriNode? {
    focusCombined(
        verticalDirection: .up,
        horizontalDirection: .right,
        currentSelection: currentSelection,
```

### 2. Full-column-width changes animate a target width, but nehir's planning geometry still reads `cachedWidth`

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:663-690
column.savedWidth = column.width
column.isFullWidth = true
column.presetWidthIdx = nil
column.hasManualSingleWindowWidthOverride = true
targetPixels = resolvedColumnPixels(.proportion(1), for: column, workingFrame: workingFrame, gaps: gaps)
...
let didStartWidthAnimation = column.animateWidthTo(
    newWidth: targetPixels,
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:314-321
if restorePreviousWidthAfterFit {
    column.cachedWidth = targetWidth
    defer { column.cachedWidth = previousWidth }
    revealTargetWidth()
} else {
    column.cachedWidth = targetWidth
    revealTargetWidth()
}
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:379-389
var width: ProportionalSize = .default

var cachedWidth: CGFloat = 0

var presetWidthIdx: Int?

var isFullWidth: Bool = false

var savedWidth: ProportionalSize?
```

There is no `planningWidth` property between `targetWidth` and `cachedWidth` in nehir;
viewport positions still use `cachedWidth` directly:

```swift
// Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift:275-281
func columnX(at index: Int, columns: [NiriContainer], gap: CGFloat) -> CGFloat {
    containerPosition(at: index, containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
}

func totalWidth(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
    totalSpan(containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
}
```

### 3. Hidden-column re-hides are transition-only in nehir

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:910-915
let previousOffscreenSide = window.hiddenState?.offscreenSide
if let side = hiddenHandles[token] {
    if previousOffscreenSide != side {
        diff.visibilityChanges.append(.hide(token, side: side))
    }
    continue
}
```

```swift
// Sources/Nehir/Core/Layout/LayoutBoundary.swift:67-70
enum LayoutVisibilityChange {
    case show(WindowToken)
    case hide(WindowToken, side: HideSide)
}
```

The applier can only re-hide entries that appear in that transition list:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:3395-3406
for change in diff.visibilityChanges {
    switch change {
    case let .show(token):
        ...
    case let .hide(token, side):
        hiddenTokens.insert(token)
        guard let entry = resolveEntry(for: token) else { continue }
        guard entry.layoutReason != .nativeFullscreen else { continue }
        hiddenEntries.append((entry, side))
    }
}
```

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:3471-3495
for (entry, side) in hiddenEntries {
    switch refreshController.resolveHideOperation(
        for: entry,
        monitor: monitor,
        side: side,
        reason: .layoutTransient
    ) {
    case let .movable(plan, hiddenState):
        controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
        hiddenJobs.append((entry.handle.pid, entry.windowId))
        hidePlans.append(plan)
...
if !hidePlans.isEmpty {
    refreshController.applyPositionPlans(hidePlans)
```

`resolveHideOperation` has a stale-cached live-frame fallback, but only after a
`.hide` transition reaches it:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2390-2412
let moveEpsilon: CGFloat = 0.01
if abs(frame.origin.x - origin.x) < moveEpsilon,
   abs(frame.origin.y - origin.y) < moveEpsilon
{
    if reason == .layoutTransient,
       let liveFrame = try? AXWindowService.frame(entry.axRef)
    {
        let liveDx = abs(liveFrame.origin.x - origin.x)
        let liveDy = abs(liveFrame.origin.y - origin.y)
        if liveDx > moveEpsilon || liveDy > moveEpsilon {
            controller.axManager.recordFrameApplyTrace("hidePlan.staleCachedAlreadyHidden ...")
            return .movable(
```

## Why this applies / owns no new action

#246's reproduction is exactly the high-risk sequence for the sibling stale-hidden-column
bug:

1. `toggleFullWidth` sets a full-width target and starts a width animation
   (`NiriLayoutEngine+Sizing.swift:663-690`). During that transition, nehir still bases
   column positions, snap bounds, and visibility on `cachedWidth` (`ViewportState+Geometry.swift:275-281`,
   `:514-516`, `:634-635`) rather than upstream's `planningWidth` target.
2. Moving focus right calls `focusUpOrRight`, which runs `ensureSelectionVisible` / horizontal
   navigation for the target column (`NiriNavigation.swift:284-312`, `:340-357`). That can
   move the viewport while the previous full-width column should become hidden.
3. If the previous column was already marked hidden on the same side, nehir emits no new
   `.hide` (`NiriLayoutHandler.swift:910-915`). Therefore no entry reaches
   `resolveHideOperation` (`LayoutRefreshController.swift:3395-3406`, `:3471-3495`), and the
   stale live AX frame can remain on-screen overlapping the newly focused window.
4. Upstream's linked fix targets precisely this gap: carry the computed hidden frame through
   `LayoutHideRequest`, remember verified hide origins, and re-emit `.hide` when the expected
   hidden origin changes even if the side did not. Those symbols are absent in nehir.

This evidence contradicts a possible "closed not_planned means fixed / irrelevant" reading:
the closure was a cleanup, while the maintainer's own linked commit fixes a real bleed/overlap
class that nehir still has by inspection.

It still should not become a separate top-level action, because nehir already has the root
invariant filed: **hidden windows must be reconciled against their live AX frame even when
they are stably hidden and produce no fresh `.hide` transition**. #246 is the focus-command
reproduction of that same invariant; #235 is the cross-workspace report in the same family.

## Recommendation

Do not port `739a96e` blindly as a standalone #246 patch. Instead, implement the sibling
stale-live-frame discovery's fix in nehir terms:

- Re-check stably hidden layout-transient windows' live AX frames against their expected park
  origins, not only when `diff.visibilityChanges` emits `.hide`.
- When width animations are in flight, use target/planning width for viewport planning so the
  hide frame being verified is the frame the user is navigating toward, not stale `cachedWidth`.
- If adapting upstream code, adapt the `LayoutHideRequest` + verified-origin idea, but keep it
  under the sibling discovery's tests and invariants.

## Suggested tests

- Full-width focus-right regression: two or three columns, toggle the left/active column to
  full width, focus/move right, then assert the previous column is either visible at its
  computed frame or re-parked to its hidden origin; it must not keep an on-screen live AX frame
  while `hidden=layoutTransient`.
- Stable hidden reapply: a window with unchanged hidden side but changed expected hidden origin
  must generate a re-hide/reconcile action, covering the upstream `lastVerifiedHideOrigin`
  behavior without depending on a side transition.
