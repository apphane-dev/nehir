# Quick-Terminal Close Switches Active Workspace — Discovery

Reported issue: **closing the Ghostty "quick terminal" switches the active
workspace to workspace 1, unexpectedly.** An existing fix in this fork is
supposed to ignore macOS's same-app focus redirection on window close and keep
the user on the same workspace with no viewport scrolling. That fix did not fire
here. All evidence is inlined below; this document does not depend on any trace
file surviving.

All file references should be re-verified before implementing; line numbers drift.

---

## TL;DR

- The existing "stay on workspace after close" guard is the
  **`.windowCloseFocusRecovery`** focus-policy lease, begun in
  `AXEventHandler.handleRemoved(token:)` (`AXEventHandler.swift:1163`–`1165`)
  **only when** the removed window is genuinely destroyed **and** was the
  confirmed focused window. It lasts 0.6 s (`windowCloseFocusRecoveryDuration`,
  `:296`).
- In the captured repro, the quick-terminal "close" produced **no window
  removal at all**: the `LayoutRefreshController` `windowRemoval` counter is `8`
  at both capture start and end, no `window_removed` reconcile event appears in
  `## Tracing logs`, and
  `lastAffectedWorkspaceIdsByReason[.windowDestroyed] = Set([])`. So
  `handleRemoved` never ran, the lease was never begun, and the post-close
  focus redirection was unsuppressed.
- The unwanted switch is visible mid-capture: focus moved from a Ghostty window
  on **workspace 2** (`189E7132`) back to Slack on **workspace 1**
  (`5B8E9E2A`) via a `native_app_switch` /
  `workspaceDidActivateApplication` lease.
- **Root cause:** the recovery trigger is destroy-gated. A quick terminal that
  **hides / orders-out** (the typical dropdown-terminal close behavior) is not a
  destroy, so the suppression never arms. The fix should arm the recovery on
  *focus leaving a managed window*, not only on destruction.
- Secondary gap: even the in-capture switch was **cross-app** (Ghostty `pid 897`
  → Slack `pid 84013`), but the same-app guard
  (`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`,
  `:1264`) only suppresses same-`pid` activations. So that particular jump would
  not have been caught even with the lease active.

---

## Inlined trace findings (self-contained)

> Source: runtime trace capture, nehir v0.5.0, build `vfb5ce3`,
> startedAt `2026-06-15T19:52:40Z`, endedAt `2026-06-15T19:52:55Z`,
> duration 15.108 s. Single monitor.

### Topology & workspace mapping

```
ID(displayId: 1) isMain=true hasNotch=true frame=(0.0, 0.0, 2056.0, 1329.0)
    visibleFrame=(0.0, 0.0, 2056.0, 1290.0) name=Built-in Retina Display
```

- **workspace 1** = `5B8E9E2A-CF45-4DDE-90DB-F0ECB6F01C14` — visible at start/end
- **workspace 2** = `189E7132-DBC3-4D92-A6B2-A75ED79ACFE6` — a Ghostty window
  lands here mid-capture

Managed windows of interest (Ghostty is `pid 897`, Slack is `pid 84013`):

| token | app | workspace | notes |
|---|---|---|---|
| `84013:1025` | slack | `5B8E9E2A` (ws1) | confirmed focus at START |
| `897:5632` | ghostty | `5B8E9E2A` (ws1) | admitted mid-capture; focused at END |
| `897:5637` | ghostty | `189E7132` (ws2) | admitted mid-capture; briefly focused on ws2 |

### Proof that no window was destroyed during the capture

`LayoutRefreshController` counters (cumulative since app start), start vs end:

```
START  windowRemoval=8   relayout=14  immediateRelayout=388
END    windowRemoval=8   relayout=16  immediateRelayout=393
```

`windowRemoval` is unchanged (8 → 8). `lastAffectedWorkspaceIdsByReason` at END:

```
Nehir.RefreshReason.windowDestroyed: Set([])
```

And `## Tracing logs` contains **no** `window_removed` record. The only
`window_admitted` records are creates. Conclusion: the quick-terminal "close"
the user performed is **not** a destroy in nehir's model — it is a hide / order
out / focus loss. This is the central fact the fix must account for.

