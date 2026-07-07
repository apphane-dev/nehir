# Upstream port candidates — Patch fixes

Groom 2026-07-07: superseded — historical combined summary; the per-cluster P1–P4 discovery docs are canonical and all landed (see 20260618-upstream-port-roadmap.md).

> ⚠️ **SUPERSEDED.** This was the original combined patch summary. Each item now has a proper per-cluster discovery doc; read those instead:
> - P1 — [`20260618-upstream-rescan-eviction-hysteresis.md`](../completed/20260618-upstream-rescan-eviction-hysteresis.md)
> - P2 — [`20260618-upstream-refresh-coalescing.md`](../completed/20260618-upstream-refresh-coalescing.md)
> - P3 — [`20260618-upstream-monitor-orientation-override.md`](../completed/20260618-upstream-monitor-orientation-override.md)
> - P4 — [`20260618-upstream-frame-write-failure-suppression.md`](../completed/20260618-upstream-frame-write-failure-suppression.md)
>
> Kept for history.

Source upstream range: `ee9b4f0707668d43f73e4af8c9a4f3581b8c11ce..BarutSRB/OmniWM main`, reviewed 2026-06-18.

Scope: small fixes that can be delivered independently in nehir without adopting upstream's WorldStore/EventIntake/IntentLedger runtime rewrite.

## TL;DR

Four patch-level candidates are ready for dedicated implementation subagents:

| ID | Candidate | Upstream reference | Nehir evidence | Recommendation |
| --- | --- | --- | --- | --- |
| P1 | require two rescan misses before eviction | `ba9d1e2` | `LayoutRefreshController.swift:1424` still passes `requiredConsecutiveMisses: 1` | direct patch |
| P2 | do not cancel same-kind refreshes | `631caa9` | `LayoutRefreshController.swift:1636-1651` cancels `.immediateRelayout/.immediateRelayout` and `.relayout/.relayout` | direct patch |
| P3 | preserve monitor orientation overrides | `8338d97` | `NiriMonitor.swift:50` overwrites override with `autoOrientation`; IPC uses `monitor.autoOrientation` | direct patch |
| P4 | suppress frame-change relayout after recent AX write failure | closed Hiro PR #403 concept; nehir discovery exists | `AXManager.swift:165` checks pending/last-applied but not `recentFrameWriteFailures` | direct nehir-native patch |

These are intentionally scoped below "minor" because each should be safe to implement and test in a normal bug-fix changeset.

---

## P1 — Require two consecutive full-rescan misses before evicting windows

### Upstream source

Commit: `ba9d1e271799a6532bb4aed24bb0080c66629cde` — "Require two consecutive rescan misses before evicting windows".

Upstream diff is effectively:

```swift
- removeMissing(keys: seenKeys, requiredConsecutiveMisses: 1)
+ removeMissing(keys: seenKeys, requiredConsecutiveMisses: 2)
```

### Nehir evidence

Verified current nehir:

- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1424`
  ```swift
  controller.workspaceManager.removeMissing(keys: seenKeys, requiredConsecutiveMisses: 1)
  ```
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2844` exposes the same `requiredConsecutiveMisses` API.
- `Sources/Nehir/Core/Workspace/WindowModel.swift:737` implements the threshold.

### Why it matters

Nehir's full rescan builds `seenKeys` from on-screen/visible sources. A transient miss should not immediately delete a known window from the model. This is especially relevant around AX timing, monitor/Space changes, app recreation, and temporarily invisible windows.

### Implementation notes

- Change the full-refresh callsite to `requiredConsecutiveMisses: 2`.
- Add or update a unit test around `WindowModel.confirmedMissingKeys` or `WorkspaceManager.removeMissing` proving:
  1. first miss increments but does not remove;
  2. second consecutive miss removes;
  3. seeing the key resets the miss counter.

### Subagent handoff: P1

Task:

> Implement P1 from `discovery/20260618-upstream-port-patch-fixes.md`: change full-rescan eviction to require two consecutive misses, add focused tests for miss-counter behavior, and verify no unrelated behavior changes.

Acceptance:

- `LayoutRefreshController` full rescan passes `requiredConsecutiveMisses: 2`.
- Tests cover first miss, second miss, and reset-on-seen behavior.
- Run relevant Swift tests, preferably `swift test` or focused `NehirTests` if full suite is too slow.

---

## P2 — Coalesce same-kind refreshes without cancelling the active task

### Upstream source

Commit: `631caa9` — "Coalesce same-kind refreshes without cancelling".

Upstream stopped cancelling the active task when a pending refresh is the same kind as the active refresh:

- `.immediateRelayout` + `.immediateRelayout`
- `.relayout` + `.relayout`

### Nehir evidence

Current nehir still cancels both cases in `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`:

```swift
// :1636-1638
case (.immediateRelayout, .immediateRelayout):
    mergePendingRefresh(refresh)
    layoutState.activeRefreshTask?.cancel()

// :1646-1651 — .relayout/.relayout is part of a canceling case group
case (.relayout, .fullRescan),
     (.relayout, .immediateRelayout),
     (.relayout, .relayout),
     (.relayout, .windowRemoval):
    mergePendingRefresh(refresh)
    layoutState.activeRefreshTask?.cancel()
```

### Why it matters

Cancelling same-kind refreshes can turn harmless bursty scheduling into self-inflicted churn: the in-flight relayout is cancelled, a new one starts, then another same-kind request cancels it again. Upstream release notes describe this as "back-to-back relayouts coalesce instead of cancelling each other."

### Implementation notes

- Remove the cancellation from `.immediateRelayout/.immediateRelayout`.
- Split `.relayout/.relayout` out of the canceling case group and make it merge only.
- Preserve cancellation for escalation cases (`relayout → fullRescan`, `relayout → immediateRelayout`, `relayout → windowRemoval`, etc.).

### Suggested tests

Add focused `RefreshRoutingTests` or equivalent tests that assert scheduling decisions:

1. active immediate relayout + new immediate relayout => merges, does not cancel active task;
2. active relayout + new relayout => merges, does not cancel active task;
3. active relayout + full rescan/window removal still cancels/escalates.

### Subagent handoff: P2

Task:

> Implement P2 from `discovery/20260618-upstream-port-patch-fixes.md`: coalesce same-kind relayout/immediate-relayout refreshes without cancelling active work, preserving cancellation for escalation cases. Add focused refresh-routing tests.

Acceptance:

- Same-kind relayout cases do not call `activeRefreshTask?.cancel()`.
- Escalation cases still cancel.
- Tests cover both positive and negative cases.

---

## P3 — Preserve monitor orientation overrides during output-size updates and IPC

### Upstream source

Commit: `8338d97` — "Preserve monitor orientation overrides and report them over IPC".

Upstream changes:

1. `NiriMonitor.updateOutputSize` no longer overwrites an existing orientation when no explicit override argument is supplied.
2. IPC display query reports `settings.effectiveOrientation(for:)` rather than `monitor.autoOrientation`.

### Nehir evidence

Current nehir has the same overwrite behavior:

- `Sources/Nehir/Core/Layout/Niri/NiriMonitor.swift:47-50`
  ```swift
  func updateOutputSize(monitor: Monitor, orientation: Monitor.Orientation? = nil) {
      frame = monitor.frame
      visibleFrame = monitor.visibleFrame
      self.orientation = orientation ?? monitor.autoOrientation
  ```

Current IPC path still reports auto orientation:

- `Sources/Nehir/IPC/IPCQueryRouter.swift:415`
  ```swift
  orientation: include("orientation", in: fields) ? ipcDisplayOrientation(from: monitor.autoOrientation) : nil,
  ```

Nehir already has the needed effective-orientation API:

- `Sources/Nehir/Core/Config/SettingsStore.swift:774`
  ```swift
  func effectiveOrientation(for monitor: Monitor) -> Monitor.Orientation
  ```

### Why it matters

A user monitor-orientation override should survive display updates/reconfiguration. If `updateOutputSize` silently resets to auto orientation, portrait/rotated display behavior can flip back under the user and IPC reports a value inconsistent with runtime layout.

