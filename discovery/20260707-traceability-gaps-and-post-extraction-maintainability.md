# Traceability gaps and post-extraction maintainability — Discovery

Groom 2026-07-07: still applicable — audit; the `RuntimeDiagnosticsCoordinator` extraction (`d1505910`) partially addressed the maintainability axis, but the highest-leverage traceability recommendations remain open (always-on background trace buffer gated behind dev-mode/active-capture, silent guards not emitting a decline reason, free-form `key=value` trace events with no typed schema) and the `AXEventHandler` extraction is flagged overdue (verified against main 7a025b78).

Codebase weak-point audit focused on two axes: (1) **traceability** — why hard
bugs keep requiring an armed re-repro instead of being diagnosable from the
first occurrence, and (2) **maintainability** — what changed in the five days
since [`20260702-mega-file-growth-and-narrow-wmcontroller-revisit.md`](20260702-mega-file-growth-and-narrow-wmcontroller-revisit.md)
and which of its predictions already came true.

Verified against the main Nehir source tree at `7a025b78` ("Verify window
liveness before honoring a spurious AX destroy on cold start") on 2026-07-07.
Line numbers drift; function names are included so code stays findable.

---

## TL;DR

- **The "background" trace buffer is not background.** It records only while a
  runtime trace capture session is explicitly active *and* developer mode is on
  (`RuntimeDiagnosticsCoordinator.swift:61-62`). There is no retroactive
  capture: a bug seen once cannot be traced after the fact — the user must arm
  capture and reproduce again. The buffer's own design (64 MB ring, time
  retention, monotonic timestamps, marker-based clip export with
  lookback/tail selection) is clearly built for always-on operation; the
  enablement gate defeats it. This is the single highest-leverage traceability
  fix available.
- **Silent guards are the dominant recent bug class, and they are silent in
  traces too.** The discovery corpus's recurring shape — "user action produces
  no effect, no error, nothing in the trace" — happens because early-return
  guards on user-visible action paths decline without emitting a reason.
  Every such bug burns its first repro cycle discovering the needed field
  isn't traced, then a commit adds it reactively (e.g. `e4ef0844` added
  "macOS-observed reality" fields only after model-only focus traces read as
  success while the window server disagreed).
- **Trace events are free-form strings with a schema by convention** —
  ~75 call sites across 9 controller files assemble `key=value` lines by hand;
  analysis is grep-only; nothing prevents field drift or asserts emission.
  `ReconcileTraceRecorder` already demonstrates the typed alternative in-tree
  but covers only the reconcile path (256-record cap).
- **Maintainability: the extraction playbook works; AXEventHandler is now
  overdue.** WMController shrank 5,031 → 4,045 LOC after the diagnostics
  extraction (`d1505910`) and held. Meanwhile `AXEventHandler.swift` grew
  4,914 → **5,781 LOC in five days** (+867), including a **+518-line single
  bug fix** — exactly the admission/focus-policy accretion the 2026-07-02
  discovery's candidate #3 predicted. The `// MARK:` follow-up (#6 there)
  never happened: still zero MARKs in all five mega-files.

---

## Part 1 — Traceability

### 1.1 The tracing surface, as it actually is

Three parallel systems plus a nearly unused system logger:

| System | Enablement | Sink | Scope |
|---|---|---|---|
| `LayoutTrace` (`Core/Controller/LayoutTrace.swift`) | `NEHIR_LAYOUT_TRACE` env var, **launch-time only** | `os_log` category `layout-trace` | Frame-application pipeline |
| Runtime trace capture (`RuntimeDiagnosticsCoordinator.swift`) | Explicit start via IPC/palette/DebugBar | Per-category rings, 400 lines each | viewport / resize / insertion / mouse / runtime |
| `BackgroundTraceBuffer` (`Core/Diagnostics/BackgroundTraceBuffer.swift`) | `developerModeEnabled && isRuntimeTraceCaptureActive` | In-memory ring, 64 MB default cap | Same categories, clip export |
| `os.Logger` elsewhere | always | unified log | **9 call sites in the entire codebase** |

Structured, typed tracing exists only for the reconcile path:
`ReconcileTraceRecorder` (`Core/Reconcile/ReconcileTrace.swift`) records typed
`WMEvent` / `ActionPlan` / `ReconcileSnapshot` / invariant-violation records,
capped at 256.

### 1.2 The background buffer cannot do its job (highest leverage)

`RuntimeDiagnosticsCoordinator.swift:61-62`:

```swift
var isBackgroundTraceBufferEffectivelyEnabled: Bool {
    (controller?.settings.developerModeEnabled ?? false) && isRuntimeTraceCaptureActive
}
```

