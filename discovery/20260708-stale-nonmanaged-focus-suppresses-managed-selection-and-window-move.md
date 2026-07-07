# Stale non-managed focus suppresses managed selection and leaves move-to-workspace commands targetless

Discovery (2026-07-08). Verified against the main Nehir source tree at `201ca607`.

## Summary

A runtime capture shows Nehir stuck with `isNonManagedFocusActive == true` even though the user is looking at and selecting managed tiled windows. Because the non-managed flag remains active:

1. trackpad viewport selection refuses to call `focusWindow(...)`, so `confirmedManagedFocusToken` stays on an older Helium window;
2. app-activation events for the newly selected managed windows are admitted by the close-recovery gate but are then suppressible by the non-managed-focus anchor guard before `handleManagedAppActivation(...)` can confirm focus; and
3. move-to-workspace commands that depend on `managedCommandTargetToken()` have no target and silently return.

This matches the user symptom: Nehir is in a weird stuck state, and assigning/moving the intended window to another workspace does nothing.

## Related plans and discoveries

- [`20260705-move-focused-window-to-workspace-noop-under-nonmanaged-focus.md`](20260705-move-focused-window-to-workspace-noop-under-nonmanaged-focus.md) is the direct predecessor for the **same command-target failure**: move-focused-window commands guard on `managedCommandTargetToken()`, which can be `nil` while stale non-managed focus is active.
- [`20260707-workspace-bar-shift-click-command-target-stale-nonmanaged.md`](20260707-workspace-bar-shift-click-command-target-stale-nonmanaged.md) covers the workspace-bar Shift-click variant. This discovery supplies a newer capture where the niri viewport selection advances to visible managed windows while the generic command target remains nil.
- [`20260622-dock-click-focus-does-not-reveal-column.md`](20260622-dock-click-focus-does-not-reveal-column.md) is the same suppressor in app-activation/reveal form: `shouldSuppressManagedActivationWhileNonManagedFocusAnchored(...)` can treat a stale non-managed-focus flag as overlay ownership and return before managed focus/reveal.
- [`../planned/20260706-app-activation-nil-focused-window-skips-reveal.md`](../planned/20260706-app-activation-nil-focused-window-skips-reveal.md) is adjacent because this capture also records `AXFocusedWindowChanged pid=89691 window=nil`; that plan handles nil focused-window app activation, while this discovery handles the case where Nehir already has a selected managed viewport target but stale non-managed focus blocks confirmation and command targeting.
- Historical context: [`20260622-workspace-bar-freezes-on-gesture-with-non-managed-focus.md`](20260622-workspace-bar-freezes-on-gesture-with-non-managed-focus.md) and its completed follow-up [`../completed/20260623-workspace-bar-reactive-viewport-lens.md`](../completed/20260623-workspace-bar-reactive-viewport-lens.md) fixed the bar projection freeze from `focusSelection=suppressedNonManagedFocus`; the current failure is the remaining command/focus-confirmation half of the same gesture suppression branch.

## Inline runtime evidence

The capture starts with command targeting already broken:

```text
Focus Targets:
interactionWorkspace=DE3332F7-D365-41F4-A3FE-5FDB86063472
wmCommandTarget=nil
wmCommandTargetSource=nil
layoutSelection=WindowToken(pid: 28651, windowId: 215)
observedManagedFocus=WindowToken(pid: 28651, windowId: 215)
interactionMonitor=ID(displayId: 1)
nonManaged=true
```

The managed layout then moves to real managed windows, but focus confirmation stays pinned to the old Helium token:

```text
21:23:14 touch_scroll_gesture_end
  focusSelection=suppressedNonManagedFocus
  previousActiveColumnIndex=1 endedActiveColumnIndex=2
  selected column contains WindowToken(pid: 82494, windowId: 22025)
  preferredFocus=WindowToken(pid: 82494, windowId: 22025)
  confirmedFocus=WindowToken(pid: 28651, windowId: 215)
```

A second gesture shows the same failure after selecting VS Code Insiders:

```text
21:23:18 touch_scroll_gesture_end
  focusSelection=suppressedNonManagedFocus
  previousActiveColumnIndex=2 endedActiveColumnIndex=3
  selected column contains WindowToken(pid: 89691, windowId: 19325)
  preferredFocus=WindowToken(pid: 89691, windowId: 19325)
  confirmedFocus=WindowToken(pid: 28651, windowId: 215)
```

Nehir observes native activations for those managed apps, but the focus session never confirms either selected token. The event history only records native-app-switch leases while `non_managed=true` remains set:

```text
21:23:16 focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication
  plan=focus=focused=WindowToken(pid: 28651, windowId: 215),pending=nil,lease=native_app_switch,non_managed=true

21:23:19 focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication
  plan=focus=focused=WindowToken(pid: 28651, windowId: 215),pending=nil,lease=native_app_switch,non_managed=true
```

At the end, the workspace viewport and the focus model disagree in the way that makes a move command ambiguous to the user but targetless to Nehir:

