# Plan: retry focused admission when a user-activated app's window resolves late

- **Status:** completed on `main` on 2026-07-13
- **Implemented by:** `b8c4ed15` (`Retry focused admission when an activated app's window resolves late`)
- **Verified target state:** `main` at `b8c4ed15`

## Completion record

Landed as fix option A, one commit, touching only
`Sources/Nehir/Core/Controller/AXEventHandler.swift` (+78) and the changeset
`.changeset/20260713125306-admit-windows-of-user-activated-apps-even-when-t.md`
(`patch`) — the fences held (no test files, no guard semantic changes, no other
files).

What shipped, against the landed source:

- New bounded retry state `pendingUntrackedActivationRetryTasksByPid` /
  `untrackedActivationRetryCountByPid`, delay `untrackedActivationRetryDelay =
  300 ms`, cap `untrackedActivationRetryLimit = 6`
  (`AXEventHandler.swift:7474` `scheduleUntrackedActivationRetry`), kept fully
  separate from the managed-request retry machinery as specified.
- The recovery hook fires at the end of `handleMissingFocusedWindow`
  (`AXEventHandler.swift:7175`) under exactly the planned condition:
  `hasRecentAppActivation(for: pid)` and no tracked entries for the pid and
  `pid != getpid()`; it calls `scheduleAXContextWarmup(for: pid)` then
  `scheduleUntrackedActivationRetry`. Each fired retry re-runs
  `handleAppActivation(pid:source:origin: .retry)` and, while the window stays
  untracked, re-enters this hook to schedule the next attempt under the cap.
- New trace event `untracked_activation_retry pid=<pid> attempt=<n>
  source=<source>` (`AXEventHandler.swift:404`).
- Cleanup wired into `cleanupFocusStateForTerminatedApp`
  (`AXEventHandler.swift:7287`), `cleanup()`, and `resetDebugStateForTests()`
  via `resetUntrackedActivationRetry(for:)` / `resetUntrackedActivationRetryState()`.

**Justified deviation (accepted):** the implementation added `origin ==
.external` to the `recordRecentAppActivation` gate in `handleAppActivation`
(`AXEventHandler.swift:3604`) and an `activeManagedRequest == nil` guard inside
the fired retry. Both are correctness necessities the plan omitted: without the
`origin` gate, each `.retry` re-invocation would renew the 10 s intent TTL and
reset the retry counter, turning the bounded retry into an unbounded loop; the
managed-request guard keeps the retry from racing a real focus request. The
retry preserves the original activation `source`.

