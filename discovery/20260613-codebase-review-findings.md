# Codebase Review Findings

Groom 2026-07-07: partially resolved — findings #1–#7 shipped (PRs #40/#41/#42/#43/#46; WMController narrowing 776b9559); #8/#9/#10 remain open monitor-class analysis references (verified against main 7a025b78).

Multi-agent review (2026-06-13) covering architecture, risk hotspots, testing, and external surfaces (IPC/CLI/config). Curated to findings worth acting on; file references should be re-verified before implementing — line numbers drift.

## Quick Wins

### 1. IPC protocol version drift in docs. Done — docs updated 2026-07-01.
`docs/IPC-CLI.md` stated protocol version 3; `Sources/NehirIPC/IPCModels.swift` implements version 6. Fixed in the main tree on 2026-07-01 (`docs/IPC-CLI.md` now says 6, including the wire-format examples). Watch for recurrence: nothing ties the doc to `IPCProtocol.version`, so the number can drift again on the next protocol bump.

### 2. App-rule TOML parser silently swallows malformed lines. Done — merged 2026-07-02.
`Sources/Nehir/Core/Config/AppRuleFileStore.swift` now emits app-rule diagnostics for ignored/malformed lines and invalid semantic values, surfaces them in Settings Diagnostics/status surfaces, and offers a safe cleanup action for cleanable files with a timestamped backup. The parser path was also tightened for CRLF input, inline comments, and section-header detection so diagnostics do not reject or rewrite valid app-rule lines accidentally. Fixed in the main tree at `a2055ff8`.

### 3. Workspace→monitor lookup has no reverse index. Done — PR #40.
`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Monitors.swift` has two near-identical O(n) monitor scans (`monitorContaining(workspace:)` / `monitorForWorkspace(_:)`). A `workspaceId → monitorId` reverse index removes the duplication and the scan.

### 4. `syncWorkspaceAssignments()` doesn't validate monitor IDs. Done — PR #40.
Same file: assignments aren't checked against the current monitor set, so stale monitor IDs can linger after detach. Relevant to the ongoing multi-monitor fixes (commits 306637d, 76bc0d3).

## Structural Refactors (small, high leverage)

### 5. WindowModel visibility: four optional fields pretending to be a state machine. Done — PR #41.
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

### 6. Centralize the RefreshReason → route mapping. Done — PR #43.
`LayoutRefreshController` (~3,500 LOC) maps `RefreshReason` to one of five refresh routes (fullRescan / relayout / immediateRelayout / visibilityRefresh / windowRemoval) implicitly, scattered across scheduling call sites. A central table (`extension RefreshReason { var route: ...; var scheduling: ... }`) makes adding reasons and changing policies a one-place edit.

### 7. Narrow WMController's public surface. Done — shipped 2026-06-20, follow-ups 2026-07-02.
`WMController` (~3,600 LOC, ~190 funcs) is an intentional orchestrator, but handlers reach through it into `niriLayoutHandler` / `niriEngine` directly, giving command logic ad-hoc access to deep layout state. Cheap insurance before any second layout paradigm or new interactive mode: hide behind narrow protocols (e.g., `LayoutCoordinator`, `FocusCoordinator`), make `niriEngine` mutation explicit (`setNiriEngine(_:)`). Shipped to `main` as `776b9559` (coordinator protocols + `setNiriEngine` funnel), with follow-ups `e87bade3` (`preferredFrame(for:)` query seam) and `d1505910` (diagnostics extraction into `RuntimeDiagnosticsCoordinator`, WMController 5,031 → 3,939 LOC). Plan: `completed/20260614-narrow-wmcontroller-public-surface.md`; boundary verification: `discovery/20260702-mega-file-growth-and-narrow-wmcontroller-revisit.md`.

## Risk Hotspots (monitor, don't necessarily fix)

### 8. Release builds lose thread-safety checking in the AX layer
`Sources/Nehir/Core/Ax/ThreadGuardedValue.swift` verifies the calling thread only in DEBUG; Release uses `unsafelyUnwrapped` with no check, so a wrong-thread access corrupts silently instead of crashing loudly. Pattern is deliberate and discipline around it is good — consider whether a cheap Release-mode assertion is worth it. Related: `MouseWarpHandler`'s `nonisolated(unsafe) weak static var _instance` accessed from a CGEvent tap callback. Expanded in `discovery/20260614-release-ax-thread-affinity.md`.

### 9. Fragility is concentrated where recent commits already point
`AXEventHandler.swift` (~3,800 LOC), `LayoutRefreshController.swift` (~3,500 LOC), and `WorkspaceManager.swift` (~4,000 LOC) each weave several concerns, and monitor attach/detach exercises all three at once. The close/collapse focus-guard logic (same-PID suppression + hidden-reason tracking + focus lease + previous-workspace memory) is the most delicate coordination point. Expanded in `discovery/20260614-focus-guard-topology-fragility.md`.

### 10. AX frame write verification can race
`AXWindow.swift` verifies written frames with a read that can race the window server's async update; mismatch is treated as recoverable, so real desync can persist silently during high-frequency layout operations. (Force-apply retry budget mitigates; flagged for awareness.) Expanded in `discovery/20260614-ax-frame-write-verification-race.md`.

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
- **Docs match reality** — `ARCHITECTURE.md` is accurate; keep it that way (minor gaps: handler back-reference pattern and the projection-invalidation pipeline aren't diagrammed; see `completed/20260609-projection-invalidation-refactor.md`).

## Linked Documents

**Expanded into dedicated discoveries:**

- `discovery/20260614-release-ax-thread-affinity.md` — expands finding #8 (corrects the mental model, audits `MouseWarpHandler._instance`, lays out implementation options).
- `discovery/20260614-focus-guard-topology-fragility.md` — expands finding #9 (maps the four-way focus-guard coordination point and the monitor attach/detach seam; also references #5, #6, #7, #10).
- `discovery/20260614-ax-frame-write-verification-race.md` — expands finding #10 (corrects the readback-race mental model, traces how a racy readback propagates into the dedup/learn caches, audits the SkyLight oracle, lays out implementation options).

**Closed by PR (findings marked Done):**

- #7 narrow WMController surface — `776b9559`, follow-ups `e87bade3` + `d1505910`; plan now at `completed/20260614-narrow-wmcontroller-public-surface.md`.
- #2 app-rule TOML parse diagnostics — merged 2026-07-02 (`a2055ff8`).
- #3 reverse index + #4 monitor-ID validation — PR #40 (`ef6cd44`).
- #5 `WindowVisibility` enum — PR #41 (`ec615dc`).
- #6 centralized `RefreshReason` routing — PR #43 (`984c536`).

**Related completed plans (context for the invariants above):**

- `completed/20260609-projection-invalidation-refactor.md` — the projection-invalidation pipeline referenced under Strengths Worth Preserving.
