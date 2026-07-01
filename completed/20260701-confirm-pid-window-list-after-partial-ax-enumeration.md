# Confirm a pid's AX window list after admission instead of trusting the first query — Plan

## Status

**Status: completed — merged to `main` as `0b0ec493` ("Prevent
structural-replacement correlation from merging same-pass sibling windows")
via PR #126 on 2026-07-01.** The shipped fix targets a different root cause
than this plan's original design (see "Fix landed" below) — Phases 2-4 as
originally proposed were not built and are not planned; the concrete defect
both discoveries observed is closed. Moved from `planned/` to `completed/` on
2026-07-01.

**Phase 1 (instrumentation) implemented, 2026-07-01.** Implemented on branch
`patch/confirm-pid-window-list-after-partial-ax-enumeration` in the main Nehir
repo, merged as part of PR #126.

What shipped:

1. `AppAXContext.getWindowsAsync()` (`Sources/Nehir/Core/Ax/AppAXContext.swift`)
   now logs every raw `kAXWindowsAttribute` result — pid, window id list, and a
   `newContext` flag (true only for the first query against a given
   `AppAXContext` instance) — into a new bounded ring buffer
   (`Sources/Nehir/Core/Ax/AXWindowsQueryTrace.swift`), dumped into runtime
   trace captures under a new `## AX windows query trace` section.
2. `AXManager.fullRescanEnumerationSnapshot()` (`Sources/Nehir/Core/Ax/AXManager.swift`)
   now cross-checks each pid's AX-reported window count against a per-pid
   WindowServer/CGWindowList on-screen count and traces
   `ax_window_count_mismatch pid=… ax=… windowServer=…` into the same ring
   buffer whenever AX undershoots.
3. The reconcile `windowAdmitted` event
   (`Sources/Nehir/Core/Reconcile/WMEvent.swift`) now carries a
   `WindowAdmissionContext`, printed in its trace summary as `context=…`:
   `startup_full_rescan` / `pid_reevaluation` / `window_rule_reevaluation` /
   `focused_admission` / `window_create` / `ax_context_confirmation`.
   `ax_context_confirmation` is defined but not yet emitted anywhere —
   reserved for Phase 2-3.

Deviations from this plan's exact wording, decided during implementation:

- This plan named four admission-context values; the real `addWindow` call
  sites needed two more (`window_rule_reevaluation` for
  `reevaluateWindowRules`'s `.window`-target path, distinct from its `.pid`
  branch; and `window_create` for the default CGS-create path) to stay
  exhaustive without mislabeling the majority of ordinary admissions.
- `LayoutRefreshController`'s single full-rescan `addWindow` call site is
  reached by every `RefreshReason` that routes to `.fullRescan` (startup,
  unlock, space change, etc.), not literally only cold start; it is tagged
  `startup_full_rescan` per this plan's naming regardless.
- A focused-admission candidate that gets deferred into the
  managed-replacement burst queue and replayed later loses its
  `focused_admission` tag and reports as `window_create` instead — threading
  context through that queue was judged out of scope for Phase 1.
- `WorkspaceManager.addWindow`'s new `admissionContext` parameter defaults to
  an added `unspecified` case rather than being required, since roughly two
  dozen test call sites construct windows directly and do not care about
  admission context.

Build (`swift build`, `swift build --build-tests`) and the full test suite
(1378 tests) pass with no regressions.

**Update, 2026-07-01: the capture came back, and it refutes this plan's
central hypothesis.** See
[`20260701-structural-replacement-correlation-merges-distinct-startup-windows.md`](20260701-structural-replacement-correlation-merges-distinct-startup-windows.md).
Two real cold-start captures, taken using the Phase 1 instrumentation above,
show the affected pids' very first `kAXWindowsAttribute` query already
returning every window id the app actually had — `newContext=true` queries
came back complete, and `ax_window_count_mismatch` never fired in either
capture. What actually happens is downstream of the AX query: the full
rescan's structural-replacement correlation
(`rekeyStructuralManagedReplacementIfNeeded`,
`Sources/Nehir/Core/Controller/AXEventHandler.swift:837`) matches a brand-new
candidate against a *different, still-live* window admitted earlier in the
**same rescan pass**, because every one of an app's just-opened windows
shares an identical pre-layout default frame and the matcher does not
distinguish "a live entry from this very pass" from "a genuinely
destroyed-and-recreated window." Several distinct real windows get silently
rekeyed into one managed token — and, in one of the two captures, the loss
was not transient: the same windows were still unmanaged ~20 seconds later
with no recovery event of any kind.

**Phases 2-4 of this plan, as designed, would not fix what the capture
shows.** Re-querying `kAXWindowsAttribute` after admission (this plan's
proposed fix) would return the same complete id list a second time — it
already does, per the capture — and the structural-replacement correlation
would re-collapse them identically, since nothing about a second query
changes the shared startup frame the candidates collapse on. This plan's
instrumentation (Phase 1) remains useful and stays in place, but the design
in "Design: confirm-after-admission for newly-created AX contexts" above
needs to be revisited against the new discovery before Phase 2 proceeds — the
real fix surface is the same-pid structural-replacement matcher, not an
AX re-query.

**Fix landed, 2026-07-01, targeting the actual root cause instead of this
plan's original design.** `structuralReplacementMatch`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:3789`, called from
`rekeyStructuralManagedReplacementIfNeeded` and
`structuralReplacementWorkspaceIdForCreate`) now takes an `admittedThisPass:
Set<WindowToken>` parameter and excludes those tokens from its same-pid match
search. Both admission-pass callers —
`LayoutRefreshController.buildFullRefreshExecutionPlan()`'s full-rescan loop
and `WMController.reevaluateWindowRules`'s per-token loop — now track every
token they admit (fresh or via a completed structural rekey) in a
pass-scoped set and pass it through, so a candidate can never get merged into
a sibling admitted earlier in the very same pass; genuine cross-pass
replacement (an already-tracked entry from a prior pass being destroyed and
recreated) is unaffected. `prepareCreateCandidate`'s single-window create
path passes an empty set (no batch to exclude). A regression test,
`fullRescanDoesNotMergeDistinctSamePidWindowsSharingStartupFrame`
(`Tests/NehirTests/AXEventHandlerTests.swift`), reproduces the discovery's
two-same-pid-window-in-one-pass shape and was confirmed to fail without the
fix (timeout waiting for both entries; only one of the two windows ends up
managed) and pass with it. Full test suite (1379 tests) passes. Implemented
on the same branch as Phase 1, on top of it, merged to `main` as part of
PR #126.

