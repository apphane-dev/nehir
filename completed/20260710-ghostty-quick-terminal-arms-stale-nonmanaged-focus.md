# Ghostty quick terminal arms stale non-managed focus; close-churn suppression swallows the only recovery signal

**Status: LANDED (2026-07-10).** Shipped on `main` in commit `31c8b851`
("Clear stale non-managed focus after quick terminal dismissal"). Changeset:
`.changeset/20260710222654-clear-stale-non-managed-focus-after-quick-termin.md`
(patch). Validated: `mise run check` (build + lint + test, 1435 tests, 116
suites) green on the landed diff, and confirmed against a real repro by the
reporting user before landing.

Discovery (2026-07-10). Verified against the main Nehir source tree at `d3ef41ee` (the same build that produced the capture, `nehir vd3ef41`).

## What actually landed (vs. the discovery below)

The discovery below proposed three fix slices (see "Working hypothesis / fix
direction"). Slice 1 shipped, with two refinements made during implementation:

- `WMController.handleOwnedFocusSuppressingWindowClosed()` and the new
  `overlay_close_churn_suppressed` call site both now go through a shared
  `WMController.clearStaleNonManagedFocusAfterOverlaySuppressed(refreshFocusFollowsMouse:)`
  — `leaveNonManagedFocus(preserveFocusedToken: true)` plus mouse-suppress and
  border refresh, **no** `confirmManagedFocus`, **no** workspace
  activation/reveal, matching the "clear without the viewport side effects"
  constraint from the discovery.
- The shared helper re-checks `!hasVisibleOwnedWindow` itself (not just at the
  original owned-window call site), and the churn-suppression call site passes
  `refreshFocusFollowsMouse: recoveryArmed` rather than unconditionally
  refreshing FFM — a tighter condition than the discovery's slice 1 sketch.
- `AXEventHandler.shouldSuppressOrDeferSameAppOverlayCloseChurn`'s
  `close_evidence_present` branch now records `clearedStaleNonManagedFocus=…`
  in the `overlay_close_churn_suppressed` runtime viewport trace, exactly as
  proposed.

Slices 2 (tie the armed state to overlay liveness) and 3 (narrow the resolver
decline on triple-agreement) were **not** needed — clearing at the suppression
point was sufficient and is the smaller, more targeted change. The adjacent
cold-start boundary condition this discovery's capture did not cover (Nehir
restarting while the quick terminal is already open) is tracked separately in
[`../discovery/20260710-quick-terminal-close-after-restart-lacks-overlay-evidence.md`](../discovery/20260710-quick-terminal-close-after-restart-lacks-overlay-evidence.md).

## Summary

This is the NF-1 arming path the earlier command-target discoveries could not see. A
20-second capture on a single built-in display contains a complete, self-contained
arm → stuck → re-arm → still-stuck cycle:

1. **Arm.** Summoning the Ghostty quick terminal focuses an unmanaged overlay window
   (`builtInRule(ghosttyQuickTerminalOverlay)`, `AXFloatingWindow`, `wsLevel=101`).
   The AX activation handler enters non-managed focus with
   `preserveFocusedToken=true`, keeping the previously confirmed managed window
   (Helium `7805:36944`) as `focusedToken`.
2. **No clear on dismiss.** When the quick terminal hides or is destroyed, the only
   follow-up activation Nehir observes is macOS refocusing **Ghostty's own parked
   managed window** (`82494:35053`, hidden off-screen left). The overlay-close-churn
   gate — added deliberately so quick-terminal close does not scroll/reveal the
   parked column — first defers that activation (`await_close_recovery_signal`) and
   then suppresses it (`close_evidence_present`). Suppressing it also discards the
   only `confirmManagedFocus(...)` opportunity, and `confirmManagedFocus` is the sole
   AX-driven path that resets `isNonManagedFocusActive`. The previously focused
   Helium window never emits any AX/workspace event (its focused window never
   changed and it was never deactivated), so nothing else can clear the flag.
3. **Self-locking stuck state.** `isNonManagedFocusActive` stays `true` indefinitely
   while `confirmedManagedFocusToken`, `layoutSelectionToken`, and the frontmost
   token **all agree** on the same tracked managed window. Every generic command
   resolves to `command_target.resolve.decline reason=nonManagedFocus.frontmostTracked`,
   trackpad scroll selection is suppressed (`suppressedNonManagedFocus`), and
   focus-follows-mouse is skipped — the stale flag disables the very interactions
   that would confirm managed focus and clear it.