### Implementation notes

- In `updateOutputSize`, only assign `self.orientation` when the optional `orientation` argument is non-nil.
- In IPC, report `controller.settings.effectiveOrientation(for: monitor)`.
- Check all callsites that pass an explicit orientation still do so intentionally.

### Suggested tests

1. Unit test `NiriMonitor.updateOutputSize` preserves pre-existing orientation when called with `orientation: nil`.
2. Unit/integration test IPC display model reports effective override, not auto orientation.

### Subagent handoff: P3

Task:

> Implement P3 from `discovery/20260618-upstream-port-patch-fixes.md`: preserve explicit monitor orientation overrides across output-size updates and report effective orientation over IPC. Add targeted tests.

Acceptance:

- `NiriMonitor.updateOutputSize(..., orientation: nil)` does not reset an existing orientation.
- IPC display `orientation` reflects settings override.
- Tests prove both behaviors.

---

## P4 — Suppress app-originated frame-change relayout after a recent frame-write failure

### Source and relationship to existing discovery

This is the narrow implementation recommendation from existing nehir discovery:

- `discovery/20260616-omniwm-403-frame-write-race-min-size-suppression.md`

It is based on a closed upstream/Hiro PR concept, not a merged upstream commit. It remains patch-sized in nehir.

### Nehir evidence

Current state maps exist in `Sources/Nehir/Core/Ax/AXManager.swift`:

- `lastAppliedFrames` at `:55`
- `pendingFrameWrites` at `:56`
- `recentFrameWriteFailures` at `:57`

Suppression currently checks pending and last-applied only:

```swift
// Sources/Nehir/Core/Ax/AXManager.swift:165
func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
    if pendingFrameWrites[windowId] != nil {
        return true
    }
    guard let observedFrame,
          let lastAppliedFrame = lastAppliedFrames[windowId]
    else {
        return false
    }
    return observedFrame.approximatelyEqual(to: lastAppliedFrame, tolerance: 0.5)
}
```

The safety property already exists: every new enqueue clears the failure flag:

- `AXManager.swift:601-602`
  ```swift
  pendingFrameWrites[windowId] = frame
  recentFrameWriteFailures.removeValue(forKey: windowId)
  ```

### Why it matters

For apps that reject a too-small frame, nehir records a recent failure but then allows the app's snap-back `kAXFrameChangedNotification` to trigger a new relayout. That recomputes and writes the same bad target, sustaining a loop. Suppressing frame-change relayout while a recent failure is recorded breaks the app-notification trigger. Legitimate new relayouts still proceed because enqueue clears the flag.

### Implementation notes

Add one branch:

```swift
if recentFrameWriteFailures[windowId] != nil {
    return true
}
```

Place it after the pending check and before the last-applied guard.

### Suggested tests

Reuse the detailed tests already proposed in `20260616-omniwm-403-frame-write-race-min-size-suppression.md`:

1. recent failure + no pending + nil/stale last-applied suppresses;
2. enqueue clears failure and suppression ends;
3. optional end-to-end bounded retry test via frame-apply test override.

### Subagent handoff: P4

Task:

> Implement P4 from `discovery/20260618-upstream-port-patch-fixes.md` and the detailed `20260616-omniwm-403-frame-write-race-min-size-suppression.md`: suppress frame-change relayouts while `recentFrameWriteFailures[windowId]` is present, and add the focused regression tests.

Acceptance:

- `shouldSuppressFrameChangeRelayout` returns true for recent-failure windows.
- The failure flag remains cleared on new enqueue, preserving legitimate relayouts.
- Tests prove suppression window is bounded.

---

## Not included in patch track

The following are intentionally not patch items:

- Upstream `40934c5` refused-frame-size feedback: valuable, but nehir file shape differs and it should be coordinated with P4.
- Upstream `6eb9ba0` size quantum: overlaps nehir's terminal/cell-quantization work.
- Upstream `fce3a2c` FFM cursor-warp origin: conceptually clean but touches focus request modeling.
- Space topology: product/runtime mode decision.
- WorldStore/EventIntake/IntentLedger: major architecture, not patch work.