### The unwanted workspace switch (mid-capture)

Selected `## Tracing logs` records, in order (all carry
`interaction=ID(displayId: 1)/prev=nil`):

```
#36 19:52:51 window_admitted token=897:5637 workspace=189E7132 (ws2) mode=tiling
#37 19:52:51 managed_focus_confirmed token=897:5637 workspace=189E7132 (ws2)
            monitor=Optional(ID(displayId: 1)) plan=focused=897:5637,pending=nil
#38 19:52:51 focus_lease_changed owner=native_app_switch
            reason=workspaceDidActivateApplication plan=…lease=native_app_switch
…
#55 19:52:51 focus_lease_changed owner=nil  focus_lease=cleared
#56 19:52:51 focus_lease_changed owner=native_app_switch
            reason=workspaceDidActivateApplication
#57 19:52:51 managed_focus_confirmed token=84013:1025 (slack)
            workspace=5B8E9E2A (ws1) monitor=Optional(ID(displayId: 1))
            plan=focused=84013:1025,pending=nil,lease=native_app_switch
```

`#57` is the switch: confirmed focus leaves the Ghostty window on **workspace 2**
and lands on Slack on **workspace 1**, under a `native_app_switch` lease. The
viewport trace confirms the active workspace went 1 → 2 → 1 (workspace-2
viewport records appear at `19:52:51`; workspace-1 records reappear at
`19:52:52` with Slack `84013:1025` as `confirmedFocus`). The
`LayoutRefreshController` executed `workspaceTransition: 4` times during the
capture.

The `## Niri create focus trace` corroborates the churn: many
`activation_source_observed pid=897 source=focusedWindowChanged` and
`non_managed_fallback_entered pid=897` records around this window, plus
`pending_focus_started request=… token=897:5637 workspace=189E7132` followed by
focus bouncing back to Slack `84013:1025` on `5B8E9E2A`.

### State at END

```
focused=WindowToken(pid: 897, windowId: 5632)   ← ghostty, workspace 1
interaction-monitor=ID(displayId: 1)
workspace 1 visible, columns=5, activeColumnIndex=3, currentViewStart=4250.8
workspace 2 NOT visible, 1 column (897:5637)
```

The quick-terminal window `897:5632` is still managed at END (not destroyed) —
consistent with the "close = hide" finding.

### Fresh capture with raw AX notifications (2026-06-15, 21:02 UTC)

A later single-monitor capture added raw AX notification tracing and direct
interaction-monitor write tracing. It reproduces the same workspace-2 →
workspace-1 jump with more precise evidence.

Workspace mapping in this capture:

- **workspace 1** = `DBD47BBA-5B7F-4013-B64C-408E95674A06`
- **workspace 2** = `F339DEEE-E6DE-4BE6-A474-9E44C4FD2466`

At `21:02:40`, Ghostty window `897:6166` is focused on workspace 2:

```
#50 21:02:40 window_admitted token=897:6166 workspace=F339DEEE (ws2) mode=tiling
#51 21:02:40 managed_focus_confirmed token=897:6166 workspace=F339DEEE (ws2)
#56 21:02:40 managed_focus_requested token=897:6166 workspace=F339DEEE (ws2)
#57 21:02:40 managed_focus_confirmed token=897:6166 workspace=F339DEEE (ws2)
```

At `21:02:41`, the jump starts. macOS/Nehir observe an activation of the
workspace-1 app Zed (`16714:4929`) under a native app-switch lease, then hide the
workspace-2 Ghostty windows:

```
#66 21:02:41 focus_lease_changed owner=native_app_switch
              reason=workspaceDidActivateApplication
              plan=focused=897:6166,pending=nil,lease=native_app_switch
#67 21:02:41 managed_focus_confirmed token=16714:4929
              workspace=DBD47BBA (ws1) monitor=Optional(ID(displayId: 1))
              plan=focused=16714:4929,pending=nil,lease=native_app_switch
#68 21:02:41 hidden_state_changed token=16714:4929 workspace=DBD47BBA hidden=false
#69 21:02:41 hidden_state_changed token=897:6160 workspace=DBD47BBA hidden=false
#70 21:02:41 hidden_state_changed token=897:6164 workspace=F339DEEE hidden=true
#71 21:02:41 hidden_state_changed token=897:6166 workspace=F339DEEE hidden=true
```

