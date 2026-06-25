// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import os
import SwiftUI

enum WorkspaceBarWindowLevel: String, CaseIterable, Identifiable {
    case normal
    case floating
    case status
    case popup
    case screensaver

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .floating: "Floating"
        case .status: "Status Bar"
        case .popup: "Popup"
        case .screensaver: "Screen Saver"
        }
    }

    var nsWindowLevel: NSWindow.Level {
        switch self {
        case .normal: .normal
        case .floating: .floating
        case .status: .statusBar
        case .popup: .popUpMenu
        case .screensaver: .screenSaver
        }
    }
}

enum WorkspaceBarPosition: String, CaseIterable, Identifiable {
    case overlappingMenuBar
    case belowMenuBar

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .overlappingMenuBar: "Overlapping Menu Bar"
        case .belowMenuBar: "Below Menu Bar"
        }
    }
}

@MainActor
final class WorkspaceBarManager {
    private static let debugLogger = Logger(subsystem: "com.nehir", category: "workspace-bar")
    final class MonitorBarInstance {
        let monitorId: Monitor.ID
        let panel: WorkspaceBarPanel
        let hostingView: NSHostingView<WorkspaceBarView>
        let measurementView: NSHostingView<WorkspaceBarMeasurementView>
        let model: WorkspaceBarModel

        var monitor: Monitor
        var lastAppliedFrame: NSRect?
        var screenDisplayId: CGDirectDisplayID?

        init(
            monitor: Monitor,
            panel: WorkspaceBarPanel,
            hostingView: NSHostingView<WorkspaceBarView>,
            measurementView: NSHostingView<WorkspaceBarMeasurementView>,
            model: WorkspaceBarModel,
            screenDisplayId: CGDirectDisplayID?
        ) {
            monitorId = monitor.id
            self.monitor = monitor
            self.panel = panel
            self.hostingView = hostingView
            self.measurementView = measurementView
            self.model = model
            self.screenDisplayId = screenDisplayId
        }
    }

    var monitorProvider: @MainActor () -> [Monitor] = { Monitor.current() }
    var screenProvider: @MainActor (CGDirectDisplayID) -> NSScreen? = { displayId in
        NSScreen.screens.first(where: { $0.displayId == displayId })
    }

    var panelFactory: @MainActor @Sendable () -> WorkspaceBarPanel = {
        WorkspaceBarManager.defaultPanel()
    }

    var frameApplier: @MainActor @Sendable (WorkspaceBarPanel, NSRect) -> Void = { panel, frame in
        panel.setFrame(frame, display: true)
    }

    var appearanceProvider: @MainActor () -> NSAppearance? = { NSApplication.shared.appearance }

    /// Defaults to the global modifier-flag poll (proven at
    /// `MultitouchGestureSource.swift:86`). Injectable so the click-wiring dispatch
    /// is hermetically testable without synthesizing an `NSEvent`.
    var clickIntentFlagProvider: @MainActor () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    private var barsByMonitor: [Monitor.ID: MonitorBarInstance] = [:]
    private var screenObserver: Any?
    private var sleepWakeObserver: Any?
    private var pendingReconfigureTask: Task<Void, Never>?
    private var recentFrameTraceRecords: [String] = []
    private weak var controller: WMController?
    private weak var settings: SettingsStore?
    private let surfaceCoordinator = SurfaceCoordinator.shared

    init() {
        setupScreenChangeObserver()
        setupSleepWakeObserver()
    }

    func setup(controller: WMController, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings

        cancelPendingReconfigure()
        reconfigureBars()
    }

    func update() {
        guard settings != nil else {
            cancelPendingReconfigure()
            removeAllBars()
            return
        }

        refreshBarsContent()
    }

    func updateAppearance() {
        guard settings != nil else { return }

        for instance in barsByMonitor.values {
            refreshBarAppearance(instance: instance)
        }
    }

    func setEnabled(_ enabled: Bool) {
        cancelPendingReconfigure()

        if enabled {
            reconfigureBars()
        } else {
            removeAllBars()
        }
    }

    func updateSettings() {
        guard settings != nil else { return }
        cancelPendingReconfigure()
        reconfigureBars()
    }

    func reconfigureBars() {
        reconfigureBars(using: monitorProvider())
    }

