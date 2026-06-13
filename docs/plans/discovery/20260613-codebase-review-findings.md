# Codebase Review Findings

Multi-agent review (2026-06-13) covering architecture, risk hotspots, testing, and external surfaces (IPC/CLI/config). Curated to findings worth acting on; file references should be re-verified before implementing — line numbers drift.

## Quick Wins

### 1. IPC protocol version drift in docs
`docs/IPC-CLI.md` states protocol version 3; `Sources/NehirIPC/IPCModels.swift` implements version 6. One-line doc fix, but it breaks external client authors following the docs.

### 2. App-rule TOML parser silently swallows malformed lines
`Sources/Nehir/Core/Config/AppRuleFileStore.swift` (hand-rolled line parser, ~lines 107–152) `continue`s past anything it can't parse with no log or user-facing diagnostic. Same theme in the codec layer: semantic config errors (e.g., invalid `layout` value) quietly fall back to defaults. The rest of the config story is strong (live reload via inode fingerprinting, corrupt files moved aside) — a warning log on skipped lines / fallback-to-default closes the gap cheaply.

### 3. Workspace→monitor lookup has no reverse index. Done.
`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Monitors.swift` has two near-identical O(n) monitor scans (`monitorContaining(workspace:)` / `monitorForWorkspace(_:)`). A `workspaceId → monitorId` reverse index removes the duplication and the scan.

### 4. `syncWorkspaceAssignments()` doesn't validate monitor IDs. Done.
Same file: assignments aren't checked against the current monitor set, so stale monitor IDs can linger after detach. Relevant to the ongoing multi-monitor fixes (commits 306637d, 76bc0d3).

## Structural Refactors (small, high leverage)

### 5. WindowModel visibility: four optional fields pretending to be a state machine. Done.
In `Sources/Nehir/Core/Workspace/WindowModel.swift`, an entry's visibility is the product of `hiddenReason` × `floatingState` × `mode` × `manualLayoutOverride`, with nothing preventing unreachable combinations (e.g., scratchpad-hidden while assigned to an active workspace). Collapsing visibility into a single enum:

```swift
enum WindowVisibility {
    case visible
    case hiddenOffscreen(side: HideSide)
    case hiddenWorkspaceInactive
    case hiddenScratchpad
}
```

makes illegal states unrepresentable. Probably the highest-leverage refactor for preventing future state-sync bugs.

### 6. Centralize the RefreshReason → route mapping. Done.
`LayoutRefreshController` (~3,500 LOC) maps `RefreshReason` to one of five refresh routes (fullRescan / relayout / immediateRelayout / visibilityRefresh / windowRemoval) implicitly, scattered across scheduling call sites. A central table (`extension RefreshReason { var route: ...; var scheduling: ... }`) makes adding reasons and changing policies a one-place edit.

### 7. Narrow WMController's public surface
`WMController` (~3,600 LOC, ~190 funcs) is an intentional orchestrator, but handlers reach through it into `niriLayoutHandler` / `niriEngine` directly, giving command logic ad-hoc access to deep layout state. Cheap insurance before any second layout paradigm or new interactive mode: hide behind narrow protocols (e.g., `LayoutCoordinator`, `FocusCoordinator`), make `niriEngine` mutation explicit (`setNiriEngine(_:)`).

## Risk Hotspots (monitor, don't necessarily fix)

### 8. Release builds lose thread-safety checking in the AX layer
`Sources/Nehir/Core/Ax/ThreadGuardedValue.swift` verifies the calling thread only in DEBUG; Release uses `unsafelyUnwrapped` with no check, so a wrong-thread access corrupts silently instead of crashing loudly. Pattern is deliberate and discipline around it is good — consider whether a cheap Release-mode assertion is worth it. Related: `MouseWarpHandler`'s `nonisolated(unsafe) weak static var _instance` accessed from a CGEvent tap callback.

### 9. Fragility is concentrated where recent commits already point
`AXEventHandler.swift` (~3,800 LOC), `LayoutRefreshController.swift` (~3,500 LOC), and `WorkspaceManager.swift` (~4,000 LOC) each weave several concerns, and monitor attach/detach exercises all three at once. The close/collapse focus-guard logic (same-PID suppression + hidden-reason tracking + focus lease + previous-workspace memory) is the most delicate coordination point.

### 10. AX frame write verification can race
`AXWindow.swift` verifies written frames with a read that can race the window server's async update; mismatch is treated as recoverable, so real desync can persist silently during high-frequency layout operations. (Force-apply retry budget mitigates; flagged for awareness.)

## Testing Gaps

Coverage is strong overall (~1,170 test functions, ~50k LOC of tests; layout engine, AX events, refresh routing, IPC, and config all well covered). Gaps:

- **System-integration seams untested**: `LockScreenObserver`, `SleepPreventionManager`, `CGSEventObserver` have essentially no coverage.
- **No coverage measurement in CI** — no `--coverage` flag or reporting step.
- **No stress/scale tests**: 100+ windows, 10+ monitors, rapid monitor churn.
- **Gesture state machine edge cases** (momentum phase transitions, gesture-end during scroll animation) are thinly covered; `MouseEventHandler` (~2,000 LOC) has three overlapping phase enums and no state diagram.
- Known quirk: test runner works around an Xcode 26.4.1 SIGTRAP by running `IPCServerTests` isolated first; everything runs `--no-parallel`, suggesting latent shared-state sensitivity in the suite.

## Strengths Worth Preserving (design invariants)

These are load-bearing decisions — future changes should not erode them:

- **Layout engine is a pure state machine** — no AX calls; input is window list + geometry, output is a frame map. This is why it can carry 7,300 lines of direct unit tests.
- **Three-level window identity** — `WindowToken` (Sendable value) → `WindowHandle` (reference identity) → `AXWindowRef` (system resource) keeps AX handles out of layout code.
- **Per-app AX threading** — one hung app can't stall the main thread; frame writes batch per PID and apply in parallel.
- **IPC security posture** — `0600` socket, `getpeereid()` UID check, per-session token, 64 KB request cap, version negotiation with explicit `protocol_mismatch`; shell completions are generated from the same manifest the server uses, so they can't drift.
- **Config error recovery** — corrupt files moved aside, defaults fallback, live reload distinguishes external edits from internal writes via inode fingerprinting.
- **Docs match reality** — `ARCHITECTURE.md` is accurate; keep it that way (minor gaps: handler back-reference pattern and the projection-invalidation pipeline aren't diagrammed).