Discovery:
[`discovery/20260707-chatgpt-activation-admission-misses-recent-activation-ttl.md`](../discovery/20260707-chatgpt-activation-admission-misses-recent-activation-ttl.md)
(fix option A there). Family:
[`NF-1` in `discovery/20260708-cross-discovery-relevance-clusters.md`](../discovery/20260708-cross-discovery-relevance-clusters.md#nf-1--stale-non-managed-focus-blocks-admission-confirmation-and-command-targets).
Repro confirmed by the user on 2026-07-13 (ChatGPT `com.openai.chat` in the
wild; Claude for Desktop `com.anthropic.claudefordesktop` with the deliberate
recipe).

## Problem (one paragraph)

When the user activates an app whose only window is untracked (skipped by the
startup rescan because it was hidden), the activation handler often cannot
resolve the app's AX focused window at that instant (the query races the
app's own unhide). `handleMissingFocusedWindow` then enters non-managed
fallback and gives up: no admission attempt, no retry, no AX-context warmup —
and a never-tracked app has no `AXFocusedWindowChanged` observer to produce a
later attempt. The `recentAppActivationByPid` intent recorded for the
activation (10 s TTL) expires unconsumed, so when an admission attempt finally
happens (a WM command's frontmost probe, minutes later), the
unrequested-admission guard suppresses the window as
`stale_unrequested_nonmanaged_focus` and it can never join the layout. The
2026-07-13 capture proves the converse: when *any* attempt lands inside the
TTL, the existing `recent_app_activation` exemption admits the window
correctly. The fix is to guarantee such an attempt.

## Fix specification

All changes in `Sources/Nehir/Core/Controller/AXEventHandler.swift`. Line
numbers reference current `main` (`602ab47a`); re-locate by symbol if drifted.

In `handleMissingFocusedWindow` (`AXEventHandler.swift`, search for
`private func handleMissingFocusedWindow`), after the existing
`recordNonManagedFallbackEntered(pid:source:)` call, add a recovery path for
exactly the trapped case:

Condition — all of:

1. `hasRecentAppActivation(for: pid)` is true (user just switched to this app;
   the helper already exists near `recordRecentAppActivation`).
2. The pid has no tracked windows: `controller.workspaceManager.entries(forPid:
   pid).isEmpty`.
3. `pid != getpid()` (never self-retry Nehir's own windows).

Action:

1. **Warm the app's AX context** so the focused-window query can succeed and
   the app gains an `AXFocusedWindowChanged` observer:
   `scheduleAXContextWarmup(for: pid)` (private, already exists; hoist
   visibility only if needed — prefer calling it from within the same type,
   which needs no change).
2. **Schedule an untracked-activation retry**: after a short delay, re-run
   `handleAppActivation(pid: pid, source: source, origin: .retry)`.
   - New state, e.g. `private var pendingUntrackedActivationRetryTasksByPid:
     [pid_t: Task<Void, Never>]` plus an attempt counter — do **not** reuse
     `pendingActivationRetryTask` / `cancelActivationRetry()`: that machinery
     is keyed to managed focus requests and `handleMissingFocusedWindow`
     itself calls `cancelActivationRetry()`, which must keep its current
     behavior.
   - Delay ≈ 300 ms between attempts, max 6 attempts (~2 s total — far inside
     the 10 s `recentAppActivationTTL`, and matching the observed rescue
     timing: the 2026-07-13 capture's coincidental probe succeeded ~2 s after
     activation).
   - On each retry firing, bail silently (and clear state) if any of:
     the pid now has a tracked entry, `hasRecentAppActivation` is no longer
     true, the app is gone (`NSRunningApplication(processIdentifier:)` nil),
     or the controller is gone. `handleAppActivation` re-entering
     `handleMissingFocusedWindow` schedules the next attempt only while under
     the attempt cap — count attempts per activation burst, reset the counter
     when a fresh `workspaceDidActivateApplication` records a new activation
     for the pid.
3. **Trace it.** Add a `NiriCreateFocusTraceEvent` case (follow the existing
   enum + render pattern, e.g. next to `nonManagedFallbackEntered`) rendered
   as `untracked_activation_retry pid=<pid> attempt=<n> source=<source>` so
   future captures show the retry firing. Keep the existing events untouched.

Cleanup hooks:

- `cleanupFocusStateForTerminatedApp(pid:)` (search for it; currently removes
  `recentAppActivationByPid`) must also cancel and remove the pid's pending
  untracked retry.
- `cleanup()` and `resetDebugStateForTests()` (the two existing
  `recentAppActivationByPid.removeAll()` sites) must cancel all pending
  untracked retries.

Explicitly out of scope (do-not-touch fences):

- `shouldSuppressUnrequestedAdmissionDuringNonManagedFocus` — no semantic
  changes, no new exemptions, no TTL changes (`recentAppActivationTTL` stays
  10 s).
- `managedCommandTarget()` in `Sources/Nehir/Core/Controller/WMController.swift`
  (fix option C is deliberately not in this plan).
- The managed-request activation retry machinery
  (`pendingActivationRetryTask`, `scheduleActivationRetry`,
  `cancelActivationRetry`).
- **No test files.** Per `AGENTS.md` / `docs/TESTING.md`: regression tests
  wait until the user confirms the fix in their real repro. Do not create,
  modify, or delete anything under `Tests/`.
- No other files except the changeset fragment below.

## Steps and gates

Run the fast gate between steps, the fuller gate once at the end.

1. Implement the retry state + scheduling in `handleMissingFocusedWindow`,
   the trace event, and the cleanup hooks.
   Gate: `mise run build` (must compile clean).
2. Self-review the diff for: retain cycles in the scheduled `Task` (use
   `[weak self]`), fish-shell-free assumptions, and that
   `handleMissingFocusedWindow`'s existing behavior (fallback entry, border
   clear, close-recovery arming) is unchanged when the new condition doesn't
   hold.
   Gate: `mise run format:check && mise run lint` (fix any findings).
3. Changeset fragment (user-visible bug fix, no tracker issue exists — do not
   invent a ticket number):
   `mise run changeset patch "Admit windows of user-activated apps even when their window resolves late after unhide, instead of leaving them permanently floating"`
4. Final gate: `mise run test:compile`; then `mise run test` if the
   environment has full Xcode — if it fails for environment reasons (not
   compilation), note that in the report rather than retrying.
5. Commit everything as **one commit** on the branch. Plain-English subject
   (no Conventional Commits), no upstream ticket references. Suggested:
   `Retry focused admission when an activated app's window resolves late`
   with a body summarizing the trap (activation intent expiring unconsumed
   because the missing-focused-window fallback never retried).

## Report format

End with a short report: files touched, gates run with pass/fail, the commit
hash, and any deviation from this plan with its justification. Print the
literal line `REPORT-TOKEN: untracked-activation-retry-done` as the last line.

## Validation (performed by the user afterwards, not by the agent)

1. Hide a managed window of a never-relaunched app (or use ChatGPT's own
   close-to-hidden behavior), restart nehir so the rescan skips it.
2. Activate the app from the Dock; even if the AX race hits, a
   `untracked_activation_retry` should fire within ~300 ms and the window must
   tile via `reason=recent_app_activation`.
3. Wait >10 s after activation, run a WM command: the window is already
   managed, so the stale-suppression path is never reached.
4. Regression guard: with non-managed focus active, a background app surfacing
   a window without user activation must still be suppressed
   (`stale_unrequested_nonmanaged_focus`).
