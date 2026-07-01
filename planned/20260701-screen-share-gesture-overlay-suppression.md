# Screen share gesture is suppressed by unmanaged-overlay snapshot fallback — Plan

Status: planned — the runtime evidence shows Nehir receiving three-finger gesture samples during a screen-share session, but every attempt is aborted by the unmanaged-overlay guard before the gesture can arm or commit. The source path and root cause are visible.

Validated against `main` on 2026-07-01 at commit `07ce4168` (`Reconcile stale hidden-window live frames`).

## Summary

During screen sharing, trackpad workspace gestures do not work because `MouseEventHandler.handleGestureEvent` treats an empty `windowUnderPointer` on an idle gesture as permission to run the WindowServer snapshot overlay fallback. That fallback reports a regular, on-screen, unmanaged WindowServer surface covering the gesture point, so the handler emits `gesture.skip reason=unmanagedOverlay`, aborts any active gesture, sets `suppressGestureUntilTouchesEnd = true`, and then drops the rest of that finger sequence as `gesture.skip reason=suppressed`.

The result is not a missing input problem: the trace contains many three-finger samples. The problem is that the first valid three-finger sample in each attempt is classified as being over an unmanaged overlay, so the gesture is suppressed before Nehir reaches the arming / commit path.

## Runtime evidence

A 3.675 s capture from 2026-07-01 `10:41:22Z` to `10:41:26Z` recorded a two-display setup:

```text
WMController runtime state
enabled=true desiredEnabled=true hotkeysEnabled=true desiredHotkeysEnabled=true
accessibilityGranted=true lockScreenActive=false overviewOpen=false startedServices=true
focusFollowsMouse=true moveMouseToFocusedWindow=false mouseWarpEnabled=false mouseWarpPolicyEnabled=false
displaySpacesMode=enabled

-- Monitor Topology --
ID(displayId: 1) isMain=true hasNotch=true frame=(0.0, 0.0, 1728.0, 1117.0) visibleFrame=(0.0, 0.0, 1728.0, 1084.0) name=Built-in Retina Display
ID(displayId: 3) hasNotch=false frame=(-104.0, 1117.0, 1920.0, 1080.0) visibleFrame=(-104.0, 1117.0, 1920.0, 1050.0) name=HP Z27k G3
```

The workspace did not enter gesture state in the capture:

```text
workspace=1 id=E9B2B3C5-57E7-4588-93F9-4541FB426113 visible=true columns=5 activeColumnIndex=1 currentOffset=-70.9 targetOffset=-70.9 currentViewStart=991.2 targetViewStart=991.2 gesture=false animating=false selectedNode=NodeId(uuid: 58C92917-D813-4E33-968A-E13D0BF79C99) preferredFocus=WindowToken(pid: 48720, windowId: 10784) restore=nil activatePrev=-70.9
```

The mouse / gesture trace contained these skip counts:

```text
gesture.skip reason=underCount: 131
gesture.skip reason=suppressed: 128
gesture.skip reason=unmanagedOverlay: 8
gesture.skip reason=ownWindow: 1
```

The important sequence repeats several times. One representative attempt:

```text
2026-07-01T10:41:23Z gesture.skip reason=underCount loc=(1495.5,844.8) requiredFingers=3 activeTouches=1 phase=1
2026-07-01T10:41:23Z gesture.skip reason=underCount loc=(1495.5,844.8) requiredFingers=3 activeTouches=1 phase=4
2026-07-01T10:41:23Z gesture.skip reason=underCount loc=(1495.5,844.8) requiredFingers=3 activeTouches=2 phase=4
2026-07-01T10:41:23Z gesture.skip reason=unmanagedOverlay loc=(1495.5,844.8) windowUnderPointer=nil snapshotProbe=true
2026-07-01T10:41:23Z gesture.skip reason=suppressed loc=(1495.5,844.8) activeTouches=3 phase=4
2026-07-01T10:41:23Z gesture.skip reason=suppressed loc=(1495.5,844.8) activeTouches=3 phase=4
2026-07-01T10:41:23Z gesture.skip reason=suppressed loc=(1495.5,844.8) activeTouches=3 phase=4
```

The same pattern repeats at `10:41:23Z`, `10:41:24Z`, and `10:41:25Z`: after one- and two-finger prelude samples, the first overlay check with `windowUnderPointer=nil snapshotProbe=true` suppresses the finger sequence, and subsequent valid three-finger samples are rejected as `suppressed`.

There are no `touch_scroll_gesture_armed`, `touch_scroll_gesture_committed`, or `touch_scroll_gesture_update` records in this capture. That confirms the gesture handler never reached the normal workspace-scroll path.

## Source-backed root cause

### Gesture snapshots can have no WindowServer window id

`Sources/Nehir/Core/Controller/MouseEventHandler.swift:2454-2467` builds `GestureEventSnapshot` from the raw gesture event. Its `windowUnderPointer` is resolved from CGEvent window-under-pointer fields, with `NSEvent.windowNumber` only as a fallback:

```swift
windowUnderPointer: windowUnderPointer(from: cgEvent)
    ?? (nsEvent.windowNumber > 0 ? nsEvent.windowNumber : nil),
```

The trace proves the screen-share gesture events arrived with no usable window id:

