# Stay on the current workspace when a close leaves no same-app window there

**Status: LANDED (2026-07-07).** Shipped on `main` in commit
`Keep current workspace active after window close` (changeset: `nehir` patch —
"Keep current workspace active after closing a window"). This completed the
follow-up to PR #148 / the 2026-07-06 close-recovery work.

## What actually landed

The merged implementation keeps the planned close-local policy, with two
important compatibility refinements found during runtime validation:

1. **Decision tracing first.** Runtime traces now identify the close-recovery
   branch decisions with stable markers including
   `close_recovery_focused_window_nil`, `close_recovery_begin`,
   `close_recovery_activation_gate`,
   `close_recovery_inactive_successor_deferred`,
   `close_recovery_inactive_successor_suppressed`,
   `close_recovery_follow_parked_skip`, and
   `close_recovery_removed_window_focus_recovery`. Parked-follow also records
   skip reasons such as `close_recovery_window`, `on_screen`, `floating`,
   `sticky`, `dedup`, and `no_monitor`.
2. **Short pre-close ambiguity marker.** `AXFocusedWindowChanged(window=nil)`
   records a short-lived focused-window-loss precursor for the pid/workspace, so
   an inactive same-app successor that arrives before tracked removal can be
   deferred instead of immediately switching workspaces.
3. **Inactive same-app successor defer.** A new same-app inactive native
   activation defer path waits briefly and retries once. If tracked close or
   close-recovery evidence appears during that delay, the existing suppression
   path absorbs the successor. If no close evidence appears, the retry proceeds,
   preserving legitimate same-app focus-follow.
4. **Removal recovery survives overwritten focus.** `handleRemoved(token:)` now
   requests removal focus recovery when the removed token matches the active
   close-recovery preserved token or the focused-window-loss precursor, even if
   macOS already moved Nehir's confirmed focus to another same-app window.
5. **Auxiliary-destroy narrowing.** Runtime validation showed browser/profile
   style same-app focus switches can destroy auxiliary AX elements after the
   target focus has already been observed. Auxiliary destroys are therefore not
   allowed to convert an already-deferred same-app activation into close
   recovery; real tracked managed-window destroys still record the close marker.
6. **Same-workspace/offscreen focus compatibility.** Same-app menu/profile focus
   changes to an offscreen window on the same workspace must still scroll/reveal
   the target. The close-only parked-focus suppression and stable redirect were
   narrowed to require overlay/close-recovery evidence instead of suppressing
   ordinary same-app focus changes.

Manual runtime validation covered the original workspace-jump close repro and
adjacent same-app focus-switch/profile/menu cases. Tests were intentionally not
added in this merge because the repository rule keeps runtime bug tests deferred
until after user-confirmed real-repro validation.

## Related prior docs

This plan extends, rather than replaces, the already-landed close/focus work:

- [`completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md`](../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md)
  split same-app behavior into:
  - real same-app focus switches, which should reveal/follow the other workspace;
  - close-successor churn, which should be absorbed.
- [`completed/20260706-stable-viewport-on-window-close-recovery.md`](../completed/20260706-stable-viewport-on-window-close-recovery.md)
  added close-recovery viewport pins, stable-target redirects, pre-confirm
  same-app suppression, and parked-follow suppression while inside the same-app
  close-recovery window.
- [`completed/20260615-quick-terminal-close-switches-workspace.md`](../completed/20260615-quick-terminal-close-switches-workspace.md)
  is the older discovery that established the same broad macOS pattern: closing
  or hiding a surface can produce native focus churn before Nehir has a reliable
  destroy/removal signal.

The new failure is a hole between those fixes: macOS reports a same-app successor
on another Nehir workspace before the close/removal marker that #148 uses to
recognize close-successor churn.

## User-facing policy

When a managed window is closed, Nehir should keep the current Nehir workspace
active. If there is a good surviving managed window on that workspace, focus it.
If the close leaves the workspace empty, still keep that empty workspace active
and clear/settle managed focus locally. Do **not** switch to another workspace
just because macOS chose another window of the closed app there.

