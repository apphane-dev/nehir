# Narrow WMController's Public Surface

## Overview

`WMController` is an intentional orchestrator (~3,670 LOC). It exposes two layout seam points
that handlers and command logic reach through directly:

1. `var niriEngine: NiriLayoutEngine?` — the live layout engine, mutable from anywhere in the
   module.
2. `var niriLayoutHandler: NiriLayoutHandler { layoutRefreshController.niriHandler }` — a
   computed pass-through whose ~41-method concrete surface is the de-facto layout command API.

The risk is not size; it is that **command logic gets ad-hoc access to deep layout state**. Today
every handler can both read and reassign the engine and call any of 41 handler methods, so there
is no boundary that says "this is the layout command surface" versus "this is layout-pipeline
plumbing". Before a second layout paradigm or a new interactive mode lands, narrow that surface so
future reach-through is a compile error, not a code-review hope.

Two concrete, independently-shippable changes:

- **Make `niriEngine` mutation explicit** via `setNiriEngine(_:)` — `private(set)` storage plus a
  single assignment funnel.
- **Hide the layout command surface behind a narrow `LayoutCoordinator` protocol** (and a smaller
  `FocusCoordinator` for the interactive-mode ops that currently poke the engine directly).

## Context (from discovery)

- Discovery doc: `discovery/20260613-codebase-review-findings.md` — §7 "Narrow
  WMController's public surface". Items 1–6 in that review are done; this is the remaining
  structural item.
- Orchestrator: `Sources/Nehir/Core/Controller/WMController.swift`
  - `var niriEngine: NiriLayoutEngine?` declared at L116 (module-internal, freely read/written).
  - `var niriLayoutHandler: NiriLayoutHandler` computed at L155, forwarding to
    `layoutRefreshController.niriHandler`.
- Handler: `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` — `@MainActor final class`,
  41 funcs, holds `weak var controller: WMController?`.
- Engine mutation is **single-site today**: `NiriLayoutHandler.enableNiriLayout(revealPartial:)`
  at L1443–1456 is the only place that assigns `controller.niriEngine = engine` (L1449). It is
  immediately followed by three side effects:
  `controller.syncNiriResizeTraceSink()`, `syncMonitorsToNiriEngine()`, and
  `controller.layoutRefreshController.requestRefresh(reason: .layoutConfigChanged)`.
- External read footprint of `.niriEngine` (measured 2026-06-14):
  - 34 production read sites outside `WMController.swift` / `NiriLayoutHandler.swift`
    (`CommandHandler`, `MouseEventHandler`, `AXEventHandler`, `LayoutRefreshController`,
    `WindowActionHandler`, `WorkspaceNavigationHandler`, `ServiceLifecycleManager`,
    `FocusBorderController`, `OverviewController`, `IPCQueryRouter`, `WorkspaceBarDataSource`).
  - 18 internal reads inside `NiriLayoutHandler` itself.
  - 23 internal reads inside `WMController`.
  - **95 read sites in `Tests/NehirTests/`** (engine setup/inspection in fixture builders).
  - **1** write site (above).
- The ~25 `niriLayoutHandler` methods touched by `CommandHandler` form the coherent "layout
  command surface"; the remaining handler funcs are layout-pipeline internals
  (`layoutWithNiriEngine`, `registerScrollAnimation`, `tickScrollAnimation`,
  `applyFramesOnDemand`, `commitWithPredictedAnimation`, …) used by the refresh pipeline and tests.

## Goal

- `niriEngine` can only be reassigned through `WMController.setNiriEngine(_:)`. Any future direct
  assignment is a compile error.
- Command logic (`CommandHandler`, and progressively the other handlers) depends on a narrow
  `LayoutCoordinator` protocol, not the 41-method concrete `NiriLayoutHandler`.
- The interactive-mode ops that currently call the engine directly (`interactiveMoveCancel`,
  `clearInteractiveResize`) and the focus-query reads (`findNode` for focus, fullscreen check) go
  through a `FocusCoordinator` so a new interactive mode has an explicit, auditable seam.

## Non-goals

- **Do not make `niriEngine` fully `private`.** 95 test reads + 34 production reads of the engine
  for legitimate whole-layout work (IPC/Overview snapshots, WorkspaceBar ordering, refresh-pipeline
  relayout, lifecycle monitor cleanup, rekey, config update) mean full privatization is large,
  risky churn — the opposite of "cheap insurance". `private(set)` captures the win (mutation
  funnel) without the churn.
