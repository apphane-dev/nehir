# Focus-Guard & Monitor-Topology Fragility — Discovery

Groom 2026-07-07: still applicable — monitor-and-harden finding; WMController narrowing shipped (776b9559) but the four-way focus-guard coordination point remains implicit and its tests/diagram/clock-unification are not landed (verified against main 7a025b78).

Discovery (2026-06-14) expanding review finding #9 ("fragility is concentrated where
recent commits already point"). It is a **monitor-and-harden** finding, not a
"rewrite the three big files" finding: the riskiest code already got the two
highest-leverage centralizations shipped (#41 `WindowVisibility`, #43 central
refresh routing). What remains fragile is a **four-way coordination point** that
those centralizations left implicit, plus a **monitor-attach/detach path** that
threads all three large files through one runtime seam. This doc maps both,
cites the code, lists concrete failure modes, and scopes cheap guards vs. the
expensive refactor.

All file references should be re-verified before implementing; line numbers drift.

---

## TL;DR

- **Three files own almost all churn risk.** `AXEventHandler.swift` (~3,793 LOC),
  `LayoutRefreshController.swift` (~3,583 LOC), and `WorkspaceManager.swift`
  (~4,000 LOC) — with `WMController.swift` (~3,670 LOC, 193 funcs) as the
  orchestrator that fans out to all three.
- **One runtime path exercises all of them at once**: monitor attach/detach
  (`DisplayConfigurationObserver` → `ServiceLifecycleManager` →
  `WorkspaceManager.recordTopologyChange` → `LayoutRefreshController` rescan +
  AX frame invalidation). Every multi-monitor commit since #28 has been a fix
  *along this path*.
