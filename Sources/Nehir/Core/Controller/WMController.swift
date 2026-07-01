// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation
import NehirIPC
import os

@MainActor
struct WindowFocusOperations {
    let activateApp: (pid_t) -> Void
    let focusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void
    let raiseWindow: (AXUIElement) -> Void
    let orderWindow: (UInt32) -> Void
    let visibleWindowInfoProvider: () -> [WindowServerInfo]

    init(
        activateApp: @escaping (pid_t) -> Void,
        focusSpecificWindow: @escaping (pid_t, UInt32, AXUIElement) -> Void,
        raiseWindow: @escaping (AXUIElement) -> Void,
        orderWindow: @escaping (UInt32) -> Void = { _ in },
        visibleWindowInfoProvider: @escaping () -> [WindowServerInfo] = {
            SkyLight.shared.queryAllVisibleWindows()
        }
    ) {
        self.activateApp = activateApp
        self.focusSpecificWindow = focusSpecificWindow
        self.raiseWindow = raiseWindow
        self.orderWindow = orderWindow
        self.visibleWindowInfoProvider = visibleWindowInfoProvider
    }

    static let live = WindowFocusOperations(
        activateApp: { pid in
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                runningApp.activate(options: [])
            }
        },
        focusSpecificWindow: { pid, windowId, element in
            Nehir.focusWindow(pid: pid, windowId: windowId, windowRef: element)
        },
        raiseWindow: { element in
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        },
        orderWindow: { windowId in
            SkyLight.shared.orderWindow(windowId, relativeTo: 0, order: .above)
        }
    )
}

@MainActor @Observable
final class WMController {
    private static let runtimeDebugLogger = Logger(subsystem: "com.nehir", category: "runtime-debug")

    struct WorkspaceBarRefreshDebugState {
        var requestCount: Int = 0
        var scheduledCount: Int = 0
        var executionCount: Int = 0
        var isQueued: Bool = false
        var invalidationCounts: [ProjectionInvalidation: Int] = [:]
    }

    struct StatusBarWorkspaceSummary: Equatable {
        let monitorId: Monitor.ID
        let workspaceLabel: String
        let workspaceRawName: String
        let focusedAppName: String?
    }

    struct WindowDecisionEvaluation {
        let token: WindowToken
        let facts: WindowRuleFacts
        let decision: WindowDecision
        let appFullscreen: Bool
        let manualOverride: ManualWindowOverride?
    }

    var isEnabled: Bool = true
    var hotkeysEnabled: Bool = true
    private(set) var desiredEnabled: Bool = true
    private(set) var desiredHotkeysEnabled: Bool = true
    private(set) var onboardingActive: Bool = false
    private(set) var accessibilityPermissionGranted = AccessibilityPermissionMonitor.shared.isGranted
    private(set) var focusFollowsMouseEnabled: Bool = false
    private(set) var moveMouseToFocusedWindowEnabled: Bool = false
    private var pointerFocusWarpSuppression: (token: WindowToken, timestamp: Date)?
    // Backstop for paths that don't go through focus confirmation (FFM, gesture snap).
    // 1s covers typical AX async confirmation latency with margin.
    private let pointerFocusWarpSuppressionInterval: TimeInterval = 1.0

    let settings: SettingsStore
    let workspaceManager: WorkspaceManager
    private let hotkeys = HotkeyCenter()
    let lockScreenObserver = LockScreenObserver()
    var isLockScreenActive: Bool = false {
        didSet {
            guard isLockScreenActive, oldValue != isLockScreenActive else { return }
            mouseEventHandler.handleInputSuppressionBegan()
        }
    }

    let axManager = AXManager()
    let appInfoCache = AppInfoCache()
    let focusBridge: FocusBridgeCoordinator
    let focusPolicyEngine: FocusPolicyEngine
    private let restorePlanner = RestorePlanner()
    let windowRuleEngine = WindowRuleEngine()

    /// The live Niri layout engine. Reads remain module-internal; writes are
    /// funneled through `setNiriEngine(_:)` so future ad-hoc assignments are a
    /// compile error rather than a code-review hope.
    private(set) var niriEngine: NiriLayoutEngine?

    /// The only sanctioned way to install/replace the live Niri engine.
    /// Reads remain module-internal; writes are funneled here so future
    /// ad-hoc assignments are caught at compile time.
    func setNiriEngine(_ engine: NiriLayoutEngine?) {
        niriEngine = engine
    }

    let tabbedOverlayManager = TabbedColumnOverlayManager()
    @ObservationIgnored
    lazy var nativeFullscreenPlaceholderManager: NativeFullscreenPlaceholderManager = {
        let manager = NativeFullscreenPlaceholderManager()
        manager.onActivate = { [weak self] token in
            self?.activateNativeFullscreenPlaceholder(token)
        }
        return manager
    }()

    @ObservationIgnored
    private(set) lazy var focusBorderController = FocusBorderController(controller: self)
    @ObservationIgnored
    private(set) lazy var workspaceBarManager: WorkspaceBarManager = .init()
    @ObservationIgnored
    private(set) lazy var debugBarManager: DebugBarManager = .init()
    @ObservationIgnored
    private var workspaceBarRefreshGeneration: UInt64 = 0
    @ObservationIgnored
    private var pendingWorkspaceBarRefreshGeneration: UInt64?
    @ObservationIgnored
    private(set) var hiddenWorkspaceBarMonitorIds: Set<Monitor.ID> = []
    @ObservationIgnored
    private lazy var commandPaletteController: CommandPaletteController = .init()

    var isTransferringWindow: Bool = false
    var hiddenAppPIDs: Set<pid_t> = []

    private struct ExplicitWorkspaceMoveIntent {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let createdAt: Date
    }

    @ObservationIgnored
    private var explicitWorkspaceMoveIntentsByToken: [WindowToken: ExplicitWorkspaceMoveIntent] = [:]
    private let explicitWorkspaceMoveIntentTTL: TimeInterval = 15

    @ObservationIgnored
    private(set) lazy var mouseEventHandler = MouseEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var mouseWarpHandler = MouseWarpHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var axEventHandler = AXEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var commandHandler = CommandHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var workspaceNavigationHandler = WorkspaceNavigationHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var layoutRefreshController = LayoutRefreshController(controller: self)
    var niriLayoutHandler: NiriLayoutHandler {
        layoutRefreshController.niriHandler
    }

    /// Narrow layout-command surface for command logic. Prefer this over the
    /// 41-method concrete `niriLayoutHandler` so the command boundary is an
    /// auditable type, not a code-review hope.
    var layoutCoordinator: LayoutCoordinator {
        niriLayoutHandler
    }

    /// Narrow seam for interactive-mode cancellation and focus-dependent reads,
    /// so handlers depend on the protocol rather than reaching into `niriEngine`.
    /// `WMController` itself conforms; see `FocusCoordinator.swift`.
    var focusCoordinator: FocusCoordinator {
        self
    }

