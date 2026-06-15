# Workspace bar selected app/window icon can go stale on focus changes — Discovery

Symptom: the workspace bar sometimes does not update the selected window/app icon
highlight after focus changes. The reporter observed this with
focus-follows-mouse activation and with direct click activation.

Trace evidence: `/Users/Aleksei_Gurianov/.local/state/nehir/traces/runtime-trace-1781557052918-1781557057118.log`

**Corrected verdict:** **Conditional refresh gap, not an absolute failure.** The
workspace bar is not refreshed by the focus invalidation itself. It updates only
when the focus change also causes, or coincides with, a workspace-projection
refresh: relayout, workspace transition, window add/remove/rekey, active
workspace/monitor change, etc. The supplied trace captures a focus-change path
that is explicitly marked `isFFM=true` and `ax_focus_confirm_skip_relayout`, so
no workspace-projection refresh is scheduled and the bar can keep stale
`isFocused` flags.

This supersedes the too-strong earlier phrasing (“never updates”). Current code
*can* update the bar after focus, but only under extra conditions that are not
part of the plain `.focusProjection` route.

---

## TL;DR

| Case | What current code does | Bar update? |
| --- | --- | --- |
| Focus changes and only `.focusProjection` is emitted | Routed to status bar refresh only | **No** workspace-bar update |
| FFM focus confirm in active workspace | `isFFM=true` → reveal skipped → relayout skipped | **No** update unless another projection event happens |
| Non-FFM focus confirm in active workspace | `isWorkspaceActive && !isFFM` → request `.layoutCommand` relayout; relayout effects request workspace projection | **Usually yes** |
| Focus/change requires workspace transition or active workspace update | workspace manager emits `.workspaceProjection` (`activeWorkspaceChanged`, `interactionMonitorChanged`, etc.) | **Yes** |
| Focus coincides with window create/destroy/rekey/assignment/hidden/layout reason change | those mutations emit `.workspaceProjection` | **Yes** |

The bug is therefore best described as: **workspace bar focus highlighting is
piggybacking on non-focus projection refreshes instead of being invalidated by
focus itself.**

---

## What the trace proves

### 1. Managed focus is changing correctly

The trace's “Tracing logs” section repeatedly alternates confirmed focus between
two visible Ghostty windows in workspace `FB639718-1074-4C24-953E-AB96CDFE45E7`:

```text
#1  event=managed_focus_requested token=WindowToken(pid: 897, windowId: 6010) … focused=…6012,pending=…6010
#2  event=managed_focus_confirmed token=WindowToken(pid: 897, windowId: 6010) … focused=…6010,pending=nil
#3  event=managed_focus_requested token=WindowToken(pid: 897, windowId: 6012) … focused=…6010,pending=…6012
#4  event=managed_focus_confirmed token=WindowToken(pid: 897, windowId: 6012) … focused=…6012,pending=nil
… repeats through #16
```

So the workspace-manager focus state (`sessionState.focus.focusedToken`) is not
stuck.

### 2. The captured focus confirms are classified as FFM

Every Niri viewport trace entry for the captured ping-pong carries `isFFM=true`:

```text
reason=ax_focus_confirm_before_activate token=…6010 pendingFFM=…6010 pendingFFMFresh=true … isFFM=true
reason=ax_focus_confirm_after_activate  token=…6010 isFFM=true …
reason=ax_focus_confirm_reveal_skipped  token=…6010 isFFM=true …
reason=ax_focus_confirm_skip_relayout   token=…6010 isWorkspaceActive=true isFFM=true isAnimating=false
```

And similarly for `6012`.

### 3. The code intentionally skips relayout for FFM focus confirms

