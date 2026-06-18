# OmniWM issue #95 — "Spaces bar vs macOS island/notch" — Discovery

Source issue: https://github.com/BarutSRB/OmniWM/issues/95 (closed, **not planned**).
Scope of this doc: determine whether the issue applies to nehir,
and whether the suggested fix is safe to port.

All file/line references were verified against the nehir worktree at `904df02`
("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify before
implementing; line numbers drift.

> **Filed under discovery/noop/** — nehir already handles the actionable part of
> this upstream report at the workspace-bar geometry layer: notched displays are
> detected via `NSScreen.safeAreaInsets.top`, notch-aware positioning is enabled
> by default, and an overlapping-menu-bar configuration is converted to
> `belowMenuBar` before the panel frame is applied. There is no upstream patch to
> port, and this item owns no new repo action.

---

## TL;DR

- **The workspace bar's default geometry is already notch-aware in nehir:** on a monitor with `hasNotch == true`, the default overlapping position is resolved to `belowMenuBar` before frame placement.
- **Verdict:** 🟢 Fixed — the actionable notch-overlap bug is prevented by existing default settings and geometry resolution; only an explicit user override (`notchAware = false` or manual offsets) could reintroduce overlap.

## Upstream claim

The upstream issue reports that the macOS "island"/notch covers the spaces bar at
the top on macOS Tahoe 26.4. It includes screenshots but no code reference, no
concrete repro beyond the top-bar overlap, and no patch; the only suggested
solution is exploratory ("some other apps doing some cool things with the
island"). The issue is closed as not planned.

## Provenance: is this nehir's code?

Yes. nehir has a workspace bar implemented as an always-present floating panel
(`WorkspaceBarManager.defaultPanel`) and a geometry resolver that decides whether
the bar overlaps the menu bar or moves below it. Relevant files:

- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift` — creates the panel and applies `WorkspaceBarGeometry` frames.
- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift` — resolves notch-aware effective position and final frame.
- `Sources/Nehir/Core/Monitor/Monitor.swift` — detects notched screens via AppKit safe-area insets.
- `Sources/Nehir/Core/Config/SettingsExport.swift` and `Sources/Nehir/Core/Config/SettingsStore.swift` — default and resolved workspace-bar settings.
- `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift` — exposes the notch-aware toggle to users.

## The code in question

The workspace bar panel is a borderless floating panel that joins every macOS
Space, so it is the same class of top overlay as the upstream "spaces bar":

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:461-470
private static func defaultPanel() -> WorkspaceBarPanel {
    let panel = WorkspaceBarPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )

    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
```

Frame placement always goes through `WorkspaceBarGeometry` immediately before the
panel frame is applied:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:388-401
private func updateBarFrameAndPosition(
    for monitor: Monitor,
    resolved: ResolvedBarSettings,
    snapshot: WorkspaceBarSnapshot,
    instance: MonitorBarInstance
) {
    let fittingWidth = measuredWidth(for: snapshot, using: instance.measurementView)
    let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
    let frame = geometry.frame(fittingWidth: fittingWidth, monitor: monitor, resolved: resolved)

    guard instance.lastAppliedFrame != frame else { return }

    let previousFrame = instance.panel.frame
    frameApplier(instance.panel, frame)
```

`Monitor.current()` marks displays with a top safe-area inset as notched:

```swift
// Sources/Nehir/Core/Monitor/Monitor.swift:19-32
static func current() -> [Monitor] {
    NSScreen.screens.compactMap { screen -> Monitor? in
        guard let displayId = screen.displayId else { return nil }
        var hasNotch = false
        if #available(macOS 12.0, *) {
            hasNotch = screen.safeAreaInsets.top > 0
        }
        return Monitor(
            id: ID(displayId: displayId),
            displayId: displayId,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            hasNotch: hasNotch,
```

The default workspace-bar configuration is enabled, starts as
`overlappingMenuBar`, and has notch-aware positioning turned on:

```swift
// Sources/Nehir/Core/Config/SettingsExport.swift:124-130
workspaceBarEnabled: true,
workspaceBarShowLabels: true,
workspaceBarShowFloatingWindows: false,
workspaceBarShowTraceButton: false,
workspaceBarWindowLevel: WorkspaceBarWindowLevel.popup.rawValue,
workspaceBarPosition: WorkspaceBarPosition.overlappingMenuBar.rawValue,
workspaceBarNotchAware: true,
```

Resolved settings preserve that default unless a per-monitor override or global
setting changes it:

```swift
// Sources/Nehir/Core/Config/SettingsStore.swift:710-720
private func resolvedBarSettings(override: MonitorBarSettings?) -> ResolvedBarSettings {
    return ResolvedBarSettings(
        enabled: override?.enabled ?? workspaceBarEnabled,
        showLabels: override?.showLabels ?? workspaceBarShowLabels,
        showFloatingWindows: override?.showFloatingWindows ?? workspaceBarShowFloatingWindows,
        showTraceButton: override?.showTraceButton ?? workspaceBarShowTraceButton,
        deduplicateAppIcons: override?.deduplicateAppIcons ?? workspaceBarDeduplicateAppIcons,
        hideEmptyWorkspaces: override?.hideEmptyWorkspaces ?? workspaceBarHideEmptyWorkspaces,
        reserveLayoutSpace: override?.reserveLayoutSpace ?? workspaceBarReserveLayoutSpace,
        notchAware: override?.notchAware ?? workspaceBarNotchAware,
        position: override?.position ?? workspaceBarPosition,
```

The effective-position guard is the key fix: on a notched monitor, with
notch-aware positioning enabled, an overlapping-menu-bar configuration is changed
to `belowMenuBar`:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:43-53
static func effectivePosition(
    for monitor: Monitor,
    resolved: ResolvedBarSettings
) -> WorkspaceBarPosition {
    if monitor.hasNotch,
       resolved.notchAware,
       resolved.position == .overlappingMenuBar
    {
        return .belowMenuBar
    }
    return resolved.position
}
```

That effective position controls the y-coordinate: below-menu-bar mode places the
bar at `monitor.visibleFrame.maxY - barHeight`, while overlap mode starts at
`monitor.visibleFrame.maxY`:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:28-40
func frame(
    fittingWidth: CGFloat,
    monitor: Monitor,
    resolved: ResolvedBarSettings
) -> CGRect {
    let width = max(fittingWidth, 300)
    var x = monitor.frame.midX - width / 2
    var y = effectivePosition == .belowMenuBar ? monitor.visibleFrame.maxY - barHeight : monitor.visibleFrame.maxY

    x += CGFloat(resolved.xOffset)
    y += CGFloat(resolved.yOffset)

    return CGRect(x: x, y: y, width: width, height: barHeight)
}
```

The behavior is also exposed in Settings with an explicit caption describing the
same purpose:

```swift
// Sources/Nehir/UI/WorkspaceBarSettingsTab.swift:114-118
Toggle("Notch-Aware Positioning", isOn: $settings.workspaceBarNotchAware)
    .onChange(of: settings.workspaceBarNotchAware) { _, _ in
        controller.updateWorkspaceBarSettings()
    }
SettingsCaption("Offsets the bar to avoid the display notch on MacBook Pro.")
```

## Why this doesn't apply as an open bug

The upstream item's actionable premise is that a centered top system cutout can
cover the spaces/workspace bar. nehir's default path already avoids that:

1. `Monitor.current()` records `hasNotch` from `NSScreen.safeAreaInsets.top` on macOS 12+ (`Sources/Nehir/Core/Monitor/Monitor.swift:19-32`).
2. The workspace bar defaults to `workspaceBarNotchAware: true` while still allowing the normal `overlappingMenuBar` style on non-notched monitors (`Sources/Nehir/Core/Config/SettingsExport.swift:124-130`).
3. Resolved per-monitor settings feed that flag into `WorkspaceBarGeometry` (`Sources/Nehir/Core/Config/SettingsStore.swift:710-720`).
4. `WorkspaceBarGeometry.effectivePosition` converts the default overlap mode to `belowMenuBar` when both `monitor.hasNotch` and `resolved.notchAware` are true (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:43-53`).
5. `WorkspaceBarManager.updateBarFrameAndPosition` applies the resolved geometry every time it positions the panel (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:388-401`).

So the default nehir configuration should not reproduce #95 on hardware where
AppKit reports the notch through safe-area insets. If a future macOS "island" is
not represented as a display safe-area inset, the upstream issue does not provide
enough detail or a concrete API-level fix to port; that would be a separate
feature investigation, not this closed upstream bug.

## Recommendation

Do not port anything for #95. Keep the existing notch-aware default and geometry
invariant. If future reports show a Tahoe-specific island that does not affect
`NSScreen.safeAreaInsets.top`, file a new nehir issue with hardware/OS details
and the observed safe-area values; #95 itself owns no code action.
