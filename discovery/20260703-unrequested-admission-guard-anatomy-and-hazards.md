# Discovery: anatomy of the unrequested-admission guard — intent, inputs, exemption ladder, and underwater stones

Status: reference document, not a bug report. Written after the
`fix/nonmanaged-admission-exemption` work landed on main as `151f4e3a`
("Exempt user-activated apps from the unrequested-admission guard"); all
source cites below are against that commit. Companion to
`discovery/20260703-user-activated-slack-suppressed-as-stale-under-nonmanaged-focus.md`
(the concrete trap this guard caused) and
`completed/20260703-fix-unrequested-admission-guard-user-activation-exemption.md`.

## Why this document exists

`shouldSuppressUnrequestedAdmissionDuringNonManagedFocus`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:742`) is a
last-line veto in the window-admission pipeline. It is small (~100 lines) but
it sits at the intersection of five independent state machines — non-managed
focus, the focus bridge's managed requests, create-placement contexts, window
rules, and two TTL intent maps — and it silently drops windows when its
inputs disagree. It already produced one self-perpetuating trap (a window
that could *never* be admitted through any activation route). The conditions
it evaluates are each maintained by different subsystems with different
lifetimes, so future bugs here will look like "Nehir just ignored my window"
with no error anywhere. This document records the mechanism, the invariants
each exemption depends on, and the fragile spots we already know about.

## Intention

While **non-managed focus** is active (an unmanaged overlay — Ghostty quick
terminal, launcher palette, Nehir's own UI — holds native focus), AX and
WindowServer keep reporting surfaces: pre-existing windows of background
apps, re-enumerated stale surfaces, the overlay's own transients. Admitting
those would pull random apps into the *active* workspace, because create-time
placement inputs (focused workspace, interaction monitor) are meaningless at
that moment — nothing managed is focused. The guard's job: **during
non-managed focus, only admit windows the user demonstrably asked for; drop
everything else.** "Asked for" is inferred, and every inference channel is an
exemption in the ladder below.

The guard is deliberately a *veto after decision*: `window_decision` (the
disposition heuristic) has already said `trackedTiling`/`trackedFloating`;
the guard only decides whether tracking proceeds *right now*. There is no
deferral queue — a suppressed admission is dropped, its placement context
discarded, and no retry is scheduled. Recovery relies entirely on a future
event re-running an admission path.

## The exemption ladder (evaluated in order)

All at `AXEventHandler.swift:742-840`. Every branch emits an
`unrequested_admission_nonmanaged_focus_decision` trace record with a
`reason`, including the non-suppressed ones — this is the primary debugging
signal.

1. **Guard disarmed** — `controller == nil` or
   `!workspaceManager.isNonManagedFocusActive` → admit, *no trace record at
   all*. (Absence of the record in a trace means the guard never armed, not
   that it passed.)
2. **`explicit_workspace_assignment`** — the caller resolved a window-rule
   workspace assignment or a pending explicit move intent for the token.
   Passed in by the caller as a bool; each of the three call sites computes
   it slightly differently (see call-site table).
3. **`matches_active_managed_request`** — the token equals
   `focusBridge.activeManagedRequest?.token`: Nehir itself is mid-way through
   focusing this window.
4. **`cgs_created_context`** — the placement context's `source ==
   "cgs_created"` (stringly-typed compare): a real WindowServer create event
   was observed for this window id. New windows are always intent.
5. **`recent_pid_workspace`** — `createPlacementContext.recentPidWorkspaceId
   != nil`: the pid had a managed workspace within
   `recentManagedAdmissionTTL` = **15 s** (`AXEventHandler.swift:453`,
   map `recentManagedWorkspaceByPid`, written by
   `recordRecentManagedWorkspace` on focus confirmation / admission). Covers
   the "focused app bounce" — an app whose window we were just managing.
6. **`recent_app_activation`** *(added in `151f4e3a`)* —
   `hasRecentAppActivation(for: token.pid)`: an app-level activation
   (`workspaceDidActivateApplication`) for this pid within
   `recentAppActivationTTL` = **10 s** (`AXEventHandler.swift:460`, map
   `recentAppActivationByPid:480`, recorded at `:1916-1918` inside
   `handleAppActivation`). Covers Dock / Cmd-Tab / launcher switches to an
   existing-but-untracked window — the trap case.
7. **Suppress** — reason `stale_unrequested_nonmanaged_focus`, plus a
   `windowDecisionSuppressed` trace record (`AXEventHandler.swift:115`) so
   decision-stream tooling doesn't believe the vetoed `trackedTiling`.

## The three call sites

All three follow the same contract: only consulted when `existingEntry ==
nil` (already-tracked windows never pass through the guard), and on
suppression they `discardCreatePlacementContext` and `continue`/return —
no retry, no deferral.

| Site | Path | Notes |
| --- | --- | --- |
| `AXEventHandler.swift:2305` in `admitFocusedWindowBeforeNonManagedFallback` (`:2261`) | AX focus lands on an untracked window during activation handling | The context here is usually **synthesized** (`ensureCreatePlacementContextForFocusedAdmission`, source `ax_focused_admission_synthesized`) because AX focus can precede or outlive the CGS create. Synthesized contexts can only pass via exemptions 2, 3, 5, 6 — never 4. |
| `WMController.swift:2900` in `reevaluateWindowRules` (`:2776`) | Rule re-evaluation sweep discovers an untracked token | `hasExplicitWorkspaceAssignment` here includes `hasPendingExplicitWorkspaceMoveIntent`. |
| `LayoutRefreshController.swift:1335` in `buildFullRefreshExecutionPlan` (`:1215`) | Full rescan (startup and periodic) enumerates an untracked window | **The guard gates full rescans too.** A rescan running while an overlay holds focus will skip every untracked window that has no context/intent signal. |

## Arming and disarming: the non-managed-focus state machine

The guard's master switch is `workspaceManager.isNonManagedFocusActive`
(`WorkspaceManager.swift:1161`), a single boolean in
`sessionState.focus` with **no cause attribution** — it does not know *which*
window armed it or whether that window still exists.

- **Armed** by `enterNonManagedFocus(...)` — six call sites in
  `AXEventHandler.swift` (`:1654, :1929, :2245, :3038, :4582, :4645`)
  covering: focus falling to an unmanaged/untracked window
  (`non_managed_fallback_entered`), Nehir's own windows taking focus
  (pid == getpid(), `:1929`), and missing-focused-window fallbacks.
- **Disarmed** only by `confirmManagedFocus` on a managed token (focus
  returning to a tracked window). There is also a
  `recentlyLeftNonManagedFocus(within:)` grace query (`:1165`) used by
  *other* consumers, not by this guard.

**The structural hazard** (root of the Slack trap, and the pattern to watch
for in any future bug): *the guard's own suppression can keep the switch
armed*. If the suppressed window itself holds native focus, its every
activation re-enters non-managed fallback, which keeps
`isNonManagedFocusActive == true`, which suppresses the next admission
attempt — a closed loop with no external exit. Exemption 6 broke the loop
for user-driven app switches, but the loop *shape* is inherent to the
design: any admission path whose failure leaves the window focused, combined
with any exemption gap, re-creates it.

## The intent maps and their lifetimes

| Map | Key | TTL | Written by | Cleared by |
| --- | --- | --- | --- | --- |
| `recentManagedWorkspaceByPid` | pid → (workspaceId, uptime) | 15 s, entry also dropped if the workspace descriptor no longer exists | `recordRecentManagedWorkspace` on focus confirmation (`:2446`) and admission | prune on read; app termination (`cleanupFocusStateForTerminatedApp:4710`); test reset |
| `recentAppActivationByPid` | pid → uptime | 10 s | `handleAppActivation` when `source == .workspaceDidActivateApplication` (`:1916`) | prune on read; app termination; `resetCreatedWindowState` (`:529`); test reset |

Both use `managedReplacementCurrentUptime()` (monotonic uptime), so sleep
does not extend the windows. Both are consulted only through pruning
accessors, so stale entries cannot fire.

## Underwater stones (known-fragile spots, not yet bugs)

1. **Intent recording is gated by the focus policy engine.**
   `recordRecentAppActivation` runs *after* the
   `focusPolicyEngine.evaluate(.managedAppActivation(source:)).allowsFocusChange`
   guard at the top of `handleAppActivation` (`:1898-1902`). If a focus lease
   (e.g. the 0.4 s `nativeAppSwitch` lease that this same function begins at
   `:1946`, or any future lease) causes the evaluation to deny at the moment
   `workspaceDidActivateApplication` arrives, the user's intent is **never
   recorded** and exemption 6 silently doesn't exist for that switch. Rapid
   successive app switches are the likely trigger. If a trap-like report
   arrives where the trace shows `activation_source_observed` *missing* for
   an activation the user clearly performed, look here first.

2. **`workspaceDidActivateApplication` is not purely user intent.**
   NSWorkspace fires it for programmatic `NSRunningApplication.activate()`
   calls too. A background app that activates itself while an overlay holds
   focus now gets a 10 s window in which *any* of its untracked windows pass
   exemption 6 and are pulled into the active workspace — exactly what the
   guard exists to prevent. The TTL and the remaining conditions (heuristic
   must want to manage; AX must report it) keep this narrow, but it is the
   deliberate trade-off of fix option A over the stricter option B, and the
   first place to look if "random app tiled itself" reports appear.

3. **Suppression destroys placement context, permanently.**
   All three call sites `discardCreatePlacementContext` on suppression. If
   the same window is admitted later through another path (rescan, next
   activation), it places from live-frame fallback instead of its create-time
   inputs — subtle wrong-monitor / wrong-workspace placement is the expected
   symptom, and it will look unrelated to the guard.

4. **No re-evaluation on disarm.** Nothing re-runs suppressed admissions
   when non-managed focus ends (fix option C's second half, deliberately not
   implemented). Today every recovery depends on a *fresh* event: another
   activation, a CGS create, a rescan. Any future overlay that holds focus
   for a long time (persistent HUD, palette pinned open) turns "suppressed
   once" into "invisible until the user pokes it".

5. **The guard runs before structural-replacement rekey.** In both the
   `reevaluateWindowRules` path (`WMController.swift:2899-2908` vs rekey at
   `:2930`) and the full-rescan path (`LayoutRefreshController.swift:1334`
   vs rekey at `:1356`), suppression skips the token *before*
   `rekeyStructuralManagedReplacementIfNeeded` can claim it. A window that is
   really a managed replacement (same app recreating its window id, the
   VS Code pattern from
   `completed/…vscode-focused-admission-skips-managed-replacement-rekey`)
   loses its rekey opportunity if it happens to be evaluated during
   non-managed focus — the replacement info has its own TTL and may expire
   before the next chance. Exemption 5 usually saves this (the pid was just
   managed), but only within its 15 s window.

6. **Stringly-typed context sources.** Exemption 4 compares
   `context.source == "cgs_created"`; the synthesized path uses
   `"ax_focused_admission_synthesized"`. These strings are produced in one
   file and consumed in another with no shared constant — a renamed or new
   source silently falls through to suppression.

7. **Boolean arming with no ownership.** Because
   `isNonManagedFocusActive` doesn't record *why* it's armed, the guard
   cannot distinguish "launcher palette flapping focus" from "the very window
   being admitted holds focus". Any future exemption that needs that
   distinction (fix option B wanted it) requires threading cause through
   `enterNonManagedFocus` first.

8. **Startup rescan + hidden windows is the trap feeder.** The full rescan
   only admits AX-enumerable windows; Cmd-H-hidden / minimized / Electron
   soft-closed windows enter the session untracked (confirmed experimentally
   in the Slack discovery). Every such window is a future guard customer:
   its eventual reveal happens through `focused_admission` with a synthesized
   context and must climb the exemption ladder. Changes to rescan enumeration
   or to the ladder must be evaluated together.

9. **Trace semantics.** `window_decision … outcome=trackedTiling` is emitted
   even when the guard subsequently vetoes; the veto appears as the separate
   `windowDecisionSuppressed` record (added in `151f4e3a`). Tooling must
   join on token. And per stone 1: *absence* of any
   `unrequested_admission_nonmanaged_focus_decision` record means the guard
   never armed — do not read it as "passed".

## Debugging playbook

Symptom "window exists, healthy, but Nehir never tiles it":

1. Capture a runtime trace of the reveal/activation; grep for the token in
   the create-focus trace.
2. `unrequested_admission_nonmanaged_focus_decision suppressed=true` present
   → this guard. Read its fields: `context_source` (synthesized vs cgs),
   `recent_pid_workspace`, `explicit_workspace_assignment`,
   `active_managed_request_token` tell you exactly which exemptions were
   evaluated and missed. Then ask *which intent signal should have fired* and
   check its recording side (stones 1, 2, 5).
3. No decision record but also no `candidate_tracked` → the guard never ran;
   look upstream at `prepareCreateCandidate` rejections
   (`prepare_create_rejected`) or the disposition heuristic.
4. Check what is arming non-managed focus: `non_managed_fallback_entered`
   records name the pid; the runtime-state snapshot shows
   `nonManaged=true/false`.
5. Unit-level: the guard is directly testable
   (`Tests/NehirTests/AXEventHandlerTests.swift:1737,1762,1794`) and state is
   resettable via `resetDebugStateForTests`.

## Invariants worth preserving in any future change

- Already-tracked windows (`existingEntry != nil`) must never pass through
  the guard — all three call sites gate on it; keep that when adding call
  sites.
- Every guard evaluation while armed must emit a decision record with a
  distinct reason; every *new exemption* needs its own reason string.
- A suppressed window must remain recoverable by at least one user action
  that does not require quitting the app. Post-`151f4e3a` the set is:
  activate it again via any app-level switch (exemption 6), focus a managed
  window first (disarms), drag to another display / reopen (CGS create).
  Any change that shrinks this set to empty re-creates the permanent trap.
- Exemptions must be pid- or token-scoped with short TTLs. A long-lived or
  global exemption converts the guard into a no-op precisely in the
  overlay-heavy sessions it was built for.
