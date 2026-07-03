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

Resize and minimum-size handling intentionally does not use substitute panels or synthetic offscreen geometry. If AX readback proves that an app accepted a larger size than requested, Nehir stores the observed size as an inferred runtime minimum and relayouts with that real constraint. If a vertical stack cannot fit the resulting minimum heights, the Niri column enters transient overflow-tabbed mode instead of asking WindowServer for impossible below-screen positions.

### 2. Layout-Pass Cache Returning Stale Pre-Move Positions — Fixed for Hide Verification

`applyPositionPlans` used `observedWindowOrigin()` which reads through the
`RefreshFrameContext` cache. This cache is populated once per layout pass — the first time
`fastFrame` is called for a token (in `resolveHideOperation`). It caches the window's
**current on-screen position** (e.g., `(1126, 8)`).

After SkyLight moves the window, the verify step read `observedWindowOrigin()` which could
return the **stale cached** value instead of the real post-move position. This made hide
plans appear to fail or obscured the actual WindowServer clamp result.

Fixed: hide-plan verification now bypasses the layout-pass cache and reads live WindowServer bounds (via `AXWindowService.framePreferFast`) when checking post-move positions.

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

### 5. Cross-Monitor Workspace-Inactive Parking Lane — Mitigated

When a window is moved directly to an inactive workspace on another monitor, its live frame
can still be on the source monitor when Nehir computes the workspace-inactive parking
origin. Preserving that source-monitor Y can make WindowServer clamp the window against the
wrong display and leave a large visible strip on the source or adjacent monitor.

Mitigation: workspace-inactive and scratchpad parking now evaluate nearby vertical parking
lanes and prefer candidates that avoid overlap with other monitors while still intersecting
the target monitor's vertical band. This does not remove macOS offscreen clamping, but it
avoids the wrong-display parking coordinates seen in direct built-in ↔ external workspace
assignment traces.

### 6. SkyLight Move Coordinate Bug (Window Height Not Accounted) — Found, Not Yet Fixed

`AXManager.applyPositionsViaSkyLight` converts each requested AppKit top-left origin to a
Quartz (WindowServer) coordinate via a bare point flip (`ScreenCoordinateSpace.toWindowServer(point:)`),
without subtracting the window's height. For a requested AppKit origin `(2055, 7)` with height
`1251` on a 1329-tall screen, this produces Quartz `(2055, 1322)` — placing the window's
top-left near the bottom of the screen, so the window ends up almost entirely below the
visible band rather than at the intended row. `hidePlan.verify` then reads the resulting AX
origin as `(2055, -1244)` (`dy=1251`, exactly the window height), fails the exact-match
check, and falls through to the AX fallback on every single park — the SkyLight move never
actually lands the window at its intended target under the current code path. The correct
height-accounted Quartz coordinate is already computed for diagnostic logging as
`hintedBottomLeft` (e.g. `(2055, 71)` for the same example) but is not used for the move.