Every `appendBackgroundTrace` is gated on this
(`RuntimeDiagnosticsCoordinator.swift:383`), so the buffer holds nothing unless
a capture session is already running. The whole point of a retention-bounded
background ring — "the bug just happened; export the last two minutes" — is
unreachable. The unmerged branch `impl-always-on-background-tracing` shows this
gap is already recognized; this discovery is the case for prioritizing it.

Compounding it, the most-investigated category is gated *twice*:
`recordRuntimeViewportTrace` early-returns on
`guard isRuntimeTraceCaptureActive` (`RuntimeDiagnosticsCoordinator.swift:286`)
before ever reaching the background append, so even an always-on buffer would
receive no viewport events until that guard is also lifted. The other
categories (`recordRuntimeResizeTrace` / `Mouse` / `Insertion`,
lines 253-263) do reach `appendBackgroundTrace` unconditionally and are only
stopped by the buffer's own gate — an inconsistency that would silently
produce viewport-less captures after a naive "always-on" change.

Cost note for the fix: call sites build the `details: [String]` arrays and
interpolated strings **eagerly before the guard runs** (e.g. the
`readmit_pending_removal` site wraps its call in an explicit
`if controller.diagnostics.isRuntimeTraceCaptureActive` at
`AXEventHandler.swift:1297` precisely to avoid that cost — a pattern only some
call sites follow). An always-on design needs either `@autoclosure`/closure
payloads or acceptance of the assembly cost; the per-site ad-hoc `if` guards
should go away either way.

### 1.3 Silent guards: the recurring investigation tax

The recent discovery corpus is dominated by "action silently does nothing"
bugs: trackpad gesture silent no-op on empty workspace under cursor
(2026-07-02), move-focused-window-to-workspace no-op under non-managed focus
(2026-07-05), user-activated Slack suppressed as stale (2026-07-03), Cmd-H
hidden column stays reserved (2026-07-03), workspace bar freezes on gesture
with non-managed focus (2026-06-22). The common anatomy: a guard clause on a
user-action path returns early, emits nothing, and the investigation's first
armed repro exists only to find *which* guard fired.