- **The delicate coordination point is a four-way handshake for window
  close/collapse focus**, where four independently-maintained pieces must agree:
  1. **same-PID activation suppression** (`AXEventHandler`)
  2. **hidden-reason tracking** (`WindowModel.WindowVisibility`, migrated in #41)
  3. **focus lease** (`FocusPolicyEngine`, owner `.windowCloseFocusRecovery`)
  4. **previous-workspace memory** (`WorkspaceManager.SessionState.previousVisibleWorkspaceId`)
  Nothing makes the *combined* invariant explicit; each piece is correct in
  isolation, the composition is not encoded.
- **Testing gap is real and specific.** The same-PID path has 4 tests; the lease
  engine is tested generically; but the **`windowCloseFocusRecovery` owner
  lifecycle** (its 0.6 s expiry context + cross-workspace suppression) and the
  brand-new **`WindowVisibility` enum** both have **zero direct test references**.
- **Lean: harden, don't split.** Add targeted tests + one invariant doc/diagram +
  a couple of seams (see [Recommendations](#recommendations)). A big-bang split
  of the three files is high-risk, low-value versus what #41/#43 already bought.

---

## The three files and what they own

| File | LOC | Primary concerns woven together |
|---|---|---|
| `Sources/Nehir/Core/Controller/AXEventHandler.swift` | ~3,793 | CGS/window lifecycle (created/destroyed/closed/frame/frontApp), app-activation routing + same-PID suppression, window-close focus recovery lifecycle, native-fullscreen replacement, create-placement context, window-rule reevaluation scheduling, managed-replacement title tracking. Both the *event ingress* and several *stateful recovery protocols* live here. |
| `Sources/Nehir/Core/Controller/LayoutRefreshController.swift` | ~3,583 | The refresh scheduler: 5 routes (`fullRescan`/`relayout`/`immediateRelayout`/`visibilityRefresh`/`windowRemoval`) × scheduling policies × coalescing × follow-up refreshes × close/reveal animations × per-monitor cleanup (`cleanupForMonitorDisconnect`). Centralized in #43; route table now lives in `RefreshReason.swift`. |
| `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` | ~4,000 | Workspace/window identity & state (`WindowModel`), session state (focus, interaction monitor, **`previousVisibleWorkspaceId`**), monitor topology resolution, topology-change planning (`recordTopologyChange` → `RestorePlanner`), disconnected-visible-workspace cache + restore, workspace ordering, native-fullscreen records, persisted-restore catalog. |

`WMController.swift` (~3,670 LOC, 193 funcs) is the intentional orchestrator that
holds back-references to all three and is the subject of the separate
finding #7 ("narrow WMController's public surface") and its own plan
(`planned/20260614-narrow-wmcontroller-public-surface.md`).

---

## The single path that exercises all three: monitor attach/detach

Every display change runs this chain, and every multi-monitor bug fix in the
recent log has been a patch somewhere along it:

```
NSApplication.didChangeScreenParametersNotification
  └─ DisplayConfigurationObserver  (Core/Monitor/, 100ms debounce)
        emits .connected / .disconnected / .reconfigured
       └─ ServiceLifecycleManager.handleDisplayEvent         (Controller, :126)
            ├─ .disconnected →
            │     • LayoutRefreshController.cleanupForMonitorDisconnect   ← file #2
            │     • niriEngine.cleanupRemovedMonitor
            └─ always → handleMonitorConfigurationChanged()
                  └─ applyMonitorConfigurationChanged(currentMonitors:)
                        • focusBorderController.hide()  (invalidate cache)
                        • WorkspaceManager.applyMonitorConfigurationChange ← file #3
                            └─ recordTopologyChange  (:515)
                                  • RestorePlanner.planMonitorConfigurationChange
                                  • applyTopologyTransition → SessionState mutate
                                  • restoreDisconnectedVisibleWorkspacesToHomeMonitors
                        • WMController.syncMonitorsToNiriEngine
                        • axManager.invalidateCachedFrameState()
                        • WorkspaceManager.clearGeometryHiddenStates()   ← interacts with WindowVisibility
                        • LayoutRefreshController.requestRefresh(.monitorConfigurationChanged)  ← file #2
```

Why this path is load-bearing for fragility:

- It **mutates session state** (`previousVisibleWorkspaceId`, interaction
  monitor, workspace assignments), **invalidates AX frame caches**, **clears
  geometry hidden-states**, and **forces a full rescan** — four different
  caches/state stores that the focus-guard logic reads from, all in one pass.
- It runs on a **100 ms debounce** (`DisplayConfigurationObserver`), so a single
  physical event can fire it multiple times and the intermediate states are
  observable by the AX event handler concurrently.
- It is the path most exposed to **hardware reality** (KVM switches, dock
  hot-plug, lid close, display-id reuse) — inputs the test suite can't easily
  simulate, which is why coverage here is thin despite the topology planner
  having 9 test references.

---

## The delicate coordination point: close/collapse focus-guard

When a managed window closes (or an app is hidden/collapsed), Nehir must (a)
not steal focus to a wrong window, (b) not let macOS's auto-reactivation pull
focus to a sibling window of the *same app* on an *inactive workspace*, and
(c) recover focus to a sensible target. Four mechanisms cooperate, each owned
by a different file:

### 1. Same-PID activation suppression — `AXEventHandler`
`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery` and
`shouldSuppressObservedActivationDuringWindowCloseRecovery` (AXEventHandler,
~`:1218` and `:1234`). Decides, per observed app activation, whether to drop it
based on the *current* border target, the confirmed managed-focus token, and
whether the activation matches an active managed request. Branches on
`ActivationRequestDisposition` (`.matchesActiveRequest` /
`.unrelatedNoRequest` / …) — a value computed elsewhere.

### 2. Hidden-reason tracking — `WindowModel.WindowVisibility`
`WindowModel.swift:54`. The enum landed in #41 (replacing a four-optional-field
state machine — review finding #5, marked done). `clearGeometryHiddenStates()`
during monitor change wipes the `layoutTransient` side; `workspaceInactive` /
`scratchpad` survive. The suppression logic in (1) reads visibility indirectly
via `confirmedManagedFocusToken` + entry lookup, so a stale visibility value
after a topology change silently changes the suppression verdict.

### 3. Focus lease — `FocusPolicyEngine`
`Sources/Nehir/Core/Reconcile/FocusPolicyEngine.swift`. A 4-owner priority table
(`nativeMenu` > `windowCloseFocusRecovery` > `nativeAppSwitch` >
`ruleCreatedFloatingWindow`), each lease with an optional expiry, pruned lazily
on read. `beginWindowCloseFocusRecovery` (AXEventHandler `:1179`) opens a
`.windowCloseFocusRecovery` lease with `suppressesFocusFollowsMouse: true` and a
**0.6 s duration** (`windowCloseFocusRecoveryDuration`, `:284`). The recovery
context (`WindowCloseFocusRecoveryContext`, `:207`) is a *separate* expiry
record from the lease — two clocks for the same logical "recovery window."

### 4. Previous-workspace memory — `WorkspaceManager.SessionState`
`WorkspaceManager.swift:144` (`previousVisibleWorkspaceId`), plus
`previousWorkspace(on:)` / `previousWorkspaceInOrder(on:)` (`:2296`, `:2311`)
and `previousInteractionMonitorId`. The "back" navigation and the recovery
target both read these; topology transitions mutate them
(`:3114`, `:3122`, `:3401`).

### Why the composition is the fragile part
Each mechanism is individually simple and individually tested. The fragility is
that **nothing asserts the combined invariant** — e.g., "if a
`.windowCloseFocusRecovery` lease is active then `windowCloseFocusRecoveryContext`
is non-nil and its workspace is on the active monitor" exists only as an
assumption shared across `beginWindowCloseFocusRecovery`,
`activeWindowCloseFocusRecoveryWorkspaceId`, and the two suppression predicates.
The lease expiry (0.6 s, pruned lazily on read) and the recovery-context expiry
(0.6 s, checked on read) are two independent clocks that today happen to share a
constant but have no enforced relationship. A topology change mid-recovery
clears geometry hidden-states and can move the workspace off its monitor without
closing the lease — exactly the window where (1) and (2) can disagree.

---

## Why recent commits cluster exactly here

The git log for these files is the bug list this discovery is about:

| Commit | What | Where it landed |
|---|---|---|
| `0ba91a7` | **window close focus recovery + cross-workspace same-app suppression** | AXEventHandler + FocusPolicyEngine (the coordination point itself) |
| `#41` `ec615dc` | `WindowVisibility` enum (replace `hiddenReason` 4-field state) | WindowModel — mechanism #2 |
| `#43` `984c536` | centralize refresh request routing | RefreshReason routing table — file #2 |
| `#44` `e3a6239` | viewport handling + lone-window policy | LayoutRefreshController + focus |
| `#45` `3254244` | resize minimum pinning (terminal cell quantization) | LayoutRefreshController |
| `#40` `ef6cd44` | workspace→monitor assignment after disconnect + revalidate | WorkspaceManager (the topology path) |
| `#36` `16a37f8` | workspace-bar positioning on attach/detach | the topology path |
| `#35` `306637d` | multi-monitor bug fixes | all three |
| `#28` `65a0fb2` | central projection-invalidation pipeline | feeds the topology path |
| `33518b5` / `e8dacfc` | focus-follows-mouse wrong target / warp suppression | AXEventHandler + FocusPolicyEngine |

That's the strongest signal in the data: **the same seam keeps getting patched.**
#41 and #43 were the structural centralizations; the rest are point fixes
along the coordination point and the topology path.

---

## Concrete failure modes at the seams

Each is plausible *given the code as written*; none are confirmed live bugs —
they are where to look first when a focus/visibility report comes in.

1. **Two-clock drift in close-focus recovery.** Lease pruned on next
   `evaluate()` read; recovery context pruned on next
   `activeWindowCloseFocusRecoveryWorkspaceId()` read. A read of the lease
   without a read of the context (or vice versa) during the 0.6 s window can
   produce a state where suppression predicate (1) sees no lease but the context
   is still "active," or the reverse. Outcome: focus either over-suppressed
   (feels stuck) or under-suppressed (focus jumps to a same-app sibling on a
   wrong workspace).
2. **Topology change mid-recovery.** `clearGeometryHiddenStates()` +
   `invalidateCachedFrameState()` during monitor change can change a window's
   effective visibility and its monitor, but the recovery context pins a
   `workspaceId` captured at close time. If that workspace is migrated to another
   monitor (`restoreDisconnectedVisibleWorkspacesToHomeMonitors`), the guard at
   the top of `beginWindowCloseFocusRecovery` (`activeWorkspace(on:)? == wsId`)
   was checked at *begin* time, not after the topology transition.
3. **Stale `confirmedManagedFocusToken` after rapid close→create.** The same-PID
   suppression in (1) keys off `confirmedManagedFocusToken`; if a new window is
   admitted for the same PID while recovery is still active, the disposition
   computation (`ActivationRequestDisposition`) has to correctly classify it as
   `.matchesActiveRequest` to *not* suppress — a regression here resurfaces the
   bug `33518b5`/`e8dacfc` fixed.
4. **`WindowVisibility` is brand new and unexercised by tests by name.** The
   enum is correct, but the migration from the old `HiddenReason`-product model
   changed how `clearGeometryHiddenStates` interacts with it (only
   `layoutTransient` clears; `workspaceInactive`/`scratchpad` persist). A future
   edit that adds a case or changes the clear semantics has no named test
   pinning the mapping.
5. **`windowDestroyed` route precondition.** `requestRefresh(reason:)` does
   `preconditionFailure` for `.windowRemoval` — callers must use
   `requestWindowRemoval`. A new `RefreshReason` routed to `.windowRemoval` that
   goes through `requestRefresh` crashes. (Mitigated by the routing-table
   completeness check `hasCompleteRoutingTable`, but only if a test calls it.)

---

## Testing gaps (grounded)

From grep of `Tests/`:

| Path | Direct test refs | Verdict |
|---|---|---|
| `windowCloseFocusRecovery` / `window_close_focus_recovery` owner + lifecycle | **0** | **Untested.** The recovery context, its 0.6 s expiry, and cross-workspace suppression during recovery have no test by name. |
| `WindowVisibility` enum | **0** | New in #41; no named coverage. Underlying `HiddenReason` behavior is covered transitively via `WorkspaceManagerTests`. |
| same-PID suppression (`shouldSuppressSameApp…`) | 4 (`WMControllerFocusTests` ×3, `AXEventHandlerTests` ×1) | Covered — the strongest-tested part of the coordination point. |
| `FocusPolicyEngine` lease begin/end/priority/expiry | yes (`ReconcileStateTests`) | Covered generically; `.windowCloseFocusRecovery` as an *owner* is not asserted. |
| Topology transition (`TopologyTransition`/`topologyChanged`/`applyMonitorConfigurationChange`) | 9 across many files | Covered at the planner/reducer level; the *full* observer→controller→refresh path is not simulated end-to-end. |
| `recordTopologyChange` restore cache (`disconnectedVisibleWorkspace…`) | yes (`RestorePlannerTests`, `ReconcileStateTests`) | Planner covered; the `WorkspaceManager` apply side + interaction with `clearGeometryHiddenStates` is thinner. |

Test-file scale: `AXEventHandlerTests` 156 `@Test`s, `WorkspaceManagerTests` 57,
`LayoutRefreshControllerTests` 43. Coverage is genuinely strong overall (review
finding: ~1,170 test functions) — the gap is specifically the *composition*
lifecycle, not the components.

---

## Strengths / invariants already in place (don't erode)

These are why the recommendation is *harden*, not *refactor*:

- **Central refresh routing table** (`RefreshReason.swift:121`) with a
  `hasCompleteRoutingTable` completeness check — adding a reason is a one-place
  edit. Shipped in #43.
- **`WindowVisibility` makes illegal states unrepresentable** at the entry level
  — the four-optional product is gone. Shipped in #41.
- **`FocusPolicyEngine` is a closed priority table with lazy expiry pruning** —
  lease semantics are auditable in one ~150-line file.
- **Per-app AX threading** means a hung app can't stall the focus-guard path on
  the main thread.
- **Three-level window identity** (`WindowToken` → `WindowHandle` → `AXWindowRef`)
  keeps the coordination point reasoning about Sendable values, not raw AX
  handles.
- **Restore planner is decoupled** from the workspace manager — topology
  planning is testable in isolation, which is why it has the most coverage.

---

## Recommendations

Ordered by leverage-per-risk. None require splitting the three files.

### A. Tests pinning the recovery lifecycle (highest leverage, lowest risk)
Add tests that exercise the **composition**, not just the components:
1. Close the focused window → assert `.windowCloseFocusRecovery` lease is
   active, `windowCloseFocusRecoveryContext` is non-nil, same-workspace.
2. Advance the clock past 0.6 s → assert *both* the lease and the context are
   gone (pins the two-clock invariant).
3. During recovery, activate a same-PID window on an inactive workspace →
   assert suppression. On the *active* workspace → assert not suppressed.
4. Topology change (monitor disconnect of the recovery workspace's monitor)
   during recovery → assert lease is ended or context revalidated, not left
   dangling. (This is failure mode #2.)
5. Call `RefreshReason.hasCompleteRoutingTable` in a test so a missing route is
   a CI failure, not a runtime precondition.

### B. One invariant + one diagram (cheap, prevents the next regression)
Add to `docs/ARCHITECTURE.md` (review noted the handler back-reference pattern
and projection-invalidation pipeline aren't diagrammed — same gap):
- A **focus-guard state diagram**: the four mechanisms, who reads/writes each,
  and the asserted invariants across them (esp. the two-clock relationship and
  the "recovery workspace must be on the active monitor at *every* read, not
  just begin" rule).
- A **monitor-attach/detach sequence diagram** of the call chain above.

### C. Two small seams (medium leverage, low risk)
1. **Unify the recovery clock.** Make `windowCloseFocusRecoveryContext` the
   single source of truth and have the lease derive its expiry from it (or
   vice-versa) so failure mode #1 is structurally impossible, not conventionally
   avoided.
2. **Revalidate the recovery workspace on topology change.** In
   `applyMonitorConfigurationChanged` (or the topology transition apply), if a
   `.windowCloseFocusRecovery` lease is active and its workspace migrated,
   either end the recovery or re-anchor it to the new monitor. Today the begin
   guard runs once.

### D. Narrow WMController reach-through (already planned)
Finding #7 / `planned/20260614-narrow-wmcontroller-public-surface.md`. Do this
*before* adding a second layout paradigm or interactive mode; it directly
reduces how many call sites can poke the coordination point ad hoc.

### E. Big-bang split of the three files — **not recommended now**
The centralizations in #41/#43 already captured most of the value of a split.
Splitting `AXEventHandler` (event ingress vs. recovery protocols) or
`WorkspaceManager` (identity vs. topology vs. session) is a multi-week,
high-regression-risk refactor whose payoff is mainly readability. Defer until a
concrete feature (second layout engine, new interactive mode) forces the seam.

---

## Decisions pending

1. **Recovery-clock unification (C1).** Accept a small behavioral change to
   lease/context coupling now, or leave as-is and rely on A's tests to catch
   drift? Lean: do A first; if drift appears, do C1.
2. **Topology-during-recovery revalidation (C2).** Is the 0.6 s recovery window
   short enough that mid-recovery topology change is negligible in practice?
   Needs the failing test in A4 to answer.
3. **`WindowVisibility` named tests.** Worth adding pinning tests for the enum's
   mapping + `clearGeometryHiddenStates` interaction even though it's
   transitively covered? Lean: yes, it's cheap insurance on brand-new code.
4. **End-to-end monitor-attach/detach test.** The components are tested; the
   full observer→refresh path is not. Worth a simulated
   `didChangeScreenParametersNotification` harness? Lean: yes if multi-monitor
   bug reports continue; the path is the single most-patched seam.

---

## Files of record

- `Sources/Nehir/Core/Controller/AXEventHandler.swift` — event ingress + the
  close/collapse recovery protocol (`WindowCloseFocusRecoveryContext` `:207`,
  duration `:284`, `beginWindowCloseFocusRecovery` `:1179`, the two suppression
  predicates `:1218` & `:1234`).
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift` — refresh
  scheduler; `requestRefresh` routing `:661`,
  `cleanupForMonitorDisconnect` `:230`, `startWindowCloseAnimation` `:298`.
- `Sources/Nehir/Core/Controller/RefreshReason.swift` — central routing table
  `:121` (shipped #43), `hasCompleteRoutingTable` completeness check.
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` —
  `SessionState.previousVisibleWorkspaceId` `:144`, `confirmedManagedFocusToken`
  `:1038`, `recordTopologyChange` `:515`,
  `restoreDisconnectedVisibleWorkspacesToHomeMonitors` `:3458`,
  `applyMonitorConfigurationChange` `:2371`.
- `Sources/Nehir/Core/Workspace/WindowModel.swift` — `WindowVisibility` enum
  `:54`, `HiddenReason` `:8`, `HiddenState` `:97` (shipped #41).
- `Sources/Nehir/Core/Reconcile/FocusPolicyEngine.swift` — lease owner enum,
  priority table, lazy expiry pruning.
- `Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift` —
  `handleDisplayEvent` `:126`, `handleMonitorDisconnect`,
  `applyMonitorConfigurationChanged` (the fan-out point).
- `Sources/Nehir/Core/Monitor/DisplayConfigurationObserver.swift` — 100 ms
  debounce, connected/disconnected/reconfigured diffing.
- `Sources/Nehir/Core/Reconcile/RestorePlanner.swift` —
  `planMonitorConfigurationChange` (topology planning; well-tested).
- `Tests/NehirTests/WMControllerFocusTests.swift` — same-PID suppression tests
  (`:942`, `:1007`, `:1070`); the model for the recovery-lifecycle tests in A.
- `Tests/NehirTests/ReconcileStateTests.swift` — lease engine tests (`:217`+).
- `planned/20260614-narrow-wmcontroller-public-surface.md` — the related
  finding #7 plan; do this before adding layout paradigms/interactive modes.

## References

- `discovery/20260613-codebase-review-findings.md` — findings #5, #6,
  #7, #9, #10 (this doc expands #9; #5/#6 are marked done).
- `docs/ARCHITECTURE.md` — accurate; missing the focus-guard and
  projection-invalidation diagrams this doc recommends adding.