- **Do not extract a protocol covering all 41 `NiriLayoutHandler` funcs.** Only the externally-used
  command surface goes on `LayoutCoordinator`. Layout-pipeline internals stay concrete.
- **Do not change `NiriLayoutHandler` internals** or its `weak controller` back-reference.
- **Do not add behavior in Phase 1.** `setNiriEngine(_:)` is a pure assignment funnel at first;
  folding in the post-assignment side effects is an explicit, separately-validated option.
- **Do not migrate test fixtures en masse.** Tests keep reading `controller.niriEngine` directly —
  that is the sanctioned inspection seam, and `private(set)` preserves read access.

## Proposed model

### Explicit engine mutation

```swift
// WMController.swift
private(set) var niriEngine: NiriLayoutEngine?

/// The only sanctioned way to install/replace the live Niri engine.
/// Reads remain module-internal; writes are funneled here so future
/// ad-hoc assignments are caught at compile time.
func setNiriEngine(_ engine: NiriLayoutEngine?) {
    niriEngine = engine
}
```

The single existing call site becomes:

```swift
// NiriLayoutHandler.enableNiriLayout
controller.setNiriEngine(engine)
```

### LayoutCoordinator protocol

A new file `Sources/Nehir/Core/Controller/LayoutCoordinator.swift`:

```swift
@MainActor protocol LayoutCoordinator: AnyObject {
    // Focus / movement
    func focusNeighbor(direction: Direction)
    @discardableResult func moveWindow(direction: Direction) -> NiriWindowMoveResult
    func moveWindowOrToAdjacentWorkspace(direction: Direction)
    func consumeOrExpelWindow(direction: Direction)
    func consumeWindowIntoColumn()
    func expelWindowFromColumn()
    func toggleFullscreen()

    // Sizing
    func cycleSize(forward: Bool)
    func cycleWindowWidth(forward: Bool)
    func cycleWindowHeight(forward: Bool)
    func toggleColumnFullWidth()
    func expandColumnToAvailableWidth()
    func resetWindowHeight()
    func setColumnWidth(_ change: NiriSizeChange)
    func setWindowWidth(_ change: NiriSizeChange)
    func setWindowHeight(_ change: NiriSizeChange)
    func balanceSizes()

    // Viewport
    func scrollViewport(direction: Direction)

    // Composite operations used by combined-navigation commands
    func activateNode(
        _ node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        options: NiriActivationOptions
    )
    func withNiriOperationContext(
        perform operation: (NiriOperationContext, inout ViewportState) -> Bool
    )
    func withNiriWorkspaceContext(
        perform: (NiriLayoutEngine, WorkspaceDescriptor.ID, MotionSnapshot,
                  inout ViewportState, Monitor, CGRect, CGFloat) -> Void
    )
}
```

`NiriLayoutHandler` conforms (it already implements every method). `CommandHandler` is migrated to
hold `var layoutCoordinator: LayoutCoordinator?` instead of reaching through
`controller.niriLayoutHandler` for these commands.

### FocusCoordinator protocol (smaller, second pass)

A new file `Sources/Nehir/Core/Controller/FocusCoordinator.swift`:

```swift
@MainActor protocol FocusCoordinator: AnyObject {
    /// Cancel an in-flight interactive move (mouse drag).
    func interactiveMoveCancel()
    /// Tear down any active interactive resize session.
    func clearInteractiveResize()
    /// Read-only focus queries used by focus-dependent UI (border, ax events).
    func focusedNode(for token: WindowToken) -> NiriNode?
    func isFocusedWindowFullscreen(_ token: WindowToken) -> Bool
}
```