The fix pattern is already practiced reactively — `e4ef0844` ("Trace: emit
macOS-observed reality and the reveal decision for focus events") added the
reveal *decision* and the window-server-observed state to focus traces after
an investigation was misled by traces that recorded only Nehir's intended
model (`focus_confirmed` reading as success while the display never switched).
What's missing is the proactive convention: **any early return on a
user-visible action path emits a trace naming the guard and the state that
armed it.** With an always-on buffer (1.2), that convention converts this
whole bug class from "armed re-repro required" to "export clip, read reason".

### 1.4 Free-form string events

All runtime trace producers hand-assemble `key=value` strings — ~75 call
sites: 30 in `AXEventHandler.swift`, 13 in `WMController.swift`, 11 in
`MouseEventHandler.swift`, 9 in `LayoutRefreshController.swift`, plus 12 more
across five other files. Consequences observed in practice:

- **Field vocabulary drifts per investigation.** Each hard bug adds bespoke
  fields (mutation-audit fields, reveal-decision fields, admission-guard
  fields); nothing ties a field name to a producer, so saved analysis
  patterns and discovery-doc grep recipes silently rot.
- **No emission guarantees.** Nothing asserts that a given decision point
  traces at all — which is how silent guards (1.3) stay silent.
- **Grep is the only query.** Correlating one window's journey across
  categories means eyeballing interleaved lines keyed by hand-formatted
  tokens.

A full structured-event system is not warranted; a **minimal envelope** is:
a stable event-name registry (the `reason=` strings already half-exist),
`event name + [key: value]` payload at the API boundary instead of
pre-joined strings, and a handful of unit tests asserting that named decision
points emit. `ReconcileTraceRecorder` proves the typed style fits the
codebase.

### 1.5 Mutation attribution: single slot, discipline-dependent

`ViewportState.swift:204-208` retains only the **last** viewport mutation
(`lastViewportMutationReason/Caller/Timestamp/Before/After`); any mutation
storm overwrites the culprit before the trace line that would have exposed it
is emitted. A small per-workspace ring (last 8–16 mutations) would make the
audit robust to bursts. The timestamp is wall-clock
(`Date().timeIntervalSince1970`, `ViewportState.swift:252`) even though the
trace pipeline already carries monotonic nanos (`BackgroundTraceEvent`).

Attribution also relies on writers voluntarily using
`withRecordedViewportMutation` (`ViewportState.swift:235`); raw
`viewOffsetPixels` mutations exist in eight files (engine internals
legitimately; `NiriLayoutHandler.swift` has three controller-layer sites).
The `setNiriEngine` lesson applies: a convention becomes a guarantee only when
there is a single write funnel. The branch
`patch/unrecorded-viewport-offset-mutation-attribution` shows unattributed
mutations have already cost an investigation.

### 1.6 The tracing surface is undocumented

`docs/` has no document describing the three trace systems, their categories,
enablement, export flow, or field conventions; `ARCHITECTURE.md` covers the
coordinator in one table row (`docs/ARCHITECTURE.md:417`). The operational
knowledge lives in AGENTS.md workflow lore and scattered discovery docs.
`LayoutTrace` additionally requires relaunching the app under an env var
(`LayoutTrace.swift:26`) — for a window manager, relaunching destroys the very
session state being investigated; it should be runtime-toggleable or folded
into the runtime capture system.

`RuntimeDiagnosticsCoordinator` (1,167 LOC) has no dedicated test file; its
`*ForTests` accessors are consumed only by `MouseEventHandlerTests.swift`.

---

## Part 2 — Maintainability delta since 2026-07-02

### 2.1 The extraction playbook is validated

The 2026-07-02 discovery's top two follow-ups shipped and held:
`d1505910` (diagnostics → `RuntimeDiagnosticsCoordinator`) took
`WMController.swift` to **4,045 LOC** today (from 5,031), and `e87bade3`
(`preferredFrame(for:)` seam) eliminated the controller-layer
`renderedFrame ?? frame` reach-through. Five days of feature traffic did not
re-inflate WMController. Extraction works where protocol seams alone did not.

### 2.2 AXEventHandler is now the urgent hotspot

`AXEventHandler.swift`: 4,914 → **5,781 LOC in five days** (+867, +18%),
now the largest file in the repo. Per-commit attribution:

| Commit | Subject | Δ |
|---|---|---|
| `7a8febb4` | Keep viewport stable after same-app window close | **+518/−22** |
| `06c0bf4e` | Reveal same-app focus switch landing on inactive workspace | +143/−20 |
| `e4ef0844` | Trace: emit macOS-observed reality for focus events | +113/−0 |
| `7a025b78` | Verify window liveness before honoring spurious AX destroy | +75/−13 |
| `151f4e3a` | Exempt user-activated apps from unrequested-admission guard | +72/−0 |

Every entry is admission/focus/close-recovery **policy** landing inside event
**plumbing** — the exact mechanism Part 3 candidate #3 of the mega-file
discovery described. A single bug fix adding 518 net lines to one file is the
cost curve bending: policy that lives inline cannot be unit-tested as a
decision table, so each fix re-derives and re-guards context by hand. The
admission-pipeline extraction (coordinated with the focused-admission rekey
plan, per the earlier discovery) should be treated as promoted from "ranked
candidate" to "next structural task".

### 2.3 Small follow-ups that keep not happening

- **Zero `// MARK:` sections** in all five mega-files (WMController,
  AXEventHandler, LayoutRefreshController, WorkspaceManager,
  MouseEventHandler) — follow-up #6 of the 2026-07-02 discovery,
  zero-risk, still unactioned.
- `FocusCoordinator.focusedNode(for:)` dead member — flagged 2026-06-19 and
  2026-07-02; not re-verified here but no commit since mentions it.

---

## Part 3 — Recommended actions (ranked)

1. **Always-on background tracing** (fixes 1.2; existing branch
   `impl-always-on-background-tracing` may be a starting point). Decouple
   `BackgroundTraceBuffer` from the capture session: enabled by default with a
   modest byte/time budget; capture sessions become "pin + export" on top.
   Must include lifting the viewport early-return
   (`RuntimeDiagnosticsCoordinator.swift:286`) and making payload assembly
   lazy so the hot path stays cheap.
2. **"No silent guards" convention + backfill** (fixes 1.3). One discovery-doc
   pass over the known silent-no-op guard sites, adding a trace with the guard
   name and arming state; then enforce by review convention. Cheap, immediately
   compounds with #1.
3. **AXEventHandler admission-pipeline extraction** (2.2) — already specced
   at the candidate level in the 2026-07-02 discovery Part 3 #3; now has five
   more days of evidence and +867 LOC of urgency.
4. **Viewport mutation audit hardening** (1.5): per-workspace mutation ring,
   monotonic timestamps, and a single write funnel for `viewOffsetPixels`
   outside the engine.
5. **Minimal trace-event envelope** (1.4): event-name registry + structured
   payload at the recording API; migrate opportunistically, starting with the
   categories touched by #1.
6. **Document the tracing surface** in `docs/` (1.6) and make `LayoutTrace`
   runtime-toggleable or fold it into runtime capture.
7. **Zero-risk hygiene**: add `// MARK:` sections to the five mega-files;
   delete or use `focusedNode(for:)`.
