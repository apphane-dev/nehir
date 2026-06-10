import AppKit
import ApplicationServices
import Carbon
import SwiftUI

struct CommandPaletteWindowItem: Identifiable {
    let id: WindowToken
    let handle: WindowHandle
    let title: String
    let appName: String
    let appIcon: NSImage?
    let workspaceName: String
}

struct CommandPaletteAppSnapshot: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    let isTerminated: Bool

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        localizedName: String?,
        isTerminated: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.isTerminated = isTerminated
    }

    init(app: NSRunningApplication) {
        processIdentifier = app.processIdentifier
        bundleIdentifier = app.bundleIdentifier
        localizedName = app.localizedName
        isTerminated = app.isTerminated
    }
}

struct CommandPaletteSummonAnchor: Equatable {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
}

private struct CommandPaletteFocusTarget {
    let app: CommandPaletteAppSnapshot
    let focusedWindow: AXUIElement?
}

enum CommandPaletteSelectionID: Hashable {
    case window(WindowToken)
    case menu(UUID)
    case command(String)
}

struct CommandPaletteCommandItem: Identifiable {
    let id: String
    let command: HotkeyCommand
    let title: String
    let category: HotkeyCategory
    let bindingDisplay: String?
    let searchTerms: [String]
}

enum CommandPaletteSelectionTrigger {
    case primary
    case alternate
}

private final class CommandPaletteActionBox: @unchecked Sendable {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }
}


@MainActor
struct CommandPaletteEnvironment {
    var frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    var runningApplication: (pid_t) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) }
    var ownBundleIdentifier: () -> String? = { Bundle.main.bundleIdentifier }
    var fetchMenuItems: (pid_t) -> [MenuItemModel] = { MenuAnywhereFetcher().fetchMenuItemsSync(for: $0) }
    var activateNehir: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var navigateToWindow: (WMController, WindowHandle) -> Void = { controller, handle in
        controller.navigateToCommandPaletteWindow(handle)
    }

    var summonWindowRight: (WMController, WindowHandle, WindowToken, WorkspaceDescriptor.ID) -> Void = {
        controller,
        handle,
        anchorToken,
        anchorWorkspaceId in
        controller.summonCommandPaletteWindowRight(
            handle,
            anchorToken: anchorToken,
            anchorWorkspaceId: anchorWorkspaceId
        )
    }

    var scheduleMenuAction: (@escaping () -> Void) -> Void = { action in
        let box = CommandPaletteActionBox(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            box.action()
        }
    }

    var performMenuAction: (AXUIElement) -> Void = { element in
        AXUIElementPerformAction(element, "AXPress" as CFString)
    }

    var isAccessibilityTrusted: () -> Bool = {
        AXIsProcessTrusted()
    }

    var isLockScreenActive: (WMController) -> Bool = { controller in
        controller.isLockScreenActive
    }

    var focusedWindowID: (pid_t) -> CGWindowID? = { pid in
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
            let windowValue,
            CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return getWindowId(from: unsafeDowncast(windowValue, to: AXUIElement.self))
    }
}

