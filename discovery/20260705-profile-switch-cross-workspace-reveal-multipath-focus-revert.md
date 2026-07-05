# Profile switch to a window on another workspace: reveal is reverted through multiple independent focus paths — Discovery

Discovery (2026-07-05). Switching a browser profile (Helium, `net.imput.helium`,
pid 28651) whose target window sits on a **different** Nehir workspace fails to
land the user on that workspace. The switch **works when both profile windows
are on the workspace already in view** (no reveal needed) and fails only when a
workspace reveal is required. Across eight instrumented builds the reveal was
observed to be reverted through **at least three independent focus paths**, all
of which restore focus to the origin window, plus a fourth "parked target is
unfocusable" mode. This is why single-path fixes each appeared to work in
isolation but never fixed the bug.

Validated against the main Nehir source tree; work-in-progress partial fix on
branch `fix/profile-switch-cross-workspace-reveal` (built as `v965e2f` … `v1baf9d`).

## The user-visible contract

- Source window (current profile) and target window (switched-to profile) are
  **separate windows of the same app**.
- **Same workspace:** switching profile focuses the target window in place. Works.
- **Separate workspace:** switching profile should reveal the workspace holding
  the target window and focus it. Instead the view stays on (or snaps back to)
  the origin window's workspace.

## Confirmed root-cause family

The target profile window is **parked off-screen** by Nehir because it lives on
an inactive workspace — every capture shows it at `liveAXFrame={{2055.0, 7.0}, …}`
(off the right edge of the 2056-wide display) with `hidden=workspaceInactive`,
while the origin window is on-screen at `{{416.0, 7.0}, …}`. During the
profile-picker churn the app briefly raises/focuses the target (and its
workspace is often revealed — sometimes by the target workspace's *other* apps
activating first), but Nehir then **restores focus to the origin window** and
reverts the reveal. The same-workspace case works precisely because no reveal is
involved and the target window is on-screen and directly focusable.

The reverts are not one bug. Distinct paths observed, each in a clean
(`startedServices=true`) capture:

1. **App-driven focus bounce.** The picker dismissing makes the app re-report
   its focused window as the origin window (`focus_confirmed … source=focusedWindowChanged`
   on the origin workspace). Handled through
   `AXEventHandler.handleManagedAppActivation`.
2. **`window_close_focus_recovery`.** The picker popup closing (an untracked,
   AX-less transient; `AXFocusedWindowChanged … window=nil`) arms
   `beginWindowCloseFocusRecovery`, anchored to the origin window, which restores
   it. (This is the mechanism of the earlier discovery
   `20260705-helium-profile-switch-cross-workspace-reveal-reverted-by-menu-close-recovery.md`.)
3. **Internal `focusWindow` request.** A reconcile/relayout path issues a fresh
   managed focus request for the origin window on its home workspace
   (`pending_focus_started token=<origin> workspace=<origin-ws>`) with
   `recovery=0` and no app activation — i.e. neither path 1 nor path 2. It enters
   through `WMController.focusWindow(_:)`
   (`Sources/Nehir/Core/Controller/WMController.swift:3817`) →
   `WorkspaceManager.beginManagedFocusRequest`, which has ~20 callers
   (LayoutRefreshController, NiriLayoutHandler, WorkspaceNavigationHandler,
   MouseEventHandler, WindowActionHandler, …).
4. **Parked-target-unfocusable mode.** In some timings the app's attempt to
   focus the target resolves to `window=nil` (macOS cannot focus an off-screen
   window), so Nehir never receives a focus event naming the target and no reveal
   is even attempted. (Diagnostic `app_focus_resolution_diag` was added to
   capture the app's AX main-window/window-list in this mode; it did not fire in
   the captures that took paths 1–3, confirming those are focus *reverts*, not
   the nil-focus mode.)

Which path wins is **timing-dependent** (picker open/close timing, whether the
target workspace's sibling apps activate first, whether the target is parked at
capture time). This is the core reason incremental single-path fixes did not
converge: each build fixed the path in the previous capture and the next capture
surfaced a different one.

## The right abstraction: a cross-workspace reveal hold

