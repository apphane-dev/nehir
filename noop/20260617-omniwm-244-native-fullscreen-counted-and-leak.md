# BarutSRB/OmniWM#244 — "Native full-screened window still counted as a window in space" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/244>
Scope of this doc: determine whether the two reported symptoms reproduce in
nehir — (a) a native-fullscreen window still being "counted" / tiled as a normal
window in its space, and (b) content from other workspaces leaking during the
fullscreen transition — and whether any fix is needed.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

> **Filed under `discovery/noop/`** — nehir already prevents both symptoms. A
> window entering native fullscreen is **suspended** from the managed model and
> **excluded from the tiling diff** (it is not counted as a window in its space),
> and the fullscreen enter/exit transition is gated by a
> `hasPendingNativeFullscreenTransition` flag that suppresses the relayout / FFM
> / border churn that would otherwise expose other-workspace content. The
> upstream issue was closed `not_planned` (a pre-v0.4.8 cleanup) with no fix to
> port. No new repo action is owned here.

---

## TL;DR

- **nehir does not count a native-fullscreen window as a tiled space member:**
  `suspendManagedWindowForNativeFullscreen` marks it suspended, and the Niri
  layout-diff loop `continue`s past suspended windows (optionally drawing a
  native-fullscreen placeholder instead of a tile).
- **nehir suppresses the transition-time content leak** via the
  `hasPendingNativeFullscreenTransition` guard on relayout, FFM, and border
  refresh, so the enter/exit animation does not churn hidden workspaces into
  view.
- **Verdict:** 🟢 **Fixed.** Both reported symptoms are addressed at the
  layout-suspension and transition-guard layers.

## Issue context

- **State:** closed `not_planned` — owner closed it as part of a v0.4.8+ cleanup
  ("the last conversation here predates the v0.4.8 release on 2026-04-21 … if
  this still reproduces on v0.4.8 or newer … it can be reopened"). No merged
  fix, no diff to port.
- **Symptom (a) (title):** "Native full screened window still counted as a window
  in space."
- **Symptom (b) (verbatim aside):** "(unrelated side effect, it also leaks
  content from other workspace - in this example, from workspace 6 during
  fullscreen transition)."

## Provenance: is this nehir's code?

Yes. nehir has a full native-fullscreen subsystem:

- `WorkspaceManager.markNativeFullscreenSuspended(_:)` / `NativeFullscreenRecord`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1339`) — records the
  window as `.suspended` under its original token, keyed by
  `nativeFullscreenRecordsByOriginalToken`.
- `WorkspaceManager.isNativeFullscreenSuspended(_:)` (`WorkspaceManager.swift:2973`).
- `WorkspaceManager.hasPendingNativeFullscreenTransition` (`WorkspaceManager.swift:1102`)
  — true while any record is `.enterRequested` or `.temporarilyUnavailable`.
- `AXEventHandler.suspendManagedWindowForNativeFullscreen(_:)`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:2127`) and
  `restoreManagedWindowFromNativeFullscreen(_:)` (`AXEventHandler.swift:2148`).
- The Niri layout-diff computation in
  `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:883`.

## The code in question

**(a) Suspension excludes the window from tiling — it is not "counted" in the space:**

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:2127
@discardableResult
private func suspendManagedWindowForNativeFullscreen(_ entry: WindowModel.Entry) -> Bool {
    guard let controller else { return false }
    cancelNativeFullscreenLifecycleTasks(containing: entry.token)
    let changed = controller.workspaceManager.markNativeFullscreenSuspended(entry.token)
    _ = controller.focusBorderController.focusChanged(to: ..., forceOrdering: true)
    if changed {
        controller.layoutRefreshController.requestRefresh(reason: .appActivationTransition, affectedWorkspaceIds: [entry.workspaceId])
    }
    return changed
}
```

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:884  (layout-diff loop)
let suspendedTokens = Set(windows.lazy.filter(\.isNativeFullscreenSuspended).map(\.token))
for window in windows {
    let token = window.token
    if window.isNativeFullscreenSuspended {
        if canRestoreHiddenWorkspaceWindows,
           window.showsNativeFullscreenPlaceholder,
           hiddenHandles[token] == nil,
           let frame = frames[token]
        {
            diff.nativeFullscreenPlaceholders.append(.init(token: token, frame: frame, selected: ...))
        }
        continue                       // ← NOT tiled / not counted as a space member
    }
    ... normal column/window tiling ...
}
```

