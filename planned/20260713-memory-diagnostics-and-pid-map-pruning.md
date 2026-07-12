# Memory diagnostics in runtime dumps and trace captures, plus pid-map pruning

## Overview

Add process-memory diagnostics to the runtime state dump so every trace
capture and background clip records how much memory Nehir uses and which
diagnostic/state containers hold how many entries. Two captures taken hours
apart then show whether (and where) memory grows, without attaching external
tools. Additionally, close the one genuinely unbounded-over-uptime structure
found during discovery: the pid-keyed "recent activity" maps in
`AXEventHandler` that are never pruned when an app terminates.

## Context (from discovery)

Live measurement of a debug build running 7.5 h under real use
(`--nehir-trace`):

- `phys_footprint` 55 MB, peak 60 MB; dominant category MALLOC_SMALL 41 MB
  (dirty). RSS ≈ 102 MB.
- `leaks` reported 343 leaks / 24 KB total — all rooted in Apple frameworks
  (AppIntents/`com.apple.linkd.autoShortcut` XPC cycles, a SwiftUI-internal
  `ContextMenuResponder.AppKitMenuDelegate` cycle ≈ 15 KB). No Nehir-owned
  leak roots.
- Codebase audit: per-window state in `AXManager`
  (`lastAppliedFrames`, `pendingFrameWrites`, `recentFrameWriteFailures`,
  `retryBudgetByWindowId`, observer maps) is pruned on window removal and
  rekey (`Sources/Nehir/Core/Ax/AXManager.swift:336-403`). Trace ring buffers
  are capped (`recentFrameApplyTrace` at 200,
  `RuntimeDiagnosticsCoordinator` per-category records at 400,
  `ReconcileTraceRecorder` at 256, `createFocusTrace` /
  `managedReplacementTrace` capped in
  `Sources/Nehir/Core/Controller/AXEventHandler.swift:1400,1431`).
  `AppAXContext.contexts` is pruned per pid
  (`Sources/Nehir/Core/Ax/AXManager.swift:760`).
