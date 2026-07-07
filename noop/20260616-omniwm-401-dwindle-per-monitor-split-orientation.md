# OmniWM PR #401 — "Dwindle split orientation respects per-monitor settings (→#270)" — Discovery

Source PR: https://github.com/BarutSRB/OmniWM/pull/401
Merge state: **closed without merge** (`state: closed`, `merged: false`, `merged_at: null`).
Related issue: OmniWM #270 (see sibling discovery
`noop/20260616-omniwm-270-dwindle-third-window-outside-grid-overlap.md`).
Scope of this doc: determine whether the PR's proposed Dwindle per-monitor split-orientation fix
applies to nehir, and whether it is safe to port.

All file/line references were verified against the Nehir source tree at `7f61cb3`
("docs: update four-finger gesture discovery with non-repro trace") on 20260616. Re-verify before
implementing; line numbers drift.

> **Filed under `discovery/noop/`** — PR #401 owns no new nehir action. It targets OmniWM's
> `DwindleLayoutEngine`, `DwindleLayoutHandler`, Dwindle settings, and Dwindle tests, but those
> symbols/directories are absent from nehir; the only carried layout engine is Niri. The sibling
> #270 discovery already records the linked Dwindle issue as not applicable; this PR-specific doc
> preserves the merge-state and diff evidence.

---

## TL;DR

- **Do not port PR #401: nehir has no Dwindle layout engine or Dwindle per-monitor settings for the
  patch to attach to.** A recursive source/test search for `Dwindle`, `splitWidthMultiplier`,
  `monitorDwindleOverrides`, `smartSplit`, `defaultSplitRatio`, `reorientSplits`, `aspectOrientation`,
  `planSplit`, and `splitLeaf` returns no matches.
- **Verdict:** ⚪ **Won't port / Not applicable.** The PR is also not open anymore: GitHub reports it
  closed without merge, contradicting the triage note's "open" state.

## Upstream PR summary

PR #401 claims OmniWM's Dwindle split orientation used the global `settings.splitWidthMultiplier`
instead of per-monitor `effectiveSettings(for: monitorId)`, so `monitorDwindleOverrides` did not
change split direction on portrait monitors. Its diff threads `monitorId` through
`addWindow -> splitLeaf -> planSplit -> aspectOrientation`, changes split ratio/defaults to read
`effectiveSettings(for:)`, adds `reorientSplits(for:monitorId:)` for hot-reload/sleep-wake settings
updates, updates Dwindle callers (`syncWindows`, `summonWindowRight`, `DwindleLayoutHandler`,
`WindowActionHandler`), and adds two Dwindle regression tests.

The GitHub API reports `state: closed`, `merged: false`, `merge_commit_sha: null`, `merged_at: null`.
That contradicts the catalog note that this PR is open; the evidence here uses the current upstream
state.

## Provenance: is this nehir's code?

The code family patched by PR #401 is not present in this fork:

- `find Sources -iname '*dwindle*'` prints nothing.
- `grep -RIn --exclude='*.md' -E 'Dwindle|dwindle|splitWidthMultiplier|monitorDwindleOverrides|smartSplit|defaultSplitRatio|DwindleSettings|reorientSplits|aspectOrientation|planSplit|splitLeaf' Sources Tests` prints nothing.
- `Sources/Nehir/Core/Layout/` contains shared layout types plus `Sources/Nehir/Core/Layout/Niri/`,
  not `Sources/Nehir/Core/Layout/Dwindle/`.

What nehir does have is a Niri layout engine. `WMController` stores a single optional
`niriEngine` (`Sources/Nehir/Core/Controller/WMController.swift:116`) and exposes it through the
Niri handler (`Sources/Nehir/Core/Controller/WMController.swift:155-157`). Startup enables Niri if
needed, then applies Niri settings (`Sources/Nehir/Core/Controller/WMController.swift:287-301`).
`NiriLayoutHandler.enableNiriLayout` constructs `NiriLayoutEngine()` and assigns it to the controller
(`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1494-1505`).

## The code in question

