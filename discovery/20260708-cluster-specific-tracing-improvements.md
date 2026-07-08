# Cluster-specific tracing improvements — Discovery

Discovery date: 2026-07-08. Verified against the main Nehir source tree at
`d4cc525c` on 2026-07-08. This discovery follows
[`20260708-cross-discovery-relevance-clusters.md`](20260708-cross-discovery-relevance-clusters.md)
and turns each relevance cluster into concrete observability work.

**Status update, 2026-07-08:** the first OT-1/NF-1 slice shipped in `main` as
`f6078799` (`Add internal cluster tracing diagnostics`). See
[`../completed/20260708-internal-cluster-tracing-diagnostics.md`](../completed/20260708-internal-cluster-tracing-diagnostics.md)
for the final shipped state. The completed slice added developer-mode background
trace retention outside active capture sessions, viewport background
participation, a lazy named runtime decision-event API, runtime decision trace
export, `eventNameCounts`, and `managedCommandTarget()`
`command_target.resolve.*` events. A VR-1 behavior fix for fully-visible focus
reveals later shipped in `c6eaafb9`, but the engine-level VR-1 tracing slice
below remains open. The broader LC-1, remaining VR-1, XD-1, TF-1, and
non-managed-focus arming traces remain open.

This is an observability discovery, not a behavior-fix plan. The durable finding
is that the current tracing surface already has useful point diagnostics, but it
is not shaped around the cross-cluster questions investigators keep needing to
answer: **which guard declined, which oracle was trusted, which target moved,
which workspace/display identity was used, and which classification evidence was
preserved or lost**.

## TL;DR

- Add an always-available, lazy, named decision-event API before adding more
  bespoke `key=value` strings. The existing background ring cannot capture after
  the fact because it is gated by `developerModeEnabled && active capture`, and
  viewport events are additionally dropped before they can reach that ring.
- Treat every cluster fix as requiring a `decision -> action -> observed result`
  trace for the affected token. A raw request line or a final state dump is not
  enough.
- Prioritize tracing in this order: **NF-1 command-target declines**, **LC-1
  lifecycle oracle outcomes**, **VR-1 reveal/snap no-op reasons**, **XD-1
  cross-display transition checkpoints**, **TF-1 classification/metadata
  changes**, and the OT-1 infrastructure that makes those traces cheap and
  queryable.

## Current tracing constraints that shape every recommendation

Source-backed facts:

- `BackgroundTraceCategory` has only broad buckets: `viewport`, `resize`,
  `insertion`, `mouse`, and `runtime` (`Sources/Nehir/Core/Diagnostics/BackgroundTraceBuffer.swift:8-14`).
  There is no first-class `command`, `focus`, `admission`, `lifecycle`,
  `classification`, or `transition` stream.
- The background buffer is effectively enabled only when developer mode is on
  **and** runtime trace capture is active (`Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift:61-63`),
  and every append goes through that gate (`RuntimeDiagnosticsCoordinator.swift:378-389`).
- Viewport events are double-gated: `recordRuntimeViewportTrace` returns before
  formatting or appending unless capture is active (`RuntimeDiagnosticsCoordinator.swift:281-287`),
  even though the other category wrappers flow through `recordRuntimeTrace` and
  then append to the background ring (`RuntimeDiagnosticsCoordinator.swift:253-279`).
- Capture export is rich but session-scoped: it dumps reconcile, viewport,
  resize, insertion, create/focus, managed replacement, raw AX, AX-window-query,
  interaction-monitor, floating-bar-projection, and mouse traces only when a
  capture is stopped (`RuntimeDiagnosticsCoordinator.swift:1026-1105`).
- Runtime viewport records include selected/preferred/confirmed focus, offsets,
  gesture/animation state, and optional layout dumps (`RuntimeDiagnosticsCoordinator.swift:281-371`),
  but their `reason` strings are free-form and caller-owned.