**(b) The transition guard suppresses the churn that leaks other workspaces:**

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1102
var hasPendingNativeFullscreenTransition: Bool {
    nativeFullscreenRecordsByOriginalToken.values.contains {
        $0.transition == .enterRequested || $0.availability == .temporarilyUnavailable
    }
}

// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1112  (one of several gates)
if controller.workspaceManager.isAppFullscreenActive
    || controller.workspaceManager.hasPendingNativeFullscreenTransition { ... skip / defer relayout ... }

// Sources/Nehir/Core/Controller/MouseEventHandler.swift:1200
guard !controller.workspaceManager.hasPendingNativeFullscreenTransition else { ... return ... }

// Sources/Nehir/Core/Border/FocusBorderController.swift:283
if controller.workspaceManager.hasPendingNativeFullscreenTransition { ... }

// Sources/Nehir/Core/Controller/WMController.swift:3480
guard !workspaceManager.hasPendingNativeFullscreenTransition else { return }
```

## Why both symptoms are already fixed

1. **(a) Not counted in space.** When AX observes a native-fullscreen enter (or a
   command requests one), `suspendManagedWindowForNativeFullscreen` flips the
   window's record to `.suspended` (`AXEventHandler.swift:2127` →
   `WorkspaceManager.swift:1339`). The very next layout pass skips it:
   `if window.isNativeFullscreenSuspended { … continue }`
   (`NiriLayoutHandler.swift:891`). The window therefore occupies no column slot
   and is not part of the space's tiled window count — exactly the behavior the
   title asks for. nehir additionally supports an optional native-fullscreen
   *placeholder* (`diff.nativeFullscreenPlaceholders`) so the suspended slot can
   be represented without tiling it.

2. **(b) No transition-time content leak.** While the enter/exit animation is in
   flight, `hasPendingNativeFullscreenTransition` is true and gates every path
   that could churn the layout or surface hidden windows: scoped/global relayout
   (`LayoutRefreshController.swift:631`, `:1059`, `:1112`, `:1451`), focus-follows-
   mouse (`MouseEventHandler.swift:1200`), border refresh
   (`FocusBorderController.swift:283`), and an early-return guard
   (`WMController.swift:3480`). By deferring relayout until the transition
   settles, nehir avoids the re-tile that would briefly expose another
   workspace's window content. This is the same content-leak class owned by the
   stale-live-frame sibling discoveries, here specifically suppressed for the
   fullscreen transition.

3. **Nothing to port.** The upstream issue is `not_planned` with no fix; nehir's
   suspension + transition-guard design already covers both reported symptoms
   more completely than the issue describes.

## Recommendation

**Do nothing / do not port.** Keep nehir's native-fullscreen suspension +
`hasPendingNativeFullscreenTransition` transition guards as the owners for this
bug class. If a future report shows a residual content flash during a fullscreen
transition *despite* these guards, investigate it as a transition-timing hole
(record the exact `transition`/`availability` values and the deferred relayout
that ran) — not as a missing suspension, which is already in place.

## Suggested tests

- Enter native fullscreen on a tiled window in a multi-window space; assert the
  suspended window is absent from the computed `WorkspaceLayoutDiff` window
  tiles (`NiriLayoutHandler.swift:884`) and that the remaining windows re-tile
  to fill the space (window count for tiling drops by one).
- With another workspace's window hidden on a stably-hidden column, trigger a
  native-fullscreen enter and assert no relayout commits while
  `hasPendingNativeFullscreenTransition` is true (defer until settle), locking in
  the transition-time leak suppression.
