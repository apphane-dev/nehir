# OmniWM issue #150 — "Screenshot of bordered window is blank" — Discovery

Source issue: https://github.com/BarutSRB/OmniWM/issues/150 (closed, **not planned**; cleanup close, not a code fix).
Scope of this doc: determine whether the issue applies to nehir,
and whether the suggested fix is safe to port.

All file/line references were verified against the nehir worktree at `904df02`
("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify before
implementing; line numbers drift.

---

## TL;DR

- **The native Cmd+Shift+4-space screenshot symptom can still be produced by nehir's border design: the focused border is a separate transparent SkyLight window larger than the target, and nehir's existing capture exclusion only guards nehir's own ScreenCaptureKit thumbnail path.**
- **Verdict:** 🟡 Partial — borders are excluded from nehir overview captures, but there is no code path that hides or marks the border window as non-selectable for macOS's system screenshot window picker.

## Provenance: is this nehir's code?

Yes. The relevant nehir symbols all exist:

- `FocusBorderController` updates the visual border when focus changes and hands
  the focused window ID to `BorderManager` (`Sources/Nehir/Core/Border/FocusBorderController.swift:43-59`, `:256-259`).
- `BorderManager` creates/registers a `BorderWindow` when borders are enabled
  (`Sources/Nehir/Core/Border/BorderManager.swift:48-62`, `:163-176`).
- `BorderWindow` is a separate SkyLight window, expanded around the target,
  cleared transparent in the center, then filled only in the ring outside the
  target (`Sources/Nehir/Core/Border/BorderWindow.swift:88-100`, `:166-196`).

The issue is conditional: nehir ships borders disabled by default
(`Sources/Nehir/Core/Config/SettingsExport.swift:117-118`), matching upstream's
"window must be focused and bordered" requirement.

## The code in question

### Focus drives border rendering

```swift
// Sources/Nehir/Core/Border/FocusBorderController.swift:43-59
@discardableResult
func focusChanged(
    to target: KeyboardFocusTarget?,
    preferredFrame: CGRect? = nil,
    preferredFrameSource: BorderFrameSource = .layout,
    forceOrdering: Bool = true
) -> Bool {
    visualFocusTarget = target
    requiresFocusValidationBeforeRender = false
    if let target {
        suppressedManagedTargets.remove(target.token)
    }
    return refresh(
        preferredFrame: preferredFrame,
        preferredFrameSource: preferredFrameSource,
        forceOrdering: forceOrdering
    )
}
```

```swift
// Sources/Nehir/Core/Border/FocusBorderController.swift:256-259
return borderManager.updateFocusedWindow(
    frame: frame,
    windowId: target.windowId,
    forceOrdering: forceOrdering
)
```

### The border is its own transparent window around the target

```swift
// Sources/Nehir/Core/Border/BorderWindow.swift:88-100
let borderOffset = -borderWidth - padding
var frame = targetFrame.insetBy(dx: borderOffset, dy: borderOffset)
    .roundedToPhysicalPixels(scale: scale)

origin = ScreenCoordinateSpace.toWindowServer(rect: frame).origin
frame.origin = .zero

let drawingBounds = CGRect(
    x: -borderOffset,
    y: -borderOffset,
    width: targetFrame.width,
    height: targetFrame.height
)
```

```swift
// Sources/Nehir/Core/Border/BorderWindow.swift:166-196
context.saveGState()
context.clear(frame)

let innerRect = drawingBounds.insetBy(dx: borderWidth, dy: borderWidth)
let innerPath = CGPath(
    roundedRect: innerRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

let clipPath = CGMutablePath()
clipPath.addRect(frame)
clipPath.addPath(innerPath)
context.addPath(clipPath)
context.clip(using: .evenOdd)

context.setFillColor(config.color.cgColor)

let outerPath = CGPath(
    roundedRect: drawingBounds,
    cornerWidth: outerRadius,
    cornerHeight: outerRadius,
    transform: nil
)
context.addPath(outerPath)
context.fillPath()

context.restoreGState()
context.flush()
operations.flushWindow(wid)
```

The window is ordered relative to the focused app, but it remains a distinct
window-server window:

```swift
// Sources/Nehir/Core/Border/BorderWindow.swift:140-148
private func createWindow(frame: CGRect, scale: CGFloat) {
    wid = operations.createBorderWindow(frame)
    guard wid != 0 else { return }

    operations.configureWindow(wid, Float(scale), false)
    lastConfiguredScale = scale

    let tags: UInt64 = (1 << 1) | (1 << 9)
    operations.setWindowTags(wid, tags)
```

```swift
// Sources/Nehir/Core/Border/BorderWindow.swift:199-202
private func move(relativeTo targetWid: UInt32, needsOrdering: Bool) {
    if needsOrdering {
        operations.transactionMoveAndOrder(wid, origin, orderingLevel, targetWid, .below)
        return
```

### Existing capture exclusion is internal-only

```swift
// Sources/Nehir/Core/Border/BorderManager.swift:163-176
surfaceCoordinator.registerWindowNumber(
    id: surfaceID,
    windowNumber: windowNumber,
    frameProvider: { [weak self] in
        self?.lastAppliedFrame
    },
    visibilityProvider: { [weak self] in
        self?.lastAppliedFrame != nil && self?.config.enabled == true
    },
    policy: SurfacePolicy(
        kind: .border,
        hitTestPolicy: .passthrough,
        capturePolicy: .excluded,
        suppressesManagedFocusRecovery: false
    )
)
```

```swift
// Sources/Nehir/Core/Surface/SurfaceScene.swift:169-172
func isCaptureEligible(windowNumber: Int) -> Bool {
    guard windowNumber > 0 else { return false }
    guard let ids = surfaceIDsByWindowNumber[windowNumber], !ids.isEmpty else { return true }
    return !ids.compactMap({ nodesByID[$0] }).contains { $0.policy.capturePolicy == .excluded }
}
```

```swift
// Sources/Nehir/Core/Overview/OverviewController.swift:450-454
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
let eligibleWindows = content.windows.compactMap { scWindow -> (CGWindowID, SCWindow)? in
    let windowNumber = Int(scWindow.windowID)
    guard ownedWindowRegistry.isCaptureEligible(windowNumber: windowNumber) else { return nil }
    return (scWindow.windowID, scWindow)
}
```

## Why this partially applies

The upstream report says Cmd+Shift+4, then Space, then selecting a focused
bordered app produces an image containing only the border/padding with a
transparent center. nehir's border window has exactly that standalone content:
`BorderWindow.draw` first clears the whole border window and then fills only the
ring outside the target content (`Sources/Nehir/Core/Border/BorderWindow.swift:166-196`).
If the system screenshot window picker selects the border window instead of the
app window, the captured image will be blank except for the border.

nehir does have one mitigation: border surfaces are registered as
`capturePolicy: .excluded` and `hitTestPolicy: .passthrough`
(`Sources/Nehir/Core/Border/BorderManager.swift:172-176`). That prevents nehir's
own capture enumerator from using the border as an overview thumbnail source
because `OverviewController` filters `SCShareableContent` through
`ownedWindowRegistry.isCaptureEligible` before calling ScreenCaptureKit
(`Sources/Nehir/Core/Overview/OverviewController.swift:450-454`). The
passthrough policy also only affects nehir's own interactive-surface hit testing
(`Sources/Nehir/Core/Surface/SurfaceScene.swift:138-150`).

That guard does not prove the native macOS screenshot UI is safe. The source tree
has no `screencapture`, `Screenshot`, or Cmd+Shift screenshot-mode hook found by
repo-wide search, and `CapturePolicy` is only consumed by nehir's
`SurfaceScene.isCaptureEligible` path (`Sources/Nehir/Core/Surface/SurfaceScene.swift:169-172`).
The SkyLight tags set on creation (`Sources/Nehir/Core/Border/BorderWindow.swift:147-148`)
are opaque bit constants with no local documentation or assertion that they make
the window non-capturable/non-selectable for the system window picker.

So the catalog's low-severity/validate flag is directionally right: this only
matters for users who enable borders and use the native whole-window screenshot
mode. But it is not obsolete by inspection; the exact transparent-border-window
premise still exists in nehir.

## Recommendation

Own a small nehir action: either make the border SkyLight window definitively
non-selectable/non-capturable by the native screenshot window picker, or hide the
border while macOS screenshot window-selection mode is active. Do not treat the
existing `capturePolicy: .excluded` registration as sufficient; it only protects
nehir-owned ScreenCaptureKit capture flows.

## Suggested tests

- Keep/extend the existing registry coverage that a border surface is passthrough
  and ineligible for nehir captures (`Tests/NehirTests/OwnedWindowRegistryTests.swift:116-138`).
- Add a manual release-check case for borders enabled: focus Chrome/Ghostty,
  invoke Cmd+Shift+4 then Space, capture the focused window, and verify the image
  includes app content rather than only the border and transparent center.