- Window decision snapshots are selectively traced; `shouldTraceWindowDecision`
  emits focused admission, Ghostty, untracked/unmanaged/dialog/nonstandard/level
  cases and otherwise suppresses normal tracked decisions
  (`RuntimeDiagnosticsCoordinator.swift:148-179`).

Implication: cluster tracing should not be implemented as six unrelated strings.
First add a thin event envelope, for example:

```text
event=<stable.name> cluster=<NF-1|LC-1|...> action=<user/system source>
token=<pid:windowId or nil> pid=<pid or nil> workspace=<uuid or nil>
monitor=<id or nil> correlation=<command/request/burst id> outcome=<...>
reason=<stable enum-like string> fields...
```

The payload can still serialize as text, but the call boundary should accept a
stable event name and lazy fields so always-on background tracing does not force
hot paths to eagerly build expensive diagnostics.

## NF-1 — stale non-managed focus / command-target declines

### Why current traces are insufficient

`managedCommandTarget()` is the shared generic resolver for many command paths.
It explicitly returns `nil` when recently leaving non-managed focus and a
frontmost token is present (`WMController.swift:1905-1914`), and returns `nil`
again while non-managed focus is active if the frontmost token is already tracked
or if the activation probe does not produce an allowed replacement target
(`WMController.swift:1916-1938`). Those returns currently have no local decision
trace. A later runtime dump can show `wmCommandTarget=nil` and
`nonManaged=true` (`RuntimeDiagnosticsCoordinator.swift:589-614`), but it does
not say **which branch declined the user command** or what state armed it.

### Add these trace events

1. `command_target.resolve.begin`
   - fields: command/action name, caller/source, frontmost pid, frontmost token,
     confirmed managed token, layout-selection token/workspace, interaction
     workspace/monitor, non-managed active, recently-left-non-managed age.
2. `command_target.resolve.decline`
   - one event for every `nil` return in `managedCommandTarget()` with stable
     reasons such as `recentlyLeftNonManagedFocus.frontmostPresent`,
     `nonManagedFocus.frontmostTracked`, `nonManagedFocus.probeNoReplacement`,
     `noConfirmedNoFrontmost`, etc.
   - include preserved managed token, resolved-frontmost token after the probe,
     whether the frontmost token is self/untracked, and whether a sticky source
     exception was considered.
3. `command_target.resolve.accept`
   - fields: target token/workspace/source (`layoutSelection`,
     `confirmedManagedFocus`, `frontmost`, etc.) and whether it was accepted
     under a non-managed-focus exception.
4. `non_managed_focus.enter/exit`
   - `WMEvent.nonManagedFocusChanged` already records active/fullscreen/preserve
     flags in reconcile (`Sources/Nehir/Core/Reconcile/WMEvent.swift:141-147`,
     `WMEvent.swift:234-235`). Add the missing arming source: observed focused
     pid/window, visible unmanaged candidate count/hash, preserved token,
     pending managed focus token, and why the state was kept or cleared.
5. Explicit-token command events for workspace-bar and context-menu moves.
   - The trace should distinguish `explicitTokenMove` from generic
     `managedCommandTarget()` resolution, so a Shift-click/right-click command
     can prove it did not re-enter the stale generic target path.

### Acceptance for NF-1 plans

A reproduced no-op should produce exactly one declined command-target event with
a reason and the arming state. If the user selected a managed visible column but
the command still declined, the trace must show both the selected token and the
non-managed-focus evidence that overrode it.

## LC-1 — lifecycle/admission desync and replacement bursts

### Why current traces are insufficient

There are good pieces, but they are not one lifecycle story:

- CGS events are decoded and drained with counters (`CGSEventObserver.swift:10-17`,
  `CGSEventObserver.swift:156-177`, `CGSEventObserver.swift:227-267`), but the
  runtime capture only exposes aggregate counters in the state dump
  (`RuntimeDiagnosticsCoordinator.swift:696-708`). It does not list the raw CGS
  create/destroy/space event that fed a removal decision.
