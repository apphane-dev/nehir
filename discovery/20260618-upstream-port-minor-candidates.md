# Upstream port candidates — Minor/runtime hardening

> ⚠️ **SUPERSEDED.** This was the original combined minor summary. Each item now has a proper per-cluster discovery doc; read those instead:
> - M1 — [`20260618-refused-frame-feedback-characterization.md`](20260618-refused-frame-feedback-characterization.md)
> - M2 — [`noop/20260618-upstream-size-quantum-rejected.md`](../noop/20260618-upstream-size-quantum-rejected.md) (rejection)
> - M3 — [`20260618-focus-request-origin-ffm-cursor-warp.md`](20260618-focus-request-origin-ffm-cursor-warp.md)
> - M4 — [`20260618-displays-separate-spaces-mode-detection.md`](20260618-displays-separate-spaces-mode-detection.md) (Stage 1) + [`20260618-space-topology-eviction-exemption.md`](20260618-space-topology-eviction-exemption.md) (Stage 2)
> - M5 — [`20260618-raw-multitouch-gesture-source.md`](20260618-raw-multitouch-gesture-source.md)
> - M6 — [`20260618-stale-session-selection-revision-guard.md`](20260618-stale-session-selection-revision-guard.md)
>
> Kept for history.

Source upstream range: `ee9b4f0707668d43f73e4af8c9a4f3581b8c11ce..BarutSRB/OmniWM main`, reviewed 2026-06-18.

Scope: upstream concepts that appear useful for nehir, but are not one-line/direct patch ports. Each needs adaptation to nehir's runtime boundaries or a product-mode decision.

Related docs:

- Patch fixes: [`20260618-upstream-port-patch-fixes.md`](20260618-upstream-port-patch-fixes.md)
- Separate Spaces / monitor arrangement: [`20260618-separate-spaces-and-monitor-arrangement.md`](20260618-separate-spaces-and-monitor-arrangement.md)
- Major architecture: [`20260618-worldstore-pure-engine-reuse.md`](20260618-worldstore-pure-engine-reuse.md)

## TL;DR

| ID | Candidate | Upstream source | Nehir state | Recommendation |
| --- | --- | --- | --- | --- |
| M1 | Feed terminally refused frame sizes into layout constraints | `40934c5` | nehir has resize-minimum learner but still has #403 loop | concept-port after/with P4 |
| M2 | Learned per-window size quantum | `6eb9ba0` | overlaps terminal/cell-quantization fixes | compare before port |
| M3 | Focus-request origin for FFM cursor-warp policy | `fce3a2c` | `ManagedFocusRequest` has no origin/timestamp | concept-port, skip Dwindle hunks |
| M4 | Space mode detection and diagnostics | `ee554c7`, `de971b6`, `2dcab36` subset | nehir has partial managed-Spaces helper, no runtime topology or mode detection | product-mode diagnostic first |
| M5 | Raw multitouch source for trackpad gestures | `06eb42d` | nehir uses `NSEvent.allTouches()` gesture tap; #53 is non-repro | evaluate as alternate source, not immediate bug fix |
| M6 | Cross-workspace stale focus/session revision guard | upstream WorldStore selection seq ideas, `713280e` nearby | `hiro-390` says restore miss open and selection patch partially guarded | implement nehir-shaped revision guard |

---

## M1 — Feed terminally refused frame sizes back into layout constraints

### Upstream source

Commit: `40934c5` — "Feed terminally refused frame sizes back into layout constraints".

Upstream adds the feedback path across:

- `AXFrameApplicationLedger`
- `AXManager`
- `LayoutRefreshController`
- `RefreshReason`
- `ServiceLifecycleManager`
- `WMController`
- `WindowModel`
- `WorkspaceManager`

### Nehir state

Nehir does **not** have upstream's `AXFrameApplicationLedger.swift`; frame-apply state lives in `AXManager.swift`/`AXWindow.swift` and layout feedback lives in `LayoutRefreshController.swift`.

Existing related nehir code:

- resize-minimum constraint learner: `LayoutRefreshController.swift:3230-3258`
- resize-minimum probe frame updates: `LayoutRefreshController.swift:3609-3670`
- recent frame-write failure state: `AXManager.swift:55-57`

Existing discovery:

- `20260616-omniwm-403-frame-write-race-min-size-suppression.md`

That discovery concludes nehir has the loop and recommends a patch-level suppression fix (P4), but also notes that the root cause is layout computing a target the app will refuse.

### Recommendation

Implement in two stages:

1. **Patch P4 first**: suppress snap-back-triggered relayout while `recentFrameWriteFailures[windowId]` is present.
2. **Then M1**: close the structural loop by feeding terminally refused sizes into the solver constraints so future layout plans stop asking for impossible frames.

Do not port upstream's file shape. Port the dataflow:

```text
AX write result says terminal refusal / verification mismatch
  -> extract observed accepted frame/minimum
  -> store per-window runtime constraint in workspace/window model
  -> schedule relayout with updated constraints
  -> solver uses constraint before computing target frames
```