Unlike the workspace-7 capture (where the resolver declined with `confirmedToken=nil`
and recovered within seconds), this capture shows the decline firing **with a live
confirmed focus and layout selection**, and the state persisting from before the
capture started until after it ended, across a fresh quick-terminal summon *and* a
full quick-terminal window destroy.

## Exact steps to reproduce the stuck state

Topology: one monitor. Workspace 4 (`EFA94F5C…`) holds a managed tiled Helium window
`7805:36944` (visible, column 5 of 6) plus parked columns including Ghostty
`82494:35053` (hidden left). Ghostty also owns managed tiled windows on another
workspace, and has its quick terminal enabled.

1. Focus the managed Helium window normally (it becomes
   `confirmedManagedFocusToken` and the niri layout selection).
2. Summon the Ghostty quick terminal with its global hotkey. Nehir sees Ghostty's
   `AXFocusedWindowChanged` for the overlay window, rules it unmanaged
   (`ghosttyQuickTerminalOverlay`), and enters non-managed focus with
   `preserve=true`.
3. Dismiss the quick terminal (toggle hotkey; fully closing it behaves the same).
   macOS refocuses Ghostty's parked managed window; the overlay-close-churn gate
   defers then suppresses that activation. No managed focus confirmation ever runs.
4. Try to assign/move the focused window to another workspace (hotkey or UI). The
   command silently no-ops. Repeat as often as you like — the state does not decay:
   there is no TTL, no watchdog, and every suppressed interaction path keeps it armed.

Recovery requires an action that still produces a managed focus confirmation:

- a `focus next/prev window` command (it resolves its target from the workspace
  focus token, not `managedCommandTarget()`, and the resulting AX focus event
  confirms managed focus and clears the flag) — the capture's history shows exactly
  this recovering an earlier same-session episode (pid 69079 overlay); or
- activating a *different* app's managed window (click/⌘-tab), which fires an AX
  activation. Clicking the already-focused window does nothing — no AX event fires.

## Related plans and discoveries

