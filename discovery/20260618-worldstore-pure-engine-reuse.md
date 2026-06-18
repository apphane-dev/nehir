# WorldStore cluster reconsideration — Pure engine reuse for real runtime and onboarding

Discovery date: 2026-06-18.

Scope: explain why upstream's WorldStore/EventIntake/IntentLedger/SufaceReconciler cluster should not be ported wholesale, while preserving the useful architectural direction for nehir. This doc frames a nehir-shaped major architecture track centered on a pure model/reducer/effect-plan core reusable by real windows and fake onboarding/demo windows.

Related:

- upstream WorldStore cluster after `ee9b4f0707668d43f73e4af8c9a4f3581b8c11ce`
- `completed/20260614-onboarding.md`
- `Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift`
- current nehir `Sources/Nehir/Core/Reconcile/*`

## TL;DR

- Upstream's WorldStore direction is good: one authoritative state, explicit commits, invariant validation, stamped async plans, intent-aware focus, derived surfaces, deterministic replay.
- Upstream's **implementation unit** is too broad to port directly: it transfers ownership of window model, focus, viewport/session state, layout engines, surface derivation, event ingress, deadlines, and Space topology into a single runtime store that also carries upstream-only product assumptions.
- Nehir should not copy upstream WorldStore wholesale. It should extract a **pure Niri/world model + reducer + layout/effect-plan engine** that can be used by both:
  1. the real AX/AppKit runtime; and
  2. fake SwiftUI/demo windows in onboarding.
- Current onboarding already duplicates real semantics in `InteractiveMoveDemo.MoveDemoModel`, which is strong evidence that a reusable pure core would pay off.

## Why not port upstream WorldStore directly?

Observed upstream shape:

- `Sources/OmniWM/Core/World/WorldStore.swift`
- `Sources/OmniWM/Core/Intake/EventIntake.swift`
- `Sources/OmniWM/Core/Intent/IntentLedger.swift`
- `Sources/OmniWM/Core/Intent/DeadlineWheel.swift`
- `Sources/OmniWM/Core/Surface/SurfaceReconciler.swift`
- `Sources/OmniWM/Core/Surface/WorldView.swift`

`WorldStore` owns or mediates:

- `WindowModel`
- focus snapshot
- viewport state
- scratchpad token
- monitor sessions
- Space topology
- Niri engine
- Dwindle engine
- epoch/invalidation marks
- sanctioned engine mutation depth

That is a replacement runtime, not a bug-fix layer.

Direct port risks:

1. **Product mismatch.** Upstream carries Dwindle, scratchpad, Hyper/hotkey, surface, and runtime assumptions that nehir intentionally removed or reshaped.
2. **God-store risk.** A single store owning model, engines, focus, surfaces, topology, and timers can become `WMController` v2 if boundaries are not strict.
3. **Conflict with existing nehir reconcile vocabulary.** Nehir already has:
   - `RuntimeStore`
   - `ReconcileTxn`
   - `Planner`
   - `StateReducer`
   - `InvariantChecks`
   - `FocusPolicyEngine`
4. **Wrong reuse boundary.** Onboarding/fake windows need pure semantics, not AX/runtime effects or real event intake.

## What to take from upstream

Take the principles, not the file shape:

- single authoritative snapshot for pure state;
- all mutations expressed as commands/events;
- commits validate invariants;
- layout/session/focus plans carry a planned revision;
- stale async effects are dropped;
- focus requests carry origin/deadline/intent metadata;
- surfaces are derived from state;
- deterministic replay tests are possible.

## Evidence: onboarding duplicates real Niri semantics today

`completed/20260614-onboarding.md` says the interactive onboarding demo models real Niri consume-or-expel move semantics:

> `InteractiveMoveDemo` replaces the static shortcut list on the navigation step. It's a small in-memory column model (`MoveDemoModel`) modeling Niri's **consume-or-expel** move semantics: moving a window that shares a column **expels** it into its own column; a **solo** window **collocates** into the neighbour column (stacking) and its empty source column collapses.