`WMController` provides a default conformance/adaptor that forwards to `niriEngine`.
`MouseEventHandler` and `FocusBorderController` depend on the protocol. This is the seam a *new*
interactive mode (e.g. a gesture-driven mode, or a non-Niri layout's focus model) would implement.

## Phase 1 — Funnel `niriEngine` mutation through `setNiriEngine(_:)`

No behavior change. Pure compile-time boundary.

- Change `var niriEngine: NiriLayoutEngine?` → `private(set) var niriEngine: NiriLayoutEngine?`
  in `WMController.swift` (L116).
- Add `func setNiriEngine(_ engine: NiriLayoutEngine?)` to `WMController`.
- Update the single write site in `NiriLayoutHandler.enableNiriLayout` (L1449) to call
  `controller.setNiriEngine(engine)`.
- Leave all read sites (`controller.niriEngine`, `controller?.niriEngine`, `wmController?.niriEngine`,
  including all 95 test reads) untouched — `private(set)` preserves read access.

Validation:

- `swift build` succeeds. If it does not, the compiler has found an unexpected second write site —
  investigate, do not silence. The whole point of this phase is to prove single-site mutation.
- `swift test` is unchanged-green (no behavior change; all reads still compile).
- Grep proves zero remaining `controller.niriEngine =` / `niriEngine = ` assignments outside
  `setNiriEngine` and the `private(set)` storage declaration.

**Decision point (do not decide for the implementer):** whether to fold the three side effects
that currently follow the assignment (`syncNiriResizeTraceSink()`, `syncMonitorsToNiriEngine()`,
`requestRefresh(reason: .layoutConfigChanged)`) into `setNiriEngine` itself. Pro: every future
engine swap gets the post-install wiring for free and cannot forget it. Con: it is a behavior
change, couples the setter to the refresh pipeline, and there is exactly one caller today. Default
recommendation: keep Phase 1 pure (funnel only); revisit folding once a second caller appears.

## Phase 2 — Introduce `LayoutCoordinator` and migrate `CommandHandler`

- Add `Sources/Nehir/Core/Controller/LayoutCoordinator.swift` with the protocol above. Confirm the
  exact member list against the methods `CommandHandler` actually calls (see Context) — add only
  what is used, nothing speculative.
- Make `NiriLayoutHandler: LayoutCoordinator` (conformance is free — signatures already match).
- Expose the coordinator from `WMController`:
  `var layoutCoordinator: LayoutCoordinator { niriLayoutHandler }` (computed; the concrete handler
  already conforms).
- Migrate `CommandHandler`'s `controller.niriLayoutHandler.<command>` call sites to
  `controller.layoutCoordinator.<command>`. This is the single largest external consumer (~22 of
  the ~25 command calls) and the most coherent surface, so it goes first.
- Do **not** migrate `MouseEventHandler`, `AXEventHandler`, `OverviewController`,
  `WindowActionHandler` in this phase — they also call `insertWindow` / `activateNode` /
  `updateTabbedColumnOverlays` / `hasScrollAnimation`, some of which are layout-pipeline methods
  that deliberately stay off the protocol. Those are assessed in Phase 4.

Validation:

- `swift build` succeeds.
- `swift test` green. No behavior change — the protocol is a type-level indirection, the concrete
  object is unchanged.
- `CommandHandler` no longer references `controller.niriLayoutHandler` for any method on the
  protocol; grep confirms remaining `niriLayoutHandler` references in `CommandHandler` are only
  for methods intentionally left off the protocol (if any).

## Phase 3 — Introduce `FocusCoordinator` for interactive-mode + focus-query ops

Smaller pass. This is the "new interactive mode" insurance the finding calls out.

- Add `Sources/Nehir/Core/Controller/FocusCoordinator.swift` with the protocol above.
- Add a `WMController`-level adaptor (or have `WMController` conform) that forwards
  `interactiveMoveCancel` / `clearInteractiveResize` to `niriEngine` and wraps the `findNode` /
  fullscreen reads used by `FocusBorderController`.
- Migrate:
  - `MouseEventHandler` L561 (`controller.niriEngine?.interactiveMoveCancel()`) and
    L570 (`controller.niriEngine?.clearInteractiveResize()`) → `controller.focusCoordinator.*`.
  - `FocusBorderController` L415 (`controller.niriEngine?.findNode(for: token)?.isFullscreen`)
    → `controller.focusCoordinator.isFocusedWindowFullscreen(token)`.

Validation:

- `swift build` succeeds.
- `swift test` green.
- Grep confirms `MouseEventHandler` and `FocusBorderController` no longer reach into
  `niriEngine` directly for these ops.

If, during implementation, the `FocusCoordinator` surface proves too thin to justify a protocol
(two cancel methods + one bool query), the acceptable fallback is to route just the two
interactive-cancel ops through named `WMController` methods
(`cancelInteractiveMove()`, `clearInteractiveResize()`) and defer the protocol. The goal is the
explicit seam, not the protocol for its own sake — do not over-engineer.

## Phase 4 — Audit and document the remaining engine reads

The remaining `.niriEngine` reads are infrastructure, not command-logic reach-through. This phase
classifies them and decides: document as sanctioned seams, or route behind a read protocol.

Likely-sanctioned (keep as direct reads, document why):

- Whole-layout snapshots: `IPCQueryRouter` L140 (`WorkspaceEntryOrdering.orderedEntries(... engine:)`),
  `OverviewController` L314 (`engine.overviewSnapshot(for:)`).
- Refresh pipeline relayout: `LayoutRefreshController` L382/3029/3546 (reads engine to apply frames).
- WorkspaceBar ordering query: `WorkspaceBarDataSource` L103 (`engine.columns(in:)`).
- Lifecycle/topology sync: `ServiceLifecycleManager` L144 (`cleanupRemovedMonitor`),
  `NiriLayoutHandler.syncMonitorsToNiriEngine` / `refreshResolvedMonitorSettings` /
  `updateNiriConfig`.
- Structural mutations that already live behind handler methods: `AXEventHandler` L2171
  (`rekeyWindow`), `NiriLayoutHandler` L1496 (`updateConfiguration`).
- Rendered-frame lookups for AX placement: `AXEventHandler` L3072
  (`findNode(for:).renderedFrame`).

Candidate for a narrow read protocol (only if Phase 4 reveals >1 consumer of the same query — do
not speculatively extract): the "rendered frame for a token" lookup
(`niriEngine?.findNode(for: token).flatMap { $0.renderedFrame ?? $0.frame }`) appears in
`AXEventHandler` and resembles the `FocusBorderController` fullscreen query. If they cluster,
a `LayoutStateQuery` protocol (`renderedFrame(for:)`, `isFullscreen(_:)`) is worth it; otherwise
leave them.

Validation:

- Produce a short table in the plan's completion note mapping every surviving `.niriEngine` read
  to its justification (snapshot / relayout / sync / query). This table is the deliverable — it
  makes the next reviewer's audit cheap.

## Rollout strategy

Small, no-behavior-change PRs, each independently shippable:

1. **Phase 1** (`setNiriEngine`) — ship first. Highest leverage (compile-enforced mutation
   boundary), lowest risk, zero migration. This alone satisfies the explicit-mutation half of the
   finding.
2. **Phase 2** (`LayoutCoordinator` + `CommandHandler`) — ship second. Delivers the narrow-protocol
   half for the command surface, which is the bulk of the ad-hoc access.
3. **Phase 3** (`FocusCoordinator`) — ship if/when the interactive-mode insurance is wanted. Can
   follow Phase 2 by a release or more; no dependency.
4. **Phase 4** (audit/doc) — ship last; pure documentation unless a real second consumer surfaces.

Phases are ordered by leverage/risk ratio, not by hard dependency. Phase 1 does not require Phase 2.
Phase 3 does not require Phase 2. Phase 4 benefits from all three being done but can run
partially after Phase 1.

## Risks

- **Protocol drift**: if `LayoutCoordinator` grows beyond the command surface (handlers start
  adding layout-pipeline methods "while we're here"), it stops being narrow. Mitigation: the
  protocol is defined by *what `CommandHandler` calls*, reviewed at Phase 2 merge.
- **Over-extraction**: the `FocusCoordinator`/`LayoutStateQuery` protocols are speculative
  insurance. If a phase's protocol ends up with one method and one conformer, prefer a named
  `WMController` method instead (Phase 3 fallback).
- **Folded side effects in `setNiriEngine`**: if Phase 1 folds the post-assignment wiring, a future
  caller that wants to install an engine *without* triggering a refresh (e.g. a test, or a
  speculative second layout paradigm) has to opt out. Mitigation: keep Phase 1 pure; fold only
  when a second real caller appears and its needs are known.
- **Test churn temptation**: 95 test sites read `controller.niriEngine`. Resist migrating them to
  a protocol — they are the inspection seam and `private(set)` keeps them working. Migrating them
  would balloon the change and buy nothing.

## Success criteria

- `niriEngine` storage is `private(set)`; the compiler rejects any assignment outside
  `setNiriEngine(_:)`.
- `CommandHandler` depends on `LayoutCoordinator`, not the 41-method `NiriLayoutHandler`.
- The interactive-cancel and focus-fullscreen reads go through an explicit seam (protocol or named
  methods), so a new interactive mode has an auditable boundary.
- Every surviving `.niriEngine` read is documented in the Phase 4 table with a one-line
  justification.
- All phases are no-behavior-change: `swift build` clean and `swift test` green after each.