nehir's node model is column/list-based, not a Dwindle/BSP split tree:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:239-243
class NiriNode {
    let id: NodeId
    weak var parent: NiriNode?
    private(set) var children: [NiriNode] = [] {
        didSet { invalidateChildrenCache() }
    }
```

New windows are added by creating/inserting Niri columns, with no split-orientation decision:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:116-165
func addWindow(
    token: WindowToken,
    to workspaceId: WorkspaceDescriptor.ID,
    afterSelection selectedNodeId: NodeId?,
    focusedToken: WindowToken? = nil
) -> NiriWindow {
    let root = ensureRoot(for: workspaceId)
    // ...
    let newColumn = NiriContainer()
    initializeNewColumnWidth(newColumn, in: workspaceId)
    if let refCol = referenceColumn {
        root.insertAfter(newColumn, reference: refCol)
    } else {
        root.appendChild(newColumn)
    }

    let windowNode = NiriWindow(token: token)
    newColumn.appendChild(windowNode)
    tokenToNode[token] = windowNode
    return windowNode
}
```

The name `summonWindowRight` exists in nehir, but it is a Niri-column operation, not OmniWM's Dwindle
`engine.summonWindowRight(..., monitorId:)` path:

```swift
// Sources/Nehir/Core/Controller/WindowActionHandler.swift:447-468
private func summonWindowRightInNiri(
    token: WindowToken,
    sourceWorkspaceId: WorkspaceDescriptor.ID,
    targetWorkspaceId: WorkspaceDescriptor.ID,
    focusedToken: WindowToken
) -> Bool {
    guard let controller,
          let engine = controller.niriEngine,
          let focusedNode = engine.findNode(for: focusedToken),
          let focusedColumn = engine.findColumn(containing: focusedNode, in: targetWorkspaceId),
          let focusedColumnIndex = engine.columnIndex(of: focusedColumn, in: targetWorkspaceId)
    else {
        return false
    }

    let insertIndex = focusedColumnIndex + 1
```

The insertion it calls also creates a new Niri column, not a binary split:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift:149-187
func insertWindowInNewColumn(
    _ window: NiriWindow,
    insertIndex: Int,
    in workspaceId: WorkspaceDescriptor.ID,
    motion: MotionSnapshot,
    state: inout ViewportState,
    workingFrame: CGRect,
    gaps: CGFloat
) -> Bool {
    guard let root = roots[workspaceId] else { return false }
    guard let sourceColumn = findColumn(containing: window, in: workspaceId) else { return false }
    // ...
    let newColumn = NiriContainer()
    initializeNewColumnWidth(newColumn, in: workspaceId)
    // ...
    window.detach()
    newColumn.appendChild(window)
```

nehir does have per-monitor Niri settings, but their schema is not Dwindle split orientation. The
only monitor-specific Niri fields are balanced column count and lone-window policy:

```swift
// Sources/Nehir/Core/Config/MonitorNiriSettings.swift:4-17
struct MonitorNiriSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID?

    var balancedColumnCount: Int?
    var loneWindowPolicy: LoneWindowPolicy?
```

Resolution applies those Niri settings only:

```swift
// Sources/Nehir/Core/Config/SettingsStore.swift:820-844
private func resolvedNiriSettings(override: MonitorNiriSettings?) -> ResolvedNiriSettings {
    let resolvedDefaultColumnWidth: DefaultColumnWidth
    if let balancedColumnCount = override?.balancedColumnCount,
       niriDefaultColumnWidth == nil
    {
        resolvedDefaultColumnWidth = .balanced(columns: balancedColumnCount.clamped(to: 1 ... 5))
    } else {
        resolvedDefaultColumnWidth = defaultColumnWidth
    }
    // ...
    return ResolvedNiriSettings(
        defaultColumnWidth: resolvedDefaultColumnWidth,
        loneWindowPolicy: resolvedLoneWindowPolicy,
        infiniteLoop: niriInfiniteLoop
    )
}
```

Per-monitor Niri settings are refreshed by monitor, but again update Niri fields, not Dwindle split
orientation:

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1529-1535
func refreshResolvedMonitorSettings() {
    guard let controller, let engine = controller.niriEngine else { return }

    for monitor in controller.workspaceManager.monitors {
        let resolved = controller.settings.resolvedNiriSettings(for: monitor)
        engine.updateMonitorSettings(resolved, for: monitor.id)
    }
}
```

## Why it doesn't apply / why the PR is unsafe to port

1. **All target Dwindle symbols are absent.** PR #401's core methods (`splitLeaf`, `planSplit`,
   `aspectOrientation`, `reorientSplits`) and settings (`splitWidthMultiplier`, `smartSplit`,
   `defaultSplitRatio`, `monitorDwindleOverrides`) have no nehir source/test matches. Porting the
   diff as-is would not compile.
2. **The analogous user-facing setting does not exist.** nehir's per-monitor layout settings are
   Niri settings and gaps (`LayoutSettingsTab` shows Niri/gap monitor sections at
   `Sources/Nehir/UI/LayoutSettingsTab.swift:23-55`), while `MonitorNiriSettings` contains only
   `balancedColumnCount` and `loneWindowPolicy` (`Sources/Nehir/Core/Config/MonitorNiriSettings.swift:4-17`).
   There is no per-monitor split-orientation knob to ignore.
3. **The same operation name is a different implementation.** nehir's `summonWindowRight` path routes
   into `summonWindowRightInNiri` (`Sources/Nehir/Core/Controller/WindowActionHandler.swift:385-391`),
   then inserts a new Niri column (`Sources/Nehir/Core/Controller/WindowActionHandler.swift:462-468`,
   `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift:164-187`). It never calls a
   Dwindle engine with a monitor-specific split orientation.
4. **The PR is closed without merge upstream.** Even if nehir had Dwindle, the current upstream state
   would require extra caution. In this fork the stronger reason is feature absence.

## Recommendation

Do not port PR #401. Mark it **not applicable (feature absent)** for nehir and keep the linked #270
Dwindle issue under `discovery/noop/`. If nehir ever introduces a Dwindle/BSP layout, re-open the
question then and use PR #401's tests as requirements for that new engine.

## Suggested tests

N/A for current nehir: Dwindle and Dwindle split-orientation settings do not exist. If a future
Dwindle layout is added, add tests equivalent to PR #401's
`perMonitorSplitOrientationUsesHighSplitWidthMultiplierForVerticalSplits` and
`reorientSplitsChangesExistingTreeWhenSplitWidthMultiplierUpdated` alongside that engine.
