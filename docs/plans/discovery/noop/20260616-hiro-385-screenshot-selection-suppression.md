# Hiro PR #385 — "Suppress input during screenshot selection" — Discovery

Source PR: https://github.com/BarutSRB/Hiro/pull/385
Filed against: `BarutSRB/Hiro` (upstream of nehir — see `NOTICE.md`;
nehir is a fork of `BarutSRB/OmniWM`, which was renamed to Hiro).
Scope of this doc: determine whether the proposed screen-capture suppression
should be adapted for nehir, and whether the same root cause exists in nehir.

Upstream state: **closed without merge** (`merged == false`, `merged_at == nil`).
The task/catalog state said "open"; the GitHub API fetched during this discovery
contradicts that and shows the PR closed on 2026-06-15. The PR says it fixes
Hiro issue #254 ("Trying to take a screenshot using Cmd + Shift + 4 causes
windows to shift.").

All file/line references were verified against `worktree-calm-meadow-6229` at
`7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace").
Re-verify before implementing; line numbers drift.

> **Filed under discovery/noop/** — this PR owns **no new nehir action**. nehir
> does not have the PR's exact `isFrontmostAppScreenCapture()` helper, but the
> PR's normal Cmd+Shift+4 left-drag symptom is not reachable through nehir's
> mouse interaction gates, and screencapture overlay windows are already stopped
> by admission/frame-event gates. The related system-overlay finding is also
> recorded in sibling doc
> `docs/plans/discovery/noop/20260616-hiro-358-system-overlay-pill-window-shift.md`.

---

## TL;DR

- **Do not port PR #385 as-is.** It adds a frontmost-app screencapture guard to
  the existing lock-screen suppression pattern, but nehir's normal screenshot
  selection drag cannot start the move/resize paths, and untracked screencapture
  surfaces cannot relayout tracked tiled windows.
- **Verdict:** ⚪ **Won't port / Not applicable** — the PR was closed unmerged
  upstream, depends on an unproven "screencapture becomes frontmost" assumption,
  and the nehir code paths it would guard are already narrower than the upstream
  symptom requires.

## Upstream PR state and diff

PR #385 proposes three changes:

1. Add `WMController.isFrontmostAppScreenCapture()` matching
   `com.apple.screencaptureui` and `com.apple.Screenshot`.
2. Extend `MouseEventHandler.isInputSuppressed` from
   `isLockScreenActive || isFrontmostAppLockScreen()` to also include that helper.
3. Extend four `LayoutRefreshController` lock-screen guards (relayout,
   visibility refresh, window removal, full refresh) to also suppress while the
   screencapture app is frontmost.

The PR body says Cmd+Shift+4 screenshot selection keeps the session event tap
active, and dragging the selection rectangle near tiled-window edges shifts or
resizes windows. Its author also noted the fix only works if `screencaptureui`
actually becomes frontmost; otherwise the root cause may be CGS frame events or
focus churn from transient system UI.

## Provenance: is this nehir's code?

Yes. The PR's touched upstream files map directly to nehir files:

| Upstream PR file | nehir equivalent | Finding |
|---|---|---|
| `Sources/OmniWM/Core/Controller/MouseEventHandler.swift` | `Sources/Nehir/Core/Controller/MouseEventHandler.swift` | session CGEvent tap and `isInputSuppressed` exist (`MouseEventHandler.swift:230`, `MouseEventHandler.swift:563`) |
| `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift` | `Sources/Nehir/Core/Controller/LayoutRefreshController.swift` | lock-screen guards exist on relayout/visibility/removal/full refresh (`LayoutRefreshController.swift:833`, `:862`, `:906`, `:989`) |
| `Sources/OmniWM/Core/Controller/WMController.swift` | `Sources/Nehir/Core/Controller/WMController.swift` | lock-screen frontmost helper exists (`WMController.swift:3621`) |

The exact PR helper and bundle IDs were **not found** in nehir: no
`isFrontmostAppScreenCapture`, `com.apple.screencaptureui`, or
`com.apple.Screenshot` match exists under `Sources/Nehir/` (only unrelated
ScreenCaptureKit use for nehir-owned screenshots/drag ghosts was found).

## The code in question

### 1. nehir has the same input-suppression hook, but only for lock screen

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift:230
let eventMask: CGEventMask =
    (1 << CGEventType.mouseMoved.rawValue) |
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue) |
    (1 << CGEventType.rightMouseDown.rawValue) |
    (1 << CGEventType.rightMouseDragged.rawValue) |
    (1 << CGEventType.rightMouseUp.rawValue) |
    (1 << CGEventType.scrollWheel.rawValue)

// Sources/Nehir/Core/Controller/MouseEventHandler.swift:563
private var isInputSuppressed: Bool {
    guard let controller else { return true }
    return controller.isLockScreenActive || controller.isFrontmostAppLockScreen()
}
```

The PR would add screencapture to this predicate. nehir currently does not.

### 2. Normal screenshot selection does not satisfy nehir's move/resize gates

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift:366
func dispatchMouseDragged(at location: CGPoint, button: MouseButton = .left, windowUnderPointer: Int? = nil) {
    guard !isInputSuppressed else { return }
    …
    handleMouseDraggedFromTap(at: location, button: button, windowUnderPointer: windowUnderPointer)
}

