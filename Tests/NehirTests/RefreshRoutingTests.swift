import ApplicationServices
import CoreGraphics
import Foundation
@testable import Nehir
import Testing

private func makeRefreshTestDefaults() -> UserDefaults {
    let suiteName = "dev.guria.nehir.refresh-routing.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeRefreshTestMonitor(
    displayId: CGDirectDisplayID = layoutPlanTestMainDisplayId(),
    name: String = "Main",
    x: CGFloat = 0,
    y: CGFloat = 0,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    makeLayoutPlanTestMonitor(
        displayId: displayId,
        name: name,
        x: x,
        y: y,
        width: width,
        height: height
    )
}

private func makeRefreshTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private func makeRefreshTestWindowFacts(
    bundleId: String = "com.example.refresh",
    title: String? = nil,
    role: String? = kAXWindowRole as String,
    subrole: String? = kAXStandardWindowSubrole as String,
    attributeFetchSucceeded: Bool = true,
    sizeConstraints: WindowSizeConstraints? = nil,
    windowServer: WindowServerInfo? = nil,
    hasFullscreenButton: Bool = true,
    fullscreenButtonEnabled: Bool? = true
) -> WindowRuleFacts {
    WindowRuleFacts(
        appName: "Refresh Test App",
        ax: AXWindowFacts(
            role: role,
            subrole: subrole,
            title: title,
            hasCloseButton: true,
            hasFullscreenButton: hasFullscreenButton,
            fullscreenButtonEnabled: fullscreenButtonEnabled,
            hasZoomButton: true,
            hasMinimizeButton: true,
            appPolicy: .regular,
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded
        ),
        sizeConstraints: sizeConstraints,
        windowServer: windowServer
    )
}

private func makeRefreshReplacementMetadata(
    workspaceId: WorkspaceDescriptor.ID,
    title: String,
    bundleId: String = "com.example.refresh.restore",
    mode: TrackedWindowMode = .tiling
) -> ManagedReplacementMetadata {
    ManagedReplacementMetadata(
        bundleId: bundleId,
        workspaceId: workspaceId,
        mode: mode,
        role: kAXWindowRole as String,
        subrole: kAXStandardWindowSubrole as String,
        title: title,
        windowLevel: nil,
        parentWindowId: nil,
        frame: nil
    )
}

private func makeRefreshFrameWriteResult(
    targetFrame: CGRect,
    currentFrameHint: CGRect?,
    observedFrame: CGRect?
) -> AXFrameWriteResult {
    AXFrameWriteResult(
        targetFrame: targetFrame,
        observedFrame: observedFrame,
        writeOrder: AXWindowService.frameWriteOrder(
            currentFrame: currentFrameHint,
            targetFrame: targetFrame
        ),
        sizeError: .success,
        positionError: .success,
        failureReason: nil
    )
}

@MainActor
private func makeRefreshTestController(
    settings: SettingsStore? = nil,
    windowFocusOperations: WindowFocusOperations? = nil,
    workspaceConfigurations: [WorkspaceConfiguration] = [
        WorkspaceConfiguration(name: "1", monitorAssignment: .main),
        WorkspaceConfiguration(name: "2", monitorAssignment: .main)
    ]
) -> WMController {
    resetSharedControllerStateForTests()
    NativeFullscreenPlaceholderManager.materializesWindowsForTests = false
    let operations = windowFocusOperations ?? WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    let resolvedSettings = settings ?? SettingsStore(defaults: makeRefreshTestDefaults())
    resolvedSettings.workspaceConfigurations = workspaceConfigurations
    let controller = WMController(
        settings: resolvedSettings,
        windowFocusOperations: operations
    )
    installSynchronousFrameApplySuccessOverride(on: controller)
    let monitor = makeRefreshTestMonitor()
    controller.workspaceManager.applyMonitorConfigurationChange([monitor])
    controller.axEventHandler.windowFactsProvider = { _, _ in
        makeRefreshTestWindowFacts()
    }
    return controller
}

@MainActor
private func cleanupRefreshTestController(_ controller: WMController) {
    controller.layoutRefreshController.resetDebugState()
    controller.layoutRefreshController.resetState()
    controller.resetWorkspaceBarRefreshDebugStateForTests()
    controller.nativeFullscreenPlaceholderManager.removeAll()
    controller.axManager.currentWindowsAsyncOverride = nil
    controller.axManager.fullRescanEnumerationOverrideForTests = nil
    controller.axManager.frameApplyOverrideForTests = nil
    controller.axEventHandler.resetDebugStateForTests()
    controller.axEventHandler.isFullscreenProvider = nil
}

@MainActor
private func makeRefreshTestStatusBarController(_ controller: WMController) -> StatusBarController {
    let statusBarController = StatusBarController(
        settings: controller.settings,
        controller: controller,
        
    )
    controller.statusBarController = statusBarController
    return statusBarController
}

@MainActor
private func configureNativeFullscreenTestState(
    on controller: WMController,
    visibleWindows: VisibleWindowsStore,
    isFullscreen: Bool = false
) {
    controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
    controller.axEventHandler.isFullscreenProvider = { _ in isFullscreen }
}

@MainActor
private func waitForRefreshWork(on controller: WMController) async {
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
}

@MainActor
private func waitForSettledRefreshWork(on controller: WMController) async {
    await controller.layoutRefreshController.waitForSettledRefreshWorkForTests()
    await controller.waitForWorkspaceBarRefreshForTests()
}

@MainActor
private func niriColumnTokenSnapshot(
    controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> [[WindowToken]]? {
    guard let engine = controller.niriEngine else { return nil }
    return engine.columns(in: workspaceId).map { column in
        column.windowNodes.map(\.token)
    }
}

@MainActor
private func workspaceManagerTokenSet(
    controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> Set<WindowToken> {
    Set(controller.workspaceManager.entries(in: workspaceId).map(\.token))
}

@MainActor
private func niriTokenSet(
    controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> Set<WindowToken> {
    controller.niriEngine?.root(for: workspaceId)?.windowIdSet ?? []
}

private func replacingToken(
    _ token: WindowToken,
    with replacement: WindowToken,
    in snapshot: [[WindowToken]]
) -> [[WindowToken]] {
    snapshot.map { column in
        column.map { $0 == token ? replacement : $0 }
    }
}

private func removingToken(
    _ token: WindowToken,
    from snapshot: [[WindowToken]]
) -> [[WindowToken]] {
    snapshot.compactMap { column in
        let filtered = column.filter { $0 != token }
        return filtered.isEmpty ? nil : filtered
    }
}

@MainActor
private func workspaceBarWindowCount(
    controller: WMController,
    workspaceId: WorkspaceDescriptor.ID
) -> Int? {
    guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else {
        return nil
    }
    return controller.workspaceBarItems(
        for: monitor,
        projection: WorkspaceBarProjectionOptions(
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            showFloatingWindows: controller.settings.workspaceBarShowFloatingWindows
        )
    )
    .first { $0.id == workspaceId }?
    .windows.count
}

@MainActor
private func lastAppliedBorderWindowId(on controller: WMController) -> Int? {
    controller.focusBorderController.lastAppliedFocusedWindowIdForTests
}

@MainActor
private final class RefreshEventRecorder {
    var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
    var visibilityReasons: [RefreshReason] = []
    var fullRescanReasons: [RefreshReason] = []
    var windowRemovalReasons: [RefreshReason] = []
}

@MainActor
private final class AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class VisibleWindowsStore {
    var value: [(AXWindowRef, pid_t, Int)]

    init(_ value: [(AXWindowRef, pid_t, Int)]) {
        self.value = value
    }
}

@MainActor
private func waitUntil(
    iterations: Int = 100,
    condition: () -> Bool
) async {
    for _ in 0 ..< iterations where !condition() {
        await Task.yield()
    }

    if !condition() {
        Issue.record("Timed out waiting for condition")
    }
}

@MainActor
private func installRefreshSpies(
    on controller: WMController,
    recorder: RefreshEventRecorder
) {
    controller.layoutRefreshController.resetDebugState()
    controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
        recorder.relayoutEvents.append((reason, route))
        return true
    }
    controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
        recorder.visibilityReasons.append(reason)
        return true
    }
    controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
        recorder.fullRescanReasons.append(reason)
        return true
    }
    controller.layoutRefreshController.debugHooks.onWindowRemoval = { reason, _ in
        recorder.windowRemovalReasons.append(reason)
        return true
    }
}

@MainActor
private func resetRefreshSpies(
    on controller: WMController,
    recorder: RefreshEventRecorder
) {
    recorder.relayoutEvents.removeAll()
    recorder.visibilityReasons.removeAll()
    recorder.fullRescanReasons.removeAll()
    recorder.windowRemovalReasons.removeAll()
    installRefreshSpies(on: controller, recorder: recorder)
}

@MainActor
private func addFocusedWindow(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID,
    windowId: Int
) -> WindowHandle {
    let token = controller.workspaceManager.addWindow(
        makeRefreshTestWindow(windowId: windowId),
        pid: getpid(),
        windowId: windowId,
        to: workspaceId
    )
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Expected bridge handle for focused refresh test window")
    }
    _ = controller.workspaceManager.setManagedFocus(
        handle,
        in: workspaceId,
        onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
    )
    return handle
}

@MainActor
private func addWindow(
    on controller: WMController,
    workspaceId: WorkspaceDescriptor.ID,
    pid: pid_t,
    windowId: Int
) -> WindowHandle {
    let token = controller.workspaceManager.addWindow(
        makeRefreshTestWindow(windowId: windowId),
        pid: pid,
        windowId: windowId,
        to: workspaceId
    )
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Expected bridge handle for refresh test window")
    }
    return handle
}

@MainActor
private func assertWorkspaceSwitchCommandRequestsRememberedFocus(
    prepare: ((WMController, WorkspaceDescriptor.ID, WorkspaceDescriptor.ID, Monitor) -> Void)? = nil,
    action: (WMController) -> Void
) async {
    var focusRequests: [(pid_t, UInt32)] = []
    let controller = makeRefreshTestController(
        windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { pid, windowId, _ in
                focusRequests.append((pid, windowId))
            },
            raiseWindow: { _ in }
        )
    )
    guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
          let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
          let monitor = controller.workspaceManager.monitors.first
    else {
        Issue.record("Failed to create workspace-switch focus fixture")
        return
    }

    let sourceToken = controller.workspaceManager.addWindow(
        makeRefreshTestWindow(windowId: 401),
        pid: 4_101,
        windowId: 401,
        to: workspaceOne
    )
    _ = controller.workspaceManager.setManagedFocus(
        sourceToken,
        in: workspaceOne,
        onMonitor: monitor.id
    )

    let inactiveHiddenState = WindowModel.HiddenState(
        proportionalPosition: CGPoint(x: 0.2, y: 0.8),
        referenceMonitorId: monitor.id,
        reason: .workspaceInactive
    )
    let fallbackHandle = addWindow(on: controller, workspaceId: workspaceTwo, pid: 4_201, windowId: 402)
    let targetHandle = addWindow(on: controller, workspaceId: workspaceTwo, pid: 4_201, windowId: 403)
    controller.workspaceManager.setHiddenState(inactiveHiddenState, for: fallbackHandle.id)
    controller.workspaceManager.setHiddenState(inactiveHiddenState, for: targetHandle.id)
    _ = controller.workspaceManager.rememberFocus(targetHandle.id, in: workspaceTwo)

    prepare?(controller, workspaceOne, workspaceTwo, monitor)
    action(controller)
    await waitForRefreshWork(on: controller)
    await waitUntil {
        controller.interactionWorkspace()?.id == workspaceTwo &&
            controller.workspaceManager.activeFocusRequestToken == targetHandle.id &&
            focusRequests.contains { $0.0 == targetHandle.id.pid && $0.1 == UInt32(targetHandle.id.windowId) }
    }

    #expect(controller.interactionWorkspace()?.id == workspaceTwo)
    #expect(controller.workspaceManager.activeFocusRequestToken == targetHandle.id)
    #expect(focusRequests.contains { $0.0 == targetHandle.id.pid && $0.1 == UInt32(targetHandle.id.windowId) })
}

@MainActor
private func assertWorkspaceSwitchCommandClearsManagedFocusForEmptyTarget(
    prepare: ((WMController, WorkspaceDescriptor.ID, WorkspaceDescriptor.ID, Monitor) -> Void)? = nil,
    action: (WMController) -> Void
) async {
    var focusRequests: [(pid_t, UInt32)] = []
    let controller = makeRefreshTestController(
        windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { pid, windowId, _ in
                focusRequests.append((pid, windowId))
            },
            raiseWindow: { _ in }
        )
    )
    guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
          let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
          let monitor = controller.workspaceManager.monitors.first
    else {
        Issue.record("Failed to create empty-workspace switch fixture")
        return
    }

    let sourceToken = controller.workspaceManager.addWindow(
        makeRefreshTestWindow(windowId: 411),
        pid: 4_111,
        windowId: 411,
        to: workspaceOne
    )
    _ = controller.workspaceManager.setManagedFocus(
        sourceToken,
        in: workspaceOne,
        onMonitor: monitor.id
    )

    prepare?(controller, workspaceOne, workspaceTwo, monitor)
    action(controller)
    await waitForRefreshWork(on: controller)
    await waitUntil {
        controller.interactionWorkspace()?.id == workspaceTwo &&
            controller.workspaceManager.confirmedManagedFocusToken == nil &&
            controller.workspaceManager.activeFocusRequestToken == nil &&
            controller.workspaceManager.isNonManagedFocusActive
    }

    #expect(controller.interactionWorkspace()?.id == workspaceTwo)
    #expect(controller.workspaceManager.confirmedManagedFocusToken == nil)
    #expect(controller.workspaceManager.activeFocusRequestToken == nil)
    #expect(controller.workspaceManager.isNonManagedFocusActive)
    #expect(focusRequests.isEmpty)
}

@MainActor
private func primeFocusedBorder(on controller: WMController, handle: WindowHandle) {
    guard controller.workspaceManager.entry(for: handle) != nil else {
        fatalError("Missing entry for focused-border priming")
    }

    controller.setBordersEnabled(true)
    controller.renderKeyboardFocusBorder(
        for: controller.managedKeyboardFocusTarget(for: handle.id),
        preferredFrame: CGRect(x: 10, y: 10, width: 800, height: 600),
        forceOrdering: true
    )
}

@MainActor
private func makeTwoMonitorRefreshTestController() -> (
    controller: WMController,
    primaryMonitor: Monitor,
    secondaryMonitor: Monitor,
    primaryWorkspaceId: WorkspaceDescriptor.ID,
    secondaryWorkspaceId: WorkspaceDescriptor.ID
) {
    let controller = makeRefreshTestController(
        workspaceConfigurations: [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]
    )
    let primaryMonitor = makeLayoutPlanPrimaryTestMonitor(name: "Primary")
    let secondaryMonitor = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
    controller.workspaceManager.applyMonitorConfigurationChange([primaryMonitor, secondaryMonitor])

    guard let primaryWorkspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
          let secondaryWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false)
    else {
        fatalError("Failed to create two-monitor test fixture")
    }

    guard controller.workspaceManager.setActiveWorkspace(primaryWorkspaceId, on: primaryMonitor.id) else {
        fatalError("Failed to activate primary workspace on the primary monitor")
    }
    _ = controller.workspaceManager.setActiveWorkspace(secondaryWorkspaceId, on: secondaryMonitor.id)
    _ = controller.workspaceManager.setInteractionMonitor(primaryMonitor.id)

    return (controller, primaryMonitor, secondaryMonitor, primaryWorkspaceId, secondaryWorkspaceId)
}