- AX removal enters `handleWindowDestroyed` through `handleRemoved(pid:winId:)`
  with liveness verification requested (`AXEventHandler.swift:1902-1908`), and
  token removal later performs focus recovery, viewport tracing, model removal,
  and refresh (`AXEventHandler.swift:1910-2010`). A trace can show recovery, but
  not always the oracle chain that decided the window was truly dead.
- Managed replacement burst tracing records enqueue, schedule, flush, match,
  rekey, and replay events (`AXEventHandler.swift:4906-4950`,
  `AXEventHandler.swift:4952-4995`, `AXEventHandler.swift:5842-5950`), but that
  ring is dumped only with an armed capture and is capped separately from the
  reconcile trace.

### Add these trace events

1. `lifecycle.oracle.event`
   - fields: oracle (`AX.destroy`, `CGS.spaceDestroyed`, `CGS.closed`,
     `fullRescan.missing`, `pidWindowList`), pid/windowId/token if known,
     space id, current workspace/monitor mapping, registration/drain sequence,
     and raw decode status.
2. `lifecycle.liveness.check`
   - fields: token, oracle that triggered the check, AX ref availability,
     WindowServer entry presence/onscreen/frame/layer, SkyLight spaces for the
     window, AX-window-list membership for pid, title/frame if available, and
     final verdict (`alive`, `dead`, `inconclusive`, `defer`).
3. `lifecycle.remove_or_defer`
   - fields: token, triggering oracle, liveness verdict, action (`remove`,
     `delay`, `ignore`, `replay_later`), affected workspace active flag,
     confirmed focus before removal, and recovery context.
4. `replacement_burst.lifecycle`
   - promote the existing managed-replacement events into the common event
     envelope with a `burstId`/`sequence`. Include create/destroy counts,
     policy, deadline reset, elapsed ms, match count, rekey success, replayed
     count, and final admission/removal outcome per token.
5. `admission.finalize`
   - after a delayed create or replay, trace whether the token ended in the
     model, niri tree, workspace, and visible frame. This closes the current gap
     where enqueue/flush can be visible but the user-facing admission outcome is
     inferred from later state.

### Acceptance for LC-1 plans

For a window that disappears, the trace must answer: **which oracle said remove,
which second oracle agreed or disagreed, what action was taken, and whether the
token survived in the model, niri tree, AX, and WindowServer afterward**.

## VR-1 — automatic viewport movement, reveal, and snap

### Why current traces are insufficient

Focus confirmation records useful reveal candidate/result lines including
scroll lock, visibility, snap count, closest/center snap, and `didReveal`
(`AXEventHandler.swift`). A 2026-07-08 two-window capture showed why that
caller-level trace is useful but still incomplete: it proved an unlocked, fully
visible automatic focus confirm chose `center=-616.2` and moved
`targetViewStart=-209.4 → -616.2`, but the engine branch and no-op/apply reason
still had to be inferred from the candidate numbers. `c6eaafb9` fixed that
specific behavior, yet the tracing gap remains for future VR-1 cases because the
actual reveal policy lives in `NiriLayoutEngine.scrollToReveal`: it can return
`false` for FFM, invalid indices/no snap points, fully-visible no-op,
scroll-lock, or missing snap; it can also move a fully visible filling group as
viewport-position maintenance (`NiriLayoutEngine+ViewportCommands.swift`). Snap
candidates are produced by `ViewportSnapContext.snapCandidates`, which stores
bounded offsets without showing the original unbounded candidate or why
candidates were retained (`ViewportState+Geometry.swift`). Viewport mutation
audit keeps only the last mutation (`ViewportState.swift`).

### Add these trace events

1. `viewport.reveal.evaluate`
   - emitted inside `scrollToReveal`, not just by callers.
   - fields: trigger (`automatic`, `explicitNavigation`, `focusConfirm`,
     `relayout`, etc.), token/column if available, isFFM, reveal style,
     scroll-lock state, visibility, current view start, active column, snap
     count, target snap chosen, and stable no-op reason.