- Cross-link cluster: [`NF-1` in `20260708-cross-discovery-relevance-clusters.md`](../discovery/20260708-cross-discovery-relevance-clusters.md#nf-1--stale-non-managed-focus-blocks-admission-confirmation-and-command-targets).
  This discovery supplied the missing **arming mechanism** for the cluster: a
  concrete overlay (quick terminal) plus the CR-1 close-churn suppression that
  swallowed the clearing confirmation.
- [`../discovery/20260708-assign-to-workspace-7-nonmanaged-command-target-decline.md`](../discovery/20260708-assign-to-workspace-7-nonmanaged-command-target-decline.md)
  — same resolver decline, but transient (recovered in ~3 s) and with
  `confirmedToken=nil`. Here the decline fired with confirmed focus and layout
  selection present, and never recovered on its own.
- [`../discovery/20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md`](../discovery/20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md)
  — the broader stuck-state consequences (suppressed scroll selection, targetless
  moves). This discovery added where the staleness comes from.
- [`20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md`](20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md)
  — the CR-1 fix (`d3ef41ee`) whose `overlayCapablePids` memory and close-churn
  suppression correctly keep the viewport still on quick-terminal close. This
  discovery documented its NF-1 side effect: the suppressed activation was also
  the only signal that would have cleared non-managed focus. The landed fix
  above preserves the viewport behavior.
- [`../discovery/20260702-quick-terminal-close-reveals-managed-ghostty-column.md`](../discovery/20260702-quick-terminal-close-reveals-managed-ghostty-column.md)
  and [`20260615-quick-terminal-close-switches-workspace.md`](20260615-quick-terminal-close-switches-workspace.md)
  — earlier quick-terminal close/overlay lineage.
- [`../discovery/20260705-move-focused-window-to-workspace-noop-under-nonmanaged-focus.md`](../discovery/20260705-move-focused-window-to-workspace-noop-under-nonmanaged-focus.md)
  — predecessor of the same silent move-command guard.

## Inline runtime evidence

All quotes are from a 2026-07-10 18:43:10–18:43:30 capture (20.075 s) on
`nehir vd3ef41`, one monitor (`Built-in Retina Display`, displayId 1), 7 workspaces,
11 managed windows.

**The capture starts already stuck.** Non-managed focus is active, yet the focus
layer's own state names a tracked managed window as focused, selected, and visible;
no unmanaged WindowServer window is visible at all:

```text
-- Focus Targets --
interactionWorkspace=EFA94F5C-FF18-45A6-B9C2-ACB9DC6269B5 wmCommandTarget=nil
layoutSelection=WindowToken(pid: 7805, windowId: 36944)
observedManagedFocus=WindowToken(pid: 7805, windowId: 36944)
interactionMonitor=ID(displayId: 1) nonManaged=true
-- Visible Unmanaged WindowServer Windows --
none
```

**Four assignment attempts silently no-op** (18:43:13, :14, :19, :23). Unlike the
workspace-7 capture, `confirmedToken` and `layoutSelectionToken` are populated and
identical to the frontmost tracked token — every signal says "managed window
focused", and the guard still drops the command:

```text
18:43:13 event=command_target.resolve.decline cluster=NF-1 resolver=managedCommandTarget
  reason=nonManagedFocus.frontmostTracked
  frontmostPid=7805 frontmostToken=7805:36944 frontmostTokenTracked=true
  confirmedToken=7805:36944 confirmedWorkspace=EFA94F5C-FF18-45A6-B9C2-ACB9DC6269B5
  preservedManagedFocus=7805:36944
  layoutSelectionToken=7805:36944 layoutSelectionWorkspace=EFA94F5C-FF18-45A6-B9C2-ACB9DC6269B5
  interactionWorkspace=EFA94F5C-FF18-45A6-B9C2-ACB9DC6269B5 interactionMonitor=ID(displayId: 1)
  nonManagedActive=true recentlyLeftNonManagedFocus=false
  stickySourceExceptionConsidered=false stickySourceExceptionAccepted=false
  targetToken=nil targetWorkspace=nil targetSource=nil
```

No `workspace_assigned` event follows any of the four attempts.

**The arming shape, replayed live at 18:43:25.** The user summons the quick terminal
again during the capture. Ghostty's AX observer reports the overlay window `5915`;
the rule engine declares it unmanaged; admission is rejected as an untracked
decision; the non-managed fallback enters with `preserve=true`, keeping Helium as
the (now decorative) focused token:

```text
window_decision token=WindowToken(pid: 82494, windowId: 5915) context=focused_admission
  existingMode=nil disposition=unmanaged source=builtInRule(ghosttyQuickTerminalOverlay)
  outcome=ignored bundleId=com.mitchellh.ghostty axSubrole=AXFloatingWindow
  wsLevel=101 wsFrame=(37.0,-1023.0,1982.0,1062.0)
prepare_create_rejected window=5915 ... context=focused_admission reason=untracked_decision
non_managed_fallback_entered pid=82494 source=focusedWindowChanged

18:43:25 event=non_managed_focus_changed active=true fullscreen=false preserve=true
  preserve_pending=false interaction=ID(displayId: 1)/prev=nil
  plan=focus=focused=WindowToken(pid: 7805, windowId: 36944),pending=nil,non_managed=true
```

The capture's pre-capture history ring contains the identical shape once before
(the same `focused_admission` → `untracked_decision` → `non_managed_fallback_entered
pid=82494` sequence for the same window `5915`), which is the arming that preceded
the failed assignments.

**Dismissal produces no clearing signal.** The quick terminal is destroyed at
18:43:27. Ghostty reports focused-window loss; the only managed activation that
follows is Ghostty's own parked window `35053`, which the overlay-close-churn gate
defers and then suppresses:

```text
18:43:25 ax=AXFocusedWindowChanged pid=82494 window=nil
18:43:27 ax=AXUIElementDestroyed pid=82494 window=5915

18:43:27 reason=close_recovery_activation_gate token=WindowToken(pid: 82494, windowId: 35053)
  source=focusedWindowChanged origin=external currentTarget=WindowToken(pid: 82494, windowId: 5915)
  currentTargetManaged=false currentTargetSamePid=true decision=evaluate
18:43:27 reason=overlay_close_churn_deferred token=WindowToken(pid: 82494, windowId: 35053)
  reason=await_close_recovery_signal
18:43:28 reason=close_recovery_activation_gate token=... origin=retry recentSameAppClose=true
18:43:28 reason=overlay_close_churn_suppressed token=WindowToken(pid: 82494, windowId: 35053)
  origin=retry recentSameAppClose=true recoveryArmed=false reason=close_evidence_present
```

No `activation_source_observed pid=7805`, no `focus_confirmed`, and no
`managed_focus_confirmed` appears anywhere after either quick-terminal episode. The
capture ends at 18:43:30 — three seconds after the overlay window was destroyed —
still stuck:

```text
-- Focus Targets --
... observedManagedFocus=WindowToken(pid: 7805, windowId: 36944) ... nonManaged=true
focus focused=7805:36944 pending=nil scratchpad=nil
interaction current=ID(displayId: 1) previous=nil nonManaged=true
```

**The observed recovery path (earlier episode in the same history ring).** An
earlier overlay episode (`non_managed_fallback_entered pid=69079`) recovered
immediately because the user issued a focus-next command, which still runs under
non-managed focus and whose confirmation clears the flag:

```text
non_managed_fallback_entered pid=69079 source=focusedWindowChanged
pending_focus_started request=257 token=WindowToken(pid: 53999, windowId: 35300)
  workspace=EFA94F5C-FF18-45A6-B9C2-ACB9DC6269B5 reason=focusNextWindow
focus_confirmed token=WindowToken(pid: 53999, windowId: 35300) ... source=focusedWindowChanged
```

After that confirmation, subsequent `mouseScrollSelection` focus requests flow
normally — proving scroll selection works when the flag is clear and is what the
stuck state suppresses.

## Source-backed mechanism

### 1. Arming: quick-terminal focus enters non-managed focus with the managed token preserved

- `Sources/Nehir/Core/Rules/WindowRuleEngine.swift:830-847` —
  `ghosttyQuickTerminalOverlayDecision` marks any Ghostty window with
  `windowServer.level != 0` as `.unmanaged` (`builtInRule(ghosttyQuickTerminalOverlay)`).
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3412` — `handleAppActivation`
  processes the `focusedWindowChanged` for Ghostty; the focused overlay resolves to
  an untracked decision (`prepare_create_rejected reason=untracked_decision`).
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:3922-3935` — the fallback:
  `shouldPreserveManagedFocus = source == .focusedWindowChanged &&
  focusedTokenBeforeFallback != nil`, then
  `enterNonManagedFocus(appFullscreen:…, preserveFocusedToken: shouldPreserveManagedFocus)`
  and `recordNonManagedFallbackEntered(pid:source:)`. This is exactly the
  `non_managed_focus_changed active=true preserve=true` + `non_managed_fallback_entered`
  pair in the capture, with `focusedToken` kept at Helium.
- `Sources/Nehir/Core/Reconcile/StateReducer.swift:346-363` — the reducer for
  `.nonManagedFocusChanged` keeps `focusedToken` when `preserveFocusedToken=true`
  and sets `isNonManagedFocusActive = true`.

### 2. Why dismissal never clears the flag

The only AX-driven reset of `isNonManagedFocusActive` is a managed focus
confirmation:

- `Sources/Nehir/Core/Reconcile/StateReducer.swift:317-330` —
  `.managedFocusConfirmed` sets `isNonManagedFocusActive = false` (line 327); the
  equivalent direct mutation is `WorkspaceManager.applyConfirmedManagedFocus`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2003-2005`).
- The only production caller is `handleManagedAppActivation` →
  `confirmManagedFocus` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:4184-4192`),
  which requires an observed managed activation to reach it.

