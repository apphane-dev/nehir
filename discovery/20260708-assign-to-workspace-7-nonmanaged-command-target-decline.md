# Assign-to-workspace-7 no-ops when non-managed focus makes command target resolution decline

Discovery (2026-07-08). Verified against the main Nehir source tree at `c6eaafb9`.

## Summary

A runtime capture of repeated attempts to assign/move Helium windows to workspace 7 shows the exact failing moment. The command-target resolver was invoked twice while the interaction workspace was already workspace 7 on display 2, but `isNonManagedFocusActive` was true and the frontmost focused window was a tracked managed window. `managedCommandTarget()` therefore emitted `command_target.resolve.decline reason=nonManagedFocus.frontmostTracked` and returned `nil`. The move-to-workspace command then had no token and silently returned before any `workspace_assigned` event could be emitted.

The stuck state cleared a few seconds later. Once managed focus was confirmed again, the same resolver accepted the visible/layout-selected Helium windows and the `workspace_assigned` events to workspace 7 appeared immediately.

This is a direct, newly instrumented NF-1 instance: stale/non-managed focus does not just suppress reveal; it can make an explicit workspace assignment command targetless while the user-visible frontmost token is already tracked by Nehir.

## Related plans and discoveries

- Cross-link cluster: [`NF-1` in `20260708-cross-discovery-relevance-clusters.md`](20260708-cross-discovery-relevance-clusters.md#nf-1--stale-non-managed-focus-blocks-admission-confirmation-and-command-targets) groups stale non-managed-focus command-target/admission failures.
- [`20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md`](20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md) is the broader current discovery. This note adds the strongest direct command-target evidence because it includes the shipped `command_target.resolve.*` decision events.
- [`20260705-move-focused-window-to-workspace-noop-under-nonmanaged-focus.md`](20260705-move-focused-window-to-workspace-noop-under-nonmanaged-focus.md) described the same silent move-command guard before the resolver trace existed.
- [`20260707-workspace-bar-shift-click-command-target-stale-nonmanaged.md`](20260707-workspace-bar-shift-click-command-target-stale-nonmanaged.md) is the workspace-bar Shift-click variant: a UI action with a concrete intended destination still re-resolves through the generic command target.

## Inline runtime evidence

Topology and final workspace mapping in the capture identify workspace 7 and the monitor involved:

```text
monitors=2 workspaces=7 visibleWorkspaces=2
workspace=7 id=858C762F-C57A-45F9-8F8A-147CAB964A91 visible=true columns=2 activeColumnIndex=1
  preferredFocus=WindowToken(pid: 28651, windowId: 22680)
workspace=7 ... c0{w26317} | c1{w22680:selected}
WindowToken(pid: 28651, windowId: 22680) workspace=858C762F-C57A-45F9-8F8A-147CAB964A91 monitor=ID(displayId: 2) visible=true
WindowToken(pid: 28651, windowId: 26317) workspace=858C762F-C57A-45F9-8F8A-147CAB964A91 monitor=ID(displayId: 2) visible=true
```

The bad state arms just before the failed assignments. Nehir has switched interaction to display 2 and enters non-managed focus:

```text
14:46:12 event=non_managed_focus_changed active=true fullscreen=false preserve=false preserve_pending=false
  interaction=ID(displayId: 2)/prev=ID(displayId: 1)
  plan=focus=focused=nil,pending=nil,non_managed=true
```

At the first failed attempt, the resolver sees the frontmost Helium window as tracked, but because non-managed focus is active it declines instead of using that token. There is no confirmed focus fallback, no layout-selection fallback, and no target token:

```text
14:46:15 event=command_target.resolve.begin cluster=NF-1 resolver=managedCommandTarget
  frontmostPid=28651 frontmostToken=28651:22680
  frontmostTokenTracked=true
  confirmedToken=nil confirmedWorkspace=nil
  layoutSelectionToken=nil layoutSelectionWorkspace=nil
  interactionWorkspace=858C762F-C57A-45F9-8F8A-147CAB964A91
  interactionMonitor=ID(displayId: 2)
  nonManagedActive=true
  targetToken=nil targetWorkspace=nil targetSource=nil

14:46:15 event=command_target.resolve.decline cluster=NF-1 resolver=managedCommandTarget
  reason=nonManagedFocus.frontmostTracked
  frontmostPid=28651 frontmostToken=28651:22680
  frontmostTokenTracked=true
  confirmedToken=nil confirmedWorkspace=nil
  layoutSelectionToken=nil layoutSelectionWorkspace=nil
  interactionWorkspace=858C762F-C57A-45F9-8F8A-147CAB964A91
  interactionMonitor=ID(displayId: 2)
  nonManagedActive=true
  targetToken=nil targetWorkspace=nil targetSource=nil
```

The same decline repeats one second later:

```text
14:46:16 event=command_target.resolve.decline cluster=NF-1 resolver=managedCommandTarget
  reason=nonManagedFocus.frontmostTracked
  frontmostPid=28651 frontmostToken=28651:22680
  frontmostTokenTracked=true
  confirmedToken=nil confirmedWorkspace=nil
  layoutSelectionToken=nil layoutSelectionWorkspace=nil
  interactionWorkspace=858C762F-C57A-45F9-8F8A-147CAB964A91
  interactionMonitor=ID(displayId: 2)
  nonManagedActive=true
  targetToken=nil targetWorkspace=nil targetSource=nil
```

No `workspace_assigned` event to workspace 7 occurs at 14:46:15 or 14:46:16. The first successful move happens only after managed focus recovers and the resolver starts accepting layout-selection targets again:

```text
14:46:18 event=managed_focus_confirmed token=WindowToken(pid: 28651, windowId: 26317)
  workspace=6844D970-CC2F-4149-BDB1-3BB9AD5DAF41
  interaction=ID(displayId: 1)/prev=ID(displayId: 2)

14:46:19 event=command_target.resolve.accept cluster=NF-1 resolver=managedCommandTarget
  reason=layoutSelection
  frontmostToken=28651:26317
  confirmedToken=28651:26317
  layoutSelectionToken=28651:26317
  targetToken=28651:26317
  targetWorkspace=6844D970-CC2F-4149-BDB1-3BB9AD5DAF41
  targetSource=layoutSelection

14:46:19 event=workspace_assigned token=WindowToken(pid: 28651, windowId: 26317)
  from=6844D970-CC2F-4149-BDB1-3BB9AD5DAF41
  to=858C762F-C57A-45F9-8F8A-147CAB964A91

14:46:20 event=command_target.resolve.accept cluster=NF-1 resolver=managedCommandTarget
  reason=layoutSelection
  frontmostToken=28651:22680
  confirmedToken=28651:22680
  layoutSelectionToken=28651:22680
  targetToken=28651:22680
  targetWorkspace=6844D970-CC2F-4149-BDB1-3BB9AD5DAF41
  targetSource=layoutSelection

14:46:20 event=workspace_assigned token=WindowToken(pid: 28651, windowId: 22680)
  from=6844D970-CC2F-4149-BDB1-3BB9AD5DAF41
  to=858C762F-C57A-45F9-8F8A-147CAB964A91
```

The recovery sequence confirms that the workspace transfer machinery and target workspace were valid. The only missing piece during the bad window was a resolved command target token.

## Source-backed mechanism

### 1. The command resolver intentionally declines a tracked frontmost token under non-managed focus

`WMController.managedCommandTarget(traceDecision:)` reads the frontmost pid/token first (`Sources/Nehir/Core/Controller/WMController.swift:1896-1900`) and emits `command_target.resolve.begin` (`WMController.swift:1925`).

Inside the non-managed-focus branch, a tracked frontmost token is an immediate decline:

- `Sources/Nehir/Core/Controller/WMController.swift:1954-1958` enters the branch when `workspaceManager.isNonManagedFocusActive` and checks whether `frontmostToken` has a managed entry.
- `Sources/Nehir/Core/Controller/WMController.swift:1959-1964` records `command_target.resolve.decline reason=nonManagedFocus.frontmostTracked` and returns `nil`.

That is exactly the runtime evidence at 14:46:15 and 14:46:16: `nonManagedActive=true`, `frontmostToken=28651:22680`, `frontmostTokenTracked=true`, `reason=nonManagedFocus.frontmostTracked`, and all target fields nil.

### 2. The trace fields prove the decline happened before later fallbacks

The resolver would normally be able to use a concrete niri layout selection:

- `Sources/Nehir/Core/Controller/WMController.swift:1879-1888` starts `layoutSelectionCommandTarget()` by finding the selected niri node in the interaction workspace and returning its token if it is still tracked.
- `Sources/Nehir/Core/Controller/WMController.swift:2060-2073` accepts that layout-selection target after the floating/frontmost branches.
- `Sources/Nehir/Core/Controller/WMController.swift:2087-2099` can also accept the confirmed managed focus token later in the resolver.

However, the non-managed-focus branch returns earlier at `WMController.swift:1964`, so those fallback branches are unreachable during the bad state. The runtime fields back this up: during the failed attempts both `layoutSelectionToken=nil` and `confirmedToken=nil`; after recovery the same trace family accepts `reason=layoutSelection` with concrete `targetToken` values.

The trace writer itself records the values used above from source: `Sources/Nehir/Core/Controller/WMController.swift:2131-2180` emits the `NF-1` decision event with `frontmostTokenTracked`, `confirmedToken`, `layoutSelectionToken`, `interactionWorkspace`, `interactionMonitor`, `nonManagedActive`, `targetToken`, `targetWorkspace`, and `targetSource`.

### 3. Move-to-workspace entry points silently return when the resolver returns nil

Move/assign commands that do not already carry an explicit token depend on `managedCommandTargetToken()`:

- `Sources/Nehir/Core/Controller/WMController.swift:2243-2245` defines `managedCommandTargetToken()` as `managedCommandTarget()?.token`.
- `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:693-709` starts adjacent-workspace moves with `guard let token = controller.managedCommandTargetToken() else { return }` and only calls `reassignManagedWindow(...)` after the guard.
- `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:868-880` uses the same guard for moving the focused window to a raw workspace id.
- `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:1020-1054` uses the same guard for move-to-workspace-on-monitor.

Therefore a nil resolver result exactly explains the missing `workspace_assigned` events during the failed attempts.

When the guard is satisfied, the source emits the later success events seen in the capture:

- `Sources/Nehir/Core/Controller/WMController.swift:3772-3794` records explicit move intent and calls `workspaceManager.setWorkspace(for:to:)`.
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3257-3279` updates the window workspace and records the `.workspaceAssigned` reconcile event.

The capture shows those events only after the resolver accepts `targetToken=28651:26317` and then `targetToken=28651:22680`.

## Working hypothesis / fix direction

The root problem is not that Nehir lacks a managed candidate. At 14:46:15–14:46:16 the frontmost token is tracked and the user is interacting with workspace 7 on display 2, but the stale/non-managed-focus guard treats the tracked frontmost token as evidence to drop the command rather than evidence that a managed command target exists.

A fix should preserve overlay/menu protection while ensuring explicit workspace-move intent is not silently discarded when the only visible/frontmost candidate is already tracked. Plausible slices:

1. For explicit move-to-workspace commands, allow a tracked frontmost token or layout-selection token under non-managed focus when there is no concrete unmanaged target surface visible.
2. Or add a separate explicit-token command path for UI gestures that know the target window, avoiding generic `managedCommandTarget()` entirely.
3. At minimum, keep `command_target.resolve.*` coverage and add destination/raw-workspace fields around move commands so future captures show both the dropped source token and the intended destination.

Do not remove the non-managed-focus guard wholesale: it protects true unmanaged overlays, menus, quick terminals, and system UI from stealing managed-window command focus.
