# OmniWM issue #223 — "Border doesn't follow a floating window" — Discovery

Source issue: https://github.com/BarutSRB/OmniWM/issues/223
Upstream state: **closed as not planned** (per task triage/upstream state).
Scope of this doc: determine whether the floating-window focus-border tracking
bug applies to nehir, and whether the closed upstream item owns any repo action.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Line
numbers drift — re-verify before implementing.

> **Filed under `discovery/noop/`** — nehir already updates the focused border
> from observed CGS/AX frame changes before the floating-window path returns,
> and existing tests cover the floating move case. This issue owns no new repo
> action.

---

## TL;DR

- **The reported stale-border path is already handled in nehir.** A subscribed
  CGS `.frameChanged` event refreshes the current border target from the
  observed frame, then floating-window geometry is updated without relayout.
- **Verdict:** 🟢 **Fixed.** The upstream issue has reproduction steps but no
  suggested code fix; nehir has an earlier, explicit frame-change border path.

## Upstream issue context

Issue #223 reports that after opening a normal app window, putting it in
floating mode, focusing it, and dragging it, the OmniWM/OmniWM border can remain at
its old position instead of following the floating window. The issue references
#208 (overlay/pop-up borders) but says regular floating windows still reproduce
it. No patch or concrete code change was proposed in the fetched issue body.

## Provenance: is this nehir's code?

Yes. The relevant nehir symbols exist:

- CGS window events include `.frameChanged`, and `AXEventHandler` dispatches that
  event to `handleFrameChanged` (`Sources/Nehir/Core/SkyLight/CGSEventObserver.swift:4`,
  `Sources/Nehir/Core/Controller/AXEventHandler.swift:388`).
- Managed windows are subscribed for CGS notifications through
  `subscribeToManagedWindows` / `subscribeToWindows` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:842`,
  `Sources/Nehir/Core/Controller/AXEventHandler.swift:4017`).
- Focus-border rendering is owned by `FocusBorderController` and `BorderManager`
  (`Sources/Nehir/Core/Border/FocusBorderController.swift:92`,
  `Sources/Nehir/Core/Border/BorderManager.swift:48`).

## The code in question

### CGS frame changes reach the AX event handler

```swift
// Sources/Nehir/Core/SkyLight/CGSEventObserver.swift:4
// enum CGSWindowEvent: Equatable {
//     case created(windowId: UInt32, spaceId: UInt64)
//     case destroyed(windowId: UInt32, spaceId: UInt64)
//     case frameChanged(windowId: UInt32)