This closes the concrete defect both discoveries observed. What remains
optional/unresolved: whether this plan's original confirm-after-admission
design is still worth doing as defense-in-depth for a genuine partial
`kAXWindowsAttribute` result (a scenario neither capture actually
demonstrated — see "Unknowns" below) — that would need its own future
capture showing a real partial-query case before it's worth building.

**Validated against a third, higher-multiplicity capture, 2026-07-01.** A
follow-up cold-start capture (VS Code Insiders and Helium each already open,
version header confirming the fix commit) showed AX reporting 10 windows for
one pid and 11 for the other on the very first query — more windows than
either original discovery or the earlier two validation captures exercised.
All 21 windows ended up as distinct managed entries (`windows total=21` at
capture end, matching 10 + 11 exactly); "Visible Unmanaged WindowServer
Windows" was empty at capture end; no `ax_window_count_mismatch` fired
(consistent with the AX query never having been the gap). This confirms the
fix generalizes beyond the 5-window/8-window shapes the original discoveries
captured.

Before merge, review also caught and fixed: a new `nehir-original` file
(`Sources/Nehir/Core/Ax/AXWindowsQueryTrace.swift`) had picked up the default
`upstream-derived` provenance header and was reclassified in
`.provenance.json`; the shared AX-windows-query trace ring let frequent
`queryResult` entries evict the rarer `countMismatch` diagnostic, fixed by
splitting them into independently-capped buffers; `WindowAdmissionContext
.unspecified` was given an explicit raw value; and the regression test above
was strengthened to assert the two admitted entries have distinct handles
(not just distinct window ids), following the reference-identity pattern
`browserReplacementDoesNotCoalesceAmbiguousMultipleCreates` already used
elsewhere in the same file.

