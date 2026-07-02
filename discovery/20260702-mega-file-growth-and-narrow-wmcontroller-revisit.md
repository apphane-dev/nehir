# Mega-file growth and the narrow-WMController plan, revisited — Discovery

Extended discovery for improvement point #3 from the 2026-07-01 docs-grooming review:
"the four mega-files keep growing." Extends
[`20260613-codebase-review-findings.md`](20260613-codebase-review-findings.md) §7
(WMController surface) and §9 (fragility concentration), and revisits
[`../completed/20260614-narrow-wmcontroller-public-surface.md`](../completed/20260614-narrow-wmcontroller-public-surface.md)
against what actually happened in the two weeks after it shipped.

Verified against the main Nehir source tree at `705831f9` ("Address diagnostic and
gesture review feedback") on 2026-07-02. Line numbers drift; function names are
included so code stays findable.

---

## Status — two follow-ups shipped (verified against `main` on 2026-07-02)

Two of the actions proposed below have now landed on `main`:

- **Part 3 candidate #1 — WMController diagnostics/trace → `RuntimeDiagnosticsCoordinator`: DONE.**
  Shipped as `d1505910` ("Extract WMController diagnostics and trace surface into
  RuntimeDiagnosticsCoordinator"). `Sources/Nehir/Core/Controller/WMController.swift`
  dropped **5,031 → 3,921 LOC (−1,110)**; the extracted surface now lives in
  `Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift` (1,173 LOC). A
  privacy follow-up in that file also redacted the runtime-debug dump and the
  trace-export file paths in its `logger.info` sites (dump contents and export paths
  are now `privacy: .private`; the pasteboard/file-export flow is unchanged).
- **Part 4 follow-up #2 — `preferredFrame(for:)` query seam: DONE.** Shipped as
  `e87bade3` ("Add preferred-frame query seam for controller-layer node lookups").
  The implementer chose the `FocusCoordinator`-member option (not a separate
  `LayoutStateQuery` protocol): `preferredFrame(for token:) -> CGRect?` at
  `Sources/Nehir/Core/Controller/FocusCoordinator.swift:31`. The raw
  `renderedFrame ?? frame` reach-through is now gone from the controller layer
  (0 sites remain); surviving lookups go through
  `controller.focusCoordinator.preferredFrame(for:)`
  (`AXEventHandler.swift:4073`, `NiriLayoutHandler.swift:182`).
- **Still open:** `FocusCoordinator.focusedNode(for:)` still has **zero consumers** —
  the seam added `preferredFrame(for:)` as a sibling rather than reusing it, so the
  dead-member flag still stands (see
  [`completed/20260614-narrow-wmcontroller-public-surface.md`](../completed/20260614-narrow-wmcontroller-public-surface.md)).
  Candidates #2–#5 below remain unactioned.

The body below was verified against `main` at `705831f9`, i.e. *before* these two
commits; its measurements and line numbers are the pre-merge baseline.

## TL;DR

- The five biggest controller-layer files grew **21–79% since the initial import**
  and **~500–900 lines each in the last ten days alone**. Growth is not
  disorganization creeping in — it is cross-cutting feature families (sticky/PiP,
  workspace-bar behavior, diagnostics) each landing a slice in every file, because
  the files own the seams those features must touch.
- The narrow-WMController plan **worked and held**. Its boundaries survived two
  weeks of heavy feature traffic essentially intact: the `setNiriEngine` write
  funnel is still the only engine assignment, `CommandHandler` has **zero**
  `niriLayoutHandler` references (44 `layoutCoordinator` calls), and
  `LayoutCoordinator` got *semantically narrower* (the `withNiri*`/`activateNode`
  escape hatches were removed in the squashed merge `776b9559`).
- The plan's own deferred follow-up is now overdue: the
  `renderedFrame ?? frame` node-lookup pattern spread from **3 controller-layer
  sites at audit time to 8 today**. The audit's `>1 consumer` rule fires loudly.
- The stale branch `patch/narrow-wmcontroller-public-surface` is **fully shipped**
  (its tip `3823c0d4` is patch-identical to main's `776b9559`; `git cherry`
  confirms). It can be deleted; nothing to rebase.
- Conclusion: protocol seams stop *reach-through* but do not stop *accretion*.
  The next round should extract whole responsibility clusters, starting with
  WMController's diagnostics surface (42 of its 240 funcs) and the
  inactive-workspace/stale-frame suppression cluster in `LayoutRefreshController`.

---

## Part 1 — Growth evidence

### LOC over time (via local reflog checkpoints)

| File | import (`9a468779`, 2026-05-30) | 2026-06-01 | 2026-06-10 | 2026-06-20 | main (2026-07-02) | Δ since import |
|---|---|---|---|---|---|---|
| `Core/Controller/WMController.swift` | 2,809 | 3,212 | 3,552 | 4,145 | **5,031** | **+79%** |
| `Core/Controller/AXEventHandler.swift` | 3,468 | 3,631 | 3,650 | 4,449 | **4,914** | +42% |
| `Core/Controller/LayoutRefreshController.swift` | 3,490 | 3,597 | 3,475 | 4,090 | **4,669** | +34% |
| `Core/Workspace/WorkspaceManager.swift` | 3,755 | 3,923 | 3,985 | 4,066 | **4,522** | +20% |
| `Core/Controller/MouseEventHandler.swift` | 1,770 | 1,783 | 1,938 | 2,390 | **2,645** | +49% |

All five accelerated after 2026-06-10; the last ten days added ~500–900 lines each.

### Density and internal structure

| File | funcs | `// MARK:` | `extension` blocks in-file |
|---|---|---|---|
| `WMController.swift` | 240 | 0 | 1 |
| `AXEventHandler.swift` | 183 | 0 | 2 |
| `LayoutRefreshController.swift` | 165 | 0 | 1 |
| `WorkspaceManager.swift` | 291 | 0 | 0 |
| `MouseEventHandler.swift` | 102 | 0 | 0 |

The 2026-06-13 review measured WMController at ~190 funcs / ~3,600 LOC; it is now
240 funcs / 5,031 LOC. None of the five files has a single `MARK` or meaningful
extension split — navigation within them is grep-only. (Contrast: the Niri engine
directory holds 32 files with per-concern `NiriLayoutEngine+*.swift` extensions;
the controller layer never adopted that convention.)

### What actually drove the growth (2026-06-20 → 2026-07-01, per `git log --numstat`)

Three distinct mechanisms, in descending order of volume:

1. **Cross-cutting feature families that slice into every file at once.**
   - "Add sticky PiP defaults and ignore app rules" (`9ef0ae82`):
     +224 WMController, +173 AXEventHandler, +77 LayoutRefreshController,
     +99 WorkspaceManager.
   - "Hide app-managed transient and parented floating surfaces from the workspace
     bar" (`54d5dd7e`): +83 WMController, +142 WorkspaceManager.
   - "Keep PiP visible across workspace switches (#108)" (`ade7cd07`):
     +177 LayoutRefreshController, +83 WorkspaceManager.
   - Workspace-bar UX round (`d0cf6368`, `f4adb75f`, `8900a436`):
     +91/+20/+26 WMController, +12 WorkspaceManager.
2. **Diagnostics and tracing.**
   - "Add trace clip buffer and DebugBar" (`f160254d`): **+243 WMController** —
     the single largest post-audit addition to that file.
   - "Add runtime diagnostics for gesture, navigation, and frame issues"
     (`6a9a5528`): +92 LayoutRefreshController, +165 MouseEventHandler.
   - Viewport-mutation audit/provenance series (`18a3174e`, `4aa2c9b2`,
     `90a752ce`, `32ba67a1`): +~75 WMController, +~75 WorkspaceManager.
3. **Bug-fix guards accreting at the same seams.**
   - "Reconcile stale hidden-window live frames" (`07ce4168`):
     +170 LayoutRefreshController.
   - "Stop inactive-workspace layout frame writes from leaking windows onscreen"
     (`70ed2619`): +78 LayoutRefreshController.
   - "Fix focus-follows-mouse blocked by click-through overlays (#64)"
     (`472f7185`... series): +140 WMController, +93 MouseEventHandler.
   - "Fix frameless qutebrowser borders": +268 AXEventHandler.

The takeaway: these files are where **admission, focus, refresh, and projection
policy** live, so every behavioral feature or fix must add code *somewhere* in
them. Reach-through protection (Part 2) worked, but it does not create a place
for new policy to live *outside* the mega-files.

---

## Part 2 — Narrow-WMController plan, revisited

### It shipped, and the stale branch is disposable

- Main carries the work as `776b9559` ("Narrow WMController layout/focus surface
  behind coordinator protocols", merged ~2026-06-20).
- The branch `patch/narrow-wmcontroller-public-surface` shows 1 commit ahead of
  main (`3823c0d4`, 2026-06-19), but `git cherry main <branch>` marks it `-`:
  **patch-identical to `776b9559`**. Nothing is stranded. The 2026-07-01 grooming
  review's "rebase or drop" question resolves to: **delete the branch**.
- The completed plan's Outcome section lists three phase commits
  (`a968a7a6`, `cb08c462`, `41902e64`); these were squashed/folded into the single
  main commit. The plan doc's history is accurate at the content level.

### The boundaries held under two weeks of heavy traffic

Measured on `705831f9` (2026-07-02) against the plan's Phase-4 audit (2026-06-19):

| Boundary | At audit | Now | Verdict |
|---|---|---|---|
| Engine write sites outside `setNiriEngine(_:)` | 0 | 0 (`WMController.swift:131` is the only assignment) | **held** |
| `CommandHandler` → `niriLayoutHandler` references | 0 | 0 (44 `layoutCoordinator` call sites) | **held** |
| External production `.niriEngine` reads (excl. `WMController`/`NiriLayoutHandler`) | 31 | 32 | held (±1) |
| `LayoutCoordinator` shape | 21 members incl. 3 context-closure escape hatches (`withNiriOperationContext`, `withNiriWorkspaceContext`, `activateNode`) | ~35 members, **all named command methods; escape hatches removed** (folded into `NiriLayoutHandler` per `776b9559`) | **improved** — wider member count but a strictly narrower capability surface |
| `FocusCoordinator` | 4 members | 4 members | held |
| Test reads of `.niriEngine` | 104 | 119 | grew, but this is the sanctioned inspection seam (plan non-goal to migrate) |

Read-distribution shifts worth noting:

- `WorkspaceBarDataSource` went from 1 direct engine read to **0** — the
  workspace-bar reactive-lens work (`8900a436`) moved it fully onto projections.
  The direction the plan pointed at is being followed without enforcement.
- `WorkspaceNavigationHandler` went 8 → 9 reads and is, at 1,094 LOC, the most
  coherent unprotocoled cluster left (workspace-switch focus restoration, move
  source/target resolution).
- One "new" read is the `FocusCoordinator` adaptor itself — expected, that is the
  seam working as designed.

### The plan's deferred items are now ripe

1. **`LayoutStateQuery` / rendered-frame helper — threshold now clearly exceeded.**
   The audit counted the `renderedFrame ?? frame` node lookup at 3 controller-layer
   sites and deferred extraction. Today it appears at **8 controller-layer sites
   across 4 files** (`AXEventHandler.swift:2420,4073`,
   `MouseEventHandler.swift:1008,2173`, `NiriLayoutHandler.swift:185,1282,2146`,
   `WMController.swift:4934`), plus ~10 legitimate engine-internal uses. The
   audit's own `>1 consumer` rule says extract: a single
   `preferredFrame(for token:) -> CGRect?` query (on `FocusCoordinator`, or a tiny
   `LayoutStateQuery` protocol) removes 8 reach-into-node-internals sites.
2. **`FocusCoordinator.focusedNode(for:)` still has zero consumers** — flagged in
   the plan's "Notes for a future reviewer" on 2026-06-19, still dead on
   2026-07-02. Either the rendered-frame query above becomes its first real use
   (replace it with `preferredFrame(for:)`), or it should be dropped.

### What the plan could not do

The plan was explicitly *cheap insurance against ad-hoc reach-through*, and it
delivered exactly that. It never claimed to address file size, and indeed:
WMController grew from ~3,670 LOC (plan's measurement) to 5,031 **after** the
narrowing shipped. Compile-time seams change where code is *allowed to look*, not
where new code *must live*. Accretion needs extraction, not protocols.

---

## Part 3 — Where the next seams are (ranked candidates)

Ranked by (cluster coherence × recent growth pressure ÷ risk). Each is sized as an
independently-shippable, no-behavior-change extraction in the spirit of the
narrow-WMController phases.

### 1. WMController diagnostics/trace surface → `RuntimeDiagnosticsCoordinator`

- **Evidence:** 42 of WMController's 240 funcs match trace/debug/diagnostic/dump
  naming — the largest single concern cluster in the file. The trace clip
  buffer/DebugBar commit alone added +243 lines; the viewport-verbosity and
  viewport-mutation-audit series added ~75 more.
- **Why safe:** diagnostics is read-mostly, behavior-inert by definition (its
  whole contract is "observe, don't change"), and already has natural collaborators
  outside the file (`ReconcileTraceRecorder`, `RuntimeStore` live in
  `Core/Reconcile/`). The IPC debug endpoints and command-palette debug actions
  give it a well-defined external API to preserve.
- **Shape:** move dump/reset/trace-toggle/clip-buffer orchestration into a
  dedicated `@MainActor` type owned by WMController; WMController keeps thin
  forwarding only where hotkey/IPC routing requires it.

### 2. LayoutRefreshController hidden/inactive-frame policy cluster

- **Evidence:** the three biggest recent additions to the file are one policy
  family: inactive-workspace frame-write leak suppression (+78, `70ed2619`),
  PiP visibility across workspace switches (+177, `ade7cd07`), stale hidden-window
  live-frame reconciliation (+170, `07ce4168`). This is "which windows must NOT be
  framed right now, and how do we heal when reality disagrees" — a coherent policy
  distinct from refresh scheduling/coalescing.
- **Why safe:** the pure-layout-engine invariant (engine never touches AX) means
  this policy already sits at a defined pipeline stage; it consumes
  `HiddenReason`/workspace-visibility inputs and produces skip/heal decisions.
- **Shape:** extract a `HiddenFramePolicy` (or `FrameWriteGate`) consulted by the
  refresh pipeline; unit-test the decision table directly instead of through
  refresh-pipeline hooks.

### 3. AXEventHandler admission pipeline vs. observer plumbing

- **Evidence:** 183 funcs, 4,914 LOC mixing (a) SkyLight/AX event intake and
  correlation (managed-replacement, close-focus-recovery leases) with (b)
  admission *policy* (sticky/PiP defaults +173, frameless-window/border
  special-casing +268, transient-popup exclusion, focused-admission). The
  2026-06-13 review's §9 already named this file the delicacy hotspot, and
  `planned/20260625-vscode-focused-admission-skips-managed-replacement-rekey.md`
  documents two admission routes that disagree — a direct symptom of policy
  duplicated inside plumbing.
- **Shape:** consolidate a single `WindowAdmissionPipeline` used by both the
  proactive rescan route and the focused-admission route (that also fixes the
  VS Code rekey bug class); keep AXEventHandler as intake/correlation only.
- **Risk:** highest of the three — this is live focus/admission behavior; needs
  the trace-first validation discipline the repo already practices.

### 4. WorkspaceManager monitor + restore clusters

- **Evidence:** 291 funcs; name-clustering shows ~48 monitor-related and ~25
  restore/rescue funcs plus ~30 trace/reconcile funcs. The restore planner
  (`restorePlanner`) and reconcile runtime are already separate types — the funcs
  in WorkspaceManager are largely coordination shims that accreted around them.
- **Shape:** continue the existing direction: push monitor-session bookkeeping
  toward the session-state types, restore/rescue coordination toward
  `Core/Reconcile/` types. Lower urgency than 1–3 because the file grew slowest
  (+20%).

### 5. MouseEventHandler gesture recognition state

- **Evidence:** +49% since import; the trackpad-recognition series (`88fed658`,
  `f81f8a9e`, diagnostics `6a9a5528` +165) all landed here. The 2026-06-13 review
  noted three overlapping phase enums and no state diagram; the July fixes
  (idle-`.changed` admission, contact-count ramp, dead-zone/projection clamp)
  were all recognition-layer bugs.
- **Shape:** extract the recognizer (contact-count ramp, phase admission,
  dead-zone/projection) as a pure state machine like `SwipeTracker` already is for
  deltas — unit-testable without CGEvent taps. The fresh diagnostics fields from
  `6a9a5528` define exactly what the recognizer's inputs/outputs are.

### Not recommended right now

- **A `NavigationCoordinator` protocol for `WorkspaceNavigationHandler`'s 9 engine
  reads** — it is a single consumer with a coherent purpose; a protocol would be
  insurance nobody is claiming yet (same reasoning that deferred
  `FocusCoordinator` alternatives in the original plan).
- **Splitting files purely by size** (e.g., `WMController+Foo.swift` extensions
  without ownership change) — cosmetic; the review's §9 concern is concern-mixing,
  not line count per se. Adding `// MARK:` sections is cheap and worth doing
  opportunistically, but is not the fix.

---

## Part 4 — Suggested follow-ups

1. **Delete `patch/narrow-wmcontroller-public-surface`** (shipped as `776b9559`;
   `git cherry` proof above). Optionally note this in the completed plan doc.
2. **Small plan: `preferredFrame(for:)` query seam** — collapse the 8
   `renderedFrame ?? frame` controller-layer sites; decide `FocusCoordinator`
   member (giving the dead `focusedNode(for:)` a replacement) vs. tiny
   `LayoutStateQuery` protocol. No-behavior-change; the follow-up the completed
   plan already scoped.
3. **Plan: WMController diagnostics extraction** (candidate #1) — biggest
   mechanical win, lowest risk, and it counters the strongest current growth
   pressure (diagnostics landed +~320 lines in ten days).
4. **Plan: hidden/inactive-frame policy extraction** (candidate #2) — turns the
   three recent leak/reconcile fix families into one testable decision table.
5. **Discovery-level dependency:** candidate #3 (admission pipeline) should be
   coordinated with
   `planned/20260625-vscode-focused-admission-skips-managed-replacement-rekey.md`
   — that plan's fix (route focused-admission through the structural rekey) is a
   natural first step of the pipeline consolidation, not a separate effort.
6. **Convention nudge, zero-risk:** adopt `// MARK:` sections in the five files
   (they currently have none) so concern clusters are visible before they are
   extracted.
