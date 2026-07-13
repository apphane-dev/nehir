# Same-app close successor reveals before actionable removal

**Status:** actionable discovery; failure ordering confirmed, repair signal not yet selected

## Scope

This note documents one captured same-app close failure on an active workspace. It establishes the order in which Nehir accepted and revealed a far same-app successor before the selected model window's removal became actionable.

It does **not** establish:

- a reliable user-level reproduction recipe;
- that ordinary same-app focus changes should be suppressed;
- that the observed AX token `82494:48771` and model token `82494:48769` are interchangeable identities;
- that a longer fixed delay would repair the race; or
- that the Quick Terminal discoveries and this failure have the same event ordering.

## Observed topology

The active workspace had 12 columns. The relevant Ghostty windows, all owned by pid `82494`, were:

| Column | Model token | Role in the failure |
| --- | --- | --- |
| 8 | `82494:42790` | parked same-app successor selected by macOS |
| 9 | `82494:47320` | intervening managed window |
| 10 | `82494:48715` | adjacent surviving managed window |
| 11 | `82494:48769` | selected and confirmed model window before the close |

Immediately before the failure, the viewport was settled on column 11:

```text
activeColumnIndex=11
selectedNode=26709990-CE20-4C1E-AEDF-E04FACF76566   # w48769
preferredFocus=WindowToken(pid: 82494, windowId: 48769)
confirmedFocus=WindowToken(pid: 82494, windowId: 48769)
currentViewStart=12299.7
targetViewStart=12299.7
animating=false
```

## Confirmed event order

### 1. The far successor arrived while column 11 was still current

The first activation-gate event for `w42790` still recorded `w48769` as the current managed same-pid target, selected node, preferred focus, and confirmed focus:

```text
reason=close_recovery_activation_gate
token=WindowToken(pid: 82494, windowId: 42790)
origin=external
requestDisposition=unrelatedNoRequest
activeRecoveryWorkspace=nil
recentSameAppClose=false
recentNonManagedFocus=false
overlayVisible=not_checked
currentTarget=WindowToken(pid: 82494, windowId: 48769)
currentTargetManaged=true
currentTargetSamePid=true
focusedWindowLossPrecursor=nil
decision=evaluate
activeColumnIndex=11
currentViewStart=12299.7
targetViewStart=12299.7
selectedNode=26709990-CE20-4C1E-AEDF-E04FACF76566
preferredFocus=WindowToken(pid: 82494, windowId: 48769)
confirmedFocus=WindowToken(pid: 82494, windowId: 48769)
```

This proves that Nehir had not yet converted the close into recovery state when the successor activation first arrived.

### 2. Overlay capability caused one 120 ms deferral

The next decision was:

```text
reason=overlay_close_churn_deferred
token=WindowToken(pid: 82494, windowId: 42790)
source=focusedWindowChanged
origin=external
reason=await_close_recovery_signal
```

This event proves that pid `82494` satisfied the overlay-capable guard: the deferral function requires `overlayCapablePids.contains(observedEntry.pid)` before it can emit this reason. The function then schedules one retry after `120_000_000` nanoseconds (`Sources/Nehir/Core/Controller/AXEventHandler.swift:3214-3298`).

That does not mean all overlay evidence was absent. The capture specifically proves only that `recentNonManagedFocus=false` and, at the later allow decision, `overlayVisible=false`. Overlay capability itself did apply and caused the deferral.

### 3. AX destruction was observed, but it did not yet produce actionable removal state for `w48769`

During this churn, the AX/runtime stream recorded destruction processing for token `82494:48771`:

```text
destroy_liveness_decision window=48771
  token=WindowToken(pid: 82494, windowId: 48771)
  origin=ax_destroyed
  verify_ws=true
  ws_pid=82494
  outcome=defer
  reason=window_server_alive

destroy_liveness_verification token=WindowToken(pid: 82494, windowId: 48771)
  origin=ax_destroyed
  ws_alive=true
  ax=missing_token
  outcome=remove
  reason=ax_missing_token
```