The partial fix on the branch introduces a per-pid **cross-workspace reveal
hold**: when the app performs a deliberate switch
(`workspaceDidActivateApplication`) that confirms focus on a workspace, pin that
workspace for a short grace (2.5s). While the hold is active, focus arbitration
that would move the app's focus **off** the held workspace is suppressed
(traced as `cross_workspace_reveal_hold_suppressed`); a later deliberate switch
re-arms/moves the hold. This is the correct anchor — it pins the workspace the
user deliberately switched to, not the app's momentary frontmost window (an
earlier heuristic that failed because the frontmost bounces to the origin
mid-churn).

The hold is currently enforced at two choke points — `handleManagedAppActivation`
(path 1) and `beginWindowCloseFocusRecovery` (path 2). Path 3 bypasses both by
issuing focus through `focusWindow` directly, so the hold does not catch it.

## Why per-path enforcement cannot finish this

`focusWindow(_ token:)` is the single funnel every managed focus request passes
through, but it takes **no origin/reason argument**, so its ~20 callers cannot be
distinguished at the funnel. The reverts (paths 1–3) and legitimate user focus
commands (workspace navigation, bar clicks, window-action focus) are
indistinguishable there today. Enforcing the hold at the funnel without an origin
would also drop legitimate user-initiated focus during the 2.5s window — a
regression against the focus-navigation behaviour covered by
`20260616-omniwm-240-focus-previous-cross-workspace.md`,
`20260616-omniwm-317-rapid-focus-revert-race.md`, and
`20260616-omniwm-379-focus-revert-grace-period.md`.

## Recommended fix (single central enforcement, origin-aware)

1. **Thread a focus origin/reason** into `WMController.focusWindow(_:)` →
   `focusBridge` / `WorkspaceManager.beginManagedFocusRequest` (e.g.
   `userCommand`, `appActivation`, `reconcile`, `recovery`, `layout`). This is a
   mechanical change across the ~20 call sites and is independently useful for
   focus diagnostics.
2. **Enforce the reveal hold once, at the funnel:** drop a managed focus request
   that targets a window of pid P on a workspace other than P's held workspace,
   **only** for non-user origins (`reconcile`/`recovery`/`layout`/`appActivation`
   focus-churn). A `userCommand` focus clears the hold and is always honoured, so
   deliberate navigation during the grace is never swallowed.
3. Keep the reveal-hold arming exactly as the branch has it (any
   `workspaceDidActivateApplication` pins its workspace; refresh on confirmed
   focus that stays on the held workspace).
4. Remove the two per-path enforcement points (paths 1–2) once the funnel
   enforcement subsumes them, or keep them as fast-path early-outs.
5. Address mode 4 (parked-target nil-focus) separately if it still reproduces:
   on a deliberate app activation whose focus resolves to nil, consult the app's
   AX main window (`kAXMainWindowAttribute`); if it maps to a managed window on an
   inactive workspace, reveal + focus it. Gate to `workspaceDidActivateApplication`
   so quick-terminal/dropdown nil-focus cases are untouched.

## Regression surface (must be verified)

- Focus-previous / cross-workspace navigation (`omniwm-240`).
- Rapid focus revert race and revert grace (`omniwm-317`, `omniwm-379`).
- Dock/Cmd-Tab reveal of a managed window (`20260622-dock-click-focus-does-not-reveal-column.md`).
- Quick-terminal close not stealing/revealing a workspace
  (`20260702-quick-terminal-close-reveals-managed-ghostty-column.md`).
- PiP sticky bounce (`20260705-nehir-108-pip-cross-monitor-bounce-sticky-not-globalsticky.md`).
- FFM menu-steal (`completed/20260705-ffm-steals-focus-at-app-menu-edge.md`).

## Known workaround

Keep both profiles' windows on the same Nehir workspace — the same-workspace
profile switch selects the correct window reliably. Confirmed across captures.

## Status / handoff

This needs a single origin-aware focus-funnel change plus a regression pass
against the focus-navigation discoveries above — it should not be finished by
further per-path patching over remote test cycles. The branch
`fix/profile-switch-cross-workspace-reveal` carries the reveal-hold abstraction
(arming + paths 1–2 enforcement + the `app_focus_resolution_diag` diagnostic) as
the foundation; earlier superseded approaches are on `backup/profile-switch-passes-1-3`.
