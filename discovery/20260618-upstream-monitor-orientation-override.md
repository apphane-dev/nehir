# Upstream port P3 — Preserve monitor orientation overrides & report effective orientation over IPC — Discovery

Source upstream commit: [`8338d97`](https://github.com/BarutSRB/OmniWM/commit/8338d97) — "Preserve monitor orientation overrides and report them over IPC" (0.4.9.8 line, behind "Rotated & portrait display support").
Filed against: `BarutSRB/OmniWM` (upstream of nehir — see `NOTICE.md`).
Scope: determine whether the orientation clobber and the IPC misreport apply to nehir, and scope the port.

All file/line references below were verified against worktree `worktree-calm-harbor-e6a1` on 2026-06-18. Re-verify before implementing; line numbers drift.

---

## TL;DR

- **Two defects apply:**
  1. `NiriMonitor.updateOutputSize` silently resets orientation to auto when no explicit override is supplied (`:50`).
  2. The IPC `displays` query reports `monitor.autoOrientation`, not the user's effective override (`IPCQueryRouter.swift:415`).
- **Severity nuance:** the production monitor-sync path (`NiriLayoutHandler.syncMonitorsToNiriEngine`) already passes `effectiveOrientation(for:)` for every monitor, so the leaf clobber does not currently fire in the *live* sync path. P3 is therefore **defensive hardening** at the leaf plus a **real, observable IPC defect**.
- **Verdict:** 🟡 Open / Applies (leaf = defensive; IPC = observable). Small, self-contained. Nehir already has `SettingsStore.effectiveOrientation(for:)` at `:774`.

## Provenance: is this nehir's code?

Yes. Both sites and the effective-orientation API exist verbatim:

- `Sources/Nehir/Core/Layout/Niri/NiriMonitor.swift:47-50` — `updateOutputSize(monitor:orientation:)`.
- `Sources/Nehir/IPC/IPCQueryRouter.swift:414-415` — `displaySnapshot` orientation field.
- `Sources/Nehir/Core/Config/SettingsStore.swift:774-781` — `effectiveOrientation(for:)` returns the override or falls back to `monitor.autoOrientation`.

## The code in question

### Leaf: updateOutputSize clobbers on nil

```swift
// Sources/Nehir/Core/Layout/Niri/NiriMonitor.swift:47-50
func updateOutputSize(monitor: Monitor, orientation: Monitor.Orientation? = nil) {
    frame = monitor.frame
    visibleFrame = monitor.visibleFrame
    self.orientation = orientation ?? monitor.autoOrientation   // ← nil clobbers any stored override
```

`init(monitor:orientation:)` at `:33-39` uses the same fallback — but there it is **correct** (construction has no prior value to preserve) and must not change.

### IPC: reports auto, not effective

```swift
// Sources/Nehir/IPC/IPCQueryRouter.swift:414-415
orientation: include("orientation", in: fields) ? ipcDisplayOrientation(from: monitor.autoOrientation) : nil,
```

`displaySnapshot(from:currentMonitorId:fields:)` already has access to `controller.settings` (used at `:30`, `:389`, `:551`), so switching to `effectiveOrientation(for:)` is a one-arg change.

### Why the live path doesn't currently clobber

The sole caller, `NiriLayoutHandler.syncMonitorsToNiriEngine()` (~`NiriLayoutHandler.swift:1539-1556`), fills `orientations[monitor.id] = controller.settings.effectiveOrientation(for: monitor)` for every monitor before calling `updateMonitors(_:orientations:)`. So today the `nil` branch is only reachable from tests or a hypothetical future caller passing `orientations: [:]` (the parameter default). P3 hardens that leaf against regressions.

## Why it applies

- A user orientation override (portrait/rotated display) should survive monitor reconfiguration. If any future caller (or a test path that constructs a `NiriMonitor`, sets an override, then calls `updateOutputSize(..., orientation: nil)`) hits the leaf, the override is silently lost and layout flips back to auto.
- IPC is the concrete user-visible defect: `nehirctl`/raycast/scripts querying `displays` for orientation get the auto-detected value, inconsistent with runtime layout when an override is set. `Monitor.autoOrientation` (`Sources/Nehir/Core/Monitor/Monitor.swift:60-62`) is simply `frame.width >= frame.height ? .horizontal : .vertical`.

## Recommendation

**Direct port of the two edits.**

1. Leaf:
```swift
// Sources/Nehir/Core/Layout/Niri/NiriMonitor.swift — updateOutputSize
if let orientation {
    self.orientation = orientation
}
```
   Do not touch `init`.

2. IPC:
```swift
// Sources/Nehir/IPC/IPCQueryRouter.swift — displaySnapshot
orientation: include("orientation", in: fields)
    ? ipcDisplayOrientation(from: controller.settings.effectiveOrientation(for: monitor)) : nil,
```

### Tests

New file `Tests/NehirTests/NiriMonitorTests.swift`:

1. `updateOutputSizePreservesExistingOrientationWhenCalledWithNil` — portrait `Monitor` (900×1600 ⇒ `autoOrientation == .vertical`); construct `NiriMonitor(monitor:, orientation: .horizontal)`; assert `.horizontal`; call `updateOutputSize(monitor:, orientation: nil)`; assert still `.horizontal`, and `frame`/`visibleFrame` refreshed.
2. `updateOutputSizeAppliesExplicitOrientationOverride` — same portrait monitor constructed default; call with `.horizontal`; assert `.horizontal`.
3. `initFallsBackToAutoOrientationWhenNoOverride` — regression guard for the init path (portrait ⇒ `.vertical`, landscape ⇒ `.horizontal`).

   Mark the suite `@MainActor` only if Swift complains about `NSScreen` access inside `updateOutputSize` (the `scale` branch tolerates nil for synthetic display ids).

IPC: extend `Tests/NehirTests/IPCQueryRouterTests.swift`:

4. `displaysQueryReportsEffectiveOrientationOverride` — portrait fixture, install a `.horizontal` override via `updateOrientationSettings(MonitorOrientationSettings(monitorName:monitorDisplayId:orientation:))`, query `.displays`, assert `orientation == .horizontal`. (Fails on current code; passes after edit.)
5. (optional) `displaysQueryReportsAutoOrientationWhenNoOverride` — guards the `effectiveOrientation` fallback branch.

Existing lifecycle tests must stay green: `monitorConfigurationChangePreservesNiriOrientationOverride` (`ServiceLifecycleManagerTests.swift:161`) and `monitorConfigurationChangeKeepsAutoNiriOrientationCurrent` (`:209`).

## Suggested validation

```bash
swift build
swift test --filter NiriMonitorTests
swift test --filter IPCQueryRouterTests
swift test --filter ServiceLifecycleManagerTests
```

Add a patch changeset via `mise run changeset -- patch "Display orientation overrides survive monitor reconfiguration and are reported correctly over IPC."`

## Risks

- **Freezing auto orientation when there is no override.** Only affects monitors that previously stored a non-auto orientation. All production callers go through `effectiveOrientation(for:)` (which itself falls back to `auto`), so a legitimate auto update is never blocked. `monitorConfigurationChangeKeepsAutoNiriOrientationCurrent` pins this end-to-end.
- **Override matching by name vs displayId** in the IPC test — populate both `monitorName` and `monitorDisplayId` to match the pattern at `LayoutRefreshControllerTests.swift:528` / `ServiceLifecycleManagerTests.swift:178`, or `effectiveOrientation` may not resolve and the test could falsely pass on both sides.
- **Field-projection:** use the bare `IPCQueryRequest(name: .displays)` form (default = all fields) so `orientation` is populated.

## Open questions

1. Should `NiriLayoutEngine.updateMonitors` also harden itself (look up `effectiveOrientation` for omitted monitors) rather than rely on every caller pre-filling the dict? Out of scope for P3 (matches upstream); surface as a follow-up if reviewers want defense-in-depth.
2. Is there an IPC golden/snapshot test (e.g. under `raycast/`) pinning the literal displays JSON? Grep `raycast/` for `"orientation"` before merging; not blocking.
