# Plan: exempt user-activated apps from the unrequested-admission guard

Source discovery:
`discovery/20260703-user-activated-slack-suppressed-as-stale-under-nonmanaged-focus.md`
(read it first — it contains the full evidence, the confirmed reproduction
recipe, and the control runs this plan's verification relies on).

## Problem

While non-managed focus is active, `shouldSuppressUnrequestedAdmissionDuringNonManagedFocus`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift`, around line 721 at
commit `8286c192`) vetoes the focused-admission of any window that lacks a
CGS-create context, a recent managed workspace for its pid, an explicit
workspace rule, or an active managed focus request. A deliberate user app
switch to an existing-but-untracked window (Slack/Teams revealed from Cmd-H,
launcher activations, Dock clicks) fails all four exemptions and is dropped —
and the state is self-perpetuating, because the rejected window's own focus
keeps `isNonManagedFocusActive` true. The user-intent signal that
distinguishes this case (`workspaceDidActivateApplication` for the same pid,
observed moments earlier and already traced as `activation_source_observed`)
is never stored where the predicate can read it.

## Tasks

### 1. Record recent user app activations

In `AXEventHandler`, add a small TTL map `recentAppActivationByPid:
[pid_t: TimeInterval]` recorded where `activation_source_observed` is emitted
(the `recordActivationSourceObserved`-adjacent path, AXEventHandler.swift:207
area), **only** for `source == .workspaceDidActivateApplication` — that event
fires on genuine app-level switches (Dock, Cmd-Tab, launcher `activate()`),
not on window-level focus churn. Mirror the mechanics of
`recentManagedWorkspaceByPid` / `pruneRecentManagedWorkspaces`
(AXEventHandler.swift:3906-3930): store `managedReplacementCurrentUptime()`,
prune on read. Use a dedicated TTL constant of a few seconds (recommend 10s;
do not reuse `recentManagedAdmissionTTL` blindly — check its value and pick
deliberately, documenting the choice).

### 2. Exempt recently activated pids in the guard

In `shouldSuppressUnrequestedAdmissionDuringNonManagedFocus`, after the
`recentPidWorkspaceId` exemption and before the final suppression, add: if the
token's pid has a live entry in `recentAppActivationByPid`, record the
decision via `recordUnrequestedAdmissionDuringNonManagedFocusDecision` with
`suppressed: false, reason: "recent_app_activation"` and return `false`.
Keep the existing exemptions and their order unchanged.

### 3. Make the suppressed decision visible in the decision stream

Today the trace shows `window_decision … outcome=trackedTiling` followed by a
separate suppression record; tooling reading decisions alone concludes the
window was tiled. Smallest honest fix: keep the decision record as-is but
ensure the suppression record is always adjacent (it already is), **and** add
the suppression outcome to the `window_decision` line when the veto happens —
e.g. a `deferred=suppressed_nonmanaged_focus` (or similar existing-field
reuse) so a single grep over decisions tells the truth. If threading that
state into the decision emitter is invasive, an acceptable fallback is a
follow-up `window_decision_suppressed token=…` record; do not restructure the
decision pipeline for this.

### 4. Tests

Extend `Tests/NehirTests/AXEventHandlerTests.swift` (it already covers
adjacent guard state):

- pid recently activated via `workspaceDidActivateApplication` + non-managed
  focus active + no other exemption → **not** suppressed, reason
  `recent_app_activation`.
- same setup but activation older than the TTL → suppressed with
  `stale_unrequested_nonmanaged_focus` (existing behavior preserved).
- activation recorded from `focusedWindowChanged` only → does **not** create
  an exemption (the map must only be fed by app-level activation).
- existing exemptions (`cgs_created_context`, `recent_pid_workspace`,
  `explicit_workspace_assignment`, `matches_active_managed_request`) unchanged
  — run the existing suite.

## Out of scope (companion findings, do not fix here)

- Cmd-H layout behavior (column stays reserved, scroll refocus unhides):
  `discovery/20260703-cmd-h-hidden-app-column-stays-reserved-and-scroll-refocus-unhides.md`.
- Startup rescan skipping non-enumerable (hidden/minimized) windows — this fix
  downgrades that gap from "permanently stuck" to "admitted on first user
  activation", which is acceptable for now.
- Re-evaluation of suppressed admissions when non-managed focus exits.

## Verification

Unit tests above, plus the confirmed manual protocol from the discovery
("Reproduction steps for the current codebase", confirmed 2026-07-03):

1. Regular Ghostty window tiled; `quick-terminal-autohide = false`; Slack
   tiled → Cmd-H → restart Nehir; click Ghostty tile; summon quick terminal,
   type a character; confirm the trace shows `non_managed_fallback_entered`
   for the Ghostty pid (guard armed); Dock-click Slack.
2. Before this fix that run yields two
   `unrequested_admission_nonmanaged_focus_decision suppressed=true
   reason=stale_unrequested_nonmanaged_focus` records and Slack floats
   unmanaged. After the fix the same run must yield
   `suppressed=false reason=recent_app_activation` followed by
   `candidate_tracked` / `window_admitted … context=focused_admission`, with
   Slack tiled into a column.
3. Regression control: reveal Slack from the Dock while a managed window has
   confirmed focus (guard unarmed) — must still tile, as today.
4. Regression: with the quick terminal focused and **no** user activation of
   any hidden app, no unrelated background window may get admitted — the
   stale-surface suppression must still fire for windows whose pid was not
   recently activated.

Gate: project's standard validation (`mise run validate` or the repo's
configured check) plus the targeted test file.