The viewport trace for the same instant confirms this is an actual activation of
workspace 1, not just focus bookkeeping:

```
workspace=1 id=DBD47BBA reason=ax_focus_confirm_before_activate
  token=WindowToken(pid: 16714, windowId: 4929)
  preserveActiveViewport=false confirmedFocus=WindowToken(pid: 16714, windowId: 4929)
workspace=1 id=DBD47BBA reason=ax_focus_confirm_after_activate
  token=WindowToken(pid: 16714, windowId: 4929)
  preserveActiveViewport=false confirmedFocus=WindowToken(pid: 16714, windowId: 4929)
workspace=1 id=DBD47BBA reason=ax_focus_confirm_skip_relayout
  token=WindowToken(pid: 16714, windowId: 4929) isWorkspaceActive=false
```

Raw AX notifications around the same period are:

```
21:02:38 ax=AXFocusedWindowChanged pid=897 window=nil
21:02:39 ax=AXFocusedWindowChanged pid=897 window=nil
21:02:40 ax=AXFocusedWindowChanged pid=897 window=nil
21:02:41 ax=AXUIElementDestroyed pid=897 window=101
21:02:43 ax=AXFocusedWindowChanged pid=897 window=nil
```

Important interpretation: the raw `AXUIElementDestroyed` is for `window=101`,
not for the managed Ghostty windows in the trace (`6160`, `6164`, `6166`). The
managed window table at END still contains all three Ghostty windows, with
`6164`/`6166` on workspace 2 and hidden because the workspace is inactive. So
the existing destroy-gated close recovery still does not apply to the managed
quick-terminal window that was focused.

This capture therefore strengthens H1: the visible "close" path is a focus-loss
/ hide / app-activation sequence, not a tracked managed-window removal. The
specific bad transition is `workspaceDidActivateApplication` confirming an
unrelated workspace-1 managed window while the focused Ghostty window on
workspace 2 is disappearing or losing AX focus.

---

## The existing fix, cited

The "ignore macOS same-app focus selection on close / stay on workspace" guard
is a focus-policy lease:

- **Lease owner:** `FocusPolicyLease.windowCloseFocusRecovery`
  (`FocusPolicyEngine.swift:5`).
- **Begun:** `AXEventHandler.beginWindowCloseFocusRecovery(in:)`
  (`AXEventHandler.swift:1210`), which sets a 0.6 s context
  (`windowCloseFocusRecoveryDuration`, `:296`) and calls
  `focusPolicyEngine.beginLease(owner: .windowCloseFocusRecovery, …)`.
- **Gated on destruction + confirmed focus.** The only call site is
  `handleRemoved(token:)` (`:1163`–`1165`):

  ```swift
  let shouldRecoverFocus = token == controller.workspaceManager.confirmedManagedFocusToken
  if shouldRecoverFocus, let workspaceId = affectedWorkspaceId {
      beginWindowCloseFocusRecovery(in: workspaceId)
  }
  ```

  `handleRemoved(token:)` is reached only from the destroy pipeline
  (`processPreparedDestroy` → `handleRemoved`, `AXEventHandler.swift:2655`;
  and `handleRemoved(pid:winId:)` → `handleWindowDestroyed`, `:1146`).

- **What the lease suppresses:**
  - `shouldSuppressObservedActivationDuringWindowCloseRecovery` (`:1249`)
    drops observed activations on a workspace other than the recovery
    workspace.
  - `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
    (`:1264`) drops same-`pid` activations onto an inactive workspace (this is
    the "ignore macOS selecting another window of the same app" guard).
  - The `if activeWindowCloseFocusRecoveryWorkspaceId() != nil` early-return
    at `:1538` returns early for `unrelatedNoRequest` activations during the
    lease.

### Why it did not fire here

1. **No destroy.** The recovery is begun exclusively from `handleRemoved`, i.e.
   on real window destruction. This capture proves the quick-terminal close was
   not a destroy (`windowRemoval` unchanged, no `window_removed` event). So the
   lease was never armed and every suppression above was a no-op.
2. **Cross-app jump is out of the same-app guard's scope.** Even if the lease
   had been active, the observed switch (`#57`) is Ghostty (`897`) → Slack
   (`84013`) — different `pid`. The same-app guard
   (`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`,
   `:1264`) keys on `currentTarget.pid == observedEntry.pid` /
   `focusedToken.pid == observedEntry.pid`, so it would not have suppressed a
   cross-app activation. The `:1538` early-return *would* have caught an
   `unrelatedNoRequest` activation — but only while the lease is active, which
   requires (1).