The liveness path deliberately defers immediate removal while WindowServer still reports the token alive (`Sources/Nehir/Core/Controller/AXEventHandler.swift:5537-5635`). The capture does not prove that AX token `w48771` and selected model token `w48769` are the same identity, so this discovery does not equate them. The relevant proven fact is narrower: no actionable removal of selected model token `w48769`, recent-close marker, recovery context, or focused-window-loss precursor existed when the activation retry ran.

Raw AX destruction therefore did not provide the gate with usable close evidence in time. It is inaccurate to say that the reveal preceded every AX-destroy notification; the reveal preceded the actionable model removal and its recovery markers.

### 4. The retry still had no close-recovery evidence and fell through

The retry recorded the same missing state:

```text
reason=close_recovery_activation_gate
token=WindowToken(pid: 82494, windowId: 42790)
origin=retry
activeRecoveryWorkspace=nil
recentSameAppClose=false
recentNonManagedFocus=false
overlayVisible=not_checked
currentTarget=WindowToken(pid: 82494, windowId: 48769)
focusedWindowLossPrecursor=nil
decision=evaluate
```

The later allow trace said:

```text
reason=close_recovery_activation_gate
token=WindowToken(pid: 82494, windowId: 42790)
origin=external
overlayVisible=false
sameAppCloseOrOverlayEvidence=false
decision=allow reason=no_close_or_overlay_evidence
```

These are not two independent successor arrivals. The first event identifies the gate invocation as `origin=retry`; the downstream `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery` call hardcodes `.external` when recording its no-evidence allow trace (`Sources/Nehir/Core/Controller/AXEventHandler.swift:3447-3479`). The second `origin` value is an instrumentation artifact.

### 5. Acceptance changed selection and started the far reveal

After the allow decision, Nehir accepted `w42790`:

```text
reason=ax_focus_confirm_before_activate
token=WindowToken(pid: 82494, windowId: 42790)
preserveActiveViewport=false
preserveActiveViewportReason=none
selectedNode=6B47C4F9-C7D3-46A4-A823-1352D77B5F58   # w42790
preferredFocus=WindowToken(pid: 82494, windowId: 48715)
confirmedFocus=WindowToken(pid: 82494, windowId: 42790)
activeColumnIndex=11
currentViewStart=12299.7
targetViewStart=12299.7
```

The reveal candidate then identified column 8 as parked and moved the viewport target:

```text
reason=ax_focus_confirm_reveal_candidate
token=WindowToken(pid: 82494, windowId: 42790)
columnIndex=8
visibility=parked(minimum)
viewStart=12299.7
closest=10265.7:leftEdge

reason=ax_focus_confirm_reveal_result
didReveal=true

reason=relayout.viewportOffsetChanged
activeColumnIndex=8
currentViewStart=12295.0
targetViewStart=10265.7
animating=true
```

Thus the concrete unwanted mutation was:

```text
selected model column: 11 -> 8
confirmed focus: w48769 -> w42790
viewport target: 12299.7 -> 10265.7
```

At the reveal, `preferredFocus` was still the adjacent survivor `w48715`; it was not changed to `w42790` until later processing.

### 6. Final model removal happened after column 8 was already active

The later removal decision for the selected model token recorded:

```text
reason=close_recovery_removed_window_focus_recovery
removedToken=WindowToken(pid: 82494, windowId: 48769)
confirmedBeforeRemoval=WindowToken(pid: 82494, windowId: 42790)
activeRecoveryWorkspace=nil
activeRecoveryPreservedToken=nil
precursorWorkspace=nil
precursorPreservedToken=nil
matchesConfirmed=false
matchesActiveRecoveryToken=false
matchesFocusedWindowLossPrecursor=false
affectedWorkspaceActive=true
shouldRecoverFocus=false
activeColumnIndex=8
targetViewStart=10265.7
selectedNode=6B47C4F9-C7D3-46A4-A823-1352D77B5F58
confirmedFocus=WindowToken(pid: 82494, windowId: 42790)
```