`AXEventHandler.handleManagedAppActivation` computes `isFFM` from fresh
`pendingFFMFocusToken` / `recentFFMFocusToken` state, applies the selection to
Niri state, then only requests relayout when the workspace is active **and** the
confirm is **not** FFM:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:1762-1771
let pendingFFMToken = state.pendingFFMFocusToken
let pendingFFMIsFresh = pendingFFMDate.map { now.timeIntervalSince($0) <= 1.0 } ?? false
let recentFFMToken = state.recentFFMFocusToken
let recentFFMIsFresh = recentFFMDate.map { now.timeIntervalSince($0) <= 1.0 } ?? false
let isFFM = pendingFFMToken == entry.token && pendingFFMIsFresh
    || (recentFFMToken == entry.token && recentFFMIsFresh)
```

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:1894-1907
if isWorkspaceActive, !isFFM {
    controller.recordRuntimeViewportTrace(reason: "ax_focus_confirm_request_relayout", …)
    controller.layoutRefreshController.requestRefresh(reason: .layoutCommand)
    …
} else {
    controller.recordRuntimeViewportTrace(reason: "ax_focus_confirm_skip_relayout", …)
}
```

The supplied trace is the `else` branch: active workspace, but `isFFM=true`, so
no relayout.

### 4. Relayout would have refreshed the bar

`LayoutRefreshController.buildRelayoutExecutionPlan` sets
`effects.requestWorkspaceProjectionRefresh = true` unconditionally for relayout
execution plans:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1048-1057
var effects = RefreshExecutionEffects()
effects.visibility = .init(activeWorkspaceIds: activeWorkspaceIds)
effects.requestWorkspaceProjectionRefresh = true
effects.updateTabbedOverlays = updateTabbedOverlays
```

And `executeRefreshExecutionPlan` routes that effect to
`controller.requestWorkspaceProjectionRefresh()`:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:460-461
if plan.effects.requestWorkspaceProjectionRefresh {
    controller.requestWorkspaceProjectionRefresh()
}
```

Therefore a non-FFM active-workspace click/hotkey path that reaches
`ax_focus_confirm_request_relayout` should update the workspace bar. The trace
does not show that path; it shows the FFM skip path.

---

## Root cause surface

### Focus invalidation itself does not refresh the workspace bar

All projection invalidations from `WorkspaceManager` go through
`WMController.requestProjectionRefresh`:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:455-468
func requestProjectionRefresh(_ invalidation: ProjectionInvalidationRequest) {
    workspaceBarRefreshDebugState.invalidationCounts[invalidation.kind, default: 0] += 1

    switch invalidation.kind {
    case .workspaceProjection:
        requestWorkspaceProjectionRefreshScheduling()
    case .focusProjection:
        requestFocusProjectionRefreshScheduling()
    case .settingsProjection:
        requestSettingsProjectionRefreshScheduling()
    case .layoutProjection, .displayProjection:
        break
    }
}
```

`.workspaceProjection` schedules the path that calls `workspaceBarManager.update()`:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:818-825
workspaceBarRefreshDebugState.executionCount += 1
if workspaceBarRefreshIsEnabled {
    workspaceBarManager.update()
}
if statusBarRefreshIsEnabled {
    refreshStatusBar()
}
```

But `.focusProjection` only schedules the status bar path:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:498-503
private func requestFocusProjectionRefreshScheduling() {
    // Focus changes are only interesting while the status bar is actually
    // displaying workspace info, so skip them when the feature is off.
    requestStatusBarRefreshScheduling(reason: "focusProjection", requireFeatureEnabled: true)
}
```

So a focus change that produces only `.focusProjection` cannot update the
workspace bar.

### Focus changes emit `.focusProjection`

`confirmManagedFocus` emits `.focusProjection` when focus state changes:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1124-1129
if changed {
    notifySessionStateChanged()
    invalidateProjection(.focusProjection, reason: "managedFocusChanged")
}
```

That invalidation reaches the status-bar-only route above. The workspace bar is
updated only if another path emits or directly requests a workspace projection.

---

## Why it sometimes updates

This is the correction to the “never” claim. The workspace bar can update after
focus, but not because `.focusProjection` reached it. It updates because one of
these companion conditions also occurs:

1. **Non-FFM focus in the active workspace.**
   `AXEventHandler` requests `.layoutCommand` relayout when
   `isWorkspaceActive && !isFFM`; relayout effects request workspace projection.
