# Ghostty Quick Terminal gesture suppression trade-off

Status: no-op for now — after restoring screen-share trackpad gestures, Nehir can again accept workspace gestures while the pointer is over Ghostty Quick Terminal in the field-empty / snapshot-only case. That is an intentional trade-off for the current fix: do not reintroduce broad WindowServer snapshot-only gesture suppression unless we can distinguish interactive overlays from screen-share / capture / presenter surfaces with stronger evidence.

Related plan: `planned/20260701-screen-share-gesture-overlay-suppression.md`.

## Decision

Keep the screen-share fix as implemented: gesture unmanaged-overlay suppression should trust only an event-provided `windowUnderPointer` id. If gesture events report `windowUnderPointer=nil`, do not run the broad unmanaged-overlay WindowServer snapshot fallback for gestures.

Consequence: Ghostty Quick Terminal may no longer block Nehir's three-finger workspace gesture when the gesture event path provides no window id. This is preferable to globally breaking gestures during screen sharing.

Do not fight this back by restoring the old snapshot-only gesture fallback. A future follow-up is only worth doing if it is narrower than the old predicate and is validated against both cases:

1. Ghostty Quick Terminal should block gestures when there is strong evidence that the pointer is over that interactive overlay.
2. Screen-share / capture / presenter surfaces must not block gestures when gesture events have no `windowUnderPointer`.

## Why the old behavior existed

Commit `d2827df2` (`Implement focus-follows-mouse suppression for unmanaged overlay`) added a gesture snapshot fallback alongside FFM overlay suppression. The gesture path set `shouldProbeWindowServerOverlay` when:

```swift
snapshot.windowUnderPointer == nil
&& state.gesturePhase == .idle
&& phase != .ended
&& phase != .cancelled
&& activeTouchCount > 0
```

It then treated `controller.unmanagedOverlayWindowServerWindowCovers(point:)` as a gesture blocker and emitted:

```text
gesture.skip reason=unmanagedOverlay ... windowUnderPointer=nil snapshotProbe=true
```

That protected cases such as an unmanaged interactive overlay being geometrically under the pointer even when the gesture event did not provide a usable WindowServer window id.

Separately, commit `56573ba2` (`Fix focus-follows-mouse blocked by click-through overlays (#64)`) preserved Ghostty Quick Terminal behavior for focus-follows-mouse by keeping interactive overlay suppression while exempting known decorative click-through border overlays. That FFM policy remains valid and should not be weakened by the gesture fix.

## Why it was removed for gestures

The same broad snapshot-only gesture fallback also classified screen-share / capture / presenter surfaces as unmanaged overlays. In the screen-share failure, valid three-finger samples arrived, but the first eligible three-finger sample had `windowUnderPointer=nil`, ran the snapshot fallback, emitted `gesture.skip reason=unmanagedOverlay`, set `suppressGestureUntilTouchesEnd=true`, and then dropped the rest of the finger sequence as `gesture.skip reason=suppressed`.

The representative failure sequence was:

```text
gesture.skip reason=underCount loc=(1495.5,844.8) requiredFingers=3 activeTouches=1 phase=1
gesture.skip reason=underCount loc=(1495.5,844.8) requiredFingers=3 activeTouches=1 phase=4
gesture.skip reason=underCount loc=(1495.5,844.8) requiredFingers=3 activeTouches=2 phase=4
gesture.skip reason=unmanagedOverlay loc=(1495.5,844.8) windowUnderPointer=nil snapshotProbe=true
gesture.skip reason=suppressed loc=(1495.5,844.8) activeTouches=3 phase=4
gesture.skip reason=suppressed loc=(1495.5,844.8) activeTouches=3 phase=4
gesture.skip reason=suppressed loc=(1495.5,844.8) activeTouches=3 phase=4
```

There were no `touch_scroll_gesture_armed`, `touch_scroll_gesture_committed`, or `touch_scroll_gesture_update` records in that capture, proving that snapshot-only overlay suppression prevented the workspace gesture from starting.

The implemented fix removed the gesture snapshot-only fallback while preserving the direct-number path:

```swift
let isOverUnmanagedOverlay = controller.unmanagedWindowServerWindowCovers(
    point: location,
    windowUnderPointer: snapshot.windowUnderPointer,
    allowWindowServerSnapshotFallback: false
)
```

## Evidence for the Ghostty trade-off

After the screen-share fix, a short capture while swiping over the Ghostty Quick Terminal scenario recorded gesture input being accepted instead of suppressed.

Relevant runtime state:

```text
enabled=true focusFollowsMouse=true moveMouseToFocusedWindow=false
interactionWorkspace=42901D99-68BB-4AC6-A225-1991E2F7BF85
interactionMonitor=ID(displayId: 1)
nonManaged=true

WindowToken(pid: 1105, windowId: 10820)
workspace=42901D99-68BB-4AC6-A225-1991E2F7BF85
mode=tiling phase=tiled hidden=nil observedVisible=true
bundleId=com.mitchellh.ghostty
role=AXWindow subrole=AXStandardWindow windowLevel=0

-- Visible Unmanaged WindowServer Windows --
none
```

During the swipe, mouse-moved event diagnostics repeatedly had empty WindowServer window fields:

```text
tap.mouseMoved direct=0 canHandle=0 resolved=nil loc=(1387.6,1049.4)
tap.mouseMoved direct=0 canHandle=0 resolved=nil loc=(1387.1,1045.0)
tap.mouseMoved direct=0 canHandle=0 resolved=nil loc=(1386.1,1040.7)
tap.mouseMoved direct=0 canHandle=0 resolved=nil loc=(1385.1,1035.6)
```

The gesture then reached the workspace scroll path:

```text
touch_scroll_gesture_armed input=trackpadTouches requiredFingers=3 activeTouches=3 phase=4 startTouch=0.492,0.626
touch_scroll_gesture_committed input=trackpadTouches requiredFingers=3 activeTouches=3 cumulativeX=-11.966 cumulativeY=-11.116 threshold=16.000
touch_scroll_gesture_update input=trackpadTouches delta=29.916 phase=committed currentOffset=-805.5 targetOffset=-805.5 gesture=true
touch_scroll_gesture_update input=trackpadTouches delta=6.480 phase=committed currentOffset=-796.5 targetOffset=-796.5 gesture=true
```

This is the expected result of disabling snapshot-only gesture blocking: with no direct event window id, the handler has no reliable direct-window evidence that an unmanaged interactive overlay should own the gesture.

## Why not restore Ghostty blocking immediately

Restoring the old behavior would require reintroducing snapshot-only gesture suppression. The available predicate is intentionally broad: regular on-screen unmanaged WindowServer surfaces with sufficient size and positive layer can satisfy it. That is exactly what made screen-share/capture surfaces block gestures.

A Ghostty-specific rollback would therefore risk re-breaking the primary bug unless it uses a stricter discriminator than the old fallback. Candidate directions, if this becomes worth revisiting:

- collect gesture-time snapshot candidate diagnostics: window id, owner pid/name, bundle id, window title, layer, bounds, activation policy, tracked/owned status;
- prove the Ghostty Quick candidate has metadata that screen-share/capture/presenter surfaces do not share;
- make any new predicate gesture-specific, not shared with FFM;
- add paired tests: Ghostty-like interactive overlay blocked, screen-share-like regular capture surface not blocked;
- consider an explicit user-facing exclusion/blocklist only if structural discrimination remains unreliable.

Until then, the safer policy is: direct unmanaged `windowUnderPointer` still suppresses gestures; snapshot-only unmanaged overlays do not.
