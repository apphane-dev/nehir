// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

enum ActivationEventSource: String, Sendable {
    case focusedWindowChanged
    case workspaceDidActivateApplication
    case cgsFrontAppChanged

    var isAuthoritative: Bool {
        self == .focusedWindowChanged
    }
}

@MainActor
final class ServiceLifecycleManager {
    weak var controller: WMController?

    private var displayObserver: DisplayConfigurationObserver?
    private var screenParametersObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var appDeactivationObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var permissionCheckerTask: Task<Void, Never>?
    private var dockReservationSettleTasks: [Task<Void, Never>] = []
    private var monitorConfigurationCoalesceTask: Task<Void, Never>?
    private var screenshotCaptureVisibilityTask: Task<Void, Never>?
    private var screenshotShortcutSuppressionActive = false
    private var screenshotShortcutSuppressionGeneration: UInt64 = 0
    var accessibilityPermissionStreamProviderForTests: ((Bool) -> AsyncStream<Bool>)?
    var accessibilityPermissionStateProviderForTests: (() -> Bool)?
    var accessibilityPermissionRequestHandlerForTests: (() -> Bool)?

    init(controller: WMController) {
        self.controller = controller
    }

    func start() {
        guard let controller else { return }
        let initialPermissionGranted = currentAccessibilityPermissionGranted()
        controller.updateAccessibilityPermissionGranted(initialPermissionGranted)
        if controller.desiredEnabled,
           initialPermissionGranted,
           !controller.onboardingActive,
           !controller.hasStartedServices
        {
            startServices()
        }
        permissionCheckerTask?.cancel()
        permissionCheckerTask = Task { @MainActor [weak self, weak controller] in
            guard let self else { return }
            for await granted in self.accessibilityPermissionStream(initial: true) {
                guard let controller, !Task.isCancelled else { return }

                if granted {
                    controller.updateAccessibilityPermissionGranted(true)
                    if controller.desiredEnabled, !controller.onboardingActive, !controller.hasStartedServices {
                        self.startServices()
                    }
                } else {
                    _ = self.requestAccessibilityPermission()
                    controller.updateAccessibilityPermissionGranted(false)
                }
            }
        }
    }

    private func startServices() {
        guard let controller, !controller.hasStartedServices else { return }
        controller.hasStartedServices = true
        controller.reconcileEnabledAndHotkeysState()
        controller.layoutRefreshController.setup()
        controller.axEventHandler.setup()
        controller.axManager.installWorkspaceObservers()
        controller.axManager.onAppLaunched = { [weak self] _ in
            self?.handleAppLaunched()
        }
        controller.axManager.onAppTerminated = { [weak self] pid in
            self?.handleAppTerminated(pid: pid)
        }
        controller.axManager.isRuntimeTraceCaptureActive = { [weak controller] in
            controller?.diagnostics.isRuntimeTraceCaptureActive == true
        }
        AppAXContext.onWindowDestroyed = { [weak controller] pid, windowId in
            guard let controller else { return }
            controller.axEventHandler.handleRemoved(pid: pid, winId: windowId)
        }
        AppAXContext.onWindowMiniaturized = { [weak controller] pid, windowId in
            controller?.axEventHandler.handleWindowMiniaturized(pid: pid, windowId: windowId)
        }
        AppAXContext.onFocusedWindowChanged = { [weak controller] pid in
            controller?.axEventHandler.handleAppActivation(
                pid: pid,
                source: .focusedWindowChanged
            )
        }
        setupWorkspaceObservation()
        controller.mouseEventHandler.setup()
        controller.syncMouseWarpPolicy()
        setupDisplayObserver()
        setupAppActivationObserver()
        setupAppDeactivationObserver()
        setupAppHideObservers()
        setupSleepWakeObservation()
        controller.workspaceManager.onGapsChanged = { [weak self] in
            self?.handleGapsChanged()
        }
        controller.dockEdgeShieldManager.trace = { [weak controller] message in
            controller?.axManager.recordFrameApplyTrace(message)
        }
        controller.dockEdgeShieldManager.onButtonTap = { [weak self] in
            // Re-evaluate the Dock environment as at app start: drop the learned insets
            // and re-read the live configuration. If the Dock is genuinely gone, the
            // working area reclaims the band and the shield hides itself.
            DockReservation.forgetStickyInsets()
            self?.handleMonitorConfigurationChanged()
        }
        controller.dockEdgeShieldManager.onLogoTap = { [weak controller] in
            guard let controller else { return }
            SettingsWindowController.shared.show(settings: controller.settings, controller: controller, section: .about)
        }
        controller.dockEdgeShieldManager.outerGapsProvider = { [weak controller] monitor in
            controller?.outerGaps(for: monitor) ?? .zero
        }
        applyDockShieldSettings()
        controller.dockEdgeShieldManager.update(monitors: controller.workspaceManager.monitors)

        performStartupRefresh()
        startLockScreenObserver()
    }