@MainActor
private func prepareNiriState(
    on controller: WMController,
    assignments: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)],
    focusedWindowId: Int,
    ensureWorkspaces: Set<WorkspaceDescriptor.ID> = []
) async -> [Int: WindowHandle] {
    controller.enableNiriLayout()
    await waitForRefreshWork(on: controller)
    controller.syncMonitorsToNiriEngine()

    var handlesByWindowId: [Int: WindowHandle] = [:]
    var workspaceByWindowId: [Int: WorkspaceDescriptor.ID] = [:]

    for (workspaceId, windowId) in assignments {
        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: windowId),
            pid: getpid(),
            windowId: windowId,
            to: workspaceId
        )
        guard let handle = controller.workspaceManager.handle(for: token) else {
            fatalError("Expected bridge handle for seeded refresh window")
        }
        handlesByWindowId[windowId] = handle
        workspaceByWindowId[windowId] = workspaceId
        _ = controller.workspaceManager.rememberFocus(handle, in: workspaceId)
    }

    if let focusedHandle = handlesByWindowId[focusedWindowId],
       let focusedWorkspaceId = workspaceByWindowId[focusedWindowId]
    {
        _ = controller.workspaceManager.setManagedFocus(
            focusedHandle,
            in: focusedWorkspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: focusedWorkspaceId)
        )
    }

    guard let engine = controller.niriEngine else {
        return handlesByWindowId
    }

    let workspaceIds = Set(assignments.map(\.workspaceId)).union(ensureWorkspaces)
    syncNiriWorkspaceStatesForRefreshTests(on: controller, workspaceIds: workspaceIds, engine: engine)

    return handlesByWindowId
}

@MainActor
private func syncNiriWorkspaceStatesForRefreshTests(
    on controller: WMController,
    workspaceIds: Set<WorkspaceDescriptor.ID>,
    engine: NiriLayoutEngine? = nil
) {
    guard let engine = engine ?? controller.niriEngine else { return }

    for workspaceId in workspaceIds {
        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        let selectedNodeId = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId
        let focusedHandle = controller.workspaceManager.lastFocusedHandle(in: workspaceId)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: selectedNodeId,
            focusedHandle: focusedHandle
        )

        let resolvedSelection = focusedHandle.flatMap { engine.findNode(for: $0)?.id }
            ?? engine.validateSelection(selectedNodeId, in: workspaceId)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = resolvedSelection
        }
    }
}