2. **Focus causes a workspace/monitor transition.**
   Workspace state mutations such as `activeWorkspaceChanged`,
   `interactionMonitorChanged`, and `workspaceMonitorAssignmentChanged` emit
   `.workspaceProjection`.
3. **Focus coincides with window lifecycle/membership changes.**
   `windowAdded`, `windowRemoved`, `windowRekeyed`,
   `workspaceAssignmentChanged`, `hiddenStateChanged`, and
   `layoutReasonChanged` emit `.workspaceProjection`.
4. **An unrelated scheduled relayout/gesture/window event is already queued.**
   The next workspace projection rebuilds the bar and makes the focused icon
   “catch up,” making the bug look intermittent.

The observed “unknown conditions” are likely this mixture: any non-focus
workspace projection masks the missing focus invalidation.

---

## Why FFM reliably misses in the supplied trace

`MouseEventHandler` records pending FFM focus before AX confirmation:

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift:1378-1382
controller.workspaceManager.withNiriViewportState(for: workspaceId) { vstate in
    vstate.pendingFFMFocusToken = window.token
    vstate.pendingFFMFocusTimestamp = Date()
    controller.niriLayoutHandler.activateNode(… layoutRefresh: false …)
}
```

`AXEventHandler` treats that pending token, and also a fresh `recentFFMFocusToken`,
as `isFFM` for up to one second. For `isFFM=true` it skips reveal and skips
relayout. Since `.focusProjection` itself does not refresh the workspace bar,
the selected app/window icon can stay stale until another workspace projection
happens.

This exactly matches the trace: every confirm is `isFFM=true`, and every confirm
ends in `ax_focus_confirm_skip_relayout`.

---

## Direct click: what is proven vs. still unknown

What is proven by code:

- A click/focus confirm that is **not** classified as FFM and is in the active
  workspace should request relayout and therefore should request workspace-bar
  refresh.
- A click/focus confirm that **is** classified as FFM will take the same skip
  path as the trace.

Why a direct click can plausibly fail in the reporter's setup:

- With focus-follows-mouse enabled, moving the pointer onto the target before
  clicking can set `pendingFFMFocusToken`.
- The subsequent AX focus confirmation for the click can arrive within the
  1-second freshness window and be classified as `isFFM=true` (or match fresh
  `recentFFMFocusToken`).
- That classification skips relayout, leaving only `.focusProjection`, which is
  status-bar-only.

What is still unknown:

- Whether the reporter's “direct click activation” was taken with FFM enabled
  and preceded by hover activation.
- Whether a direct click with FFM disabled, or after the pending/recent FFM
  freshness window expires, does update the bar in the reporter's environment.
- Whether there is another click path that confirms focus without reaching the
  active-workspace non-FFM relayout branch.

The trace does not include a non-FFM click confirm; all captured confirms are
`isFFM=true`. A follow-up trace should intentionally capture one click with
`focusFollowsMouse=false` and one with it enabled.

---

## Data flow: the bar projection itself is not the failing layer

The workspace bar computes focus highlight from the current confirmed focus
token:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:619-631
WorkspaceBarDataSource.workspaceBarProjection(
    …
    focusedToken: workspaceManager.confirmedManagedFocusToken,
    …
)
```

`WorkspaceBarDataSource` marks windows/apps focused by matching entries against
that token:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift
let anyFocused = appEntries.contains { $0.handle.id == focusedToken }
…
isFocused: entry.handle.id == focusedToken
```

`WorkspaceBarView` uses `isFocused` for the visible highlight/selected state:

- workspace pill background / accent stroke: `WorkspaceBarView.swift:342-348`
- label color: `WorkspaceBarView.swift:376`
- window/app icon opacity/fill/stroke/animation: `WorkspaceBarView.swift:470-494`
- focused indicator affordances: `WorkspaceBarView.swift:507`, `:518`, `:607`, `:617`

`WorkspaceBarWindowItem.==` includes `isFocused` in equality, so a refreshed
snapshot would be detected as changed:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:35-40
lhs.isFocused == rhs.isFocused
```

