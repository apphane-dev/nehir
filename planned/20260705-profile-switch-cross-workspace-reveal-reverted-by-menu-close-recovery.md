# Profile switch does not reveal the target profile's workspace — let a completed cross-workspace raise survive menu-close focus recovery — Plan

Switching a browser profile from its menu bar raises the target profile's
window, which lives on a **different Nehir workspace**. Nehir reveals that
workspace for a moment, but the profile-picker **menu popup closing** arms
`window_close_focus_recovery` anchored to the *pre-switch* window on the
*original* workspace, and recovery reverts the reveal. The target profile's
windows are never shown.

The raw finding (symptom + inlined trace evidence + source mechanism) is in the
companion discovery
[`../discovery/20260705-helium-profile-switch-cross-workspace-reveal-reverted-by-menu-close-recovery.md`](../discovery/20260705-helium-profile-switch-cross-workspace-reveal-reverted-by-menu-close-recovery.md).
Read it first — this plan does not re-derive the evidence.

All source references verified against the main Nehir source tree at `83c2234b`
on 2026-07-05 (the build that produced the capture, `nehir v83c223`). Line
numbers will drift; functions are named so they remain findable.

---

## TL;DR

- **Symptom.** One display, Nehir virtual workspaces (`displaySpacesMode=enabled`,
  all workspaces on one native Space). User is on workspace 2 with a browser
  window focused; switches profile from the menu bar; the target profile's window
  is on workspace 1. The view flickers toward workspace 1, then snaps back to
  workspace 2 — target profile stays hidden.
- **Root cause.** The reveal genuinely runs (`handleManagedAppActivation` confirms
  focus with `activateWorkspaceOnMonitor` for the raised window on the inactive
  workspace), but the transient profile-picker menu popups — untracked, level
  101 — are then destroyed. `handleWindowDestroyed`'s untracked-auxiliary
  fallback calls `armWindowCloseFocusRecoveryForFocusedAppEvent`
  (`AXEventHandler.swift:3564`), and the menu's `AXFocusedWindowChanged
  window=nil` arms recovery again via
  `armWindowCloseFocusRecoveryForFocusedWindowLossIfNeeded`
  (`AXEventHandler.swift:4635`). Both anchor recovery to the pre-switch
  `confirmedManagedFocusToken` on the original workspace, and
  `shouldSuppressObservedActivationDuringWindowCloseRecovery`
  (`AXEventHandler.swift:1659`, `recoveryWorkspaceId != observedEntry.workspaceId`
  at `:1680-1682`) then suppresses the target-workspace raise. Focus is restored
  to the original workspace.
- **False assumption.** The recovery + inactive-workspace suppression defenses
  assume a genuine cross-workspace switch arrives as a
  `workspaceDidActivateApplication` that makes the target workspace active
  *first* (true for native Spaces, false for Nehir's virtual workspaces), so any
  same-app re-focus onto an inactive workspace is treated as churn to undo.
- **Fix (this plan).** Record, per pid, the most recent **user-initiated raise of
  a standard managed window onto a workspace other than the current interaction
  workspace**. When close-focus-recovery is about to arm for that same pid, if
  such a raise happened within a short TTL, **do not arm recovery** (equivalently:
  let the raise stand). This defends the exact invariant — "a real cross-workspace
  raise the user just caused" — without weakening overlay-close recovery, which
  produces no such raise.

---

## Scope fence — files this plan owns

Touch only:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift` — the recovery arming +
  the new recent-cross-workspace-raise record.
- `Tests/NehirTests/` — new tests (see below). Add to an existing
  `AXEventHandler`-focused test file if one exists; otherwise a new file.
- `.changeset/<timestamp>-profile-switch-reveals-target-workspace.md` — created
  via `mise run changeset`, not by hand.

**Do not touch:** `WorkspaceManager.swift`, `StateReducer.swift`,
`FocusPolicyEngine.swift`, the niri engine, or any of the other suppression
guards' *conditions* (`shouldSuppressManagedActivationWhileNonManagedFocusAnchored`,
`shouldSuppressHiddenInactiveStickyActivation`,
`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`). This
plan changes *whether recovery arms*, not the reveal or suppression logic. Do
not modify unrelated existing tests.