This is a genuine, narrow bug independent of the Dock clamp (see finding #17 above): fixing
it makes the SkyLight move land exactly on target and removes the always-AX-fallback
behavior. It does **not** fix Dock-edge parking — WindowServer re-clamps the corrected
SkyLight move too (see #17) — but it is worth fixing on its own, since it currently makes
every park depend on the AX fallback path when SkyLight alone should suffice on non-Dock
edges.

## Status

**PARTIALLY SOLVED (corner parking).** The `layoutTransient` hide pushes windows to
`y=-10000`, which macOS clamps to `y≈-1034`, leaving only a small corner strip
(~40×32px) visible instead of a full-height edge strip (~40×1068px). The corner strip is
less visually annoying than the full-height strip, but the window is still not truly
hidden.

A fixed Dock on a screen edge **makes things worse** for windows hidden to the opposite
side — see [Dock Presence Affects Clamp Strip Size](#dock-presence-affects-clamp-strip-size).

For multi-monitor setups, the practical recommendation is to arrange monitors
**vertically** in macOS System Settings. Side-by-side horizontal displays put another
screen directly next to the horizontal parking edge, so a parked/clamped offscreen window
can bleed onto the neighboring monitor. A vertical arrangement keeps horizontal parking
edges away from adjacent displays and produces a better Niri scrolling experience.

The core problem remains: macOS clamps both axes and no tested API can order out
external app windows. **We are still looking for a working solution.** Do not mark a
runtime workaround as solved from geometry reasoning or unit tests alone; WindowServer
behavior must be confirmed manually in a real trace/run first.

Useful confirmed findings:

- macOS clamps both horizontal and vertical offscreen positions for external app windows.
- The stale `RefreshFrameContext` cache can make hide verification misleading; hide-plan
  verification now bypasses that cache and reads live WindowServer bounds when checking
  post-move positions.
- Direct moves to inactive workspaces on another monitor can preserve a source-display Y;
  workspace-inactive parking should choose a target-monitor vertical lane to avoid
  wrong-display clamp strips.
- Workspace-inactive hiding appears acceptable because it parks windows at the physical
  screen edge with ~1px visible; this is not a true hide. Some apps (confirmed with a
  Zoom call window) clamp to a larger visible strip if requested exactly at the edge,
  so workspace-inactive parking uses the same 1pt reveal limitation as transient
  parking rather than an app-specific special case.
- Picture-in-Picture surfaces can report fresh app activation/focus after Nehir parks
  them. For manually-unstuck PiP/default-sticky windows, the focus layer must suppress
  unrelated hidden-inactive activation churn; otherwise native activation can reveal the
  parked PiP again even though the hide plan itself requested the correct edge position.
- Using that same right-edge parking for transient left-hidden windows removes the parked
  left corner but causes a visible left-to-right fly during the hide transition.
- **Unconfirmed hypotheses are not fixes.** A proposed hide strategy may be implemented
  only as an experiment until runtime traces and visual testing confirm it. Unit tests can
  cover our chosen coordinates and invariants, but they cannot prove WindowServer accepts
  or renders the result correctly.

## Multi-Monitor Arrangement Recommendation

Nehir's Niri layout scrolls columns horizontally, and transient hiding parks windows near
horizontal screen edges. Because macOS will not truly move full-size external app windows
fully offscreen, any parked/clamped remnant near a horizontal edge can become visible on a
neighboring display when monitors are arranged side-by-side.

For best results, arrange displays **vertically** in macOS System Settings (`Displays >
Arrange`). A vertical arrangement prevents horizontal parking edges from touching another
monitor, which avoids the most visible cross-monitor bleed. Side-by-side monitor layouts
are a known degraded configuration for transient parked-window hiding.

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

### Confirmed: The Dock-Edge Clamp Applies to SkyLight Moves Too, Not Just AX

A later session measured a right-hidden window (1011px wide) on a 2056-wide screen with a
fixed right Dock (`visibleFrame.maxX=1969`, ≈87px Dock inset). Requesting the near-edge
target `x=2055` (physical edge − 1px reveal) through the **uncorrected** SkyLight move (see
finding #6/#17) always fell through to the AX fallback, which clamped to `x=1929` — a 127px
strip (87px Dock + 40px standard clamp).

After fixing the SkyLight move's coordinate bug (see [SkyLight Move Coordinate Bug](#6-skylight-move-coordinate-bug-window-height-not-accounted--found-not-yet-fixed))
so the move lands exactly on `(2055, 7)` with no AX fallback triggered, the window's live
frame still drifted back to `x=1943` (a ~113px strip) on the very next layout snapshot, with
no further Nehir frame write in between. **The Dock-edge clamp is a WindowServer-level
re-clamp that applies to a SkyLight-placed window just as it applies to an AX-placed one.**
Neither backend can hold a window past the Dock-reserved region on the Dock's own edge. See
finding #17 in [Approaches That Did Not Work](#approaches-that-did-not-work).

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
| 10 | `SLSTransactionOrderWindow` with order-out mode (`kCGSOrderOut`, raw value `0`) | Transaction ordered the window but `isWindowOrderedIn` still returns `true`. Window remains rendered. | Trace: `hidePlan.orderOut id=985 orderedIn=true` |
| 11 | `SLSOrderWindow` (direct, non-transaction) with order-out mode (`kCGSOrderOut`, raw value `0`) | Same result — `isWindowOrderedIn` still `true`. Neither transaction nor direct call orders out regular app windows. | Trace: `hidePlan.orderOut id=985 orderedIn=true` |
| 12 | Stale cache in `applyPositionPlans` | `observedWindowOrigin` returned pre-move position from cache, making SkyLight moves appear to fail or hiding the real clamp result. Fixed for hide verification by reading live WindowServer bounds; useful diagnostic finding, not a hiding approach. | |
| 13 | Push all hidden windows to x=monitor.maxX (right edge) | With AX fallback this parks windows at the same 1px right-edge position as workspace-inactive hide, but left-hidden windows visibly fly across the screen to get there. Without AX fallback, SkyLight-only moves can leave left-edge clamps. | |
| 14 | `SLSSetWindowTransform` / `CGSSetWindowTransform` raw near-zero scale | API returns success but does not hide external app pixels reliably. Raw scale pulls windows toward global origin, causing random-width left-edge clamp artifacts. | Trace: `hideTransform.apply ... result=CGError(rawValue: 0)` followed by visible artifacts |
| 15 | Anchored `SLSSetWindowTransform` near-zero scale, skip move | API still returns success, but the window remains visually parked at natural left-clamped position — effectively as if nothing happened/worse. Transform is not a usable external-window hide primitive. | |
| 16 | Explicit 1px edge parking on both sides | **Intermittent mitigation, not a complete fix.** The approach improves the common non-Dock-edge case, but must not be described as fully confirmed or universally reliable. Slowly approaching the edge can look stable briefly, but after the window is classified hidden/parked, a visible strip can remain stuck on screen (~15px or more observed). A later physical-frame variant showed some windows parked at `-851`/`1727`, while another stale/cached-hidden window remained live-clamped at `-812`. | Evidence: one right-edge run requested `placement=(1728,8) result=(1728,8)` for `frame=(1726,8 1626x1068)`, then AX fallback targeted `(1727.5,8)` and observed `(1727,8)` for a 1626px-wide window. Another run requested `experiment=physicalEdge1pt ... result=(-851,8)`, but layout decisions showed one window with `target=-852 ... live=-812`, while neighboring hidden windows were `live=-851`. |
| 17 | SkyLight-only move to the physical edge, past the Dock, with the AX fallback made unreachable by fixing the SkyLight move's coordinate | **Disproven — WindowServer re-clamps the SkyLight move itself, not just the AX fallback.** `AXManager.applyPositionsViaSkyLight` was found to feed the wrong Quartz coordinate for the move (it flips the window's AppKit top-left as a bare point, without subtracting window height, so the intended near-edge origin lands far below the real screen). Feeding it the height-corrected coordinate made the SkyLight move land exactly on the requested near-edge target and let `hidePlan.verify` pass with no AX fallback — but with a fixed Dock on the parking edge, the window's live frame still drifted back onto the Dock-reserved region afterward, with **zero further Nehir frame writes issued**. WindowServer re-clamps the SkyLight-placed window on its own, the same way it re-clamps the AX fallback. | Evidence: a right park requested `(2055,7)` on a 2056-wide screen with `visibleFrame.maxX=1969` (87px right Dock inset). Corrected-coordinate SkyLight move: `hidePlan.verify requested=(2055,7) observed=(2055,7) dx=0.0 dy=0.0 fallback=no`, `hidePlan.final ... verified=false`, `parking_verify_mismatch backend=skylight ... visibleRisk=false` — the move landed exactly on target with no fallback triggered. No further frame-apply call for that window followed. The next layout snapshot nonetheless showed the window's live frame at `1943` (`hidden:right`), a ~113px strip (`2056 − 1943`), matching the same clamp family as the AX-fallback case (`1929` in the uncorrected run). Since Nehir issued nothing between the confirmed `(2055,7)` verify and the observed `1943` drift, the re-clamp is WindowServer's, not Nehir's animation writer's. |

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

Both `SLSTransactionOrderWindow(cid, wid, 0, 0)` and `SLSOrderWindow(cid, wid, 0)` are
accepted without error but **do not actually order out windows belonging to other processes**.
The window server appears to protect managed application windows from being ordered out
by external processes. `kCGSOrderOut` (raw value `0`) likely only works on windows the
caller owns (created via `SLSNewWindow`).

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

Both `SLSTransactionOrderWindow` and `SLSOrderWindow` with order-out mode
(`kCGSOrderOut`, raw value `0`) are silently ignored for windows owned by other
processes. `isWindowOrderedIn` continues returning `true` after the call. This API
only works on windows the caller created.

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

## Code Status

Failed runtime experiments described above were reverted unless explicitly called out as
active below. This document is retained as the failure log so the same approaches are not
retried without new evidence.

**Open problem:** there is no confirmed working solution yet for truly hiding transient
offscreen external app windows.

Active experiment in the tree: explicit 1pt parking on the **physical monitor frame** for
both sides, without the `y=-10000` vertical push and without using `visibleFrame` edges.
This is only a hypothesis under test. Do not promote it to a fix unless runtime traces and
visual testing confirm the settled idle state is acceptable for both narrow and wide
windows. Look for trace marker `experiment=physicalEdge1pt`.

Iteration finding: live AX evidence suggests one failure mode is stale cached /
last-applied state. Nehir can classify a window as already parked because its cached frame
is near the 1pt target, while live AX has drifted/clamped to a larger visible strip
(`live=-812` instead of requested `-851`). The experiment logs
`hidePlan.staleCachedAlreadyHidden` and re-applies the parking move when live AX disagrees
with the cached already-hidden decision.

Iteration finding: visual testing showed parking can happen too late. The window approaches
the edge, then jumps when it takes the final parked position. The experiment pre-parks
when only a small edge sliver remains visible (`preParkMargin = 16` in
`NiriLayout.containerIntersectsViewport`) so the parking move is triggered slightly before
exact zero intersection.

Iteration finding: fixed Dock should be treated as degraded / unsupported for now, not
something to tune further with trigger math. In one right-Dock run,
`visibleFrame.maxX=1641` while `frame.maxX=1728` (Dock inset ≈87px). macOS may reject /
adjust 1pt parking on the Dock-owned physical edge and leave roughly Dock-width + extra
visible. A dock-aware trigger experiment (`basePreParkMargin + dockInsetOnThatEdge`) was
tried and then reverted: it can change when the parking move happens, but it cannot force
WindowServer to accept the final parked coordinate on the Dock-owned physical edge.

Support stance for fixed Dock: transient hiding is expected to work best with auto-hide
Dock or with the fixed Dock on a non-parking edge. Fixed Dock on the target parking edge is
a known degraded/unsupported configuration until a non-position-based hide primitive is
found.

Current workspace-inactive parking uses the physical monitor frame and a 1pt reveal for
all apps. This avoids a narrow Zoom-only workaround: the confirmed Zoom call-window issue
is treated as evidence that exact-edge requests can trigger a wider WindowServer clamp for
some windows/classes, not as a property unique to Zoom.

Known limitation: Nehir's window "hide" is still position-based parking, not a real
WindowServer order-out. Parked windows can still expose a thin edge/corner and their
shadows along screen sides. This is expected until a non-position-based hide primitive is
found.

No failing test is kept in the tree: the runtime behavior depends on WindowServer/private
SkyLight behavior that unit tests can only simulate. A future fix should first be confirmed
manually with layout traces and visual testing, then covered by tests for the code
path/invariants that are under Nehir's control.

## Iteration: Fixed-Dock Edge Confirmed Unbeatable Positionally (SkyLight Included)

A follow-up investigation set out to answer whether a fixed Dock on the parking edge could
be fixed by routing the park through SkyLight instead of the AX fallback, since SkyLight
moves are not documented to hit the same clamp as `AXUIElementSetAttributeValue`. Two things
were established (see finding #17 in [Approaches That Did Not Work](#approaches-that-did-not-work)
and [SkyLight Move Coordinate Bug](#6-skylight-move-coordinate-bug-window-height-not-accounted--found-not-yet-fixed)):

1. `AXManager.applyPositionsViaSkyLight` has a real, narrow coordinate bug (window height
   not accounted for in the AppKit→Quartz flip) that makes every park fall through to the AX
   fallback regardless of Dock presence. This is worth fixing independently of the Dock
   question.
2. Once that bug is corrected and the SkyLight move lands exactly on the requested near-edge
   target with no AX fallback triggered, a fixed Dock on the parking edge still re-clamps the
   window back onto the Dock-reserved region on its own, with no further Nehir frame write in
   between the confirmed on-target verify and the observed drift. This rules out "avoid the
   AX fallback" as a fix for the Dock case: the clamp is enforced by WindowServer against
   both backends.

**Conclusion: no positional primitive available to Nehir (AX or SkyLight) can hold a window
past the Dock-reserved region on the Dock's own parking edge.** The support stance from the
prior iteration — fixed Dock on the target parking edge is a known degraded/unsupported
configuration — stands, and is now confirmed for the SkyLight path as well, not just AX.

The active direction going forward is **virtual-display parking**: creating a display with
no physical screen and parking hidden windows fully inside its frame, so the park never
approaches a real screen or Dock-reserved edge at all. A feasibility spike already confirmed
the core hypothesis — a window parked fully inside a virtual display's frame is not clamped
and its AX-observed origin matches the requested target exactly, while the window remains
alive/ordered-in and invisible on the real display. A full single-display integration attempt
is in progress in a separate branch, reusing the spike's private-API loader
(`Sources/Nehir/Core/SkyLight/VirtualParkDisplay.swift`) as its starting point. Do not mark
virtual-display parking as fixed/solved until it is manually confirmed end-to-end (workspace
bar, gestures, focus, and reveal all still functioning, plus visual confirmation of no strip
on the real display) per the pitfalls above — a clean compile is not sufficient evidence.
