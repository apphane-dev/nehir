# Do not warp the cursor to a window's center when it is already inside

Verified against main `3056bee8` on 2026-07-14. **Re-verify line numbers before
editing; they drift.**

**Status:** planned.
**Symptom:** When focus is moved to a window whose frame already contains the
pointer, Nehir still warps the cursor to that window's geometric center, yanking
it away from where the user is pointing/clicking. Reported upstream as
`BarutSRB/OmniWM#446` and fixed by commit `b243d36f` ("Keep the pointer where
users click").
**Desired behavior:** if the pointer is already inside the target window's frame,
skip the warp entirely; leave the cursor where it is. Warping still happens when
the cursor is outside the target (e.g. keyboard-driven focus of a window on
another monitor).

Root cause and prior-sweep context (this was flagged 🔴 in the 2026-07-07 sweep;
`b243d36f` is the clean complementary backstop to Nehir's existing click-token
suppression): see
[`discovery/20260714-upstream-post-roadmap-candidates.md`](../discovery/20260714-upstream-post-roadmap-candidates.md).

## Root cause (inline recap — confirmed in source)

`WMController.moveMouseToWindow(_:preferredFrame:reason:)` computes
`center = frame.center` and warps to it after only two guards — the center must
be on some screen, and no mouse button may be pressed:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:3997-4025 (approx)
let center = frame.center
let pressedButtons = NSEvent.pressedMouseButtons
let centerOnScreen = NSScreen.screens.contains(where: { $0.frame.contains(center) })
...
guard centerOnScreen else { ... return }
guard pressedButtons == 0 else { ... return }

let windowServerCenter = ScreenCoordinateSpace.toWindowServer(point: center)
warpMouseCursorPosition(windowServerCenter)   // ← warps even if cursor already inside `frame`
```

There is no "cursor already inside the target frame" short-circuit. Nehir's
existing mouse-down token suppression (`MouseEventHandler.swift:957-968` +
`NiriLayoutHandler.swift:254-264`) prevents *click-originated* focus confirms
from warping, but the warp primitive itself has no geometric guard, so other
focus paths that resolve to a cursor-containing window still recenter.

## Fix — inject a mouse-location reader and add a cursor-inside guard

Mirror the upstream shape (`b243d36f`): make the current mouse location an
injectable closure (so it is testable, like `warpMouseCursorPosition` already
is), and short-circuit the warp when the pointer is inside the frame.

### Step 1 — add an injectable `currentMouseLocation`

File: `Sources/Nehir/Core/Controller/WMController.swift`, next to the existing
`warpMouseCursorPosition` property (`:242`).

```swift
@ObservationIgnored
var warpMouseCursorPosition: (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) }
@ObservationIgnored
var currentMouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
```

Match the surrounding `@ObservationIgnored` property style exactly.

### Step 2 — guard the warp in `moveMouseToWindow`

Same function, after the `pressedButtons == 0` guard and before computing
`windowServerCenter` (~`:4023`):

```swift
let mouse = currentMouseLocation()
guard !frame.contains(mouse) else {
    if diagnostics.isRuntimeTraceCaptureActive {
        diagnostics.recordRuntimeMouseTrace(
            "moveMouseToFocused.skip reason=cursorInside source=\(reason) token=\(token) mouse=\(formatTracePoint(mouse)) frame=\(formatTraceRect(frame))"
        )
    }
    return
}

let windowServerCenter = ScreenCoordinateSpace.toWindowServer(point: center)
warpMouseCursorPosition(windowServerCenter)
```

Notes:
- Use `frame.contains(mouse)` against the **screen-space** `frame` and the
  screen-space `NSEvent.mouseLocation` — both are in AppKit/global screen
  coordinates here (the conversion to window-server space happens only for the
  warp destination). Do not convert `mouse` before the containment check.
- Place the guard **after** the existing `centerOnScreen` / `pressedButtons`
  guards so their trace/skip semantics are unchanged; this adds a third, more
  specific skip reason.
- Reuse the existing `formatTracePoint` / `formatTraceRect` helpers already used
  in this function.

### Step 3 — regression test

File: `Tests/NehirTests/WMControllerFocusTests.swift` — it already constructs a
controller and overrides `controller.warpMouseCursorPosition` to capture warp
points (`:232`, `:264`, `:321`), so it is the natural home.

Add two tests:

1. **Cursor inside target → no warp.** Set
   `controller.currentMouseLocation = { frame.center }` (or any point inside the
   target frame), capture warps, drive `moveMouseToWindow(token, preferredFrame:
   frame, reason: "test")`, and assert **no** warp point was recorded.
2. **Cursor outside target → warps (no regression).** Set
   `controller.currentMouseLocation = { CGPoint(x: -10_000, y: -10_000) }`
   (well outside), and assert exactly one warp to the frame center. This mirrors
   the existing default and proves the guard did not suppress legitimate warps.

Follow the existing fixture/override idiom in the file; do not add a new fixture
type if an existing one already yields a controller with a placeable window.

## Do-not-touch fences

- Do **not** modify the click-token suppression path
  (`MouseEventHandler.swift:957-968`, `NiriLayoutHandler.swift:254-264`) — it is
  orthogonal and correct; this guard is a complementary geometric backstop.
- Do **not** change the `centerOnScreen` or `pressedButtons` guards, or the
  warp coordinate conversion (`ScreenCoordinateSpace.toWindowServer`).
- Do **not** touch the other `moveMouseToWindow` overload
  (`WMController.swift:3979`, the `WindowHandle` forwarder) beyond it already
  delegating to the token overload — no change needed there.
- Do **not** touch any other file. This change is one source file plus test
  additions (and a changeset).

## Gate

- **Between steps (fast):** `mise run build`. Optionally `mise run format:check`
  + `mise run lint`.
- **Once at the end (full):** `mise run check`. New tests pass; existing
  `WMControllerFocusTests` / `MouseEventHandlerTests` stay green.

## Changeset (required — user-visible bug fix)

```bash
mise run changeset patch "Keep the pointer where it is when focusing a window it is already inside, instead of warping the cursor to that window's center"
```

## Commit message shape

```
Do not warp the cursor into a window it is already inside

moveMouseToWindow warped to the target window's center whenever the center was
on-screen and no button was pressed, even if the pointer was already inside the
window — yanking the cursor away from where the user was pointing. Add an
injectable currentMouseLocation and skip the warp when the pointer is already
within the target frame.

Ports BarutSRB/OmniWM@b243d36f; addresses BarutSRB/OmniWM#446.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

## Completion token

On success, after the full gate is green, print exactly:

`PLAN_DONE_cursor_inside_no_warp_guard`
