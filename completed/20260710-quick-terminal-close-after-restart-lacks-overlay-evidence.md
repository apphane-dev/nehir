# Quick-terminal close right after a Nehir restart reveals the parked Ghostty column: overlay evidence is in-memory only

Discovery (2026-07-10). Verified against branch `fix/quick-terminal-stale-nonmanaged-focus` at `5d34d706` (one commit ahead of `main` `d3ef41ee`); every guard cited here is identical on `main`.

**Status: LANDED (2026-07-10).** Shipped on `main` in commit `efc64f1a`
("Arm overlay close-churn protection from window-rule classification").
Changeset: `.changeset/20260710224959-arm-quick-terminal-close-churn-protection-from-w.md`
(patch).

## What actually landed (vs. the discovery below)

Slice 1 from "Fix direction" shipped, with the arming call placed directly in
`WMController.evaluateWindowDisposition` (unconditional on trace verbosity) —
not through the trace-event sink. A first implementation attempt piggybacked
`overlayCapablePids` insertion on `recordNiriCreateFocusTrace`'s
`.windowDecision` event; that was reworked before landing because it depended
on an unrelated diagnostics-verbosity heuristic
(`RuntimeDiagnosticsCoordinator.shouldTraceWindowDecision`) and did not
reliably cover all three overlay rules (`cleanShotRecordingOverlay` has
`disposition: .floating`, not `.unmanaged`; `systemTextInputPanel` has no
windowServer-level guard) — both only happened to get traced via that
heuristic's separate `level != 0` fallback, not by design.

Two refinements landed beyond that rework:

- **Manual-override ordering fix.** `WMController.evaluateWindowDisposition`
  arms overlay capability from `baseDecision.source` — the rule engine's
  decision *before* a manual layout override can replace `decision.source` —
  so a window a user has manually forced to tile still gets recorded as
  overlay-capable if the underlying rule classified it as one. Without this,
  a manual override on an overlay-capable window (e.g. forcing a Ghostty quick
  terminal to tile) would have silently dropped its arming.
- **Regression coverage.** `Tests/NehirTests/AXEventHandlerTests.swift` gained
  `overlayDecisionArmsPidBeforeManualOverrideWithoutTraceContext`, exercising
  exactly that manual-override-plus-untraced-decision case end to end via
  `evaluateWindowDisposition`.

The distinct NF-1 discovery this one is adjacent to —
[`20260710-ghostty-quick-terminal-arms-stale-nonmanaged-focus.md`](20260710-ghostty-quick-terminal-arms-stale-nonmanaged-focus.md)
— landed separately on `main` as `31c8b851`, one commit before this fix.

## Summary

Closing the Ghostty quick terminal made the viewport scroll to Ghostty's parked
managed column — the exact symptom the CR-1 fix in `d3ef41ee` addressed. The
capture proves this is **not** a regression of that fix, and **not** a regression
of the stale-non-managed-focus clear added in `5d34d706` (whose code path never
executed in the capture: no `overlay_close_churn_*` and no
`clearedStaleNonManagedFocus` entries exist).

The actual gap: every piece of evidence the close/overlay protections consult —
`overlayCapablePids`, `recentNonManagedFocusByPid`,
`recentSameAppWindowCloseByPid`, and the live overlay-visibility scan — is
in-memory state populated only when the *running* Nehir instance observes the
quick terminal being summoned or sees it still visible. When Nehir starts (or
restarts) **while the quick terminal is already open**, none of that state
exists. The first quick-terminal close after startup therefore evaluates with
every evidence field false, macOS's refocus of Ghostty's managed window passes
the gate as a genuine same-app focus switch, close recovery arms off the
quick-terminal destroy, redirects to the `nearest` same-pid managed window, and
confirms + reveals it — scrolling the viewport to the parked column.

The bitter detail: Nehir's startup full refresh had *already identified* the
open quick-terminal window as `ghosttyQuickTerminalOverlay / unmanaged` seconds
earlier. The knowledge existed; it just never reaches the evidence sets the
guards consult.

The same capture also shows the protections working correctly two seconds
later: a second summon/close cycle (which the running instance observed) was
suppressed with no viewport movement.

## Exact steps to reproduce

Topology: one monitor, one active workspace holding parked (hidden-left) managed
Ghostty columns among others. Ghostty quick terminal enabled.

1. Summon the Ghostty quick terminal and leave it open.
2. Start (or restart) Nehir while the quick terminal is up.
3. After Nehir finishes startup, close/dismiss the quick terminal.
4. The viewport scrolls to Ghostty's parked managed column (close recovery
   confirms + reveals it). On the *next* summon/close cycle the suppression
   works and nothing moves.

## Related plans and discoveries