private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class CommandPaletteController: NSObject, ObservableObject, NSWindowDelegate {
    static let unavailableMenuStatusText = "Open the palette while another app is frontmost to search its menus."

    struct InlineHint: Equatable {
        let title: String
        let shortcut: String
    }

    @Published private(set) var isVisible = false
    @Published var searchText = "" {
        didSet { updateSelectionAfterFilterChange() }
    }

    @Published var selectedMode: CommandPaletteMode = .windows {
        didSet { handleModeChange(from: oldValue) }
    }

    @Published var selectedItemID: CommandPaletteSelectionID?
    @Published private(set) var windows: [CommandPaletteWindowItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    @Published private(set) var menuItems: [MenuItemModel] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    @Published private(set) var commandItems: [CommandPaletteCommandItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    @Published private(set) var isMenuLoading = false

    private let environment: CommandPaletteEnvironment
    private let ownedWindowRegistry: OwnedWindowRegistry
    private var panel: NSPanel?
    private var eventMonitor: Any?

    private weak var wmController: WMController?
    private var restoreFocusTarget: CommandPaletteFocusTarget?
    private var menuFocusTarget: CommandPaletteFocusTarget?
    private var summonAnchor: CommandPaletteSummonAnchor?
    private var cachedMenuTargetApp: CommandPaletteAppSnapshot?
    private var sessionMenuCache: [pid_t: [MenuItemModel]] = [:]
    private var hasLoadedMenuItems = false
    private var menuLoadGeneration = 0
    private var isProgrammaticDismiss = false

    private enum DismissReason {
        case cancel
        case selection
        case deactivation
        case superseded
    }

    private enum SelectionAction {
        case navigateWindow(WMController, WindowHandle)
        case summonWindowRight(WMController, WindowHandle, CommandPaletteSummonAnchor)
        case pressMenu(CommandPaletteFocusTarget, AXUIElement)
        case executeCommand(WMController, HotkeyCommand)
    }

    init(
        environment: CommandPaletteEnvironment = .init(),
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        self.environment = environment
        self.ownedWindowRegistry = ownedWindowRegistry
        super.init()
    }

    var filteredWindowItems: [CommandPaletteWindowItem] {
        filterWindowItems(windows, query: searchText)
    }

    var filteredMenuItems: [MenuItemModel] {
        filterMenuItems(menuItems, query: searchText)
    }

    var filteredCommandItems: [CommandPaletteCommandItem] {
        filterCommandItems(commandItems, query: searchText)
    }

    var isMenuModeAvailable: Bool {
        Self.menuModeAvailable(hasMenuFocusTarget: menuFocusTarget != nil)
    }

    var isSummonRightAvailable: Bool {
        summonAnchor != nil
    }

    var menuStatusText: String {
        if let menuFocusTarget {
            return Self.availableMenuStatusText(for: menuFocusTarget.app.localizedName)
        }
        return Self.unavailableMenuStatusText
    }

    func toggle(wmController: WMController) {
        if isVisible {
            dismiss(reason: .cancel)
        } else {
            show(wmController: wmController)
        }
    }

    func show(wmController: WMController) {
        if isVisible {
            dismiss(reason: .superseded)
        }

        self.wmController = wmController

        restoreFocusTarget = captureFrontmostFocusTarget()
        menuFocusTarget = resolveMenuFocusTarget()
        summonAnchor = Self.resolveSummonAnchor(for: wmController)
        windows = buildWindowItems(from: wmController)
        commandItems = buildCommandItems(from: wmController)
        menuItems = []
        hasLoadedMenuItems = false
        sessionMenuCache.removeAll()
        isMenuLoading = false
        searchText = ""
        selectedItemID = nil
        menuLoadGeneration &+= 1

        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        positionPanel(panel)

        let preferredMode = wmController.settings.commandPaletteLastMode
        selectedMode = resolvedInitialMode(preferredMode)

        installEventMonitor()

        isVisible = true
        panel.makeKeyAndOrderFront(nil)
        environment.activateNehir()

        if selectedMode == .menu {
            loadMenuItemsIfNeeded()
        }

        DispatchQueue.main.async { [weak self] in
            self?.focusSearchField()
        }
    }

    static func menuModeAvailable(hasMenuFocusTarget: Bool) -> Bool {
        hasMenuFocusTarget
    }

    static func availableMenuStatusText(for appName: String?) -> String {
        "Searching menus in \(appName ?? "Current App")"
    }

    static func modeHint(for mode: CommandPaletteMode) -> InlineHint {
        switch mode {
        case .windows:
            InlineHint(title: mode.displayName, shortcut: "⌘1")
        case .menu:
            InlineHint(title: mode.displayName, shortcut: "⌘2")
        case .commands:
            InlineHint(title: mode.displayName, shortcut: "⌘3")
        }
    }

    static func selectedWindowHint(isSummonRightAvailable: Bool) -> InlineHint? {
        guard isSummonRightAvailable else { return nil }
        return InlineHint(title: "Summon Right", shortcut: "⇧↩")
    }

    static func windowsStatusText(isSummonRightAvailable: Bool) -> String {
        let summonText = if isSummonRightAvailable {
            "Shift-Enter summons right."
        } else {
            "Shift-Enter unavailable for this session."
        }
        return "Enter jumps. \(summonText)"
    }

    static func resolveSummonAnchor(for wmController: WMController) -> CommandPaletteSummonAnchor? {
        guard let activeWorkspace = wmController.interactionWorkspace() else { return nil }

        let anchorToken = if let focusedToken = wmController.workspaceManager.confirmedManagedFocusToken,
                             let entry = wmController.workspaceManager.entry(for: focusedToken),
                             entry.workspaceId == activeWorkspace.id
        {
            focusedToken
        } else {
            wmController.workspaceManager.preferredWorkspaceFocusToken(in: activeWorkspace.id)
        }

        guard let anchorToken,
              let entry = wmController.workspaceManager.entry(for: anchorToken),
              entry.workspaceId == activeWorkspace.id
        else {
            return nil
        }

        return .init(token: anchorToken, workspaceId: activeWorkspace.id)
    }

    static func resolveMenuTarget(
        current: CommandPaletteAppSnapshot?,
        cached: CommandPaletteAppSnapshot?,
        ownBundleIdentifier: String?
    ) -> CommandPaletteAppSnapshot? {
        sanitizedMenuTarget(current, ownBundleIdentifier: ownBundleIdentifier)
            ?? sanitizedMenuTarget(cached, ownBundleIdentifier: ownBundleIdentifier)
    }

    func windowDidResignKey(_: Notification) {
        guard isVisible, !isProgrammaticDismiss else { return }
        dismiss(reason: .deactivation)
    }

    private func handleModeChange(from oldValue: CommandPaletteMode) {
        guard selectedMode != oldValue else { return }
        guard isModeAvailable(selectedMode) else {
            selectedMode = .windows
            return
        }
        wmController?.settings.commandPaletteLastMode = selectedMode
        if selectedMode == .menu {
            loadMenuItemsIfNeeded()
        }
        updateSelectionAfterFilterChange()
        DispatchQueue.main.async { [weak self] in
            self?.focusSearchField()
        }
    }

    private func resolvedInitialMode(_ preferredMode: CommandPaletteMode) -> CommandPaletteMode {
        isModeAvailable(preferredMode) ? preferredMode : .windows
    }

    private func isModeAvailable(_ mode: CommandPaletteMode) -> Bool {
        switch mode {
        case .windows:
            return true
        case .menu:
            return isMenuModeAvailable
        case .commands:
            return true
        }
    }

    private func filterWindowItems(
        _ items: [CommandPaletteWindowItem],
        query rawQuery: String
    ) -> [CommandPaletteWindowItem] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return items
        }
        let query = trimmedQuery.lowercased()

        let scored: [(CommandPaletteWindowItem, Int)] = items.compactMap { item in
            let titleLower = item.title.lowercased()
            let appLower = item.appName.lowercased()

            if let range = titleLower.range(of: query) {
                let pos = titleLower.distance(from: titleLower.startIndex, to: range.lowerBound)
                return (item, pos)
            }

            if let range = appLower.range(of: query) {
                let pos = appLower.distance(from: appLower.startIndex, to: range.lowerBound)
                return (item, 1000 + pos)
            }

            return nil
        }

        return scored
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.title.count != b.0.title.count { return a.0.title.count < b.0.title.count }
                return a.0.title < b.0.title
            }
            .map(\.0)
    }

    private func filterMenuItems(_ items: [MenuItemModel], query rawQuery: String) -> [MenuItemModel] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return items
        }
        let query = trimmedQuery.lowercased()

        let scored: [(MenuItemModel, Int)] = items.compactMap { item in
            let titleLower = item.title.lowercased()
            let pathLower = item.fullPath.lowercased()

            if let range = titleLower.range(of: query) {
                let pos = titleLower.distance(from: titleLower.startIndex, to: range.lowerBound)
                return (item, pos)
            }

            if let range = pathLower.range(of: query) {
                let pos = pathLower.distance(from: pathLower.startIndex, to: range.lowerBound)
                return (item, 1000 + pos)
            }

            return nil
        }

        return scored
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.title.count != b.0.title.count { return a.0.title.count < b.0.title.count }
                return a.0.title < b.0.title
            }
            .map(\.0)
    }

    private func filterCommandItems(
        _ items: [CommandPaletteCommandItem],
        query rawQuery: String
    ) -> [CommandPaletteCommandItem] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty { return items }
        let normalized = ActionCatalog.normalizedSearchTerm(trimmedQuery)

        let scored: [(CommandPaletteCommandItem, Int)] = items.compactMap { item in
            for (i, term) in item.searchTerms.enumerated() {
                let normalizedTerm = ActionCatalog.normalizedSearchTerm(term)
                if let range = normalizedTerm.range(of: normalized) {
                    let pos = normalizedTerm.distance(from: normalizedTerm.startIndex, to: range.lowerBound)
                    return (item, i * 10000 + pos)
                }
            }
            return nil
        }

        return scored
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0.title < b.0.title
            }
            .map(\.0)
    }

    private func buildCommandItems(from wmController: WMController) -> [CommandPaletteCommandItem] {
        let bindingsByID = Dictionary(
            uniqueKeysWithValues: wmController.settings.hotkeyBindings.map { ($0.id, $0.binding) }
        )
        let developerModeEnabled = wmController.settings.developerModeEnabled
        return ActionCatalog.allSpecs()
            .filter { !$0.requiresDeveloperMode || developerModeEnabled }
            .map { spec in
                let trigger = bindingsByID[spec.id]
                let bindingDisplay = trigger.flatMap { $0.isUnassigned ? nil : $0.displayString }
                return CommandPaletteCommandItem(
                    id: spec.id,
                    command: spec.command,
                    title: spec.title,
                    category: spec.category,
                    bindingDisplay: bindingDisplay,
                    searchTerms: spec.searchTerms
                )
            }
    }

    private func buildWindowItems(from wmController: WMController) -> [CommandPaletteWindowItem] {
        let entries = wmController.workspaceManager.allEntries()
        var items: [CommandPaletteWindowItem] = []
        items.reserveCapacity(entries.count)

        for entry in entries {
            guard entry.layoutReason == .standard else { continue }

            let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)) ?? ""
            let appInfo = wmController.appInfoCache.info(for: entry.handle.pid)
            let workspaceName = wmController.workspaceManager.descriptor(for: entry.workspaceId)?.name ?? "?"

            items.append(CommandPaletteWindowItem(
                id: entry.handle.id,
                handle: entry.handle,
                title: title,
                appName: appInfo?.name ?? "Unknown",
                appIcon: appInfo?.icon,
                workspaceName: workspaceName
            ))
        }

        items.sort { ($0.appName, $0.title) < ($1.appName, $1.title) }
        return items
    }

    private func captureFrontmostFocusTarget() -> CommandPaletteFocusTarget? {
        guard let app = environment.frontmostApplication(),
              !app.isTerminated
        else {
            return nil
        }

        return captureFocusTarget(for: app)
    }

    private func resolveMenuFocusTarget() -> CommandPaletteFocusTarget? {
        let ownBundleIdentifier = environment.ownBundleIdentifier()
        let currentTarget = environment.frontmostApplication().map(CommandPaletteAppSnapshot.init(app:))
        if let currentTarget = Self.resolveMenuTarget(
            current: currentTarget,
            cached: nil,
            ownBundleIdentifier: ownBundleIdentifier
        ) {
            cachedMenuTargetApp = currentTarget
            return focusTarget(for: currentTarget)
        }

        let cachedTarget = liveCachedMenuTarget()
        guard let resolvedTarget = Self.resolveMenuTarget(
            current: nil,
            cached: cachedTarget,
            ownBundleIdentifier: ownBundleIdentifier
        ) else {
            return nil
        }
        return focusTarget(for: resolvedTarget)
    }

    private static func sanitizedMenuTarget(
        _ target: CommandPaletteAppSnapshot?,
        ownBundleIdentifier: String?
    ) -> CommandPaletteAppSnapshot? {
        guard let target, !target.isTerminated else { return nil }
        guard target.bundleIdentifier != ownBundleIdentifier else { return nil }
        return target
    }

    private func liveCachedMenuTarget() -> CommandPaletteAppSnapshot? {
        guard let cachedMenuTargetApp else { return nil }
        guard let app = environment.runningApplication(cachedMenuTargetApp.processIdentifier) else {
            self.cachedMenuTargetApp = nil
            return nil
        }

        let liveTarget = CommandPaletteAppSnapshot(app: app)
        guard !liveTarget.isTerminated else {
            self.cachedMenuTargetApp = nil
            return nil
        }

        if let expectedBundleIdentifier = cachedMenuTargetApp.bundleIdentifier,
           liveTarget.bundleIdentifier != expectedBundleIdentifier
        {
            self.cachedMenuTargetApp = nil
            return nil
        }

        self.cachedMenuTargetApp = liveTarget
        return liveTarget
    }

    private func captureFocusTarget(for app: NSRunningApplication) -> CommandPaletteFocusTarget {
        CommandPaletteFocusTarget(
            app: CommandPaletteAppSnapshot(app: app),
            focusedWindow: focusedWindow(for: app)
        )
    }

    private func focusTarget(for appSnapshot: CommandPaletteAppSnapshot) -> CommandPaletteFocusTarget? {
        guard let app = environment.runningApplication(appSnapshot.processIdentifier),
              !app.isTerminated
        else {
            if cachedMenuTargetApp?.processIdentifier == appSnapshot.processIdentifier {
                cachedMenuTargetApp = nil
            }
            return nil
        }

        return captureFocusTarget(for: app)
    }

    private func focusedWindow(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success else {
            return nil
        }
        guard let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(windowValue, to: AXUIElement.self)
    }

    private func loadMenuItemsIfNeeded() {
        guard isVisible, selectedMode == .menu else { return }
        guard isMenuModeAvailable else {
            menuItems = []
            isMenuLoading = false
            return
        }
        guard !hasLoadedMenuItems else { return }
        guard let menuFocusTarget else { return }

        let pid = menuFocusTarget.app.processIdentifier
        if let cached = sessionMenuCache[pid] {
            hasLoadedMenuItems = true
            menuItems = cached
            isMenuLoading = false
            return
        }

        hasLoadedMenuItems = true
        isMenuLoading = true
        menuItems = []
        let generation = menuLoadGeneration &+ 1
        menuLoadGeneration = generation

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isVisible,
                  self.menuLoadGeneration == generation,
                  self.selectedMode == .menu
            else {
                return
            }

            let items = self.environment.fetchMenuItems(pid)
            guard self.isVisible, self.menuLoadGeneration == generation else { return }
            self.sessionMenuCache[pid] = items
            self.menuItems = items
            self.isMenuLoading = false
        }
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isVisible else { return event }
            return handleKeyDown(event) ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let relevantModifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        let commandOnly = relevantModifiers == .command

        if commandOnly,
           let characters = event.charactersIgnoringModifiers,
           handleModeShortcut(characters)
        {
            return true
        }

        switch event.keyCode {
        case 53:
            dismiss(reason: .cancel)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        case 125:
            moveSelection(by: 1)
            return true
        default:
            guard let trigger = Self.selectionTrigger(
                forKeyCode: event.keyCode,
                modifierFlags: relevantModifiers
            ) else {
                return false
            }
            selectCurrent(trigger: trigger)
            return true
        }
    }

    private static func selectionTrigger(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> CommandPaletteSelectionTrigger? {
        switch keyCode {
        case 36,
             76:
            return modifierFlags == .shift ? .alternate : .primary
        default:
            return nil
        }
    }

    func moveSelection(by delta: Int) {
        let selectionList = currentSelectionList()
        guard !selectionList.isEmpty else { return }

        let currentIndex: Int = if let selectedItemID,
                                   let idx = selectionList.firstIndex(of: selectedItemID)
        {
            idx
        } else {
            0
        }

        let newIndex = (currentIndex + delta + selectionList.count) % selectionList.count
        selectedItemID = selectionList[newIndex]
    }

    func selectCurrent(trigger: CommandPaletteSelectionTrigger = .primary) {
        guard let action = resolvedSelectionAction(for: trigger) else { return }
        dismiss(reason: .selection)
        performSelectionAction(action)
    }

    private func dismiss(reason: DismissReason) {
        removeEventMonitor()
        isVisible = false
        isMenuLoading = false
        menuLoadGeneration &+= 1

        isProgrammaticDismiss = true
        panel?.orderOut(nil)
        isProgrammaticDismiss = false
        wmController?.handleOwnedFocusSuppressingWindowClosed()

        let restoreTarget = reason == .cancel ? restoreFocusTarget : nil

        restoreFocusTarget = nil
        menuFocusTarget = nil
        summonAnchor = nil
        wmController = nil
        hasLoadedMenuItems = false
        sessionMenuCache.removeAll()
        searchText = ""
        selectedItemID = nil
        windows = []
        menuItems = []
        commandItems = []

        if let restoreTarget {
            _ = focus(target: restoreTarget)
        }
    }

    private func handleModeShortcut(_ characters: String) -> Bool {
        switch characters {
        case "1":
            selectedMode = .windows
            return true
        case "2":
            guard isMenuModeAvailable else { return false }
            selectedMode = .menu
            return true
        case "3":
            selectedMode = .commands
            return true
        default:
            return false
        }
    }

    private func resolvedSelectionAction(
        for trigger: CommandPaletteSelectionTrigger
    ) -> SelectionAction? {
        switch selectedMode {
        case .windows:
            let filtered = filteredWindowItems
            guard let wmController,
                  case let .window(token)? = selectedItemID,
                  let item = filtered.first(where: { $0.id == token })
            else {
                return nil
            }
            switch trigger {
            case .primary:
                return .navigateWindow(wmController, item.handle)
            case .alternate:
                guard let summonAnchor else { return nil }
                return .summonWindowRight(wmController, item.handle, summonAnchor)
            }
        case .menu:
            let filtered = filteredMenuItems
            guard case let .menu(id)? = selectedItemID,
                  let item = filtered.first(where: { $0.id == id }),
                  let menuFocusTarget
            else {
                return nil
            }
            return .pressMenu(menuFocusTarget, item.axElement)
        case .commands:
            guard let wmController,
                  case let .command(id)? = selectedItemID,
                  let item = filteredCommandItems.first(where: { $0.id == id })
            else {
                return nil
            }
            return .executeCommand(wmController, item.command)
        }
    }

    private func performSelectionAction(_ action: SelectionAction) {
        switch action {
        case let .navigateWindow(wmController, handle):
            environment.navigateToWindow(wmController, handle)
        case let .summonWindowRight(wmController, handle, summonAnchor):
            environment.summonWindowRight(
                wmController,
                handle,
                summonAnchor.token,
                summonAnchor.workspaceId
            )
        case let .pressMenu(target, element):
            _ = focus(target: target)
            environment.scheduleMenuAction { [environment] in
                environment.performMenuAction(element)
            }
        case let .executeCommand(wmController, command):
            wmController.commandHandler.handleCommand(command)
        }
    }

    private func focus(target: CommandPaletteFocusTarget) -> Bool {
        guard let app = environment.runningApplication(target.app.processIdentifier),
              !app.isTerminated
        else {
            return false
        }

        if let focusedWindow = target.focusedWindow,
           let windowId = getWindowId(from: focusedWindow)
        {
            SkyLight.shared.orderWindow(UInt32(windowId), relativeTo: 0, order: .above)

            var psn = ProcessSerialNumber()
            if GetProcessForPID(target.app.processIdentifier, &psn) == noErr {
                _ = _SLPSSetFrontProcessWithOptions(&psn, UInt32(windowId), kCPSUserGenerated)
                makeKeyWindow(psn: &psn, windowId: UInt32(windowId))
            }
        }

        app.activate(options: [])
        return true
    }







    private func currentSelectionList() -> [CommandPaletteSelectionID] {
        switch selectedMode {
        case .windows:
            return filteredWindowItems.map { CommandPaletteSelectionID.window($0.id) }
        case .menu:
            return filteredMenuItems.map { CommandPaletteSelectionID.menu($0.id) }
        case .commands:
            return filteredCommandItems.map { CommandPaletteSelectionID.command($0.id) }
        }
    }

    private func updateSelectionAfterFilterChange() {
        let selectionList = currentSelectionList()
        if selectionList.isEmpty {
            selectedItemID = nil
            return
        }

        if let selectedItemID, !selectionList.contains(selectedItemID) {
            self.selectedItemID = selectionList.first
        } else if selectedItemID == nil {
            selectedItemID = selectionList.first
        }
    }

    private func createPanel() {
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.delegate = self
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace]

        let hostingView = NSHostingView(rootView: makeRootView())
        panel.contentView = hostingView

        ownedWindowRegistry.register(panel)
        self.panel = panel
    }

    private func makeRootView() -> CommandPaletteView {
        CommandPaletteView(controller: self)
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main else { return }

        let panelWidth: CGFloat = 620
        let panelHeight: CGFloat = 430
        let x = screen.frame.midX - panelWidth / 2
        let y = screen.frame.midY - panelHeight / 2 + 80
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField, textField.isEditable {
            return textField
        }
        for subview in view.subviews {
            if let found = findTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    private func focusSearchField() {
        guard let contentView = panel?.contentView,
              let textField = findTextField(in: contentView)
        else {
            return
        }
        panel?.makeFirstResponder(textField)
    }

    func setWindowSelectionStateForTests(
        wmController: WMController,
        items: [CommandPaletteWindowItem],
        selectedItemID: CommandPaletteSelectionID?,
        summonAnchor: CommandPaletteSummonAnchor? = nil
    ) {
        self.wmController = wmController
        windows = items
        menuItems = []
        selectedMode = .windows
        self.selectedItemID = selectedItemID
        self.summonAnchor = summonAnchor
    }

    func setMenuAvailabilityForTests(_ target: CommandPaletteAppSnapshot?) {
        menuFocusTarget = target.map { CommandPaletteFocusTarget(app: $0, focusedWindow: nil) }
    }

    func setMenuLoadingStateForTests(
        wmController: WMController,
        target: CommandPaletteAppSnapshot
    ) {
        self.wmController = wmController
        isVisible = true
        menuFocusTarget = CommandPaletteFocusTarget(app: target, focusedWindow: nil)
        menuItems = []
        hasLoadedMenuItems = false
        menuLoadGeneration &+= 1
        selectedMode = .menu
    }

    func loadMenuItemsForTests() {
        loadMenuItemsIfNeeded()
    }

    @discardableResult
    func handleModeShortcutForTests(_ characters: String) -> Bool {
        handleModeShortcut(characters)
    }

    func selectionTriggerForTests(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> CommandPaletteSelectionTrigger? {
        Self.selectionTrigger(forKeyCode: keyCode, modifierFlags: modifierFlags)
    }

    var panelForTests: NSPanel? {
        panel
    }
}

private struct CommandPaletteView: View {
    @ObservedObject var controller: CommandPaletteController

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                CommandPaletteModePicker(
                    selectedMode: controller.selectedMode,
                    isMenuModeAvailable: controller.isMenuModeAvailable,
                    onSelect: { controller.selectedMode = $0 }
                )

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(searchPlaceholder, text: $controller.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                    if !controller.searchText.isEmpty {
                        Button(action: { controller.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if controller.selectedMode == .menu && controller.isMenuLoading {
                CommandPaletteLoadingView(text: "Loading menu items...")
            } else if isEmptyStateVisible {
                CommandPaletteEmptyStateView(
                    symbolName: emptyStateSymbol,
                    text: emptyStateText
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            switch controller.selectedMode {
                            case .windows:
                                ForEach(controller.filteredWindowItems) { item in
                                    CommandPaletteWindowRow(
                                        item: item,
                                        isSelected: controller.selectedItemID == .window(item.id),
                                        isSummonRightAvailable: controller.isSummonRightAvailable
                                    )
                                    .id(CommandPaletteSelectionID.window(item.id))
                                    .onTapGesture {
                                        controller.selectedItemID = .window(item.id)
                                        controller.selectCurrent()
                                    }
                                }
                            case .menu:
                                ForEach(controller.filteredMenuItems) { item in
                                    CommandPaletteMenuRow(
                                        item: item,
                                        isSelected: controller.selectedItemID == .menu(item.id)
                                    )
                                    .id(CommandPaletteSelectionID.menu(item.id))
                                    .onTapGesture {
                                        controller.selectedItemID = .menu(item.id)
                                        controller.selectCurrent()
                                    }
                                }
                            case .commands:
                                ForEach(controller.filteredCommandItems) { item in
                                    CommandPaletteCommandRow(
                                        item: item,
                                        isSelected: controller.selectedItemID == .command(item.id)
                                    )
                                    .id(CommandPaletteSelectionID.command(item.id))
                                    .onTapGesture {
                                        controller.selectedItemID = .command(item.id)
                                        controller.selectCurrent()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: controller.selectedItemID) { _, newValue in
                        if let newValue {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 620, height: 430)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var searchPlaceholder: String {
        switch controller.selectedMode {
        case .windows:
            "Search windows..."
        case .menu:
            "Search menu items..."
        case .commands:
            "Search commands..."
        }
    }

    private var statusText: String {
        switch controller.selectedMode {
        case .windows:
            CommandPaletteController.windowsStatusText(
                isSummonRightAvailable: controller.isSummonRightAvailable
            )
        case .menu:
            controller.menuStatusText
        case .commands:
            "Enter executes the selected command."
        }
    }

    private var isEmptyStateVisible: Bool {
        switch controller.selectedMode {
        case .windows:
            controller.filteredWindowItems.isEmpty
        case .menu:
            !controller.isMenuLoading &&
                (!controller.isMenuModeAvailable || controller.filteredMenuItems.isEmpty)
        case .commands:
            controller.filteredCommandItems.isEmpty
        }
    }

    private var emptyStateSymbol: String {
        switch controller.selectedMode {
        case .windows:
            "macwindow.on.rectangle"
        case .menu:
            controller.isMenuModeAvailable ? "text.magnifyingglass" : "menubar.rectangle"
        case .commands:
            "text.magnifyingglass"
        }
    }

    private var emptyStateText: String {
        switch controller.selectedMode {
        case .windows:
            return controller.searchText.isEmpty ? "No windows available" : "No windows found"
        case .menu:
            if !controller.isMenuModeAvailable {
                return controller.menuStatusText
            }
            return controller.searchText.isEmpty ? "No menu items available" : "No menu items found"
        case .commands:
            return controller.searchText.isEmpty ? "No commands available" : "No commands found"
        }
    }
}

private struct CommandPaletteModePicker: View {
    @Environment(\.colorScheme) private var colorScheme

    let selectedMode: CommandPaletteMode
    let isMenuModeAvailable: Bool
    let onSelect: (CommandPaletteMode) -> Void

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
    }

    private var selectedFillColor: Color {
        colorScheme == .dark ? Color.accentColor.opacity(0.55) : Color.accentColor.opacity(0.18)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CommandPaletteMode.allCases, id: \.self) { mode in
                modeButton(mode, enabled: mode != .menu || isMenuModeAvailable)
            }
        }
        .padding(4)
        .background(trackColor)
        .clipShape(Capsule())
    }

    private func modeButton(_ mode: CommandPaletteMode, enabled: Bool) -> some View {
        let hint = CommandPaletteController.modeHint(for: mode)
        let isSelected = selectedMode == mode
        return Button(action: { onSelect(mode) }) {
            HStack(spacing: 10) {
                Text(hint.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tabTitleColor(isSelected: isSelected, enabled: enabled))
                Text(hint.shortcut)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tabShortcutColor(isSelected: isSelected, enabled: enabled))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? selectedFillColor : Color.clear)
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected ? selectedFillColor.opacity(0.95) : Color.clear,
                        lineWidth: 1
                    )
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func tabTitleColor(isSelected: Bool, enabled: Bool) -> Color {
        if !enabled {
            return Color.secondary.opacity(0.55)
        }
        return isSelected ? .primary : .primary.opacity(0.82)
    }

    private func tabShortcutColor(isSelected: Bool, enabled: Bool) -> Color {
        if !enabled {
            return Color.secondary.opacity(0.45)
        }
        return isSelected ? .secondary : .secondary.opacity(0.82)
    }
}

private struct CommandPaletteShortcutBadge: View {
    let text: String
    var prominent = false
    var enabled = true

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(enabled ? 1 : 0.6)
    }

    private var foregroundColor: Color {
        enabled ? (prominent ? .primary : .secondary) : .secondary
    }

    private var backgroundColor: Color {
        prominent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.14)
    }

    private var borderColor: Color {
        prominent ? Color.accentColor.opacity(0.22) : Color.clear
    }
}

private struct CommandPaletteLoadingView: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.85)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CommandPaletteEmptyStateView: View {
    let symbolName: String
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Image(systemName: symbolName)
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


private struct CommandPaletteWindowRow: View {
    let item: CommandPaletteWindowItem
    let isSelected: Bool
    let isSummonRightAvailable: Bool

    private var summonHint: CommandPaletteController.InlineHint? {
        guard isSelected else { return nil }
        return CommandPaletteController.selectedWindowHint(isSummonRightAvailable: isSummonRightAvailable)
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon = item.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? item.appName : item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(item.appName)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 8) {
                if let summonHint {
                    Text(summonHint.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    CommandPaletteShortcutBadge(text: summonHint.shortcut)
                }

                Text(item.workspaceName)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
}

private struct CommandPaletteMenuRow: View {
    let item: MenuItemModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if !item.parentTitles.isEmpty {
                    Text(item.parentTitles.joined(separator: " > "))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let shortcut = item.keyboardShortcut {
                CommandPaletteShortcutBadge(text: shortcut)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
}

private struct CommandPaletteCommandRow: View {
    let item: CommandPaletteCommandItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(item.category.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let binding = item.bindingDisplay {
                CommandPaletteShortcutBadge(text: binding)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
}