- **Gap:** `cleanupFocusStateForTerminatedApp(pid:)`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:7065`) removes only
  `recentManagedWorkspaceByPid` and `recentAppActivationByPid`. These sibling
  maps (`Sources/Nehir/Core/Controller/AXEventHandler.swift:873-899`) keep
  entries for terminated pids forever (entries are TTL-guarded on read but
  never deleted):
  - `recentSameAppWindowCloseByPid`
  - `recentNonManagedFocusByPid`
  - `focusedWindowLossClosePrecursorByPid`
  - `sameAppRecoveryRedirectLatches` (key contains a pid)
  - `parkedFollowHoldByPid`
  - `recentParkedFocusFollowByToken` / `recentManagedAdmissionByToken`
    (token contains a pid; entries for dead windows linger)
- Integration point: `RuntimeDiagnosticsCoordinator.runtimeStateDebugDump()`
  (`Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift:724`)
  already aggregates per-subsystem debug snapshots and is embedded in every
  runtime trace capture (state at start + end) and every background clip
  export, so a new section there automatically lands in all trace artifacts.

## Development Approach

- Testing approach: **regular** (code first, then tests), per
  `docs/TESTING.md`: new tests go in small per-behavior files; never append
  to frozen monoliths (`AXEventHandlerTests.swift`, `AXManagerTests.swift`,
  …); test hooks observe, they do not decide.
- Fast gate between tasks: `mise run build` (plus targeted test run). Full
  gate once at the end: `mise run check`.
- Complete each task fully before the next; keep changes small and focused.

## Solution Overview

1. A small `ProcessMemoryDiagnostics` helper reads the process's own
   `task_vm_info` (`phys_footprint`, `ledger_phys_footprint_peak`,
   `resident_size`) via `task_info(mach_task_self_, …)` — the same numbers
   `footprint(1)` reports — and formats one summary line.
2. A new `-- Memory --` section in `runtimeStateDebugDump()` prints that
   line plus entry counts for the diagnostic/state containers that are not
   already surfaced (the AXManager counters already appear in the
   `-- AXManager --` section; do not duplicate them):
   - `AXEventHandler`: sizes of every pid-/token-keyed map listed above,
     `createPlacementContextsByWindowId`, `deferredCreatedWindowOrder`,
     pending task maps (`pendingManagedReplacementTasks`,
     `pendingNativeFullscreenFollowupTasks`, `pendingWindowStabilizationTasks`,
     …), and trace array lengths.
   - `LayoutRefreshController`: `pendingRevealTransactionsByWindowId`,
     `pendingRevealVerificationTasksByWindowId`,
     `delayedParkReverifyTasksByWindowId` /
     `delayedParkReverifyAttemptsByWindowId`,
     `lastStableHideReconciliationUptimeByWorkspace`, display-link map sizes.
   - `AppAXContext.contexts` count (and in-flight creations count).
   - `WorkspaceManager`: tracked entry count if not already in its summary.
   Counters are exposed through per-subsystem `memoryDebugSnapshot()`
   structs/methods (observation only — no behavior change), mirroring the
   existing `windowStateDebugSnapshot()` pattern in
   `Sources/Nehir/Core/Ax/AXManager.swift`.
3. Extend `cleanupFocusStateForTerminatedApp(pid:)` to prune all pid-keyed
   maps for the terminated pid, and drop token-keyed entries whose
   `token.pid` matches.

Not in scope (deliberately): a periodic background memory sampler. The
start/end dumps in every capture plus background-clip exports already give
before/after deltas; add sampling later only if a real investigation needs a
continuous trend.

## Technical Details

- Footprint read: `task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), …)`
  with `task_vm_info_data_t`; use `TASK_VM_INFO_REV1_COUNT`-aware `count` so
  `ledger_phys_footprint_peak` is populated when available. Pure function,
  no state; returns a struct of byte counts plus a `formattedLine` like
  `footprint=55.2MB peak=60.1MB resident=102.4MB`.
- New section renders near the top of the dump (after the trace-capture
  status line) as:
  `-- Memory --` / `<footprint line>` /
  `axEventHandler recentManagedWorkspaceByPid=N recentAppActivationByPid=N …` /
  `layoutRefresh pendingRevealTransactions=N …` / `appAXContexts=N inFlight=N`.
- Pruning uses the existing termination path only — no new timers. The
  token-keyed maps are swept with `filter { $0.key.pid != pid }` semantics.

## Do-not-touch fences

- Do not modify `BackgroundTraceBuffer` internals or trace file formats
  beyond adding lines to the runtime-state dump body.
- Do not touch the frozen test monoliths listed in `docs/TESTING.md`.
- Do not change any reconciliation/lifecycle decision logic; every new
  accessor is observational. The only behavior change is the pruning in
  `cleanupFocusStateForTerminatedApp(pid:)`.
- No changes under `Sources/NehirIPC/` (no new IPC surface in this plan).

## Implementation Steps

### Task 1: ProcessMemoryDiagnostics helper

**Files:**
- Create: `Sources/Nehir/Core/Diagnostics/ProcessMemoryDiagnostics.swift`
- Create: `Tests/NehirTests/ProcessMemoryDiagnosticsTests.swift`

- [ ] implement `ProcessMemoryDiagnostics.current()` reading `task_vm_info`
      for the current process (footprint, peak, resident)
- [ ] implement `formattedLine` with MB formatting; nil-safe when the
      `task_info` call fails (report `footprint=unavailable`)
- [ ] tests: `current()` returns nonzero footprint for the test process;
      `formattedLine` renders expected keys; formatting of a known byte
      value
- [ ] gate: `mise run build` + run the new test file — must pass before
      task 2

### Task 2: Container-size snapshots and `-- Memory --` dump section

**Files:**
- Modify: `Sources/Nehir/Core/Controller/AXEventHandler.swift` (add
  observational `memoryDebugSnapshot()` returning named counts)
- Modify: `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`
  (same pattern)
- Modify: `Sources/Nehir/Core/Ax/AppAXContext.swift` (static counts accessor)
- Modify: `Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift`
  (render `-- Memory --` section in `runtimeStateDebugDump()`)
- Create: `Tests/NehirTests/RuntimeMemoryDumpSectionTests.swift`

- [ ] add `memoryDebugSnapshot()` to `AXEventHandler` covering the maps and
      trace arrays listed in Solution Overview
- [ ] add `memoryDebugSnapshot()` to `LayoutRefreshController`
- [ ] add `AppAXContext` context/in-flight counts accessor
- [ ] render `-- Memory --` section (footprint line + counters) in
      `runtimeStateDebugDump()`
- [ ] tests: dump output contains the `-- Memory --` header, the footprint
      key, and each subsystem counter line; counter snapshot reflects a
      known populated state (populate via existing test seams, not new
      decision-changing hooks)
- [ ] gate: `mise run build` + targeted tests — must pass before task 3

### Task 3: Prune pid-keyed maps on app termination

**Files:**
- Modify: `Sources/Nehir/Core/Controller/AXEventHandler.swift`
  (`cleanupFocusStateForTerminatedApp(pid:)`)
- Create: `Tests/NehirTests/TerminatedAppStatePruningTests.swift`

- [ ] extend `cleanupFocusStateForTerminatedApp(pid:)` to remove entries for
      the pid from `recentSameAppWindowCloseByPid`,
      `recentNonManagedFocusByPid`, `focusedWindowLossClosePrecursorByPid`,
      `sameAppRecoveryRedirectLatches`, `parkedFollowHoldByPid`
- [ ] sweep `recentParkedFocusFollowByToken` and
      `recentManagedAdmissionByToken` for tokens whose `pid` matches
- [ ] tests: seed the maps (via existing test seams), invoke termination
      cleanup, assert entries for the dead pid are gone and entries for
      other pids survive
- [ ] gate: `mise run build` + targeted tests — must pass before task 4

### Task 4: Verify acceptance criteria and full gate

- [ ] run a debug build, trigger a runtime state dump, and confirm the
      `-- Memory --` section appears with plausible values; start/stop a
      trace capture and confirm both embedded dumps include it
- [ ] full suite: `mise run check`
- [ ] changeset: `mise run changeset none "Runtime state dumps and trace
      captures now include process memory diagnostics"` (developer-facing
      diagnostics; use `patch` instead if the pruning fix is judged
      user-visible)

### Task 5: Housekeep

- [ ] update this plan's checkboxes; note any deviations inline
- [ ] move this plan to `completed/` on the plans branch once merged

## Commit message shape

Plain English, no Conventional Commits prefixes. Reference only nehir's own
ticket numbers (bare `#nnn`), never upstream. Suggested subjects:

- `Add memory diagnostics section to runtime state dumps`
- `Prune per-pid focus state when an app terminates`

## Post-Completion

- Compare `-- Memory --` sections from two captures taken hours apart during
  normal use to validate the counters stay flat; if a counter climbs, open a
  new discovery for that subsystem.
- If long-horizon trend data ever becomes necessary, a follow-up plan can add
  a low-frequency sampler writing into the background trace buffer as a new
  `BackgroundTraceCategory`.
