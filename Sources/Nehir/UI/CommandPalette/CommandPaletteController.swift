// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

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

struct CommandPaletteFallbackSection: Identifiable {
    let source: CommandPaletteMode
    let windowItems: [CommandPaletteWindowItem]
    let menuItems: [MenuItemModel]
    let commandItems: [CommandPaletteCommandItem]
    var id: CommandPaletteMode {
        source
    }

    var isEmpty: Bool {
        windowItems.isEmpty && menuItems.isEmpty && commandItems.isEmpty
    }
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
    override var canBecomeKey: Bool {
        true
    }
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

    /// Non-nil while a command-row hotkey capture is in progress. The id is the
    /// selected `CommandPaletteCommandItem.id`. The palette's key monitor passes
    /// every key through to the embedded `KeyRecorderView` while this is set.
    @Published private(set) var recordingCommandId: String?

    /// Drives the conflict confirmation sheet over the panel when a recorded
    /// chord collides with another action. Writable so the SwiftUI `.alert`
    /// binding can clear it.
    @Published var pendingConflictAlert: ConflictAlert?

    /// Drives a transient notice (e.g. reserved-palette-chord rejection) over
    /// the panel. Writable so the SwiftUI `.alert` binding can clear it.
    @Published var pendingNoticeAlert: HotkeyNoticeAlert?

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

    var activeModeFilteredIsEmpty: Bool {
        switch selectedMode {
        case .windows:
            return filteredWindowItems.isEmpty
        case .menu:
            return !isMenuLoading && (!isMenuModeAvailable || filteredMenuItems.isEmpty)
        case .commands:
            return filteredCommandItems.isEmpty
        }
    }

    var fallbackSections: [CommandPaletteFallbackSection] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, activeModeFilteredIsEmpty else {
            return []
        }

        var sections: [CommandPaletteFallbackSection] = []

        let matchedWindows = filterWindowItems(windows, query: searchText)
        if !matchedWindows.isEmpty {
            sections.append(
                CommandPaletteFallbackSection(
                    source: .windows,
                    windowItems: matchedWindows,
                    menuItems: [],
                    commandItems: []
                )
            )
        }

        let matchedCommands = filterCommandItems(commandItems, query: searchText)
        if !matchedCommands.isEmpty {
            sections.append(
                CommandPaletteFallbackSection(
                    source: .commands,
                    windowItems: [],
                    menuItems: [],
                    commandItems: matchedCommands
                )
            )
        }

        if isMenuModeAvailable, hasLoadedMenuItems {
            let matchedMenu = filterMenuItems(menuItems, query: searchText)
            if !matchedMenu.isEmpty {
                sections.append(
                    CommandPaletteFallbackSection(
                        source: .menu,
                        windowItems: [],
                        menuItems: matchedMenu,
                        commandItems: []
                    )
                )
            }
        }