Thus the likely defect is refresh routing/triggering, not stale projection
calculation.

---

## Suggested fix surface

No implementation is done in this discovery pass.

### Option A: route `.focusProjection` to the workspace projection scheduler

Treat focus changes as workspace-bar-relevant:

```swift
// Sources/Nehir/Core/Controller/WMController.swift
switch invalidation.kind {
case .workspaceProjection, .focusProjection:
    requestWorkspaceProjectionRefreshScheduling()
case .settingsProjection:
    requestSettingsProjectionRefreshScheduling()
case .layoutProjection, .displayProjection:
    break
}
```

Pros:

- Simple; reuses existing coalescing (`Task.yield()` twice), generation guard,
  and `WorkspaceBarSnapshot` equality guard.
- Fixes FFM skip-relayout paths because focus no longer relies on relayout to
  refresh the bar.
- Decouples workspace bar correctness from `settings.statusBarShowWorkspaceName`
  (`requestFocusProjectionRefreshScheduling` currently gates on that unrelated
  status-bar feature).

Cons / review point:

- `flushRequestedWorkspaceProjectionRefresh` also publishes `.workspaceBar`,
  `.windowsChanged`, and `.layoutChanged` IPC events. Decide whether focus-only
  changes should publish those, or whether a narrower refresh path is needed.

### Option B: add a dedicated coalesced focus refresh for the workspace bar

Keep `.focusProjection` distinct but make it schedule:

- `workspaceBarManager.update()` if the workspace bar is enabled
- `refreshStatusBar()` if status-bar workspace name is enabled
- optionally no layout/window IPC fan-out

Pros: avoids broad IPC events on pure focus. Cons: duplicates refresh scheduling
state and leaves another parallel path to maintain.

### Option C: emit workspace projection only for FFM skip-relayout confirms

Patch the narrow failing path after `ax_focus_confirm_skip_relayout` when
`changed == true` / `isFFM == true` by requesting workspace projection. This is
more surgical but less conceptually clean: the bar cares about focus regardless
of why relayout was skipped.

---

## Test coverage gaps

Existing tests cover pieces but not the failing integration:

- `WorkspaceBarDataSourceTests` passes a fixed `focusedToken` and checks
  projection shape. It does not assert that focus changes trigger a bar refresh.
- `RefreshRoutingTests` validates `.workspaceProjection` coalescing, but not
  that `.focusProjection` refreshes the workspace bar.
- `WorkspaceManagerTests` observes focus invalidations, but not their consumers.

Recommended regression tests:

1. **Focus projection refreshes workspace bar.** Enable workspace bar, disable
   status-bar workspace-name, emit `.focusProjection`, wait for flush, assert
   workspace-bar refresh executed and snapshot changed when focus token changed.
2. **FFM skip-relayout still refreshes bar.** Simulate/drive focus confirm with
   fresh `pendingFFMFocusToken` so `isFFM=true` and no relayout is requested;
   assert the bar refreshes anyway.
3. **Non-FFM active-workspace path remains coalesced.** Multiple focus changes
   in one main-actor turn should not cause multiple bar updates.

---

## Follow-up trace request

To identify the reporter's “direct click” condition precisely, capture two short
traces:

1. `focusFollowsMouse=false`, direct click between two visible windows in the
   same active workspace.
2. `focusFollowsMouse=true`, direct click after moving pointer onto the target
   window, both within and after the 1-second pending/recent FFM window if
   possible.

The discriminating fields are in the Niri viewport trace:

- `reason=ax_focus_confirm_before_activate`
- `pendingFFM=…`, `pendingFFMFresh=…`
- `recentFFM=…`, `recentFFMFresh=…`
- `isFFM=…`
- final branch: `ax_focus_confirm_request_relayout` vs.
  `ax_focus_confirm_skip_relayout`

If the direct-click failure shows `isFFM=true`, it is the same skip-relayout
condition as the supplied trace. If it shows `isFFM=false` and still no bar
refresh, there is a second bug after the relayout scheduling path.