Current implementation confirms the duplicate model:

- `Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift:11` — `final class MoveDemoModel: ObservableObject`
- local fake `Window`, `Column`, `Workspace` structs at `:12-27`
- local focus state at `:36-39`
- local viewport/scroll state at `:41-47`
- local fixed geometry at `:54-61`

This is not wrong for onboarding, but it is a signal: nehir now has demo semantics that can drift from real runtime semantics.

## Proposed nehir-shaped architecture

### Layer 1 — Pure Niri core

A pure module with no AX/AppKit/CGWindow dependencies.

Owns:

- workspaces;
- columns;
- window identities and constraints;
- focus within layout;
- viewport state;
- move/focus/window-placement commands;
- pure layout calculation;
- invariant validation.

Possible generic model:

```swift
struct CoreWindow<ID: Hashable>: Equatable {
    var id: ID
    var constraints: WindowConstraints
    var desiredSize: CGSize?
    var mode: WindowMode
}

struct CoreColumn<ID: Hashable>: Equatable {
    var id: ColumnID
    var windows: [ID]
    var width: ColumnWidth
}

struct CoreWorkspace<ID: Hashable>: Equatable {
    var id: WorkspaceID
    var columns: [CoreColumn<ID>]
    var focusedWindow: ID?
    var viewport: ViewportState
}
```

Runtime can use:

```swift
typealias RuntimeWindowID = WindowToken
```

Onboarding can use:

```swift
typealias DemoWindowID = Int
```

### Layer 2 — Pure reducer and layout/effect plans

Commands/events mutate pure state and produce effect descriptions:

```swift
enum CoreCommand<ID> {
    case focus(Direction)
    case moveFocused(Direction)
    case switchWorkspace(Direction)
    case addWindow(ID, PlacementContext)
    case removeWindow(ID)
    case setViewport(WorkspaceID, CGFloat)
}

enum LayoutEffect<ID> {
    case setFrame(ID, CGRect)
    case focus(ID)
    case setViewport(WorkspaceID, CGFloat)
    case hide(ID, HiddenPlacement)
    case show(ID)
}

struct LayoutPlan<ID> {
    var plannedRevision: UInt64
    var effects: [LayoutEffect<ID>]
    var sessionPatch: SessionPatch?
}
```

### Layer 3 — Interpreters

Real runtime interpreter:

- maps `WindowToken` to AX handles;
- writes frames;
- requests focus;
- updates borders/bars/surfaces;
- handles native fullscreen and real monitor/Space topology.

Demo interpreter:

- maps `Int` windows to SwiftUI fake tiles;
- animates frames/highlights;
- updates fake viewport;
- never touches AX.

### Layer 4 — Runtime store

Nehir's existing `RuntimeStore`/`ReconcileTxn` can evolve into the runtime adapter around the pure core rather than being replaced by upstream WorldStore.

Runtime-only state remains outside pure core:

- AX handles/subscriptions;
- process/app metadata;
- monitor topology;
- macOS Space topology if supported;
- pending focus requests;
- deadlines/timers;
- frame-write caches;
- diagnostics/traces.

## Migration phases

### A1 — Extract pure demo/real Niri movement semantics

Start small: consume-or-expel focus/move semantics.

Inputs:

- `InteractiveMoveDemo.MoveDemoModel` fake `Window/Column/Workspace` operations.
- Real Niri movement/focus operations in `Sources/Nehir/Core/Layout/Niri/*`.

Deliverable:

- a pure core module or set of files used by both onboarding and tests;
- onboarding no longer owns its own copy of consume-or-expel logic.

Subagent handoff:

> Design and implement A1 from `20260618-worldstore-pure-engine-reuse.md`: extract pure consume-or-expel Niri movement/focus semantics from `InteractiveMoveDemo.MoveDemoModel` and the real Niri engine into a shared pure model used by onboarding and tests. Do not touch AX frame writes.

Acceptance:

- Shared pure operations cover focus left/right/up/down and move left/right/up/down for the demo's scenarios.
- Onboarding uses the shared operations rather than duplicating them.
- Tests prove demo scenarios and real semantics agree.

### A2 — Introduce effect-plan boundary

Move from direct mutation to pure plan output for selected Niri operations.

Deliverable:

- `LayoutPlan`/`LayoutEffect` for a narrow command set;
- real interpreter and demo interpreter for that set.

Subagent handoff:

> Design A2 from `20260618-worldstore-pure-engine-reuse.md`: introduce a narrow `LayoutPlan`/`LayoutEffect` boundary for selected Niri commands, with real-runtime and SwiftUI-demo interpreters. Prototype one command path end-to-end.

Acceptance:

- One real command path and one onboarding/demo path consume the same plan.
- Effects are pure data.
- AX/AppKit only appears in the real interpreter.

### A3 — Add revision stamps to async plans

Address stale async layout/session/focus application without full WorldStore.

Inputs:

- `20260615-omniwm-390-workspace-restore-and-stale-selection.md`
- minor candidate M6

Deliverable:

- selection/session/layout revision counters;
- plans stamped with planned revision;
- apply path drops stale plans.

Subagent handoff:

> Implement A3/M6: add revision stamps to nehir async layout/session plans and drop stale application when selection/session changed after planning. Use existing hiro-390 discovery as source evidence.

Acceptance:

- Stale patch overwrite is reproduced in a test.
- Stale patch is dropped after revision guard.
- Current gesture-specific guard remains valid or is folded into the general mechanism.

### A4 — Add focus-request metadata / small intent ledger

Do not port upstream `IntentLedger` wholesale. Add the minimum model nehir needs:

- request origin;
- creation time;
- target token/workspace;
- deadline or grace window;
- classification of observed focus as echo, late echo, or external user focus.

Inputs:

- minor candidate M3;
- `20260616-omniwm-317-rapid-focus-revert-race.md`;
- `20260616-omniwm-379-focus-revert-grace-period.md`.

Subagent handoff:

> Design A4: a nehir-sized focus intent ledger or enriched `ManagedFocusRequest` model that handles rapid focus-next/prev stale AX echoes without adopting upstream `IntentLedger`/`DeadlineWheel` wholesale.

Acceptance:

- Proposed data model and callsites are documented.
- Includes tests for stale AX echo after a newer managed request.
- Does not reintroduce removed hotkey/Hyper concepts.

### A5 — Space-aware runtime mode as a runtime adapter concern

Space topology should not live in the pure Niri core. It belongs in runtime adapter state because it describes macOS WindowServer topology.

Inputs:

- `20260618-separate-spaces-and-monitor-arrangement.md`
- minor candidate M4

Deliverable:

- mode detection and diagnostics first;
- optional minimal topology for miss-eviction hardening.

Subagent handoff:

> Design A5: decide where macOS Space topology lives in nehir's runtime adapter, how it feeds missing-window detection, and how diagnostics/mouse-warp policy branch by Separate Spaces mode.

Acceptance:

- Clear boundary: pure Niri core remains Space-agnostic.
- Runtime model can pass inactive-Space exemption into eviction logic.
- Diagnostics reflect Separate Spaces ON/OFF behavior.

## Non-goals

- Do not copy upstream `WorldStore.swift` wholesale.
- Do not reintroduce Dwindle.
- Do not reintroduce upstream hotkey/Hyper management.
- Do not couple onboarding to AX or real windows.
- Do not make `RuntimeStore` a second god-object; keep pure core and runtime effects separate.

## Suggested first architecture spike

The safest first spike is **A1**, because it has bounded blast radius and immediate payoff:

1. Extract demo-compatible Niri move/focus pure operations.
2. Add tests that compare current onboarding scenarios.
3. Switch onboarding to shared operations.
4. Do not change real AX runtime behavior yet.

If A1 works cleanly, proceed to A2 effect plans. If A1 becomes awkward, that is useful evidence about where real Niri semantics are currently too coupled to runtime state.
