# Internal cluster tracing diagnostics

**Status:** completed, merged to `main` as `f6078799` on 2026-07-08.

This is the shipped first slice from
[`discovery/20260708-cluster-specific-tracing-improvements.md`](../discovery/20260708-cluster-specific-tracing-improvements.md):
OT-1 tracing infrastructure plus NF-1 generic command-target decision tracing.
It is observability-only; no window-management behavior change was intended.

## Actual implementation shipped

Source files changed in `main`:

- `Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift`
- `Sources/Nehir/Core/Controller/WMController.swift`
- `Sources/Nehir/Core/Diagnostics/BackgroundTraceBuffer.swift`
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift`
- `.changeset/20260708123713-internal-cluster-tracing-diagnostics.md`

Shipped behavior:

- Added a lazy named runtime decision-event API:
  `recordRuntimeDecisionEvent(named:cluster:fields:)` plus
  `RuntimeDecisionTraceField`.
- Added a dedicated runtime decision trace ring and a `## Runtime decision trace`
  section to full runtime trace captures.
- Added `eventNameCounts` to background trace clip exports so captures summarize
  stable `event=...` names.
- Decoupled the background trace buffer from active runtime trace capture: the
  effective gate is now developer mode, not `developerModeEnabled && active
  capture`.
- Stopped clearing the background ring/drafts on trace capture start/stop, so a
  recent background clip can retain context across explicit capture sessions.
- Let viewport trace records participate in the background buffer while developer
  diagnostics are enabled, instead of returning before background append unless a
  capture session is active.
- Instrumented `WMController.managedCommandTarget()` with NF-1 decision events:
  `command_target.resolve.begin`, `command_target.resolve.accept`, and
  `command_target.resolve.decline`.
- Command-target fields include stable reason, compact pid/window token values,
  frontmost/confirmed/layout-selection state, interaction workspace/monitor,
  non-managed focus state, recently-left-non-managed-focus age, sticky exception
  state, and final target/source.
- Added `WorkspaceManager.nonManagedFocusExitAge()` so traces can report the age
  of the recently-left non-managed-focus guard instead of only a boolean.
- Added a `none` changeset: internal diagnostics only, no release note impact.

Validation reported by the worker before merge:

- `mise run format:check`
- `swift build`
- `mise run test:compile`

## Explicitly not completed by this slice

The discovery remains partially open for later observability work:

- Non-managed-focus enter/exit arming detail events.
- Explicit-token workspace-bar/context-menu move traces.
- LC-1 lifecycle oracle/liveness/action envelope.
- VR-1 engine-level reveal/snap decision events and viewport mutation ring.
- XD-1 cross-display transition correlation and materialization checkpoints.
- TF-1 classification/metadata/projection decision stream.
- A broader typed event registry beyond the small `event=` envelope used here.