---

A single per-app `kAXWindowsAttribute` query — used by both the startup/full-
rescan path and the targeted pid-reevaluation path — can return fewer windows
than an app actually has. Nehir treats that first answer as final: it never
re-checks whether the app has more windows than it just reported, so the
missing windows sit in "Visible Unmanaged WindowServer Windows" until some
unrelated event (a focus change on the missing window itself, or a CGS
`.created` for an unrelated auxiliary surface on the same pid) incidentally
triggers a fresh query that happens to return the complete list.

This plan covers two companion discoveries that show the same defect with two
different recovery shapes:

- [`20260701-startup-full-rescan-under-enumerates-multi-window-app.md`](20260701-startup-full-rescan-under-enumerates-multi-window-app.md) —
  VS Code Insiders, 2 of 3 windows missing after the **startup full rescan**,
  recovered one at a time via **per-window focused admission** (staggered,
  single-column pop-in).
- [`20260630-visible-unmanaged-windows-admitted-late-as-columns.md`](20260630-visible-unmanaged-windows-admitted-late-as-columns.md) —
  Helium, 2 of 3 windows missing, recovered together via a **pid-scoped
  reevaluation** triggered by an unrelated auxiliary-window create on the same
  pid (batched, multi-column pop-in).

Both discoveries conclude (with the caveats noted in each) that this is most
likely one underlying defect — an incomplete `AppAXContext.getWindowsAsync()`
result being trusted as complete — with the difference in symptom shape fully
explained by which incidental event happens to touch the pid next. This plan
treats it as one defect with one fix surface.

All source references verified against the main Nehir source tree at
`472f7185` on 2026-07-01 (`git log -1 --format='%h %s' main`). Line numbers
will drift; functions are named so they remain findable.

---

## TL;DR

- **Symptom.** A multi-window app can have real, on-screen, AX-owned windows
  sit unmanaged for seconds after they should have been admitted — at startup,
  or any time a per-app AX query runs while that app's window list hasn't
  fully settled.
- **Root cause.** `AppAXContext.getWindowsAsync()`
  (`Sources/Nehir/Core/Ax/AppAXContext.swift:378`) is queried exactly once per
  admission pass (full rescan: `AXManager.fullRescanEnumerationSnapshot()`,
  `Sources/Nehir/Core/Ax/AXManager.swift:451`; targeted reevaluation:
  `WMController.reevaluateWindowRules`'s `.pid` branch,
  `Sources/Nehir/Core/Controller/WMController.swift:3888-3903`). Whatever it
  returns is treated as the complete window list for that pid. There is no
  re-check, no comparison against the WindowServer-level window count for the
  same pid, and no scheduled follow-up query.
- **A near-miss already exists in the code.** `scheduleAXContextWarmup`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1278-1295`) already
  calls `controller.axManager.windowsForApp(app)` after every create-admission
  — but discards the result (`_ = await controller.axManager.windowsForApp(app)`).
  It exists purely to warm the per-app AX context/cache, not to catch windows
  the prior query missed. This is the natural seam to extend.
- **Fix direction.** After any admission pass that creates a *new* per-app AX
  context (i.e. the app wasn't already tracked before this pass), schedule one
  short-delay confirmation re-query for that pid. If the re-query returns
  window ids not present in the pass that just ran, route them through the
  normal create-candidate pipeline immediately — closing the gap without
  waiting for an incidental focus/create event to do it by accident.

---

## Problem statement

Nehir's admission pipeline assumes a per-app AX windows query is a complete,
authoritative snapshot. Two independent captures show this assumption failing
for Electron-style multi-window apps (VS Code Insiders, Helium) whose AX
window bookkeeping had not fully settled at the moment Nehir queried it — most
plausibly because `AppAXContext.getOrCreate` was still spinning up that pid's
dedicated AX thread/observer (up to a 2s budget,
`Sources/Nehir/Core/Ax/AppAXContext.swift:184`) under concurrent AX-subsystem
load (multiple apps' contexts being created at once, which is exactly what
happens at cold start with several apps already running).

The two captures differ only in *what touches the pid next*:

- A focus event on the specific missing window → `admitFocusedWindowBeforeNonManagedFallback`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:2199`) admits it alone.
- A CGS `.created` for an unrelated surface on the same pid →
  `scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid)])` (multiple call
  sites in `AXEventHandler.swift`) → `WMController.reevaluateWindowRules`'s
  `.pid` branch re-queries the whole pid and admits everything missing at
  once.