3. **0.6 s is fragile.** `windowCloseFocusRecoveryDuration` (`:296`) is 600 ms.
  Even for a genuine destroy, a focus redirection that arrives after 600 ms
  (common when an app takes time to re-activate) escapes the guard.

---

## Hypotheses

### H1 — quick-terminal close is a hide/order-out, not a destroy (favored)

Ghostty's quick terminal toggles visibility rather than destroying its window.
macOS therefore delivers a **focus-changed** event (focus leaves the terminal)
rather than a destroy. Because the recovery lease is destroy-gated, it never
arms, and macOS's chosen successor window (here Slack on workspace 1, or another
same-app window) takes focus unimpeded.

Consistent with: `windowRemoval` unchanged across the capture; `897:5632` still
managed at END; the `native_app_switch` / `focusedWindowChanged` activation
churn in `## Niri create focus trace`.

### H2 — the recovery armed but expired before the redirection

The lease lasts 0.6 s. If the close *were* a destroy but macOS redirected focus
>600 ms later, the guard would have expired. Less likely than H1 here (no
destroy evidence at all), but the 0.6 s window is independently fragile and
worth addressing.

### H3 — the quick terminal is classified as an unmanaged overlay

The recent commit `d2827df` ("Implement focus-follows-mouse suppression for
unmanaged overlay") suggests dropdown/overlay windows may be unmanaged. If the
quick terminal is unmanaged, it never becomes `confirmedManagedFocusToken`, so
`shouldRecoverFocus` (`token == confirmedManagedFocusToken`) is false even on
destroy. Verify by checking the quick terminal's disposition
(`WindowDecisionEvaluation.decision.disposition`) and whether it ever appears as
`confirmedManagedFocusToken`. In this capture `897:5632` *is* managed
(`mode=tiling`, admitted via `window_admitted`), so H3 is unlikely for this
window — but the classification is worth confirming for the real close path.

---

## Reproduction steps (for a fresh capture)

1. Single monitor. Workspace 1 with Slack (or any app) focused.
2. Open a Ghostty quick terminal (toggle hotkey). Confirm it is admitted to a
   workspace (watch `## Tracing logs` for `window_admitted token=897:…`).
3. Switch to workspace 2 (so the active workspace is not workspace 1).
4. Toggle the quick terminal closed. Start runtime trace capture just before.
5. Stop capture. Check:
   - Did `windowRemoval` increment? (Establishes destroy vs hide.)
   - Is there a `focus_lease owner=.windowCloseFocusRecovery` /
     `window_close_focus_recovery` in the reconcile trace? (Establishes whether
     the recovery armed.)
   - Which `managed_focus_confirmed` / `focus_lease_changed owner=native_app_switch`
     record follows the close, and does its `workspace=` differ from the
     pre-close active workspace?

---

## Fix direction

### Primary (H1): arm recovery on focus loss, not only on destroy

The trigger must cover "managed window lost focus / was ordered out without
being destroyed". Options:

- **A. Focus-out driven recovery.** When a managed window that is the
  `confirmedManagedFocusToken` loses keyboard focus to a non-managed successor
  (or is ordered out), begin a short `.windowCloseFocusRecovery`-style lease on
  its workspace, mirroring `beginWindowCloseFocusRecovery` (`:1210`) but keyed
  off the AX focus-out / `focusedWindowChanged` signal rather than
  `handleRemoved`. This requires a reliable "focus left this managed window"
  signal — the same `activation_source_observed pid=… source=focusedWindowChanged`
  stream already visible in `## Niri create focus trace`.
- **B. Broaden the existing suppression's scope.** Decouple
  `shouldSuppressObservedActivationDuringWindowCloseRecovery` (`:1249`) and the
  `:1538` early-return from destruction: also arm them when a managed window
  transitions to hidden (`hidden_state_changed … phase=hidden`) while it was the
  confirmed focus. This reuses the existing reconcile events and avoids a new
  signal source.

Prefer B first (reuses existing plumbing); fall back to A if the hide signal is
unreliable.

### Secondary: cover cross-app redirection

Even with the lease armed via (A)/(B), the same-app guard
(`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`, `:1264`)
won't catch a Ghostty → Slack jump. The `:1538` `unrelatedNoRequest` early-return
*will* catch it while the lease is active — so the primary fix mostly subsumes
this — but verify that the post-close activation is classified
`unrelatedNoRequest` (not `matchesActiveRequest`). If an app-switch leaves a
*pending* managed request, `:1543` continues it and the early-return is bypassed.

### Tertiary: revisit the 0.6 s duration

`windowCloseFocusRecoveryDuration` (`:296`) is tight. Either lengthen it for the
hide-driven case (app re-activation can lag) or make the hide-driven lease
end only when focus settles on a managed window on the recovery workspace,
rather than on a fixed timer.

### Regression test

Add a test in `Tests/NehirTests/AXEventHandlerTests.swift` (near the
`windowCloseFocusRecovery` coverage): a managed window that is the confirmed
focus is **hidden** (not destroyed) while the active workspace is workspace 2;
assert that the subsequent cross-app / same-app activation does not move
confirmed focus off workspace 2 and does not trigger a workspace transition.
This would fail today and pass after (A)/(B).

---

## Later regression evidence — recovery armed but expired before successor activation

A later close repro showed that the recovery lease can arm correctly but still
miss the real native successor activation because the activation arrives several
seconds later. The relevant timeline was:

```text
21:59:56 event=focus_lease_changed owner=window_close_focus_recovery
         plan=focus=focused=WindowToken(pid: 897, windowId: 6691),pending=nil,lease=window_close_focus_recovery
21:59:56 event=window_removed token=WindowToken(pid: 897, windowId: 6691)
         workspace=A7A0D5D7-BE3A-4B65-8613-04D1B5F040A0
         plan=phase=destroyed focus=focused=nil,pending=nil,lease=window_close_focus_recovery
21:59:59 event=managed_focus_requested token=WindowToken(pid: 897, windowId: 6493)
         workspace=741420DA-78FC-4051-9F6A-AD13033E062C
         plan=focus=focused=nil,pending=WindowToken(pid: 897, windowId: 6493)
21:59:59 event=managed_focus_confirmed token=WindowToken(pid: 897, windowId: 6493)
         workspace=741420DA-78FC-4051-9F6A-AD13033E062C
```

The active workspace at close time was `A7A0D5D7-BE3A-4B65-8613-04D1B5F040A0`;
the successor activation was on `741420DA-78FC-4051-9F6A-AD13033E062C`. The old
lease duration was 0.6 s, so by the time the 3 s delayed activation arrived,
`shouldSuppressObservedActivationDuringWindowCloseRecovery` had no active
recovery context to consult.

Follow-up fix:

- Extend `windowCloseFocusRecoveryDuration` from 0.6 s to 4.0 s.
- Record the same fresh app-event workspace on focused-window loss and
  untracked auxiliary destroy so quick-terminal hides/auxiliary destroys have a
  workspace anchor even when no tracked managed window is destroyed.

Existing and new regression coverage:

- `focusedWindowLossSuppressesUnrelatedInactiveWorkspaceActivation`
- `untrackedSamePidDestroySuppressesUnrelatedInactiveWorkspaceActivation`
- `focusedUntrackedStandardWindowAdmissionPrefersRecentAppEventWorkspaceOverStaleSamePidWorkspace`


---

## Revert note (2026-06-16) — long lease made the scroll common, not rare

The `windowCloseFocusRecoveryDuration` change from 0.6 s to 4.0 s, plus arming
the recovery lease on every `AXFocusedWindowChanged window=nil`, was reverted.
A fresh capture of a quick-terminal **hide** showed the viewport scrolling to
the existing Ghostty column far more often than before:

```text
managed_focus_confirmed token=WindowToken(pid: 897, windowId: 6712)
  workspace=5A1CF56C-…
reason=ax_focus_confirm_reveal_result token=WindowToken(pid: 897, windowId: 6712)
  columnIndex=3 visibility=parked(Nehir.AxisHideEdge.maximum) didReveal=true
  currentViewStart=0.0 → targetViewStart=2932.6 animating=true
```

When the quick terminal hides, macOS re-focuses the existing managed Ghostty
window `897:6712`, which is parked offscreen (column 3). The focus-confirm
reveal then animates the viewport to it. The 4.0 s / broad-arming change made
that re-focus reach the reveal path routinely.

The 0.6 s lease and the original confirmed-same-pid-only arming are restored.
The remaining open issue is that focus-confirm on a parked offscreen column
still reveals/scrolls; the candidate fix is to preserve the active viewport for
a focus-confirm that lands while a recovery context is active, or to not reveal
a `parked` column on a non-user-initiated focus change.

---

## Resolution architecture (2026-06-16)

The final fix treats quick-terminal close/hide as an **ordering problem** rather
than as a Ghostty-specific behavior. The observable close signal can arrive via
several channels and not always before macOS chooses a successor focus target:

1. tracked managed-window destroy;
2. untracked same-pid auxiliary destroy, such as an AX element with `window=101`;
3. the currently confirmed managed window becoming hidden because its workspace
   is inactive;
4. `AXFocusedWindowChanged window=nil` for the app that owned the confirmed
   managed focus.

The robust architecture is:

- **Keep the short close-recovery lease.** `windowCloseFocusRecoveryDuration`
  remains 0.6 s. A previous 4.0 s lease made ordinary app-internal refocuses
  much more likely to scroll to parked columns.
- **Arm recovery from multiple close-shaped signals.** Recovery can begin from a
  tracked destroy, an auxiliary same-pid destroy, focused-window loss, or the
  confirmed managed window becoming hidden while its workspace is active.
- **Suppress only while the recovery context is active.**
  `shouldSuppressObservedActivationDuringWindowCloseRecovery` drops unrelated
  activations away from the recovery workspace, including unrelated same-workspace
  native activations for a different token than the current focus.
- **Preserve the viewport on duplicate focus confirmation.** If AX confirms an
  already-confirmed token, `handleManagedAppActivation` marks the activation as
  `preserveActiveViewport`, so repeated `focusedWindowChanged` events do not
  reveal parked columns.
- **Defer ambiguous inactive native activations before recovery.** In the last
  failing capture, macOS reported `workspaceDidActivateApplication` for an older
  managed window on an inactive workspace before the quick-terminal destroy/hide
  signal arrived. `shouldDeferInactiveNativeActivationBeforeCloseRecovery`
  postpones exactly that shape briefly. If a close signal arms recovery during
  the delay, the retry is suppressed by the normal recovery path. If no recovery
  signal arrives, the retry is allowed so genuine native app switches still work.

This keeps the policy generic: no bundle ID, app name, or Ghostty-specific rule
is involved. Ghostty only supplied the repro because dropdown terminals commonly
hide, destroy helper AX elements, or lose focused AX state before the managed
window itself is removed.

### Validation evidence

A later live validation run repeatedly opened new windows and closed the quick
terminal without reproducing the workspace jump. The relevant trace facts are
self-contained:

```text
07:16:51 event=focus_lease_changed owner=window_close_focus_recovery
         reason=window_close_focus_recovery
         plan=focus=focused=WindowToken(pid: 897, windowId: 7585),pending=nil,lease=window_close_focus_recovery
07:16:51 event=window_removed token=WindowToken(pid: 897, windowId: 7585)
         workspace=7FBFE458-6A8C-47E2-B88A-638130428B53
         plan=phase=destroyed focus=focused=nil,pending=nil,lease=window_close_focus_recovery
```

User-visible result from that run: no quick-terminal close jump reproduced, and
new windows were created on the expected workspace.
