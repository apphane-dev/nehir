import AppKit
import ApplicationServices
import Foundation
@testable import Nehir
import Testing

private func makeCommandPaletteTestDefaults() -> UserDefaults {
    let suiteName = "dev.guria.nehir.commandpalette.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

@MainActor
private func makeCommandPaletteTestWMController() -> WMController {
    WMController(settings: SettingsStore(defaults: makeCommandPaletteTestDefaults()))
}

private func makeCommandPaletteWindowItem(windowId: Int) -> CommandPaletteWindowItem {
    let handle = WindowHandle(id: WindowToken(pid: 4242, windowId: windowId))
    return CommandPaletteWindowItem(
        id: handle.id,
        handle: handle,
        title: "Window \(windowId)",
        appName: "Test App",
        appIcon: nil,
        workspaceName: "1"
    )
}


@MainActor
private func makeCommandPaletteSummonAnchor(
    wmController: WMController,
    windowId: Int = 11
) -> CommandPaletteSummonAnchor {
    guard let workspaceId = wmController.interactionWorkspace()?.id else {
        fatalError("Expected active workspace for summon-anchor test fixture")
    }
    return .init(
        token: WindowToken(pid: 4343, windowId: windowId),
        workspaceId: workspaceId
    )
}

private func makeCommandPaletteAppSnapshot(
    pid: pid_t,
    bundleIdentifier: String?,
    localizedName: String?,
    isTerminated: Bool = false
) -> CommandPaletteAppSnapshot {
    CommandPaletteAppSnapshot(
        processIdentifier: pid,
        bundleIdentifier: bundleIdentifier,
        localizedName: localizedName,
        isTerminated: isTerminated
    )
}

@Suite(.serialized) @MainActor struct CommandPaletteControllerTests {
    @Test func toggleShowsPaletteWhenHidden() {
        var environment = CommandPaletteEnvironment()
        environment.activateNehir = {}
        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()

        defer {
            if controller.isVisible {
                controller.toggle(wmController: wmController)
            }
        }

        controller.toggle(wmController: wmController)

        #expect(controller.isVisible)
    }

    @Test func palettePanelRegistersAsOwnedAndCreateEventIsSkipped() async {
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        var environment = CommandPaletteEnvironment()
        environment.activateNehir = {}
        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        var windowInfoLookups = 0
        var axRefLookups = 0
        var factLookups = 0
        var subscriptions: [[UInt32]] = []

        defer {
            if controller.isVisible {
                controller.toggle(wmController: wmController)
            }
            registry.resetForTests()
        }

        controller.toggle(wmController: wmController)
        guard let panel = controller.panelForTests else {
            Issue.record("Missing command palette panel")
            return
        }
        let panelWindowId = UInt32(panel.windowNumber)
        guard panelWindowId > 0 else {
            Issue.record("Missing command palette window number")
            return
        }

        wmController.axEventHandler.windowInfoProvider = { windowId in
            windowInfoLookups += 1
            return WindowServerInfo(id: windowId, pid: getpid(), level: 0, frame: panel.frame)
        }
        wmController.axEventHandler.axWindowRefProvider = { windowId, _ in
            axRefLookups += 1
            return AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: Int(windowId))
        }
        wmController.axEventHandler.windowFactsProvider = { _, _ in
            factLookups += 1
            return WindowRuleFacts(
                appName: "Nehir",
                ax: AXWindowFacts(
                    role: kAXWindowRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    title: "Command Palette",
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: nil,
                    hasZoomButton: false,
                    hasMinimizeButton: false,
                    appPolicy: .accessory,
                    bundleId: Bundle.main.bundleIdentifier,
                    attributeFetchSucceeded: true
                ),
                sizeConstraints: nil,
                windowServer: nil
            )
        }
        wmController.axEventHandler.windowSubscriptionHandler = { windowIds in
            subscriptions.append(windowIds)
        }
        wmController.layoutRefreshController.resetDebugState()

        wmController.axEventHandler.cgsEventObserver(
            CGSEventObserver.shared,
            didReceive: .created(windowId: panelWindowId, spaceId: 0)
        )
        await wmController.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(registry.contains(window: panel))
        #expect(registry.contains(windowNumber: Int(panelWindowId)))
        #expect(panel.collectionBehavior.contains(.moveToActiveSpace))
        #expect(wmController.workspaceManager.entry(forPid: getpid(), windowId: Int(panelWindowId)) == nil)
        #expect(subscriptions.isEmpty)
        #expect(wmController.layoutRefreshController.debugCounters.relayoutExecutions == 0)
        #expect(windowInfoLookups == 0)
        #expect(axRefLookups == 0)
        #expect(factLookups == 0)
    }

    @Test func toggleHidesVisiblePaletteAndClearsTransientState() {
        var environment = CommandPaletteEnvironment()
        environment.activateNehir = {}
        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()

        guard let workspaceId = wmController.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace for command palette toggle test")
            return
        }

        _ = wmController.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 707),
            pid: 4242,
            windowId: 707,
            to: workspaceId
        )

        defer {
            if controller.isVisible {
                controller.toggle(wmController: wmController)
            }
        }

        controller.toggle(wmController: wmController)
        controller.searchText = "Unknown"

        #expect(controller.isVisible)
        #expect(controller.filteredWindowItems.count == 1)
        #expect(controller.selectedItemID == .window(WindowToken(pid: 4242, windowId: 707)))

        controller.toggle(wmController: wmController)

        #expect(controller.isVisible == false)
        #expect(controller.searchText.isEmpty)
        #expect(controller.selectedItemID == nil)
        #expect(controller.filteredWindowItems.isEmpty)
    }

    @Test func motionToggleKeepsLivePanelAndSelectionState() throws {
        var environment = CommandPaletteEnvironment()
        environment.activateNehir = {}
        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()

        guard let workspaceId = wmController.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace for command palette motion test")
            return
        }

        _ = wmController.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 808),
            pid: 4343,
            windowId: 808,
            to: workspaceId
        )

        defer {
            if controller.isVisible {
                controller.toggle(wmController: wmController)
            }
        }

        controller.toggle(wmController: wmController)
        let panel = try #require(controller.panelForTests)
        let contentView = try #require(panel.contentView)

        controller.searchText = "Window"
        let expectedSelection = CommandPaletteSelectionID.window(WindowToken(pid: 4343, windowId: 808))
        controller.selectedItemID = expectedSelection

        #expect(controller.selectedItemID == expectedSelection)


        #expect(controller.isVisible)
        #expect(controller.searchText == "Window")
        #expect(controller.selectedItemID == expectedSelection)
        #expect(controller.panelForTests === panel)
        #expect(controller.panelForTests?.contentView === contentView)
    }

    @Test func selectCurrentNavigatesSelectedWindowAfterDismiss() {
        var navigatedHandle: WindowHandle?
        var environment = CommandPaletteEnvironment()
        environment.navigateToWindow = { _, handle in
            navigatedHandle = handle
        }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        let item = makeCommandPaletteWindowItem(windowId: 101)

        controller.setWindowSelectionStateForTests(
            wmController: wmController,
            items: [item],
            selectedItemID: .window(item.id)
        )

        controller.selectCurrent()

        #expect(navigatedHandle == item.handle)
        #expect(controller.selectedItemID == nil)
        #expect(controller.filteredWindowItems.isEmpty)
    }

    @Test func selectCurrentUsesUpdatedWindowSelection() {
        var navigatedHandle: WindowHandle?
        var environment = CommandPaletteEnvironment()
        environment.navigateToWindow = { _, handle in
            navigatedHandle = handle
        }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        let first = makeCommandPaletteWindowItem(windowId: 101)
        let second = makeCommandPaletteWindowItem(windowId: 202)

        controller.setWindowSelectionStateForTests(
            wmController: wmController,
            items: [first, second],
            selectedItemID: .window(second.id)
        )

        controller.selectCurrent()

        #expect(navigatedHandle == second.handle)
    }

    @Test func selectCurrentSummonsSelectedWindowAfterDismiss() {
        var summonedHandle: WindowHandle?
        var summonedAnchorToken: WindowToken?
        var summonedAnchorWorkspaceId: WorkspaceDescriptor.ID?
        var environment = CommandPaletteEnvironment()
        environment.summonWindowRight = { _, handle, anchorToken, anchorWorkspaceId in
            summonedHandle = handle
            summonedAnchorToken = anchorToken
            summonedAnchorWorkspaceId = anchorWorkspaceId
        }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        let item = makeCommandPaletteWindowItem(windowId: 303)
        let summonAnchor = makeCommandPaletteSummonAnchor(wmController: wmController)

        controller.setWindowSelectionStateForTests(
            wmController: wmController,
            items: [item],
            selectedItemID: .window(item.id),
            summonAnchor: summonAnchor
        )

        controller.selectCurrent(trigger: .alternate)

        #expect(summonedHandle == item.handle)
        #expect(summonedAnchorToken == summonAnchor.token)
        #expect(summonedAnchorWorkspaceId == summonAnchor.workspaceId)
        #expect(controller.selectedItemID == nil)
        #expect(controller.filteredWindowItems.isEmpty)
    }

    @Test func selectCurrentDoesNotSummonWithoutAnchor() {
        var didSummon = false
        var environment = CommandPaletteEnvironment()
        environment.summonWindowRight = { _, _, _, _ in
            didSummon = true
        }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        let item = makeCommandPaletteWindowItem(windowId: 404)

        controller.setWindowSelectionStateForTests(
            wmController: wmController,
            items: [item],
            selectedItemID: .window(item.id)
        )

        controller.selectCurrent(trigger: .alternate)

        #expect(didSummon == false)
        #expect(controller.selectedItemID == .window(item.id))
        #expect(controller.filteredWindowItems.map(\.id) == [item.id])
    }

    @Test func resolveMenuTargetPrefersCurrentExternalApp() {
        let current = makeCommandPaletteAppSnapshot(
            pid: 200,
            bundleIdentifier: "com.apple.Safari",
            localizedName: "Safari"
        )
        let cached = makeCommandPaletteAppSnapshot(
            pid: 201,
            bundleIdentifier: "com.apple.TextEdit",
            localizedName: "TextEdit"
        )

        let resolved = CommandPaletteController.resolveMenuTarget(
            current: current,
            cached: cached,
            ownBundleIdentifier: "dev.guria.nehir"
        )

        #expect(resolved == current)
    }

    @Test func resolveMenuTargetFallsBackToCachedExternalAppWhenCurrentIsNehir() {
        let current = makeCommandPaletteAppSnapshot(
            pid: 300,
            bundleIdentifier: "dev.guria.nehir",
            localizedName: "Nehir"
        )
        let cached = makeCommandPaletteAppSnapshot(
            pid: 301,
            bundleIdentifier: "com.apple.Finder",
            localizedName: "Finder"
        )

        let resolved = CommandPaletteController.resolveMenuTarget(
            current: current,
            cached: cached,
            ownBundleIdentifier: "dev.guria.nehir"
        )

        #expect(resolved == cached)
    }

    @Test func resolveMenuTargetIgnoresTerminatedCachedApp() {
        let current = makeCommandPaletteAppSnapshot(
            pid: 400,
            bundleIdentifier: "dev.guria.nehir",
            localizedName: "Nehir"
        )
        let cached = makeCommandPaletteAppSnapshot(
            pid: 401,
            bundleIdentifier: "com.apple.Terminal",
            localizedName: "Terminal",
            isTerminated: true
        )

        let resolved = CommandPaletteController.resolveMenuTarget(
            current: current,
            cached: cached,
            ownBundleIdentifier: "dev.guria.nehir"
        )

        #expect(resolved == nil)
    }

    @Test func menuModeCachesMenuItemsPerPidWithinVisibleSession() async {
        var fetchCount = 0
        var environment = CommandPaletteEnvironment()
        environment.fetchMenuItems = { pid in
            fetchCount += 1
            return [
                MenuItemModel(
                    title: "Reload \(pid)",
                    fullPath: "File > Reload",
                    keyboardShortcut: nil,
                    axElement: AXUIElementCreateSystemWide(),
                    parentTitles: ["File"]
                )
            ]
        }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        let target = makeCommandPaletteAppSnapshot(
            pid: 410,
            bundleIdentifier: "com.apple.Safari",
            localizedName: "Safari"
        )

        controller.setMenuLoadingStateForTests(wmController: wmController, target: target)
        controller.loadMenuItemsForTests()
        try? await Task.sleep(for: .milliseconds(5))
        controller.loadMenuItemsForTests()
        try? await Task.sleep(for: .milliseconds(5))

        #expect(fetchCount == 1)
        #expect(controller.menuItems.count == 1)
    }

    @Test func command2SwitchesOnlyWhenMenuModeIsAvailable() {
        let controller = CommandPaletteController()
        controller.selectedMode = .windows
        controller.setMenuAvailabilityForTests(nil)

        #expect(controller.handleModeShortcutForTests("2") == false)
        #expect(controller.selectedMode == .windows)

        controller.setMenuAvailabilityForTests(
            makeCommandPaletteAppSnapshot(
                pid: 500,
                bundleIdentifier: "com.apple.Safari",
                localizedName: "Safari"
            )
        )

        #expect(controller.handleModeShortcutForTests("2") == true)
        #expect(controller.selectedMode == .menu)
    }


    @Test func command1SwitchesBackToWindowsMode() {
        let controller = CommandPaletteController()
        controller.setMenuAvailabilityForTests(
            makeCommandPaletteAppSnapshot(
                pid: 501,
                bundleIdentifier: "com.apple.Finder",
                localizedName: "Finder"
            )
        )
        controller.selectedMode = .menu

        #expect(controller.handleModeShortcutForTests("1") == true)
        #expect(controller.selectedMode == .windows)
    }

    @Test func modeHintMatchesDisplayedShortcuts() {
        #expect(
            CommandPaletteController.modeHint(for: .windows)
                == .init(title: "Windows", shortcut: "⌘1")
        )
        #expect(
            CommandPaletteController.modeHint(for: .menu)
                == .init(title: "Menu", shortcut: "⌘2")
        )
    }

    @Test func selectedWindowHintReflectsSummonAvailability() {
        #expect(
            CommandPaletteController.selectedWindowHint(isSummonRightAvailable: true)
                == .init(title: "Summon Right", shortcut: "⇧↩")
        )
        #expect(CommandPaletteController.selectedWindowHint(isSummonRightAvailable: false) == nil)
    }

    @Test func windowsStatusTextReflectsSummonAvailability() {
        #expect(
            CommandPaletteController.windowsStatusText(isSummonRightAvailable: true)
                == "Enter jumps. Shift-Enter summons right."
        )
        #expect(
            CommandPaletteController.windowsStatusText(isSummonRightAvailable: false)
                == "Enter jumps. Shift-Enter unavailable for this session."
        )
    }

    @Test func selectionTriggerHandlesReturnAndKeypadEnter() {
        let controller = CommandPaletteController()

        #expect(controller.selectionTriggerForTests(keyCode: 36, modifierFlags: []) == .primary)
        #expect(controller.selectionTriggerForTests(keyCode: 76, modifierFlags: []) == .primary)
        #expect(controller.selectionTriggerForTests(keyCode: 36, modifierFlags: .shift) == .alternate)
        #expect(controller.selectionTriggerForTests(keyCode: 76, modifierFlags: .shift) == .alternate)
    }


    @Test func persistedMenuModeFallsBackToWindowsWhenUnavailable() {
        var environment = CommandPaletteEnvironment()
        environment.activateNehir = {}
        environment.frontmostApplication = { nil }

        let controller = CommandPaletteController(environment: environment)
        let wmController = makeCommandPaletteTestWMController()
        wmController.settings.commandPaletteLastMode = .menu

        defer {
            if controller.isVisible {
                controller.toggle(wmController: wmController)
            }
        }

        controller.toggle(wmController: wmController)

        #expect(controller.selectedMode == .windows)
    }






    @Test func resolveSummonAnchorFallsBackToLastFocusedMemory() {
        let wmController = makeCommandPaletteTestWMController()
        guard let workspaceId = wmController.interactionWorkspace()?.id else {
            Issue.record("Missing active workspace for summon-anchor test")
            return
        }

        let handle = WindowHandle(id: WindowToken(pid: 5151, windowId: 5151))
        let token = wmController.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: 5151),
            pid: handle.pid,
            windowId: handle.windowId,
            to: workspaceId
        )
        guard let storedHandle = wmController.workspaceManager.handle(for: token) else {
            Issue.record("Missing managed handle for summon-anchor test")
            return
        }

        _ = wmController.workspaceManager.rememberFocus(storedHandle, in: workspaceId)
        _ = wmController.workspaceManager.enterNonManagedFocus(appFullscreen: false)

        let anchor = CommandPaletteController.resolveSummonAnchor(for: wmController)

        #expect(anchor?.token == storedHandle.id)
        #expect(anchor?.workspaceId == workspaceId)
    }
}