If neither of those incidental triggers happens to fire, the missing windows
apparently stay unmanaged indefinitely — there is no scheduled retry absent
one of these triggers, and the `Visible Unmanaged WindowServer Windows` debug
dump (the only place this is currently visible to a user/developer) requires
manually starting a runtime trace capture to see it.

---

## Design: confirm-after-admission for newly-created AX contexts

### Where to hook the confirmation

`AppAXContext.getOrCreate` (`Sources/Nehir/Core/Ax/AppAXContext.swift:145`)
already distinguishes "context already existed" (`contexts[pid]` hit, line
148) from "context was just created" (falls through to `createContext`). Both
`AXManager.fullRescanEnumerationSnapshot()` and the `.pid` branch of
`reevaluateWindowRules` call `getOrCreate` (directly or via `windowsForApp`)
before querying windows. The fix should key off **"was this pid's AX context
newly created during this pass"** — that is precisely the condition under
which the very first `kAXWindowsAttribute` query is least trustworthy (the
underlying app/AX bookkeeping may not have settled yet), and the condition
that does **not** apply to a pid whose context has been alive and queried
successfully many times before.

Concretely: surface a `wasNewlyCreated: Bool` out of `getOrCreate` (or have
the caller check `contexts[pid] == nil` immediately before calling it — same
information, smaller diff), and thread it back through
`AXManager.fullRescanEnumerationSnapshot()`'s per-app task group and through
`reevaluateWindowRules`'s `.pid` branch, collecting the set of pids whose
context was newly created during this pass.

### What the confirmation pass does

For each pid in that "newly created this pass" set, after the admission pass
finishes applying its results (so the workspace already reflects whatever was
admitted), schedule one delayed re-query — reusing the existing
`scheduleAXContextWarmup` seam
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:1278`) rather than adding
a parallel mechanism:

```swift
// sketch — not final
private func scheduleAXContextConfirmation(for pid: pid_t, admittedWindowIds: Set<Int>) {
    Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(500))   // let AX bookkeeping settle
        await self?.confirmAXWindowList(for: pid, previouslyAdmitted: admittedWindowIds)
    }
}