@Suite(.serialized) struct RefreshRoutingTests {
    @Test func relayoutPoliciesAreExplicit() {
        #expect(RefreshReason.axWindowChanged.relayoutSchedulingPolicy == .debounced(
            nanoseconds: 8_000_000,
            dropWhileBusy: true
        ))
        #expect(RefreshReason.axWindowCreated.relayoutSchedulingPolicy == .debounced(
            nanoseconds: 4_000_000,
            dropWhileBusy: false
        ))
        #expect(RefreshReason.gapsChanged.relayoutSchedulingPolicy == .plain)
        #expect(RefreshReason.workspaceTransition.relayoutSchedulingPolicy == .plain)
        #expect(RefreshReason.windowRuleReevaluation.relayoutSchedulingPolicy == .plain)
    }

    @Test func refreshRoutesAreExplicit() {
        #expect(RefreshReason.appLaunched.requestRoute == .fullRescan)
        #expect(RefreshReason.gapsChanged.requestRoute == .relayout)
        #expect(RefreshReason.workspaceTransition.requestRoute == .immediateRelayout)
        #expect(RefreshReason.appHidden.requestRoute == .visibilityRefresh)
        #expect(RefreshReason.appUnhidden.requestRoute == .visibilityRefresh)
        #expect(RefreshReason.windowDestroyed.requestRoute == .windowRemoval)
        #expect(RefreshReason.windowRuleReevaluation.requestRoute == .relayout)
    }

    @Test @MainActor func startupRestorePreservesPersistedNiriStackedColumnsAndWidths() async throws {
        try await withAXFrameProviderIsolationForTests {
            let defaults = makeRefreshTestDefaults()
            let workspaceConfigurations = [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main)
            ]
            let bundleId = "com.example.refresh.niri.restore"
            let titlesByInitialWindowId = [
                6_101: "Launch Restore A",
                6_102: "Launch Restore B",
                6_103: "Launch Restore C"
            ]
            let titlesByRelaunchedWindowId = [
                6_201: "Launch Restore A",
                6_202: "Launch Restore B",
                6_203: "Launch Restore C"
            ]

            do {
                let initialSettings = SettingsStore(defaults: defaults)
                let initialController = makeRefreshTestController(
                    settings: initialSettings,
                    workspaceConfigurations: workspaceConfigurations
                )
                defer { cleanupRefreshTestController(initialController) }
                initialController.enableNiriLayout()
                await waitForRefreshWork(on: initialController)
                initialController.syncMonitorsToNiriEngine()

                guard let workspaceId = initialController.interactionWorkspace()?.id,
                      let monitor = initialController.workspaceManager.monitor(for: workspaceId),
                      let engine = initialController.niriEngine
                else {
                    Issue.record("Missing initial Niri restore fixture")
                    return
                }

                var tokensByTitle: [String: WindowToken] = [:]
                for (windowId, title) in titlesByInitialWindowId {
                    let token = initialController.workspaceManager.addWindow(
                        makeRefreshTestWindow(windowId: windowId),
                        pid: getpid(),
                        windowId: windowId,
                        to: workspaceId,
                        managedReplacementMetadata: makeRefreshReplacementMetadata(
                            workspaceId: workspaceId,
                            title: title,
                            bundleId: bundleId
                        )
                    )
                    initialController.workspaceManager.setCachedConstraints(.unconstrained, for: token)
                    tokensByTitle[title] = token
                }

                let tokenA = try #require(tokensByTitle["Launch Restore A"])
                let tokenB = try #require(tokensByTitle["Launch Restore B"])
                let tokenC = try #require(tokensByTitle["Launch Restore C"])

                let root = NiriRoot(workspaceId: workspaceId)
                let firstColumn = NiriContainer()
                firstColumn.width = .fixed(480)
                firstColumn.cachedWidth = 480
                let secondColumn = NiriContainer()
                secondColumn.width = .fixed(720)
                secondColumn.cachedWidth = 720
                root.appendChild(firstColumn)
                root.appendChild(secondColumn)
                engine.roots[workspaceId] = root
                engine.ensureMonitor(for: monitor.id, monitor: monitor).workspaceRoots[workspaceId] = root

                for token in [tokenA, tokenB] {
                    let window = NiriWindow(token: token)
                    firstColumn.appendChild(window)
                    engine.tokenToNode[token] = window
                }
                let windowC = NiriWindow(token: tokenC)
                secondColumn.appendChild(windowC)
                engine.tokenToNode[tokenC] = windowC

                initialController.layoutRefreshController.requestRelayout(
                    reason: .gapsChanged,
                    affectedWorkspaceIds: [workspaceId]
                )
                await waitForSettledRefreshWork(on: initialController)

                let persistedEntries = initialController.workspaceManager.persistedWindowRestoreCatalogForTests()
                    .entries
                #expect(persistedEntries.count == 3)
                #expect(persistedEntries.allSatisfy { $0.restoreIntent.niriPlacement != nil })

                initialController.workspaceManager.flushPersistedWindowRestoreCatalogNow()
                initialSettings.flushNow()
            }

            let relaunchedSettings = SettingsStore(defaults: defaults)
            let relaunchedController = makeRefreshTestController(
                settings: relaunchedSettings,
                workspaceConfigurations: workspaceConfigurations
            )
            defer { cleanupRefreshTestController(relaunchedController) }
            relaunchedController.axEventHandler.windowFactsProvider = { axRef, _ in
                makeRefreshTestWindowFacts(
                    bundleId: bundleId,
                    title: titlesByRelaunchedWindowId[axRef.windowId]
                )
            }
            relaunchedController.axManager.currentWindowsAsyncOverride = {
                titlesByRelaunchedWindowId.keys.sorted().map { windowId in
                    (makeRefreshTestWindow(windowId: windowId), getpid(), windowId)
                }
            }
            relaunchedController.enableNiriLayout()
            await waitForRefreshWork(on: relaunchedController)
            let bootEntries = relaunchedController.workspaceManager.bootPersistedWindowRestoreCatalogForTests().entries
            #expect(bootEntries.count == 3)
            #expect(Set(bootEntries.compactMap(\.key.title)) == Set(titlesByInitialWindowId.values))

            relaunchedController.layoutRefreshController.requestFullRescan(reason: .startup)
            await waitForSettledRefreshWork(on: relaunchedController)

            guard let restoredWorkspaceId = relaunchedController.workspaceManager.workspaceId(
                for: "1",
                createIfMissing: false
            ),
                  let engine = relaunchedController.niriEngine
            else {
                Issue.record("Missing relaunched Niri restore fixture")
                return
            }

            let restoredTokenA = WindowToken(pid: getpid(), windowId: 6_201)
            let restoredTokenB = WindowToken(pid: getpid(), windowId: 6_202)
            let restoredTokenC = WindowToken(pid: getpid(), windowId: 6_203)
            #expect(Set(relaunchedController.workspaceManager.allEntries().compactMap(\.managedReplacementMetadata?.bundleId)) == [bundleId])
            #expect(Set(relaunchedController.workspaceManager.allEntries().compactMap(\.managedReplacementMetadata?.title)) == Set(titlesByRelaunchedWindowId.values))
            #expect(relaunchedController.workspaceManager.consumedBootPersistedWindowRestoreEntryCountForTests() == 3)
            #expect(workspaceManagerTokenSet(controller: relaunchedController, workspaceId: restoredWorkspaceId) == Set([
                restoredTokenA,
                restoredTokenB,
                restoredTokenC
            ]))
            #expect(niriColumnTokenSnapshot(controller: relaunchedController, workspaceId: restoredWorkspaceId) == [
                [restoredTokenA, restoredTokenB],
                [restoredTokenC]
            ])

            let restoredColumns = engine.columns(in: restoredWorkspaceId)
            #expect(restoredColumns.count == 2)
            if restoredColumns.count == 2 {
                #expect(abs(restoredColumns[0].cachedWidth - 480) < 0.5)
                #expect(abs(restoredColumns[1].cachedWidth - 720) < 0.5)
            }
        }
    }

    @Test @MainActor func workspaceBarRefreshRequestsCoalesceOnNextMainTurn() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }

        controller.requestWorkspaceBarRefresh()
        controller.requestWorkspaceBarRefresh()
        controller.requestWorkspaceBarRefresh()

        #expect(controller.workspaceBarRefreshDebugState.requestCount == 3)
        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 0)
        #expect(controller.workspaceBarRefreshDebugState.isQueued)

        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)
        #expect(!controller.workspaceBarRefreshDebugState.isQueued)
    }

    @Test @MainActor func fullRescanFallbackFloatingDoesNotRetileExistingNiriParent() async {
        let bundleId = "com.example.full-rescan-parent"
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let rule = AppRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000864")!,
            bundleId: bundleId,
            assignToWorkspace: "2"
        )
        controller.windowRuleEngine.rebuild(rules: [rule])
        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        let effects = ManagedWindowRuleEffects(matchedRuleId: rule.id)
        let parentToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 860),
            pid: getpid(),
            windowId: 860,
            to: workspaceId,
            mode: .tiling,
            ruleEffects: effects
        )
        let siblingToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 861),
            pid: getpid(),
            windowId: 861,
            to: workspaceId,
            mode: .tiling
        )
        let parentNode = engine.addWindow(token: parentToken, to: workspaceId, afterSelection: nil, focusedToken: parentToken)
        _ = engine.addWindow(token: siblingToken, to: workspaceId, afterSelection: parentNode.id, focusedToken: parentToken)
        guard let parentColumn = engine.column(of: parentNode),
              let parentColumnIndex = engine.columnIndex(of: parentColumn, in: workspaceId)
        else {
            Issue.record("Missing parent Niri column")
            return
        }
        parentColumn.width = .fixed(640)
        parentColumn.cachedWidth = 640
        let originalParentNodeId = parentNode.id
        let originalParentColumnWidth = parentColumn.width
        let originalParentCachedWidth = parentColumn.cachedWidth

        controller.axManager.currentWindowsAsyncOverride = {
            [
                (makeRefreshTestWindow(windowId: 860), getpid(), 860),
                (makeRefreshTestWindow(windowId: 861), getpid(), 861)
            ]
        }
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            makeRefreshTestWindowFacts(
                bundleId: bundleId,
                title: axRef.windowId == 860 ? "Parent" : "Sibling",
                hasFullscreenButton: axRef.windowId != 860
            )
        }

        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let updatedParentNode = engine.findNode(for: parentToken),
              let updatedParentColumn = engine.column(of: updatedParentNode)
        else {
            Issue.record("Missing updated parent Niri state")
            return
        }

        #expect(controller.workspaceManager.entry(for: parentToken)?.mode == .tiling)
        #expect(updatedParentNode.id == originalParentNodeId)
        #expect(engine.columnIndex(of: updatedParentColumn, in: workspaceId) == parentColumnIndex)
        #expect(updatedParentColumn.width == originalParentColumnWidth)
        #expect(abs(updatedParentColumn.cachedWidth - originalParentCachedWidth) < 0.5)
    }

    @Test @MainActor func workspaceBarRefreshRunsAfterPostLayoutActions() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }

        var eventOrder: [String] = []
        var executionCountDuringPostLayout = -1
        controller.workspaceBarRefreshExecutionHookForTests = {
            eventOrder.append("workspaceBar")
        }

        controller.layoutRefreshController.commitWorkspaceTransition(
            reason: .workspaceTransition
        ) {
            executionCountDuringPostLayout = controller.workspaceBarRefreshDebugState.executionCount
            eventOrder.append("postLayout")
        }

        await waitForRefreshWork(on: controller)

        #expect(executionCountDuringPostLayout == 0)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 0)
        #expect(controller.workspaceBarRefreshDebugState.isQueued)

        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(eventOrder == ["postLayout", "workspaceBar"])
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)
    }

    @Test @MainActor func tabbedOverlayRefreshRunsAfterPostLayoutActions() async {
        let controller = makeRefreshTestController()
        defer {
            controller.tabbedOverlayManager.removeAll()
            cleanupRefreshTestController(controller)
        }

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Expected active workspace")
            return
        }

        _ = await prepareNiriState(
            on: controller,
            assignments: [(workspaceId: workspaceId, windowId: 711)],
            focusedWindowId: 711
        )

        var eventOrder: [String] = []
        controller.tabbedOverlayManager.disablesWindowUpdatesForTests = true
        controller.tabbedOverlayManager.updateHookForTests = { _, forceOrdering in
            eventOrder.append(forceOrdering ? "tabbedOverlayForced" : "tabbedOverlay")
        }

        controller.layoutRefreshController.commitWorkspaceTransition(
            reason: .workspaceTransition
        ) {
            eventOrder.append("postLayout")
        }

        await waitForRefreshWork(on: controller)

        #expect(eventOrder == ["postLayout", "tabbedOverlayForced"])
    }

    @Test @MainActor func tabbedOverlayAnimationDirectiveForcesOrdering() async {
        let controller = makeRefreshTestController()
        defer {
            controller.tabbedOverlayManager.removeAll()
            cleanupRefreshTestController(controller)
        }

        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.interactionWorkspace()?.id
        else {
            Issue.record("Expected active workspace")
            return
        }

        _ = await prepareNiriState(
            on: controller,
            assignments: [(workspaceId: workspaceId, windowId: 713)],
            focusedWindowId: 713
        )

        var forceOrderingValues: [Bool] = []
        controller.tabbedOverlayManager.disablesWindowUpdatesForTests = true
        controller.tabbedOverlayManager.updateHookForTests = { _, forceOrdering in
            forceOrderingValues.append(forceOrdering)
        }

        let plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId),
            diff: WorkspaceLayoutDiff(),
            animationDirectives: [.updateTabbedOverlays]
        )

        controller.layoutRefreshController.executeLayoutPlan(plan)

        #expect(forceOrderingValues == [true])
    }

    @Test @MainActor func queuedWorkspaceBarRefreshIsCanceledDuringUICleanup() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }

        controller.requestWorkspaceBarRefresh()
        #expect(controller.workspaceBarRefreshDebugState.isQueued)

        controller.cleanupUIOnStop()
        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(controller.workspaceBarRefreshDebugState.executionCount == 0)
        #expect(!controller.workspaceBarRefreshDebugState.isQueued)
    }

    @Test @MainActor func unlockAndWorkspaceConfigUseSingleDeferredWorkspaceBarRefresh() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }

        let lifecycleManager = ServiceLifecycleManager(controller: controller)

        controller.resetWorkspaceBarRefreshDebugStateForTests()
        lifecycleManager.handleUnlockDetected()
        await waitForRefreshWork(on: controller)
        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(controller.workspaceBarRefreshDebugState.requestCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)

        controller.resetWorkspaceBarRefreshDebugStateForTests()
        controller.updateWorkspaceConfig()
        await waitForRefreshWork(on: controller)
        await controller.waitForWorkspaceBarRefreshForTests()

        #expect(controller.workspaceBarRefreshDebugState.requestCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)
    }

    @Test @MainActor func focusOnlyChangesRefreshStatusBarWithoutWorkspaceBarQueue() {
        let controller = makeRefreshTestController()
        controller.settings.workspaceBarEnabled = false
        controller.settings.statusBarShowWorkspaceName = true
        controller.settings.statusBarShowAppNames = true

        guard let monitor = controller.monitorForInteraction(),
              let workspaceId = controller.interactionWorkspace()?.id
        else {
            Issue.record("Missing active workspace for status bar refresh routing test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 501),
            pid: 501,
            windowId: 501,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 502),
            pid: 502,
            windowId: 502,
            to: workspaceId
        )
        controller.appInfoCache.storeInfoForTests(pid: 501, name: "First App", bundleId: "com.example.first")
        controller.appInfoCache.storeInfoForTests(pid: 502, name: "Second App", bundleId: "com.example.second")
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let statusBarController = makeRefreshTestStatusBarController(controller)
        defer {
            statusBarController.cleanup()
            cleanupRefreshTestController(controller)
        }
        statusBarController.setup()
        #expect(statusBarController.statusButtonTitleForTests() == " 1 \u{2013} First App")

        controller.resetWorkspaceBarRefreshDebugStateForTests()
        _ = controller.workspaceManager.setManagedFocus(secondToken, in: workspaceId, onMonitor: monitor.id)

        #expect(controller.workspaceBarRefreshDebugState.requestCount == 0)
        #expect(statusBarController.statusButtonTitleForTests() == " 1 \u{2013} Second App")
    }

    @Test @MainActor func interactionMonitorChangeOnUnassignedThirdDisplayDoesNotRecurseAfterMonitorExpansion() {
        let controller = makeRefreshTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
            ]
        )
        let primary = makeRefreshTestMonitor(displayId: layoutPlanTestMainDisplayId(), name: "Primary", x: 0, y: 0)
        let secondary = makeRefreshTestMonitor(
            displayId: layoutPlanTestSyntheticDisplayId(1),
            name: "Secondary",
            x: 1920,
            y: 0
        )
        controller.workspaceManager.applyMonitorConfigurationChange([primary, secondary])
        controller.settings.statusBarShowWorkspaceName = true

        let statusBarController = makeRefreshTestStatusBarController(controller)
        defer {
            statusBarController.cleanup()
            cleanupRefreshTestController(controller)
        }
        statusBarController.setup()

        let third = makeRefreshTestMonitor(displayId: layoutPlanTestSyntheticDisplayId(2), name: "Third", x: 3840, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([primary, secondary, third])

        var sessionChangeCount = 0
        let originalOnSessionStateChanged = controller.workspaceManager.onSessionStateChanged
        controller.workspaceManager.onSessionStateChanged = {
            sessionChangeCount += 1
            originalOnSessionStateChanged?()
        }

        #expect(controller.workspaceManager.setInteractionMonitor(third.id))
        #expect(sessionChangeCount == 1)
        #expect(statusBarController.statusButtonTitleForTests() == "")
        #expect(statusBarController.statusButtonImagePositionForTests() == .imageOnly)
    }

    @Test @MainActor func niriConfigAndEnableUseRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 0)
        #expect(recorder.relayoutEvents.map(\.0) == [.layoutConfigChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)

        resetRefreshSpies(on: controller, recorder: recorder)

        controller.updateNiriConfig(maxVisibleColumns: 3)
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 0)
        #expect(recorder.relayoutEvents.map(\.0) == [.layoutConfigChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func workspaceTransitionFlowsUseImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.focusWorkspaceFromBar(named: "2")
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func workspaceSwitchUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func reselectingActiveWorkspaceDoesNotTriggerRefreshOrClearBorder() async {
        let controller = makeRefreshTestController()
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Failed to create active workspace reselect fixture")
            return
        }

        let handles = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceOne, 352),
                (workspaceTwo, 353)
            ],
            focusedWindowId: 352,
            ensureWorkspaces: [workspaceTwo]
        )
        guard let targetHandle = handles[353] else {
            Issue.record("Missing target workspace handle")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(workspaceTwo, on: monitor.id))
        #expect(controller.workspaceManager.setManagedFocus(
            targetHandle.id,
            in: workspaceTwo,
            onMonitor: monitor.id
        ))
        primeFocusedBorder(on: controller, handle: targetHandle)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        let previousFocusedToken = controller.workspaceManager.confirmedManagedFocusToken
        let previousBorderWindowId = lastAppliedBorderWindowId(on: controller)

        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForRefreshWork(on: controller)

        #expect(controller.interactionWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == previousFocusedToken)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == targetHandle.id)
        #expect(lastAppliedBorderWindowId(on: controller) == previousBorderWindowId)
        #expect(lastAppliedBorderWindowId(on: controller) == targetHandle.windowId)
        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(recorder.windowRemovalReasons.isEmpty)
    }

    @Test @MainActor func crossMonitorWorkspaceSwitchSkipsAnimationWhenTargetIsAlreadyVisible() async {
        let fixture = makeTwoMonitorRefreshTestController()
        _ = await prepareNiriState(
            on: fixture.controller,
            assignments: [
                (fixture.primaryWorkspaceId, 350),
                (fixture.secondaryWorkspaceId, 351)
            ],
            focusedWindowId: 350,
            ensureWorkspaces: [fixture.secondaryWorkspaceId]
        )

        fixture.controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForRefreshWork(on: fixture.controller)

        #expect(fixture.controller.niriLayoutHandler
            .scrollAnimationByDisplay[fixture.secondaryMonitor.displayId] == nil)
    }

    @Test @MainActor func sameMonitorWorkspaceSwitchSkipsAnimationWhenTargetWasHidden() async {
        let controller = makeRefreshTestController()
        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Failed to create single-monitor workspace switch fixture")
            return
        }

        _ = await prepareNiriState(
            on: controller,
            assignments: [
                (ws1, 352),
                (ws2, 353)
            ],
            focusedWindowId: 352,
            ensureWorkspaces: [ws2]
        )

        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForRefreshWork(on: controller)

        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
    }

    @Test @MainActor func workspaceRelativeSwitchUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func focusWorkspaceAnywhereUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.workspaceNavigationHandler.focusWorkspaceAnywhere(index: 1)
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func workspaceBackAndForthUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForRefreshWork(on: controller)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.workspaceNavigationHandler.workspaceBackAndForth()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func workspaceSwitchCommandsRequestRememberedTargetFocus() async {
        await assertWorkspaceSwitchCommandRequestsRememberedFocus { controller in
            controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        }
        await assertWorkspaceSwitchCommandRequestsRememberedFocus { controller in
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        }
        await assertWorkspaceSwitchCommandRequestsRememberedFocus { controller in
            controller.workspaceNavigationHandler.focusWorkspaceAnywhere(index: 1)
        }
        await assertWorkspaceSwitchCommandRequestsRememberedFocus(
            prepare: { controller, workspaceOne, workspaceTwo, monitor in
                _ = controller.workspaceManager.setActiveWorkspace(workspaceTwo, on: monitor.id)
                _ = controller.workspaceManager.setActiveWorkspace(workspaceOne, on: monitor.id)
            }
        ) { controller in
            controller.workspaceNavigationHandler.workspaceBackAndForth()
        }
    }

    @Test @MainActor func workspaceSwitchCommandsClearManagedFocusForEmptyTargets() async {
        await assertWorkspaceSwitchCommandClearsManagedFocusForEmptyTarget { controller in
            controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        }
        await assertWorkspaceSwitchCommandClearsManagedFocusForEmptyTarget { controller in
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        }
        await assertWorkspaceSwitchCommandClearsManagedFocusForEmptyTarget { controller in
            controller.workspaceNavigationHandler.focusWorkspaceAnywhere(index: 1)
        }
        await assertWorkspaceSwitchCommandClearsManagedFocusForEmptyTarget(
            prepare: { controller, workspaceOne, workspaceTwo, monitor in
                _ = controller.workspaceManager.setActiveWorkspace(workspaceTwo, on: monitor.id)
                _ = controller.workspaceManager.setActiveWorkspace(workspaceOne, on: monitor.id)
            }
        ) { controller in
            controller.workspaceNavigationHandler.workspaceBackAndForth()
        }
    }

    @Test @MainActor func movingFocusedWindowUpdatesCachedFocusTargetWorkspace() async {
        let controller = makeRefreshTestController()
        controller.setBordersEnabled(true)
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Failed to create focused-target sync fixture")
            return
        }

        let handles = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceOne, 415)
            ],
            focusedWindowId: 415,
            ensureWorkspaces: [workspaceTwo]
        )
        guard let focusedHandle = handles[415] else {
            Issue.record("Missing focused window handle")
            return
        }

        controller.renderKeyboardFocusBorder(
            for: controller.managedKeyboardFocusTarget(for: focusedHandle.id),
            preferredFrame: CGRect(x: 20, y: 20, width: 640, height: 480),
            forceOrdering: true
        )

        var animatingState = controller.workspaceManager.niriViewportState(for: workspaceOne)
        animatingState.viewOffsetPixels = .spring(
            SpringAnimation(
                from: 0,
                to: 120,
                startTime: 0,
                config: .snappy
            )
        )
        controller.workspaceManager.updateNiriViewportState(animatingState, for: workspaceOne)

        #expect(controller.workspaceNavigationHandler.moveWindow(handle: focusedHandle, toWorkspaceId: workspaceTwo))
        #expect(controller.currentBorderTarget()?.workspaceId == workspaceTwo)

        let rendered = controller.renderKeyboardFocusBorder(
            preferredFrame: CGRect(x: 20, y: 20, width: 640, height: 480)
        )

        #expect(rendered)
        #expect(lastAppliedBorderWindowId(on: controller) == 415)
    }

    @Test @MainActor func summonWindowRightIntoNiriUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        guard let targetWorkspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing target workspace for Niri summon-right test")
            return
        }

        let handles = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceId: targetWorkspaceId, windowId: 9101),
                (workspaceId: targetWorkspaceId, windowId: 9102),
                (workspaceId: targetWorkspaceId, windowId: 9103)
            ],
            focusedWindowId: 9101
        )
        guard let summonedHandle = handles[9102] else {
            Issue.record("Missing summoned handle for Niri summon-right test")
            return
        }

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.windowActionHandler.summonWindowRight(handle: summonedHandle)
        await waitForRefreshWork(on: controller)

        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine after summon-right test setup")
            return
        }

        let orderedWindowIds = engine.columns(in: targetWorkspaceId).compactMap { $0.windowNodes.first?.token.windowId }

        #expect(recorder.relayoutEvents.map(\.0) == [.layoutCommand])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(controller.workspaceManager.rememberedTiledFocusToken(in: targetWorkspaceId)?.windowId == 9102)
        #expect(orderedWindowIds == [9101, 9102, 9103])
    }

    @Test @MainActor func paletteSummonWindowRightIntoNiriUsesCapturedAnchorWhenManagedFocusIsNil() async {
        let controller = makeRefreshTestController()
        guard let targetWorkspaceId = controller.interactionWorkspace()?.id,
              let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspace for palette summon-right Niri test")
            return
        }

        let handles = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceId: targetWorkspaceId, windowId: 9301),
                (workspaceId: targetWorkspaceId, windowId: 9303),
                (workspaceId: sourceWorkspaceId, windowId: 9302)
            ],
            focusedWindowId: 9301
        )
        guard let anchorHandle = handles[9301],
              let summonedHandle = handles[9302]
        else {
            Issue.record("Missing handles for palette summon-right Niri test")
            return
        }

        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.windowActionHandler.summonWindowRight(
            handle: summonedHandle,
            anchorToken: anchorHandle.id,
            anchorWorkspaceId: targetWorkspaceId
        )
        await waitForRefreshWork(on: controller)

        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine after palette summon-right test")
            return
        }

        let orderedWindowIds = engine.columns(in: targetWorkspaceId).compactMap { $0.windowNodes.first?.token.windowId }

        #expect(recorder.relayoutEvents.map(\.0) == [.layoutCommand])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(controller.workspaceManager.workspace(for: summonedHandle.id) == targetWorkspaceId)
        #expect(controller.workspaceManager.rememberedTiledFocusToken(in: targetWorkspaceId)?.windowId == 9302)
        #expect(orderedWindowIds == [9301, 9302, 9303])
    }

    @Test @MainActor func paletteSummonWindowRightIntoNiriNoOpsWhenAnchorDisappears() async {
        let controller = makeRefreshTestController()
        guard let targetWorkspaceId = controller.interactionWorkspace()?.id,
              let sourceWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspace for stale-anchor Niri test")
            return
        }

        let handles = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceId: targetWorkspaceId, windowId: 9401),
                (workspaceId: sourceWorkspaceId, windowId: 9402)
            ],
            focusedWindowId: 9401
        )
        guard let anchorHandle = handles[9401],
              let summonedHandle = handles[9402]
        else {
            Issue.record("Missing handles for stale-anchor Niri test")
            return
        }

        _ = controller.workspaceManager.removeWindow(
            pid: anchorHandle.pid,
            windowId: anchorHandle.windowId
        )

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.windowActionHandler.summonWindowRight(
            handle: summonedHandle,
            anchorToken: anchorHandle.id,
            anchorWorkspaceId: targetWorkspaceId
        )
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(controller.workspaceManager.workspace(for: summonedHandle.id) == sourceWorkspaceId)
    }

    @Test @MainActor func inactiveWorkspaceAppActivationUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        guard let workspaceTwo else {
            Issue.record("Failed to create target workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 202),
            pid: getpid(),
            windowId: 202,
            to: workspaceTwo
        )
        guard let handle = controller.workspaceManager.handle(for: token) else {
            Issue.record("Failed to create bridge handle")
            return
        }
        guard let entry = controller.workspaceManager.entry(for: handle) else {
            Issue.record("Failed to create managed entry")
            return
        }

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: false,
            appFullscreen: false
        )
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.appActivationTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func inactiveWorkspaceHandleAppActivationUsesImmediateRelayoutOnly() async {
        let controller = makeRefreshTestController()
        controller.hasStartedServices = true
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Failed to create inactive-workspace app-activation fixture")
            return
        }

        let sourceToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 211),
            pid: 2_211,
            windowId: 211,
            to: workspaceOne
        )
        _ = controller.workspaceManager.setManagedFocus(
            sourceToken,
            in: workspaceOne,
            onMonitor: monitor.id
        )

        let targetPid: pid_t = 2_212
        let targetToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 212),
            pid: targetPid,
            windowId: 212,
            to: workspaceTwo
        )
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == targetPid else { return nil }
            return makeRefreshTestWindow(windowId: targetToken.windowId)
        }

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.axEventHandler.handleAppActivation(
            pid: targetPid,
            source: .workspaceDidActivateApplication
        )
        await waitForRefreshWork(on: controller)

        #expect(controller.interactionWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == targetToken)
        #expect(recorder.relayoutEvents.map(\.0) == [.appActivationTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func inactiveWorkspaceHandleAppActivationRevealsHiddenWindow() async {
        let controller = makeRefreshTestController()
        controller.hasStartedServices = true
        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Failed to create inactive-workspace reveal fixture")
            return
        }

        let sourcePid: pid_t = 2_311
        let targetPid: pid_t = 2_312
        let sourceToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 311),
            pid: sourcePid,
            windowId: 311,
            to: workspaceOne
        )
        let targetToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 312),
            pid: targetPid,
            windowId: 312,
            to: workspaceTwo
        )
        _ = controller.workspaceManager.rememberFocus(sourceToken, in: workspaceOne)
        _ = controller.workspaceManager.rememberFocus(targetToken, in: workspaceTwo)
        _ = controller.workspaceManager.setManagedFocus(
            sourceToken,
            in: workspaceOne,
            onMonitor: monitor.id
        )
        syncNiriWorkspaceStatesForRefreshTests(
            on: controller,
            workspaceIds: [workspaceOne, workspaceTwo]
        )

        let hiddenFrame = CGRect(x: -1400, y: 140, width: 760, height: 520)
        controller.axManager.applyFramesParallel([(targetPid, targetToken.windowId, hiddenFrame)])
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: targetToken, monitor: monitor)
        controller.axManager.markWindowInactive(targetToken.windowId)
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == targetPid else { return nil }
            return makeRefreshTestWindow(windowId: targetToken.windowId)
        }

        controller.axEventHandler.handleAppActivation(
            pid: targetPid,
            source: .workspaceDidActivateApplication
        )
        await waitForRefreshWork(on: controller)

        #expect(controller.interactionWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.confirmedManagedFocusToken == targetToken)
        #expect(controller.workspaceManager.hiddenState(for: targetToken) == nil)
        #expect(!controller.axManager.inactiveWorkspaceWindowIds.contains(targetToken.windowId))

        guard let appliedFrame = controller.axManager.lastAppliedFrame(for: targetToken.windowId) else {
            Issue.record("Expected visible frame for activated hidden window")
            return
        }
        #expect(monitor.visibleFrame.contains(CGPoint(x: appliedFrame.midX, y: appliedFrame.midY)))
    }

    @Test @MainActor func activeSpaceChangeDoesNotFrameWriteNativeFullscreenSuspendedWindowInNiri() async {
        let controller = makeRefreshTestController()
        defer { controller.nativeFullscreenPlaceholderManager.removeAll() }
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        controller.axManager.currentWindowsAsyncOverride = { [] }
        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 2601),
            pid: getpid(),
            windowId: 2601,
            to: workspaceId
        )
        _ = controller.workspaceManager.rememberFocus(token, in: workspaceId)
        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

        lifecycleManager.handleActiveSpaceDidChange()
        await waitForRefreshWork(on: controller)

        #expect(controller.axManager.lastAppliedFrame(for: 2601) == nil)
        #expect(controller.nativeFullscreenPlaceholderManager.snapshotForTests()[token] != nil)
        #expect(controller.workspaceManager.entry(for: token) != nil)
        #expect(controller.workspaceManager.layoutReason(for: token) == .nativeFullscreen)
    }

    @Test @MainActor func nativeFullscreenDestroyImmediatelyRetainsPlaceholderInNiri() async {
        let controller = makeRefreshTestController()
        defer { controller.nativeFullscreenPlaceholderManager.removeAll() }
        controller.axManager.currentWindowsAsyncOverride = { [] }
        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 2602),
            pid: getpid(),
            windowId: 2602,
            to: workspaceId
        )
        _ = controller.workspaceManager.rememberFocus(token, in: workspaceId)
        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

        controller.axEventHandler.handleRemoved(token: token)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.nativeFullscreenRecord(for: token)?.availability == .temporarilyUnavailable)
        #expect(controller.nativeFullscreenPlaceholderManager.snapshotForTests()[token] != nil)
        #expect(controller.workspaceManager.entry(for: token) != nil)
        #expect(controller.workspaceManager.layoutReason(for: token) == .nativeFullscreen)
    }

    @Test @MainActor func workspaceTransitionRestoresWorkspaceInactiveFloatingWindowsOnlyOnNewlyVisibleWorkspace()
        async throws
    {
        let controller = makeRefreshTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main),
                WorkspaceConfiguration(name: "3", monitorAssignment: .main)
            ]
        )
        defer { cleanupRefreshTestController(controller) }
        let workspaceOne = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        let workspaceTwo = try #require(controller.workspaceManager.workspaceId(for: "2", createIfMissing: false))
        let workspaceThree = try #require(controller.workspaceManager.workspaceId(for: "3", createIfMissing: false))
        let monitor = try #require(controller.workspaceManager.monitor(for: workspaceOne))
        #expect(controller.workspaceManager.setActiveWorkspace(workspaceOne, on: monitor.id))
        _ = controller.workspaceManager.setInteractionMonitor(monitor.id)

        let targetFrame = CGRect(x: 260, y: 180, width: 520, height: 360)
        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 2603),
            pid: getpid(),
            windowId: 2603,
            to: workspaceTwo,
            mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: targetFrame,
            for: token,
            referenceMonitor: monitor
        )
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(
            on: controller,
            token: token,
            monitor: monitor
        )
        controller.axManager.markWindowInactive(token.windowId)
        controller.axManager.suppressFrameWrites([(token.pid, token.windowId)])

        let hiddenToken = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 2604),
            pid: getpid(),
            windowId: 2604,
            to: workspaceThree,
            mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: CGRect(x: 420, y: 260, width: 460, height: 300),
            for: hiddenToken,
            referenceMonitor: monitor
        )
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(
            on: controller,
            token: hiddenToken,
            monitor: monitor
        )
        controller.axManager.markWindowInactive(hiddenToken.windowId)
        controller.axManager.suppressFrameWrites([(hiddenToken.pid, hiddenToken.windowId)])

        controller.workspaceNavigationHandler.switchWorkspace(index: 1)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.interactionWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(!controller.axManager.inactiveWorkspaceWindowIds.contains(token.windowId))
        #expect(controller.axManager.lastAppliedFrame(for: token.windowId) == targetFrame)
        #expect(controller.workspaceManager.hiddenState(for: hiddenToken)?.workspaceInactive == true)
        #expect(controller.axManager.inactiveWorkspaceWindowIds.contains(hiddenToken.windowId))
        #expect(controller.axManager.lastAppliedFrame(for: hiddenToken.windowId) == nil)
    }

    @Test @MainActor func hideInactiveWorkspacesSkipsNativeFullscreenRealWindowMoves() async {
        await withAXFrameProviderIsolationForTests {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let monitor = controller.workspaceManager.monitor(for: workspaceTwo)
        else {
            Issue.record("Missing inactive workspace fixture")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: 2602),
            pid: getpid(),
            windowId: 2602,
            to: workspaceTwo
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceTwo)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        controller.nativeFullscreenPlaceholderManager.update(
            placeholders: [
                NativeFullscreenPlaceholderUpdate(
                    token: token,
                    workspaceId: workspaceTwo,
                    frame: CGRect(x: 200, y: 160, width: 600, height: 420),
                    selected: false,
                    appName: "Inactive Full Screen",
                    icon: nil
                )
            ],
            in: workspaceTwo
        )

        let previousFastFrameProvider = AXWindowService.fastFrameProviderForTests
        let previousSetFrameProvider = AXWindowService.setFrameResultProviderForTests
        let nativeFrame = CGRect(x: monitor.visibleFrame.minX + 40, y: monitor.visibleFrame.minY + 50, width: 620, height: 430)
        var frameWrites: [CGRect] = []
        AXWindowService.fastFrameProviderForTests = { axRef in
            if axRef.windowId == token.windowId {
                return nativeFrame
            }
            return previousFastFrameProvider?(axRef)
        }
        AXWindowService.setFrameResultProviderForTests = { axRef, frame, currentFrameHint in
            if axRef.windowId == token.windowId {
                frameWrites.append(frame)
            }
            return previousSetFrameProvider?(axRef, frame, currentFrameHint) ?? makeRefreshFrameWriteResult(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                observedFrame: frame
            )
        }
        defer {
            AXWindowService.fastFrameProviderForTests = previousFastFrameProvider
            AXWindowService.setFrameResultProviderForTests = previousSetFrameProvider
        }

        controller.layoutRefreshController.hideInactiveWorkspaces(activeWorkspaceIds: [workspaceOne])

        #expect(frameWrites.isEmpty)
        #expect(controller.nativeFullscreenPlaceholderManager.snapshotForTests()[token] == nil)
        #expect(controller.axManager.inactiveWorkspaceWindowIds.contains(token.windowId))
        #expect(controller.workspaceManager.layoutReason(for: token) == .nativeFullscreen)
        }
    }

    @Test @MainActor func nativeFullscreenExitRestoresPriorManagedFrameInNiri() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeRefreshTestController()
            defer { cleanupRefreshTestController(controller) }
            let visibleWindows = VisibleWindowsStore([
                (makeRefreshTestWindow(windowId: 2611), getpid(), 2611),
                (makeRefreshTestWindow(windowId: 2612), getpid(), 2612)
            ])
            configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
            controller.enableNiriLayout()
            await waitForRefreshWork(on: controller)

            controller.layoutRefreshController.requestFullRescan(reason: .startup)
            await waitForSettledRefreshWork(on: controller)

            guard let workspaceId = controller.interactionWorkspace()?.id else {
                Issue.record("Missing active workspace")
                return
            }
            let targetToken = WindowToken(pid: getpid(), windowId: 2612)
            guard let engine = controller.niriEngine,
                  let originalNode = engine.findNode(for: targetToken),
                  let originalColumn = engine.column(of: originalNode),
                  let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId)
            else {
                Issue.record("Missing original Niri placement state")
                return
            }
            guard let originalFrame = controller.axManager.lastAppliedFrame(for: 2612) else {
                Issue.record("Missing original applied frame")
                return
            }
            let originalColumnWidth = originalColumn.cachedWidth

            _ = controller.workspaceManager.rememberFocus(targetToken, in: workspaceId)
            controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: targetToken)
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

            visibleWindows.value = [
                (makeRefreshTestWindow(windowId: 2611), getpid(), 2611)
            ]
            controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
            await waitForSettledRefreshWork(on: controller)

            visibleWindows.value = [
                (makeRefreshTestWindow(windowId: 2611), getpid(), 2611),
                (makeRefreshTestWindow(windowId: 2612), getpid(), 2612)
            ]
            controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
            await waitForSettledRefreshWork(on: controller)

            guard let restoredNode = engine.findNode(for: targetToken),
                  let restoredColumn = engine.column(of: restoredNode),
                  let restoredColumnIndex = engine.columnIndex(of: restoredColumn, in: workspaceId),
                  let restoredFrame = controller.axManager.lastAppliedFrame(for: 2612)
            else {
                Issue.record("Missing restored Niri placement state")
                return
            }

            #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
            #expect(restoredNode.id == originalNode.id)
            #expect(restoredColumnIndex == originalColumnIndex)
            #expect(abs(restoredColumn.cachedWidth - originalColumnWidth) < 0.5)
            #expect(abs(restoredFrame.origin.x - originalFrame.origin.x) <= CGFloat(controller.workspaceManager.gaps) + 0.5)
            #expect(abs(restoredFrame.origin.y - originalFrame.origin.y) < 0.5)
            #expect(abs(restoredFrame.size.width - originalFrame.size.width) < 0.5)
            #expect(abs(restoredFrame.size.height - originalFrame.size.height) < 0.5)
        }
    }

    @Test @MainActor func nativeFullscreenSameWindowIdRestoreIgnoresFreshLifecycleModeReevaluationInNiri() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeRefreshTestController()
            defer { cleanupRefreshTestController(controller) }
            let visibleWindows = VisibleWindowsStore([
                (makeRefreshTestWindow(windowId: 2671), getpid(), 2671),
                (makeRefreshTestWindow(windowId: 2672), getpid(), 2672)
            ])
            configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
            controller.enableNiriLayout()
            await waitForRefreshWork(on: controller)

            controller.layoutRefreshController.requestFullRescan(reason: .startup)
            await waitForSettledRefreshWork(on: controller)

            guard let workspaceId = controller.interactionWorkspace()?.id else {
                Issue.record("Missing active workspace")
                return
            }
            let targetToken = WindowToken(pid: getpid(), windowId: 2672)
            guard let engine = controller.niriEngine,
                  let originalNode = engine.findNode(for: targetToken),
                  let originalColumn = engine.column(of: originalNode),
                  let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId)
            else {
                Issue.record("Missing original Niri reevaluation placement state")
                return
            }
            guard let originalFrame = controller.axManager.lastAppliedFrame(for: 2672) else {
                Issue.record("Missing original Niri reevaluation frame")
                return
            }
            let originalColumnWidth = originalColumn.cachedWidth

            _ = controller.workspaceManager.rememberFocus(targetToken, in: workspaceId)
            controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: targetToken)
            _ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: true)

            visibleWindows.value = [
                (makeRefreshTestWindow(windowId: 2671), getpid(), 2671)
            ]
            controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
            await waitForSettledRefreshWork(on: controller)

            controller.axEventHandler.windowFactsProvider = { axRef, _ in
                if axRef.windowId == targetToken.windowId {
                    return makeRefreshTestWindowFacts(
                        title: "Same window appears floating",
                        hasFullscreenButton: false,
                        fullscreenButtonEnabled: false
                    )
                }
                return makeRefreshTestWindowFacts()
            }

            visibleWindows.value = [
                (makeRefreshTestWindow(windowId: 2671), getpid(), 2671),
                (makeRefreshTestWindow(windowId: 2672), getpid(), 2672)
            ]
            controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
            await waitForSettledRefreshWork(on: controller)

            guard let restoredNode = engine.findNode(for: targetToken),
                  let restoredColumn = engine.column(of: restoredNode),
                  let restoredColumnIndex = engine.columnIndex(of: restoredColumn, in: workspaceId),
                  let restoredFrame = controller.axManager.lastAppliedFrame(for: 2672)
            else {
                Issue.record("Missing restored Niri reevaluation placement state")
                return
            }

            #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
            #expect(controller.workspaceManager.windowMode(for: targetToken) == .tiling)
            #expect(restoredNode.id == originalNode.id)
            #expect(restoredColumnIndex == originalColumnIndex)
            #expect(abs(restoredColumn.cachedWidth - originalColumnWidth) < 0.5)
            #expect(abs(restoredFrame.origin.x - originalFrame.origin.x) <= CGFloat(controller.workspaceManager.gaps) + 0.5)
            #expect(abs(restoredFrame.origin.y - originalFrame.origin.y) < 0.5)
            #expect(abs(restoredFrame.size.width - originalFrame.size.width) < 0.5)
            #expect(abs(restoredFrame.size.height - originalFrame.size.height) < 0.5)
        }
    }

    @Test @MainActor func nativeFullscreenExitWithReplacementWindowIdPreservesNiriIdentity() async {
        await withAXFrameProviderIsolationForTests {
            let controller = makeRefreshTestController()
            defer { cleanupRefreshTestController(controller) }
            let visibleWindows = VisibleWindowsStore([
                (makeRefreshTestWindow(windowId: 2615), getpid(), 2615),
                (makeRefreshTestWindow(windowId: 2616), getpid(), 2616)
            ])
            configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
            controller.enableNiriLayout()
            await waitForRefreshWork(on: controller)

            controller.layoutRefreshController.requestFullRescan(reason: .startup)
            await waitForSettledRefreshWork(on: controller)

            guard let workspaceId = controller.interactionWorkspace()?.id else {
                Issue.record("Missing active workspace")
                return
            }
            let originalToken = WindowToken(pid: getpid(), windowId: 2616)
            guard let engine = controller.niriEngine,
                  let originalEntry = controller.workspaceManager.entry(for: originalToken),
                  let originalNode = engine.findNode(for: originalToken),
                  let originalColumn = engine.column(of: originalNode),
                  let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId),
                  let originalFrame = controller.axManager.lastAppliedFrame(for: 2616)
            else {
                Issue.record("Missing original Niri replacement state")
                return
            }

            _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
            _ = controller.workspaceManager.markNativeFullscreenSuspended(originalToken)
            controller.axEventHandler.handleRemoved(token: originalToken)

            let replacementToken = WindowToken(pid: getpid(), windowId: 2617)
            visibleWindows.value = [
                (makeRefreshTestWindow(windowId: 2615), getpid(), 2615),
                (makeRefreshTestWindow(windowId: 2617), getpid(), 2617)
            ]
            controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
            await waitForSettledRefreshWork(on: controller)

            guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
                  let replacementNode = engine.findNode(for: replacementToken),
                  let replacementColumn = engine.column(of: replacementNode),
                  let replacementColumnIndex = engine.columnIndex(of: replacementColumn, in: workspaceId),
                  let replacementFrame = controller.axManager.lastAppliedFrame(for: 2617)
            else {
                Issue.record("Missing replacement Niri restore state")
                return
            }

            #expect(controller.workspaceManager.entry(for: originalToken) == nil)
            #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .standard)
            #expect(controller.workspaceManager.nativeFullscreenRecord(for: replacementToken) == nil)
            #expect(replacementEntry.handle === originalEntry.handle)
            #expect(replacementNode.id == originalNode.id)
            #expect(replacementColumnIndex == originalColumnIndex)
            #expect(abs(replacementFrame.origin.x - originalFrame.origin.x) <= CGFloat(controller.workspaceManager.gaps) + 0.5)
            #expect(abs(replacementFrame.origin.y - originalFrame.origin.y) < 0.5)
            #expect(abs(replacementFrame.size.width - originalFrame.size.width) < 0.5)
            #expect(abs(replacementFrame.size.height - originalFrame.size.height) < 0.5)
        }
    }

    @Test @MainActor func nativeFullscreenSpaceChangeRetainsMultiColumnNiriOrderWithSameWindowId() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2641), getpid(), 2641),
            (makeRefreshTestWindow(windowId: 2642), getpid(), 2642),
            (makeRefreshTestWindow(windowId: 2643), getpid(), 2643),
            (makeRefreshTestWindow(windowId: 2644), getpid(), 2644),
            (makeRefreshTestWindow(windowId: 2645), getpid(), 2645)
        ])
        var fullscreenWindowIds: Set<Int> = []
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            fullscreenWindowIds.contains(axRef.windowId)
        }
        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2644)
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }
        guard controller.workspaceManager.entry(for: targetToken) != nil else {
            Issue.record("Missing managed entry for fullscreen target")
            return
        }
        guard let originalNode = engine.findNode(for: targetToken) else {
            Issue.record("Missing original Niri node for fullscreen target")
            return
        }
        guard let originalColumn = engine.column(of: originalNode),
              let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId)
        else {
            Issue.record("Missing original Niri column for fullscreen target")
            return
        }
        guard let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing original Niri snapshot")
            return
        }
        guard let originalFrame = originalNode.renderedFrame ?? originalNode.frame else {
            Issue.record("Missing original Niri frame for fullscreen target")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected initial Niri placement to span multiple columns")
            return
        }
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        guard let targetEntry = controller.workspaceManager.entry(for: targetToken) else {
            Issue.record("Missing entry before native fullscreen suspension")
            return
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: targetEntry,
            isWorkspaceActive: true,
            appFullscreen: true
        )

        fullscreenWindowIds = [2644]
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2644), getpid(), 2644)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2641)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2642)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2643)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2645)) != nil)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)

        fullscreenWindowIds.removeAll()
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2641), getpid(), 2641),
            (makeRefreshTestWindow(windowId: 2642), getpid(), 2642),
            (makeRefreshTestWindow(windowId: 2643), getpid(), 2643),
            (makeRefreshTestWindow(windowId: 2644), getpid(), 2644),
            (makeRefreshTestWindow(windowId: 2645), getpid(), 2645)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let restoredNode = engine.findNode(for: targetToken),
              let restoredColumn = engine.column(of: restoredNode),
              let restoredColumnIndex = engine.columnIndex(of: restoredColumn, in: workspaceId),
              let restoredSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId)
        else {
            Issue.record("Missing restored multi-column Niri same-ID state")
            return
        }
        guard let restoredFrame = restoredNode.renderedFrame ?? restoredNode.frame else {
            Issue.record("Missing restored Niri frame for fullscreen target")
            return
        }

        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(restoredNode.id == originalNode.id)
        #expect(restoredColumnIndex == originalColumnIndex)
        #expect(restoredSnapshot == originalSnapshot)
        #expect(abs(restoredFrame.origin.x - originalFrame.origin.x) <= 6.0)
        #expect(abs(restoredFrame.origin.y - originalFrame.origin.y) < 0.5)
        #expect(abs(restoredFrame.size.width - originalFrame.size.width) < 0.5)
        #expect(abs(restoredFrame.size.height - originalFrame.size.height) < 0.5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
    }

    @Test @MainActor func nativeFullscreenUnlockRetainsMultiColumnNiriOrderWithSameWindowId() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2681), getpid(), 2681),
            (makeRefreshTestWindow(windowId: 2682), getpid(), 2682),
            (makeRefreshTestWindow(windowId: 2683), getpid(), 2683),
            (makeRefreshTestWindow(windowId: 2684), getpid(), 2684),
            (makeRefreshTestWindow(windowId: 2685), getpid(), 2685)
        ])
        var fullscreenWindowIds: Set<Int> = []
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            fullscreenWindowIds.contains(axRef.windowId)
        }
        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2684)
        guard controller.niriEngine != nil else {
            Issue.record("Missing Niri engine")
            return
        }
        guard controller.workspaceManager.entry(for: targetToken) != nil else {
            Issue.record("Missing managed entry for unlock fullscreen target")
            return
        }
        guard let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing original unlock Niri snapshot")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected unlock Niri placement to span multiple columns")
            return
        }
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        guard let targetEntry = controller.workspaceManager.entry(for: targetToken) else {
            Issue.record("Missing entry before unlock fullscreen suspension")
            return
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: targetEntry,
            isWorkspaceActive: true,
            appFullscreen: true
        )

        fullscreenWindowIds = [2684]
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2684), getpid(), 2684)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .unlock)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2681)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2682)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2683)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2685)) != nil)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)
    }

    @Test @MainActor func nativeFullscreenMissingFocusedWindowFallbackKeepsNiriLifecyclePreservationAcrossFullRescans(
    ) async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2721), getpid(), 2721),
            (makeRefreshTestWindow(windowId: 2722), getpid(), 2722),
            (makeRefreshTestWindow(windowId: 2723), getpid(), 2723),
            (makeRefreshTestWindow(windowId: 2724), getpid(), 2724),
            (makeRefreshTestWindow(windowId: 2725), getpid(), 2725)
        ])
        var fullscreenWindowIds: Set<Int> = []
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            fullscreenWindowIds.contains(axRef.windowId)
        }
        controller.enableNiriLayout()
        controller.hasStartedServices = true
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2724)
        guard let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing original Niri snapshot")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected initial Niri placement to span multiple columns")
            return
        }
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        guard let targetEntry = controller.workspaceManager.entry(for: targetToken) else {
            Issue.record("Missing entry before lifecycle fallback test")
            return
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: targetEntry,
            isWorkspaceActive: true,
            appFullscreen: true
        )

        fullscreenWindowIds = [2724]
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2724), getpid(), 2724)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)

        controller.axEventHandler.focusedWindowRefProvider = { _ in nil }
        controller.axEventHandler.handleAppActivation(
            pid: getpid(),
            source: .workspaceDidActivateApplication
        )

        #expect(controller.workspaceManager.isAppFullscreenActive)
        #expect(controller.workspaceManager.hasNativeFullscreenLifecycleContext)

        controller.layoutRefreshController.requestFullRescan(reason: .unlock)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2721)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2722)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2723)) != nil)
        #expect(controller.workspaceManager.entry(for: WindowToken(pid: getpid(), windowId: 2725)) != nil)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)
    }

    @Test @MainActor func nativeFullscreenDelayedSameTokenDestroyRoundTripPreservesNiriIdentityAndBarState() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2731), getpid(), 2731),
            (makeRefreshTestWindow(windowId: 2732), getpid(), 2732),
            (makeRefreshTestWindow(windowId: 2733), getpid(), 2733),
            (makeRefreshTestWindow(windowId: 2734), getpid(), 2734),
            (makeRefreshTestWindow(windowId: 2735), getpid(), 2735)
        ])
        var fullscreenWindowIds: Set<Int> = []
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            fullscreenWindowIds.contains(axRef.windowId)
        }
        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2734)
        guard let engine = controller.niriEngine,
              let originalEntry = controller.workspaceManager.entry(for: targetToken),
              let originalNode = engine.findNode(for: targetToken),
              let originalColumn = engine.column(of: originalNode),
              let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId),
              let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId),
              let originalFrame = originalNode.renderedFrame ?? originalNode.frame
        else {
            Issue.record("Missing original Niri state for delayed destroy round-trip")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected initial Niri placement to span multiple columns")
            return
        }
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        controller.axEventHandler.handleRemoved(token: targetToken)

        visibleWindows.value = []
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let enterRecord = controller.workspaceManager.nativeFullscreenRecord(for: targetToken) else {
            Issue.record("Missing delayed enter record after destroy")
            return
        }
        if case .enterRequested = enterRecord.transition {} else {
            Issue.record("Expected delayed enter record to remain enterRequested")
        }
        #expect(enterRecord.availability == .temporarilyUnavailable)
        #expect(controller.workspaceManager.entry(for: targetToken)?.handle === originalEntry.handle)
        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)

        fullscreenWindowIds = [2734]
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2734), getpid(), 2734)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let suspendedRecord = controller.workspaceManager.nativeFullscreenRecord(for: targetToken) else {
            Issue.record("Missing suspended record after delayed same-token fullscreen reappearance")
            return
        }
        if case .suspended = suspendedRecord.transition {} else {
            Issue.record("Expected delayed enter record to become suspended")
        }
        #expect(suspendedRecord.availability == .present)
        #expect(controller.workspaceManager.entry(for: targetToken)?.handle === originalEntry.handle)

        _ = controller.workspaceManager.requestNativeFullscreenExit(targetToken, initiatedByCommand: true)
        controller.axEventHandler.handleRemoved(token: targetToken)

        fullscreenWindowIds.removeAll()
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2731), getpid(), 2731),
            (makeRefreshTestWindow(windowId: 2732), getpid(), 2732),
            (makeRefreshTestWindow(windowId: 2733), getpid(), 2733),
            (makeRefreshTestWindow(windowId: 2735), getpid(), 2735)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let exitRecord = controller.workspaceManager.nativeFullscreenRecord(for: targetToken) else {
            Issue.record("Missing delayed exit record after destroy")
            return
        }
        if case .exitRequested = exitRecord.transition {} else {
            Issue.record("Expected delayed exit record to remain exitRequested")
        }
        #expect(exitRecord.availability == .temporarilyUnavailable)
        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
        #expect(niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) == originalSnapshot)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2731), getpid(), 2731),
            (makeRefreshTestWindow(windowId: 2732), getpid(), 2732),
            (makeRefreshTestWindow(windowId: 2733), getpid(), 2733),
            (makeRefreshTestWindow(windowId: 2734), getpid(), 2734),
            (makeRefreshTestWindow(windowId: 2735), getpid(), 2735)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let restoredNode = engine.findNode(for: targetToken),
              let restoredColumn = engine.column(of: restoredNode),
              let restoredColumnIndex = engine.columnIndex(of: restoredColumn, in: workspaceId),
              let restoredSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId),
              let restoredFrame = restoredNode.renderedFrame ?? restoredNode.frame
        else {
            Issue.record("Missing restored Niri state after delayed destroy round-trip")
            return
        }

        #expect(controller.workspaceManager.nativeFullscreenRecord(for: targetToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(controller.workspaceManager.entry(for: targetToken)?.handle === originalEntry.handle)
        #expect(restoredNode.id == originalNode.id)
        #expect(restoredColumnIndex == originalColumnIndex)
        #expect(restoredSnapshot == originalSnapshot)
        #expect(abs(restoredFrame.origin.x - originalFrame.origin.x) <= 6.0)
        #expect(abs(restoredFrame.origin.y - originalFrame.origin.y) < 0.5)
        #expect(abs(restoredFrame.size.width - originalFrame.size.width) < 0.5)
        #expect(abs(restoredFrame.size.height - originalFrame.size.height) < 0.5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
    }

    @Test @MainActor func nativeFullscreenExitPreservesInactiveWorkspaceWindowsDuringPartialEnumeration() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }

        guard let workspaceOne = controller.interactionWorkspace()?.id,
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspaces for native fullscreen partial enumeration")
            return
        }

        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2741), getpid(), 2741),
            (makeRefreshTestWindow(windowId: 2742), getpid(), 2742)
        ])
        var fullscreenWindowIds: Set<Int> = []
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { axRef in
            fullscreenWindowIds.contains(axRef.windowId)
        }

        _ = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceOne, 2741),
                (workspaceTwo, 2742)
            ],
            focusedWindowId: 2741,
            ensureWorkspaces: [workspaceTwo]
        )

        let targetToken = WindowToken(pid: getpid(), windowId: 2741)
        let inactiveToken = WindowToken(pid: getpid(), windowId: 2742)
        let originalEntryCount = controller.workspaceManager.allEntries().count

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceOne)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(targetToken)

        fullscreenWindowIds.removeAll()
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2741), getpid(), 2741)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.nativeFullscreenRecord(for: targetToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(controller.workspaceManager.entry(for: inactiveToken)?.workspaceId == workspaceTwo)
        #expect(controller.workspaceManager.allEntries().count == originalEntryCount)
        #expect(controller.workspaceManager.entry(for: targetToken) != nil)
    }

    @Test @MainActor func nativeFullscreenExitPreservesInactiveWorkspaceWindowsWhenLifecycleClearsDuringEnumeration() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }

        guard let workspaceOne = controller.interactionWorkspace()?.id,
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing workspaces for native fullscreen enumeration race")
            return
        }

        _ = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceOne, 2743),
                (workspaceTwo, 2744)
            ],
            focusedWindowId: 2743,
            ensureWorkspaces: [workspaceTwo]
        )

        let targetToken = WindowToken(pid: getpid(), windowId: 2743)
        let inactiveToken = WindowToken(pid: getpid(), windowId: 2744)
        let originalEntryCount = controller.workspaceManager.allEntries().count

        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceOne)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(targetToken)
        #expect(controller.workspaceManager.hasNativeFullscreenLifecycleContext)

        var restoredDuringEnumeration = false
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.axManager.fullRescanEnumerationOverrideForTests = {
            await Task.yield()
            _ = controller.workspaceManager.restoreNativeFullscreenRecord(for: targetToken)
            restoredDuringEnumeration = !controller.workspaceManager.hasNativeFullscreenLifecycleContext
            return AXManager.FullRescanEnumerationSnapshot(
                windows: [(makeRefreshTestWindow(windowId: 2743), getpid(), 2743)],
                failedPIDs: []
            )
        }

        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        #expect(restoredDuringEnumeration)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: targetToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(controller.workspaceManager.entry(for: inactiveToken)?.workspaceId == workspaceTwo)
        #expect(controller.workspaceManager.allEntries().count == originalEntryCount)
        #expect(controller.workspaceManager.entry(for: targetToken) != nil)
    }

    @Test @MainActor func nativeFullscreenReplacementSpaceChangePreservesMultiColumnNiriOrder() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2651), getpid(), 2651),
            (makeRefreshTestWindow(windowId: 2652), getpid(), 2652),
            (makeRefreshTestWindow(windowId: 2653), getpid(), 2653),
            (makeRefreshTestWindow(windowId: 2654), getpid(), 2654),
            (makeRefreshTestWindow(windowId: 2655), getpid(), 2655)
        ])
        configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let originalToken = WindowToken(pid: getpid(), windowId: 2654)
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }
        guard let originalEntry = controller.workspaceManager.entry(for: originalToken) else {
            Issue.record("Missing original replacement entry")
            return
        }
        guard let originalNode = engine.findNode(for: originalToken) else {
            Issue.record("Missing original replacement node")
            return
        }
        guard let originalColumn = engine.column(of: originalNode),
              let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId)
        else {
            Issue.record("Missing original replacement column")
            return
        }
        guard let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing original replacement snapshot")
            return
        }
        guard let originalFrame = originalNode.renderedFrame ?? originalNode.frame else {
            Issue.record("Missing original Niri frame for replacement target")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected initial Niri placement to span multiple columns")
            return
        }
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        guard let originalEntryBeforeFullscreen = controller.workspaceManager.entry(for: originalToken) else {
            Issue.record("Missing entry before native fullscreen replacement flow")
            return
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: originalEntryBeforeFullscreen,
            isWorkspaceActive: true,
            appFullscreen: true
        )
        controller.axEventHandler.handleRemoved(token: originalToken)

        visibleWindows.value = []
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        #expect(controller.workspaceManager.allEntries().count == 5)
        #expect(controller.workspaceManager.entry(for: originalToken) != nil)
        #expect(controller.workspaceManager.hasPendingNativeFullscreenTransition)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        let replacementToken = WindowToken(pid: getpid(), windowId: 2656)
        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2651), getpid(), 2651),
            (makeRefreshTestWindow(windowId: 2652), getpid(), 2652),
            (makeRefreshTestWindow(windowId: 2653), getpid(), 2653),
            (makeRefreshTestWindow(windowId: 2655), getpid(), 2655),
            (makeRefreshTestWindow(windowId: 2656), getpid(), 2656)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let replacementEntry = controller.workspaceManager.entry(for: replacementToken),
              let replacementNode = engine.findNode(for: replacementToken),
              let replacementColumn = engine.column(of: replacementNode),
              let replacementColumnIndex = engine.columnIndex(of: replacementColumn, in: workspaceId),
              let restoredSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId)
        else {
            Issue.record("Missing restored multi-column replacement Niri state")
            return
        }
        guard let replacementFrame = replacementNode.renderedFrame ?? replacementNode.frame else {
            Issue.record("Missing replacement Niri frame")
            return
        }

        #expect(controller.workspaceManager.entry(for: originalToken) == nil)
        #expect(controller.workspaceManager.layoutReason(for: replacementToken) == .standard)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: replacementToken) == nil)
        #expect(replacementEntry.handle === originalEntry.handle)
        #expect(replacementNode.id == originalNode.id)
        #expect(replacementColumnIndex == originalColumnIndex)
        #expect(restoredSnapshot == replacingToken(originalToken, with: replacementToken, in: originalSnapshot))
        #expect(abs(replacementFrame.origin.x - originalFrame.origin.x) <= 2.0)
        #expect(abs(replacementFrame.origin.y - originalFrame.origin.y) < 0.5)
        #expect(abs(replacementFrame.size.width - originalFrame.size.width) < 0.5)
        #expect(abs(replacementFrame.size.height - originalFrame.size.height) < 0.5)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
    }

    @Test @MainActor func nativeFullscreenLikeDestroyBeforeRecordPreservesMultiColumnNiriOrder() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2671), getpid(), 2671),
            (makeRefreshTestWindow(windowId: 2672), getpid(), 2672),
            (makeRefreshTestWindow(windowId: 2673), getpid(), 2673),
            (makeRefreshTestWindow(windowId: 2674), getpid(), 2674),
            (makeRefreshTestWindow(windowId: 2675), getpid(), 2675)
        ])
        configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2674)
        guard let engine = controller.niriEngine,
              let originalEntry = controller.workspaceManager.entry(for: targetToken),
              let originalNode = engine.findNode(for: targetToken),
              let originalColumn = engine.column(of: originalNode),
              let originalColumnIndex = engine.columnIndex(of: originalColumn, in: workspaceId),
              let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId)
        else {
            Issue.record("Missing original Niri state")
            return
        }
        _ = controller.workspaceManager.setManagedFocus(
            targetToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.axEventHandler.isFullscreenProvider = { axRef in
            axRef.windowId == targetToken.windowId
        }

        controller.axEventHandler.handleRemoved(token: targetToken)
        visibleWindows.value = []
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let unavailableRecord = controller.workspaceManager.nativeFullscreenRecord(for: targetToken),
              let preservedNode = engine.findNode(for: targetToken),
              let preservedColumn = engine.column(of: preservedNode),
              let preservedColumnIndex = engine.columnIndex(of: preservedColumn, in: workspaceId),
              let preservedSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId)
        else {
            Issue.record("Missing preserved Niri state")
            return
        }

        #expect(unavailableRecord.availability == .temporarilyUnavailable)
        #expect(controller.workspaceManager.entry(for: targetToken)?.handle === originalEntry.handle)
        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .nativeFullscreen)
        #expect(preservedNode.id == originalNode.id)
        #expect(preservedColumnIndex == originalColumnIndex)
        #expect(preservedSnapshot == originalSnapshot)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2674), getpid(), 2674)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let suspendedRecord = controller.workspaceManager.nativeFullscreenRecord(for: targetToken),
              let suspendedNode = engine.findNode(for: targetToken),
              let suspendedColumn = engine.column(of: suspendedNode),
              let suspendedColumnIndex = engine.columnIndex(of: suspendedColumn, in: workspaceId),
              let suspendedSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId)
        else {
            Issue.record("Missing suspended Niri state")
            return
        }

        if case .suspended = suspendedRecord.transition {} else {
            Issue.record("Expected speculative record to become suspended")
        }
        #expect(suspendedRecord.availability == .present)
        #expect(controller.workspaceManager.entry(for: targetToken)?.handle === originalEntry.handle)
        #expect(suspendedNode.id == originalNode.id)
        #expect(suspendedColumnIndex == originalColumnIndex)
        #expect(suspendedSnapshot == originalSnapshot)
        #expect(controller.workspaceManager.barVisibleEntries(in: workspaceId).count == 5)
        #expect(workspaceBarWindowCount(controller: controller, workspaceId: workspaceId) == 5)
    }

    @Test @MainActor func nativeFullscreenReplacementWithFloatingFactsRemovesOriginalNiriEntry() async {
        let controller = makeRefreshTestController()
        defer { cleanupRefreshTestController(controller) }
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2661), getpid(), 2661),
            (makeRefreshTestWindow(windowId: 2662), getpid(), 2662),
            (makeRefreshTestWindow(windowId: 2663), getpid(), 2663),
            (makeRefreshTestWindow(windowId: 2664), getpid(), 2664),
            (makeRefreshTestWindow(windowId: 2665), getpid(), 2665)
        ])
        configureNativeFullscreenTestState(on: controller, visibleWindows: visibleWindows)
        controller.enableNiriLayout()
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForSettledRefreshWork(on: controller)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForSettledRefreshWork(on: controller)

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let originalToken = WindowToken(pid: getpid(), windowId: 2664)
        guard let engine = controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }
        guard controller.workspaceManager.entry(for: originalToken) != nil else {
            Issue.record("Missing original replacement reevaluation entry")
            return
        }
        guard engine.findNode(for: originalToken) != nil else {
            Issue.record("Missing original replacement reevaluation node")
            return
        }
        guard let originalSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing original replacement reevaluation snapshot")
            return
        }
        guard originalSnapshot.count >= 3 else {
            Issue.record("Expected initial Niri placement to span multiple columns")
            return
        }

        _ = controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(originalToken)
        controller.axEventHandler.handleRemoved(token: originalToken)

        let replacementToken = WindowToken(pid: getpid(), windowId: 2666)
        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            if axRef.windowId == replacementToken.windowId {
                return makeRefreshTestWindowFacts(
                    title: "Replacement appears floating",
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: false
                )
            }
            return makeRefreshTestWindowFacts()
        }

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2661), getpid(), 2661),
            (makeRefreshTestWindow(windowId: 2662), getpid(), 2662),
            (makeRefreshTestWindow(windowId: 2663), getpid(), 2663),
            (makeRefreshTestWindow(windowId: 2665), getpid(), 2665),
            (makeRefreshTestWindow(windowId: 2666), getpid(), 2666)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForSettledRefreshWork(on: controller)

        guard let restoredSnapshot = niriColumnTokenSnapshot(controller: controller, workspaceId: workspaceId) else {
            Issue.record("Missing restored Niri replacement reevaluation snapshot")
            return
        }

        #expect(controller.workspaceManager.windowMode(for: replacementToken) == .floating)
        #expect(engine.findNode(for: replacementToken) == nil)
        #expect(restoredSnapshot == removingToken(originalToken, from: originalSnapshot))
    }

    @Test @MainActor func fullRescanExitClearsFullscreenSessionFlagsAndRecoversFocusedBorder() async {
        let controller = makeRefreshTestController()
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 2631), getpid(), 2631),
            (makeRefreshTestWindow(windowId: 2632), getpid(), 2632)
        ])
        controller.axManager.currentWindowsAsyncOverride = { visibleWindows.value }
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.enableNiriLayout()
        controller.setBordersEnabled(true)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        let targetToken = WindowToken(pid: getpid(), windowId: 2632)
        _ = controller.workspaceManager.setManagedFocus(
            targetToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId)
        _ = controller.workspaceManager.markNativeFullscreenSuspended(targetToken)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2631), getpid(), 2631)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        visibleWindows.value = [
            (makeRefreshTestWindow(windowId: 2631), getpid(), 2631),
            (makeRefreshTestWindow(windowId: 2632), getpid(), 2632)
        ]
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.layoutReason(for: targetToken) == .standard)
        #expect(controller.workspaceManager.nativeFullscreenRecord(for: targetToken) == nil)
        #expect(controller.workspaceManager.isAppFullscreenActive == false)
        #expect(controller.workspaceManager.isNonManagedFocusActive == false)
        #expect(controller.workspaceManager.hasPendingNativeFullscreenTransition == false)
        guard let recoveredToken = controller.workspaceManager.activeFocusRequestToken else {
            Issue.record("Expected managed focus recovery to resume after native fullscreen restore")
            return
        }

        if let engine = controller.niriEngine {
            await waitUntil {
                !engine.hasAnyWindowAnimationsRunning(in: workspaceId)
                    && !engine.hasAnyColumnAnimationsRunning(in: workspaceId)
            }
        }
        controller.focusWindow(recoveredToken)

        #expect(controller.workspaceManager.activeFocusRequestToken == recoveredToken)
    }

    @Test @MainActor func gapsChangedUsesRelayoutOnly() async {
        let controller = makeRefreshTestController()
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        lifecycleManager.handleGapsChanged()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.gapsChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func appHideAndUnhideUseVisibilityRefreshOnly() async {
        let controller = makeRefreshTestController()
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }
        _ = addWindow(on: controller, workspaceId: workspaceId, pid: getpid(), windowId: 305)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        controller.axEventHandler.handleAppHidden(pid: getpid())
        await waitForRefreshWork(on: controller)

        #expect(recorder.visibilityReasons == [.appHidden])
        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(recorder.windowRemovalReasons.isEmpty)

        resetRefreshSpies(on: controller, recorder: recorder)

        controller.axEventHandler.handleAppUnhidden(pid: getpid())
        await waitForRefreshWork(on: controller)

        #expect(recorder.visibilityReasons == [.appUnhidden])
        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(recorder.windowRemovalReasons.isEmpty)
    }

    @Test @MainActor func fullRescanQueuesLowerPriorityRequestsAsFollowUps() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        var fullRescanReasons: [RefreshReason] = []
        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        var postLayoutRuns = 0

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return true
        }
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            await gate.wait()
            return true
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitUntil { !fullRescanReasons.isEmpty }

        controller.layoutRefreshController.requestRelayout(reason: .gapsChanged)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition) {
            postLayoutRuns += 1
        }

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1)
        #expect(fullRescanReasons == [.startup])
        #expect(relayoutEvents.map(\.0) == [.workspaceTransition, .gapsChanged])
        #expect(relayoutEvents.map(\.1) == [.immediateRelayout, .relayout])
        #expect(postLayoutRuns == 1)
    }

    @Test @MainActor func hiddenAppsSurviveVisibleOnlyFullRescansAndRestoreOnUnhide() async {
        let controller = makeRefreshTestController()
        controller.axManager.currentWindowsAsyncOverride = { [] }
        controller.axEventHandler.windowSubscriptionHandler = { _ in }
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let windowId = 306
        let handle = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: windowId)

        controller.axEventHandler.handleAppHidden(pid: pid)
        await waitForRefreshWork(on: controller)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)
        #expect(controller.workspaceManager.entry(for: handle) != nil)
        #expect(controller.workspaceManager.entry(forPid: pid, windowId: windowId)?.workspaceId == workspaceId)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)
        #expect(controller.workspaceManager.entry(for: handle) != nil)
        #expect(controller.workspaceManager.layoutReason(for: handle) == .macosHiddenApp)

        controller.axEventHandler.handleAppUnhidden(pid: pid)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(for: handle) != nil)
        #expect(controller.workspaceManager.layoutReason(for: handle) == .standard)
    }

    @Test @MainActor func fullRescanRemovesMissingTrackedWindowOnFirstVerifiedMiss() async {
        let controller = makeRefreshTestController()
        controller.axManager.currentWindowsAsyncOverride = { [] }
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let windowId = 3061
        _ = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: windowId)
        let targetFrame = CGRect(x: 120, y: 120, width: 500, height: 320)
        controller.axManager.frameApplyOverrideForTests = { _ in [] }
        controller.axManager.applyFramesParallel([(pid, windowId, targetFrame)])
        controller.axManager.markWindowInactive(windowId)
        controller.axManager.forceApplyNextFrame(for: windowId)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: windowId) == nil)
        let axState = controller.axManager.windowStateDebugSnapshot()
        #expect(axState.pendingFrameWriteCount == 0)
        #expect(axState.retryBudgetCount == 0)
        #expect(axState.forceApplyWindowIdCount == 0)
        #expect(axState.inactiveWorkspaceWindowIdCount == 0)
    }

    @Test @MainActor func fullRescanClearsFocusedFloatingBorderWhenWindowMissing() async {
        let controller = makeRefreshTestController()
        controller.axManager.currentWindowsAsyncOverride = { [] }
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let windowId = 3063
        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: windowId),
            pid: getpid(),
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        guard let handle = controller.workspaceManager.handle(for: token) else {
            Issue.record("Missing handle for floating window")
            return
        }
        _ = controller.workspaceManager.setManagedFocus(
            handle,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: CGRect(x: 80, y: 80, width: 620, height: 420),
            for: token
        )
        primeFocusedBorder(on: controller, handle: handle)
        #expect(controller.currentBorderTarget()?.token == token)
        #expect(lastAppliedBorderWindowId(on: controller) == windowId)

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(for: token) == nil)
        #expect(controller.currentBorderTarget() == nil)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func fullRescanPreservesScratchpadHiddenWindowWhenWindowServerStillSeesIt() async {
        let controller = makeRefreshTestController()
        defer {
            controller.axEventHandler.windowInfoProvider = nil
            SkyLight.orderedStateProviderForTests = nil
        }
        controller.axManager.fullRescanEnumerationOverrideForTests = {
            AXManager.FullRescanEnumerationSnapshot(windows: [], failedPIDs: [])
        }
        SkyLight.orderedStateProviderForTests = { _ in nil }
        guard let workspaceId = controller.interactionWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let windowId = 3062
        let handle = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: windowId)
        _ = controller.workspaceManager.setScratchpadToken(handle.token)
        controller.workspaceManager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: handle.token
        )
        controller.axEventHandler.windowInfoProvider = { queriedWindowId in
            queriedWindowId == UInt32(windowId)
                ? WindowServerInfo(
                    id: queriedWindowId,
                    pid: pid,
                    level: 0,
                    frame: CGRect(x: monitor.frame.maxX + 600, y: 20, width: 500, height: 400)
                )
                : nil
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(for: handle) != nil)
        #expect(controller.workspaceManager.hiddenState(for: handle.token)?.isScratchpad == true)
        #expect(controller.workspaceManager.scratchpadToken() == handle.token)
    }

    @Test @MainActor func fullRescanReconcilesScratchpadHiddenWindowWhenWindowServerFrameIsVisible() async {
        let controller = makeRefreshTestController()
        defer {
            controller.axEventHandler.windowInfoProvider = nil
            SkyLight.orderedStateProviderForTests = nil
        }
        controller.axManager.fullRescanEnumerationOverrideForTests = {
            AXManager.FullRescanEnumerationSnapshot(windows: [], failedPIDs: [])
        }
        guard let workspaceId = controller.interactionWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let windowId = 3063
        let handle = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: windowId)
        _ = controller.workspaceManager.setScratchpadToken(handle.token)
        controller.workspaceManager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: handle.token
        )
        SkyLight.orderedStateProviderForTests = { queriedWindowId in
            queriedWindowId == UInt32(windowId) ? true : nil
        }
        controller.axEventHandler.windowInfoProvider = { queriedWindowId in
            queriedWindowId == UInt32(windowId)
                ? WindowServerInfo(
                    id: queriedWindowId,
                    pid: pid,
                    level: 0,
                    frame: CGRect(x: 240, y: 140, width: 520, height: 360)
                )
                : nil
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(for: handle) != nil)
        #expect(controller.workspaceManager.hiddenState(for: handle.token) == nil)
        #expect(controller.workspaceManager.scratchpadToken() == handle.token)
    }

    @Test @MainActor func fullRescanPreservesScratchpadHiddenWindowWhenOrderedInButFrameOffscreen() async {
        let controller = makeRefreshTestController()
        defer {
            controller.axEventHandler.windowInfoProvider = nil
            SkyLight.orderedStateProviderForTests = nil
        }
        controller.axManager.fullRescanEnumerationOverrideForTests = {
            AXManager.FullRescanEnumerationSnapshot(windows: [], failedPIDs: [])
        }
        guard let workspaceId = controller.interactionWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let windowId = 3065
        let handle = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: windowId)
        _ = controller.workspaceManager.setScratchpadToken(handle.token)
        controller.workspaceManager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: handle.token
        )
        SkyLight.orderedStateProviderForTests = { queriedWindowId in
            queriedWindowId == UInt32(windowId) ? true : nil
        }
        controller.axEventHandler.windowInfoProvider = { queriedWindowId in
            queriedWindowId == UInt32(windowId)
                ? WindowServerInfo(
                    id: queriedWindowId,
                    pid: pid,
                    level: 0,
                    frame: CGRect(x: monitor.frame.maxX + 600, y: 140, width: 520, height: 360)
                )
                : nil
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(for: handle) != nil)
        #expect(controller.workspaceManager.hiddenState(for: handle.token)?.isScratchpad == true)
        #expect(controller.workspaceManager.scratchpadToken() == handle.token)
    }

    @Test @MainActor func fullRescanOrderedInKeepsStaleScratchpadRevealFromRehidingWindow() async {
        let controller = makeRefreshTestController()
        defer {
            controller.axEventHandler.windowInfoProvider = nil
            SkyLight.orderedStateProviderForTests = nil
        }
        controller.axManager.fullRescanEnumerationOverrideForTests = {
            AXManager.FullRescanEnumerationSnapshot(windows: [], failedPIDs: [])
        }
        guard let workspaceId = controller.interactionWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let windowId = 3064
        let token = controller.workspaceManager.addWindow(
            makeRefreshTestWindow(windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let frame = CGRect(x: 240, y: 140, width: 520, height: 360)
        controller.workspaceManager.updateFloatingGeometry(frame: frame, for: token, referenceMonitor: monitor)
        _ = controller.workspaceManager.setScratchpadToken(token)
        controller.workspaceManager.setHiddenState(
            WindowModel.HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: token
        )
        controller.axManager.frameApplyOverrideForTests = { requests in
            requests.map { request in
                AXFrameApplyResult(
                    requestId: request.requestId,
                    pid: request.pid,
                    windowId: request.windowId,
                    targetFrame: request.frame,
                    currentFrameHint: request.currentFrameHint,
                    writeResult: AXFrameWriteResult(
                        targetFrame: request.frame,
                        observedFrame: nil,
                        writeOrder: AXWindowService.frameWriteOrder(
                            currentFrame: request.currentFrameHint,
                            targetFrame: request.frame
                        ),
                        sizeError: .success,
                        positionError: .success,
                        failureReason: .verificationMismatch
                    )
                )
            }
        }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Missing scratchpad entry")
            return
        }

        var successCount = 0
        controller.layoutRefreshController.restoreScratchpadWindow(
            entry,
            monitor: monitor,
            onSuccess: { successCount += 1 }
        )
        #expect(controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true)

        SkyLight.orderedStateProviderForTests = { queriedWindowId in
            queriedWindowId == UInt32(windowId) ? true : nil
        }
        controller.axEventHandler.windowInfoProvider = { queriedWindowId in
            queriedWindowId == UInt32(windowId)
                ? WindowServerInfo(
                    id: queriedWindowId,
                    pid: pid,
                    level: 0,
                    frame: frame
                )
                : nil
        }
        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)
        try? await Task.sleep(for: .milliseconds(75))

        #expect(controller.workspaceManager.hiddenState(for: token) == nil)
        #expect(controller.workspaceManager.scratchpadToken() == token)
        #expect(successCount == 1)
    }

    @Test @MainActor func fullRescanPreservesTrackedEmacsLikeWindowOnActiveSpaceChange() async {
        let controller = makeRefreshTestController()
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let windowId = 6_104
        let handle = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: windowId)

        controller.axEventHandler.windowFactsProvider = { axRef, _ in
            guard axRef.windowId == windowId else {
                return makeRefreshTestWindowFacts()
            }
            return makeRefreshTestWindowFacts(
                bundleId: "org.gnu.Emacs",
                role: kAXTextFieldRole as String,
                subrole: kAXStandardWindowSubrole as String
            )
        }
        controller.axManager.fullRescanEnumerationOverrideForTests = {
            AXManager.FullRescanEnumerationSnapshot(
                windows: [(makeRefreshTestWindow(windowId: windowId), pid, windowId)],
                failedPIDs: []
            )
        }

        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(for: handle) != nil)
    }

    @Test @MainActor func fullRescanPreservesTrackedWindowsForFailedEnumerationPIDs() async {
        let controller = makeRefreshTestController()
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let liveHandle = addWindow(on: controller, workspaceId: workspaceId, pid: 6_101, windowId: 6_101)
        let failedHandle = addWindow(on: controller, workspaceId: workspaceId, pid: 6_102, windowId: 6_102)
        let missingHandle = addWindow(on: controller, workspaceId: workspaceId, pid: 6_103, windowId: 6_103)

        controller.axManager.fullRescanEnumerationOverrideForTests = {
            AXManager.FullRescanEnumerationSnapshot(
                windows: [(makeRefreshTestWindow(windowId: 6_101), 6_101, 6_101)],
                failedPIDs: [6_102]
            )
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(for: liveHandle) != nil)
        #expect(controller.workspaceManager.entry(for: failedHandle) != nil)
        #expect(controller.workspaceManager.entry(for: missingHandle) == nil)
    }

    @Test @MainActor func activeFullRescanQueuesFollowUpRelayoutForLateNiriCreate() async {
        let fixture = makeTwoMonitorRefreshTestController()
        let controller = fixture.controller
        defer { cleanupRefreshTestController(controller) }
        var fullRescanReasons: [RefreshReason] = []
        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        var injectLateCreate = false
        var lateCreateWasQueuedDuringFullRescan = false
        var newToken: WindowToken?

        controller.enableNiriLayout()
        let primaryHandle = addWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            pid: getpid(),
            windowId: 6_501
        )
        let secondaryHandle = addWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            pid: getpid(),
            windowId: 6_502
        )
        let visibleWindows = VisibleWindowsStore([
            (makeRefreshTestWindow(windowId: 6_501), getpid(), 6_501),
            (makeRefreshTestWindow(windowId: 6_502), getpid(), 6_502)
        ])
        controller.axManager.currentWindowsAsyncOverride = {
            let snapshot = visibleWindows.value
            if injectLateCreate {
                injectLateCreate = false
                Task { @MainActor in
                    let builtWorkspaceId = fixture.primaryWorkspaceId
                    let newWindowId = 6_503
                    let token = controller.workspaceManager.addWindow(
                        makeRefreshTestWindow(windowId: newWindowId),
                        pid: getpid(),
                        windowId: newWindowId,
                        to: builtWorkspaceId
                    )
                    newToken = token
                    visibleWindows.value.append((makeRefreshTestWindow(windowId: newWindowId), getpid(), newWindowId))
                    lateCreateWasQueuedDuringFullRescan = controller.layoutRefreshController.layoutState.activeRefresh?
                        .kind == .fullRescan
                    controller.layoutRefreshController.requestRelayout(
                        reason: .axWindowCreated,
                        affectedWorkspaceIds: [builtWorkspaceId]
                    )
                }
            }
            return snapshot
        }
        await waitForRefreshWork(on: controller)

        controller.niriEngine?.roots.removeValue(forKey: fixture.primaryWorkspaceId)
        controller.niriEngine?.roots.removeValue(forKey: fixture.secondaryWorkspaceId)
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return false
        }
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            return false
        }

        injectLateCreate = true
        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitForRefreshWork(on: controller)
        guard let newToken else {
            Issue.record("Missing late Niri create token")
            return
        }

        #expect(fullRescanReasons == [.startup])
        #expect(lateCreateWasQueuedDuringFullRescan)
        #expect(relayoutEvents.map(\.0) == [.axWindowCreated])
        #expect(relayoutEvents.map(\.1) == [.relayout])
        #expect(controller.workspaceManager.entry(for: newToken) != nil)
        #expect(niriTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId).contains(newToken))
        #expect(niriTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId) ==
            workspaceManagerTokenSet(
                controller: controller,
                workspaceId: fixture.primaryWorkspaceId
            ))
        #expect(niriTokenSet(controller: controller, workspaceId: fixture.primaryWorkspaceId)
            .contains(primaryHandle.id))
        #expect(controller.workspaceManager.entry(for: secondaryHandle.id) != nil)
    }

    @Test @MainActor func sameWorkspaceWindowRemovalPreservesMultiplePayloads() async {
        let controller = makeRefreshTestController()
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let gate = AsyncGate()
        var observedPayloadCounts: [Int] = []
        controller.layoutRefreshController.debugHooks.onRelayout = { _, route in
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onWindowRemoval = { reason, payloads in
            if reason == .windowDestroyed {
                observedPayloadCounts.append(payloads.count)
            }
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        controller.layoutRefreshController.requestWindowRemoval(
            workspaceId: workspaceId,
                        removedNodeId: NodeId(),
            niriOldFrames: [WindowToken(pid: getpid(), windowId: 4011): CGRect(x: 0, y: 0, width: 100, height: 100)],
            shouldRecoverFocus: false
        )
        controller.layoutRefreshController.requestWindowRemoval(
            workspaceId: workspaceId,
                        removedNodeId: NodeId(),
            niriOldFrames: [WindowToken(pid: getpid(), windowId: 4012): CGRect(x: 100, y: 0, width: 100, height: 100)],
            shouldRecoverFocus: false
        )
        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(observedPayloadCounts == [2])
    }

    @Test @MainActor func immediateRelayoutSupersedesPendingDebouncedRelayout() async {
        let controller = makeRefreshTestController()
        controller.layoutRefreshController.resetDebugState()

        controller.layoutRefreshController.requestRelayout(reason: .axWindowCreated)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitForRefreshWork(on: controller)

        #expect(controller.layoutRefreshController.debugCounters.relayoutExecutions == 0)
        #expect(controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.fullRescanExecutions == 0)
    }

    @Test @MainActor func scopedRelayoutDoesNotNarrowPendingGlobalRelayout() async {
        let controller = makeRefreshTestController()
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        var affectedWorkspaceSnapshots: [Set<WorkspaceDescriptor.ID>] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { _, _ in
            affectedWorkspaceSnapshots.append(
                controller.layoutRefreshController.layoutState.activeRefresh?.affectedWorkspaceIds ?? []
            )
            return true
        }

        controller.layoutRefreshController.requestRelayout(reason: .gapsChanged)
        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [workspaceId]
        )
        await waitForRefreshWork(on: controller)

        #expect(affectedWorkspaceSnapshots.last == [])
    }

    @Test @MainActor func appLifecycleUsesFullRescan() async {
        let controller = makeRefreshTestController()
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        lifecycleManager.handleAppLaunched()
        await waitForRefreshWork(on: controller)

        #expect(recorder.fullRescanReasons == [.appLaunched])
        #expect(recorder.relayoutEvents.isEmpty)

        resetRefreshSpies(on: controller, recorder: recorder)
        lifecycleManager.handleAppTerminated(pid: getpid())
        await waitForRefreshWork(on: controller)

        #expect(recorder.fullRescanReasons == [.appTerminated])
        #expect(recorder.relayoutEvents.isEmpty)
    }

    @Test @MainActor func swapCurrentWorkspaceWithMonitorDoesNotRelayoutAcrossFixedHomes() async {
        let fixture = makeTwoMonitorRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.workspaceNavigationHandler.swapCurrentWorkspaceWithMonitor(direction: .right)
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func moveWindowToWorkspaceOnMonitorUsesImmediateRelayoutOnly() async {
        let fixture = makeTwoMonitorRefreshTestController()
        fixture.controller.settings.focusFollowsWindowToMonitor = true
        _ = await prepareNiriState(
            on: fixture.controller,
            assignments: [(fixture.primaryWorkspaceId, 403)],
            focusedWindowId: 403,
            ensureWorkspaces: [fixture.secondaryWorkspaceId]
        )
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.workspaceNavigationHandler.moveWindowToWorkspaceOnMonitor(
            workspaceIndex: 1,
            monitorDirection: .right
        )
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func navigateToWindowInternalUsesImmediateRelayoutOnly() async {
        let fixture = makeTwoMonitorRefreshTestController()
        let handlesByWindowId = await prepareNiriState(
            on: fixture.controller,
            assignments: [
                (fixture.primaryWorkspaceId, 404),
                (fixture.secondaryWorkspaceId, 405)
            ],
            focusedWindowId: 404,
            ensureWorkspaces: [fixture.secondaryWorkspaceId]
        )
        guard let targetHandle = handlesByWindowId[405] else {
            Issue.record("Missing target window handle")
            return
        }

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: fixture.controller, recorder: recorder)

        fixture.controller.windowActionHandler.navigateToWindowInternal(
            handle: targetHandle,
            workspaceId: fixture.secondaryWorkspaceId
        )
        await waitForRefreshWork(on: fixture.controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.fullRescanReasons.isEmpty)
    }

    @Test @MainActor func focusWindowFromBarRevealsHiddenWindowOnInteractionWorkspace() async {
        var focusRequests: [(pid_t, UInt32)] = []
        let controller = makeRefreshTestController(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusRequests.append((pid, windowId))
                },
                raiseWindow: { _ in }
            )
        )
        guard let workspaceOne = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false),
              let workspaceTwo = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
              let monitor = controller.workspaceManager.monitors.first
        else {
            Issue.record("Missing same-monitor workspace-bar reveal fixture")
            return
        }

        let handlesByWindowId = await prepareNiriState(
            on: controller,
            assignments: [
                (workspaceOne, 431),
                (workspaceTwo, 432)
            ],
            focusedWindowId: 431,
            ensureWorkspaces: [workspaceTwo]
        )
        guard let targetHandle = handlesByWindowId[432] else {
            Issue.record("Missing target window handle for workspace-bar reveal test")
            return
        }

        let targetToken = targetHandle.id
        let hiddenFrame = CGRect(x: -1400, y: 140, width: 760, height: 520)
        controller.axManager.applyFramesParallel([(targetToken.pid, targetToken.windowId, hiddenFrame)])
        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: targetToken, monitor: monitor)
        controller.axManager.markWindowInactive(targetToken.windowId)
        controller.axEventHandler.isFullscreenProvider = { _ in false }
        controller.axEventHandler.focusedWindowRefProvider = { pid in
            guard pid == targetToken.pid else { return nil }
            return makeRefreshTestWindow(windowId: targetToken.windowId)
        }

        let didStartFocus = controller.windowActionHandler.focusWindowFromBar(token: targetToken)
        #expect(didStartFocus)
        await waitForRefreshWork(on: controller)
        await waitUntil {
            controller.interactionWorkspace()?.id == workspaceTwo &&
                controller.workspaceManager.hiddenState(for: targetToken) == nil &&
                !controller.axManager.inactiveWorkspaceWindowIds.contains(targetToken.windowId) &&
                controller.workspaceManager.activeFocusRequestToken == targetToken &&
                focusRequests.contains { $0.0 == targetToken.pid && $0.1 == UInt32(targetToken.windowId) }
        }

        #expect(controller.interactionWorkspace()?.id == workspaceTwo)
        #expect(controller.workspaceManager.activeFocusRequestToken == targetToken)
        #expect(controller.workspaceManager.hiddenState(for: targetToken) == nil)
        #expect(!controller.axManager.inactiveWorkspaceWindowIds.contains(targetToken.windowId))
        #expect(focusRequests.contains { $0.0 == targetToken.pid && $0.1 == UInt32(targetToken.windowId) })

        guard let appliedFrame = controller.axManager.lastAppliedFrame(for: targetToken.windowId) else {
            Issue.record("Expected visible frame for workspace-bar reveal")
            return
        }
        #expect(monitor.visibleFrame.contains(CGPoint(x: appliedFrame.midX, y: appliedFrame.midY)))
    }

    @Test @MainActor func conservativeLifecycleAndPolicyCallersUseFullRescan() async {
        let controller = makeRefreshTestController()
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)

        lifecycleManager.performStartupRefresh()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.startup])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        lifecycleManager.handleAppLaunched()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.appLaunched])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        lifecycleManager.handleUnlockDetected()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.unlock])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        lifecycleManager.handleActiveSpaceDidChange()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.activeSpaceChanged])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        let otherMonitor = makeLayoutPlanSecondaryTestMonitor(name: "Secondary", x: 1920)
        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [otherMonitor],
            performPostUpdateActions: true
        )
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.monitorConfigurationChanged])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        controller.updateWorkspaceConfig()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.workspaceConfigChanged])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        controller.updateAppRules()
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.appRulesChanged])
        #expect(recorder.relayoutEvents.isEmpty)

        recorder.fullRescanReasons.removeAll()
        lifecycleManager.handleAppTerminated(pid: getpid())
        await waitForRefreshWork(on: controller)
        #expect(recorder.fullRescanReasons == [.appTerminated])
        #expect(recorder.relayoutEvents.isEmpty)
    }

    @Test func destroyNotificationRefconRoundTripsWindowId() {
        let windowId = 6202
        let refcon = AppAXContext.destroyNotificationRefcon(for: windowId)

        #expect(refcon != nil)
        #expect(AppAXContext.destroyNotificationWindowId(from: refcon) == windowId)
        #expect(AppAXContext.destroyNotificationWindowId(from: nil) == nil)
    }

    @Test @MainActor func destroyCallbackDispatchesEncodedWindowId() async {
        let pid = getpid()
        let windowId = 6302
        var delivered: (pid_t, Int)?

        AppAXContext.handleWindowDestroyedCallback(
            pid: pid,
            refcon: AppAXContext.destroyNotificationRefcon(for: windowId),
            handler: { callbackPid, callbackWindowId in
                delivered = (callbackPid, callbackWindowId)
            }
        )
        await waitUntil { delivered != nil }

        #expect(delivered?.0 == pid)
        #expect(delivered?.1 == windowId)
    }

    @Test @MainActor func exactDestroyCallbackRemovesClosedWindowWithoutFullRescan() async {
        let controller = makeRefreshTestController()
        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let survivorWindowId = 6401
        let removedWindowId = 6402
        _ = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: survivorWindowId)
        _ = addWindow(on: controller, workspaceId: workspaceId, pid: pid, windowId: removedWindowId)

        AppAXContext.handleWindowDestroyedCallback(
            pid: pid,
            refcon: AppAXContext.destroyNotificationRefcon(for: removedWindowId),
            handler: { [weak controller] callbackPid, callbackWindowId in
                controller?.axEventHandler.handleRemoved(pid: callbackPid, winId: callbackWindowId)
            }
        )
        await waitUntil {
            controller.workspaceManager.entry(forPid: pid, windowId: removedWindowId) == nil
        }
        await waitForRefreshWork(on: controller)

        #expect(controller.workspaceManager.entry(forPid: pid, windowId: survivorWindowId) != nil)
        #expect(controller.workspaceManager.entry(forPid: pid, windowId: removedWindowId) == nil)
        #expect(controller.workspaceManager.entries(in: workspaceId).map(\.windowId) == [survivorWindowId])
        #expect(recorder.fullRescanReasons.isEmpty)
        #expect(recorder.relayoutEvents.isEmpty)
        #expect(recorder.windowRemovalReasons == [.windowDestroyed])
    }

    @Test @MainActor func frameChangedBurstReachesRefreshSchedulingAsSingleRelayout() async {
        await withCGSEventObserverIsolationForTests {
            let controller = makeRefreshTestController()
            let recorder = RefreshEventRecorder()
            installRefreshSpies(on: controller, recorder: recorder)
            guard let workspaceId = controller.interactionWorkspace()?.id else {
                Issue.record("Missing active workspace")
                return
            }

            _ = addWindow(on: controller, workspaceId: workspaceId, pid: getpid(), windowId: 6403)

            let observer = CGSEventObserver.shared
            observer.resetDebugStateForTests()
            observer.delegate = controller.axEventHandler
            defer {
                observer.delegate = nil
                observer.resetDebugStateForTests()
            }

            observer.enqueueEventForTests(.frameChanged(windowId: 6403))
            observer.enqueueEventForTests(.frameChanged(windowId: 6403))
            observer.flushPendingCGSEventsForTests()
            await waitForRefreshWork(on: controller)

            #expect(recorder.relayoutEvents.map(\.0) == [.axWindowChanged])
            #expect(recorder.relayoutEvents.map(\.1) == [.relayout])
            #expect(
                controller.layoutRefreshController.refreshDebugSnapshot()
                    .lastAffectedWorkspaceIdsByReason[.axWindowChanged] == [workspaceId]
            )
            #expect(recorder.fullRescanReasons.isEmpty)
            #expect(recorder.visibilityReasons.isEmpty)
        }
    }

    @Test @MainActor func relayoutQueuedBehindActiveImmediateRelayoutStillExecutes() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestRelayout(reason: .gapsChanged)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(relayoutEvents.map(\.0) == [.workspaceTransition, .gapsChanged])
        #expect(relayoutEvents.map(\.1) == [.immediateRelayout, .relayout])
    }

    @Test @MainActor func visibilityRefreshCoalescesWhilePending() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        let recorder = RefreshEventRecorder()

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
            recorder.visibilityReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appUnhidden)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.visibilityReasons == [.appUnhidden])
        #expect(controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 1)
    }

    @Test @MainActor func pendingVisibilityRefreshUpgradesToRelayout() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        let recorder = RefreshEventRecorder()

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
            recorder.visibilityReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
        controller.layoutRefreshController.requestRelayout(reason: .gapsChanged)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition, .gapsChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout, .relayout])
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 0)
    }

    @Test @MainActor func pendingVisibilityRefreshUpgradesToFullRescan() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        let recorder = RefreshEventRecorder()

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
            recorder.visibilityReasons.append(reason)
            return true
        }
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            recorder.fullRescanReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
        controller.layoutRefreshController.requestFullRescan(reason: .startup)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.fullRescanReasons == [.startup])
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 0)
    }

    @Test @MainActor func activeFullRescanAbsorbsVisibilityReconciliation() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let handle = addFocusedWindow(on: controller, workspaceId: workspaceId, windowId: 307)
        primeFocusedBorder(on: controller, handle: handle)
        #expect(lastAppliedBorderWindowId(on: controller) == 307)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            recorder.fullRescanReasons.append(reason)
            await gate.wait()
            return true
        }

        controller.layoutRefreshController.requestFullRescan(reason: .startup)
        await waitUntil { recorder.fullRescanReasons == [.startup] }
        controller.axEventHandler.handleAppHidden(pid: pid)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.fullRescanReasons == [.startup])
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 0)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func pendingRelayoutAbsorbsVisibilityReconciliation() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        guard let workspaceId = controller.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace")
            return
        }

        let pid = getpid()
        let handle = addFocusedWindow(on: controller, workspaceId: workspaceId, windowId: 308)
        primeFocusedBorder(on: controller, handle: handle)
        #expect(lastAppliedBorderWindowId(on: controller) == 308)

        let recorder = RefreshEventRecorder()
        installRefreshSpies(on: controller, recorder: recorder)
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestRelayout(reason: .gapsChanged)
        controller.axEventHandler.handleAppHidden(pid: pid)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition, .gapsChanged])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout, .relayout])
        #expect(recorder.visibilityReasons.isEmpty)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 0)
        #expect(lastAppliedBorderWindowId(on: controller) == nil)
    }

    @Test @MainActor func visibilityQueuedBehindActiveImmediateRelayoutStillExecutes() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        let recorder = RefreshEventRecorder()

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            recorder.relayoutEvents.append((reason, route))
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onVisibilityRefresh = { reason in
            recorder.visibilityReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await waitUntil { recorder.relayoutEvents.count == 1 }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(recorder.relayoutEvents.map(\.0) == [.workspaceTransition])
        #expect(recorder.relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(recorder.visibilityReasons == [.appHidden])
        #expect(controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1)
        #expect(controller.layoutRefreshController.debugCounters.visibilityExecutions == 1)
    }

    @Test @MainActor func canceledImmediateRelayoutPreservesPostLayoutActionsWhenUpgradedToFullRescan() async {
        let controller = makeRefreshTestController()
        let gate = AsyncGate()
        var fullRescanReasons: [RefreshReason] = []
        var postLayoutRuns = 0

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { _, route in
            if route == .immediateRelayout {
                await gate.wait()
            }
            return true
        }
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            fullRescanReasons.append(reason)
            return true
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition) {
            postLayoutRuns += 1
        }
        await waitUntil { controller.layoutRefreshController.debugCounters.immediateRelayoutExecutions == 1 }
        controller.layoutRefreshController.requestFullRescan(reason: .startup)

        gate.open()
        await waitForRefreshWork(on: controller)

        #expect(fullRescanReasons == [.startup])
        #expect(postLayoutRuns == 1)
    }
}