    func reconfigureBars(using monitors: [Monitor]) {
        guard let controller, let settings else { return }

        var existingMonitorIds = Set(barsByMonitor.keys)

        for monitor in monitors {
            existingMonitorIds.remove(monitor.id)
            let resolved = settings.resolvedBarSettings(for: monitor)

            // Global workspace-bar settings are defaults; monitor overrides and runtime visibility decide bar ownership.
            if !controller.isWorkspaceBarVisible(on: monitor, resolved: resolved) {
                removeBarForMonitor(monitor.id)
                continue
            }

            if let existing = barsByMonitor[monitor.id] {
                if !updateBarForMonitor(monitor, instance: existing) {
                    removeBarForMonitor(monitor.id)
                    createBarForMonitor(monitor)
                }
            } else {
                createBarForMonitor(monitor)
            }
        }

        for monitorId in existingMonitorIds {
            removeBarForMonitor(monitorId)
        }
    }

    func scheduleReconfigure(after delayNanoseconds: UInt64) {
        scheduleDeferredUpdate(after: delayNanoseconds) { [weak self] in
            self?.reconfigureBars()
        }
    }

    private func refreshBarsContent() {
        guard settings != nil else { return }

        let currentMonitors = Dictionary(uniqueKeysWithValues: monitorProvider().map { ($0.id, $0) })
        for instance in barsByMonitor.values {
            let monitor = currentMonitors[instance.monitorId] ?? instance.monitor
            refreshBarContent(for: monitor, instance: instance)
        }
    }