2. `viewport.reveal.apply`
   - fields: old/new target offset, old/new current offset, animation config,
     motion enabled, scale, and whether the movement was a true reveal or
     fully-visible maintenance.
3. `viewport.snap.candidate`
   - for suspicious cases, include unbounded left/right/center offsets,
     bounded offsets, candidate kind, whether the column/strip fills the
     viewport, whether the workspace is lone-column/narrow, and filter reason.
4. `viewport.mutation.ring`
   - replace the single last-mutation slot with the last 8-16 mutations per
     workspace, using monotonic time as well as wall time. Keep caller, before,
     after, and reason. The current single slot is easy to overwrite before a
     later trace line records the culprit.
5. `viewport.scroll_lock.decision`
   - emitted when lock is honored or bypassed, with trigger and explicitness.

### Acceptance for VR-1 plans

Any viewport movement bug should have a before/after offset pair and either a
selected target snap or a no-op reason. A fully-visible target should show
whether movement was skipped, explicit navigation, or maintenance centering.

## XD-1 — cross-display move/reveal ordering

### Why current traces are insufficient

Cross-display commands need a single transition identity across model move,
engine move, workspace assignment, layout refresh, frame write, focus, and
reveal. Today, the pieces are split:

- `WorkspaceNavigationHandler.transferWindowFromSourceEngine` traces some engine
  transfer failures and source repair (`WorkspaceNavigationHandler.swift:546-667`).
- `moveWindow(handle:toWorkspaceId:)` is a refresh-free primitive used by
  summon-right and overview drag; it transfers, reassigns, prepares the target
  viewport, and returns (`WorkspaceNavigationHandler.swift:918-940`).
- `moveWindowFromBar` and `commitNonFollowingWindowMove` explicitly schedule the
  workspace-transition refresh (`WorkspaceNavigationHandler.swift:942-1013`).
- Summon Right records request/insert/move/commit/reject lines in the insertion
  trace (`WindowActionHandler.swift:411-465`, `WindowActionHandler.swift:543-668`),
  but those lines are not tied to the subsequent viewport/frame materialization
  and focus/reveal callbacks.

### Add these trace events

1. `transition.cross_display.begin`
   - fields: command (`summonRight`, hotkey move, bar move, overview drag),
     token, source/target workspace, source/target monitor/display, monitor
     frames, working frames/insets, scale, anchor token/workspace, and whether
     focus should follow.
2. `transition.cross_display.checkpoint`
   - one correlation id across: engine transfer result, model reassignment,
     target viewport preparation, insertion index/column count, workspace
     transition scheduled, refresh started, refresh completed, frame write
     requested, frame write observed, focus requested/confirmed, reveal
     evaluated/applied.
3. `transition.cross_display.materialization`
   - fields: token present in model, present in niri tree, target column index,
     target frame from layout plan, last applied frame, live AX/WindowServer
     frame, hidden/workspace-inactive state, and whether target workspace is
     visible/active.
4. `transition.cross_display.reveal_timing`
   - explicitly mark reveal/focus calls that happen before target-display frame
     materialization versus after it.

### Acceptance for XD-1 plans

A cross-display trace should let a reviewer line up one token's journey without
searching by hand across insertion, viewport, refresh, and AX sections. The
trace must prove whether reveal used source-display or target-display geometry.

## TF-1 — transient/floating/PiP classification and durable metadata

### Why current traces are insufficient

Classification facts are preserved in the model: `ManagedReplacementMetadata`
includes role/subrole/title/window level/parent/frame and transient/user-addressable
flags (`WindowModel.swift:20-45`). Admission and refresh paths merge transient
flags into metadata (`WMController.swift:3082-3110`,
`LayoutRefreshController.swift:1535-1572`). Floating-bar projection already logs
accept/reject decisions with metadata and sticky/scratchpad state
(`WorkspaceManager.swift:2728-2818`). However, window-decision tracing is
selective (`RuntimeDiagnosticsCoordinator.swift:148-179`), and projection trace
is a separate 120-record ring dumped with capture, not a first-class background
classification stream (`WorkspaceManager.swift:348-355`,
`WorkspaceManager.swift:2813-2817`).

