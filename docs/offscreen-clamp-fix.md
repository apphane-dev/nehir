# Offscreen Window Clamp Fix

## Bug

When scrolling through a Niri horizontal column layout via trackpad gesture, keyboard
navigation, or focus change, fully-offscreen columns appeared as a visible corner strip
(~40×34 px) at the display edge. The strip persisted even after the gesture or animation
completed, creating the impression of a "parked leftover" window.

## Root Cause

### 1. macOS AX/WindowServer Offscreen Position Clamping

macOS **clamps both horizontal and vertical positions** of a full-size window that would be
moved completely offscreen. Instead of accepting the target coordinate, WindowServer parks
the window so that approximately 40 pixels remain visible horizontally and ~34 pixels
vertically at the display edge.

This is invisible to the caller: `AXUIElementSetAttributeValue(kAXPositionAttribute)` returns
`.success`, but a subsequent readback of `kAXPositionAttribute` reveals the clamped position.

Layout wants window far offscreen:
```
enqueue id=276 target={{-1712.0, 8.0}, {852.0, 1068.0}}
```
AX/WindowServer result — clamped back, leaving 40px visible:
```
failed id=276 target={{-1712.0, 8.0}, {852.0, 1068.0}} observed={{-812.0, 8.0}, {852.0, 1068.0}} reason=verificationMismatch
```
Window width is 852, so `-812 + 852 = 40px` visible. Retrying produces the same failure
indefinitely — the clamp is deterministic.

The horizontal clamp applies symmetrically on both edges. Right-edge windows targeting
`x=3448` (on a 1720-wide screen) were clamped to `x=1688`, also leaving ~40px visible.

The vertical clamp: `y=-10000` is clamped to approximately `y=-1034`,
leaving `-1034 + 1068 = 34px` visible.

Combined: a hidden window at target `(-1712, -10000)` is clamped to approximately
`(-812, -1034)`, leaving a **40×34px corner** visible.

**Neither axis can be used to push a full-size window completely offscreen on macOS.**

### 2. Layout-Pass Cache Returning Stale Pre-Move Positions

`applyPositionPlans` used `observedWindowOrigin()` which reads through the
`RefreshFrameContext` cache. This cache is populated once per layout pass — the first time
`fastFrame` is called for a token (in `resolveHideOperation`). It caches the window's
**current on-screen position** (e.g., `(1126, 8)`).

After SkyLight moves the window, the verify step reads `observedWindowOrigin` which returns
the **stale cached** value instead of the real post-move position. This makes every hide
plan appear to fail, triggering the AX fallback unnecessarily.

Diagnostic lesson: hide verification should bypass the layout-pass cache and read directly from AX.

### 3. Stale Gesture Viewport Regression — Fixed

`WorkspaceManager.applySessionPatch` could apply a stale gesture-era viewport snapshot
that overwrote a later snap animation target, causing the viewport to "pull back" toward a
previous position.

Fixed in `879a330`: stale gesture-era viewport snapshots replaced with live state.

### 4. Proportional Restore for Tiled Windows — Fixed

When switching workspaces, tiled windows being restored from `workspaceInactive` hidden
state were first moved to a proportional "restore position" within the monitor, then
async moved to their actual layout target. During the gap, windows appeared at wrong
positions causing visible overlaps and missing columns.

Fixed in `879a330`: tiled windows in tiling mode now skip the proportional restore
position and move directly to their layout target (`LayoutRefreshController` line ~3416).

## Status

**PARTIALLY SOLVED (corner parking).** The `layoutTransient` hide pushes windows to
`y=-10000`, which macOS clamps to `y≈-1034`, leaving only a small corner strip
(~40×32px) visible instead of a full-height edge strip (~40×1068px). The corner strip is
less visually annoying than the full-height strip, but the window is still not truly
hidden.

