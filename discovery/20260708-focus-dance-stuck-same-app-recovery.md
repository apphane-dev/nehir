# Same-app close recovery can get stuck in an alternating focus dance

**Date:** 2026-07-08
**Status:** Root cause confirmed in source; actionable.
**Area:** AX focus lifecycle / same-app close-overlay recovery / Niri viewport focus.

## Related docs

- Cross-link cluster: [`CR-1` in `20260708-cross-discovery-relevance-clusters.md`](20260708-cross-discovery-relevance-clusters.md#cr-1--close-recovery-and-same-app-overlay-focus-churn) groups close-recovery / same-app overlay focus churn.
- [`../completed/20260706-stable-viewport-on-window-close-recovery.md`](../completed/20260706-stable-viewport-on-window-close-recovery.md) is the direct parent: it introduced the stable-target redirect, preconfirm/overlay phases, and `recent non-managed (overlay) focus` TTL used by this failure.
- [`../completed/20260707-close-last-app-window-stay-on-current-workspace.md`](../completed/20260707-close-last-app-window-stay-on-current-workspace.md) is the follow-up that narrowed same-app close recovery and added the current close-recovery decision trace markers. Keep its local-close policy intact.
- [`../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md`](../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md) is the compatibility boundary: real same-app focus switches must still reveal/follow the intended target; only close/overlay recovery churn should be damped.
- [`../completed/20260615-quick-terminal-close-switches-workspace.md`](../completed/20260615-quick-terminal-close-switches-workspace.md) is the older quick-terminal close-recovery root problem that led to the current recovery family.
- [`20260615-viewport-reveal-from-unmanaged-overlay-activation.md`](20260615-viewport-reveal-from-unmanaged-overlay-activation.md) is the older unmanaged-overlay activation/reveal sibling. It is not the same loop, but it shares the app-owned overlay / managed sibling activation hazard.
- [`20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md`](20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md) is adjacent NF-1 context: stale or recent non-managed-focus evidence can suppress/redirect managed focus paths. Do not merge its command-target fix surface with this oscillation guard.

## Symptom

After a same-app close or overlay interaction, focus can get stuck rapidly
alternating between two managed windows from the same process. The user-visible
result is a “focus dance”: Nehir keeps issuing managed focus requests, macOS
keeps confirming focus, and the recovery code redirects to the opposite window
again.

## Runtime evidence

The supplied captures contain enough evidence to diagnose this without another
trace. They include start/end runtime state, the managed focus request stream,
viewport recovery decisions, AX focus notifications, and source-mappable
create-focus/replacement records.

### Managed focus requests alternate between two same-pid windows

In the 10:45 capture, the event stream records **111** `managed_focus_requested`
events in roughly three seconds, but only **8** `managed_focus_confirmed` events.
The hot section alternates between the same pid and two window ids:

```text
10:45:23 event=managed_focus_requested token=WindowToken(pid: 82494, windowId: 25395)
         plan=focus=focused=WindowToken(pid: 82494, windowId: 25395),pending=WindowToken(pid: 82494, windowId: 25395)
10:45:23 event=managed_focus_requested token=WindowToken(pid: 82494, windowId: 25401)
         plan=focus=focused=WindowToken(pid: 82494, windowId: 25395),pending=WindowToken(pid: 82494, windowId: 25401)
10:45:23 event=managed_focus_requested token=WindowToken(pid: 82494, windowId: 25395)
         pending=WindowToken(pid: 82494, windowId: 25395)
10:45:23 event=managed_focus_requested token=WindowToken(pid: 82494, windowId: 25401)
         pending=WindowToken(pid: 82494, windowId: 25401)
...
10:45:24 event=managed_focus_requested token=WindowToken(pid: 82494, windowId: 25395)
         pending=WindowToken(pid: 82494, windowId: 25395)
10:45:24 event=managed_focus_requested token=WindowToken(pid: 82494, windowId: 25401)
         pending=WindowToken(pid: 82494, windowId: 25401)
```

The 10:46 capture reproduces the same shape with the newer window set. It records
**93** `managed_focus_requested` events and **13** confirmations, alternating
between `25536` and `25540`:

```text
10:46:36 event=managed_focus_requested token=WindowToken(pid: 82494, windowId: 25540)
         pending=WindowToken(pid: 82494, windowId: 25540)
10:46:36 event=managed_focus_requested token=WindowToken(pid: 82494, windowId: 25536)
         pending=WindowToken(pid: 82494, windowId: 25536)
10:46:36 event=managed_focus_requested token=WindowToken(pid: 82494, windowId: 25540)
         pending=WindowToken(pid: 82494, windowId: 25540)
10:46:36 event=managed_focus_requested token=WindowToken(pid: 82494, windowId: 25536)
         pending=WindowToken(pid: 82494, windowId: 25536)
...
10:46:36 event=managed_focus_confirmed token=WindowToken(pid: 82494, windowId: 25536)
         plan=focus=focused=WindowToken(pid: 82494, windowId: 25536),pending=nil
```

### The same-app overlay recovery redirect picks the opposite window

The viewport trace shows the recovery decision itself. It observes one window and
chooses the other same-pid window as the stable target:

```text
reason=close_recovery_overlay_stable_target
observedToken=WindowToken(pid: 82494, windowId: 25397)
targetToken=WindowToken(pid: 82494, windowId: 25395)
recentSameAppClose=true recentNonManaged=true overlayVisible=false
previousSameAppFocusDisappeared=false selectedSameAppFocusDisappeared=false

reason=close_recovery_activation_gate token=WindowToken(pid: 82494, windowId: 25395)
requestDisposition=matchesActiveRequest(... requestId: 9 ... status: pending)
recentSameAppClose=true recentNonManagedFocus=true decision=evaluate

reason=close_recovery_overlay_stable_target
observedToken=WindowToken(pid: 82494, windowId: 25395)
targetToken=WindowToken(pid: 82494, windowId: 25397)
recentSameAppClose=true recentNonManaged=true overlayVisible=false
previousSameAppFocusDisappeared=false selectedSameAppFocusDisappeared=false
```

The 10:46 capture shows the same source path after active close recovery has
ended (`activeRecoveryWorkspace=nil`):

```text
reason=close_recovery_overlay_stable_target
observedToken=WindowToken(pid: 82494, windowId: 25536)
targetToken=WindowToken(pid: 82494, windowId: 25540)
recentSameAppClose=true recentNonManaged=true overlayVisible=false
previousSameAppFocusDisappeared=false selectedSameAppFocusDisappeared=false

reason=close_recovery_activation_gate token=WindowToken(pid: 82494, windowId: 25540)
requestDisposition=matchesActiveRequest(... requestId: 128 ... status: pending)
activeRecoveryWorkspace=nil recentSameAppClose=true recentNonManagedFocus=true decision=evaluate

reason=close_recovery_overlay_stable_target
observedToken=WindowToken(pid: 82494, windowId: 25540)
targetToken=WindowToken(pid: 82494, windowId: 25536)
recentSameAppClose=true recentNonManaged=true overlayVisible=false
previousSameAppFocusDisappeared=false selectedSameAppFocusDisappeared=false
```

The important discriminator is that both disappeared-focus signals are `false`.
The redirect is not being driven by a confirmed disappeared previous/selected
focus. It is being driven by `.overlay` recovery treating `recentNonManaged=true`
as enough evidence to redirect to the opposite stable viewport target.

### Confirmation pins the viewport and keeps relayout active

The focus confirmation path does not break the dance. The same recovery evidence
pins the active viewport, skips reveal, and still requests relayout:

```text
reason=ax_focus_confirm_before_activate token=WindowToken(pid: 82494, windowId: 25536)
preserveActiveViewport=true closeRecoveryPin=false recentSameAppClosePin=true
overlayRecoveryPin=true selectedSameAppFocusDisappearedPin=false
recentNonManaged=true overlayVisible=false wasAlreadyConfirmedFocus=false
isGesture=false wasAnimating=true

reason=ax_focus_confirm_after_activate token=WindowToken(pid: 82494, windowId: 25536)
isFFM=false preserveActiveViewport=true

reason=ax_focus_confirm_reveal_skipped token=WindowToken(pid: 82494, windowId: 25536)
isFFM=false preserveActiveViewport=true

reason=ax_focus_confirm_request_relayout token=WindowToken(pid: 82494, windowId: 25536)
isFFM=false
```

This explains why the loop stays alive without a normal reveal resolving it:
confirmation preserves the viewport, skips `scrollToReveal`, applies the session
patch, and asks layout refresh to continue.

## Source-backed root cause

`redirectToStableSameAppRecoveryFocusIfNeeded` is the loop source. It runs when
there is no active close-recovery workspace, evaluates same-app overlay evidence,
chooses a stable viewport target excluding the currently observed token, then
focuses that target:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2424` defines
  `redirectToStableSameAppRecoveryFocusIfNeeded(...)`.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2440` computes
  `hasOverlayRecoveryEvidence = signal.recentNonManaged || signal.overlayVisible`.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2445` allows the `.overlay`
  phase when `hasOverlayRecoveryEvidence` is true, even without disappeared-focus
  evidence.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2451` chooses
  `stableViewportFocusTarget(workspaceId: excluding: observedEntry.token)`.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2465` only checks that the
  target exists and differs from the observed token.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2466` calls
  `controller?.focusWindow(target, reason: phase.focusReason)`.

The activation path invokes this overlay redirect before normal request handling
can confirm the observed focus:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3090` checks close-recovery
  suppression.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3106` invokes
  `redirectToStableOverlayRecoveryFocusIfNeeded(...)`.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3110` only then switches on
  `requestDisposition`.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3139` checks the active
  close-recovery stable target later.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3143` ends active
  close-recovery only after those earlier redirect gates.

Each redirect creates or replaces the active managed request:

- `Sources/Nehir/Core/Controller/WMController.swift:4066` records the managed
  focus request in workspace manager state.
- `Sources/Nehir/Core/Controller/WMController.swift:4071` calls
  `focusBridge.beginManagedRequest(...)`.
- `Sources/Nehir/Core/Controller/WMController.swift:4088` invokes the serialized
  focus operation.
- `Sources/Nehir/Core/Controller/WMController.swift:4092` fronts/focuses/raises
  the window and probes focused-window state.
- `Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:62`
  starts `beginManagedRequest(...)`.
- `Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:66`
  reuses only an identical active token/workspace.
- `Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:73`
  creates a new request for a different token.
- `Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:79`
  installs that new request as `activeManagedRequest`.

Therefore A → B and B → A redirects are both treated as fresh, matching active
requests, which is exactly what the runtime records show.

The confirmation path explains the viewport side effects:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3739` computes
  `preserveActiveViewport`.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3742` includes
  `closeRecoveryPins.shouldPin` in that preservation decision.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3848` takes the skipped
  reveal branch when preservation is true.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3866` still requests
  relayout for active workspaces.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3872` calls
  `requestRefresh(reason: .layoutCommand)`.

## Non-root observation: large viewport rebases are explained by source

The captures also show large offset changes while columns are being readmitted
and active-column state is being rebased, for example:

```text
reason=relayout.viewportOffsetChanged columns=2 activeColumnIndex=1
currentOffset=-1027.6 targetOffset=-1023.0 currentViewStart=-10.7 targetViewStart=-6.0
lastViewportMutation=moveSelectionToContainer.rebaseActiveColumn
beforeCurrentOffset=-204.0 beforeTargetOffset=-6.0 beforeActiveColumnIndex=0
afterCurrentOffset=-1221.0 afterTargetOffset=-1023.0 afterActiveColumnIndex=1
```

That movement is source-consistent with the rebase helpers:

- `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:207` finds the display
  scale for reveal/rebase work.
- `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:221` computes the
  active-column position delta.
- `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:222` records
  `moveSelectionToContainer.rebaseActiveColumn` and offsets the viewport.
- `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:2311` computes the
  previous active container position.
- `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:2323` records
  `adjustViewportForContainerPositionChange` and applies the compensating
  offset.

Those rebases are context, not the root cause of the repeated focus requests.
The focus dance is better explained by the overlay stable-target redirect loop.

## Why no more trace data is needed for discovery

The supplied evidence contains every required dimension:

- **Actors:** pid `82494`, alternating managed windows `25395`/`25401` and later
  `25536`/`25540`.
- **Trigger:** `close_recovery_overlay_stable_target` records the observed token
  and opposite target token.
- **Gate inputs:** `recentSameAppClose=true`, `recentNonManaged=true`,
  `overlayVisible=false`, and disappeared-focus signals false.
- **Request behavior:** each opposite redirect becomes a new active request, so
  subsequent observed focus is `matchesActiveRequest`.
- **Viewport behavior:** confirmation records `preserveActiveViewport=true`,
  `ax_focus_confirm_reveal_skipped`, then `ax_focus_confirm_request_relayout`.
- **Source mapping:** redirect, request replacement, confirmation pinning, and
  relayout request all map to durable source citations above.

A fix should still be validated with a fresh runtime run because macOS focus
ordering is timing-sensitive, but the root-cause discovery itself is complete.

## Candidate fix direction

Add an oscillation guard to same-app close/overlay recovery, not to generic focus
confirmation. Reasonable options:

1. Store a short per-pid/workspace recovery redirect latch. After redirecting
   `observed=A -> target=B`, do not redirect `observed=B -> target=A` in the
   same recovery window unless stronger evidence appears, such as
   `previousSameAppFocusDisappeared` or `selectedSameAppFocusDisappeared`.
2. Tighten `.overlay` phase so `recentNonManaged=true` alone does not redirect
   between two on-screen, managed, same-workspace windows when both
   disappeared-focus signals are false.
3. Downgrade or end same-app overlay recovery evidence after the first successful
   managed confirmation that matches a redirected request.

The lowest-risk first patch is likely option 1: preserve the initial recovery
handoff, but prevent the exact two-token bounce shown by the captures.