    @ObservationIgnored
    private(set) lazy var serviceLifecycleManager = ServiceLifecycleManager(controller: self)
    @ObservationIgnored
    private(set) lazy var diagnostics = RuntimeDiagnosticsCoordinator(controller: self)
    @ObservationIgnored
    private(set) lazy var windowActionHandler = WindowActionHandler(
        controller: self,
        orderWindow: windowFocusOperations.orderWindow,
        visibleWindowInfoProvider: windowFocusOperations.visibleWindowInfoProvider
    )
    @ObservationIgnored
    private(set) lazy var focusNotificationDispatcher = FocusNotificationDispatcher(controller: self)
    @ObservationIgnored
    var hasStartedServices = false
    @ObservationIgnored
    private(set) var isMouseWarpPolicyEnabled = false
    @ObservationIgnored
    private let ownedWindowRegistry: OwnedWindowRegistry
    @ObservationIgnored
    private(set) var workspaceBarRefreshDebugState = WorkspaceBarRefreshDebugState()
    @ObservationIgnored
    var workspaceBarRefreshExecutionHookForTests: (() -> Void)?
    @ObservationIgnored
    var warpMouseCursorPosition: (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) }
    @ObservationIgnored
    var unmanagedWindowServerWindowFramesProvider: @MainActor (Set<Int>) -> [CGRect] = WMController
        .visibleUnmanagedWindowServerFrames
    @ObservationIgnored
    var unmanagedOverlayWindowServerWindowCoversOverride: (@MainActor (CGPoint) -> Bool)?
    /// On-screen WindowServer window records consulted by focus-follows-mouse's
    /// occlusion check. Defaults to the live `CGWindowList` snapshot; tests stub
    /// it so the occlusion decision is deterministic and does not depend on
    /// whatever real windows happen to be on screen. Each record is the raw
    /// `kCGWindowListCopyWindowInfo` dictionary (window id, owner pid, layer,
    /// bounds, on-screen flag).
    @ObservationIgnored
    var unmanagedOverlayWindowInfoProvider: @MainActor () -> [[String: Any]] = {
        CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// Reports whether the process owning an overlay window is a registered,
    /// bundled application. This is a structural, timing-independent signal
    /// (unlike an `AXUIElementCopyAttributeNames` query, which can transiently
    /// fail for a real app revealing a window and would let FFM fire through
    /// it). The snapshot fallback only exempts faceless owners when they also
    /// match a known decorative border utility name (e.g. JankyBorders'
    /// `borders` owner). Unknown faceless owners, including Ghostty's Quick
    /// terminal path, remain interactive/occluding. Override in tests.
    @ObservationIgnored
    var ownerAppIsInteractiveApplicationProvider: @MainActor (pid_t) -> Bool = { pid in
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.bundleIdentifier != nil
    }

    @ObservationIgnored
    weak var ipcApplicationBridge: IPCApplicationBridge?

    let animationClock = AnimationClock()
    let motionPolicy: MotionPolicy
    private let windowFocusOperations: WindowFocusOperations
    weak var statusBarController: StatusBarController?

    init(
        settings: SettingsStore,
        windowFocusOperations: WindowFocusOperations = .live,
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        self.settings = settings
        motionPolicy = MotionPolicy()
        self.windowFocusOperations = windowFocusOperations
        self.ownedWindowRegistry = ownedWindowRegistry
        workspaceManager = WorkspaceManager(settings: settings)
        focusBridge = FocusBridgeCoordinator()
        focusPolicyEngine = FocusPolicyEngine()
        workspaceManager.updateAnimationClock(animationClock)
        hotkeys.onCommand = { [weak self] command in
            self?.commandHandler.handleHotkeyCommand(command)
        }
        tabbedOverlayManager.onSelect = { [weak self] workspaceId, columnId, visualIndex in
            self?.layoutRefreshController.selectTabInNiri(
                workspaceId: workspaceId,
                columnId: columnId,
                visualIndex: visualIndex
            )
        }
        workspaceManager.onSessionStateChanged = { [weak self] in
            self?.handleSessionStateChanged()
        }
        workspaceManager.onProjectionInvalidated = { [weak self] invalidation in
            self?.requestProjectionRefresh(invalidation)
        }
        workspaceManager.onHiddenStateChanged = { [weak self] token, previousState, newState in
            self?.axEventHandler.handleManagedWindowHiddenStateChanged(
                token: token,
                previousState: previousState,
                newState: newState
            )
        }
        workspaceManager.setNiriViewportOffsetMutationObserver { [weak self] workspaceId in
            self?.diagnostics.recordRuntimeViewportTrace(
                workspaceId: workspaceId,
                reason: "relayout.viewportOffsetChanged",
                details: []
            )
        }
        focusPolicyEngine.onLeaseChanged = { [weak self] lease in
            self?.workspaceManager.recordReconcileEvent(
                .focusLeaseChanged(
                    lease: lease,
                    source: .focusPolicy
                )
            )
        }
        MenuAnywhereController.shared.onMenuTrackingChanged = { [weak self] isTracking in
            guard let self else { return }
            if isTracking {
                self.focusPolicyEngine.beginLease(
                    owner: .nativeMenu,
                    reason: "menu_anywhere",
                    suppressesFocusFollowsMouse: true,
                    duration: nil
                )
            } else {
                self.focusPolicyEngine.endLease(owner: .nativeMenu)
            }
        }
    }

    func applyPersistedSettings(_ settings: SettingsStore) {
        applyCurrentAppearanceMode()

        updateHotkeyBindings(settings.hotkeyBindings)
        setHotkeysEnabled(settings.hotkeysEnabled)

        setGapSize(settings.gapSize)
        setOuterGaps(
            left: settings.outerGapLeft,
            right: settings.outerGapRight,
            top: settings.outerGapTop,
            bottom: settings.outerGapBottom
        )

        if niriEngine == nil {
            enableNiriLayout(revealStyle: settings.revealStyle)
        }
        updateNiriConfig(
            balancedColumnCount: settings.niriBalancedColumnCount,
            infiniteLoop: settings.niriInfiniteLoop,
            revealStyle: settings.revealStyle,
            loneWindowPolicy: settings.loneWindowPolicy,
            columnWidthPresets: settings.niriColumnWidthPresets,
            defaultColumnWidth: settings.niriDefaultColumnWidth
        )

        updateWorkspaceConfig()
        updateMonitorOrientations()
        updateMonitorNiriSettings()
        updateAppRules()

        setBordersEnabled(settings.bordersEnabled)
        updateBorderConfig(BorderConfig.from(settings: settings))

        setFocusFollowsMouse(settings.focusFollowsMouse)
        setMoveMouseToFocusedWindow(settings.moveMouseToFocusedWindow)

        setWorkspaceBarEnabled(settings.workspaceBarEnabled)
        setPreventSleepEnabled(settings.preventSleepEnabled)

        // External edits to settings.toml otherwise stop here
        // and skip subsystems that read settings only at trigger time. Push the
        // remaining live values explicitly so editor saves take effect without
        // an app relaunch.
        updateWorkspaceBarSettings()
        diagnostics.updateBackgroundTraceBufferConfiguration()
        diagnostics.applyViewportTraceVerbosity()
        _ = syncMouseWarpPolicy()

        setEnabled(true)

        // Use the projection pipeline for status bar refresh so external config
        // reload follows the same path as UI-initiated settings changes.
        requestSettingsProjectionRefresh(reason: "externalSettingsReload")
    }

    func applyCurrentAppearanceMode() {
        settings.appearanceMode.apply()
        workspaceBarManager.updateSettings()
        statusBarController?.rebuildMenu()
    }

    func setEnabled(_ enabled: Bool) {
        desiredEnabled = enabled
        if enabled && !onboardingActive {
            serviceLifecycleManager.start()
        } else if !enabled {
            serviceLifecycleManager.stop()
        }
        reconcileEnabledAndHotkeysState()
    }

    /// While onboarding is active, the layout engine and global hotkeys are suppressed so the
    /// wizard never moves real windows or intercepts the shortcuts it teaches. Toggling back
    /// to false (re)activates the engine with the previously desired enabled state.
    func setOnboardingActive(_ active: Bool) {
        guard onboardingActive != active else { return }
        onboardingActive = active
        if active {
            serviceLifecycleManager.stop()
            reconcileEnabledAndHotkeysState()
            // Force re-evaluation so any existing bars are torn down immediately.
            workspaceBarManager.setEnabled(false)
        } else {
            setEnabled(desiredEnabled)
            // Re-apply the configured bar state now that the onboarding gate is open.
            setWorkspaceBarEnabled(settings.workspaceBarEnabled)
        }
    }

    func setHotkeysEnabled(_ enabled: Bool) {
        desiredHotkeysEnabled = enabled
        reconcileEnabledAndHotkeysState()
    }

    func updateAccessibilityPermissionGranted(_ granted: Bool) {
        accessibilityPermissionGranted = granted
        reconcileEnabledAndHotkeysState()
    }

    func reconcileEnabledAndHotkeysState() {
        // Onboarding suppresses both the layout engine and global hotkeys so the wizard
        // never moves real windows or intercepts the shortcuts it demonstrates.
        isEnabled = desiredEnabled && accessibilityPermissionGranted && !onboardingActive

        let shouldEnableHotkeys = desiredHotkeysEnabled
            && isEnabled
            && hasStartedServices
        hotkeysEnabled = shouldEnableHotkeys
        shouldEnableHotkeys ? hotkeys.start() : hotkeys.stop()
    }

    func setGapSize(_ size: Double) {
        workspaceManager.setGaps(to: size)
        niriEngine?.invalidateCachedLayoutSpans()
    }

    func setOuterGaps(left: Double, right: Double, top: Double, bottom: Double) {
        workspaceManager.setOuterGaps(left: left, right: right, top: top, bottom: bottom)
        niriEngine?.invalidateCachedLayoutSpans()
    }

    func updateMonitorGapSettings() {
        niriEngine?.invalidateCachedLayoutSpans()
        layoutRefreshController.requestRefresh(reason: .gapsChanged)
    }

    func resolvedGapSettings(for monitor: Monitor) -> ResolvedGapSettings {
        settings.resolvedGapSettings(for: monitor, connectedMonitors: workspaceManager.monitors)
    }

    func gapSize(for monitor: Monitor) -> CGFloat {
        CGFloat(resolvedGapSettings(for: monitor).gapSize)
    }

    func outerGaps(for monitor: Monitor) -> LayoutGaps.OuterGaps {
        resolvedGapSettings(for: monitor).outerGaps
    }

    func setBordersEnabled(_ enabled: Bool) {
        focusBorderController.setEnabled(enabled)
    }

    func updateBorderConfig(_ config: BorderConfig) {
        focusBorderController.updateConfig(config)
    }

    func setWorkspaceBarEnabled(_ enabled: Bool) {
        if settings.workspaceBarEnabled != enabled {
            settings.workspaceBarEnabled = enabled
        }
        pruneHiddenWorkspaceBarMonitorIds()
        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.setup(controller: self, settings: settings)
        debugBarManager.setup(controller: self, settings: settings)
        // isWorkspaceBarVisible gates on onboardingActive, so this is a no-op render while
        // onboarding is active and renders the bar once it completes.
        workspaceBarManager.setEnabled(enabled)
        layoutRefreshController.requestRefresh(reason: .monitorSettingsChanged)
    }

    func cleanupUIOnStop() {
        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.cleanup()
        debugBarManager.cleanup()
    }

    func setPreventSleepEnabled(_ enabled: Bool) {
        if enabled {
            SleepPreventionManager.shared.preventSleep()
        } else {
            SleepPreventionManager.shared.allowSleep()
        }
    }

    @discardableResult
    func toggleWorkspaceBarVisibility() -> Bool {
        pruneHiddenWorkspaceBarMonitorIds()

        guard let monitor = monitorForInteraction() else { return false }
        let resolved = settings.resolvedBarSettings(for: monitor)
        guard resolved.enabled else { return false }

        if hiddenWorkspaceBarMonitorIds.contains(monitor.id) {
            hiddenWorkspaceBarMonitorIds.remove(monitor.id)
        } else {
            hiddenWorkspaceBarMonitorIds.insert(monitor.id)
        }

        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.setup(controller: self, settings: settings)
        debugBarManager.setup(controller: self, settings: settings)
        layoutRefreshController.requestRefresh(reason: .monitorSettingsChanged)
        return true
    }

    func requestProjectionRefresh(_ invalidation: ProjectionInvalidationRequest) {
        workspaceBarRefreshDebugState.invalidationCounts[invalidation.kind, default: 0] += 1

        switch invalidation.kind {
        case .workspaceProjection:
            requestWorkspaceProjectionRefreshScheduling()
        case .focusProjection:
            // Focus changes are relevant to both the status bar (workspace-name
            // display) and the workspace bar (per-window focus indicator), so
            // refresh both surfaces. This closes the family of "focus changed but
            // the workspace bar didn't move" paths (e.g. click / focus-follows-
            // mouse confirms) that previously only invalidated the status bar.
            requestFocusProjectionRefreshScheduling()
            requestWorkspaceProjectionRefreshScheduling()
        case .settingsProjection:
            requestSettingsProjectionRefreshScheduling()
        case .layoutProjection,
             .displayProjection:
            break
        }
    }

    func requestWorkspaceProjectionRefresh(reason: String = "workspaceProjection") {
        requestProjectionRefresh(.init(.workspaceProjection, reason: reason))
    }

    func requestSettingsProjectionRefresh(reason: String = "settingsProjection") {
        requestProjectionRefresh(.init(.settingsProjection, reason: reason))
    }

    private func requestWorkspaceProjectionRefreshScheduling() {
        workspaceBarRefreshDebugState.requestCount += 1

        guard hasWorkspaceProjectionRefreshConsumers else { return }
        guard pendingWorkspaceBarRefreshGeneration == nil else { return }

        let generation = workspaceBarRefreshGeneration
        pendingWorkspaceBarRefreshGeneration = generation
        workspaceBarRefreshDebugState.scheduledCount += 1
        workspaceBarRefreshDebugState.isQueued = true

        Task { @MainActor [weak self] in
            await Task.yield()
            await Task.yield()
            self?.flushRequestedWorkspaceProjectionRefresh(expectedGeneration: generation)
        }
    }

    private var pendingStatusBarRefreshGeneration: Int?
    private var statusBarRefreshGeneration: Int = 0

    private func requestFocusProjectionRefreshScheduling() {
        // Focus changes are only interesting while the status bar is actually
        // displaying workspace info, so skip them when the feature is off.
        requestStatusBarRefreshScheduling(reason: "focusProjection", requireFeatureEnabled: true)
    }

    private func requestSettingsProjectionRefreshScheduling() {
        // Settings refreshes must run even when the feature is being turned OFF —
        // otherwise the status bar never clears its title (it stays until restart).
        // refreshWorkspaces() applies the current settings, including hiding.
        requestStatusBarRefreshScheduling(reason: "settingsProjection", requireFeatureEnabled: false)
    }

    private func requestStatusBarRefreshScheduling(reason: String, requireFeatureEnabled: Bool) {
        guard statusBarController != nil else { return }
        if requireFeatureEnabled {
            guard settings.statusBarShowWorkspaceName else { return }
        }
        guard pendingStatusBarRefreshGeneration == nil else { return }

        let generation = statusBarRefreshGeneration
        pendingStatusBarRefreshGeneration = generation

        Task { @MainActor [weak self] in
            await Task.yield()
            await Task.yield()
            self?.flushRequestedStatusBarRefresh(expectedGeneration: generation)
        }
    }

    private func flushRequestedStatusBarRefresh(expectedGeneration: Int) {
        guard pendingStatusBarRefreshGeneration == expectedGeneration else { return }
        pendingStatusBarRefreshGeneration = nil
        refreshStatusBar()
    }

    func isManagedWindowDisplayable(_ handle: WindowHandle) -> Bool {
        guard workspaceManager.entry(for: handle) != nil else { return false }
        if hiddenAppPIDs.contains(handle.pid) {
            return false
        }
        if workspaceManager.layoutReason(for: handle.id) != .standard {
            return false
        }
        return !workspaceManager.isHiddenInCorner(handle.id)
    }

    func isManagedWindowSuspendedForNativeFullscreen(_ token: WindowToken) -> Bool {
        workspaceManager.isNativeFullscreenSuspended(token)
    }

    func refreshStatusBar() {
        statusBarController?.refreshWorkspaces()
    }

    func activeStatusBarWorkspaceSummary() -> StatusBarWorkspaceSummary? {
        guard let monitor = monitorForInteraction(),
              let workspace = workspaceManager.currentActiveWorkspace(on: monitor.id)
        else {
            return nil
        }

        let focusedAppName: String? = if let focusedToken = workspaceManager.confirmedManagedFocusToken,
                                         let entry = workspaceManager.entry(for: focusedToken),
                                         entry.workspaceId == workspace.id
        {
            resolvedAppInfo(for: entry.pid)?.name
        } else {
            nil
        }

        return StatusBarWorkspaceSummary(
            monitorId: monitor.id,
            workspaceLabel: settings.displayName(for: workspace.name),
            workspaceRawName: workspace.name,
            focusedAppName: focusedAppName
        )
    }

    func updateWorkspaceBarSettings() {
        pruneHiddenWorkspaceBarMonitorIds()
        cancelPendingWorkspaceBarRefresh()
        workspaceBarManager.updateSettings()
        debugBarManager.setup(controller: self, settings: settings)
        layoutRefreshController.requestRefresh(reason: .monitorSettingsChanged)
    }

    func updateWorkspaceBarAppearance() {
        workspaceBarManager.updateAppearance()
    }

    func updateMonitorOrientations() {
        let monitors = workspaceManager.monitors
        for monitor in monitors {
            let orientation = settings.effectiveOrientation(for: monitor)
            niriEngine?.monitors[monitor.id]?.updateOrientation(orientation)
        }
        layoutRefreshController.requestRefresh(reason: .monitorSettingsChanged)
    }

    func updateMonitorNiriSettings() {
        guard niriEngine != nil else { return }
        niriLayoutHandler.refreshResolvedMonitorSettings()
        layoutRefreshController.requestRefresh(reason: .monitorSettingsChanged)
    }

    func workspaceBarItems(
        for monitor: Monitor,
        projection options: WorkspaceBarProjectionOptions
    ) -> [WorkspaceBarItem] {
        WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: options,
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            niriEngine: niriEngine,
            focusedToken: workspaceManager.confirmedManagedFocusToken,
            viewportSelectedToken: viewportSelectedToken(for: monitor),
            settings: settings
        )
    }

    func workspaceBarMoveTargets() -> [WorkspaceBarWindowMoveTarget] {
        WorkspaceBarDataSource.workspaceBarMoveTargets(
            workspaceManager: workspaceManager,
            settings: settings
        )
    }

    func workspaceBarProjection(
        for monitor: Monitor,
        projection options: WorkspaceBarProjectionOptions,
        moveTargets: [WorkspaceBarWindowMoveTarget]? = nil
    ) -> WorkspaceBarProjection {
        WorkspaceBarDataSource.workspaceBarProjection(
            for: monitor,
            options: options,
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            niriEngine: niriEngine,
            focusedToken: workspaceManager.confirmedManagedFocusToken,
            viewportSelectedToken: viewportSelectedToken(for: monitor),
            settings: settings,
            moveTargets: moveTargets
        )
    }

    func toggleViewportScrollLock(on monitorId: Monitor.ID? = nil) {
        guard let monitorId else {
            niriLayoutHandler.toggleViewportScrollLock()
            return
        }
        guard let workspaceId = workspaceManager.activeWorkspaceOrFirst(on: monitorId)?.id else { return }
        niriLayoutHandler.toggleViewportScrollLock(in: workspaceId)
    }

    /// Resolves the window the viewport is parked on for the monitor's active
    /// workspace, so the workspace bar can highlight the viewport column even
    /// when managed-focus confirmation is suppressed (a non-managed app holds
    /// focus). Returns `nil` when there is no engine, no active workspace, or no
    /// selected node — in which case the bar falls back to managed-focus only.
    private func viewportSelectedToken(for monitor: Monitor) -> WindowToken? {
        guard let engine = niriEngine,
              let workspace = workspaceManager.activeWorkspace(on: monitor.id)
        else { return nil }
        let state = workspaceManager.niriViewportState(for: workspace.id)
        guard let selectedNodeId = state.selectedNodeId,
              let window = engine.findNode(by: selectedNodeId) as? NiriWindow
        else {
            return nil
        }
        return window.token
    }

    func focusWorkspaceFromBar(named name: String) {
        windowActionHandler.focusWorkspaceFromBar(named: name, suppressMouseWarp: true)
    }

    func focusWorkspaceFromBar(id workspaceId: WorkspaceDescriptor.ID) {
        windowActionHandler.focusWorkspaceFromBar(id: workspaceId, suppressMouseWarp: true)
    }

    /// Shift+click on a workspace pill moves the focused managed window to that
    /// workspace. Mirrors `focusWorkspaceFromBar(id:)` and reuses the existing
    /// `moveFocusedWindow(toRawWorkspaceID:)` pipeline (target-viewport reveal +
    /// `focusFollowsWindowToMonitor`). Silent no-op if the workspace is unknown or
    /// no managed window is focused (same early-return behavior as the hotkey path).
    func moveFocusedWindowFromBar(toWorkspaceId id: WorkspaceDescriptor.ID) {
        guard let rawID = workspaceManager.descriptor(for: id)?.name else { return }
        workspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID: rawID)
    }

    func focusWindowFromBar(token: WindowToken) {
        windowActionHandler.focusWindowFromBar(token: token, suppressMouseWarp: true)
    }

    /// Token-based close backing the workspace bar's right-click *Close* item.
    /// Resolves the token to its handle (same lookup as
    /// `focusWindowFromBar(token:)`) and delegates to the shared
    /// `WindowActionHandler.closeWindow(handle:)`.
    @discardableResult
    func closeWindowFromBar(token: WindowToken) -> ExternalCommandResult {
        guard windowActionHandler.closeWindow(token: token) else {
            return .notFound
        }
        return .executed
    }

    /// Token-based move backing the workspace bar's right-click *Move to
    /// Workspace* submenu. Resolves the token to its handle and delegates to
    /// `WorkspaceNavigationHandler.moveWindowFromBar(handle:toWorkspaceId:)`,
    /// which commits the workspace transition so the affected workspaces relayout
    /// immediately after the explicit-token move.
    @discardableResult
    func moveWindowFromBar(token: WindowToken, toWorkspaceId: WorkspaceDescriptor.ID) -> ExternalCommandResult {
        guard let entry = workspaceManager.entry(for: token) else {
            return .notFound
        }
        let moved = workspaceNavigationHandler.moveWindowFromBar(
            handle: entry.handle,
            toWorkspaceId: toWorkspaceId
        )
        return moved ? .executed : .notFound
    }

    @discardableResult
    func activateScratchpadFromBar(on monitorId: Monitor.ID?) -> ExternalCommandResult {
        guard let scratchpadToken = workspaceManager.scratchpadToken() else {
            return .notFound
        }
        guard let entry = workspaceManager.entry(for: scratchpadToken) else {
            cleanupScratchpadWindowResources(for: scratchpadToken)
            return .notFound
        }
        guard !isManagedWindowSuspendedForNativeFullscreen(scratchpadToken) else {
            return .notFound
        }

        if let monitorId {
            _ = workspaceManager.setInteractionMonitor(monitorId)
        }

        if let hiddenState = workspaceManager.hiddenState(for: scratchpadToken) {
            guard hiddenState.isScratchpad || hiddenState.workspaceInactive,
                  let target = scratchpadTarget(on: monitorId)
            else {
                return .notFound
            }
            let updatedEntry = workspaceManager.entry(for: scratchpadToken) ?? entry
            return showScratchpadWindow(updatedEntry, on: target.workspaceId, monitor: target.monitor)
                ? .executed
                : .notFound
        }

        if windowActionHandler.focusWindowFromBar(token: scratchpadToken, suppressMouseWarp: true) {
            return .executed
        }

        focusWindow(scratchpadToken)
        return .executed
    }

    func setFocusFollowsMouse(_ enabled: Bool) {
        focusFollowsMouseEnabled = enabled
    }

    func setMoveMouseToFocusedWindow(_ enabled: Bool) {
        moveMouseToFocusedWindowEnabled = enabled
    }

    func suppressMouseMoveToFocusedWindow(for token: WindowToken) {
        pointerFocusWarpSuppression = (token, Date())
    }

    func shouldSuppressMouseMoveToFocusedWindow(for token: WindowToken) -> Bool {
        guard let suppression = pointerFocusWarpSuppression else { return false }
        guard Date().timeIntervalSince(suppression.timestamp) <= pointerFocusWarpSuppressionInterval else {
            return false
        }
        return suppression.token == token
    }

    func shouldUseMouseWarp(for monitors: [Monitor]? = nil) -> Bool {
        guard settings.mouseWarpEnabled else { return false }
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        return effectiveMonitors.count > 1
    }

    @discardableResult
    func syncMouseWarpPolicy(for monitors: [Monitor]? = nil) -> Bool {
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        let shouldEnable = shouldUseMouseWarp(for: effectiveMonitors)

        guard shouldEnable != isMouseWarpPolicyEnabled else {
            return shouldEnable
        }

        if shouldEnable {
            mouseWarpHandler.setup()
        } else {
            mouseWarpHandler.cleanup()
        }

        isMouseWarpPolicyEnabled = shouldEnable
        return shouldEnable
    }

    func resetMouseWarpPolicy() {
        mouseWarpHandler.cleanup()
        isMouseWarpPolicyEnabled = false
    }

    func insetWorkingFrame(for monitor: Monitor) -> CGRect {
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
        let resolved = settings.resolvedBarSettings(for: monitor)
        var reservedTopInset = WorkspaceBarGeometry.resolve(
            monitor: monitor,
            resolved: resolved,
            isVisible: isWorkspaceBarVisible(on: monitor, resolved: resolved)
        ).reservedTopInset
        // Keep managed windows out of the auto-hidden menu bar's reveal region
        // so they stay aligned with the (re-anchored) workspace bar. No-op when
        // the menu bar inset is already in `visibleFrame` (visible menu bar / notch).
        if WorkspaceBarGeometry.effectivePosition(for: monitor, resolved: resolved) == .belowMenuBar {
            reservedTopInset += WorkspaceBarGeometry.additionalMenuBarTopStrut(for: monitor)
        }
        return insetWorkingFrame(
            from: monitor.visibleFrame,
            scale: scale,
            reservedTopInset: reservedTopInset,
            outerGaps: outerGaps(for: monitor)
        )
    }

    func insetWorkingFrame(
        from frame: CGRect,
        scale: CGFloat = 2.0,
        reservedTopInset: CGFloat = 0,
        outerGaps: LayoutGaps.OuterGaps? = nil
    ) -> CGRect {
        let outer = outerGaps ?? workspaceManager.outerGaps
        let struts = Struts(
            left: outer.left,
            right: outer.right,
            top: outer.top + reservedTopInset,
            bottom: outer.bottom
        )
        return computeWorkingArea(
            parentArea: frame,
            scale: scale,
            struts: struts
        )
    }

    func updateHotkeyBindings(_ bindings: [HotkeyBinding], force: Bool = false) {
        hotkeys.updateBindings(bindings, force: force)
    }

    func updateWorkspaceConfig() {
        workspaceManager.applySettings()
        syncMonitorsToNiriEngine()
        layoutRefreshController.requestRefresh(reason: .workspaceConfigChanged)
    }

    func rebuildAppRulesCache() {
        windowRuleEngine.rebuild(rules: settings.appRules)
    }

    func updateAppRules() {
        rebuildAppRulesCache()
        layoutRefreshController.requestRefresh(reason: .appRulesChanged)
    }

    var hotkeyRegistrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] {
        hotkeys.registrationFailures
    }

    private var workspaceBarRefreshIsEnabled: Bool {
        settings.workspaceBarEnabled || settings.monitorBarSettings.contains(where: { $0.enabled == true })
    }

    private var statusBarRefreshIsEnabled: Bool {
        statusBarController != nil && settings.statusBarShowWorkspaceName
    }

    private var anyBarRefreshIsEnabled: Bool {
        workspaceBarRefreshIsEnabled || statusBarRefreshIsEnabled
    }

    private var hasWorkspaceProjectionRefreshConsumers: Bool {
        anyBarRefreshIsEnabled
            || ipcApplicationBridge?.hasSubscribers(for: .workspaceBar) == true
            || ipcApplicationBridge?.hasSubscribers(for: .windowsChanged) == true
            || ipcApplicationBridge?.hasSubscribers(for: .layoutChanged) == true
    }

    private func flushRequestedWorkspaceProjectionRefresh(expectedGeneration: UInt64) {
        guard pendingWorkspaceBarRefreshGeneration == expectedGeneration,
              workspaceBarRefreshGeneration == expectedGeneration
        else {
            return
        }

        pendingWorkspaceBarRefreshGeneration = nil
        workspaceBarRefreshDebugState.isQueued = false

        guard hasWorkspaceProjectionRefreshConsumers else { return }

        workspaceBarRefreshDebugState.executionCount += 1
        workspaceBarRefreshExecutionHookForTests?()
        if workspaceBarRefreshIsEnabled {
            workspaceBarManager.update()
        }
        if statusBarRefreshIsEnabled {
            refreshStatusBar()
        }
        if let ipcApplicationBridge {
            Task {
                await ipcApplicationBridge.publishEvent(.workspaceBar)
                await ipcApplicationBridge.publishEvent(.windowsChanged)
                await ipcApplicationBridge.publishEvent(.layoutChanged)
            }
        }
    }

    private func cancelPendingWorkspaceBarRefresh() {
        pendingWorkspaceBarRefreshGeneration = nil
        workspaceBarRefreshGeneration &+= 1
        workspaceBarRefreshDebugState.isQueued = false
    }

    func isWorkspaceBarVisible(on monitor: Monitor, resolved: ResolvedBarSettings? = nil) -> Bool {
        // Onboarding suppresses the workspace bar regardless of config — it must not render
        // until the wizard completes. This is the single chokepoint consulted by
        // `reconfigureBars`, so it gates every entry path (setup, screen-change observer,
        // sleep/wake, scheduled reconfigures).
        if onboardingActive { return false }
        let effective = resolved ?? settings.resolvedBarSettings(for: monitor)
        return effective.enabled && !hiddenWorkspaceBarMonitorIds.contains(monitor.id)
    }

    private func pruneHiddenWorkspaceBarMonitorIds() {
        hiddenWorkspaceBarMonitorIds = hiddenWorkspaceBarMonitorIds.filter { monitorId in
            guard let monitor = workspaceManager.monitor(byId: monitorId) else { return false }
            return settings.resolvedBarSettings(for: monitor).enabled
        }
    }

    func waitForWorkspaceBarRefreshForTests() async {
        for _ in 0 ..< 100 {
            await Task.yield()
            if !workspaceBarRefreshDebugState.isQueued {
                break
            }
        }
        await Task.yield()
    }

    func waitForStatusBarRefreshForTests() async {
        for _ in 0 ..< 100 {
            await Task.yield()
            if pendingStatusBarRefreshGeneration == nil {
                break
            }
        }
        await Task.yield()
    }

    func resetWorkspaceBarRefreshDebugStateForTests() {
        cancelPendingWorkspaceBarRefresh()
        pendingStatusBarRefreshGeneration = nil
        workspaceBarRefreshDebugState = .init()
        workspaceBarRefreshExecutionHookForTests = nil
    }

    func activeWorkspaceBarCountForTests() -> Int {
        workspaceBarManager.activeBarCountForTests()
    }

    func isWorkspaceBarRuntimeHiddenForTests(on monitorId: Monitor.ID) -> Bool {
        hiddenWorkspaceBarMonitorIds.contains(monitorId)
    }

    func configureWorkspaceBarManagerForTests(monitors: [Monitor]) {
        workspaceBarManager.monitorProvider = { monitors }
        workspaceBarManager.screenProvider = { _ in nil }
    }

    func enableNiriLayout(revealStyle: RevealStyle) {
        niriLayoutHandler.enableNiriLayout(revealStyle: revealStyle)
    }

    func syncMonitorsToNiriEngine() {
        niriLayoutHandler.syncMonitorsToNiriEngine()
    }

    func updateNiriConfig(
        balancedColumnCount: Int? = nil,
        infiniteLoop: Bool? = nil,
        revealStyle: RevealStyle? = nil,
        loneWindowPolicy: LoneWindowPolicy? = nil,
        columnWidthPresets: [Double]? = nil,
        defaultColumnWidth: Double?? = nil
    ) {
        niriLayoutHandler.updateNiriConfig(
            balancedColumnCount: balancedColumnCount,
            infiniteLoop: infiniteLoop,
            revealStyle: revealStyle,
            loneWindowPolicy: loneWindowPolicy,
            columnWidthPresets: columnWidthPresets,
            defaultColumnWidth: defaultColumnWidth
        )
    }

    func monitorForInteraction() -> Monitor? {
        if let interactionMonitorId = workspaceManager.interactionMonitorId,
           let monitor = workspaceManager.monitor(byId: interactionMonitorId)
        {
            return monitor
        }
        if let focusedToken = workspaceManager.confirmedManagedFocusToken,
           let workspaceId = workspaceManager.workspace(for: focusedToken),
           let monitor = workspaceManager.monitor(for: workspaceId)
        {
            return monitor
        }
        return workspaceManager.monitors.first
    }

    private func handleSessionStateChanged() {
        let changeSet = focusNotificationDispatcher.notifyFocusChangesIfNeeded()
        if let ipcApplicationBridge {
            Task {
                if changeSet.focusChanged {
                    await ipcApplicationBridge.publishEvent(.focus)
                }
                if changeSet.workspaceChanged || changeSet.monitorChanged {
                    await ipcApplicationBridge.publishEvent(.activeWorkspace)
                }
                if changeSet.monitorChanged {
                    await ipcApplicationBridge.publishEvent(.focusedMonitor)
                    await ipcApplicationBridge.publishEvent(.displayChanged)
                }
            }
        }
    }

    func interactionWorkspace() -> WorkspaceDescriptor? {
        guard let monitor = monitorForInteraction() else { return nil }
        return workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
    }

    func resolveWorkspaceForNewWindow(
        workspaceName: String? = nil,
        axRef: AXWindowRef,
        pid: pid_t,
        parentWindowId: UInt32? = nil,
        inheritTrackedParentWorkspace: Bool = false,
        preferSameAppSiblingWorkspace: Bool = false,
        bindTransientFloatingToAppWorkspace: Bool = false,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID? = nil,
        restrictWorkspaceRuleToPlacementMonitor: Bool = true,
        createPlacementContext: WindowCreatePlacementContext? = nil,
        windowFrame: CGRect? = nil,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceDescriptor.ID {
        resolveWorkspacePlacement(
            workspaceName: workspaceName,
            axRef: axRef,
            pid: pid,
            parentWindowId: parentWindowId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            preferSameAppSiblingWorkspace: preferSameAppSiblingWorkspace,
            bindTransientFloatingToAppWorkspace: bindTransientFloatingToAppWorkspace,
            structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
            restrictWorkspaceRuleToPlacementMonitor: restrictWorkspaceRuleToPlacementMonitor,
            createPlacementContext: createPlacementContext,
            windowFrame: windowFrame,
            existingEntry: nil,
            fallbackWorkspaceId: fallbackWorkspaceId,
            context: .automatic
        )
    }

    private struct WorkspacePlacementTarget {
        let workspaceId: WorkspaceDescriptor.ID?
        let monitorId: Monitor.ID?
        let isAuthoritative: Bool
    }

    private func resolveWorkspacePlacement(
        workspaceName: String?,
        axRef: AXWindowRef,
        pid: pid_t?,
        parentWindowId: UInt32?,
        inheritTrackedParentWorkspace: Bool,
        preferSameAppSiblingWorkspace: Bool,
        bindTransientFloatingToAppWorkspace: Bool,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID?,
        restrictWorkspaceRuleToPlacementMonitor: Bool,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        existingEntry: WindowModel.Entry?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        context: WindowRuleReevaluationContext
    ) -> WorkspaceDescriptor.ID {
        if context == .automatic, let existingEntry {
            return existingEntry.workspaceId
        }

        if existingEntry == nil,
           let explicitMoveTarget = explicitWorkspaceMovePlacementTarget(pid: pid, windowId: axRef.windowId),
           let workspaceId = explicitMoveTarget.workspaceId
        {
            return workspaceId
        }

        if existingEntry == nil,
           let structuralReplacementWorkspaceId,
           workspaceManager.descriptor(for: structuralReplacementWorkspaceId) != nil
        {
            return structuralReplacementWorkspaceId
        }

        if existingEntry == nil,
           inheritTrackedParentWorkspace,
           let parentWorkspaceId = workspaceForTrackedParentWindow(parentWindowId: parentWindowId, pid: pid)
        {
            return parentWorkspaceId
        }

        let placementTarget = createPlacementTarget(
            axRef: axRef,
            pid: existingEntry == nil ? pid : nil,
            createPlacementContext: createPlacementContext,
            windowFrame: windowFrame,
            fallbackWorkspaceId: fallbackWorkspaceId,
            preferManagedFocusPlacement: existingEntry == nil && restrictWorkspaceRuleToPlacementMonitor
        )

        if context == .automatic,
           existingEntry == nil,
           preferSameAppSiblingWorkspace,
           let pid,
           let siblingWorkspaceId = workspaceForNewSiblingWindow(
               pid: pid,
               fallbackWorkspaceId: fallbackWorkspaceId,
               targetMonitorId: placementTarget.isAuthoritative ? placementTarget.monitorId : nil
           )
        {
            return siblingWorkspaceId
        }

        if let workspaceName,
           let workspaceId = workspaceManager.workspaceId(for: workspaceName, createIfMissing: false),
           existingEntry != nil ||
           !restrictWorkspaceRuleToPlacementMonitor ||
           shouldApplyWorkspaceRule(workspaceId, placementTarget: placementTarget)
        {
            return workspaceId
        }

        // A newly-created non-user-addressable transient floating surface with no
        // document/parent binding (e.g. a Teams/Zoom call mini-window) is app-managed
        // ephemeral UI. It must follow its owning app's primary window rather than the
        // currently-viewed workspace, otherwise it "leaks" onto whatever workspace the
        // user happens to be viewing and can then anchor managed focus there, dragging
        // later siblings across. User-addressable transient standard windows (e.g.
        // Zoom's full call window) keep normal placement; sticky/global surfaces are
        // reanchored separately by LayoutRefreshController.
        if context == .automatic,
           existingEntry == nil,
           bindTransientFloatingToAppWorkspace,
           let pid,
           let siblingWorkspaceId = workspaceForPrimarySiblingWindow(pid: pid)
        {
            return siblingWorkspaceId
        }

        if let existingEntry {
            return existingEntry.workspaceId
        }

        return defaultWorkspaceId(placementTarget: placementTarget)
    }

    private func workspaceForTrackedParentWindow(
        parentWindowId: UInt32?,
        pid _: pid_t?
    ) -> WorkspaceDescriptor.ID? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return workspaceManager.entry(forWindowId: Int(parentWindowId))?.workspaceId
    }

    private func workspaceForNewSiblingWindow(
        pid: pid_t,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        targetMonitorId: Monitor.ID?
    ) -> WorkspaceDescriptor.ID? {
        let entries = workspaceManager.entries(forPid: pid)
        guard let firstEntry = entries.first else { return nil }

        if let focusedToken = workspaceManager.confirmedManagedFocusToken,
           let focusedEntry = entries.first(where: { $0.token == focusedToken }),
           workspace(focusedEntry.workspaceId, isOn: targetMonitorId)
        {
            return focusedEntry.workspaceId
        }

        if let fallbackWorkspaceId,
           entries.contains(where: { $0.workspaceId == fallbackWorkspaceId }),
           workspace(fallbackWorkspaceId, isOn: targetMonitorId)
        {
            return fallbackWorkspaceId
        }

        let workspaceId = firstEntry.workspaceId
        guard entries.dropFirst().allSatisfy({ $0.workspaceId == workspaceId }),
              workspace(workspaceId, isOn: targetMonitorId)
        else {
            return nil
        }
        return workspaceId
    }

    /// The workspace of an app's primary (non-transient) window. Used to bind a
    /// newly-created small transient floating surface (e.g. a Teams/Zoom call
    /// mini-window) to its owning app instead of the currently-viewed workspace.
    /// Prefers a non-transient sibling so a transient helper never anchors placement
    /// for the app's real windows; falls back to a shared workspace if all siblings
    /// agree.
    private func workspaceForPrimarySiblingWindow(pid: pid_t) -> WorkspaceDescriptor.ID? {
        let entries = workspaceManager.entries(forPid: pid)
        if let primary = entries.first(where: {
            $0.managedReplacementMetadata?.transientWindowServerEvidence != true
        }) {
            return primary.workspaceId
        }
        guard let firstEntry = entries.first else { return nil }
        let workspaceId = firstEntry.workspaceId
        if entries.dropFirst().allSatisfy({ $0.workspaceId == workspaceId }) {
            return workspaceId
        }
        return nil
    }

    private func isNonUserAddressableNonGlobalTransientFloatingSurface(_ entry: WindowModel.Entry) -> Bool {
        guard entry.managedReplacementMetadata?.transientWindowServerEvidence == true,
              !workspaceManager.hasStickyWindowSource(entry.token)
        else {
            return false
        }
        return entry.managedReplacementMetadata?.userAddressableTransientWindowServerSurface != true
    }

    private func workspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        isOn targetMonitorId: Monitor.ID?
    ) -> Bool {
        guard let targetMonitorId else { return true }
        return workspaceManager.monitorId(for: workspaceId) == targetMonitorId
    }

    private func shouldApplyWorkspaceRule(
        _ workspaceId: WorkspaceDescriptor.ID,
        placementTarget: WorkspacePlacementTarget
    ) -> Bool {
        guard placementTarget.isAuthoritative,
              let targetMonitorId = placementTarget.monitorId,
              let workspaceMonitorId = workspaceManager.monitorId(for: workspaceId)
        else {
            return true
        }
        return workspaceMonitorId == targetMonitorId
    }

    func shouldInheritTrackedParentWorkspace(for evaluation: WindowDecisionEvaluation) -> Bool {
        let facts = evaluation.facts
        guard let windowServer = facts.windowServer,
              windowServer.parentId != 0
        else {
            return false
        }

        // Match niri's parented-window model: a window with a concrete parent is
        // child UI of that parent (dialogs/popovers/sheets), so keep it on the
        // parent's workspace instead of resolving it against interaction focus.
        if let parentWindowId = UInt32(exactly: windowServer.parentId),
           workspaceManager.entry(forWindowId: Int(parentWindowId)) != nil
        {
            return true
        }

        if windowServer.hasDocumentTag {
            return false
        }

        return windowServer.hasModalTag || windowServer.hasTransientSurfaceEvidence
    }

    func shouldPreferSameAppSiblingWorkspace(
        for evaluation: WindowDecisionEvaluation,
        inheritTrackedParentWorkspace: Bool
    ) -> Bool {
        guard let workspaceName = evaluation.decision.workspaceName,
              workspaceManager.workspaceId(for: workspaceName, createIfMissing: false) != nil,
              evaluation.decision.disposition == .managed,
              !inheritTrackedParentWorkspace
        else {
            return false
        }

        let axFacts = evaluation.facts.ax
        guard axFacts.attributeFetchSucceeded,
              axFacts.role == kAXWindowRole as String
        else {
            return false
        }

        return axFacts.subrole == nil || axFacts.subrole == kAXStandardWindowSubrole as String
    }

    private func defaultWorkspaceId(placementTarget: WorkspacePlacementTarget) -> WorkspaceDescriptor.ID {
        if let workspaceId = placementTarget.workspaceId {
            return workspaceId
        }

        if let monitor = monitorForInteraction(),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return workspace.id
        }
        if let workspaceId = workspaceManager.primaryWorkspace()?.id ?? workspaceManager.workspaces.first?.id {
            return workspaceId
        }
        if let createdWorkspaceId = workspaceManager.workspaceId(for: "1", createIfMissing: false) {
            return createdWorkspaceId
        }
        fatalError("resolveWorkspaceForNewWindow: no workspaces exist")
    }

    private func createPlacementTarget(
        axRef: AXWindowRef,
        pid: pid_t?,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        preferManagedFocusPlacement: Bool
    ) -> WorkspacePlacementTarget {
        if let target = explicitWorkspaceMovePlacementTarget(pid: pid, windowId: axRef.windowId) {
            return target
        }

        if preferManagedFocusPlacement {
            if let target = managedFocusPlacementTarget(
                createPlacementContext?.activeFocusRequestWorkspaceId,
                createPlacementContext?.activeFocusRequestMonitorId
            ) {
                return target
            }

            if let nativeMonitorId = createPlacementContext?.nativeSpaceMonitorId,
               let workspace = workspaceManager.activeWorkspaceOrFirst(on: nativeMonitorId)
            {
                return WorkspacePlacementTarget(
                    workspaceId: workspace.id,
                    monitorId: nativeMonitorId,
                    isAuthoritative: true
                )
            }

            let frameMonitor = monitorForPlacementFrame(windowFrame)
                ?? (workspaceManager.monitors.count > 1
                    ? monitorForPlacementFrame(AXWindowService.framePreferFast(axRef))
                    : nil)
            if let focusedMonitorId = createPlacementContext?.focusedMonitorId {
                if let frameMonitor,
                   frameMonitor.id != focusedMonitorId,
                   (createPlacementContext?.interactionMonitorId == nil
                       || createPlacementContext?.interactionMonitorId == frameMonitor.id),
                   let workspace = workspaceManager.activeWorkspaceOrFirst(on: frameMonitor.id)
                {
                    return WorkspacePlacementTarget(
                        workspaceId: workspace.id,
                        monitorId: frameMonitor.id,
                        isAuthoritative: true
                    )
                }

                if let interactionMonitorId = createPlacementContext?.interactionMonitorId,
                   interactionMonitorId != focusedMonitorId,
                   let workspace = workspaceManager.activeWorkspaceOrFirst(on: interactionMonitorId)
                {
                    return WorkspacePlacementTarget(
                        workspaceId: workspace.id,
                        monitorId: interactionMonitorId,
                        isAuthoritative: true
                    )
                }
            }

            if let interactionMonitorId = createPlacementContext?.interactionMonitorId,
               let activeWorkspace = workspaceManager.activeWorkspace(on: interactionMonitorId),
               let focusedWorkspaceId = createPlacementContext?.focusedWorkspaceId,
               activeWorkspace.id != focusedWorkspaceId,
               (createPlacementContext?.focusedMonitorId == nil
                   || createPlacementContext?.focusedMonitorId == interactionMonitorId)
            {
                return WorkspacePlacementTarget(
                    workspaceId: activeWorkspace.id,
                    monitorId: interactionMonitorId,
                    isAuthoritative: true
                )
            }

            if let target = managedFocusPlacementTarget(
                createPlacementContext?.focusedWorkspaceId,
                createPlacementContext?.focusedMonitorId
            ) {
                return target
            }
        }

        let fallbackFrameMonitor = monitorForPlacementFrame(windowFrame)
        let fallbackFastFrameMonitor = workspaceManager.monitors.count > 1
            ? monitorForPlacementFrame(AXWindowService.framePreferFast(axRef))
            : nil
        let fallbackResolvedFrameMonitor = fallbackFrameMonitor ?? fallbackFastFrameMonitor

        if let interactionMonitorId = createPlacementContext?.interactionMonitorId,
           let frameMonitor = fallbackResolvedFrameMonitor,
           frameMonitor.id == interactionMonitorId,
           createPlacementContext?.nativeSpaceMonitorId != interactionMonitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: interactionMonitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: interactionMonitorId,
                isAuthoritative: true
            )
        }

        if let monitorId = createPlacementContext?.nativeSpaceMonitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true
            )
        }

        if let monitor = fallbackFrameMonitor,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitor.id,
                isAuthoritative: true
            )
        }

        if let monitor = fallbackFastFrameMonitor,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitor.id,
                isAuthoritative: true
            )
        }

        if !preferManagedFocusPlacement {
            if let target = managedFocusPlacementTarget(
                createPlacementContext?.activeFocusRequestWorkspaceId,
                createPlacementContext?.activeFocusRequestMonitorId
            ) {
                return target
            }

            if let target = managedFocusPlacementTarget(
                createPlacementContext?.focusedWorkspaceId,
                createPlacementContext?.focusedMonitorId
            ) {
                return target
            }
        }

        if let monitorId = createPlacementContext?.interactionMonitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true
            )
        }

        if let fallbackWorkspaceId,
           workspaceManager.descriptor(for: fallbackWorkspaceId) != nil
        {
            return WorkspacePlacementTarget(
                workspaceId: fallbackWorkspaceId,
                monitorId: workspaceManager.monitorId(for: fallbackWorkspaceId),
                isAuthoritative: false
            )
        }

        return WorkspacePlacementTarget(
            workspaceId: nil,
            monitorId: nil,
            isAuthoritative: false
        )
    }

    private func explicitWorkspaceMovePlacementTarget(pid: pid_t?, windowId: Int) -> WorkspacePlacementTarget? {
        pruneExplicitWorkspaceMoveIntents()
        guard let pid else { return nil }

        let token = WindowToken(pid: pid, windowId: windowId)
        guard let intent = explicitWorkspaceMoveIntentsByToken.removeValue(forKey: token),
              let target = workspacePlacementTarget(forExplicitMoveIntent: intent)
        else {
            return nil
        }
        return target
    }

    func hasPendingExplicitWorkspaceMoveIntent(for token: WindowToken) -> Bool {
        pruneExplicitWorkspaceMoveIntents()
        guard let intent = explicitWorkspaceMoveIntentsByToken[token] else { return false }
        return workspaceManager.descriptor(for: intent.workspaceId) != nil
    }

    private func workspacePlacementTarget(
        forExplicitMoveIntent intent: ExplicitWorkspaceMoveIntent
    ) -> WorkspacePlacementTarget? {
        guard workspaceManager.descriptor(for: intent.workspaceId) != nil else { return nil }
        return WorkspacePlacementTarget(
            workspaceId: intent.workspaceId,
            monitorId: workspaceManager.monitorId(for: intent.workspaceId),
            isAuthoritative: true
        )
    }

    private func recordExplicitWorkspaceMoveIntent(
        for token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID
    ) {
        pruneExplicitWorkspaceMoveIntents()
        let intent = ExplicitWorkspaceMoveIntent(
            token: token,
            workspaceId: workspaceId,
            createdAt: Date()
        )
        explicitWorkspaceMoveIntentsByToken[token] = intent
    }

    private func pruneExplicitWorkspaceMoveIntents(now: Date = Date()) {
        explicitWorkspaceMoveIntentsByToken = explicitWorkspaceMoveIntentsByToken.filter { _, intent in
            now.timeIntervalSince(intent.createdAt) <= explicitWorkspaceMoveIntentTTL &&
                workspaceManager.descriptor(for: intent.workspaceId) != nil
        }
    }

    func clearExplicitWorkspaceMoveIntents() {
        explicitWorkspaceMoveIntentsByToken.removeAll()
    }

    private func managedFocusPlacementTarget(
        _ workspaceId: WorkspaceDescriptor.ID?,
        _ monitorId: Monitor.ID?
    ) -> WorkspacePlacementTarget? {
        if let workspaceId,
           workspaceManager.descriptor(for: workspaceId) != nil
        {
            let resolvedMonitorId = workspaceManager.monitorId(for: workspaceId) ?? monitorId
            return WorkspacePlacementTarget(
                workspaceId: workspaceId,
                monitorId: resolvedMonitorId,
                isAuthoritative: true
            )
        }

        if let monitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true
            )
        }

        return nil
    }

    private func monitorForPlacementFrame(_ frame: CGRect?) -> Monitor? {
        guard let frame, !frame.isNull, !frame.isEmpty else { return nil }
        return frame.center.monitorApproximation(in: workspaceManager.monitors)
    }

    private func resolvedAppInfo(for pid: pid_t) -> AppInfoCache.AppInfo? {
        appInfoCache.info(for: pid) ?? NSRunningApplication(processIdentifier: pid).map {
            AppInfoCache.AppInfo(
                name: $0.localizedName,
                bundleId: $0.bundleIdentifier,
                icon: $0.icon,
                activationPolicy: $0.activationPolicy
            )
        }
    }

    private func evaluateSizeConstraints(
        for token: WindowToken,
        axRef: AXWindowRef
    ) -> WindowSizeConstraints {
        if let cached = workspaceManager.cachedConstraints(for: token) {
            return cached
        }

        let currentSize = AXWindowService.framePreferFast(axRef)?.size
            ?? axManager.lastAppliedFrame(for: token.windowId)?.size
        let resolved = AXWindowService.sizeConstraints(axRef, currentSize: currentSize)
        workspaceManager.setCachedConstraints(resolved, for: token)
        return resolved
    }

    private func decisionApplyingManualOverride(
        _ decision: WindowDecision,
        manualOverride: ManualWindowOverride?
    ) -> WindowDecision {
        guard let manualOverride else {
            return decision
        }
        if decision.disposition == .unmanaged,
           case .userRule = decision.source
        {
            return decision
        }

        return WindowDecision(
            disposition: manualOverride == .forceTile ? .managed : .floating,
            source: .manualOverride,
            layoutDecisionKind: .explicitLayout,
            workspaceName: decision.workspaceName,
            ruleEffects: decision.ruleEffects,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func liveFrame(for entry: WindowModel.Entry) -> CGRect? {
        AXWindowService.framePreferFast(entry.axRef)
            ?? axManager.lastAppliedFrame(for: entry.windowId)
            ?? (try? AXWindowService.frame(entry.axRef))
    }

    private func floatingPlacementMonitor(
        for entry: WindowModel.Entry,
        preferredMonitor: Monitor? = nil,
        frame: CGRect? = nil
    ) -> Monitor? {
        if let preferredMonitor {
            return preferredMonitor
        }
        if let interactionMonitor = monitorForInteraction() {
            return interactionMonitor
        }
        if let workspaceMonitor = workspaceManager.monitor(for: entry.workspaceId) {
            return workspaceMonitor
        }
        if let frame,
           let approximatedMonitor = frame.center.monitorApproximation(in: workspaceManager.monitors)
        {
            return approximatedMonitor
        }
        return workspaceManager.monitors.first
    }

    private func clampedFloatingFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect
    ) -> CGRect {
        let maxX = visibleFrame.maxX - frame.width
        let maxY = visibleFrame.maxY - frame.height
        let clampedX = min(max(frame.origin.x, visibleFrame.minX), max(maxX, visibleFrame.minX))
        let clampedY = min(max(frame.origin.y, visibleFrame.minY), max(maxY, visibleFrame.minY))
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: frame.size)
    }

    private func initialFloatingFrame(
        for entry: WindowModel.Entry,
        preferredMonitor: Monitor?
    ) -> CGRect? {
        guard let frame = liveFrame(for: entry) else { return nil }
        let offsetFrame = frame.offsetBy(dx: 50, dy: 50)
        guard let monitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        ) else {
            return offsetFrame
        }
        return clampedFloatingFrame(offsetFrame, in: monitor.visibleFrame)
    }

    private func targetFloatingFrame(
        for entry: WindowModel.Entry,
        preferredMonitor: Monitor?
    ) -> CGRect? {
        if let floatingState = workspaceManager.floatingState(for: entry.token),
           floatingState.restoreToFloating,
           let restoredFrame = workspaceManager.resolvedFloatingFrame(
               for: entry.token,
               preferredMonitor: preferredMonitor
           )
        {
            return restoredFrame
        }
        return initialFloatingFrame(for: entry, preferredMonitor: preferredMonitor)
    }

    private func shouldApplyFloatingFrameImmediately(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let monitor = workspaceManager.monitor(for: workspaceId) else { return false }
        return workspaceManager.activeWorkspace(on: monitor.id)?.id == workspaceId
    }

    func seedFloatingGeometryIfNeeded(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) {
        guard workspaceManager.floatingState(for: token) == nil,
              let entry = workspaceManager.entry(for: token),
              let frame = liveFrame(for: entry)
        else {
            return
        }

        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
    }

    func focusedOrFrontmostWindowTokenForAutomation(
        preferFrontmostWhenNonManagedFocusActive: Bool = false
    ) -> WindowToken? {
        let focusedToken = workspaceManager.confirmedManagedFocusToken
        let frontmostPid = commandHandler.frontmostAppPidProvider?()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostToken = commandHandler.frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { axEventHandler.focusedWindowToken(for: $0) }
        if preferFrontmostWhenNonManagedFocusActive, workspaceManager.isNonManagedFocusActive {
            return frontmostToken ?? focusedToken
        }
        return focusedToken ?? frontmostToken
    }

    private func screen(for monitorId: Monitor.ID) -> NSScreen? {
        guard let monitor = workspaceManager.monitor(byId: monitorId) else { return nil }
        return NSScreen.screens.first(where: { $0.displayId == monitor.displayId })
    }

    private func layoutSelectionCommandTarget() -> WMCommandTarget? {
        if let workspaceId = interactionWorkspace()?.id,
           let engine = niriEngine,
           let selectedNodeId = workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
           let selectedWindow = engine.findNode(by: selectedNodeId) as? NiriWindow,
           workspaceManager.entry(for: selectedWindow.token) != nil
        {
            return WMCommandTarget(
                token: selectedWindow.token,
                workspaceId: workspaceId,
                source: .layoutSelection
            )
        }

        return nil
    }

    func managedCommandTarget() -> WMCommandTarget? {
        let frontmostPid = commandHandler.frontmostAppPidProvider?()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostToken = commandHandler.frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { axEventHandler.focusedWindowToken(for: $0) }

        let frontmostTokenIsUntracked = frontmostToken.map { workspaceManager.entry(for: $0) == nil } == true
        let frontmostTokenIsSelfProcess = frontmostPid == getpid() && frontmostTokenIsUntracked

        if workspaceManager.recentlyLeftNonManagedFocus(within: 1.0) {
            if let target = managedCommandTarget(forFrontmostToken: frontmostToken),
               workspaceManager.hasStickyWindowSource(target.token)
            {
                return target
            }
            if frontmostToken != nil, !frontmostTokenIsSelfProcess {
                return nil
            }
        }

        if workspaceManager.isNonManagedFocusActive {
            let preservedManagedFocus = workspaceManager.confirmedManagedFocusToken
            if let frontmostToken,
               workspaceManager.entry(for: frontmostToken) != nil
            {
                return nil
            }
            if let frontmostPid {
                axEventHandler.handleAppActivation(
                    pid: frontmostPid,
                    source: .focusedWindowChanged,
                    origin: .probe
                )
                let resolvedFrontmostToken = commandHandler.frontmostFocusedWindowTokenProvider?()
                    ?? axEventHandler.focusedWindowToken(for: frontmostPid)
                if let target = managedCommandTarget(forFrontmostToken: resolvedFrontmostToken),
                   target.token != preservedManagedFocus || workspaceManager.hasStickyWindowSource(target.token)
                {
                    return target
                }
            }
            return nil
        }

        if let frontmostPid,
           frontmostTokenIsUntracked,
           !frontmostTokenIsSelfProcess
        {
            axEventHandler.handleAppActivation(
                pid: frontmostPid,
                source: .focusedWindowChanged,
                origin: .probe
            )
            let resolvedFrontmostToken = commandHandler.frontmostFocusedWindowTokenProvider?()
                ?? axEventHandler.focusedWindowToken(for: frontmostPid)
            if let target = managedCommandTarget(forFrontmostToken: resolvedFrontmostToken) {
                return target
            }
            if resolvedFrontmostToken != nil {
                // The frontmost app has an untracked window, but the focus layer
                // has not entered non-managed focus. Keep evaluating confirmed
                // managed focus/layout targets instead of dropping focused
                // commands on unrelated frontmost app noise (notably tests and
                // Nehir-owned UI). Stale non-managed focus is handled by the
                // `isNonManagedFocusActive` and `recentlyLeftNonManagedFocus`
                // guards above.
            }
        }

        if let token = workspaceManager.confirmedManagedFocusToken,
           let workspaceId = workspaceManager.workspace(for: token),
           let entry = workspaceManager.entry(for: token),
           entry.mode == .floating
        {
            return WMCommandTarget(
                token: token,
                workspaceId: workspaceId,
                source: .confirmedManagedFocus
            )
        }

        if let target = managedCommandTarget(forFrontmostToken: frontmostToken, requireFloating: true) {
            return target
        }

        // A concrete layout selection (the selected tiled node of the interaction
        // workspace) must win over an unfocused same-pid floating sibling. Without
        // this ordering, a visible floating window of the frontmost app shadows the
        // selected tiled window for move/focus commands — e.g. moving a PiP sibling
        // instead of the focused tiled window. A floating window that is genuinely
        // focused is still resolved first (confirmed/frontmost floating branches
        // above) before reaching this point.
        if let target = layoutSelectionCommandTarget() {
            return target
        }

        if let frontmostPid,
           let target = samePidFloatingCommandTarget(pid: frontmostPid, excluding: frontmostToken)
        {
            return target
        }

        if let token = workspaceManager.confirmedManagedFocusToken,
           let workspaceId = workspaceManager.workspace(for: token),
           workspaceManager.entry(for: token) != nil
        {
            return WMCommandTarget(
                token: token,
                workspaceId: workspaceId,
                source: .confirmedManagedFocus
            )
        }

        return managedCommandTarget(forFrontmostToken: frontmostToken)
    }

    private func managedCommandTarget(
        forFrontmostToken frontmostToken: WindowToken?,
        requireFloating: Bool = false
    ) -> WMCommandTarget? {
        guard let frontmostToken,
              let workspaceId = workspaceManager.workspace(for: frontmostToken),
              let entry = workspaceManager.entry(for: frontmostToken),
              !requireFloating || entry.mode == .floating
        else {
            return nil
        }
        return WMCommandTarget(
            token: frontmostToken,
            workspaceId: workspaceId,
            source: .frontmostManagedFallback
        )
    }

    private func samePidFloatingCommandTarget(pid: pid_t, excluding excludedToken: WindowToken?) -> WMCommandTarget? {
        let candidates = workspaceManager.entries(forPid: pid)
            .filter { entry in
                entry.token != excludedToken
                    && entry.mode == .floating
                    && entry.visibility == .visible
                    && !isNonUserAddressableNonGlobalTransientFloatingSurface(entry)
            }
            .sorted { lhs, rhs in
                if lhs.observedState.isFocused != rhs.observedState.isFocused {
                    return lhs.observedState.isFocused && !rhs.observedState.isFocused
                }
                return lhs.windowId > rhs.windowId
            }
        guard let entry = candidates.first else { return nil }
        return WMCommandTarget(
            token: entry.token,
            workspaceId: entry.workspaceId,
            source: .samePidFloatingFallback
        )
    }

    func managedCommandTargetToken() -> WindowToken? {
        managedCommandTarget()?.token
    }

    func managedLayoutCommandTargetToken() -> WindowToken? {
        layoutSelectionCommandTarget()?.token ?? managedCommandTargetToken()
    }

    private func focusedManagedTokenForCommand() -> WindowToken? {
        managedCommandTargetToken()
    }

    @discardableResult
    private func captureVisibleFloatingGeometry(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> CGRect? {
        guard !workspaceManager.isHiddenInCorner(token),
              let entry = workspaceManager.entry(for: token),
              let frame = liveFrame(for: entry)
        else {
            return nil
        }

        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
        return frame
    }

    @discardableResult
    private func prepareWindowForScratchpadAssignment(
        _ token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }

        if entry.mode == .floating {
            guard captureVisibleFloatingGeometry(for: token, preferredMonitor: preferredMonitor) != nil
                || workspaceManager.floatingState(for: token) != nil
            else {
                return false
            }
            if workspaceManager.manualLayoutOverride(for: token) != .forceFloat {
                workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
            }
            return true
        }

        guard let frame = liveFrame(for: entry) else { return false }
        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        _ = workspaceManager.setWindowMode(.floating, for: token)
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
        if workspaceManager.manualLayoutOverride(for: token) != .forceFloat {
            workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
        }
        return true
    }

    private func scratchpadTarget(on monitorId: Monitor
        .ID? = nil) -> (workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)?
    {
        guard let monitor = monitorId.flatMap({ workspaceManager.monitor(byId: $0) }) ?? monitorForInteraction(),
              let workspaceId = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            return nil
        }
        return (workspaceId, monitor)
    }

    private func visibleFocusRecoveryToken(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding excludedToken: WindowToken
    ) -> WindowToken? {
        let explicitCandidates = [
            workspaceManager.rememberedTiledFocusToken(in: workspaceId),
            workspaceManager.preferredWorkspaceFocusToken(in: workspaceId),
            workspaceManager.lastFloatingFocusedToken(in: workspaceId),
            workspaceManager.confirmedManagedFocusToken
        ]

        for candidate in explicitCandidates {
            guard let candidate,
                  candidate != excludedToken,
                  let entry = workspaceManager.entry(for: candidate),
                  entry.workspaceId == workspaceId,
                  isManagedWindowDisplayable(entry.handle)
            else {
                continue
            }
            return candidate
        }

        if let tiledEntry = workspaceManager.tiledEntries(in: workspaceId).first(where: {
            $0.token != excludedToken && isManagedWindowDisplayable($0.handle)
        }) {
            return tiledEntry.token
        }

        return workspaceManager.floatingEntries(in: workspaceId).first(where: {
            $0.token != excludedToken && isManagedWindowDisplayable($0.handle)
        })?.token
    }

    private func recoverFocusAfterScratchpadHide(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding token: WindowToken,
        on monitorId: Monitor.ID?
    ) {
        if let nextFocusToken = visibleFocusRecoveryToken(in: workspaceId, excluding: token) {
            focusWindow(nextFocusToken)
            return
        }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId)
        if workspaceManager.confirmedManagedFocusToken == nil {
            focusBorderController.hide()
        }
    }

    func cleanupScratchpadWindowResources(for token: WindowToken) {
        layoutRefreshController.cancelPendingScratchpadReveal(for: token)
        let frameEntry = [(pid: token.pid, windowId: token.windowId)]
        axManager.cancelPendingFrameJobs(frameEntry)
        axManager.unsuppressFrameWrites(frameEntry)
        AXWindowService.unpinAXElement(for: UInt32(token.windowId))
        _ = workspaceManager.clearScratchpadIfMatches(token)
    }

    func cleanupScratchpadWindowResourcesIfNeeded(for token: WindowToken) {
        guard workspaceManager.isScratchpadToken(token)
            || workspaceManager.hiddenState(for: token)?.isScratchpad == true
        else {
            return
        }
        cleanupScratchpadWindowResources(for: token)
    }

    func rekeyScratchpadWindowResources(from oldToken: WindowToken, to newToken: WindowToken, axRef: AXWindowRef) {
        guard workspaceManager.hiddenState(for: newToken)?.isScratchpad == true else { return }
        AXWindowService.unpinAXElement(for: UInt32(oldToken.windowId))
        AXWindowService.pinAXElement(axRef.element, for: UInt32(newToken.windowId))
    }

    private func hideScratchpadWindow(
        _ entry: WindowModel.Entry,
        monitor: Monitor
    ) {
        // Hold an AX reference before hiding so reveal can still resolve windows
        // whose apps drop them from kAXWindowsAttribute while off-screen
        // (Calculator, some AppKit panels). axWindowRef enumeration would
        // otherwise return nil and the reveal frame write would silently skip.
        if let ref = AXWindowService.axWindowRef(for: UInt32(entry.windowId), pid: entry.pid) {
            AXWindowService.pinAXElement(ref.element, for: UInt32(entry.windowId))
        }

        let preferredSide = layoutRefreshController.preferredHideSide(for: monitor)
        layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: preferredSide,
            reason: .scratchpad
        )
        recoverFocusAfterScratchpadHide(
            in: entry.workspaceId,
            excluding: entry.token,
            on: monitor.id
        )
    }

    @discardableResult
    private func showScratchpadWindow(
        _ entry: WindowModel.Entry,
        on workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) -> Bool {
        if entry.workspaceId != workspaceId {
            reassignManagedWindow(entry.token, to: workspaceId, explicitMoveIntent: false)
        }
        axManager.markWindowActive(entry.windowId)

        if let hiddenState = workspaceManager.hiddenState(for: entry.token) {
            let focusOnRevealSuccess: LayoutRefreshController.PostLayoutAction = { [weak self] in
                self?.focusWindow(entry.token)
            }
            if hiddenState.isScratchpad {
                return layoutRefreshController.restoreScratchpadWindow(
                    entry,
                    monitor: monitor,
                    onSuccess: focusOnRevealSuccess
                )
            } else {
                return layoutRefreshController.unhideWindow(
                    entry,
                    monitor: monitor,
                    onSuccess: focusOnRevealSuccess
                )
            }
        }

        if let frame = workspaceManager.resolvedFloatingFrame(
            for: entry.token,
            preferredMonitor: monitor
        ) {
            axManager.forceApplyNextFrame(for: entry.windowId)
            axManager.applyFramesParallel([(entry.pid, entry.windowId, frame)])
        }

        focusWindow(entry.token)
        return true
    }

    @discardableResult
    func transitionWindowMode(
        for token: WindowToken,
        to targetMode: TrackedWindowMode,
        preferredMonitor: Monitor? = nil,
        applyFloatingFrame: Bool? = nil
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }
        let currentMode = entry.mode
        guard currentMode != targetMode else { return false }

        let currentFrame = liveFrame(for: entry)
        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: currentFrame
        )

        switch (currentMode, targetMode) {
        case (.tiling, .floating):
            let targetFrame = targetFloatingFrame(
                for: entry,
                preferredMonitor: referenceMonitor
            )
            _ = workspaceManager.setWindowMode(.floating, for: token)
            if let targetFrame {
                workspaceManager.updateFloatingGeometry(
                    frame: targetFrame,
                    for: token,
                    referenceMonitor: referenceMonitor,
                    restoreToFloating: true
                )
                if applyFloatingFrame ?? shouldApplyFloatingFrameImmediately(for: entry.workspaceId) {
                    axManager.forceApplyNextFrame(for: entry.windowId)
                    axManager.applyFramesParallel([(entry.pid, entry.windowId, targetFrame)])
                    _ = focusBorderController.updateFrameHint(for: token, frame: targetFrame)
                }
            }
            return true

        case (.floating, .tiling):
            if let currentFrame {
                workspaceManager.updateFloatingGeometry(
                    frame: currentFrame,
                    for: token,
                    referenceMonitor: referenceMonitor,
                    restoreToFloating: true
                )
            } else if var floatingState = workspaceManager.floatingState(for: token) {
                floatingState.restoreToFloating = true
                workspaceManager.setFloatingState(floatingState, for: token)
            }
            _ = workspaceManager.setWindowMode(.tiling, for: token)
            return true

        case (.tiling, .tiling),
             (.floating, .floating):
            return false
        }
    }

    func trackedModeForLifecycle(
        decision: WindowDecision,
        existingEntry: WindowModel.Entry?
    ) -> TrackedWindowMode? {
        if let trackedMode = decision.trackedMode {
            return trackedMode
        }
        if decision.disposition == .undecided {
            return existingEntry?.mode
        }
        return nil
    }

    func trackedModePreservingAutomaticFallbackState(
        decision: WindowDecision,
        existingEntry: WindowModel.Entry?,
        context: WindowRuleReevaluationContext
    ) -> TrackedWindowMode? {
        if context == .automatic,
           let existingEntry,
           decision.disposition == .unmanaged,
           case .builtInRule("transientSystemDialogSurface") = decision.source,
           existingEntry.mode == .floating,
           existingEntry.managedReplacementMetadata?.transientWindowServerEvidence == true
        {
            return .floating
        }

        guard let trackedMode = trackedModeForLifecycle(
            decision: decision,
            existingEntry: existingEntry
        ) else {
            return nil
        }

        guard context == .automatic,
              let existingEntry,
              decision.layoutDecisionKind == .fallbackLayout
        else {
            return trackedMode
        }

        if workspaceManager.isStickyWindow(existingEntry.token) {
            return .floating
        }

        if existingEntry.mode == .floating,
           trackedMode == .tiling,
           existingEntry.managedReplacementMetadata?.transientWindowServerEvidence == true
        {
            return .floating
        }

        if existingEntry.mode == .tiling,
           trackedMode == .floating
        {
            return .tiling
        }

        return trackedMode
    }

    func resolvedWorkspaceId(
        for evaluation: WindowDecisionEvaluation,
        axRef: AXWindowRef,
        existingEntry: WindowModel.Entry?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID? = nil,
        restrictWorkspaceRuleToPlacementMonitor: Bool = true,
        createPlacementContext: WindowCreatePlacementContext? = nil,
        context: WindowRuleReevaluationContext = .automatic
    ) -> WorkspaceDescriptor.ID {
        let inheritTrackedParentWorkspace = shouldInheritTrackedParentWorkspace(for: evaluation)
        let bindTransientFloatingToAppWorkspace =
            evaluation.decision.disposition == .floating
                && evaluation.facts.windowServer?.hasTransientSurfaceEvidence == true
                && !evaluation.facts.userAddressableTransientWindowServerSurface
        return resolveWorkspacePlacement(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: evaluation.token.pid,
            parentWindowId: evaluation.facts.windowServer?.parentId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            preferSameAppSiblingWorkspace: shouldPreferSameAppSiblingWorkspace(
                for: evaluation,
                inheritTrackedParentWorkspace: inheritTrackedParentWorkspace
            ),
            bindTransientFloatingToAppWorkspace: bindTransientFloatingToAppWorkspace,
            structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
            restrictWorkspaceRuleToPlacementMonitor: restrictWorkspaceRuleToPlacementMonitor,
            createPlacementContext: createPlacementContext,
            windowFrame: evaluation.facts.windowServer?.frame,
            existingEntry: existingEntry,
            fallbackWorkspaceId: fallbackWorkspaceId,
            context: context
        )
    }

    func evaluateWindowDisposition(
        axRef: AXWindowRef,
        pid: pid_t,
        appFullscreen: Bool? = nil,
        applyingManualOverride: Bool = true,
        windowInfo: WindowServerInfo? = nil,
        traceContext: String? = nil,
        existingModeForTrace: TrackedWindowMode? = nil
    ) -> WindowDecisionEvaluation {
        let token = WindowToken(pid: pid, windowId: axRef.windowId)
        let sizeConstraints = evaluateSizeConstraints(for: token, axRef: axRef)
        let appInfo = resolvedAppInfo(for: pid)
        let baseFacts = axEventHandler.windowFactsProvider?(axRef, pid) ?? WindowRuleFacts(
            appName: appInfo?.name,
            ax: AXWindowService.collectWindowFacts(
                axRef,
                appPolicy: appInfo?.activationPolicy,
                bundleId: appInfo?.bundleId,
                includeTitle: windowRuleEngine.requiresTitle(for: appInfo?.bundleId)
            ),
            sizeConstraints: sizeConstraints,
            windowServer: nil
        )
        let resolvedWindowInfo = baseFacts.windowServer ?? resolveWindowServerInfoForDisposition(
            token: token,
            bundleId: baseFacts.ax.bundleId ?? appInfo?.bundleId,
            preferredWindowInfo: windowInfo
        )
        let facts = WindowRuleFacts(
            appName: baseFacts.appName,
            ax: baseFacts.ax,
            sizeConstraints: baseFacts.sizeConstraints,
            windowServer: resolvedWindowInfo
        )
        let fullscreen = appFullscreen ??
            (axEventHandler.isFullscreenProvider?(axRef) ?? AXWindowService.isFullscreen(axRef))
        let manualOverride = workspaceManager.manualLayoutOverride(for: token)
        let baseDecision = windowRuleEngine.decision(
            for: facts,
            token: token,
            appFullscreen: fullscreen
        )
        let decision = applyingManualOverride
            ? decisionApplyingManualOverride(baseDecision, manualOverride: manualOverride)
            : baseDecision
        let evaluation = WindowDecisionEvaluation(
            token: token,
            facts: facts,
            decision: decision,
            appFullscreen: fullscreen,
            manualOverride: manualOverride
        )
        if let traceContext {
            diagnostics.recordWindowDecisionTrace(
                evaluation,
                context: traceContext,
                existingMode: existingModeForTrace
            )
        }
        return evaluation
    }

    private func resolveWindowServerInfoForDisposition(
        token: WindowToken,
        bundleId: String?,
        preferredWindowInfo: WindowServerInfo?
    ) -> WindowServerInfo? {
        if let preferredWindowInfo {
            return preferredWindowInfo
        }

        guard let windowId = UInt32(exactly: token.windowId) else {
            return nil
        }

        return axEventHandler.windowInfoProvider?(windowId) ?? SkyLight.shared.queryWindowInfo(windowId)
    }

    func decideWindowDisposition(
        axRef: AXWindowRef,
        pid: pid_t,
        appFullscreen: Bool? = nil
    ) -> WindowDecision {
        evaluateWindowDisposition(
            axRef: axRef,
            pid: pid,
            appFullscreen: appFullscreen
        ).decision
    }

    static func visibleUnmanagedWindowServerFrames(
        trackedWindowIds: Set<Int> = []
    ) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windows.compactMap { info -> CGRect? in
            let windowId = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            guard let windowId, !trackedWindowIds.contains(Int(windowId)) else { return nil }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { return nil }

            let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            guard isOnscreen else { return nil }

            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 80,
                  height >= 80
            else { return nil }

            return ScreenCoordinateSpace.toAppKit(
                rect: CGRect(x: x, y: y, width: width, height: height)
            )
        }
    }

    func unmanagedWindowServerWindowCovers(
        point: CGPoint,
        windowUnderPointer: Int? = nil,
        allowWindowServerSnapshotFallback: Bool = true
    ) -> Bool {
        let trackedWindowIds = Set(workspaceManager.trackedWindowIdsForDebug())
        if let windowUnderPointer, windowUnderPointer > 0 {
            return isUnmanagedWindowServerWindow(
                windowId: windowUnderPointer,
                trackedWindowIds: trackedWindowIds
            )
        }

        guard allowWindowServerSnapshotFallback else { return false }
        return unmanagedWindowServerWindowFramesProvider(trackedWindowIds).contains { $0.contains(point) }
    }

    /// Focus-follows-mouse occlusion variant that excludes click-through
    /// decorative overlays on the snapshot-fallback branch.
    ///
    /// `unmanagedWindowServerWindowCovers` treats any on-screen, layer-0,
    /// ≥80 px, unmanaged window frame as an occluder. That is correct for
    /// interactive overlays (e.g. the Ghostty Quick terminal) but wrong for a
    /// decorative click-through overlay such as the JankyBorders app: it is
    /// purely visual and never receives clicks, so FFM should fire on the
    /// managed tile beneath. JankyBorders creates its windows via private SLS
    /// APIs (no `ignoresMouseEvents`, empty opaque-shape region) and neither
    /// the CGEvent window-under-pointer fields (empty for these mouse-moved
    /// events — verified) nor the `CGWindowList` snapshot can flag it as
    /// click-through. The conservative discriminator is: only a faceless owner
    /// whose WindowServer owner name matches a known decorative border utility
    /// (e.g. `borders` / JankyBorders) is excluded (#64). Unknown faceless
    /// owners remain occluding, preserving Ghostty Quick terminal suppression.
    /// The number fast-path is unchanged.
    func unmanagedInteractiveWindowServerWindowCovers(
        point: CGPoint,
        windowUnderPointer: Int? = nil,
        allowWindowServerSnapshotFallback: Bool = true
    ) -> Bool {
        let trackedWindowIds = Set(workspaceManager.trackedWindowIdsForDebug())
        if let windowUnderPointer, windowUnderPointer > 0 {
            return isUnmanagedWindowServerWindow(
                windowId: windowUnderPointer,
                trackedWindowIds: trackedWindowIds
            )
        }

        guard allowWindowServerSnapshotFallback else { return false }
        // Single source of truth: the injectable window-info provider (the live
        // `CGWindowList` snapshot in production; a stub in tests). Filtering for
        // an interactive unmanaged overlay that covers `point` — excluding
        // click-through decorative overlays owned by a faceless process (#64).
        return Self.visibleUnmanagedInteractiveWindowServerWindowCovers(
            point: point,
            trackedWindowIds: trackedWindowIds,
            windows: unmanagedOverlayWindowInfoProvider(),
            isOwnedWindowNumber: { [ownedWindowRegistry] windowNumber in
                ownedWindowRegistry.contains(windowNumber: windowNumber)
            },
            ownerAppIsInteractiveApplication: { [weak self] pid in
                self?.ownerAppIsInteractiveApplicationProvider(pid) ?? true
            }
        )
    }

    static func visibleUnmanagedInteractiveWindowServerWindowCovers(
        point: CGPoint,
        trackedWindowIds: Set<Int> = [],
        windows providedWindows: [[String: Any]]? = nil,
        isOwnedWindowNumber: @MainActor (Int) -> Bool = { _ in false },
        ownerAppIsInteractiveApplication: @MainActor (pid_t) -> Bool = { _ in true }
    ) -> Bool {
        let windows: [[String: Any]]
        if let providedWindows {
            windows = providedWindows
        } else {
            windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        }

        for info in windows {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            // FFM snapshot fallback must catch interactive overlays above the
            // normal app layer too (e.g. Ghostty Quick terminal). Decorative
            // JankyBorders windows are filtered later by owner name.
            guard layer >= 0 else { continue }

            let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            guard isOnscreen else { continue }

            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 80,
                  height >= 80
            else { continue }

            let frame = ScreenCoordinateSpace.toAppKit(
                rect: CGRect(x: x, y: y, width: width, height: height)
            )
            guard frame.contains(point) else { continue }

            let windowId = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
            guard windowId > 0 else { continue }
            if isOwnedWindowNumber(windowId) { continue }
            if trackedWindowIds.contains(windowId) { continue }

            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let ownerName = info[kCGWindowOwnerName as String] as? String
            // Only a known decorative border utility gets the faceless-process
            // exemption. Ghostty's Quick terminal can also appear faceless on
            // the snapshot path, but it is interactive and must still occlude.
            if pid > 0,
               !ownerAppIsInteractiveApplication(pid),
               isDecorativeBorderOverlayOwner(ownerName)
            {
                continue
            }

            return true
        }

        return false
    }

    private static func isDecorativeBorderOverlayOwner(_ ownerName: String?) -> Bool {
        guard let ownerName else { return false }
        let normalized = ownerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "borders" || normalized == "jankyborders" || normalized == "janky borders"
    }

    private func isUnmanagedWindowServerWindow(windowId: Int, trackedWindowIds: Set<Int>) -> Bool {
        guard !trackedWindowIds.contains(windowId) else { return false }
        guard !ownedWindowRegistry.contains(windowNumber: windowId) else { return false }
        return true
    }

    func unmanagedOverlayWindowServerWindowCovers(point: CGPoint) -> Bool {
        if let unmanagedOverlayWindowServerWindowCoversOverride {
            return unmanagedOverlayWindowServerWindowCoversOverride(point)
        }

        let trackedWindowIds = Set(workspaceManager.trackedWindowIdsForDebug())
        return Self.visibleUnmanagedOverlayWindowServerWindowCovers(
            point: point,
            trackedWindowIds: trackedWindowIds,
            isOwnedWindowNumber: { [ownedWindowRegistry] windowNumber in
                ownedWindowRegistry.contains(windowNumber: windowNumber)
            }
        )
    }

    static func visibleUnmanagedOverlayWindowServerWindowCovers(
        point: CGPoint,
        trackedWindowIds: Set<Int> = [],
        windows providedWindows: [[String: Any]]? = nil,
        isOwnedWindowNumber: @MainActor (Int) -> Bool = { _ in false },
        ownerActivationPolicyProvider: (pid_t) -> NSApplication.ActivationPolicy? = {
            NSRunningApplication(processIdentifier: $0)?.activationPolicy
        }
    ) -> Bool {
        let windows: [[String: Any]]
        if let providedWindows {
            windows = providedWindows
        } else {
            windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        }

        for info in windows {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer >= 0 else { continue }

            let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            guard isOnscreen else { continue }

            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 80,
                  height >= 80
            else { continue }

            let frame = ScreenCoordinateSpace.toAppKit(
                rect: CGRect(x: x, y: y, width: width, height: height)
            )
            guard frame.contains(point) else { continue }

            let windowId = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
            guard windowId > 0 else { continue }
            if isOwnedWindowNumber(windowId) { continue }
            if trackedWindowIds.contains(windowId) { return false }

            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if pid > 0,
               let activationPolicy = ownerActivationPolicyProvider(pid),
               activationPolicy != .regular
            {
                continue
            }

            return true
        }

        return false
    }

    func clearManualWindowOverride(for token: WindowToken) {
        workspaceManager.setManualLayoutOverride(nil, for: token)
    }

    private func resolveAXWindowRef(for token: WindowToken) -> AXWindowRef? {
        workspaceManager.entry(for: token)?.axRef
            ?? axEventHandler.axWindowRefProvider?(UInt32(token.windowId), token.pid)
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
    }

    func relaunchCurrentApplication(extraArguments: [String] = []) -> Bool {
        let executablePath = (Bundle.main.executableURL?.path).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.arguments.first
        guard let executablePath else { return false }

        var allArguments = ProcessInfo.processInfo.arguments.dropFirst()
            .filter { $0 != Self.traceLaunchArgument }
        allArguments.append(contentsOf: extraArguments)
        let quotedArguments = allArguments.map(Self.shellQuote).joined(separator: " ")
        let command = quotedArguments.isEmpty
            ? "sleep 0.5; \(Self.shellQuote(executablePath)) >/dev/null 2>&1 &"
            : "sleep 0.5; \(Self.shellQuote(executablePath)) \(quotedArguments) >/dev/null 2>&1 &"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        do {
            try process.run()
            return true
        } catch {
            Self.runtimeDebugLogger
                .error("Failed to spawn relaunch helper: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static let traceLaunchArgument = "--nehir-trace"

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    func reevaluateWindowRules(
        for targets: Set<WindowRuleReevaluationTarget>,
        context: WindowRuleReevaluationContext = .automatic
    ) async -> WindowRuleReevaluationOutcome {
        guard !targets.isEmpty else { return .none }

        var liveWindowsByToken: [WindowToken: AXWindowRef] = [:]
        var tokensToReevaluate: Set<WindowToken> = []
        var pidTargets: Set<pid_t> = []
        var resolvedAnyTarget = false
        // Diagnostic only: tracks which tokens reached this reevaluation via a
        // `.pid` target (a whole-pid AX re-query) vs a `.window` target (a
        // single-token reevaluation), so the resulting `windowAdmitted` event
        // can be tagged with an accurate admission context.
        var tokensFromPidTarget: Set<WindowToken> = []

        for target in targets {
            switch target {
            case let .window(token):
                let existingEntry = workspaceManager.entry(for: token)
                if let axRef = resolveAXWindowRef(for: token) {
                    resolvedAnyTarget = true
                    tokensToReevaluate.insert(token)
                    liveWindowsByToken[token] = axRef
                } else if existingEntry != nil {
                    resolvedAnyTarget = true
                    tokensToReevaluate.insert(token)
                }
            case let .pid(pid):
                pidTargets.insert(pid)
            }
        }

        for pid in pidTargets {
            let managedEntries = workspaceManager.entries(forPid: pid)
            if !managedEntries.isEmpty {
                resolvedAnyTarget = true
            }
            if let app = NSRunningApplication(processIdentifier: pid) {
                let windows = await axManager.windowsForApp(app)
                if !windows.isEmpty {
                    resolvedAnyTarget = true
                }
                for (axRef, _, windowId) in windows {
                    let token = WindowToken(pid: pid, windowId: windowId)
                    tokensToReevaluate.insert(token)
                    liveWindowsByToken[token] = axRef
                    tokensFromPidTarget.insert(token)
                }
            }

            for entry in managedEntries {
                tokensToReevaluate.insert(entry.token)
                tokensFromPidTarget.insert(entry.token)
            }
        }

        guard !tokensToReevaluate.isEmpty else {
            return WindowRuleReevaluationOutcome(
                resolvedAnyTarget: resolvedAnyTarget,
                evaluatedAnyWindow: false,
                relayoutNeeded: false
            )
        }

        var relayoutNeeded = false
        var evaluatedAnyWindow = false
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        // See the matching comment in LayoutRefreshController's full-rescan
        // loop: tokens admitted earlier in this reevaluation pass must not be
        // eligible structural-replacement match targets for later candidates
        // in the same pass (e.g. a `.pid` target's fresh AX query returning
        // several distinct, never-before-tracked windows at once).
        var structuralReplacementAdmittedThisPass: Set<WindowToken> = []

        for token in tokensToReevaluate.sorted(by: {
            if $0.pid == $1.pid {
                return $0.windowId < $1.windowId
            }
            return $0.pid < $1.pid
        }) {
            let existingEntry = workspaceManager.entry(for: token)
            let axRef = liveWindowsByToken[token] ?? existingEntry?.axRef
            guard let axRef else { continue }
            let createPlacementContext = existingEntry == nil
                ? axEventHandler.pendingCreatePlacementContext(for: token.windowId)
                : nil

            evaluatedAnyWindow = true
            let evaluation = evaluateWindowDisposition(
                axRef: axRef,
                pid: token.pid,
                traceContext: "reevaluate:\(String(describing: context))",
                existingModeForTrace: existingEntry?.mode
            )

            guard let effectiveTrackedMode = trackedModePreservingAutomaticFallbackState(
                decision: evaluation.decision,
                existingEntry: existingEntry,
                context: context
            ) else {
                if let existingEntry {
                    affectedWorkspaceIds.insert(existingEntry.workspaceId)
                    cleanupScratchpadWindowResourcesIfNeeded(for: token)
                    nativeFullscreenPlaceholderManager.remove(token)
                    _ = workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
                    relayoutNeeded = true
                } else if evaluation.decision.disposition != .undecided {
                    axEventHandler.discardCreatePlacementContext(for: token.windowId)
                }
                continue
            }

            let oldEffects = existingEntry?.ruleEffects ?? .none
            let effectiveRuleEffects = ruleEffectsPreservingExistingAutomaticStickySource(
                evaluation.decision.ruleEffects,
                existingEntry: existingEntry,
                facts: evaluation.facts
            )
            let oldMode = existingEntry?.mode
            let oldWorkspaceId = existingEntry?.workspaceId
            let hasExplicitWorkspaceAssignment = workspaceAssignment(pid: token.pid, windowId: token.windowId) != nil
                || hasPendingExplicitWorkspaceMoveIntent(for: token)
            if existingEntry == nil,
               axEventHandler.shouldSuppressUnrequestedAdmissionDuringNonManagedFocus(
                   token: token,
                   createPlacementContext: createPlacementContext,
                   hasExplicitWorkspaceAssignment: hasExplicitWorkspaceAssignment
               )
            {
                axEventHandler.discardCreatePlacementContext(for: token.windowId)
                continue
            }

            let structuralReplacementWorkspaceId = existingEntry == nil
                ? axEventHandler.structuralReplacementWorkspaceIdForCreate(
                    token: token,
                    bundleId: evaluation.facts.ax.bundleId,
                    mode: effectiveTrackedMode,
                    facts: evaluation.facts,
                    admittedThisPass: structuralReplacementAdmittedThisPass
                )
                : nil
            let workspaceId = resolvedWorkspaceId(
                for: evaluation,
                axRef: axRef,
                existingEntry: existingEntry,
                fallbackWorkspaceId: interactionWorkspace()?.id,
                structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
                restrictWorkspaceRuleToPlacementMonitor: effectiveTrackedMode != .floating,
                createPlacementContext: createPlacementContext,
                context: context
            )

            if existingEntry == nil,
               let windowId = UInt32(exactly: token.windowId),
               axEventHandler.rekeyStructuralManagedReplacementIfNeeded(
                   token: token,
                   windowId: windowId,
                   axRef: axRef,
                   bundleId: evaluation.facts.ax.bundleId,
                   mode: effectiveTrackedMode,
                   facts: evaluation.facts,
                   admittedThisPass: structuralReplacementAdmittedThisPass
               )
            {
                structuralReplacementAdmittedThisPass.insert(token)
                affectedWorkspaceIds.insert(workspaceId)
                relayoutNeeded = true
                continue
            }

            if existingEntry == nil {
                structuralReplacementAdmittedThisPass.insert(token)
            }

            _ = workspaceManager.addWindow(
                axRef,
                pid: token.pid,
                windowId: token.windowId,
                to: workspaceId,
                mode: oldMode ?? effectiveTrackedMode,
                ruleEffects: effectiveRuleEffects,
                admissionContext: tokensFromPidTarget.contains(token) ? .pidReevaluation : .windowRuleReevaluation
            )
            if existingEntry == nil {
                axEventHandler.discardCreatePlacementContext(for: token.windowId)
            }

            if let oldMode, oldMode != effectiveTrackedMode {
                _ = transitionWindowMode(
                    for: token,
                    to: effectiveTrackedMode,
                    preferredMonitor: workspaceManager.monitor(for: workspaceId)
                )
            } else if effectiveTrackedMode == .floating {
                seedFloatingGeometryIfNeeded(
                    for: token,
                    preferredMonitor: workspaceManager.monitor(for: workspaceId)
                )
            }

            if let updatedEntry = workspaceManager.entry(for: token) {
                let parentWindowId = if let windowServer = evaluation.facts.windowServer {
                    windowServer.parentId == 0 ? nil : windowServer.parentId
                } else {
                    updatedEntry.managedReplacementMetadata?.parentWindowId
                }
                let transientFlags = mergedManagedReplacementTransientFlags(
                    existingMetadata: updatedEntry.managedReplacementMetadata,
                    facts: evaluation.facts
                )
                _ = workspaceManager.setManagedReplacementMetadata(
                    ManagedReplacementMetadata(
                        bundleId: evaluation.facts.ax.bundleId ?? updatedEntry.managedReplacementMetadata?.bundleId,
                        workspaceId: updatedEntry.workspaceId,
                        mode: updatedEntry.mode,
                        role: evaluation.facts.ax.role ?? updatedEntry.managedReplacementMetadata?.role,
                        subrole: evaluation.facts.ax.subrole ?? updatedEntry.managedReplacementMetadata?.subrole,
                        title: evaluation.facts.ax.title ?? updatedEntry.managedReplacementMetadata?.title,
                        windowLevel: evaluation.facts.windowServer?.level ?? updatedEntry.managedReplacementMetadata?
                            .windowLevel,
                        parentWindowId: parentWindowId,
                        frame: evaluation.facts.windowServer?.frame ?? updatedEntry.managedReplacementMetadata?.frame,
                        transientWindowServerEvidence: transientFlags.transientWindowServerEvidence,
                        degradedWindowServerChildEvidence: transientFlags.degradedWindowServerChildEvidence,
                        userAddressableTransientWindowServerSurface: transientFlags
                            .userAddressableTransientWindowServerSurface
                    ),
                    for: token
                )
            }

            if existingEntry == nil
                || oldEffects != effectiveRuleEffects
                || oldWorkspaceId != workspaceId
                || oldMode != effectiveTrackedMode
            {
                if let oldWorkspaceId {
                    affectedWorkspaceIds.insert(oldWorkspaceId)
                }
                affectedWorkspaceIds.insert(workspaceId)
                relayoutNeeded = true
            }
        }

        if relayoutNeeded {
            layoutRefreshController.requestRefresh(
                reason: .windowRuleReevaluation,
                affectedWorkspaceIds: affectedWorkspaceIds
            )
        }

        return WindowRuleReevaluationOutcome(
            resolvedAnyTarget: resolvedAnyTarget,
            evaluatedAnyWindow: evaluatedAnyWindow,
            relayoutNeeded: relayoutNeeded
        )
    }

    /// Token-parameterized toggle of floating/tiling for an explicit window,
    /// independent of focus. Backs the workspace bar's right-click *Toggle
    /// Floating* item. The focused wrapper below delegates here.
    func toggleWindowFloating(token: WindowToken) -> ExternalCommandResult {
        guard let entry = workspaceManager.entry(for: token) else {
            return .notFound
        }

        // A non-user-addressable transient, non-global-sticky floating surface (e.g.
        // a Teams/Zoom call mini-window) is app-managed ephemeral UI the owning app
        // destroys and recreates at will. It is hidden from the workspace bar for the
        // same reason, so it must not be force-tiled via the toggle command either —
        // treat it as not a valid command target. User-addressable transient call
        // windows and genuinely global PiP windows remain toggleable.
        if isNonUserAddressableNonGlobalTransientFloatingSurface(entry) {
            return .notFound
        }

        let currentOverride = workspaceManager.manualLayoutOverride(for: token)
        let metadata = entry.managedReplacementMetadata
        let isStandardSurface = metadata == nil
            || (metadata?.role == kAXWindowRole as String
                && (metadata?.subrole == nil || metadata?.subrole == kAXStandardWindowSubrole as String))
        let togglesExplicitTransientState = workspaceManager.isManualUnstickyWindow(token) || !isStandardSurface
        let nextOverride: ManualWindowOverride?
        if currentOverride == .forceTile, entry.mode == .tiling, togglesExplicitTransientState {
            nextOverride = .forceFloat
        } else if currentOverride == .forceFloat, entry.mode == .floating, togglesExplicitTransientState {
            nextOverride = .forceTile
        } else if currentOverride != nil {
            nextOverride = nil
        } else {
            nextOverride = entry.mode == .tiling ? .forceFloat : .forceTile
        }

        if nextOverride == .forceTile, workspaceManager.isStickyWindow(token) {
            _ = workspaceManager.setManualStickyWindow(false, for: token)
            _ = workspaceManager.setStickyFloatingPromotion(false, for: token)
        }

        applyManagedWindowOverride(nextOverride, for: token, entry: entry)
        return .executed
    }

    func toggleFocusedWindowFloating() -> ExternalCommandResult {
        guard let token = focusedManagedTokenForCommand() else {
            return .notFound
        }
        return toggleWindowFloating(token: token)
    }

    @discardableResult
    func toggleWindowSticky(token: WindowToken) -> ExternalCommandResult {
        guard let entry = workspaceManager.entry(for: token),
              !isManagedWindowSuspendedForNativeFullscreen(token),
              !isNonUserAddressableNonGlobalTransientFloatingSurface(entry)
        else {
            return .notFound
        }

        let shouldStick = !workspaceManager.isStickyWindow(token)
        let manualOverride = workspaceManager.manualLayoutOverride(for: token)
        let wasManualSticky = workspaceManager.isManualStickyWindow(token)
        let wasStickyPromotion = workspaceManager.isStickyFloatingPromotion(token)
        _ = workspaceManager.setManualStickyWindow(shouldStick, for: token)

        if shouldStick {
            if manualOverride == .forceTile {
                workspaceManager.setManualLayoutOverride(nil, for: token)
            }
            if entry.mode == .tiling {
                _ = workspaceManager.setStickyFloatingPromotion(true, for: token)
                _ = transitionWindowMode(
                    for: token,
                    to: .floating,
                    preferredMonitor: monitorForInteraction(),
                    applyFloatingFrame: true
                )
            }
            layoutRefreshController.requestRefresh(reason: .layoutCommand)
        } else {
            _ = workspaceManager.setStickyFloatingPromotion(false, for: token)
            let shouldRestoreTiling = wasStickyPromotion || (wasManualSticky && manualOverride == .forceFloat)
            if shouldRestoreTiling {
                let updatedEntry = workspaceManager.entry(for: token) ?? entry
                if manualOverride == .forceFloat {
                    workspaceManager.setManualLayoutOverride(nil, for: token)
                }
                _ = transitionWindowMode(
                    for: token,
                    to: .tiling,
                    preferredMonitor: monitorForInteraction(),
                    applyFloatingFrame: true
                )
                layoutRefreshController.requestRefresh(
                    reason: .layoutCommand,
                    affectedWorkspaceIds: [updatedEntry.workspaceId]
                )
            } else {
                if manualOverride == .forceFloat, entry.ruleEffects.sticky == true {
                    workspaceManager.setManualLayoutOverride(nil, for: token)
                }
                layoutRefreshController.requestRefresh(reason: .layoutCommand)
            }
        }
        return .executed
    }

    func toggleFocusedWindowSticky() -> ExternalCommandResult {
        guard let token = focusedManagedTokenForCommand() else {
            return .notFound
        }
        return toggleWindowSticky(token: token)
    }

    /// Assigns an explicit token to the single scratchpad slot, honoring the
    /// single-slot constraint: returns `.notFound` when the slot is held by a
    /// different managed window so the right-click menu can disable/relabel the
    /// item rather than silently no-op'ing. Token-parameterized twin of the
    /// assign branch of `assignFocusedWindowToScratchpad()`.
    @discardableResult
    func assignWindowToScratchpad(token: WindowToken) -> ExternalCommandResult {
        guard let entry = workspaceManager.entry(for: token),
              !isManagedWindowSuspendedForNativeFullscreen(token)
        else {
            return .notFound
        }

        if let existingScratchpadToken = workspaceManager.scratchpadToken(),
           existingScratchpadToken != token
        {
            if workspaceManager.entry(for: existingScratchpadToken) == nil {
                cleanupScratchpadWindowResources(for: existingScratchpadToken)
            } else {
                return .notFound
            }
        }

        let preferredMonitor = monitorForInteraction() ?? workspaceManager.monitor(for: entry.workspaceId)
        let transitionedFromTiling = entry.mode == .tiling
        guard prepareWindowForScratchpadAssignment(token, preferredMonitor: preferredMonitor) else {
            return .notFound
        }

        _ = workspaceManager.setScratchpadToken(token)

        guard let updatedEntry = workspaceManager.entry(for: token),
              let hideMonitor = workspaceManager.monitor(for: updatedEntry.workspaceId) ?? preferredMonitor
        else {
            cleanupScratchpadWindowResources(for: token)
            return .notFound
        }

        hideScratchpadWindow(updatedEntry, monitor: hideMonitor)

        if transitionedFromTiling {
            layoutRefreshController.requestRefresh(reason: .layoutCommand)
        }

        return .executed
    }

    /// Unassigns an explicit token from the scratchpad slot, restoring it to
    /// tiling. Returns `.notFound` when the token is not the current scratchpad
    /// or is suspended for native fullscreen. Backs the workspace bar's
    /// scratchpad-pill *Unassign* item.
    @discardableResult
    func unassignWindowFromScratchpad(token: WindowToken) -> ExternalCommandResult {
        guard workspaceManager.isScratchpadToken(token),
              let entry = workspaceManager.entry(for: token),
              !isManagedWindowSuspendedForNativeFullscreen(token)
        else {
            return .notFound
        }

        if let hiddenState = workspaceManager.hiddenState(for: token) {
            guard hiddenState.isScratchpad,
                  let monitor = workspaceManager.monitor(for: entry.workspaceId) ?? monitorForInteraction(),
                  layoutRefreshController.restoreScratchpadWindow(entry, monitor: monitor)
            else {
                return .notFound
            }
        }

        cleanupScratchpadWindowResources(for: token)
        applyManagedWindowOverride(.forceTile, for: token, entry: entry)
        return .executed
    }

    /// Token-aware assign-or-unassign routed by current scratchpad state. Used
    /// by both the window-icon *Assign to Scratchpad* and the scratchpad-pill
    /// *Unassign from Scratchpad* menu items.
    @discardableResult
    func toggleWindowScratchpadAssignment(token: WindowToken) -> ExternalCommandResult {
        if workspaceManager.isScratchpadToken(token) {
            return unassignWindowFromScratchpad(token: token)
        }
        return assignWindowToScratchpad(token: token)
    }

    @discardableResult
    func assignFocusedWindowToScratchpad() -> ExternalCommandResult {
        guard let token = focusedManagedTokenForCommand() else {
            return .notFound
        }
        return toggleWindowScratchpadAssignment(token: token)
    }

    private func applyManagedWindowOverride(
        _ override: ManualWindowOverride?,
        for token: WindowToken,
        entry: WindowModel.Entry
    ) {
        workspaceManager.setManualLayoutOverride(override, for: token)
        let evaluation = evaluateWindowDisposition(
            axRef: entry.axRef,
            pid: token.pid
        )
        guard let trackedMode = trackedModeForLifecycle(
            decision: evaluation.decision,
            existingEntry: entry
        ) else {
            cleanupScratchpadWindowResourcesIfNeeded(for: token)
            nativeFullscreenPlaceholderManager.remove(token)
            _ = workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
            layoutRefreshController.requestRefresh(
                reason: .windowRuleReevaluation,
                affectedWorkspaceIds: [entry.workspaceId]
            )
            return
        }

        _ = transitionWindowMode(
            for: token,
            to: trackedMode,
            preferredMonitor: monitorForInteraction(),
            applyFloatingFrame: true
        )
        layoutRefreshController.requestRefresh(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    @discardableResult
    func toggleScratchpadWindow() -> ExternalCommandResult {
        guard let scratchpadToken = workspaceManager.scratchpadToken() else {
            return .notFound
        }
        guard let entry = workspaceManager.entry(for: scratchpadToken) else {
            cleanupScratchpadWindowResources(for: scratchpadToken)
            return .notFound
        }
        guard !isManagedWindowSuspendedForNativeFullscreen(scratchpadToken) else {
            return .notFound
        }
        guard let target = scratchpadTarget() else {
            return .notFound
        }

        if let hiddenState = workspaceManager.hiddenState(for: scratchpadToken) {
            let updatedEntry = workspaceManager.entry(for: scratchpadToken) ?? entry
            if hiddenState.isScratchpad || hiddenState.workspaceInactive {
                let started = showScratchpadWindow(updatedEntry, on: target.workspaceId, monitor: target.monitor)
                return started ? .executed : .notFound
            }
            return .notFound
        }

        let hasCapturedGeometry = captureVisibleFloatingGeometry(
            for: scratchpadToken,
            preferredMonitor: target.monitor
        ) != nil || workspaceManager.floatingState(for: scratchpadToken) != nil
        guard hasCapturedGeometry else {
            return .notFound
        }

        if entry.workspaceId == target.workspaceId,
           isManagedWindowDisplayable(entry.handle)
        {
            hideScratchpadWindow(entry, monitor: target.monitor)
            return .executed
        }

        let started = showScratchpadWindow(entry, on: target.workspaceId, monitor: target.monitor)
        return started ? .executed : .notFound
    }

    func workspaceAssignment(pid: pid_t, windowId: Int) -> WorkspaceDescriptor.ID? {
        workspaceManager.entry(forPid: pid, windowId: windowId)?.workspaceId
    }

    func openCommandPalette() {
        commandPaletteController.toggle(wmController: self)
    }

    func openMenuAnywhere() {
        windowActionHandler.openMenuAnywhere()
    }

    func navigateToCommandPaletteWindow(_ handle: WindowHandle) {
        windowActionHandler.navigateToWindow(handle: handle)
    }

    func summonCommandPaletteWindowRight(
        _ handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) {
        windowActionHandler.summonWindowRight(
            handle: handle,
            anchorToken: anchorToken,
            anchorWorkspaceId: anchorWorkspaceId
        )
    }

    func toggleOverview() {
        windowActionHandler.toggleOverview()
    }

    func navigateOverviewSelection(_ direction: Direction) -> Bool {
        windowActionHandler.navigateOverviewSelection(direction)
    }

    func raiseAllFloatingWindows() {
        windowActionHandler.raiseAllFloatingWindows()
    }

    @discardableResult
    func restoreVisibleWorkspaceInactiveFloatingWindows() -> Int {
        layoutRefreshController.restoreWorkspaceInactiveFloatingWindows(
            activeWorkspaceIds: workspaceManager.visibleWorkspaceIds()
        )
    }

    func hasVisibleWorkspaceInactiveFloatingWindows() -> Bool {
        layoutRefreshController.hasWorkspaceInactiveFloatingWindows(
            activeWorkspaceIds: workspaceManager.visibleWorkspaceIds()
        )
    }

    @discardableResult
    func restoreHiddenWindowsForGracefulTermination() -> Int {
        layoutRefreshController.restoreHiddenWindowsForGracefulTermination()
    }

    @discardableResult
    func rescueOffscreenWindows() -> Int {
        guard !isLockScreenActive else { return 0 }

        var candidates: [RestorePlanner.FloatingRescueCandidate] = []
        let visibleWorkspaceIds = workspaceManager.visibleWorkspaceIds()

        for entry in workspaceManager.allFloatingEntries() {
            guard entry.layoutReason == .standard else { continue }
            guard visibleWorkspaceIds.contains(entry.workspaceId) else { continue }
            guard let targetMonitor = workspaceManager.monitor(for: entry.workspaceId)
                ?? monitorForInteraction()
                ?? workspaceManager.monitors.first
            else {
                continue
            }

            guard let targetFrame = workspaceManager.resolvedFloatingFrame(
                for: entry.token,
                preferredMonitor: targetMonitor
            ) else {
                continue
            }

            candidates.append(
                .init(
                    token: entry.token,
                    pid: entry.pid,
                    windowId: entry.windowId,
                    workspaceId: entry.workspaceId,
                    targetMonitor: targetMonitor,
                    currentFrame: liveFrame(for: entry),
                    targetFrame: targetFrame,
                    isScratchpadHidden: workspaceManager.hiddenState(for: entry.token)?.isScratchpad == true,
                    isWorkspaceInactiveHidden: workspaceManager.hiddenState(for: entry.token)?.workspaceInactive == true
                )
            )
        }

        let rescuePlan = restorePlanner.planFloatingRescue(candidates)
        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        var visibleJobs: [(pid: pid_t, windowId: Int)] = []
        var rescuedEntries: [WindowModel.Entry] = []

        for operation in rescuePlan.operations {
            guard let entry = workspaceManager.entry(for: operation.token) else { continue }
            let wasWorkspaceInactiveHidden = workspaceManager.hiddenState(for: operation.token)?
                .workspaceInactive == true
            if !wasWorkspaceInactiveHidden {
                workspaceManager.updateFloatingGeometry(
                    frame: operation.targetFrame,
                    for: operation.token,
                    referenceMonitor: operation.targetMonitor,
                    restoreToFloating: true
                )
            }
            if wasWorkspaceInactiveHidden {
                workspaceManager.setHiddenState(nil, for: operation.token)
                visibleJobs.append((operation.pid, operation.windowId))
                axManager.markWindowActive(operation.windowId)
            }
            axManager.forceApplyNextFrame(for: operation.windowId)
            frameUpdates.append((operation.pid, operation.windowId, operation.targetFrame))
            rescuedEntries.append(entry)
        }

        if !frameUpdates.isEmpty {
            if !visibleJobs.isEmpty {
                axManager.unsuppressFrameWrites(visibleJobs)
            }
            axManager.applyFramesParallel(frameUpdates)
            for entry in rescuedEntries {
                windowFocusOperations.raiseWindow(entry.axRef.element)
            }
        }

        return rescuePlan.rescuedCount
    }

    func isOverviewOpen() -> Bool {
        windowActionHandler.isOverviewOpen()
    }

    func selectedOverviewWindowForTests() -> WindowHandle? {
        windowActionHandler.selectedOverviewWindowForTests()
    }

    @discardableResult
    func resolveAndSetWorkspaceFocusToken(for workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        workspaceManager.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId)
        )
    }

    func reassignManagedWindow(
        _ token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        explicitMoveIntent: Bool = true
    ) {
        // Cross-workspace stale pending-focus clear: if the token being
        // reassigned has a pending managed-focus request targeting a DIFFERENT
        // workspace, cancel it now so a late AX confirmation does not pull
        // focus/selection back to the old workspace. Callers already reissue
        // focus for the new workspace after this call.
        if let activeRequest = focusBridge.activeManagedRequest,
           activeRequest.token == token,
           activeRequest.workspaceId != workspaceId
        {
            _ = focusBridge.cancelManagedRequest(requestId: activeRequest.requestId)
            focusBridge.discardPendingFocus(token)
        }

        if explicitMoveIntent {
            recordExplicitWorkspaceMoveIntent(for: token, to: workspaceId)
        }
        workspaceManager.setWorkspace(for: token, to: workspaceId)
        guard let entry = workspaceManager.entry(for: token) else { return }
        focusBorderController.updateFocusedTargetWorkspace(
            matching: token,
            axRef: entry.axRef,
            workspaceId: entry.workspaceId
        )
    }

    func recoverSourceFocusAfterMove(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredNodeId: NodeId?
    ) {
        let monitorId = workspaceManager.monitorId(for: workspaceId)

        if let engine = niriEngine,
           let preferredNodeId,
           let node = engine.findNode(by: preferredNodeId) as? NiriWindow
        {
            _ = workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: node.token,
                in: workspaceId,
                onMonitor: monitorId
            )
            return
        }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId)
    }

    func ensureFocusedTokenValid(in workspaceId: WorkspaceDescriptor.ID) {
        guard !shouldSuppressManagedFocusRecovery else { return }
        guard !workspaceManager.hasPendingNativeFullscreenTransition else { return }

        if let activeFocusRequestToken = workspaceManager.activeFocusRequestToken,
           workspaceManager.activeFocusRequestWorkspaceId == workspaceId
        {
            if let engine = niriEngine,
               let node = engine.findNode(for: activeFocusRequestToken)
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: node.id,
                    focusedToken: activeFocusRequestToken,
                    in: workspaceId,
                    onMonitor: workspaceManager.monitorId(for: workspaceId)
                )
            } else {
                _ = workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: workspaceId,
                        viewportState: nil,
                        rememberedFocusToken: activeFocusRequestToken
                    )
                )
            }
            return
        }

        if let focusedToken = workspaceManager.confirmedManagedFocusToken,
           workspaceManager.entry(for: focusedToken)?.workspaceId == workspaceId
        {
            if let engine = niriEngine,
               let node = engine.findNode(for: focusedToken)
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: node.id,
                    focusedToken: focusedToken,
                    in: workspaceId,
                    onMonitor: workspaceManager.monitorId(for: workspaceId)
                )
            } else {
                _ = workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: workspaceId,
                        viewportState: nil,
                        rememberedFocusToken: focusedToken
                    )
                )
            }
            return
        }

        guard let nextFocusToken = workspaceManager.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId)
        ) else {
            return
        }

        if let engine = niriEngine,
           let node = engine.findNode(for: nextFocusToken)
        {
            _ = workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: nextFocusToken,
                in: workspaceId
            )
        }
        focusWindow(nextFocusToken)
    }

    func moveMouseToWindow(_ handle: WindowHandle, preferredFrame: CGRect? = nil, reason: String = "unspecified") {
        moveMouseToWindow(handle.id, preferredFrame: preferredFrame, reason: reason)
    }

    func moveMouseToWindow(_ token: WindowToken, preferredFrame: CGRect? = nil, reason: String = "unspecified") {
        guard let entry = workspaceManager.entry(for: token) else {
            diagnostics
                .recordRuntimeMouseTrace("moveMouseToFocused.skip reason=noEntry source=\(reason) token=\(token)")
            return
        }
        let frameSource = preferredFrame == nil ? "ax" : "preferred"
        guard let frame = preferredFrame ?? AXWindowService.framePreferFast(entry.axRef) else {
            diagnostics.recordRuntimeMouseTrace(
                "moveMouseToFocused.skip reason=noFrame source=\(reason) token=\(token) frameSource=\(frameSource)"
            )
            return
        }

        let center = frame.center
        let pressedButtons = NSEvent.pressedMouseButtons
        let centerOnScreen = NSScreen.screens.contains(where: { $0.frame.contains(center) })
        if diagnostics.isRuntimeTraceCaptureActive {
            let current = NSEvent.mouseLocation
            diagnostics.recordRuntimeMouseTrace(
                "moveMouseToFocused.request source=\(reason) token=\(token) frame=\(formatTraceRect(frame)) frameSource=\(frameSource) current=\(formatTracePoint(current)) dest=\(formatTracePoint(center)) pressedButtons=\(pressedButtons) centerOnScreen=\(centerOnScreen)"
            )
        }

        guard centerOnScreen else {
            if diagnostics.isRuntimeTraceCaptureActive {
                diagnostics.recordRuntimeMouseTrace(
                    "moveMouseToFocused.skip reason=centerOffscreen source=\(reason) token=\(token) dest=\(formatTracePoint(center))"
                )
            }
            return
        }
        guard pressedButtons == 0 else {
            if diagnostics.isRuntimeTraceCaptureActive {
                diagnostics.recordRuntimeMouseTrace(
                    "moveMouseToFocused.skip reason=mouseButtonPressed source=\(reason) token=\(token) pressedButtons=\(pressedButtons) dest=\(formatTracePoint(center))"
                )
            }
            return
        }

        let windowServerCenter = ScreenCoordinateSpace.toWindowServer(point: center)
        warpMouseCursorPosition(windowServerCenter)
        if diagnostics.isRuntimeTraceCaptureActive {
            diagnostics.recordRuntimeMouseTrace(
                "moveMouseToFocused.perform source=\(reason) token=\(token) dest=\(formatTracePoint(center)) windowServerDest=\(formatTracePoint(windowServerCenter)) pressedButtons=\(pressedButtons)"
            )
        }
    }

    func moveMouseToMonitor(_ monitor: Monitor) {
        let center = monitor.visibleFrame.center
        let pressedButtons = NSEvent.pressedMouseButtons
        guard pressedButtons == 0 else {
            diagnostics.recordRuntimeMouseTrace(
                "moveMouseToMonitor.skip reason=mouseButtonPressed monitor=\(monitor.displayId) dest=\(formatTracePoint(center)) pressedButtons=\(pressedButtons)"
            )
            return
        }
        diagnostics.recordRuntimeMouseTrace(
            "moveMouseToMonitor.perform monitor=\(monitor.displayId) frame=\(formatTraceRect(monitor.visibleFrame)) dest=\(formatTracePoint(center)) pressedButtons=\(pressedButtons)"
        )
        warpMouseCursorPosition(
            ScreenCoordinateSpace.toWindowServer(point: center, displayId: monitor.displayId)
        )
    }

    private func formatTracePoint(_ point: CGPoint) -> String {
        String(format: "(%.1f,%.1f)", point.x, point.y)
    }

    private func formatTraceRect(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        windowActionHandler.runningAppsWithWindows()
    }
}