    private func createBarForMonitor(_ monitor: Monitor) {
        guard let controller, let settings else { return }

        let resolved = settings.resolvedBarSettings(for: monitor)
        let snapshot = makeSnapshot(for: monitor, resolved: resolved)
        let model = WorkspaceBarModel(snapshot: snapshot)

        let hostingView = NSHostingView(
            rootView: WorkspaceBarView(
                model: model,
                onFocusWorkspace: { [weak self] item in
                    self?.handleWorkspacePillClick(item)
                },
                onMoveFocusedWindowToWorkspace: { [weak controller] item in
                    controller?.moveFocusedWindowFromBar(toWorkspaceId: item.id)
                },
                onFocusWindow: { [weak controller] token in
                    controller?.focusWindowFromBar(token: token)
                },
                onActivateScratchpad: { [weak controller] in
                    controller?.activateScratchpadFromBar(on: monitor.id)
                },
                onOpenCommandPalette: { [weak controller] in
                    controller?.openCommandPalette()
                },
                onOpenDiagnostics: { [weak controller, weak settings] in
                    guard let controller, let settings else { return }
                    SettingsWindowController.shared.show(
                        settings: settings,
                        controller: controller,
                        section: .diagnostics
                    )
                },
                onToggleWindowFloating: { [weak controller] token in
                    _ = controller?.toggleWindowFloating(token: token)
                },
                onToggleScratchpadAssignment: { [weak controller] token in
                    _ = controller?.toggleWindowScratchpadAssignment(token: token)
                },
                onCloseWindow: { [weak controller] token in
                    _ = controller?.closeWindowFromBar(token: token)
                },
                onMoveWindowToWorkspace: { [weak controller] token, workspaceId in
                    _ = controller?.moveWindowFromBar(token: token, toWorkspaceId: workspaceId)
                },
                onToggleScratchpadVisible: { [weak controller] in
                    _ = controller?.toggleScratchpadWindow()
                }
            )
        )
        configureHostingView(hostingView)

        let measurementView = NSHostingView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot))

        let panel = panelFactory()
        let screen = screenProvider(monitor.displayId)
        panel.targetScreen = screen
        panel.targetFrame = monitor.frame
        panel.contentView = hostingView
        applyCurrentAppearance(
            to: panel,
            hostingView: hostingView,
            measurementView: measurementView
        )
        applySettingsToPanel(panel, resolved: resolved)

        let instance = MonitorBarInstance(
            monitor: monitor,
            panel: panel,
            hostingView: hostingView,
            measurementView: measurementView,
            model: model,
            screenDisplayId: screen?.displayId
        )
        barsByMonitor[monitor.id] = instance

        updateBarFrameAndPosition(
            for: monitor,
            resolved: resolved,
            snapshot: snapshot,
            instance: instance
        )
        surfaceCoordinator.register(
            window: panel,
            id: surfaceId(for: monitor.id),
            policy: SurfacePolicy(
                kind: .workspaceBar,
                hitTestPolicy: .interactive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: false
            )
        )
        panel.orderFrontRegardless()
    }

    private func updateBarForMonitor(_ monitor: Monitor, instance: MonitorBarInstance) -> Bool {
        guard let settings else { return false }

        let screen = screenProvider(monitor.displayId)
        let nextScreenDisplayId = screen?.displayId

        if let currentScreenDisplayId = instance.screenDisplayId,
           nextScreenDisplayId != currentScreenDisplayId
        {
            return false
        }

        if nextScreenDisplayId == nil, instance.screenDisplayId != nil {
            return false
        }

        instance.monitor = monitor
        instance.panel.targetScreen = screen
        instance.panel.targetFrame = monitor.frame
        instance.screenDisplayId = nextScreenDisplayId

        let resolved = settings.resolvedBarSettings(for: monitor)
        let snapshot = makeSnapshot(for: monitor, resolved: resolved)
        instance.model.snapshot = snapshot
        applyCurrentAppearance(
            to: instance.panel,
            hostingView: instance.hostingView,
            measurementView: instance.measurementView
        )
        applySettingsToPanel(instance.panel, resolved: resolved)
        updateBarFrameAndPosition(
            for: monitor,
            resolved: resolved,
            snapshot: snapshot,
            instance: instance
        )
        return true
    }

    private func refreshBarContent(for monitor: Monitor, instance: MonitorBarInstance) {
        guard let settings else { return }

        instance.monitor = monitor
        instance.panel.targetFrame = monitor.frame

        let resolved = settings.resolvedBarSettings(for: monitor)
        let snapshot = makeSnapshot(for: monitor, resolved: resolved)
        if snapshot != instance.model.snapshot {
            instance.model.snapshot = snapshot
        }
        updateBarFrameAndPosition(
            for: monitor,
            resolved: resolved,
            snapshot: snapshot,
            instance: instance
        )
    }

    private func refreshBarAppearance(instance: MonitorBarInstance) {
        guard let settings else { return }

        let resolved = settings.resolvedBarSettings(for: instance.monitor)
        let current = instance.model.snapshot
        let snapshot = WorkspaceBarSnapshot(
            projection: current.projection,
            showLabels: current.showLabels,
            backgroundOpacity: current.backgroundOpacity,
            barHeight: current.barHeight,
            hasDisplayDiagnosticsWarning: current.hasDisplayDiagnosticsWarning,
            accentColor: resolved.accentColor,
            textColor: resolved.textColor
        )

        if snapshot != current {
            instance.model.snapshot = snapshot
        }
    }

    private func removeBarForMonitor(_ monitorId: Monitor.ID) {
        if let instance = barsByMonitor[monitorId] {
            surfaceCoordinator.unregister(id: surfaceId(for: monitorId))
            instance.panel.orderOut(nil)
            instance.panel.close()
            barsByMonitor.removeValue(forKey: monitorId)
        }
    }

    func removeAllBars() {
        for (_, instance) in barsByMonitor {
            surfaceCoordinator.unregister(id: surfaceId(for: instance.monitorId))
            instance.panel.orderOut(nil)
            instance.panel.close()
        }
        barsByMonitor.removeAll()
    }

    private func surfaceId(for monitorId: Monitor.ID) -> String {
        "workspace-bar-\(String(describing: monitorId))"
    }

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
        let appliedFrame = instance.panel.frame
        let traceRecord = "\(Date().ISO8601Format()) display=\(monitor.displayId) requested=\(frame.debugDescription) previous=\(previousFrame.debugDescription) actual=\(appliedFrame.debugDescription) effectivePosition=\(geometry.effectivePosition.rawValue) hasNotch=\(monitor.hasNotch) targetFrame=\(instance.panel.targetFrame?.debugDescription ?? "nil") targetScreen=\(instance.panel.targetScreen?.displayId.map(String.init) ?? "nil") panelScreen=\(instance.panel.screen?.displayId.map(String.init) ?? "nil")"
        Self.debugLogger.debug("WorkspaceBar.frame \(traceRecord)")
        recentFrameTraceRecords.append(traceRecord)
        if recentFrameTraceRecords.count > 80 {
            recentFrameTraceRecords.removeFirst(recentFrameTraceRecords.count - 80)
        }
        instance.lastAppliedFrame = frame
    }

    private func measuredWidth(
        for snapshot: WorkspaceBarSnapshot,
        using measurementView: NSHostingView<WorkspaceBarMeasurementView>
    ) -> CGFloat {
        measurementView.rootView = WorkspaceBarMeasurementView(snapshot: snapshot)
        measurementView.layoutSubtreeIfNeeded()
        return measurementView.fittingSize.width
    }

    private func makeSnapshot(
        for monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarSnapshot {
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        let projection = controller?.workspaceBarProjection(
            for: monitor,
            projection: resolved.projectionOptions
        ) ?? WorkspaceBarProjection(items: [], scratchpad: nil)

        return WorkspaceBarSnapshot(
            projection: projection,
            showLabels: resolved.showLabels,
            backgroundOpacity: resolved.backgroundOpacity,
            barHeight: geometry.barHeight,
            hasDisplayDiagnosticsWarning: DisplayEnvironmentDiagnostics.evaluate(monitors: monitorProvider())
                .hasWarnings,
            accentColor: resolved.accentColor,
            textColor: resolved.textColor
        )
    }

    private func configureHostingView<Content: View>(_ hostingView: NSHostingView<Content>) {
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
    }

    private func applyCurrentAppearance(
        to panel: NSPanel,
        hostingView: NSHostingView<WorkspaceBarView>,
        measurementView: NSHostingView<WorkspaceBarMeasurementView>
    ) {
        let appearance = appearanceProvider()
        panel.appearance = appearance
        hostingView.appearance = appearance
        measurementView.appearance = appearance
    }

    private static func defaultPanel() -> WorkspaceBarPanel {
        let panel = WorkspaceBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        return panel
    }

    nonisolated static func effectivePosition(
        for monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarPosition {
        WorkspaceBarGeometry.effectivePosition(for: monitor, resolved: resolved)
    }

    nonisolated static func barFrame(
        fittingWidth: CGFloat,
        monitor: Monitor,
        resolved: ResolvedBarSettings,
        menuBarHeight: Double
    ) -> NSRect {
        let geometry = WorkspaceBarGeometry.resolve(
            monitor: monitor,
            resolved: resolved,
            isVisible: true,
            menuBarHeight: CGFloat(menuBarHeight)
        )
        return geometry.frame(fittingWidth: fittingWidth, monitor: monitor, resolved: resolved)
    }

    nonisolated static func reservedTopInset(
        for monitor: Monitor,
        resolved: ResolvedBarSettings,
        isVisible: Bool,
        menuBarHeight: Double? = nil
    ) -> CGFloat {
        WorkspaceBarGeometry.resolve(
            monitor: monitor,
            resolved: resolved,
            isVisible: isVisible,
            menuBarHeight: menuBarHeight.map { CGFloat($0) }
        ).reservedTopInset
    }

    private func setupScreenChangeObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleReconfigure(after: 150_000_000)
            }
        }
    }

    private func setupSleepWakeObserver() {
        sleepWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDeferredUpdate(after: 500_000_000) { [weak self] in
                    self?.handleWakeFromSleep()
                }
            }
        }
    }

    private func scheduleDeferredUpdate(
        after delayNanoseconds: UInt64,
        action: @escaping @MainActor () -> Void
    ) {
        cancelPendingReconfigure()
        pendingReconfigureTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }

            guard let self else { return }
            self.pendingReconfigureTask = nil
            action()
        }
    }

    private func cancelPendingReconfigure() {
        pendingReconfigureTask?.cancel()
        pendingReconfigureTask = nil
    }

    private func handleWakeFromSleep() {
        guard settings != nil else { return }
        removeAllBars()
        reconfigureBars()
    }

    func cleanup() {
        cancelPendingReconfigure()

        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        if let observer = sleepWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepWakeObserver = nil
        }
        removeAllBars()
    }

    /// Routes a workspace-pill click to focus or move-focused-window based on the
    /// held modifiers reported by `clickIntentFlagProvider`. The plain-click path
    /// is unchanged (`focusWorkspaceFromBar`); Shift routes to
    /// `moveFocusedWindowFromBar` (the mouse analogue of `Opt+Shift+N`).
    func handleWorkspacePillClick(_ item: WorkspaceBarItem) {
        guard let controller else { return }
        let flags = clickIntentFlagProvider()
        switch WorkspaceBarClickIntent.resolve(modifiers: flags) {
        case .focus:
            controller.focusWorkspaceFromBar(id: item.id)
        case .moveWindow:
            controller.moveFocusedWindowFromBar(toWorkspaceId: item.id)
        }
    }

    private func applySettingsToPanel(_ panel: NSPanel, resolved: ResolvedBarSettings) {
        panel.level = resolved.windowLevel.nsWindowLevel
    }

    func runtimeFrameTraceDebugDump() -> String {
        recentFrameTraceRecords.isEmpty ? "workspace-bar frame trace empty" : recentFrameTraceRecords
            .joined(separator: "\n")
    }

    func runtimeStateDebugDump(
        monitors: [Monitor],
        resolvedProvider: (Monitor) -> ResolvedBarSettings,
        visibilityProvider: (Monitor, ResolvedBarSettings) -> Bool
    ) -> String {
        let activeInstances = barsByMonitor
        guard !monitors.isEmpty else { return "no-monitors" }

        var lines: [String] = []
        for monitor in monitors {
            let resolved = resolvedProvider(monitor)
            let visible = visibilityProvider(monitor, resolved)
            let instance = activeInstances[monitor.id]
            let geometry = WorkspaceBarGeometry.resolve(
                monitor: monitor,
                resolved: resolved,
                isVisible: visible
            )

            var parts: [String] = [
                "ID(displayId: \(monitor.displayId))",
                "hasNotch=\(monitor.hasNotch)",
                "visible=\(visible)",
                "enabled=\(resolved.enabled)",
                "notchAware=\(resolved.notchAware)",
                "configuredPosition=\(resolved.position.rawValue)",
                "effectivePosition=\(geometry.effectivePosition.rawValue)",
                "barHeight=\(geometry.barHeight)",
                "menuBarHeight=\(geometry.menuBarHeight)",
                "reservedTopInset=\(geometry.reservedTopInset)",
                "monitorFrame=\(monitor.frame.debugDescription)",
                "monitorVisibleFrame=\(monitor.visibleFrame.debugDescription)",
                "panelTargetFrame=\(instance?.panel.targetFrame?.debugDescription ?? "nil")"
            ]
            if let barFrame = instance?.lastAppliedFrame {
                parts.append("lastAppliedFrame=\(barFrame.debugDescription)")
            } else {
                parts.append("lastAppliedFrame=nil")
            }
            if let panelFrame = instance?.panel.frame {
                parts.append("actualPanelFrame=\(panelFrame.debugDescription)")
            } else {
                parts.append("actualPanelFrame=nil")
            }
            parts.append("targetScreen=\(instance?.panel.targetScreen?.displayId.map(String.init) ?? "nil")")
            parts.append("panelScreen=\(instance?.panel.screen?.displayId.map(String.init) ?? "nil")")
            parts.append("screenDisplayId=\(instance?.screenDisplayId.map(String.init) ?? "nil")")
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}

extension WorkspaceBarManager {
    func activeBarCountForTests() -> Int {
        barsByMonitor.count
    }

    func hostingViewIdentifierForTests(on monitorId: Monitor.ID) -> ObjectIdentifier? {
        barsByMonitor[monitorId].map { ObjectIdentifier($0.hostingView) }
    }

    func lastAppliedFrameForTests(on monitorId: Monitor.ID) -> CGRect? {
        barsByMonitor[monitorId]?.lastAppliedFrame
    }

    func snapshotForTests(on monitorId: Monitor.ID) -> WorkspaceBarSnapshot? {
        barsByMonitor[monitorId]?.model.snapshot
    }

    func panelEffectiveAppearanceForTests(on monitorId: Monitor.ID) -> NSAppearance.Name? {
        barsByMonitor[monitorId]?.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }

    func hostingViewEffectiveAppearanceForTests(on monitorId: Monitor.ID) -> NSAppearance.Name? {
        barsByMonitor[monitorId]?.hostingView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }
}

/// Which bar action a workspace-pill click should perform, given held modifiers.
///
/// v1 is Shift-only: Shift maps to `.moveWindow` (the mouse analogue of
/// `Opt+Shift+N`); everything else maps to `.focus`. A `.moveColumn` case is
/// intentionally absent — the column-move path does not inherit the
/// target-viewport reveal or the focus-follows policy, so it is a separate
/// follow-up.
enum WorkspaceBarClickIntent {
    case focus
    case moveWindow

    static func resolve(modifiers: NSEvent.ModifierFlags) -> WorkspaceBarClickIntent {
        modifiers.contains(.shift) ? .moveWindow : .focus
    }
}