---

## Implementation steps

### Step 1 — record user-initiated cross-workspace raises

In `handleManagedAppActivation` (`AXEventHandler.swift:2391`), at the point where
focus is confirmed with `shouldActivateWorkspace == true` (i.e.
`!isWorkspaceActive`, `:2408`, `:2418-2426`), record the raise:

- Add a small per-pid map on `AXEventHandler`, e.g.
  `private var recentCrossWorkspaceRaiseByPid: [pid_t: (workspaceId:
  WorkspaceDescriptor.ID, at: DispatchTime)]`, mirroring the mechanics of the
  existing `recordRecentAppActivation` / recent-managed-workspace maps in this
  file (find them by name; reuse their TTL/uptime idiom rather than inventing a
  new clock).
- Record only when **all** hold: `shouldActivateWorkspace == true`; the entry's
  window is a **standard** window (role `AXWindow` / subrole `AXStandardWindow`,
  not a popup/level ≠ 0 surface); the activation was **user-initiated**
  (the pid has a `recordRecentAppActivation` entry within its TTL, i.e. a recent
  `workspaceDidActivateApplication`); and the window is **not sticky-sourced**
  (`!workspaceManager.hasStickyWindowSource(entry.token)` — excludes PiP, see
  regression 3).
- Use a short TTL (target ~300–500 ms; align with, and keep shorter than, the
  `native_app_switch` lease of `0.4` s at `:1947-1952`). Prune on read.

### Step 2 — let a fresh cross-workspace raise veto recovery arming

Add a helper `recentCrossWorkspaceRaiseActive(forPid:) -> Bool` that returns true
when the pid has a non-expired record from Step 1 whose `workspaceId` is **not**
the current interaction workspace.

Gate both recovery arm sites on it:

- `armWindowCloseFocusRecoveryForFocusedAppEvent` (`:1624`): return early
  (do not `beginWindowCloseFocusRecovery`) when
  `recentCrossWorkspaceRaiseActive(forPid: pid)`.
- `armWindowCloseFocusRecoveryForFocusedWindowLossIfNeeded` (`:1586`): same early
  return, keyed on the `pid` argument.

Rationale: an overlay/quick-terminal close produces **no** cross-workspace
standard-window raise for that pid, so this gate never fires for the cases
recovery exists to protect (see regressions). A profile switch does, so recovery
yields and the reveal stands.

Do **not** change `shouldSuppressObservedActivationDuringWindowCloseRecovery` —
once recovery is not armed, its `recoveryContext` is nil and it already returns
false.

### Step 3 — trace

Add a create-focus trace record when the gate vetoes arming (a new
`recordNiriCreateFocusTrace` kind or a reuse of the existing lease/recovery trace
shape) so the decision is observable in future captures, e.g.
`close_recovery_skipped reason=recent_cross_workspace_raise pid=… workspace=…`.
Follow the existing trace-record enum pattern in this file; keep the field names
snake_case to match sibling records.

---

## Tests (`Tests/NehirTests/`)

Drive `handleAppActivation` / `handleManagedAppActivation` /
`handleWindowDestroyed` at the seam the existing AXEventHandler tests use (match
their harness — do not stand up a real WindowServer). Add:

1. **Profile-switch reveal survives menu close (the fix).** Two Nehir workspaces
   on one monitor; app pid P has window A tiled+focused on the active workspace 2
   and window B tiled on inactive workspace 1. Simulate: user activation of P
   (`workspaceDidActivateApplication`), a raise/confirm of B on workspace 1
   (reveal), then destruction of an **untracked level-101 popup** for P and an
   `AXFocusedWindowChanged window=nil` for P. Assert: recovery is **not** armed,
   B stays confirmed, and workspace 1 is the active/revealed workspace at the end.
2. **Quick-terminal close still triggers recovery (regression guard).** Same
   two-workspace setup, but **no** cross-workspace standard-window raise for P;
   simulate a quick-terminal/overlay close (`window=nil`) with P's managed
   window on another workspace. Assert recovery **is** armed and the view does
   **not** jump to that window's workspace.