extension WMController {
    func isFrontmostAppLockScreen() -> Bool {
        lockScreenObserver.isFrontmostAppLockScreen()
    }

    func isPointInOwnWindow(_ point: CGPoint) -> Bool {
        ownedWindowRegistry.contains(point: point)
    }

    var hasFrontmostOwnedWindow: Bool {
        ownedWindowRegistry.hasFrontmostWindow
    }

    var hasVisibleOwnedWindow: Bool {
        ownedWindowRegistry.hasVisibleWindow
    }

    func handleOwnedFocusSuppressingWindowClosed() {
        guard workspaceManager.isNonManagedFocusActive, !hasVisibleOwnedWindow else { return }
        let preservedToken = workspaceManager.confirmedManagedFocusToken
        guard workspaceManager.leaveNonManagedFocus(preserveFocusedToken: true) else { return }
        if let preservedToken {
            suppressMouseMoveToFocusedWindow(for: preservedToken)
        }
        _ = focusBorderController.refresh(forceOrdering: true)
        mouseEventHandler.refreshFocusFollowsMouseAtCurrentPointer()
    }

    func isOwnedWindow(windowNumber: Int) -> Bool {
        ownedWindowRegistry.contains(windowNumber: windowNumber)
    }

    var shouldSuppressManagedFocusRecovery: Bool {
        workspaceManager.isNonManagedFocusActive && hasFrontmostOwnedWindow
    }

