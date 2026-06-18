# OmniWM issue #218 — "Tab indicators misplaced after workspace change" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/218>
Scope of this doc: determine whether the symptom reproduces in nehir — a tabbed
column's tab indicator overlay landing on top of the window (stale position)
after a workspace switch or a focus-driven auto-scroll, only corrected by a
manual horizontal scroll — and whether any fix is needed.

All file/line references were verified against worktree `worktree-calm-meadow-6229`
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

> **Filed under `discovery/noop/`** — nehir positions the tabbed-column overlay
> from the column's **live rendered frame** (viewport-/animation-aware) and
> refreshes it after every layout pass and on relayout/focus/activation. There
> is no path where the overlay holds a stale column frame past a layout pass, so
> the "misplaced until a manual scroll" symptom cannot persist. No fix to port.

---

## TL;DR

- **nehir derives the overlay frame from `column.renderedFrame` (the current,
  viewport-applied frame), not a cached/static column frame, and recomputes it
  on every layout pass** — which run as part of a workspace switch
  (`commitWorkspaceTransition`) and during/after a focus-driven auto-scroll. So
  the overlay tracks the column to its correct on-screen position; the OmniWM
  "stuck over the window until manual scroll" state does not occur.
- **Verdict:** 🟢 **Fixed.**

## Issue context

- **State:** closed `not_planned`; no merged fix, no diff to port.
- **Symptom (verbatim):**
  - "switch to workspace where some columns use tabs … Actual: Tab indicator
    placed over window."
  - "click to focus column on workspace where some columns use tabs so
    autoscroll happens … Actual: Tab indicator placed over window."
  - "Note: Tab indicator are placed to expected location immediately after
    manual horizontal scroll."
- **Root-cause signature:** the overlay's position is computed from a column
  frame that goes stale when the viewport offset changes programmatically
  (workspace switch or auto-scroll); only a manual scroll (which forces a
  re-render) repositions it. This is the classic "overlay snapshot not refreshed
  on programmatic viewport change."

## Provenance: is this nehir's code?

Yes. nehir has a dedicated tabbed-column overlay subsystem:

- `TabbedColumnOverlayManager` / `TabbedColumnOverlayWindow`
  (`Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:282`/`:427`) — the
  overlay windows positioned next to tabbed columns.
- `NiriLayoutHandler.updateTabbedColumnOverlays(...)`
  (`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1001`/`:1019`) and the
  info collector `tabbedColumnOverlayInfos(...)` (`:1032`).
- Refresh call sites after every layout pass (`NiriLayoutHandler.swift:107`),
  on relayout (`LayoutRefreshController.swift:457`/`:643`/`:2002`), and on
  focus-confirm / app-activation (`AXEventHandler.swift:2097`/`:2401`).

## The code in question

**The overlay frame is derived from the column's LIVE rendered frame, then
intersected with the monitor — so it reflects the current viewport offset:**

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1043  (tabbedColumnOverlayInfos)
for column in engine.columns(in: workspaceId) where column.isEffectivelyTabbed {
    guard let frame = column.renderedFrame ?? column.frame else { continue }   // ← LIVE rendered frame
    let visibleColumnFrame = frame.intersection(monitor.visibleFrame)
    guard TabbedColumnOverlayManager.shouldShowOverlay(columnFrame: frame, visibleFrame: monitor.visibleFrame) else { continue }
    ...
    infos.append(TabbedColumnOverlayInfo(
        workspaceId: workspaceId, columnId: column.id,
        columnFrame: frame, visibleColumnFrame: visibleColumnFrame, ...))
}
```

**The overlay window is repositioned whenever its computed frame changes:**

```swift
// Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:504  (TabbedColumnOverlayWindow.update)
let frame = Self.overlayFrame(for: info.visibleColumnFrame, tabCount: info.tabCount)
...
if lastFrame != frame || self.frame != frame {
    setFrame(frame, display: false)
    overlayView.frame = CGRect(origin: .zero, size: frame.size)
    lastFrame = frame
}

// Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:547  (overlayFrame)
let x = visibleColumnFrame.minX - (width - TabbedOverlayMetrics.totalWidth)   // just left of the column
let y = visibleColumnFrame.minY + (visibleColumnFrame.height - height) / 2
```

**The refresh is wired into every pass and every relevant transition:**

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:107  (after applying a layout plan)
self.updateTabbedColumnOverlays(workspaceId: wsId, monitor: monitor)

// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:457 / :643 / :2002  (relayout)
niriHandler.updateTabbedColumnOverlays(forceOrdering: true)

// Sources/Nehir/Core/Controller/AXEventHandler.swift:2097 / :2401  (focus confirm / app activation)
controller.niriLayoutHandler.updateTabbedColumnOverlays(forceOrdering: true)
```

## Why the bug does not apply (nehir refreshes from the live frame)

1. **No stale frame can survive a pass.** The overlay position is recomputed
   from `column.renderedFrame` on every call to `updateTabbedColumnOverlays`
   (`NiriLayoutHandler.swift:1044`), and that call follows every layout pass
   (`:107`). A workspace switch drives `commitWorkspaceTransition` → a layout
   pass → an overlay refresh with the new rendered frames. A focus-driven
   auto-scroll animates the viewport, and each layout pass during/after the
   animation re-derives the overlay from the current `renderedFrame`. So the
   overlay is never left at a pre-transition position waiting for a manual
   scroll.

2. **The overlay tracks viewport offset by construction.** Because
   `visibleColumnFrame = column.renderedFrame.intersection(monitor.visibleFrame)`
   and `renderedFrame` already includes the animated `viewOffsetPixels`, the
   overlay's `minX`/`minY` move with the column as the viewport scrolls — without
   needing a separate "overlay scroll" event (the thing OmniWM was missing).

3. **Force-ordering on focus/activation keeps z-order correct.** The refresh
   sites on focus-confirm and app activation pass `forceOrdering: true`
   (`AXEventHandler.swift:2097`/`:2401`), which re-fronts and re-orders the
   overlay relative to the active window (`TabbedColumnOverlay.swift:530`), so
   the overlay is also not left under/over the wrong surface after a switch.

4. **Nothing to port.** The issue is `not_planned` with no upstream fix, and
   nehir's rendered-frame-derived + per-pass-refresh design is the correct
   structure. The only theoretical residual is a sub-frame lag if a refresh were
   skipped between animation ticks, which does not reproduce the reported
   "stuck-until-manual-scroll" state.

## Recommendation

**Do nothing / do not port.** Keep the rendered-frame-derived overlay refresh as
the owner for correct tab-indicator placement. If a future report shows an
overlay stuck at a stale position after a switch/scroll, the investigation
target is a regression where `updateTabbedColumnOverlays` stopped being called
on a pass, or where `column.renderedFrame` stopped reflecting the viewport
offset — not a missing refresh hook, which is already in place.

## Suggested tests

- Workspace A (tabbed column at viewport offset 0) and workspace B (tabbed
  column scrolled off-center): switch A→B→A; after each switch assert each
  overlay's frame equals `overlayFrame(for: column.renderedFrame.intersection(
  monitor.visibleFrame))` for the active workspace — i.e. it matches the live
  rendered column, not the previous workspace's frame.
- Focus a far-right tabbed column that triggers an auto-scroll; assert the
  overlay frame tracks the column's `renderedFrame` across the animation and at
  settle (no stale minX), without requiring a manual scroll.