After quick-terminal dismissal, no such activation survives:

- **Ghostty's own successor activation is deliberately dropped.**
  `shouldSuppressOrDeferSameAppOverlayCloseChurn`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:3069-3126`) defers the first
  external arrival of an off-screen same-pid managed activation for an
  overlay-capable pid (`overlay_close_churn_deferred`, lines 3103-3116) and
  suppresses the retry once close evidence exists
  (`overlay_close_churn_suppressed reason=close_evidence_present`, lines
  3085-3101). This gate shipped with the CR-1 fix in `d3ef41ee` and is correct for
  its purpose (keep the viewport still) — but the suppressed activation was also
  the only `confirmManagedFocus` candidate.
- **The preserved window emits nothing.** The still-visible Helium window never
  changed its app's focused window and the app was never deactivated, so macOS
  fires no `AXFocusedWindowChanged`/`didActivateApplication` for it. (The sibling
  suppressor `shouldSuppressSameAppAlreadyConfirmedOverlayRefocus`,
  `AXEventHandler.swift:3027-3053`, would drop a same-pid re-focus of the
  already-confirmed token if one did arrive for an overlay-capable pid.)
- **The generic leave path only serves Nehir's own windows.**
  `handleOwnedFocusSuppressingWindowClosed`
  (`Sources/Nehir/Core/Controller/WMController.swift:3996-4005`) is the sole
  `leaveNonManagedFocus` caller, and it is gated on the `ownedWindowRegistry`
  (Nehir-owned UI windows), so a third-party overlay's disappearance never triggers
  it. There is no TTL or liveness check tied to the overlay that armed the state.

### 3. Why the stuck state locks out its own recovery

- `Sources/Nehir/Core/Controller/WMController.swift:1954-1965` — under
  `isNonManagedFocusActive`, a tracked frontmost token is an unconditional decline
  (`nonManagedFocus.frontmostTracked`), **without comparing it to
  `preservedManagedFocus`**. The capture shows all three tokens equal; the guard
  drops the command anyway.
- `Sources/Nehir/Core/Controller/WMController.swift:1966-1992` — the probe/self-heal
  branch only runs for an *untracked* frontmost token, and even then refuses a
  target equal to `preservedManagedFocus` (line 1975) unless it has a sticky window
  source. The design treats "the preserved token is frontmost again" as
  insufficient proof the overlay went away — which is exactly the state this bug
  produces permanently.
- `Sources/Nehir/Core/Controller/MouseEventHandler.swift:2183-2195, 2202-2203` —
  trackpad scroll selection refuses to call `focusWindow(...)` while the flag is
  active (`suppressedNonManagedFocus`), so the natural "scroll to reselect" gesture
  cannot generate the clearing confirmation.
- `Sources/Nehir/Core/Controller/MouseEventHandler.swift:1295-1297` —
  focus-follows-mouse is likewise skipped (`ffm.skip reason=nonManaged`).
- Escape hatch that still works: `focusNextWindow`
  (`Sources/Nehir/Core/Controller/WMController.swift:3876-3892`) resolves its
  target via `resolveAndSetWorkspaceFocusToken` — not `managedCommandTarget()` —
  and issues a real focus request whose confirmation clears the flag (observed in
  the pid-69079 episode above).

## Working hypothesis / fix direction

The two guard families are individually correct and jointly deadlock:

- NF-1's resolver guard assumes non-managed focus is transient — some later event
  will confirm managed focus. CR-1's close-churn suppression removes that later
  event for exactly the overlay class (quick terminals) most likely to arm the flag.

Plausible slices, smallest first:

1. **Clear (or schedule clearing of) non-managed focus when the churn is
   suppressed.** At the `close_evidence_present` suppression point
   (`AXEventHandler.swift:3085-3101`), Nehir has positive evidence the overlay is
   gone (recent same-app close / destroy of the overlay window) and a preserved
   confirmed managed token. Re-confirming the preserved token *without* the
   workspace-activation/reveal side effects (`confirmManagedFocus` with
   `activateWorkspaceOnMonitor: false`, or a dedicated `leaveNonManagedFocus`
   call preserving the token) would clear the flag while keeping the viewport
   still — the exact split the CR-1 fix needs to preserve.
2. **Tie the armed state to the overlay's liveness.** The non-managed fallback
   knows the arming pid; `AXUIElementDestroyed` for the overlay window (observed at
   18:43:27) or the pid's loss of any visible non-zero-level window could drop the
   flag when no other unmanaged surface is visible ("Visible Unmanaged WindowServer
   Windows: none" was already true at capture start).
3. **Narrow the resolver decline.** When `frontmostToken == preservedManagedFocus ==
   layoutSelectionToken` and no visible unmanaged WindowServer window exists,
   `managedCommandTarget()` declining protects nothing — there is no overlay left to
   protect. Accepting the preserved token in that triple-agreement case is a
   targeted escape that keeps the guard for genuine overlay/menu states.

Do not weaken the churn suppression's viewport behavior (CR-1 regression) and do not
remove the non-managed guard for real overlays; the fix is to stop treating a
provably-dismissed overlay as still owning focus.