```text
Niri Viewports:
workspace=1 visible=true activeColumnIndex=3 currentViewStart=3451.8 targetViewStart=3451.8
  selectedNode=NodeId(uuid: 7667184D-50BC-4869-A141-46DD8E6BB615)
  preferredFocus=WindowToken(pid: 89691, windowId: 19325)

Niri Layout Decisions:
c3 ... {w19325:selected{cur=522,7,1011,1251,target=522,7,1011,1251,hidden:nil}}
c1 ... {w215{cur=-1926,7,1926,1251,target=-1926,7,1926,1251,hidden:left}}

Reconcile Snapshot:
focused=WindowToken(pid: 28651, windowId: 215)
focus-lease=native_app_switch
non-managed-focus=true
WindowToken(pid: 28651, windowId: 215) ... phase=offscreen visible=false
WindowToken(pid: 89691, windowId: 19325) ... phase=tiled visible=true
```

There is also a nil focused-window event from VS Code Insiders:

```text
AX notification trace:
21:23:19 ax=AXFocusedWindowChanged pid=89691 window=nil
```

That event is consistent with the code path that can keep or re-enter non-managed focus when a focused-window query is missing.

## Source-backed mechanism

### 1. The gesture selected managed windows but intentionally did not request focus

`MouseEventHandler` only focuses the selected window after a trackpad snap when focus-follows-mouse is disabled **and** non-managed focus is inactive:

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift:2181-2185` checks `!controller.workspaceManager.isNonManagedFocusActive` before resolving a keyboard focus target.
- `Sources/Nehir/Core/Controller/MouseEventHandler.swift:2197-2203` records `focusSelection=suppressedNonManagedFocus` when a selected window exists but non-managed focus is active.

The capture has exactly that logged disposition twice, so the selected Ghostty and VS Code windows never got a managed focus request from the gesture path.

### 2. Native app activations can be suppressed before they clear non-managed focus

The managed activation path calls `shouldSuppressManagedActivationWhileNonManagedFocusAnchored(...)` before it reaches `handleManagedAppActivation(...)`:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3049-3054` returns early if the non-managed-focus anchor guard says to suppress.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3129-3137` is the later path that would call `handleManagedAppActivation(...)` with `confirmRequest: true`.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3607-3615` shows that `handleManagedAppActivation(...)` would call `workspaceManager.confirmManagedFocus(...)`, which is the transition needed to leave the stale non-managed-focus state.

The suppressor's conditions match the capture:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2484-2490` requires `requestDisposition == .unrelatedNoRequest`, a confirmed focused token different from the observed token, and that confirmed token's workspace still active.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2495-2504` suppresses if `workspaceManager.isNonManagedFocusActive` or a same-pid overlay is visible.

Runtime values line up with those conditions: activations for `WindowToken(pid: 82494, windowId: 22025)` and `WindowToken(pid: 89691, windowId: 19325)` are `requestDisposition=unrelatedNoRequest`, the confirmed token is still the older `WindowToken(pid: 28651, windowId: 215)`, the workspace is active on display 1, and `nonManaged=true` throughout. The guard does not emit a distinct trace record, but the absence of any `managedFocusConfirmed` event plus the final `non-managed-focus=true`/`focused=...215` state is the observed effect of returning before `handleManagedAppActivation(...)`.

### 3. Move-to-workspace commands silently no-op because command target resolution returns nil

The move commands depend on `managedCommandTargetToken()`:

- `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:868-876` starts `moveFocusedWindow(toRawWorkspaceID:)` with `guard let token = controller.managedCommandTargetToken() else { return }`.
- `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:1020-1025` does the same for cross-monitor workspace moves.

Under non-managed focus, `WMController.managedCommandTarget()` refuses to use a tracked frontmost token:

- `Sources/Nehir/Core/Controller/WMController.swift:1916-1922` returns `nil` when `isNonManagedFocusActive` and the current frontmost focused token is already tracked.
- `Sources/Nehir/Core/Controller/WMController.swift:1923-1937` only probes activation when there is not already a tracked frontmost token, and still returns `nil` if no acceptable replacement target is found.

The capture's Focus Targets block has `wmCommandTarget=nil` and `wmCommandTargetSource=nil`, so the guard in the move command has no token to move. That is why assigning/moving the visible selected window to another workspace can do nothing without producing a layout transition.

## Working hypothesis / fix direction

The stuck state is not that the selected managed window is unknown; it is known and selected in the niri viewport. The stuck state is that non-managed focus is allowed to veto both selection focus and managed app activation indefinitely while the confirmed managed focus token points to an offscreen/hidden old window.

A fix should make one of these paths break the loop:

- When a trackpad snap selects a managed tiled window while non-managed focus is active but no visible unmanaged owner is present, allow the explicit viewport selection to request managed focus.
- Or narrow `shouldSuppressManagedActivationWhileNonManagedFocusAnchored(...)` so it does not suppress user-visible managed activations when the preserved focused token is offscreen/hidden and the observed token is the current selected/preferred viewport target.
- Or make `managedCommandTarget()` fall back to the current layout selection/preferred viewport focus when non-managed focus is active but the preserved confirmed focus is offscreen and no concrete unmanaged focused surface is visible.

Any implementation should preserve the quick-terminal/overlay protection documented in the suppressor comment: true unmanaged overlays should not bounce focus to a managed sibling merely because macOS reports a regular app window as focused.
