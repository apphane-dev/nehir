# Offscreen Window Clamp Fix

## Bug

When scrolling through a Niri horizontal column layout via trackpad gesture, keyboard
navigation, or focus change, fully-offscreen columns appeared as a visible strip (~40 px
wide) at the left or right display edge. The strip persisted even after the gesture or
animation completed, creating the impression of a "parked leftover" window.

A secondary symptom: when switching between workspaces, tiled windows appeared at
overlapping positions or failed to render until a gesture was performed.

## Root Cause

### 1. macOS AX/WindowServer Offscreen Position Clamping

macOS **clamps the horizontal position** of a full-size window that would be moved
completely offscreen. Instead of accepting the target x-coordinate, WindowServer parks the
window so that approximately 40 pixels remain visible at the display edge.

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

The clamp applies symmetrically on both edges. Right-edge windows targeting `x=3448`
(on a 1720-wide screen) were clamped to `x=1688`, also leaving ~40px visible.

**Critically, macOS does NOT clamp the vertical (y) position.** Windows can be moved to
arbitrary y coordinates (confirmed at `y=-460`, `y=-261`, and ultimately `y=-10000`).

### 2. Stale Gesture Viewport Regression

`WorkspaceManager.applySessionPatch` could apply a stale gesture-era viewport snapshot
that overwrote a later snap animation target, causing the viewport to "pull back" toward a
previous position.

### 3. Proportional Restore for Tiled Windows

When switching workspaces, tiled windows being restored from `workspaceInactive` hidden
state were first moved to a proportional "restore position" within the monitor, then
async moved to their actual layout target. During the gap, windows appeared at wrong
positions causing visible overlaps and missing columns.

## Fix

### A. Push Hidden Windows Vertically Offscreen (`LayoutRefreshController.swift`)

Since macOS does not clamp y-coordinates, transient-hidden windows are moved to
`y = -10000` instead of relying on the horizontal edge. The clamped x-coordinate is
irrelevant because the window is thousands of pixels above the screen.

Additionally, hidden windows are ordered below other windows via `SkyLight.orderWindow`
for defense-in-depth, and restored to above when revealed.

```swift
// In liveFrameHideOrigin(), .layoutTransient case:
let offscreenY: CGFloat = -10000
return CGPoint(x: placement.origin.x, y: offscreenY)
```

A guard also clamps the orthogonal origin to the monitor's visible frame bounds, so a
window already at a bad y-position doesn't propagate that bad coordinate into the hidden
placement.

### B. Guard Against Stale Gesture Snapshots (`WorkspaceManager.swift`)

`applySessionPatch` now detects when a patch carries a `.gesture` viewport state and
replaces it with the live state (and discards `rememberedFocusToken`), preventing stale
gesture snapshots from regressing the viewport.

### C. Direct-to-Target Restore for Tiled Windows (`LayoutRefreshController.swift`)

When switching workspaces, tiled windows being restored from `workspaceInactive` hidden
state now go directly to their layout target frame, skipping the intermediate proportional
position. Floating windows still use the proportional restore path to preserve
user-positioned floating window placement.

## Approaches That Did Not Work

| Approach | Result |
|----------|--------|
| Retry AX frame writes after `verificationMismatch` | Same clamp, same failure, infinite loop |
| Resize window to `1×1` then move | Apps enforce minimum size; some reposition to random y |
| `kAXMinimizedAttribute = true` | macOS plays minimize animation to/from Dock — unusable |
| `SLSSetWindowOpacity` (opacity 0) | No visible effect on the clamped strip |
| `SkyLight.orderWindow(..., .below)` alone | Strip remains visible (window still rendered) |
| Keep all columns in normal flow (remove hide) | Far-offscreen frames hit the same clamp for all windows |
| `isNearViewport` gate in NiriLayout | Bypassed the hide for columns hidden due to neighboring monitor overflow, causing cross-monitor frame leaking |

## Pitfalls

### macOS AX Horizontal Clamp

Any window whose full width would be completely offscreen (i.e., `x + width < 0` or
`x > screen_width`) gets clamped. The threshold depends on window size — a narrow window
can be pushed further offscreen before clamping kicks in. **Never rely on horizontal
offscreen placement for full-size windows on macOS.**

### Vertical Position Is Free

macOS imposes no practical limit on y-coordinates. This is the basis of the y=-10000 fix.
However, this could change in future macOS versions. If it does, the fallback would be
`SkyLight.orderWindow(..., .out)` to remove the window from the window list entirely, but
that approach requires careful lifecycle management.

### Restore Path for Tiled Windows

The `makeRestorePositionPlan` uses proportional positioning within the monitor frame.
This is correct for floating windows (preserves user position) but wrong for tiled windows
whose position is determined entirely by the layout engine. Tiled windows must go directly
to their layout target to avoid a visible intermediate position.

### No Layout Gate for Hide

Do not add a gate in `NiriLayout` that bypasses the hide for columns that `containerVisibilityState`
marked as hidden. The hide decision covers two cases: (1) fully offscreen, and (2) partially
visible but leaking into a neighboring monitor. Both must remain hidden. The y=-10000 fix
handles case 1 without needing any layout-level bypass.

## Files Changed

| File | Change |
|------|--------|
| `Sources/Nehir/Core/Controller/LayoutRefreshController.swift` | Vertical offscreen push (y=-10000), order below/above, orthogonal clamp, direct-to-target tiled restore |
| `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` | Stale gesture guard in `applySessionPatch` |