3. **Sticky-sourced (PiP) raise does not veto recovery.** Same as test 1 but B is
   sticky-sourced (`hasStickyWindowSource == true`). Assert the raise is **not**
   recorded and recovery **is** armed (PiP must not yank the view).
4. **Raise without recent user activation does not veto recovery.** Same as test 1
   but with no recent `recordRecentAppActivation` for P (passive same-app focus
   churn). Assert recovery **is** armed.
5. **TTL expiry.** Record a cross-workspace raise, advance the clock past the TTL,
   then arm recovery. Assert recovery **is** armed (the veto is not sticky).

If the existing test harness cannot advance the recovery clock, inject the TTL
clock the same way sibling tests inject time (look for an existing date/uptime
provider on `AXEventHandler` or the controller; reuse it — do not add a new
global).

---

## Gate

Between steps, run the fast gate from the repo root:

```
mise run format:check && mise run lint && mise run build
```

Once, at the end, run the full gate and create the changeset:

```
mise run check
mise run changeset patch "Switching a browser profile now reveals the workspace holding the target profile's window (previously the profile-picker menu closing reverted the switch)."
```

`mise run check` = `format:check + lint + build + test`. If a fresh worktree
lacks shims, run `mise trust` first.

---

## Regressions to guard against (verify each; cross-refs)

1. **Quick-terminal close must not reveal/steal a workspace** —
   `discovery/20260702-quick-terminal-close-reveals-managed-ghostty-column.md`,
   `discovery/20260617-move-mouse-to-focused-warps-across-monitors-on-quick-terminal-close.md`.
   Covered by the standard-window + recent-user-activation gate (a QT toggle
   raises no cross-workspace standard window). Test 2 locks it in.
2. **App menu / menu-bar edge must not steal focus (FFM)** —
   `completed/20260705-ffm-steals-focus-at-app-menu-edge.md`,
   `completed/20260705-nehir-112-ffm-fixed-dock-occlusion-regression.md`. This
   plan does not change focus admission of popups; it only skips *recovery
   arming*. Confirm no interaction with the menu-popup unmanaged classification.
3. **PiP / sticky cross-monitor bounce** —
   `discovery/20260705-nehir-108-pip-cross-monitor-bounce-sticky-not-globalsticky.md`,
   `shouldSuppressHiddenInactiveStickyActivation` (`:1817`). The
   `!hasStickyWindowSource` condition (Step 1) excludes PiP. Test 3 locks it in.
4. **Dock/Cmd-Tab to a managed window still reveals, no double-reveal** —
   `discovery/20260622-dock-click-focus-does-not-reveal-column.md`. The gate only
   suppresses recovery *arming*; the reveal path is untouched. Ordinary dock
   switches without a popup burst do not trigger recovery in the first place.
5. **Rapid focus-revert races / lease timing** —
   `discovery/20260616-omniwm-317-rapid-focus-revert-race.md`,
   `discovery/20260616-omniwm-379-focus-revert-grace-period.md`. Keep the new TTL
   shorter than the `native_app_switch` lease (`0.4` s) and the revert grace
   period; note the chosen value in a code comment.
6. **Multi-window app, deliberate cross-workspace work.** The veto requires a
   *recent user activation* + a *standard-window* raise, so passive same-app
   focus churn between two workspaces does not trip it and the existing anchor
   behavior is preserved.

---

## Commit

Single focused commit on a feature branch (not `main`). Message shape:

```
Keep a user-driven cross-workspace raise from being reverted by menu-close focus recovery

Switching a browser profile from its menu bar raises the target profile's
window on another Nehir workspace; the profile-picker popup closing armed
window_close_focus_recovery anchored to the pre-switch window and reverted the
reveal. Record recent user-initiated cross-workspace standard-window raises per
pid and skip arming recovery for that pid within a short TTL.

Refs discovery 20260705-helium-profile-switch-cross-workspace-reveal-reverted-by-menu-close-recovery.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

Include the changeset fragment in the same commit. When done, print the
completion token: `PLAN_PROFILE_SWITCH_REVEAL_COMPLETE`.