    private func startLockScreenObserver() {
        guard let controller else { return }
        controller.lockScreenObserver.onLockDetected = { [weak controller] in
            controller?.isLockScreenActive = true
        }
        controller.lockScreenObserver.onUnlockDetected = { [weak controller] in
            guard let controller else { return }
            controller.isLockScreenActive = false
            controller.serviceLifecycleManager.handleUnlockDetected()
        }
        controller.lockScreenObserver.start()
    }

    private func setupDisplayObserver() {
        displayObserver = DisplayConfigurationObserver()
        displayObserver?.setEventHandler { [weak self] event in
            self?.handleDisplayEvent(event)
        }
        // The Dock showing/hiding (e.g. a quick-terminal that hides the Dock while
        // frontmost) changes screen parameters but is NOT a CGDisplay reconfiguration,
        // so DisplayConfigurationObserver never fires for it. Without this the Dock
        // reservation can be absent at launch and the viewport stays full-width until a
        // manual restart. didChangeScreenParameters fires on every visibleFrame change.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMonitorConfigurationChanged()
            }
        }
    }

    private func handleDisplayEvent(_ event: DisplayConfigurationObserver.DisplayEvent) {
        switch event {
        case let .disconnected(monitorId, outputId):
            handleMonitorDisconnect(monitorId: monitorId, outputId: outputId)
        case .connected,
             .reconfigured:
            break
        }
        handleMonitorConfigurationChanged()
    }

    private func handleMonitorDisconnect(monitorId: Monitor.ID, outputId: OutputId) {
        guard let controller else { return }
        controller.layoutRefreshController.cleanupForMonitorDisconnect(
            displayId: outputId.displayId,
            migrateAnimations: false
        )

        controller.niriEngine?.cleanupRemovedMonitor(monitorId)
    }

    /// Coalesces bursts of monitor-configuration notifications: a display reconfiguration
    /// fires both `DisplayConfigurationObserver` and `didChangeScreenParameters`, which
    /// would otherwise trigger two back-to-back full rescans. A short debounce collapses
    /// overlapping notifications into a single `applyMonitorConfigurationChanged`.
    private func handleMonitorConfigurationChanged() {
        monitorConfigurationCoalesceTask?.cancel()
        monitorConfigurationCoalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self, self.controller != nil else { return }
            self.applyMonitorConfigurationChanged(currentMonitors: Monitor.current())
        }
    }

    func applyMonitorConfigurationChanged(
        currentMonitors: [Monitor],
        performPostUpdateActions: Bool = true
    ) {
        guard let controller else { return }
        // Invalidate border cache so it gets fully recomputed after monitor change
        // (prevents stale geometry when display ID or coordinate space changes, e.g. KVM switch)
        controller.focusBorderController.hide()
        guard !currentMonitors.isEmpty else { return }
        guard currentMonitors.allSatisfy({ $0.frame.width > 1 && $0.frame.height > 1 }) else { return }

        controller.workspaceManager.applyMonitorConfigurationChange(currentMonitors)
        controller.syncMouseWarpPolicy(for: controller.workspaceManager.monitors)
        controller.dockEdgeShieldManager.update(monitors: controller.workspaceManager.monitors)
        guard performPostUpdateActions else { return }

        controller.syncMonitorsToNiriEngine()

        let focusedWsId = controller.workspaceManager.confirmedManagedFocusToken
            .flatMap { controller.workspaceManager.workspace(for: $0) }
        controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWsId)

        // Invalidate cached geometry assumptions so the upcoming full rescan
        // re-applies positions for every window. macOS physically repositions
        // windows during display reconfiguration, but cached AX frames and logical
        // offscreen hidden-state can make the layout diff skip writes for windows
        // it considers "already in place".
        controller.axManager.invalidateCachedFrameState()
        controller.workspaceManager.clearGeometryHiddenStates()

        controller.layoutRefreshController.requestRefresh(reason: .monitorConfigurationChanged)
    }

    func handleAppTerminated(pid: pid_t) {
        guard let controller else { return }
        controller.axEventHandler.cleanupFocusStateForTerminatedApp(pid: pid)
        let removedTokens = controller.workspaceManager.entries(forPid: pid).map(\.token)
        for token in removedTokens {
            controller.cleanupScratchpadWindowResourcesIfNeeded(for: token)
            controller.axManager.removeWindowState(pid: token.pid, windowId: token.windowId)
        }
        let affectedWorkspaces = controller.workspaceManager.removeWindowsForApp(pid: pid)
        for token in removedTokens {
            controller.nativeFullscreenPlaceholderManager.remove(token)
        }
        for workspaceId in affectedWorkspaces {
            if let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
               controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
            {
                controller.ensureFocusedTokenValid(in: workspaceId)
            }
        }
        _ = controller.focusBorderController.refresh(forceOrdering: true)
        controller.appInfoCache.evict(pid: pid)
        controller.layoutRefreshController.requestRefresh(reason: .appTerminated)
    }

    func handleGapsChanged() {
        controller?.layoutRefreshController.requestRefresh(reason: .gapsChanged)
    }

    func handleAppLaunched() {
        controller?.layoutRefreshController.requestRefresh(reason: .appLaunched)
    }

    /// Hide focus borders before macOS handles its standard screenshot shortcuts.
    /// `screencaptureui` remains resident between captures, so process lifecycle is
    /// not a reliable signal for the interactive picker's lifetime.
    func handleSystemScreenshotShortcut(keyCode: Int64) {
        guard Self.screenshotShortcutKeyCodes.contains(keyCode) else { return }
        screenshotShortcutSuppressionGeneration &+= 1
        let generation = screenshotShortcutSuppressionGeneration
        screenshotShortcutSuppressionActive = true
        controller?.focusBorderController.setScreenshotCaptureSuppressed(true)
        recordScreenshotBorderSuppression(state: "entered", trigger: "shortcut-\(keyCode)")
        screenshotCaptureVisibilityTask?.cancel()

        if keyCode == Self.fullScreenScreenshotKeyCode {
            screenshotCaptureVisibilityTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                self?.endScreenshotShortcutSuppression(
                    trigger: "full-screen-timeout",
                    generation: generation
                )
            }
            return
        }

        screenshotCaptureVisibilityTask = Task { @MainActor [weak self] in
            var observedPickerWindow = false
            let deadline = Date().addingTimeInterval(Self.interactiveScreenshotSuppressionTimeout)
            while !Task.isCancelled {
                guard let self,
                      self.screenshotShortcutSuppressionActive,
                      self.screenshotShortcutSuppressionGeneration == generation
                else { return }

                let pickerVisible = self.isScreenshotPickerWindowVisible
                observedPickerWindow = observedPickerWindow || pickerVisible
                if observedPickerWindow, !pickerVisible {
                    self.endScreenshotShortcutSuppression(
                        trigger: "picker-window-hidden",
                        generation: generation
                    )
                    return
                }
                if Date() >= deadline {
                    self.endScreenshotShortcutSuppression(
                        trigger: "picker-window-timeout",
                        generation: generation
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func handlePotentialScreenshotInteractionCompletion() {
        guard screenshotShortcutSuppressionActive else { return }
        let generation = screenshotShortcutSuppressionGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled,
                  let self,
                  self.screenshotShortcutSuppressionActive,
                  self.screenshotShortcutSuppressionGeneration == generation,
                  !self.isScreenshotPickerWindowVisible
            else { return }
            self.endScreenshotShortcutSuppression(
                trigger: "interaction-completed",
                generation: generation
            )
        }
    }

    private func endScreenshotShortcutSuppression(trigger: String, generation: UInt64) {
        guard screenshotShortcutSuppressionActive,
              screenshotShortcutSuppressionGeneration == generation
        else { return }
        screenshotShortcutSuppressionActive = false
        screenshotCaptureVisibilityTask?.cancel()
        screenshotCaptureVisibilityTask = nil
        controller?.focusBorderController.setScreenshotCaptureSuppressed(false)
        recordScreenshotBorderSuppression(state: "exited", trigger: trigger)
    }

    private func recordScreenshotBorderSuppression(state: String, trigger: String) {
        controller?.diagnostics.recordRuntimeDecisionEvent(
            named: "screenshot_border_suppression",
            cluster: "border-capture"
        ) {
            [
                RuntimeDecisionTraceField("state", state),
                RuntimeDecisionTraceField("trigger", trigger)
            ]
        }
    }

    private var isScreenshotPickerWindowVisible: Bool {
        let pids = Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.screenshotCaptureUIBundleIdentifier
            ).map(\.processIdentifier)
        )
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], 0) as? [[String: Any]]
        else { return false }

        return windows.contains { window in
            guard let ownerPid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pids.contains(ownerPid),
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
            else { return false }
            // The persistent transparent backing window is at layer 24. The
            // interactive controls are transient high-level windows (1000+).
            return layer >= 1_000
        }
    }

    func handleUnlockDetected() {
        guard let controller else { return }
        controller.layoutRefreshController.requestRefresh(reason: .unlock)
    }

    /// Push the current Dock-Shield settings (enabled/color/opacity) into the manager and
    /// refresh live shields. Call at setup and whenever those settings change.
    func applyDockShieldSettings() {
        guard let controller else { return }
        let manager = controller.dockEdgeShieldManager
        manager.isEnabled = controller.settings.dockShieldEnabled
        manager.fillColorHex = controller.settings.dockShieldColorHex
        manager.fillColorDarkHex = controller.settings.dockShieldColorDarkHex
        manager.fillOpacity = controller.settings.dockShieldOpacity
        manager.applyAppearance()
        manager.update(monitors: controller.workspaceManager.monitors)
    }

    func performStartupRefresh() {
        controller?.layoutRefreshController.requestRefresh(reason: .startup)
        scheduleDockReservationSettleRefreshes()
    }

    /// The Dock's edge reservation — and its AX bar geometry — is frequently not
    /// available for the first moment after launch, so the initial layout computes a
    /// full-width viewport and it stays that way (a manual restart is what "fixes" it).
    /// Re-read the monitor configuration a few times shortly after startup and re-apply
    /// it only if the effective visibleFrame changed, so the viewport corrects itself.
    private func scheduleDockReservationSettleRefreshes() {
        guard controller != nil else { return }
        dockReservationSettleTasks.forEach { $0.cancel() }
        dockReservationSettleTasks.removeAll(keepingCapacity: true)
        for delay in [0.5, 1.5, 3.0] {
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, let controller = self.controller else { return }
                let fresh = Monitor.current()
                let currentById = Dictionary(
                    uniqueKeysWithValues: controller.workspaceManager.monitors.map { ($0.id, $0) }
                )
                let changed = fresh.contains { monitor in
                    guard let current = currentById[monitor.id] else { return true }
                    return abs(current.visibleFrame.width - monitor.visibleFrame.width) > 0.5
                        || abs(current.visibleFrame.height - monitor.visibleFrame.height) > 0.5
                }
                guard changed else { return }
                self.applyMonitorConfigurationChanged(currentMonitors: fresh)
            }
            dockReservationSettleTasks.append(task)
        }
    }

    func handleActiveSpaceDidChange() {
        guard let controller else { return }
        controller.focusBorderController.hide()
        controller.workspaceManager.recordReconcileEvent(.activeSpaceChanged(source: .service))
        controller.layoutRefreshController.requestRefresh(reason: .activeSpaceChanged)
    }

    private func setupWorkspaceObservation() {
        guard controller != nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleActiveSpaceDidChange()
            }
        }
    }

    private func setupAppActivationObserver() {
        guard let controller else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppActivation(
                    pid: pid,
                    source: .workspaceDidActivateApplication
                )
            }
        }
    }

    private func setupAppDeactivationObserver() {
        guard let controller else { return }
        appDeactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppDeactivated(pid: app.processIdentifier)
            }
        }
    }

    private func setupAppHideObservers() {
        guard let controller else { return }
        appHideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppHidden(pid: app.processIdentifier)
            }
        }

        appUnhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak controller] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                controller?.axEventHandler.handleAppUnhidden(pid: app.processIdentifier)
            }
        }
    }

    private func setupSleepWakeObservation() {
        guard controller != nil else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let controller = self?.controller else { return }
                controller.mouseEventHandler.stopMultitouch()
                _ = controller.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let controller = self?.controller else { return }
                _ = controller.workspaceManager.recordReconcileEvent(.systemWake(source: .service))
                controller.mouseEventHandler.restartMultitouch()
                controller.layoutRefreshController.requestRefresh(reason: .unlock)
            }
        }
    }

    func stop() {
        guard let controller else { return }
        controller.hasStartedServices = false

        AppAXContext.onWindowDestroyed = nil
        AppAXContext.onWindowMiniaturized = nil
        AppAXContext.onFocusedWindowChanged = nil
        controller.axManager.onAppLaunched = nil
        controller.axManager.onAppTerminated = nil
        controller.axManager.isRuntimeTraceCaptureActive = { false }
        controller.workspaceManager.onGapsChanged = nil
        screenshotShortcutSuppressionActive = false
        screenshotShortcutSuppressionGeneration &+= 1
        screenshotCaptureVisibilityTask?.cancel()
        screenshotCaptureVisibilityTask = nil

        controller.layoutRefreshController.resetState()
        controller.mouseEventHandler.cleanup()
        controller.resetMouseWarpPolicy()
        controller.axEventHandler.cleanup()

        controller.tabbedOverlayManager.removeAll()
        controller.nativeFullscreenPlaceholderManager.removeAll()
        controller.focusBorderController.cleanup()
        controller.cleanupUIOnStop()

        controller.axManager.cleanup()

        displayObserver = nil

        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
            screenParametersObserver = nil
        }
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        if let observer = appDeactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appDeactivationObserver = nil
        }
        if let observer = appHideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appHideObserver = nil
        }
        if let observer = appUnhideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appUnhideObserver = nil
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepObserver = nil
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }

        controller.lockScreenObserver.stop()
        permissionCheckerTask?.cancel()
        permissionCheckerTask = nil
        dockReservationSettleTasks.forEach { $0.cancel() }
        dockReservationSettleTasks.removeAll(keepingCapacity: true)
        monitorConfigurationCoalesceTask?.cancel()
        monitorConfigurationCoalesceTask = nil
        controller.reconcileEnabledAndHotkeysState()
    }

    private static let screenshotCaptureUIBundleIdentifier = "com.apple.screencaptureui"
    private static let interactiveScreenshotSuppressionTimeout: TimeInterval = 30
    // Hardware key codes for 3, 4, and 5 in macOS's standard screenshot chords.
    private static let fullScreenScreenshotKeyCode: Int64 = 20
    private static let screenshotShortcutKeyCodes: Set<Int64> = [20, 21, 23]

    private func accessibilityPermissionStream(initial: Bool) -> AsyncStream<Bool> {
        accessibilityPermissionStreamProviderForTests?(initial)
            ?? AccessibilityPermissionMonitor.shared.stream(initial: initial)
    }

    private func currentAccessibilityPermissionGranted() -> Bool {
        accessibilityPermissionStateProviderForTests?() ?? AccessibilityPermissionMonitor.shared.isGranted
    }

    @discardableResult
    private func requestAccessibilityPermission() -> Bool {
        accessibilityPermissionRequestHandlerForTests?() ?? controller?.axManager.requestPermission() ?? false
    }
}