### Subagent handoff: M1

Task:

> Implement M1 from `discovery/20260618-upstream-port-minor-candidates.md`: after P4 is present, concept-port upstream `40934c5` by feeding terminally refused AX frame sizes into nehir's runtime layout constraints. Compare with existing `resizeMinimumConstraints` and avoid duplicating the learner.

Acceptance:

- Terminal frame-write refusal produces a stored per-window constraint or equivalent solver input.
- Follow-up relayout no longer recomputes the same impossible target.
- Tests cover a fake refusal path and prove the next layout uses the learned constraint.
- Residual risk explains interaction with existing resize-minimum learner.

---

## M2 — Learned per-window size quantum for grid-snapping apps

### Upstream source

Commit: `6eb9ba0` — "Converge frame writes to a learned per-window size quantum".

Upstream teaches frame application to learn a per-window size quantum so apps that snap to a grid, especially terminals, converge instead of producing jittery verification mismatches.

### Nehir state

Nehir has related local work:

- `3254244f` — "Fix false resize minimum pinning for terminal windows with cell quantization overshoot (#45)"
- resize-minimum learner and probe path in `LayoutRefreshController.swift`

Because nehir already handled at least one terminal/cell-quantization bug, M2 must start with comparison rather than direct implementation.

### Recommendation

Treat M2 as a comparison task:

1. Reproduce or simulate a grid-snapping frame mismatch.
2. Identify whether nehir's existing terminal/cell-quantization fix already handles it.
3. If not, introduce a minimal quantum learner in nehir's current frame-apply path rather than upstream's `AXFrameApplicationLedger` file shape.

### Subagent handoff: M2

Task:

> Investigate M2 from `discovery/20260618-upstream-port-minor-candidates.md`: compare upstream `6eb9ba0`'s size-quantum concept with nehir's existing terminal/cell-quantization and resize-minimum handling. Implement only if a gap remains, with tests.

Acceptance:

- Written comparison of upstream concept vs nehir's current logic.
- If implemented: tests prove repeated snapped sizes converge and do not falsely pin a resize minimum.
- If rejected/noop: evidence that existing nehir behavior already covers the upstream case.

---

## M3 — Focus-request origin for FFM cursor-warp policy

### Upstream source

Commit: `fce3a2c` — "Fix cursor warp for focus follows mouse".

Upstream tracks the origin of managed focus requests so "move mouse to focused window" warps only for keyboard/programmatic focus, not hover-driven focus-follows-mouse. The upstream diff also touches Dwindle; ignore that part for nehir.

### Nehir state

Current nehir `ManagedFocusRequest` has no origin or creation timestamp:

- `Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:26-38`

```swift
struct ManagedFocusRequest: Equatable {
    let requestId: UInt64
    var token: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
    var retryCount: Int = 0
    var lastActivationSource: ActivationEventSource?
    var status: Status = .pending
}
```

Related local work/discoveries:

- `20260616-ffm-steals-focus-behind-overlay-on-stale-queued-mouse-moves.md`
- `20260616-omniwm-317-rapid-focus-revert-race.md`
- multi-monitor mouse-warp fixes in recent git history

### Recommendation

Add a small nehir-specific focus request origin model, e.g.:

```swift
enum ManagedFocusOrigin {
    case keyboard
    case command
    case focusFollowsMouse
    case programmatic
    case restore
}
```

Then thread it through focus request creation and mouse-warp decision points. This is useful both for FFM cursor-warp correctness and as groundwork for rapid-focus race hardening.

### Subagent handoff: M3

Task:

> Implement M3 from `discovery/20260618-upstream-port-minor-candidates.md`: add a nehir-sized focus request origin to `ManagedFocusRequest`, thread it through Niri/FFM focus requests, and make mouse-warp skip hover-origin focus confirmations while preserving keyboard/programmatic warp behavior.

Acceptance:

- Focus requests carry origin.
- FFM/hover-origin focus does not trigger move-mouse-to-focused-window warp.
- Keyboard/programmatic focus still warps when the user setting requires it.
- Tests cover at least hover vs keyboard origin.
- Dwindle code is not reintroduced.

---

## M4 — Space mode detection and diagnostics before full Space topology

### Upstream source

Relevant upstream commits:

- `de971b6` — add read-only Spaces queries to SkyLight.
- `ee554c7` — support/require Displays have separate Spaces.
- `2dcab36` — exempt windows on known-inactive Spaces from miss-eviction.

### Nehir state

Nehir has **partial** SkyLight managed-Spaces support:

- `Sources/Nehir/Core/SkyLight/SkyLight.swift:365` — `displayId(forSpaceId:among:)` uses `copyManagedDisplaySpaces`.

But nehir does **not** have:

- `SLSGetSpaceManagementMode` / `displaysHaveSeparateSpaces` mode detection;
- `SLSCopySpacesForWindows` / per-window Space lookup;
- `SpaceTopology` runtime model;
- `isWindowOnKnownInactiveSpace` eviction exemption.

Nehir's full rescan is on-screen/visible based:

- `AXManager.swift:450` uses `SkyLight.shared.queryAllVisibleWindows()`.
- `AXManager.swift:456-458` uses `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], ...)`.
- `LayoutRefreshController.swift:1424` removes missing windows based on that visible set.

Separate detailed note:

- `20260618-separate-spaces-and-monitor-arrangement.md`

### Recommendation

Do not immediately port upstream's "require separate Spaces" startup gate. First add mode detection and diagnostics:

- If Separate Spaces **OFF**: keep nehir's current vertical-arrangement diagnostic and allow nehir mouse-warp behavior.
- If Separate Spaces **ON**: suppress/reword the vertical-arrangement warning, because display surfaces appear isolated; recommend real physical arrangement; consider disabling or warning on nehir-controlled cross-monitor mouse warp until topology-aware focus/monitor routing is implemented.

Only after diagnostics are correct should nehir decide whether to implement full per-window Space topology.

### Subagent handoff: M4

Task:

> Implement M4 discovery/prototype from `discovery/20260618-upstream-port-minor-candidates.md` and `20260618-separate-spaces-and-monitor-arrangement.md`: add read-only detection of macOS Displays-have-separate-Spaces mode, expose it in diagnostics, and adjust vertical-arrangement/mouse-warp guidance by mode. Do not require the setting at startup.

Acceptance:

- Nehir can report Separate Spaces enabled/disabled/unavailable.
- Diagnostics distinguish Separate Spaces OFF vs ON.
- OFF keeps the current horizontal-arrangement warning.
- ON suppresses or changes that warning and flags topology/mouse-warp limitations clearly.
- No startup hard requirement is introduced.

---

## M5 — Raw multitouch source for trackpad gestures

### Upstream source

Commit: `06eb42d` — "Fix stuck trackpad workspace gestures".

Upstream moved workspace swipes to a raw MultitouchSupport gesture source so focused apps cannot starve the normal gesture stream, and so listening survives stop/restart and sleep/wake.

### Nehir state

Nehir currently uses a CGEvent/NSEvent gesture path. The onboarding demo intentionally mirrors the real 3-finger path, and `20260616-nehir-53-trackpad-four-finger-swipe-gesture.md` says:

- 4-finger mode could not be reproduced as globally broken;
- current fragility is exact-count matching over `NSEvent.allTouches()`;
- next best fix is better abort/skip tracing, then reporter-side failing trace.

### Recommendation

Do not port raw multitouch as a blind fix for #53. Evaluate it as an alternate input source with a feature flag or diagnostic branch. It may be a better long-term source, but it changes a sensitive input path.

### Subagent handoff: M5

Task:

> Investigate M5 from `discovery/20260618-upstream-port-minor-candidates.md`: compare upstream `06eb42d` raw MultitouchSupport gesture source with nehir's current CGEvent/NSEvent gesture path and onboarding mirror. Produce a prototype or a rejection memo; do not replace the production path without trace/test evidence.

Acceptance:

- Documents API/sandbox/permission implications of MultitouchSupport.
- Shows whether raw source solves exact-count/noisy-stream issues or only focused-app starvation.
- If prototyped, includes a fallback to existing gesture path and trace output.

---

## M6 — Cross-workspace stale focus/session revision guard

### Upstream source

Upstream's full solution appears inside the WorldStore/sequence-mark cluster, with nearby symptom commit `713280e` — "Clear stale pending managed focus on cross-workspace reassignment".

### Nehir state

Existing discovery:

- `20260615-omniwm-390-workspace-restore-and-stale-selection.md`

That discovery says:

1. persisted restore misses windows without `managedReplacementMetadata` — unfixed;
2. stale session patch overwrites newer selection — partially fixed only for gesture path; no general selection revision guard.

### Recommendation

Implement a nehir-sized revision guard rather than upstream WorldStore wholesale:

- Add a selection/session revision counter to the relevant workspace/session state.
- Stamp async layout/session patches with the revision they were planned against.
- Drop patches if a newer selection/session revision exists at apply time.
- Clear pending focus requests when cross-workspace reassignment invalidates their workspace context.

### Subagent handoff: M6

Task:

> Implement M6 from `discovery/20260618-upstream-port-minor-candidates.md` using `20260615-omniwm-390-workspace-restore-and-stale-selection.md` as the authoritative bug source: add a nehir-specific selection/session revision guard for async layout/session patches and clear stale pending focus when cross-workspace reassignment invalidates it.

Acceptance:

- Async session/layout patch carries planned selection/session revision.
- Apply path drops stale patches.
- Cross-workspace reassignment clears or revalidates pending managed focus.
- Tests reproduce the stale patch overwrite and prove it is dropped.

---

## Explicit non-goals for this minor track

- Do not reintroduce Dwindle.
- Do not reintroduce upstream hotkey/Hyper model.
- Do not port config round-trip preservation; nehir already solved it with diagnostics in `b7cfb91`.
- Do not require Separate Spaces at startup unless a later product decision explicitly chooses that stance.
- Do not move to upstream WorldStore; see major track.