In short: closing a window is local workspace maintenance, not workspace
navigation.

This is possible in Nehir's model because active workspace identity is stored
independently from whether the workspace has managed windows:

- `WorkspaceManager.activeWorkspace(on:)` reads the visible workspace map, not a
  window list (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2411`).
- Cross-workspace focus following is an explicit action, e.g.
  `WorkspaceNavigationHandler.activateWorkspace(_:focusing:)`, which calls
  `setActiveWorkspace` and then focuses the target
  (`Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:473`).
- If we suppress/defer the premature same-app successor and do not call
  `activateWorkspace` / `confirmManagedFocus(... activateWorkspaceOnMonitor:
  true)`, the current workspace can remain visible even with no focused managed
  token.

## Reproduction shape and inlined evidence

Single display. Current workspace is `BDC3D217...` and contains at least:

| token | app | workspace | state before close |
|---|---|---|---|
| `28651:20492` | Helium | `BDC3D217...` | focused / being closed |
| `82494:20497` | Ghostty | `BDC3D217...` | other current-workspace managed window |
| `28651:215` | Helium | `3798CA34...` | same app on another workspace |

After closing `28651:20492`, the observed final state was:

```text
focused=WindowToken(pid: 28651, windowId: 215)
WindowToken(pid: 28651, windowId: 215) workspace=3798CA34... visible=true
WindowToken(pid: 82494, windowId: 20497) workspace=BDC3D217... hidden=workspaceInactive
```

So Nehir switched to the other Helium workspace and hid the workspace where the
close happened.

The decisive event order shows why the existing #148 close gate missed it:

```text
managed_focus_confirmed token=28651:20485 workspace=4603C34F...
managed_focus_confirmed token=28651:215   workspace=3798CA34...
hidden_state_changed  token=28651:20485 workspace=4603C34F... hidden=true
managed_focus_requested token=28651:215 workspace=3798CA34...
window_removed token=28651:20485 workspace=4603C34F...
```

The same-app successor (`28651:215`) was accepted **before** the close/removal
record for the previous Helium window (`28651:20485`). At that moment, the
`recentSameAppWindowCloseByPid` gate used by #148 had not necessarily been set
for the tracked window being closed, so the successor looked like a legitimate
same-app focus switch.

A shorter capture shows the same end state with the current workspace becoming
inactive after the close:

```text
AXFocusedWindowChanged pid=28651 window=nil
AXUIElementDestroyed pid=28651 window=20492
window_removed token=28651:20492 workspace=BDC3D217...
managed_focus_confirmed token=28651:215 workspace=3798CA34...
hidden_state_changed token=28651:20492 workspace=BDC3D217... hidden=true
hidden_state_changed token=82494:20497 workspace=BDC3D217... hidden=true
```

The important point is not the specific app. The pattern is: focused app window
closes; macOS reports another window of that app on another Nehir workspace;
Nehir follows it; the workspace where the close happened becomes inactive.

## Source-backed call paths

### Native focused-window callback path

1. `AppAXContext.onFocusedWindowChanged` is wired in
   `Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:97` to call:
   `AXEventHandler.handleAppActivation(pid:source:.focusedWindowChanged)`.
2. `AXEventHandler.handleAppActivation(...)`
   (`Sources/Nehir/Core/Controller/AXEventHandler.swift:2664`) resolves the
   app's focused AX window and classifies the request as one of:
   `.matchesActiveRequest`, `.conflictsWithPendingRequest`, or
   `.unrelatedNoRequest`.
3. For an existing managed entry, the branch around
   `AXEventHandler.swift:2746-2884` runs suppression/defer/redirect guards and
   then calls `handleManagedAppActivation(...)`.
4. `handleManagedAppActivation(...)` (`AXEventHandler.swift:3292`) confirms the
   token as managed focus and computes:
   `shouldActivateWorkspace = !isWorkspaceActive && !isTransferringWindow &&
   !bounceBlocked`.
5. After focus confirmation, `followFocusToParkedWindowWorkspaceIfNeeded(...)`
   (`AXEventHandler.swift:5054`) may call
   `workspaceNavigationHandler.activateWorkspace(entry.workspaceId,
   focusing: entry.token)` for an off-screen tiling target, unless
   `isWithinSameAppCloseRecoveryWindow(pid:)` is true.

### Close/removal path

1. `AppAXContext.onWindowDestroyed` is wired in
   `Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:91` to call
   `AXEventHandler.handleRemoved(pid:winId:)`.
2. `handleWindowDestroyed(...)` (`AXEventHandler.swift:4516`) records a recent
   same-app close for the pid, prepares a destroy candidate, and may delay via
   managed-replacement correlation before `processPreparedDestroy(...)`.
3. `processPreparedDestroy(...)` calls `handleRemoved(token:)`.
4. `handleRemoved(token:)` (`AXEventHandler.swift:1886`) currently computes:

   ```swift
   let shouldRecoverFocus = token == controller.workspaceManager.confirmedManagedFocusToken
   ```

   That is too narrow for this race: if macOS already moved Nehir's confirmed
   focus to the same-app successor, the closed token no longer matches confirmed
   focus, so removal recovery is not requested for the workspace where the close
   happened.

## Why the existing guards miss this case

- `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery(...)`
  (`AXEventHandler.swift:2606`) intentionally starts with
  `hasRecentSameAppWindowClose(for:)`. This preserves the #148 behavior where a
  real same-app focus switch with no close should reveal the other workspace.
  In the failure, the observed successor can arrive before the tracked close
  path has established the close marker.
- `shouldDeferSameAppActiveNativeActivationBeforeCloseRecovery(...)`
  (`AXEventHandler.swift:2528`) handles active-workspace pre-close churn. This
  failure is an inactive-workspace successor.
- `followFocusToParkedWindowWorkspaceIfNeeded(...)` is correct for legitimate
  same-app switches, but it only skips during `isWithinSameAppCloseRecoveryWindow`.
  The race is that the close-recovery window is not reliably active/marked yet.

## Original required observability before behavior changes

Do this first. The next runtime trace should identify every decision branch so
we can prove the fix is catching the close path, not suppressing legitimate
same-app switches.

Add trace records with stable `reason=` names around these points:

1. `handleMissingFocusedWindow(...)`
   - pid, source, origin, requestDisposition
   - preserved token before fallback
   - whether `armWindowCloseFocusRecoveryForFocusedWindowLossIfNeeded` armed
   - recovery workspace, if any
2. `beginWindowCloseFocusRecovery(...)`
   - caller/reason (`focused_window_nil`, `tracked_destroy`,
     `auxiliary_destroy`, `hidden_workspace_inactive`)
   - workspace, suppressed pid, preserved token
3. Existing managed-entry activation branch before each close-recovery guard
   - observed token/workspace
   - isWorkspaceActive
   - requestDisposition
   - active close-recovery workspace
   - recentSameAppClose / recentNonManagedFocus
   - decision: allow / suppress / defer / redirect
4. `followFocusToParkedWindowWorkspaceIfNeeded(...)`
   - log both switch and skip decisions
   - skip reasons: `close_recovery_window`, `on_screen`, `floating`, `sticky`,
     `dedup`, `no_monitor`
5. `handleRemoved(token:)`
   - token removed, affected workspace
   - confirmed token before removal
   - active close-recovery context
   - shouldRecoverFocus and why
   - removed node id if available

Suggested reason names:

```text
close_recovery_focused_window_nil
close_recovery_begin
close_recovery_activation_gate
close_recovery_inactive_successor_deferred
close_recovery_inactive_successor_suppressed
close_recovery_follow_parked_skip
close_recovery_removed_window_focus_recovery
```

## Original implementation plan

### Step 1 — Add decision tracing only

No behavior change. Add the observability listed above and build. Run the real
repro and confirm the trace shows whether the same-app inactive successor arrives
before or after:

- `AXFocusedWindowChanged(window=nil)`
- `AXUIElementDestroyed`
- `window_removed`
- `recentSameAppWindowClose` / close-recovery begin

Fast gate: `swift build`.

### Step 2 — Introduce a focused-window-loss close precursor

Add a short-lived per-pid marker set when `handleMissingFocusedWindow(...)` sees
`source == .focusedWindowChanged` and the current confirmed managed focus belongs
to that pid, or when it arms close recovery through the non-managed overlay path.

This marker represents: "macOS just told us this app has no focused window while
Nehir still has/just had a managed focus anchor for that app." It is not enough
to permanently suppress same-app switches; it is only a pre-close ambiguity
window.

Suggested lifetime: match or stay below the existing close recovery TTL family
(about 0.6–2.0 seconds). Keep it per pid and prune like
`recentSameAppWindowCloseByPid`.

### Step 3 — Defer inactive same-app successor during the precursor window

Add a sibling to the existing pre-close defer helpers:

```swift
shouldDeferSameAppInactiveNativeActivationBeforeCloseRecovery(...)
```

Candidate shape:

- `origin == .external`
- `source == .focusedWindowChanged` or `workspaceDidActivateApplication`
- `case .unrelatedNoRequest = requestDisposition`
- `!isWorkspaceActive`
- observed token pid matches the precursor pid
- active close-recovery context is nil, or not yet for this workspace
- there is evidence this is not a user-requested Nehir focus request

Behavior:

- record `close_recovery_inactive_successor_deferred`
- defer briefly (same style as `shouldDeferInactiveNativeActivationBeforeCloseRecovery`)
- retry once
- if a close/removal/recovery marker appeared, normal close suppression handles it
- if no close marker appeared, allow the retry so #148's legitimate same-app
  cross-workspace focus switch still works

This is the key compatibility point with
`completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md`.

### Step 4 — Make removal recovery independent of already-overwritten focus

In `handleRemoved(token:)`, broaden `shouldRecoverFocus` from only
"removed token is the current confirmed token" to also include:

- removed token matches the active close-recovery preserved/lost token; or
- removed token belongs to a pid with an active focused-window-loss precursor and
  the removed workspace is the active workspace where the close began.

When that happens, request removal focus recovery for the affected workspace even
if confirmed focus has already been overwritten by the same-app successor.

Policy for empty workspaces:

- If the removed workspace still has an eligible survivor, recovery may focus the
  spatial/layout fallback selected by the niri removal path.
- If it has no eligible survivor, do **not** activate another workspace. Clear or
  leave managed focus nil/non-managed locally, keep the workspace active, and keep
  border/selection coherent with "no focused managed window".

Implementation detail to verify before coding: `ensureFocusedTokenValid(in:)`
currently calls `resolveAndSetWorkspaceFocusToken`; if that returns nil, it just
returns. That is compatible with an empty workspace as long as no earlier branch
has already activated the same-app successor workspace.

### Step 5 — Re-run real repro; only then consider tests

Per `AGENTS.md`, do not add or rewrite tests until the runtime fix is confirmed
in the real repro. After confirmation, add targeted regression coverage for the
policy, but tests are not source of truth for this investigation.

## Do-not-touch fences

- Do not remove #148's legitimate same-app focus-follow behavior.
- Do not turn `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
  into a blanket same-app inactive-workspace suppressor.
- Do not widen `recentSameAppWindowCloseTTL` as the primary fix; the problem is
  ordering, not just duration.
- Do not make empty workspaces auto-switch away as part of focus recovery.
- Do not edit tests before runtime confirmation.

## Acceptance criteria (runtime-validated before merge)

Manual/runtime first:

1. Closing the last window of app A on the current workspace does not switch to
   another workspace containing app A.
2. If other windows remain on the current workspace, Nehir focuses the spatially
   appropriate/current-workspace survivor.
3. If no windows remain on the current workspace, that workspace stays active and
   Nehir has no misleading managed focus/border on another workspace.
4. A deliberate same-app focus switch without a close still reveals/follows the
   target workspace, preserving the #148 behavior.
5. Trace output clearly states which close-recovery branch made the decision.

Regression tests remain deferred per repository policy until after user-confirmed runtime validation is explicitly followed by a test task.