// Sources/Nehir/Core/Controller/MouseEventHandler.swift:878
if button == .left, modifiers.contains(.maskAlternate) {
    …
    if engine.interactiveMoveBegin(…) {
        state.isMoving = true
        …
    }
}

// Sources/Nehir/Core/Controller/MouseEventHandler.swift:927
guard button == .right,
      Self.modifierFlagsMatch(modifiers, required: controller.settings.mouseResizeModifierKey.cgEventFlag)
else { return false }
```

A Cmd+Shift+4 selection drag is a left-button drag. In nehir, left-button moving
requires Option (`.maskAlternate`) at `MouseEventHandler.swift:878`; resizing is
right-button-only and requires the configured resize modifier at
`MouseEventHandler.swift:927`. The default resize modifier is Option
(`SettingsExport.swift:146`), and modifier matching is exact over relevant flags
(`MouseEventHandler.swift:2088`). A Command+Shift screenshot gesture therefore
cannot start the normal move/resize paths by inspection.

### 3. Once no interaction is active, dragged events are inert

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift:999
if state.isMoving {
    …
    let hoverTarget = engine.interactiveMoveUpdate(currentLocation: location, in: wsId)
    …
    return
}

guard state.isResizing else { return }  // Sources/Nehir/Core/Controller/MouseEventHandler.swift:1039
…
if engine.interactiveResizeUpdate(…) {
    controller.layoutRefreshController.requestRefresh(reason: .interactiveGesture)
}
```

If the initial screenshot-selection mouse-down did not enter `state.isMoving` or
`state.isResizing`, later left-drag callbacks return at the `state.isResizing`
guard and never request an interactive relayout (`MouseEventHandler.swift:1039`,
`:1064`).

### 4. The layout-refresh guards PR #385 would extend are lock-screen-only

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:831
if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
    return false
}

// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:860
if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
    return false
}

// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:905
if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
    return false
}

// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:986
if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
    return false
}
```

These are the four upstream guard sites the PR modified. nehir has them, but
without screencapture.

### 5. Screencapture overlay windows still cannot relayout tracked windows

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:677
private func handleFrameChanged(windowId: UInt32) {
    …
    guard let token = resolvedToken else { return }
    guard let entry = controller.workspaceManager.entry(for: token) else { return }
    …
}

// Sources/Nehir/Core/Controller/AXEventHandler.swift:2561
private func prepareCreateCandidate(…) -> PreparedCreate? {
    …
    guard let axRef = fallbackAXRef?.windowId == Int(windowId)
        ? fallbackAXRef
        : resolveAXWindowRef(windowId: windowId, pid: token.pid)
    else { return nil }
    …
}

// Sources/Nehir/Core/SkyLight/SkyLight.swift:486
guard level == 0 || level == 3 || level == 8 else { continue }
```

A CGS frame event for an untracked screencapture overlay can resolve to a window
server token, but `handleFrameChanged` returns unless that token is already a
tracked workspace entry (`AXEventHandler.swift:690`). New-window admission also
requires an AX window reference (`AXEventHandler.swift:2581`), which system
screencapture chrome is not expected to provide. The normal visible-window scan
is additionally limited to levels 0, 3, and 8 (`SkyLight.swift:486`), excluding
high-level system capture chrome from ordinary enumeration.

## Why this PR does not apply cleanly

The PR correctly identifies that nehir has the same *kind* of input and layout
suppression hooks: `MouseEventHandler.isInputSuppressed` and the four
`LayoutRefreshController` lock-screen checks exist. It also correctly identifies
that nehir does **not** currently suppress merely because the frontmost app is
`screencaptureui` / `Screenshot`.

But the proposed fix is not justified for nehir by inspection:

- The upstream symptom is a **left-button screenshot selection drag**. nehir's
  left-button interactive move requires Option (`MouseEventHandler.swift:878`),
  while interactive resize is right-button-only (`MouseEventHandler.swift:927`).
- If those begin gates are not crossed, later drag events are no-ops for layout
  purposes (`MouseEventHandler.swift:999`, `:1039`).
- The alternative root cause named by the PR author — CGS frame events from the
  screenshot overlay — is stopped by tracked-entry membership before relayout
  (`AXEventHandler.swift:690`).
- The admission path for a newly observed screencapture overlay requires an AX
  window ref (`AXEventHandler.swift:2581`), and ordinary SkyLight enumeration
  ignores non-0/3/8 window levels (`SkyLight.swift:486`).
- The frontmost-app assumption is not proven upstream, and the PR was closed
  without merge.

The lock-screen tests confirm the existing suppression mechanism works when its
predicate is true (`MouseEventHandlerTests.swift:671`, `:709`, `:764`, `:801`),
so if future runtime evidence proves a real nehir screenshot-selection bug, an
adapted predicate could be tested. That is not established by PR #385 alone.

## Recommendation

Do **not** port PR #385 as-is. Keep this as a no-op discovery unless a nehir
runtime trace or manual reproduction shows Cmd+Shift+4 can actually start a
nehir interaction or relayout. If that happens, implement a narrower fix with a
first-class `isFrontmostAppScreenCapture` abstraction and tests proving both:

1. Cmd+Shift+4 input is suppressed only while the capture UI is active.
2. Normal mouse move/resize/scroll behavior resumes immediately afterward.

## Suggested tests

None required for this no-op verdict. Existing lock-screen input tests already
pin the suppression behavior when `isInputSuppressed` is true
(`MouseEventHandlerTests.swift:671`, `MouseEventHandlerTests.swift:764`).
