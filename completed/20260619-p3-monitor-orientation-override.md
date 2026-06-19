# P3 — Preserve monitor orientation overrides & report effective orientation over IPC

**Status:** completed — shipped on `main` in `7e9f44a9` ("Preserve orientation overrides and report effective orientation over IPC (P3)").
**Source upstream commit:** [`8338d97`](https://github.com/BarutSRB/OmniWM/commit/8338d97) — "Preserve monitor orientation overrides and report them over IPC"
**Discovery doc (authoritative):** [`completed/20260618-upstream-monitor-orientation-override.md`](20260618-upstream-monitor-orientation-override.md)
**Branch:** `patch/p3-monitor-orientation-override`

---

## Completion evidence

`origin/main` contains `7e9f44a9` with the plan's intended source and test changes. Verified while updating this plan branch on 2026-06-19 via `git log origin/main` and `git show --stat 7e9f44a9`.


## Goal

Fix two orientation defects with two one-line edits, so a user-set monitor
orientation override (portrait/rotated display) survives `NiriMonitor`
reconfiguration and is reported accurately over the IPC `displays` query.

- **Leaf (`updateOutputSize`):** defensive hardening. Today the live sync path
  (`NiriLayoutHandler.syncMonitorsToNiriEngine`) already passes
  `effectiveOrientation(for:)` for every monitor, so the nil-clobber does not
  fire in production. This edit guards the leaf against a regression or a future
  caller passing `orientations: [:]` (the parameter default).
- **IPC (`displaySnapshot`):** real, observable defect. `nehirctl`/raycast/scripts
  querying `displays` for `orientation` get the auto-detected value
  (`frame.width >= frame.height ? .horizontal : .vertical`) instead of the
  user's effective override, inconsistent with runtime layout when an override
  is set.

## Scope & non-goals

**In scope:** two leaf edits + focused tests (new `NiriMonitorTests.swift`, extend
`IPCQueryRouterTests.swift`).

**Non-goals (do NOT touch):**
- `init(monitor:orientation:)` at `NiriMonitor.swift:37-51` — the same
  `orientation ?? monitor.autoOrientation` fallback is **correct** there
  (construction has no prior value to preserve). Must not change.
- The live `NiriLayoutHandler.syncMonitorsToNiriEngine` monitor-sync path — it
  already fills `orientations[monitor.id] = controller.settings.effectiveOrientation(for:)`
  for every monitor, so it is unaffected by the leaf edit.
- `NiriLayoutEngine.updateMonitors` defense-in-depth (look up
  `effectiveOrientation` for omitted monitors). Matches upstream scope; defer.
- `WorkspaceManager.removeMissing(...)` default, `confirmedMissingKeys`, the
  `Monitor.autoOrientation` definition itself.

## Exact edits

### Edit (a) — `Sources/Nehir/Core/Layout/Niri/NiriMonitor.swift:50` (updateOutputSize)

Verified current state (`:47-50`):

```swift
func updateOutputSize(monitor: Monitor, orientation: Monitor.Orientation? = nil) {
    frame = monitor.frame
    visibleFrame = monitor.visibleFrame
    self.orientation = orientation ?? monitor.autoOrientation   // ← nil clobbers any stored override
```

Change **only** this line to preserve a stored override when no explicit
argument is supplied:

```swift
func updateOutputSize(monitor: Monitor, orientation: Monitor.Orientation? = nil) {
    frame = monitor.frame
    visibleFrame = monitor.visibleFrame
    if let orientation {
        self.orientation = orientation
    }
```

Leave the trailing `scale` block (`NSScreen.screens.first(...)`) as-is.

### Edit (b) — `Sources/Nehir/IPC/IPCQueryRouter.swift:415` (displaySnapshot)

Verified current state (`:415`):

```swift
orientation: include("orientation", in: fields) ? ipcDisplayOrientation(from: monitor.autoOrientation) :
    nil,
```

`displaySnapshot(...)` already has access to `controller.settings` (used elsewhere
in the same function), and `SettingsStore.effectiveOrientation(for:)` (verified
at `Sources/Nehir/Core/Config/SettingsStore.swift:886`; was `:774` in the
discovery doc — drifted) returns the override or falls back to
`monitor.autoOrientation`. Switch the source:

```swift
orientation: include("orientation", in: fields)
    ? ipcDisplayOrientation(from: controller.settings.effectiveOrientation(for: monitor))
    : nil,
```

## Tests

### New file: `Tests/NehirTests/NiriMonitorTests.swift`

`@testable import Nehir`, suite `@MainActor` only if Swift complains about
`NSScreen` access inside `updateOutputSize` (the `scale` branch tolerates nil
for synthetic display ids).

1. **`updateOutputSizePreservesExistingOrientationWhenCalledWithNil`** — build a
   portrait `Monitor` (900×1600 ⇒ `autoOrientation == .vertical`); construct
   `NiriMonitor(monitor:, orientation: .horizontal)`; assert `.horizontal`; call
   `updateOutputSize(monitor:, orientation: nil)`; assert still `.horizontal`,
   and `frame`/`visibleFrame` refreshed. (Fails on current code; passes after edit (a).)
2. **`updateOutputSizeAppliesExplicitOrientationOverride`** — same portrait
   monitor constructed default (`orientation: nil` ⇒ `.vertical`); call
   `updateOutputSize(monitor:, orientation: .horizontal)`; assert `.horizontal`.
3. **`initFallsBackToAutoOrientationWhenNoOverride`** — regression guard for the
   untouched `init` path (portrait ⇒ `.vertical`, landscape ⇒ `.horizontal`).

### Extend: `Tests/NehirTests/IPCQueryRouterTests.swift`

4. **`displaysQueryReportsEffectiveOrientationOverride`** — portrait fixture,
   install a `.horizontal` override via
   `updateOrientationSettings(MonitorOrientationSettings(monitorName:monitorDisplayId:orientation:))`,
   query `.displays` using the bare `IPCQueryRequest(name: .displays)` form
   (default = all fields, so `orientation` is populated), assert
   `orientation == .horizontal`. (Fails on current code; passes after edit (b).)
5. _(optional)_ **`displaysQueryReportsAutoOrientationWhenNoOverride`** — guards
   the `effectiveOrientation` fallback branch (auto value flows through).

### Must-stay-green (regression guards)

- `monitorConfigurationChangePreservesNiriOrientationOverride`
  (`Tests/NehirTests/ServiceLifecycleManagerTests.swift:161`)
- `monitorConfigurationChangeKeepsAutoNiriOrientationCurrent`
  (`Tests/NehirTests/ServiceLifecycleManagerTests.swift:209`)

### Fixture gotcha

Override matching is by **name vs displayId**. In the IPC test, populate **both**
`monitorName` and `monitorDisplayId` to match the pattern at
`LayoutRefreshControllerTests.swift:528` / `ServiceLifecycleManagerTests.swift:178`,
or `effectiveOrientation` may not resolve and the test could falsely pass on both
sides of the edit.

## Changeset

```bash
mise run changeset -- patch "Display orientation overrides survive monitor reconfiguration and are reported correctly over IPC."
```

## Validation

```bash
swift build
swift test --filter NiriMonitorTests
swift test --filter IPCQueryRouterTests
swift test --filter ServiceLifecycleManagerTests
```

Before merging, also grep `raycast/` for `"orientation"` in case any golden IPC
JSON snapshot pins the literal `displays` payload (not blocking).

## Risks

- **Freezing auto orientation when there is no override.** Only affects monitors
  that previously stored a non-auto orientation. All production callers go
  through `effectiveOrientation(for:)` (which falls back to `auto`), so a
  legitimate auto update is never blocked. `monitorConfigurationChangeKeepsAutoNiriOrientationCurrent`
  pins this end-to-end.
- **Override matching by name vs displayId** in the IPC test — see fixture gotcha
  above; a wrong fixture can make the test falsely pass on both sides.
- **Field projection** — use the default-fields `IPCQueryRequest(name: .displays)`
  form so `orientation` is populated; a field-projection request omitting
  `orientation` will return `nil` by design.

## Pointer

Discovery / evidence: [`completed/20260618-upstream-monitor-orientation-override.md`](20260618-upstream-monitor-orientation-override.md).