// Sources/Nehir/Core/Controller/AXEventHandler.swift:388
func cgsEventObserver(_: CGSEventObserver, didReceive event: CGSWindowEvent) {
    guard let controller else { return }

    switch event {
    ...
    case let .frameChanged(windowId):
        handleFrameChanged(windowId: windowId)
```

### Floating frame changes update the focused border before returning

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:677
private func handleFrameChanged(windowId: UInt32) {
    guard let controller else { return }
    guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
    let windowServerToken = resolveWindowToken(windowId)
    let resolvedToken = resolveTrackedToken(
        windowId,
        resolvedWindowToken: windowServerToken
    )
    let focusedObservedFrame = updateFocusedBorderForFrameChange(
        windowId: windowId,
        windowServerToken: windowServerToken,
        resolvedToken: resolvedToken
    )
    guard let token = resolvedToken else { return }
    guard let entry = controller.workspaceManager.entry(for: token) else { return }
    ...
    if entry.mode == .floating {
        if let frame = focusedObservedFrame ?? observedFrame(for: entry) {
            controller.workspaceManager.updateFloatingGeometry(frame: frame, for: token)
        }
        return
    }
```

### The border refresh uses the observed frame for the current target

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:755
private func updateFocusedBorderForFrameChange(
    windowId: UInt32,
    windowServerToken: WindowToken?,
    resolvedToken: WindowToken?
) -> CGRect? {
    guard let controller else { return nil }
    guard let target = controller.currentBorderTarget() else { return nil }
    ...
    if let entry = controller.workspaceManager.entry(for: target.token) {
        ...
        if let frame = observedFrame(for: entry) {
            updateManagedReplacementFrame(frame, for: entry)
            _ = controller.focusBorderController.updateFrameHint(
                for: target.token,
                frame: frame,
                source: .observed
            )
            return frame
        }
```

```swift
// Sources/Nehir/Core/Border/FocusBorderController.swift:92
func updateFrameHint(
    for token: WindowToken,
    frame: CGRect,
    source: BorderFrameSource = .layout,
    forceOrdering: Bool = false
) -> Bool {
    guard visualFocusTarget?.token == token else { return false }
    ...
    return refresh(
        preferredFrame: frame,
        preferredFrameSource: source,
        forceOrdering: forceOrdering
    )
}

// Sources/Nehir/Core/Border/FocusBorderController.swift:247
guard let frame = resolveFrame(
    for: target,
    preferredFrame: preferredFrame,
    preferredFrameSource: preferredFrameSource
) else {
    borderManager.hideBorder()
    return false
}

return borderManager.updateFocusedWindow(
    frame: frame,
    windowId: target.windowId,
    forceOrdering: forceOrdering
)
```

### BorderManager applies the new frame to the border window

```swift
// Sources/Nehir/Core/Border/BorderManager.swift:48
func updateFocusedWindow(
    frame: CGRect,
    windowId: Int?,
    forceOrdering: Bool = false
) -> Bool {
    guard config.enabled else { return false }
    guard frame.width > 0, frame.height > 0 else {
        hideBorder()
        return false
    }
    ...
    guard borderWindow?.update(
        frame: frame,
        targetWid: targetWid,
        cornerRadius: cornerRadius,
        forceOrdering: forceOrdering
    ) == true else {
        clearCornerRadiusCache()
        return false
    }
    lastAppliedFrame = frame
```

## Why this does not apply to nehir

The upstream symptom requires the focused border to remain on the old frame after
a focused floating window moves. In nehir, the frame-change path is intentionally
ordered the other way around:

1. `.frameChanged` is a first-class CGS event (`Sources/Nehir/Core/SkyLight/CGSEventObserver.swift:4`-
   `Sources/Nehir/Core/SkyLight/CGSEventObserver.swift:7`) and is dispatched to
   `handleFrameChanged` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:388`-
   `Sources/Nehir/Core/Controller/AXEventHandler.swift:402`).
2. `handleFrameChanged` calls `updateFocusedBorderForFrameChange` before it checks
   whether the moved entry is floating (`Sources/Nehir/Core/Controller/AXEventHandler.swift:685`-
   `Sources/Nehir/Core/Controller/AXEventHandler.swift:699`). Thus the border is
   refreshed before the floating path returns without a relayout
   (`Sources/Nehir/Core/Controller/AXEventHandler.swift:697`-
   `Sources/Nehir/Core/Controller/AXEventHandler.swift:701`).
3. `updateFocusedBorderForFrameChange` only updates the border for the current
   border target, using the observed frame from AX/fast frame providers
   (`Sources/Nehir/Core/Controller/AXEventHandler.swift:760`-
   `Sources/Nehir/Core/Controller/AXEventHandler.swift:799`). That avoids moving
   the border for unrelated frame changes.
4. `FocusBorderController.updateFrameHint` immediately refreshes with the
   observed frame (`Sources/Nehir/Core/Border/FocusBorderController.swift:92`-
   `Sources/Nehir/Core/Border/FocusBorderController.swift:105`), and the render
   path passes that frame to `BorderManager.updateFocusedWindow`
   (`Sources/Nehir/Core/Border/FocusBorderController.swift:247`-
   `Sources/Nehir/Core/Border/FocusBorderController.swift:260`).
5. `BorderManager.updateFocusedWindow` applies the frame to the border window and
   records it as `lastAppliedFrame` (`Sources/Nehir/Core/Border/BorderManager.swift:88`-
   `Sources/Nehir/Core/Border/BorderManager.swift:99`).

Existing tests cover the exact invariant this issue needs. A focused floating
window receiving a frame-change event with only a tracked-token fallback updates
both the border frame and floating state to the observed frame
(`Tests/NehirTests/AXEventHandlerTests.swift:4294`-
`Tests/NehirTests/AXEventHandlerTests.swift:4344`). A separate floating-frame
change test verifies floating geometry updates without scheduling relayout
(`Tests/NehirTests/AXEventHandlerTests.swift:4606`-
`Tests/NehirTests/AXEventHandlerTests.swift:4652`).

## Recommendation

Do not port anything for #223. Keep the existing nehir behavior: CGS frame
changes refresh the focused border immediately, and floating-window geometry is
then updated without relayout. If a future runtime report shows a specific app
not emitting/subscribing frame-change notifications, treat that as a new
app-specific discovery, not as this closed upstream no-code issue.