```text
gesture.skip reason=unmanagedOverlay loc=(1495.5,844.8) windowUnderPointer=nil snapshotProbe=true
```

### Empty `windowUnderPointer` enables snapshot overlay probing for idle gestures

`Sources/Nehir/Core/Controller/MouseEventHandler.swift:1496-1505` sets `shouldProbeWindowServerOverlay` exactly when the gesture is idle, non-ended, has active touches, and `snapshot.windowUnderPointer == nil`:

```swift
let shouldProbeWindowServerOverlay = snapshot.windowUnderPointer == nil
    && state.gesturePhase == .idle
    && phase != .ended
    && phase != .cancelled
    && activeTouchCount > 0
let isOverUnmanagedOverlay = controller.unmanagedWindowServerWindowCovers(
    point: location,
    windowUnderPointer: snapshot.windowUnderPointer,
    allowWindowServerSnapshotFallback: false
) || (shouldProbeWindowServerOverlay && controller.unmanagedOverlayWindowServerWindowCovers(point: location))
```

Because `windowUnderPointer=nil`, the direct-number path cannot identify the real target under the pointer. The code therefore asks the WindowServer snapshot fallback whether some unmanaged overlay covers the gesture point.

### A positive overlay result suppresses the whole touch sequence

`Sources/Nehir/Core/Controller/MouseEventHandler.swift:1506-1516` handles the positive result:

```swift
if isOverUnmanagedOverlay,
   phase != .ended,
   phase != .cancelled,
   activeTouchCount > 0
{
    traceMouseFocus(
        "gesture.skip reason=unmanagedOverlay ..."
    )
    abortActiveGestureIfNeeded()
    state.suppressGestureUntilTouchesEnd = true
    return
}
```

Then `Sources/Nehir/Core/Controller/MouseEventHandler.swift:1462-1473` drops later samples from the same touch sequence while fingers remain active:

```swift
if state.suppressGestureUntilTouchesEnd {
    if phase == .ended || phase == .cancelled || activeTouchCount == 0 {
        state.suppressGestureUntilTouchesEnd = false
    } else {
        traceGestureSkip(reason: "suppressed", ...)
        return
    }
}
```

This maps directly to the trace: `unmanagedOverlay` is immediately followed by many `suppressed activeTouches=3` records.

### The overlay fallback is broad enough to classify screen-share surfaces as blockers

`Sources/Nehir/Core/Controller/WMController.swift:3219-3231` calls `visibleUnmanagedOverlayWindowServerWindowCovers` with the current tracked Nehir window ids. `WMController.swift:3250-3284` returns `true` for any snapshot window that:

- has `layer >= 0`;
- is on screen;
- has finite bounds at least `80 x 80`;
- contains the gesture point;
- is not Nehir-owned;
- is not a tracked Nehir window id;
- belongs to a regular activation-policy app.

That predicate is intentionally conservative for interactive overlays, but during screen sharing it is too conservative for gestures: a screen-share / presenter / capture surface can be regular, visible, large enough, and unmanaged while still not being a reason to disable Nehir workspace gestures. When the raw gesture event also lacks `windowUnderPointer`, Nehir cannot distinguish that case and suppresses the gesture globally until fingers lift.

## Fix direction

Make gesture overlay suppression less aggressive than focus-follows-mouse suppression.

Recommended implementation:

1. Split the overlay policy into a gesture-specific predicate, for example `unmanagedGestureBlockingWindowServerWindowCovers(point:)`.
2. Keep the direct `windowUnderPointer` fast path: if the event identifies a real unmanaged interactive window under the pointer, continue suppressing gestures over it.
3. For `windowUnderPointer == nil` snapshot fallback, do not treat every regular unmanaged snapshot window as gesture-blocking. Either:
   - disable snapshot fallback for gestures entirely; or
   - require stronger evidence that the surface is truly interactive and not a screen-share/capture/presenter surface.
4. Add diagnostics to the fallback result before changing behavior: trace the candidate `windowId`, owner pid/name, bundle id, layer, frame, activation policy, and whether it was tracked/owned. The current `gesture.skip reason=unmanagedOverlay` proves the branch but not the exact snapshot candidate.

The safest first fix is to disable snapshot fallback for gestures when `windowUnderPointer == nil`, while preserving the direct-number suppression path. This should restore screen-share gestures and avoid regressing the case where the event itself identifies an unmanaged overlay.

## Tests

Add unit coverage in `Tests/NehirTests/MouseEventHandlerTests.swift`:

1. **Nil-window gesture over snapshot-only overlay should not suppress.** Configure a regular unmanaged overlay in `unmanagedOverlayWindowInfoProvider`, send a gesture snapshot with `windowUnderPointer=nil`, three active touches, and assert that Nehir does not emit `gesture.skip reason=unmanagedOverlay` / `suppressed` and proceeds to the arming path.
2. **Direct unmanaged window id still suppresses.** Send a gesture snapshot with `windowUnderPointer` set to an untracked, unowned window id and assert `gesture.skip reason=unmanagedOverlay` is still emitted.
3. **Suppression state clears on touch end.** Preserve existing behavior that once suppression is intentionally entered, `phase=.ended`, `phase=.cancelled`, or `activeTouchCount=0` clears `suppressGestureUntilTouchesEnd`.

Also add or update `WMController` predicate tests if a new gesture-specific overlay predicate is introduced.