    func performWindowFronting(
        pid: pid_t,
        windowId: Int,
        axRef: AXWindowRef
    ) {
        windowFocusOperations.activateApp(pid)
        windowFocusOperations.focusSpecificWindow(pid, UInt32(windowId), axRef.element)
        windowFocusOperations.raiseWindow(axRef.element)
    }

    func activateNativeFullscreenPlaceholder(_ token: WindowToken) {
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard workspaceManager.layoutReason(for: token) == .nativeFullscreen else { return }
        guard !isLockScreenActive else { return }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return }
        }
        selectNativeFullscreenPlaceholder(entry)
        performWindowFronting(pid: entry.pid, windowId: entry.windowId, axRef: entry.axRef)
    }

    @discardableResult
    private func selectNativeFullscreenPlaceholder(_ entry: WindowModel.Entry) -> Bool {
        let token = entry.token
        let changed = workspaceManager.selectNativeFullscreenPlaceholder(
            token,
            in: entry.workspaceId,
            onMonitor: workspaceManager.monitorId(for: entry.workspaceId)
        )
        _ = focusBridge.cancelManagedRequest(matching: token, workspaceId: entry.workspaceId)
        focusBridge.discardPendingFocus(token)
        focusBorderController.hide()
        if changed {
            layoutRefreshController.requestRefresh(
                reason: .appActivationTransition,
                affectedWorkspaceIds: [entry.workspaceId]
            )
        }
        return changed
    }

    func focusWindow(_ token: WindowToken) {
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard !isLockScreenActive else { return }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return }
        }
        if isManagedWindowSuspendedForNativeFullscreen(token) {
            selectNativeFullscreenPlaceholder(entry)
            return
        }
        _ = workspaceManager.beginManagedFocusRequest(
            token,
            in: entry.workspaceId,
            onMonitor: workspaceManager.monitorId(for: entry.workspaceId)
        )
        let request = focusBridge.beginManagedRequest(
            token: token,
            workspaceId: entry.workspaceId
        )
        diagnostics.recordNiriCreateFocusTrace(
            .pendingFocusStarted(
                requestId: request.requestId,
                token: token,
                workspaceId: entry.workspaceId
            )
        )

        let axRef = entry.axRef
        let pid = entry.pid
        let windowId = entry.windowId

        focusBridge.focusWindow(
            token,
            performFocus: {
                self.performWindowFronting(pid: pid, windowId: windowId, axRef: axRef)
                self.axEventHandler.probeFocusedWindowAfterFronting(
                    expectedToken: token,
                    workspaceId: entry.workspaceId
                )
            },
            onDeferredFocus: { [weak self] deferred in
                guard let self, self.workspaceManager.entry(for: deferred) != nil else { return }
                self.focusWindow(deferred)
            }
        )
    }

    func focusWindow(_ handle: WindowHandle) {
        focusWindow(handle.id)
    }

    func keyboardFocusTarget(for token: WindowToken, axRef: AXWindowRef) -> KeyboardFocusTarget {
        if let entry = workspaceManager.entry(for: token) {
            return KeyboardFocusTarget(
                token: token,
                axRef: entry.axRef,
                workspaceId: entry.workspaceId,
                isManaged: true
            )
        }

        return KeyboardFocusTarget(
            token: token,
            axRef: axRef,
            workspaceId: nil,
            isManaged: false
        )
    }

    func managedKeyboardFocusTarget(for token: WindowToken) -> KeyboardFocusTarget? {
        guard let entry = workspaceManager.entry(for: token) else { return nil }
        return KeyboardFocusTarget(
            token: token,
            axRef: entry.axRef,
            workspaceId: entry.workspaceId,
            isManaged: true
        )
    }

    func currentBorderTarget() -> KeyboardFocusTarget? {
        focusBorderController.currentBorderTarget
    }

    func preferredKeyboardFocusFrame(for token: WindowToken) -> CGRect? {
        if let node = niriEngine?.findNode(for: token) {
            return node.preferredFrame
        }
        if let floatingState = workspaceManager.floatingState(for: token) {
            return floatingState.lastFrame
        }
        return nil
    }

    @discardableResult
    func renderKeyboardFocusBorder(
        for target: KeyboardFocusTarget? = nil,
        preferredFrame: CGRect? = nil,
        preferredFrameSource: BorderFrameSource = .layout,
        forceOrdering: Bool = false
    ) -> Bool {
        if let target {
            return focusBorderController.focusChanged(
                to: target,
                preferredFrame: preferredFrame,
                preferredFrameSource: preferredFrameSource,
                forceOrdering: forceOrdering
            )
        }
        return focusBorderController.refresh(
            preferredFrame: preferredFrame,
            preferredFrameSource: preferredFrameSource,
            forceOrdering: forceOrdering
        )
    }

    @discardableResult
    func updateManagedKeyboardFocusBorder(
        token: WindowToken,
        preferredFrame: CGRect,
        forceOrdering: Bool = false
    ) -> Bool {
        if currentBorderTarget()?.token == token {
            return focusBorderController.updateFrameHint(
                for: token,
                frame: preferredFrame,
                forceOrdering: forceOrdering
            )
        }
        guard !focusBorderController.isManagedTargetSuppressed(token),
              !workspaceManager.isNonManagedFocusActive,
              workspaceManager.confirmedManagedFocusToken == token,
              let target = managedKeyboardFocusTarget(for: token)
        else {
            return false
        }
        return focusBorderController.focusChanged(
            to: target,
            preferredFrame: preferredFrame,
            forceOrdering: forceOrdering
        )
    }

    @discardableResult
    func reapplyKeyboardFocusBorderIfMatching(
        token: WindowToken,
        preferredFrame: CGRect? = nil,
        phase: ManagedBorderReapplyPhase,
        forceOrdering: Bool = false
    ) -> Bool {
        guard currentBorderTarget()?.token == token else { return false }
        diagnostics.recordNiriCreateFocusTrace(.borderReapplied(token: token, phase: phase))
        if let preferredFrame {
            return focusBorderController.updateFrameHint(
                for: token,
                frame: preferredFrame,
                forceOrdering: forceOrdering
            )
        }
        return focusBorderController.refresh(forceOrdering: forceOrdering)
    }

    func clearKeyboardFocusTarget(
        matching token: WindowToken? = nil,
        pid: pid_t? = nil,
        restoreCurrentBorder: Bool = false
    ) {
        focusBorderController.clear(matching: token, pid: pid)
        guard restoreCurrentBorder else { return }
        _ = focusBorderController.refresh(forceOrdering: true)
    }

    var isDiscoveryInProgress: Bool {
        layoutRefreshController.isDiscoveryInProgress
    }

    var isInteractiveGestureActive: Bool {
        mouseEventHandler.isInteractiveGestureActive
    }
}