private func confirmAXWindowList(for pid: pid_t, previouslyAdmitted: Set<Int>) async {
    guard let controller, let app = NSRunningApplication(processIdentifier: pid) else { return }
    let windows = await controller.axManager.windowsForApp(app)
    let newIds = Set(windows.map { $0.2 }).subtracting(previouslyAdmitted)
    guard !newIds.isEmpty else { return }
    // route through the existing reevaluation entry point — do not duplicate
    // admission logic here.
    scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid)])
}
```

The delay (sketch: 500ms) should be tuned against repeat captures (see
"Unknowns" in both discoveries) — long enough that a genuinely-settling AX
context has stabilized, short enough that the user doesn't perceive a window
"popping in" as a separate, jarring event from normal admission. Reusing
`scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid)])` for the actual
admission (rather than hand-rolling it in the confirmation helper) means the
fix gets the existing `.pid` branch's correctness for free — including its
existing handling of `managedEntries`, `tokensToReevaluate`, and the
disposition/rule evaluation per window
(`Sources/Nehir/Core/Controller/WMController.swift:3860-3908` onward).

### Why not just always re-query every pid after every full rescan

That would double full-rescan cost for every app on every startup/unlock/space
change, for a condition that (per both discoveries) is specific to *newly
created* AX contexts. Scoping the confirmation to pids whose context was
created during this very pass keeps the fix proportional to the actual risk
window — an app that has been running and tracked for a while has already
proven its `kAXWindowsAttribute` answers are stable, and does not need a
confirmation pass.

### Why not extend `scheduleAXContextWarmup` itself instead of adding a new helper

`scheduleAXContextWarmup` runs after **every** create-admission, for the pid
of the window that was just admitted — including pids that were already
tracked before. Wiring "diff against previously admitted ids and reconcile if
new ones appear" into it directly would work for the create-triggered path,
but would not cover the **startup full-rescan** case, where no individual
create event ever fires for the missing windows (they were never separately
"created" from Nehir's point of view — they were just absent from the rescan's
result). The full-rescan path needs its own hook into "was this pid's context
newly created during this pass," which `scheduleAXContextWarmup`'s call sites
do not have visibility into (they're called per-window, after a single
window's admission, not per-rescan-pass).

---

## Implementation plan

### Phase 1 — Instrumentation first (per both discoveries' "tracing improvements") — implemented, see Status above

Before changing admission behavior, add the diagnostics both discoveries
identify as missing, so the fix can be verified against a capture instead of
inferred:

1. Log the raw `kAXWindowsAttribute` result (window id list, not just count)
   every time `AppAXContext.getWindowsAsync()` returns, tagged with whether
   the AX context was newly created for this call.
2. In `AXManager.fullRescanEnumerationSnapshot()`, cross-check the per-pid AX
   window count against the WindowServer/CGWindowList on-screen window count
   for the same pid (data already available via `SkyLight.shared.queryAllVisibleWindows()`
   and `CGWindowListCopyWindowInfo`, both already called in this function);
   trace any mismatch as `ax_window_count_mismatch pid=… ax=N windowServer=M`.
3. Add admission context (`startup_full_rescan` / `pid_reevaluation` /
   `focused_admission` / `ax_context_confirmation`) to the reconcile
   `windowAdmitted` event (`Sources/Nehir/Core/Reconcile/WMEvent.swift:20-26`,
   `:172-173`) — already proposed independently in the Helium discovery.

Deliverable: a capture of the startup-rescan scenario that directly shows
`ax_window_count_mismatch pid=54505 ax=1 windowServer=3` (or whatever the true
numbers are) at the moment the startup rescan ran, confirming or refuting this
plan's central hypothesis before behavior changes.

### Phase 2 — Track "newly created AX context" per admission pass

- Surface whether `AppAXContext.getOrCreate` created a new context vs. reused
  an existing one (smallest change: check `contexts[pid] == nil` at the call
  site immediately before calling `getOrCreate`, since the dictionary check
  and the call happen on the same actor).
- Thread a `Set<pid_t>` of "newly created this pass" pids out of
  `AXManager.fullRescanEnumerationSnapshot()` (extend `FullRescanEnumerationSnapshot`
  alongside its existing `failedPIDs`) and out of `reevaluateWindowRules`'s
  `.pid` branch.

### Phase 3 — Schedule and wire the confirmation pass

- Add `scheduleAXContextConfirmation(for:admittedWindowIds:)` (see sketch
  above) to `AXEventHandler`, called once per newly-created-context pid after
  `buildFullRefreshExecutionPlan` and after the `.pid` branch of
  `reevaluateWindowRules` finish applying their results.
- Confirmation re-queries via `controller.axManager.windowsForApp(app)` (the
  same call `scheduleAXContextWarmup` already makes) and, if new ids are
  found, routes them through `scheduleWindowRuleReevaluationIfNeeded(targets:
  [.pid(pid)])` — reusing the existing, tested admission path rather than
  duplicating it.

### Phase 4 — Verify against both discoveries' scenarios

- Re-run (or script) the VS Code Insiders cold-start scenario; confirm `3922`
  and `2194` are admitted via `ax_context_confirmation` shortly after startup,
  not 7 seconds later via an incidental focus event.
- Re-run (or script) the Helium scenario; confirm `3416`/`6537` are admitted
  via `ax_context_confirmation` rather than waiting for the auxiliary `6814`
  create.
- Confirm a normal single-window app's startup admission is unaffected (no
  spurious confirmation re-query latency perceptible, since its first query
  was already complete).

---

## Tests

- **Confirmation catches a partial first query.** Mock `AppAXContext` (test
  seam already exists per `contextFactoryForTests`,
  `Sources/Nehir/Core/Ax/AppAXContext.swift:161`) to return 1 window on the
  first `getWindowsAsync()` call for a pid and 3 windows on a second call.
  Assert: after the confirmation delay, the other 2 windows are admitted
  without any focus or create event being injected.
- **No confirmation for already-tracked pids.** A pid whose AX context already
  existed before a full rescan does not get a confirmation re-query scheduled
  (assert call count / scheduled-task absence).
- **Confirmation is idempotent / no duplicate admission.** If the confirmation
  re-query returns the same windows already admitted (no partial-query case),
  no reevaluation is scheduled and no duplicate `window_admitted` event fires.
- **Existing full-rescan and `.pid`-reevaluation behavior unchanged** for the
  non-partial-query case (regression guard — reuse existing rescan/reevaluation
  tests).

---

## Acceptance criteria

- A multi-window app whose first per-app AX query returns fewer windows than
  it actually has gets the rest admitted within one confirmation-delay window
  (sketch: ~500ms) of the originating admission pass, without requiring an
  incidental focus or create event on that pid.
- The confirmation pass does not add a recurring re-query cost for pids whose
  AX context was not newly created during the pass that triggered it.
- Both discoveries' captured scenarios (VS Code Insiders startup,
  Helium late pop-in) are closed: re-running them shows admission via
  `ax_context_confirmation`, not via the previously-incidental triggers.

---

## Risks and mitigations

- **False positives from a genuinely transient extra window.** A confirmation
  re-query 500ms later could catch a window that was legitimately created and
  destroyed in between (e.g. a real CGS create/destroy pair unrelated to the
  original partial-query bug). Mitigation: routing through
  `scheduleWindowRuleReevaluationIfNeeded` reuses the existing disposition
  logic (`evaluateWindowDisposition`), which already handles "window no longer
  resolves" by removing rather than admitting — no special-casing needed here.
- **Confirmation delay tuning.** Too short risks re-querying before the AX
  context has actually settled (same partial-result risk, just shifted later);
  too long makes the pop-in visibly delayed rather than eliminated. Mitigation:
  Phase 1's instrumentation should be used to measure actual settle time
  across several cold starts before fixing the delay constant.
- **Scope creep into `AppAXContext` internals.** The temptation is to "fix" AX
  context creation itself (e.g. block until `kAXWindowsAttribute` is stable
  across two consecutive reads). That changes lower-level, widely-shared
  machinery and risks regressing every other admission path. Prefer the
  confirmation-pass approach above, which is additive and scoped to the
  specific newly-created-context window.

---

## Unknowns (inherited from both discoveries, not yet resolved by this plan)

- Actual settle-time distribution for `kAXWindowsAttribute` on a newly created
  `AppAXContext`, across different apps and cold-start loads — needed to pick
  the confirmation delay with confidence rather than a guess.
- Whether this can recur for an app that has been running (and already
  confirmed once) for a long time — e.g. after a window-server-level state
  change that doesn't go through `AppAXContext.getOrCreate`'s "newly created"
  branch at all. If repeat captures show this, the "newly created context
  only" scoping in Phase 2 would need to widen — Phase 1's instrumentation
  should be left in place to catch this scenario if it occurs.