`handleRemoved(token:)` records the recent same-app close only when this actionable removal path starts (`Sources/Nehir/Core/Controller/AXEventHandler.swift:2265-2272`). By then the far successor was already selected and the reveal spring was running.

The layout removal logic can select a fallback from the active column when the removed column is active (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:294-327,411-539`). Here the active index had already changed to 8 before column 11 was removed. Consequently, removal of column 11 did not execute the active-column adjacent fallback that could have kept focus near the closing column.

## Confirmed failure mechanism

The proven failure is an ordering gap:

1. macOS reported the far same-app successor while `w48769` was still selected and confirmed;
2. overlay capability delayed the first arrival by 120 ms;
3. at retry, Nehir still had no `recentSameAppClose`, active close-recovery context, recent non-managed focus, visible overlay, or focused-window-loss precursor;
4. the retry accepted `w42790`, changed selected/confirmed focus to column 8, and started the viewport reveal;
5. actionable removal of model token `w48769` occurred only after column 8 was active, so the removal path could no longer apply active-column adjacency behavior.

This evidence supports “successor focus was accepted before actionable close/removal evidence armed recovery.” It does not support “the reveal happened before any AX destroy event.”

## Existing precursor and why it did not help

Nehir already has a pid-keyed, 0.6-second `focusedWindowLossClosePrecursor` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:918,927-928,6275-6301`). It is armed in `handleMissingFocusedWindow` when a `focusedWindowChanged` event observes no focused window and can preserve the current managed token/workspace (`Sources/Nehir/Core/Controller/AXEventHandler.swift:7116-7162`).

The activation and removal evidence both recorded the precursor as `nil`. Therefore the missing-focused-window arming path did not run in this failure. A proposal to add another workspace-keyed precursor would be unsupported unless a new pre-acceptance signal is first identified and shown to distinguish this close from a legitimate same-app focus change.

## Repair requirements, not a selected design

A valid implementation plan needs a proven signal available before successor acceptance that can distinguish:

- this close-related transition, where selected model token `w48769` must remain the recovery anchor until removal; from
- a genuine user-driven same-app focus change to `w42790`, which must still be honored.

Any candidate design must also establish how the AX/runtime token involved in destruction maps to the selected model token before using it as closing-token evidence. Candidate-ordering helpers or adjacent-column fallbacks are not sufficient on their own: they are safe only after the closing model identity is proved and excluded from successor selection.

The evidence does not justify:

- suppressing all same-app parked focus changes;
- treating overlay capability alone as proof of a close;
- extending the 120 ms delay without an evidence-based completion condition; or
- adding a new precursor keyed differently but armed from the same absent signal.

## Validation requirements

A future fix should be accepted only with a capture that demonstrates the actual overlap:

1. column 11 is selected and confirmed before the close-related successor event;
2. `w42790` arrives before actionable removal of `w48769`;
3. the new gate identifies a concrete close signal and preserves the closing-column anchor;
4. `w42790` is not confirmed or revealed during that overlap;
5. removal excludes the closing token and selects an adjacent surviving target such as `w48715` according to the existing layout policy;
6. the viewport does not spring from `12299.7` to `10265.7`; and
7. a genuine user-driven same-app switch to a parked window still reveals normally.

A no-scroll run without the overlapping ordering above is not sufficient validation.

## Relationship to existing discoveries

- [`20260709-window-close-successor-app-activation-reveals-far-parked-column.md`](20260709-window-close-successor-app-activation-reveals-far-parked-column.md) shares the symptom and desired close-successor policy, but its cross-app activation ordering is different. It is a policy sibling, not proof of the same mechanism.
- [`../completed/20260706-stable-viewport-on-window-close-recovery.md`](../completed/20260706-stable-viewport-on-window-close-recovery.md) covers the post-removal close-recovery machinery that arrived too late here.
- [`../completed/20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md`](../completed/20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md) and [`../completed/20260710-quick-terminal-close-after-restart-lacks-overlay-evidence.md`](../completed/20260710-quick-terminal-close-after-restart-lacks-overlay-evidence.md) cover Quick Terminal-specific paths. This discovery does not claim their reproduction conditions or event ordering.