- Cross-link cluster: [`CR-1` in `20260708-cross-discovery-relevance-clusters.md`](../discovery/20260708-cross-discovery-relevance-clusters.md#cr-1--close-recovery-and-same-app-overlay-focus-churn).
  This was a CR-1 boundary condition, not a reopen of the fixed oscillation or the
  `d3ef41ee` quick-terminal close reveal: the guards behaved as designed; their
  evidence inputs were empty after a restart.
- [`20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md`](20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md)
  — the `d3ef41ee` fix whose `overlayCapablePids` memory this discovery showed was
  populated too lazily to cover the cold-start case.
- [`20260710-ghostty-quick-terminal-arms-stale-nonmanaged-focus.md`](20260710-ghostty-quick-terminal-arms-stale-nonmanaged-focus.md)
  — the adjacent NF-1 discovery from the same day. Its fix (clear stale
  non-managed focus at the churn-suppression point) landed as `31c8b851` and is
  unaffected by and did not cause this behavior; in this capture the suppression branch never
  ran, so the clear never ran either.
- [`../discovery/20260709-window-close-successor-app-activation-reveals-far-parked-column.md`](../discovery/20260709-window-close-successor-app-activation-reveals-far-parked-column.md)
  — different root cause (cross-app successor selection) but the same user-facing
  symptom family: a close reveals a far parked column.

## Inline runtime evidence

Capture: 2026-07-10 19:28:45–19:28:56 (10.957 s), build `nehir v5d34d7`, one
monitor (displayId 1). Nehir starts at 19:28:45; the active workspace
`9993B402-3078-4546-A23F-BAE97E4741D2` has 8 columns; Ghostty (pid 82494) owns
parked managed windows `34648` and `29687` (both `hidden=left`), and the quick
terminal is window `5915`.

**The quick terminal predates this Nehir instance.** The first AX enumeration at
startup already contains it, and the startup full refresh already classifies it:

```text
19:28:46 ax_windows_query pid=82494 newContext=true count=3 windowIds=[5915, 34648, 29687]

window_decision token=WindowToken(pid: 82494, windowId: 5915) context=full_refresh
  existingMode=nil disposition=unmanaged source=builtInRule(ghosttyQuickTerminalOverlay)
  outcome=ignored bundleId=com.mitchellh.ghostty
```

No `non_managed_fallback_entered pid=82494` and no `non_managed_focus_changed`
event exists before 19:28:50 — this instance never observed the quick terminal
*taking* focus, so no recent-non-managed-focus evidence was ever recorded.

**First close at 19:28:49 — the gate evaluates with zero evidence.** The quick
terminal is destroyed; macOS refocuses Ghostty's parked managed window `34648`;
the close-recovery activation gate finds nothing to suppress on:

```text
19:28:49 ax=AXFocusedWindowChanged pid=82494 window=nil
19:28:49 ax=AXUIElementDestroyed pid=82494 window=5915
19:28:49 ax_windows_query pid=82494 newContext=false count=2 windowIds=[29687, 34648]

19:28:49 reason=close_recovery_activation_gate token=WindowToken(pid: 82494, windowId: 34648)
  isWorkspaceActive=true source=focusedWindowChanged origin=external
  requestDisposition=unrelatedNoRequest activeRecoveryWorkspace=nil
  recentSameAppClose=false recentNonManagedFocus=false
  overlayVisible=false sameAppCloseOrOverlayEvidence=false
  currentTarget=WindowToken(pid: 53999, ...) decision=evaluate
```

`overlayVisible=false` because the overlay-visibility scan runs *after* the
destroy — window `5915` is already gone from the WindowServer list it checks.

**With the gate passed, the activation confirms and close recovery owns the
reveal.** The `5915` destroy (same pid as the now-confirmed focus) arms
`auxiliary_destroy` recovery, which redirects to the nearest same-pid column and
confirms it:

```text
#39 19:28:49 event=managed_focus_confirmed token=WindowToken(pid: 82494, windowId: 34648)
#40 19:28:49 event=focus_lease_changed owner=window_close_focus_recovery

19:28:49 reason=close_recovery_begin caller=auxiliary_destroy suppressedPid=82494
  preservedToken=nil columns=8 activeColumnIndex=7
  currentOffset=-3009.2 targetOffset=-1023.0 currentViewStart=4096.0 targetViewStart=6096.0
19:28:49 reason=close_recovery_stable_target observedToken=WindowToken(pid: 82494, windowId: 34648)
  targetToken=WindowToken(pid: 82494, windowId: 29687) reason=nearest

#45 19:28:49 event=managed_focus_confirmed token=WindowToken(pid: 82494, windowId: 29687)
#41 19:28:49 event=hidden_state_changed token=WindowToken(pid: 82494, windowId: 29687) hidden=false
```

`hidden=false` on `29687` plus the viewport moving toward
`targetViewStart=6096.0` is the user-visible scroll to the parked Ghostty
column.

**Two seconds later the same protections work.** The user summons the quick
terminal again at 19:28:50 — this time the running instance observes it
(`window_decision ... context=focused_admission` → `non_managed_fallback_entered
pid=82494`, and `non_managed_focus_changed active=true preserve=true` at
19:28:50). On the 19:28:51 close, the refocus of the already-confirmed `29687`
is suppressed with no viewport movement:

```text
19:28:51 ax=AXUIElementDestroyed pid=82494 window=5915
19:28:51 reason=overlay_refocus_already_confirmed_suppressed
  token=WindowToken(pid: 82494, windowId: 29687) reason=already_confirmed_overlay_refocus
```

Focus then returns to the managed Helium window normally at 19:28:54
(`managed_focus_confirmed token=WindowToken(pid: 7805, windowId: 36944)`), which
also clears non-managed focus — no stale-flag deadlock occurred in this session.

**Why this is not a `5d34d706` regression:** the capture contains no
`overlay_close_churn_deferred`, no `overlay_close_churn_suppressed`, and no
`clearedStaleNonManagedFocus` field anywhere. The stale-focus clear added in
`5d34d706` lives exclusively inside the churn-suppression branch, which never
executed.

## Source-backed mechanism

All of the evidence the quick-terminal close protections rely on is in-memory
and observation-driven:

1. **`overlayCapablePids` is populated only by the live overlay-visibility
   scan.** The set is declared at
   `Sources/Nehir/Core/Controller/AXEventHandler.swift:889`; the *only*
   insertion is `AXEventHandler.swift:2869` inside
   `isKnownSamePidOverlayWindow(_:pid:)` (2849-2871), which is reached from
   `hasVisibleSamePidOverlayWindow` (2826-2846) — a scan over currently
   *visible* WindowServer windows. It is cleared on service resets
   (`AXEventHandler.swift:952`, `1109`) and on app termination (`7046`). A
   window-rule decision classifying a window as `ghosttyQuickTerminalOverlay`
   (e.g. the startup `full_refresh` decision above) never inserts into it.
   Consequence: after a restart, both same-app churn suppressors —
   `shouldSuppressSameAppAlreadyConfirmedOverlayRefocus`
   (`AXEventHandler.swift:3027-3053`, membership check at 3036) and
   `shouldSuppressOrDeferSameAppOverlayCloseChurn`
   (`AXEventHandler.swift:3069-3126`, membership check at 3077) — are inert for
   the pid until the overlay is *seen visible* during an evidence check, and on
   a close the overlay is already gone by the time the scan runs
   (`overlayVisible=false` in the capture).
2. **Recent-non-managed-focus evidence requires observing the summon.**
   `recordRecentNonManagedFocus` (`AXEventHandler.swift:6135-6138`) is called
   only from `recordNonManagedFallbackEntered` (`6152-6162`), i.e. when the
   running instance handles the quick terminal's focus event. An instance that
   booted underneath an already-open quick terminal has
   `recentNonManagedFocusByPid` empty — hence
   `recentNonManagedFocus=false` at the gate.
3. **Same-app-close evidence arrives with/after the destroy, not before the
   refocus.** `recordRecentSameAppWindowClose` (`AXEventHandler.swift:6102-6104`)
   had not fired when the first gate evaluation ran
   (`recentSameAppClose=false`), matching the known ordering the churn
   deferral exists for — but the deferral itself is gated on
   `overlayCapablePids` (point 1), so it never got the chance to defer.
4. **With all evidence empty, the activation is a legitimate focus switch.**
   The gate proceeds (`decision=evaluate`), `handleManagedAppActivation`
   confirms Ghostty `34648`; the quick-terminal destroy then arms
   `armWindowCloseFocusRecoveryForFocusedAppEvent`
   (`AXEventHandler.swift:2326-2335`, `reason: "auxiliary_destroy"`) because the
   confirmed focus pid now equals the destroyed window's pid, and the recovery's
   stable-target redirect picks the nearest same-pid column and confirms it —
   the reveal of `29687`.

## Fix direction

Feed the knowledge Nehir already has into the evidence sets, so the first
post-restart close is protected:

1. **Populate `overlayCapablePids` from window-rule decisions.** Whenever a
   window decision resolves to one of the overlay built-in rules
   (`ghosttyQuickTerminalOverlay`, `cleanShotRecordingOverlay`,
   `systemTextInputPanel` — the same names special-cased at
   `AXEventHandler.swift:2864-2867`), insert the pid. The startup `full_refresh`
   decision at 19:28:46 would then have armed both churn suppressors before the
   19:28:49 close. Cheapest, most targeted slice.
2. Optionally, when startup enumeration sees a visible non-zero-level window for
   a pid whose decision is unmanaged-overlay, also record it as recent overlay
   evidence (or a dedicated "overlay currently open" latch cleared on destroy),
   covering guards that consult recency rather than capability.
3. Keep the existing scan-based insertion as a fallback; do not remove the
   termination/reset cleanup.

Constraint: this only widens *when* the existing suppressors are armed; it must
not change what they suppress. The `5d34d706` stale-focus clear inside the
suppression branch then also covers the cold-start close, clearing any
non-managed focus the pre-restart quick terminal may have left behind.