A fixed Dock on a screen edge **makes things worse** for windows hidden to the opposite
side — see [Dock Presence Affects Clamp Strip Size](#dock-presence-affects-clamp-strip-size).

The core problem remains: macOS clamps both axes and no tested API can order out
external app windows. **We are still looking for a working solution.** Do not mark a
runtime workaround as solved from geometry reasoning or unit tests alone; WindowServer
behavior must be confirmed manually in a real trace/run first.

Useful confirmed findings:

- macOS clamps both horizontal and vertical offscreen positions for external app windows.
- The stale `RefreshFrameContext` cache can make hide verification misleading; live AX
  reads are necessary when diagnosing post-move positions.
- Workspace-inactive hiding appears acceptable because it parks windows at the right edge
  with ~1px visible; this is not a true hide.
- Using that same right-edge parking for transient left-hidden windows removes the parked
  left corner but causes a visible left-to-right fly during the hide transition.
- **Unconfirmed hypotheses are not fixes.** A proposed hide strategy may be implemented
  only as an experiment until runtime traces and visual testing confirm it. Unit tests can
  cover our chosen coordinates and invariants, but they cannot prove WindowServer accepts
  or renders the result correctly.

## Dock Presence Affects Clamp Strip Size

A fixed Dock changes the `visibleFrame` boundaries. The hide code calculates parking
positions relative to `visibleFrame` edges, not screen edges. When the Dock occupies
the same edge as the hide direction, the gap between `visibleFrame` and screen edge
(= Dock width) means the window is parked that much further onto the visible screen.

### Measured Clamp Strip Sizes (right-hidden 808px window, screen width 1728px)

| Dock Position | `liveAXFrame` | Visible Strip |
|---------------|--------------|---------------|
| Auto-hide (baseline) | `{{1727, -1036}, {808, 1068}}` | **1×32px** corner |
| Right fixed | `{{1640, -1036}, {808, 1068}}` | **88×32px** corner |
| Left fixed | `{{1727, -1036}, {808, 1068}}` | **1×32px** corner (unchanged) |
| Bottom fixed | `{{1727, -862}, {808, 981}}` | **1×119px** edge |

### Mechanism

- **Right fixed Dock**: `visibleFrame.maxX` shrinks from ~1728 to ~1640 (Dock takes ~88px).
  Right-hidden windows park at `visibleFrame.maxX - reveal` ≈ 1640, leaving 88px visible
  on screen. Previously ~1px visible; now clearly noticeable.

- **Bottom fixed Dock**: `visibleFrame` shrinks vertically (tiles become 981px tall instead
  of 1068px). The `y=-10000` clamp leaves 119px visible instead of 32px — nearly a
  full-height edge strip again.

- **Left fixed Dock**: does not affect right-hidden windows (`visibleFrame.maxX` unchanged).
  But would increase the left clamp strip from ~40px to ~dock-width for left-hidden
  windows (same mechanism as right dock on right-hidden).

- **Auto-hide**: Dock is not permanently present, so `visibleFrame` equals the full screen
  minus the menu bar. Works the same as no Dock at all.

### What Improved: Corner Parking

The `y=-10000` vertical push (in `layoutTransient` hides) parks windows at the
**top-left or top-right corner** of the screen rather than along the full edge. This
creates a small corner strip (~40×32px) instead of a full-height edge strip
(~40×1068px). While still not hidden, the corner strip is significantly less visually
intrusive.

### Vertical Clamp Variance

The vertical clamp is not an exact constant. Auto-hide traces show 32px (1068−1036),
while earlier traces showed ~34px. The threshold may vary with window size or timing.

## Approaches That Did Not Work

| # | Approach | Result | Evidence |
|---|----------|--------|----------|
| 1 | Retry AX frame writes after `verificationMismatch` | Same clamp, same failure, infinite loop | |
| 2 | Resize window to `1×1` then move | Apps enforce minimum size; some reposition to random y | |
| 3 | `kAXMinimizedAttribute = true` | macOS plays minimize animation to/from Dock — unusable | |
| 4 | `SLSSetWindowOpacity` (opacity 0) | No visible effect on the clamped strip | |
| 5 | `SkyLight.orderWindow(..., .below)` | Strip remains visible (window still rendered at clamped position) | Trace: `liveAXFrame={{1727,-1036},{1626,1068}}` |
| 6 | Keep all columns in normal flow (remove hide) | Far-offscreen frames hit the same clamp for all windows | |
| 7 | `isNearViewport` gate in NiriLayout | Bypassed the hide for columns hidden due to neighboring monitor overflow, causing cross-monitor frame leaking | |
| 8 | `y=-10000` vertical push alone | macOS also clamps y — `y=-10000` becomes `y≈-1034`, leaving ~34px visible | Trace: `hidePlan.verify observed=(1728,-11068)` but live AX shows `liveAXFrame={{1727,-1036},{1626,1068}}` |
| 9 | `SLSWindowSetShape` with 1×1 offscreen region | No visible effect. Regular app windows override the shape on each draw cycle. Only works on windows created via `SLSNewWindow`. | |
| 10 | `SLSTransactionOrderWindow` with mode 1 (kCGSOrderOut) | Transaction ordered the window but `isWindowOrderedIn` still returns `true`. Window remains rendered. | Trace: `hidePlan.orderOut id=985 orderedIn=true` |
| 11 | `SLSOrderWindow` (direct, non-transaction) with mode 1 | Same result — `isWindowOrderedIn` still `true`. Neither transaction nor direct call orders out regular app windows. | Trace: `hidePlan.orderOut id=985 orderedIn=true` |
| 12 | Stale cache in `applyPositionPlans` | `observedWindowOrigin` returned pre-move position from cache, making SkyLight moves appear to fail. Useful diagnostic finding, not a hiding approach. | |
| 13 | Push all hidden windows to x=monitor.maxX (right edge) | With AX fallback this parks windows at the same 1px right-edge position as workspace-inactive hide, but left-hidden windows visibly fly across the screen to get there. Without AX fallback, SkyLight-only moves can leave left-edge clamps. | |
| 14 | `SLSSetWindowTransform` / `CGSSetWindowTransform` raw near-zero scale | API returns success but does not hide external app pixels reliably. Raw scale pulls windows toward global origin, causing random-width left-edge clamp artifacts. | Trace: `hideTransform.apply ... result=CGError(rawValue: 0)` followed by visible artifacts |
| 15 | Anchored `SLSSetWindowTransform` near-zero scale, skip move | API still returns success, but the window remains visually parked at natural left-clamped position — effectively as if nothing happened/worse. Transform is not a usable external-window hide primitive. | |
| 16 | Explicit 1px edge parking on both sides | **Does not work reliably.** This was only a hypothesis and must not be described as confirmed. Slowly approaching the edge can look stable briefly, but after the window is classified hidden/parked, a visible strip can remain stuck on screen (~15px or more observed). | Trace `runtime-trace-1780413107-1780413122.log`: `hideOrigin.resolve ... placement=(1728,8) result=(1728,8) frame=(1726,8 1626x1068)`, then AX fallback targeted `(1727.5,8)` and observed `(1727,8)` for a 1626px-wide window. |

### Why Right-Hidden Windows Can Appear Invisible — But Are Not Reliable

Right-hidden windows can sometimes end up with their **near edge** at ~1px inside the
screen because the layout pushes them just past the right edge. For a narrow window
(852px) on a 1728-wide screen targeting x=1728, macOS may allow x=1727 — the left edge is
still on screen.

This is a coincidence of window width/state/timing, not a universal right-edge behavior.
A 1626px-wide window pushed to x=1728 can be clamped to x=1688 — 40px visible — the same
clamp as the left edge. The clamp threshold depends on window width.

A later hypothesis tried to request the 1px parking position explicitly on both sides
(e.g. right edge `x≈1727`, left edge `x≈minX-width+1`). Runtime testing disproved it as a
solution: slowly approaching the edge may not jump immediately, but once the window is
hidden/parked, a visible strip can remain stuck on screen (~15px or more observed). Do not
reintroduce explicit 1px edge parking as a claimed fix without new runtime evidence.

### Key Insight: `orderWindow(.out)` Silently Ignored for External Windows

```
hidePlan.orderOut id=985 orderedIn=true
```

Both `SLSTransactionOrderWindow(cid, wid, 1, 0)` and `SLSOrderWindow(cid, wid, 1)` are
accepted without error but **do not actually order out windows belonging to other processes**.
The window server appears to protect managed application windows from being ordered out
by external processes. `kCGSOrderOut` (mode 1) likely only works on windows the caller
owns (created via `SLSNewWindow`).

## Pitfalls

### Do Not Claim Runtime WindowServer Fixes Without Manual Confirmation

Private WindowServer/SkyLight/AX behavior cannot be proven by coordinate math or unit
tests. A unit test can only say “Nehir requested coordinate X”; it cannot say “macOS
rendered the external app window hidden/acceptable.” Any future hide attempt must follow
this process:

1. Document it as an **experiment/hypothesis**, not a fix.
2. Capture runtime traces with live AX frames before and after the transition.
3. Visually test slow gesture approach, snap/keyboard navigation, focus change, and
   settled idle state.
4. Test at least narrow and wide windows; wide windows have different clamp behavior.
5. Only after manual confirmation should docs/status say “works”, “fixed”, or “solved”.

If runtime testing disproves an approach, add it to [Approaches That Did Not Work](#approaches-that-did-not-work)
with trace evidence.

### macOS AX Position Clamping

macOS clamps **both** horizontal and vertical positions of full-size windows that would be
completely offscreen. The clamp ensures approximately 40px visible horizontally and ~34px
vertically. The threshold depends on window size. **Never rely on position-based hiding
for full-size windows on macOS.**

### `SLSWindowSetShape` Does Not Work on App Windows

Setting a clip region via `SLSWindowSetShape` only affects windows created through
`SLSNewWindow` (like Nehir's border windows). Regular application windows managed by
their own process override the shape on each draw cycle.

### `orderWindow(.out)` Does Not Work on External Windows

Both `SLSTransactionOrderWindow` and `SLSOrderWindow` with mode 1 (kCGSOrderOut) are
silently ignored for windows owned by other processes. `isWindowOrderedIn` continues
returning `true` after the call. This API only works on windows the caller created.

### Restore Path for Tiled Windows

The `makeRestorePositionPlan` uses proportional positioning within the monitor frame.
This is correct for floating windows (preserves user position) but wrong for tiled windows
whose position is determined entirely by the layout engine. Tiled windows must go directly
to their layout target to avoid a visible intermediate position.

### No Layout Gate for Hide

Do not add a gate in `NiriLayout` that bypasses the hide for columns that
`containerVisibilityState` marked as hidden. The hide decision covers two cases: (1) fully
offscreen, and (2) partially visible but leaking into a neighboring monitor. Both must
remain hidden.

## Current Code Status

All runtime experiments described above were reverted. This document is retained as the
failure log so the same approaches are not retried without new evidence.

**Open problem:** there is no confirmed working solution yet for truly hiding transient
offscreen external app windows.

No failing test is kept in the tree: the runtime behavior depends on WindowServer/private
SkyLight behavior that unit tests can only simulate. A future fix should first be confirmed
manually with layout traces and visual testing, then covered by tests for the code
path/invariants that are under Nehir's control.