        return sections
    }

    var fallbackActive: Bool {
        !fallbackSections.isEmpty
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

    /// Hint rendered on the selected Commands row. The caller gates numbered-group
    /// rows (read-only) so this only needs to know whether the row is assigned.
    static func selectedCommandHint(isAssigned: Bool) -> InlineHint {
        InlineHint(
            title: isAssigned ? "Clear Shortcut" : "Assign Shortcut",
            shortcut: "⇥"
        )
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
        // While recording a command hotkey, pass every key through to the
        // embedded `KeyRecorderView` (first responder) so the palette's own
        // navigation chords do not swallow the capture.
        if recordingCommandId != nil { return false }

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
            // Bare Tab on a selected Commands row assigns or clears its hotkey
            // without leaving the palette. Numbered-group rows are read-only.
            if selectedMode == .commands,
               event.keyCode == 48,
               relevantModifiers.isEmpty,
               handleCommandAssignChord()
            {
                return true
            }
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

    // MARK: - In-palette hotkey assignment

    /// Handles a bare `Tab` on the selected Commands row. Returns true when the
    /// chord is claimed (so the event monitor consumes it). Numbered-group rows
    /// are read-only: Tab is claimed but does nothing. Singleton rows either
    /// enter recording (unassigned) or clear their binding (assigned).
    private func handleCommandAssignChord() -> Bool {
        guard case let .command(id)? = selectedItemID else { return false }
        if HotkeyConfigMapping.isNumberedGroupMember(id) {
            return true
        }
        let isAssigned = commandItems.first { $0.id == id }?.bindingDisplay != nil
        if isAssigned {
            clearSelectedCommandBinding()
        } else {
            recordingCommandId = id
        }
        return true
    }

    /// Applies a captured chord to the action being recorded. Reuses the same
    /// chokepoint as the Hotkeys tab (`HotkeyBindingEditor.capture`). On a free
    /// chord the binding is committed, the row badges refresh, and the palette
    /// stays open so several actions can be bound in one visit. On a conflict,
    /// the alert is surfaced and the binding is left untouched.
    func commitRecording(_ binding: KeyBinding) {
        guard let id = recordingCommandId, let wmController else { return }

        guard !Self.isReservedPaletteChord(binding) else {
            pendingNoticeAlert = HotkeyNoticeAlert(
                title: "Shortcut Reserved",
                message: "That key combination is used by the command palette itself. Pick a different one."
            )
            // The recorder is one-shot (it stops after any capture), so end the
            // recording session and let the user press Tab again to retry.
            cancelRecording()
            return
        }

        switch HotkeyBindingEditor.capture(binding, for: id, settings: wmController.settings) {
        case .applied:
            wmController.updateHotkeyBindings(wmController.settings.hotkeyBindings)
            commandItems = buildCommandItems(from: wmController)
            finishRecording()
        case let .conflict(alert):
            pendingConflictAlert = alert
        }
    }

    /// Clears the selected command's binding. No conflict is possible on clear,
    /// so no alert is surfaced.
    private func clearSelectedCommandBinding() {
        guard case let .command(id)? = selectedItemID,
              let wmController
        else { return }
        wmController.settings.clearBinding(for: id)
        wmController.updateHotkeyBindings(wmController.settings.hotkeyBindings)
        commandItems = buildCommandItems(from: wmController)
        focusSearchField()
    }

    /// Resolves a surfaced conflict alert. `replace` claims the chord for the
    /// recorded action (displacing the previous owner); a cancel returns focus
    /// to the search field with the same command still selected.
    func resolvePendingConflict(replace: Bool) {
        let alert = pendingConflictAlert
        pendingConflictAlert = nil
        guard replace, let alert, let wmController else {
            focusSearchField()
            return
        }
        HotkeyBindingEditor.applyConflictResolution(alert, settings: wmController.settings)
        wmController.updateHotkeyBindings(wmController.settings.hotkeyBindings)
        commandItems = buildCommandItems(from: wmController)
        finishRecording()
    }

    private func finishRecording() {
        recordingCommandId = nil
        focusSearchField()
    }

    /// Cancelled by the recorder (Esc) or by clearing the conflict notice.
    func cancelRecording() {
        recordingCommandId = nil
        focusSearchField()
    }

    /// Rejects chords the palette itself uses for navigation, so a recorded
    /// binding cannot shadow in-palette control (Risk 4). `KeyRecorderView`
    /// already drops bare non-special keys, but `⌘1`/`⌘2`/`⌘3` would otherwise
    /// pass and double as mode switches.
    private static func isReservedPaletteChord(_ binding: KeyBinding) -> Bool {
        if binding.modifiers == UInt32(cmdKey),
           HotkeyConfigMapping.digitKeyCodes.prefix(3).contains(binding.keyCode)
        {
            return true
        }
        switch binding.keyCode {
        case UInt32(kVK_Escape),
             UInt32(kVK_UpArrow), UInt32(kVK_DownArrow),
             UInt32(kVK_Return), UInt32(kVK_ANSI_KeypadEnter),
             UInt32(kVK_Tab):
            return true
        default:
            return false
        }
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
        recordingCommandId = nil
        pendingConflictAlert = nil
        pendingNoticeAlert = nil

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
        guard let selectedItemID else { return nil }
        switch selectedItemID {
        case .window(let token):
            let resolvedItems = fallbackActive
                ? (section(in: .windows)?.windowItems ?? [])
                : filteredWindowItems
            guard let wmController,
                  let item = resolvedItems.first(where: { $0.id == token })
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
        case .menu(let id):
            let resolvedItems = fallbackActive
                ? (section(in: .menu)?.menuItems ?? [])
                : filteredMenuItems
            guard let item = resolvedItems.first(where: { $0.id == id }),
                  let menuFocusTarget
            else {
                return nil
            }
            return .pressMenu(menuFocusTarget, item.axElement)
        case .command(let id):
            let resolvedItems = fallbackActive
                ? (section(in: .commands)?.commandItems ?? [])
                : filteredCommandItems
            guard let wmController,
                  let item = resolvedItems.first(where: { $0.id == id })
            else {
                return nil
            }
            return .executeCommand(wmController, item.command)
        }
    }

    private func section(in source: CommandPaletteMode) -> CommandPaletteFallbackSection? {
        fallbackSections.first { $0.source == source }
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
            switch command {
            case .debugResetRuntimeState:
                guard DestructiveConfirmationAlert.confirm(
                    title: "Reset Runtime State",
                    message: "This will clear all runtime state and rebootstrap from a rescan. Continue?",
                    confirmTitle: "Reset"
                ) else { return }
            case .debugRestartClearingRuntimeState:
                let result = DestructiveConfirmationAlert.confirmRestart(
                    title: "Restart Clearing Runtime State",
                    message: "This will clear runtime state and relaunch the app. Continue?",
                    confirmTitle: "Restart"
                )
                guard result.confirmed else { return }
                wmController.commandHandler.performRestartClearingRuntimeState(enableTracing: result.enableTracing)
                return
            default:
                break
            }
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
        if fallbackActive {
            return fallbackSections.flatMap { fallbackSection -> [CommandPaletteSelectionID] in
                switch fallbackSection.source {
                case .windows:
                    return fallbackSection.windowItems.map { .window($0.id) }
                case .menu:
                    return fallbackSection.menuItems.map { .menu($0.id) }
                case .commands:
                    return fallbackSection.commandItems.map { .command($0.id) }
                }
            }
        }
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

    /// Drives the palette key-down path with a synthetic event, mirroring what
    /// the local `.keyDown` monitor would deliver.
    @discardableResult
    func handleKeyDownForTests(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return false
        }
        return handleKeyDown(event)
    }

    /// Sets up a Commands-mode selection without driving the full panel show
    /// path, so Tab/assign behavior can be exercised deterministically.
    func setCommandSelectionStateForTests(
        wmController: WMController,
        selectedItemID: CommandPaletteSelectionID?,
        isVisible: Bool = true
    ) {
        self.wmController = wmController
        commandItems = buildCommandItems(from: wmController)
        selectedMode = .commands
        self.selectedItemID = selectedItemID
        self.isVisible = isVisible
    }

    /// Enters recording for the currently selected command, then captures
    /// `binding`. Thin wrapper over `commitRecording` so tests do not need to
    /// drive the Tab key-down path to exercise the capture pipeline.
    func commitRecordingForTests(_ binding: KeyBinding) {
        guard case let .command(id)? = selectedItemID else { return }
        recordingCommandId = id
        commitRecording(binding)
    }

    var panelForTests: NSPanel? {
        panel
    }

    func setCommandItemsForTests(
        _ items: [CommandPaletteCommandItem],
        wmController: WMController
    ) {
        self.wmController = wmController
        commandItems = items
    }

    struct CommandPaletteFallbackTestState {
        let wmController: WMController
        let windows: [CommandPaletteWindowItem]
        let menuItems: [MenuItemModel]
        let commands: [CommandPaletteCommandItem]
        let selectedMode: CommandPaletteMode
        let selectedItemID: CommandPaletteSelectionID?
        let hasLoadedMenuItems: Bool
    }

    func setFallbackStateForTests(_ state: CommandPaletteFallbackTestState) {
        wmController = state.wmController
        windows = state.windows
        menuItems = state.menuItems
        commandItems = state.commands
        selectedMode = state.selectedMode
        selectedItemID = state.selectedItemID
        hasLoadedMenuItems = state.hasLoadedMenuItems
    }

    func currentSelectionListForTests() -> [CommandPaletteSelectionID] {
        currentSelectionList()
    }

    enum CommandPaletteResolvedActionKindForTests: Equatable {
        case navigateWindow
        case summonWindowRight
        case pressMenu
        case executeCommand
    }

    func resolvedSelectionActionKindForTests(
        trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteResolvedActionKindForTests? {
        guard let action = resolvedSelectionAction(for: trigger) else { return nil }
        switch action {
        case .navigateWindow: return .navigateWindow
        case .summonWindowRight: return .summonWindowRight
        case .pressMenu: return .pressMenu
        case .executeCommand: return .executeCommand
        }
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
                    if controller.recordingCommandId != nil {
                        KeyRecorderView(
                            accessibilityLabel: "Recording hotkey for selected command",
                            onCapture: { controller.commitRecording($0) },
                            onCancel: { controller.cancelRecording() }
                        )
                        .frame(minWidth: 180, idealWidth: 210, minHeight: 34)
                    } else {
                        Text(statusText)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if controller.selectedMode == .menu && controller.isMenuLoading {
                CommandPaletteLoadingView(text: "Loading menu items...")
            } else if isEmptyStateVisible && controller.fallbackActive {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(controller.fallbackSections) { section in
                                fallbackSection(section)
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
        .alert(item: $controller.pendingConflictAlert) { alert in
            Alert(
                title: Text("Hotkey Conflict"),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Replace")) {
                    controller.resolvePendingConflict(replace: true)
                },
                secondaryButton: .cancel {
                    controller.resolvePendingConflict(replace: false)
                }
            )
        }
        .alert(item: $controller.pendingNoticeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    controller.cancelRecording()
                }
            )
        }
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
        if controller.recordingCommandId != nil {
            return "Press a key combination… Esc to cancel."
        }
        if controller.fallbackActive {
            return "No \(controller.selectedMode.displayName.lowercased()) matches — showing other sources."
        }
        switch controller.selectedMode {
        case .windows:
            return CommandPaletteController.windowsStatusText(
                isSummonRightAvailable: controller.isSummonRightAvailable
            )
        case .menu:
            return controller.menuStatusText
        case .commands:
            return "Enter executes the selected command."
        }
    }

    private var isEmptyStateVisible: Bool {
        controller.activeModeFilteredIsEmpty
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

    @ViewBuilder
    private func fallbackSection(_ section: CommandPaletteFallbackSection) -> some View {
        CommandPaletteFallbackSectionHeader(title: section.source.displayName)
        switch section.source {
        case .windows:
            ForEach(section.windowItems) { item in
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
            ForEach(section.menuItems) { item in
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
            ForEach(section.commandItems) { item in
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

private struct CommandPaletteFallbackSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
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

    /// Inline assign/clear hint, shown only on the selected singleton row.
    /// Numbered-group rows (switchWorkspace.N, focusColumn.N, ...) are edited as
    /// a 1–9 pattern in the Hotkeys tab and are read-only here.
    private var assignHint: CommandPaletteController.InlineHint? {
        guard isSelected,
              !HotkeyConfigMapping.isNumberedGroupMember(item.id)
        else { return nil }
        return CommandPaletteController.selectedCommandHint(isAssigned: item.bindingDisplay != nil)
    }

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

            HStack(spacing: 8) {
                if let assignHint {
                    Text(assignHint.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    CommandPaletteShortcutBadge(text: assignHint.shortcut)
                }

                if let binding = item.bindingDisplay {
                    CommandPaletteShortcutBadge(text: binding)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
}
