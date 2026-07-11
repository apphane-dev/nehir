# OmniWM PR BarutSRB/OmniWM#296 — "Fix trackpad gesture focus commit" — Discovery

Source PR: <https://github.com/BarutSRB/OmniWM/pull/296>
Scope of this doc: determine whether the focus-commit fix PR BarutSRB/OmniWM#296 proposes
(commit keyboard focus to the window in the column a committed trackpad
gesture snapped to) is relevant to nehir, whether it is distinct from the
trackpad-gesture-detection sibling track (#53 / BarutSRB/OmniWM#301), and whether the
proposed diff is safe to port.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM").
Re-verify before implementing; line numbers drift.

> **Filed under discovery/noop/** — this is a 🟢 **Fixed** result, not a
> sibling duplicate. nehir's `finalizeOrCancelCommittedGesture` already
> commits keyboard focus to the snapped column's active window on
> committed-gesture end (`MouseEventHandler.swift:1796`–`:1809`), with
> **richer** guards and tracing than the PR adds to the upstream rewrite. The
> PR is also **distinct** from the trackpad-gesture sibling track
> ([`20260616-nehir-53-trackpad-four-finger-swipe-gesture.md`](../discovery/20260616-nehir-53-trackpad-four-finger-swipe-gesture.md)
> / [`…-omniwm-301-…`](./20260616-omniwm-301-three-finger-swipe-stuck-under-app-gesture-competition.md)):
> those concern gesture *detection* / competition (the swipe aborts or
> "gets stuck" mid-gesture); BarutSRB/OmniWM#296 concerns *focus* at gesture *end* (a
> successful swipe completes — does the target window receive keyboard
> focus?). Different layer of the gesture lifecycle, different code block.
> Porting the OmniWM diff would be a **regression** (it would drop nehir's
> FFM / non-managed-focus guards, focus-border rendering, mouse-warp
> suppression, and the `touch_scroll_gesture_end` trace), so it owns no
> new repo action.

---

## TL;DR

- **nehir already focuses the snapped-column window at committed-gesture end;
  PR BarutSRB/OmniWM#296's change is the same behavior the upstream rewrite lacks — nehir forked
  OmniWM and independently evolved this function further than the PR.**
- **Verdict:** 🟢 **Fixed** — the focus commit exists in nehir and is more
  guarded than the proposed diff; porting it would regress. Filed under
  `noop/` (Fixed; no new action).

## PR state

**Closed, not merged** (`merged: false`, closed `2026-05-05T17:57:35Z`).
The author `@nick-s5` closed it themselves: *"Didn't mean to create this
upstream yet, needs more testing."* Maintainer `@BarutSRB` replied
*"no problem ❤️"*. So the diff was never landed upstream; it is a work-in-
progress attempt to add post-gesture focus commit to the upstream rewrite's
`MouseEventHandler`. Base `6a98497` → head `e7d09bc`; 2 files,
`Sources/OmniWM/Core/Controller/MouseEventHandler.swift` (+28) and
`Tests/OmniWMTests/MouseEventHandlerTests.swift` (+78).

## What the PR changes (in the upstream rewrite)

It edits the rewrite's `finalizeOrCancelCommittedGesture`. After the viewport
snaps to `endState.activeColumnIndex`, the added block derives the target
window from that column and force-focuses it:

```swift
// upstream rewrite — finalizeOrCancelCommittedGesture (PR BarutSRB/OmniWM#296, unmerged)
if columns.indices.contains(endState.activeColumnIndex),
   let activeWindow = columns[endState.activeColumnIndex].activeWindow {
    endState.selectedNodeId = activeWindow.id
    targetWindowNode = activeWindow
    targetWindowHandle = controller.workspaceManager.handle(for: activeWindow.token)
    engine.updateFocusTimestamp(for: activeWindow.id)
}
...
if let targetWindowNode {
    _ = runtime.commitWorkspaceSelection(nodeId: targetWindowNode.id, focusedToken: targetWindowNode.token, ...)
    _ = runtime.beginManagedFocusRequest(targetWindowNode.token, ...)
}
...
if let targetWindowHandle {
    controller.focusWindow(targetWindowHandle, source: .mouse)   // unconditional focus
}
```

New test `committedTrackpadGestureFinalizationCommitsSnappedColumnFocus`
asserts that finalizing a committed gesture updates `activeColumnIndex`,
`selectedNodeId`, and `pendingFocusedToken` to the next column's window.

## Provenance: is this nehir's code?

Yes. nehir's analog is the same function name, reached on the same paths:

- Normal committed-gesture end: `handleGestureEvent` on `phase == .ended` /
  `.cancelled` with `gesturePhase == .committed` calls
  `finalizeOrCancelCommittedGesture` (`MouseEventHandler.swift:1469`).
- Touch-release finalize: `finalizeCommittedGestureAfterTouchRelease` (`:1852`)
  → `finalizeOrCancelCommittedGesture` (`:1861`).
- Over-count abort of a committed gesture: `:1895` (per the sibling BarutSRB/OmniWM#301 doc).

So the function runs on every committed trackpad-swipe termination.

## The code in question (nehir, already shipped)

`finalizeOrCancelCommittedGesture` (`MouseEventHandler.swift:1747`) snaps the
viewport, then selects and focuses the snapped column's active window. After
`endState.endGesture(snapToColumn:)` (`:1782`), it pulls the active window
and commits focus — guarded and traced:

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift
if !lockedContext.bypassSnap {
    selectedWindow = syncViewportSelectionToActiveColumn(columns: columns, state: &endState)   // :1795
}                                                                                              //   sets selectedNodeId
...
var didRequestFocus = false
if let selectedWindow {
    rememberViewportFocusAnchor(selectedWindow, engine: engine, wsId: wsId)                    // :1802  anchor + focusTimestamp
    if !controller.focusFollowsMouseEnabled,                                                   // :1803
       !controller.workspaceManager.isNonManagedFocusActive,                                   // :1804
       let target = controller.managedKeyboardFocusTarget(for: selectedWindow.token)           // :1805
    {
        _ = controller.renderKeyboardFocusBorder(for: target, preferredFrame: ..., forceOrdering: false)
        controller.suppressMouseMoveToFocusedWindow(for: selectedWindow.token)
        controller.focusWindow(selectedWindow.token)                                           // :1807  ← the focus commit
        didRequestFocus = true
    }
}
```

The selection helper (`:1953`) is the analog of the PR's
`endState.selectedNodeId = activeWindow.id`, with extra active-tile indexing:

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift:1953
private func syncViewportSelectionToActiveColumn(columns: [NiriContainer], state: inout ViewportState) -> NiriWindow? {
    guard columns.indices.contains(state.activeColumnIndex) else { return nil }
    let activeColumn = columns[state.activeColumnIndex]
    let windows = activeColumn.windowNodes
    guard !windows.isEmpty else { return nil }
    let activeTileIndex = activeColumn.activeTileIdx.clamped(to: 0 ... (windows.count - 1))
    let selectedWindow = windows[activeTileIndex]
    state.selectedNodeId = selectedWindow.id
    return selectedWindow
}
```

And nehir traces the disposition, which the PR does not:

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift:1811–:1828
controller.recordRuntimeViewportTrace(
    workspaceId: wsId,
    reason: "touch_scroll_gesture_end",
    details: [ ..., "focusSelection=\(focusSelectionDisposition)", ... ]
)   // disposition ∈ none | suppressed | suppressedNonManagedFocus | requested | skippedNoManagedTarget
```

## Why it is Fixed and the PR is not safe to port

Side-by-side, the two implementations aim at the same behavior — focus the
window in the column the committed gesture snapped to — but nehir's is the
strict superset:

| Concern                          | PR BarutSRB/OmniWM#296 (upstream rewrite, unmerged)         | nehir (already shipped)                              |
|----------------------------------|------------------------------------------|------------------------------------------------------|
| Select snapped column's window   | `endState.selectedNodeId = activeWindow.id` | `syncViewportSelectionToActiveColumn` (`:1795`, sets `selectedNodeId` + active-tile idx) |
| Remember focus / timestamp       | `engine.updateFocusTimestamp(for:)`      | `rememberViewportFocusAnchor` (`:1802`: anchor + timestamp) |
| Focus the target window          | `controller.focusWindow(...)`, **unconditional** | `controller.focusWindow(selectedWindow.token)` (`:1807`), **guarded** |
| Respect focus-follows-mouse      | ✗ (would steal focus under FFM)          | ✓ `!focusFollowsMouseEnabled` (`:1803`)             |
| Respect non-managed focus (overlay) | ✗                                    | ✓ `!isNonManagedFocusActive` (`:1804`)             |
| Require a managed focus target   | ✗                                        | ✓ `managedKeyboardFocusTarget(for:) != nil` (`:1805`) |
| Render keyboard-focus border     | ✗                                        | ✓ `renderKeyboardFocusBorder(...)`                  |
| Suppress mouse-warp to target    | ✗                                        | ✓ `suppressMouseMoveToFocusedWindow(...)`           |
| Trace the focus disposition      | ✗                                        | ✓ `touch_scroll_gesture_end focusSelection=requested|…` |

Porting the PR's diff (or its spirit) on top of nehir would therefore **lose**
the FFM guard, the non-managed-focus guard, the managed-target requirement,
the focus-border rendering, the mouse-warp suppression, and the disposition
trace — a clear regression. The upstream rewrite simply does not yet have these
layers; nehir, having iterated independently, already does.
The matching nehir test surface already exists too (the PR's
`committedTrackpadGestureFinalizationCommitsSnappedColumnFocus` is the same
shape as nehir's existing `trackpadGesture*` tests in
`Tests/NehirTests/MouseEventHandlerTests.swift`).

## Distinctness from the trackpad-gesture sibling track (#53 / BarutSRB/OmniWM#301)

The triage note asked specifically whether BarutSRB/OmniWM#296 duplicates BarutSRB/OmniWM#301. It does not.
They operate at different layers of the committed-gesture lifecycle:

- **#53 / BarutSRB/OmniWM#301 (sibling track): gesture detection / competition.** The strict
  exact-count matcher `averageGestureTouchPosition` (`MouseEventHandler.swift:2146`)
  returns `nil` on transient over/under-count, an in-flight `.armed`/
  `.committed` gesture aborts (`:1458`/`:1502`), and the swipe "gets stuck" or
  never commits — especially when a competing app/OS claims the gesture. The
  fix is matcher hysteresis + abort-path tracing. This is about whether the
  gesture *qualifies and stays alive*.
- **BarutSRB/OmniWM#296 (this PR): focus commit at gesture end.** A committed gesture
  *successfully* terminates and snaps to a column; the question is whether the
  active window in that column *receives keyboard focus*. The code lives in
  `finalizeOrCancelCommittedGesture` (`:1747`) *after* `endGesture(snapToColumn:)`,
  not in the matcher or abort block. nehir already does it.

BarutSRB/OmniWM#296 presupposes a gesture that committed and ended cleanly; #53/BarutSRB/OmniWM#301 are about
failing to reach that point. They share `finalizeOrCancelCommittedGesture` as a
common tail, but address disjoint behavior. Hence BarutSRB/OmniWM#296 is not a sibling
duplicate; it is simply already-fixed in nehir.

## Recommendation

Do **not** port PR BarutSRB/OmniWM#296. nehir's `finalizeOrCancelCommittedGesture` already
commits focus to the snapped-column window at committed-gesture end, and the
nehir implementation is the guarded superset (FFM / non-managed-focus /
managed-target gates, focus border, mouse-warp suppression, disposition trace)
of what the unmerged OmniWM diff adds. No new repo action is owned here. If a
future report says "the window in the column I swiped to didn't get focus,"
the investigation should start at `MouseEventHandler.swift:1795`–`:1828` — the
`focusSelection` disposition trace there will already tell you whether focus
was `requested`, `suppressed` (FFM/non-managed), `skippedNoManagedTarget`, or
`none`.

## Suggested tests   (already covered; listed for completeness)

nehir's focus-commit is already reachable and the existing `trackpadGesture*`
tests in `Tests/NehirTests/MouseEventHandlerTests.swift` cover the committed-
finalize path. The one assertion worth confirming is locked-in: that
finalizing a committed trackpad gesture onto a column with a window sets
`selectedNodeId` to that window and issues a focus request — the exact
behavior the PR's
`committedTrackpadGestureFinalizationCommitsSnappedColumnFocus` encodes. If a
nehir test of that specific end-state does not yet exist, add it next to the
existing gesture-finalization tests; the production code path (`:1795`–`:1807`)
already supports it.