### Add these trace events

1. `classification.window_decision`
   - emit for every disposition change, mode change, or suspicious metadata
     update, not only the current sampled cases.
   - fields: token, bundle id, role/subrole, title length, window level, tags,
     parent id, frame, close/zoom/minimize/fullscreen buttons, built-in/user rule
     source, disposition, tracked mode, deferred reason, existing mode.
2. `classification.metadata_merge`
   - fields: old/new metadata, which fields were live facts vs carried forward,
     transient flags before/after, and whether a nil/empty frame was preserved or
     replaced.
3. `classification.projection_decision`
   - promote floating-bar projection accept/reject into the common event stream
     with reason, metadata, frame source, sticky/global-sticky/scratchpad state,
     and user-addressable flag.
4. `classification.policy_override`
   - trace automatic fallback preservation, e.g. transient floating surfaces that
     stay floating even when a reevaluation would otherwise tile/unmanage them
     (`WMController.swift:2355-2402`).
5. `pip.workspace_semantics`
   - for PiP/sticky surfaces, trace sticky/global-sticky state, workspace
     assignment, monitor, and whether the surface is treated as user-addressable.

### Acceptance for TF-1 plans

A helper/PiP bug trace should show exactly which evidence made the surface tile,
float, appear in the bar, or disappear from the bar, and whether that evidence
was live, cached, inherited, or lost during refresh/replacement.

## OT-1 — observability/test truthfulness enabler

### Infrastructure work that supports every cluster

1. **Always-on background ring, capture as export/pin.** Decouple
   `BackgroundTraceBuffer` from active capture; lift the viewport early return;
   make payload generation lazy enough for normal use.
2. **Stable event names and typed-ish payload API.** Keep text export, but route
   cluster events through one helper so fields and correlation ids are
   consistent.
3. **Decision-event tests.** For each high-risk guard, assert that a named event
   is emitted with a reason. The target is not exhaustive behavioral testing; it
   is preventing new silent guards.
4. **Trace health summary.** Every export should list enabled categories, event
   counts by stable event name, retention truncation, and whether viewport events
   were dropped by gating. This makes a bad capture self-diagnosing.
5. **Production-path tests only for trace assertions.** If a regression test
   bypasses the real scheduler/reconcile/admission path, it can still assert the
   pure decision result, but it must not be the only test that claims the runtime
   trace point works.

## Suggested implementation slices

1. **OT-1 base slice — partially shipped in `f6078799`:** lazy named-event API,
   developer-mode background buffer outside active capture sessions, viewport
   background participation, runtime decision trace export, and background clip
   `eventNameCounts` are in `main`. Still open: a broader typed event registry
   and any non-developer-mode/default-on policy change.
2. **NF-1 slice — partially shipped in `f6078799`:**
   `managedCommandTarget()` declines/accepts now emit `command_target.resolve.*`
   events. Still open: non-managed-focus enter/exit arming details and
   explicit-token workspace-bar/context-menu move traces.
3. **LC-1 slice:** add lifecycle oracle/liveness/action events and promote
   managed-replacement burst ids into the common envelope.
4. **VR-1 slice:** still open after the `c6eaafb9` behavior fix — move
   reveal/snap decision tracing into the engine and add a small viewport
   mutation ring.
5. **XD-1 slice:** add transition correlation ids and materialization checkpoints
   around Summon Right and cross-monitor workspace moves.
6. **TF-1 slice:** promote classification metadata/projection decisions into the
   common event stream.

Each slice is additive and should be reviewable independently. Behavior fixes in
NF-1, LC-1, VR-1, or XD-1 should require the relevant slice's trace point before
or in the same patch.
