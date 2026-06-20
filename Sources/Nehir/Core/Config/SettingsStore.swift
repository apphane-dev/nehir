// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon
import Foundation
import NehirIPC

@MainActor @Observable
final class SettingsStore {
    private nonisolated static let defaultExport = SettingsExport.defaults()

    private let persistence: SettingsFilePersistence
    private let runtimeState: RuntimeStateStore
    private let autosaveEnabled: Bool
    private var isApplyingExport = false
    private var settingsTOMLUnknownFields: SettingsTOMLUnknownFields = [:]

    var onIPCEnabledChanged: (@MainActor (Bool) -> Void)?
    var onExternalSettingsReloaded: (@MainActor () -> Void)?

    var hotkeysEnabled = SettingsStore.defaultExport.hotkeysEnabled {
        didSet { scheduleSave() }
    }

    var focusFollowsMouse = SettingsStore.defaultExport.focusFollowsMouse {
        didSet { scheduleSave() }
    }

    var moveMouseToFocusedWindow = SettingsStore.defaultExport.moveMouseToFocusedWindow {
        didSet { scheduleSave() }
    }

    var focusFollowsWindowToMonitor = SettingsStore.defaultExport.focusFollowsWindowToMonitor {
        didSet { scheduleSave() }
    }

    var mouseWarpEnabled = SettingsStore.defaultExport.mouseWarpEnabled {
        didSet { scheduleSave() }
    }

    var mouseWarpMonitorOrder = SettingsStore.defaultExport.mouseWarpMonitorOrder {
        didSet { scheduleSave() }
    }

    var mouseWarpAxis = MouseWarpAxis(rawValue: SettingsStore.defaultExport.mouseWarpAxis ?? "") ?? .horizontal {
        didSet { scheduleSave() }
    }

    var niriColumnWidthPresets = SettingsStore.validatedPresets(
        SettingsStore.defaultExport.niriColumnWidthPresets ?? BuiltInSettingsDefaults.niriColumnWidthPresets
    ) {
        didSet { scheduleSave() }
    }

    var niriDefaultColumnWidth = SettingsStore.validatedDefaultColumnWidth(
        SettingsStore.defaultExport.niriDefaultColumnWidth
    ) {
        didSet {
            let validated = SettingsStore.validatedDefaultColumnWidth(niriDefaultColumnWidth)
            if validated != niriDefaultColumnWidth {
                niriDefaultColumnWidth = validated
                return
            }
            scheduleSave()
        }
    }

    var mouseWarpMargin = SettingsStore.defaultExport.mouseWarpMargin {
        didSet { scheduleSave() }
    }

    var gapSize = SettingsStore.defaultExport.gapSize {
        didSet { scheduleSave() }
    }

    var outerGapLeft = SettingsStore.defaultExport.outerGapLeft {
        didSet { scheduleSave() }
    }

    var outerGapRight = SettingsStore.defaultExport.outerGapRight {
        didSet { scheduleSave() }
    }

    var outerGapTop = SettingsStore.defaultExport.outerGapTop {
        didSet { scheduleSave() }
    }

    var outerGapBottom = SettingsStore.defaultExport.outerGapBottom {
        didSet { scheduleSave() }
    }

    var niriBalancedColumnCount = SettingsStore.defaultExport.niriBalancedColumnCount {
        didSet { scheduleSave() }
    }

    var niriInfiniteLoop = SettingsStore.defaultExport.niriInfiniteLoop {
        didSet { scheduleSave() }
    }

    var revealPartial = RevealPartial(
        rawValue: SettingsStore.defaultExport.revealPartial
    ) ?? .default {
        didSet { scheduleSave() }
    }

    var niriLoneWindowMaxWidth = SettingsStore.validatedLoneWindowMaxWidth(
        SettingsStore.defaultExport.niriLoneWindowMaxWidth
    ) {
        didSet {
            let validated = SettingsStore.validatedLoneWindowMaxWidth(niriLoneWindowMaxWidth)
            if validated != niriLoneWindowMaxWidth {
                niriLoneWindowMaxWidth = validated
                return
            }
            scheduleSave()
        }
    }

    var loneWindowPolicy: LoneWindowPolicy {
        guard let maxWidth = niriLoneWindowMaxWidth else { return .fill }
        return .centered(maxWidthFraction: maxWidth)
    }

    var defaultColumnWidth: DefaultColumnWidth {
        if let width = niriDefaultColumnWidth {
            return .custom(fraction: width)
        }
        return .balanced(columns: niriBalancedColumnCount)
    }

    var workspaceConfigurations = SettingsStore.defaultExport.workspaceConfigurations {
        didSet { scheduleSave() }
    }

    var bordersEnabled = SettingsStore.defaultExport.bordersEnabled {
        didSet { scheduleSave() }
    }

    var borderWidth = SettingsStore.defaultExport.borderWidth {
        didSet { scheduleSave() }
    }

    var borderColorRed = SettingsStore.defaultExport.borderColorRed {
        didSet { scheduleSave() }
    }

    var borderColorGreen = SettingsStore.defaultExport.borderColorGreen {
        didSet { scheduleSave() }
    }

    var borderColorBlue = SettingsStore.defaultExport.borderColorBlue {
        didSet { scheduleSave() }
    }

    var borderColorAlpha = SettingsStore.defaultExport.borderColorAlpha {
        didSet { scheduleSave() }
    }

    var hotkeyBindings = SettingsStore.defaultExport.hotkeyBindings {
        didSet { scheduleSave() }
    }

    var workspaceBarEnabled = SettingsStore.defaultExport.workspaceBarEnabled {
        didSet { scheduleSave() }
    }

    var workspaceBarShowLabels = SettingsStore.defaultExport.workspaceBarShowLabels {
        didSet { scheduleSave() }
    }

    var workspaceBarShowFloatingWindows = SettingsStore.defaultExport.workspaceBarShowFloatingWindows {
        didSet { scheduleSave() }
    }

    var workspaceBarShowTraceButton = SettingsStore.defaultExport.workspaceBarShowTraceButton {
        didSet { scheduleSave() }
    }

    var workspaceBarWindowLevel = WorkspaceBarWindowLevel(
        rawValue: SettingsStore.defaultExport.workspaceBarWindowLevel
    ) ?? .popup {
        didSet { scheduleSave() }
    }

    var workspaceBarPosition = WorkspaceBarPosition(
        rawValue: SettingsStore.defaultExport.workspaceBarPosition
    ) ?? .overlappingMenuBar {
        didSet { scheduleSave() }
    }

    var workspaceBarNotchAware = SettingsStore.defaultExport.workspaceBarNotchAware {
        didSet { scheduleSave() }
    }

    var workspaceBarDeduplicateAppIcons = SettingsStore.defaultExport.workspaceBarDeduplicateAppIcons {
        didSet { scheduleSave() }
    }

    var workspaceBarHideEmptyWorkspaces = SettingsStore.defaultExport.workspaceBarHideEmptyWorkspaces {
        didSet { scheduleSave() }
    }

    var workspaceBarReserveLayoutSpace = SettingsStore.defaultExport.workspaceBarReserveLayoutSpace {
        didSet { scheduleSave() }
    }

    var workspaceBarHeight = SettingsStore.defaultExport.workspaceBarHeight {
        didSet { scheduleSave() }
    }

    var workspaceBarBackgroundOpacity = SettingsStore.defaultExport.workspaceBarBackgroundOpacity {
        didSet { scheduleSave() }
    }

    var workspaceBarXOffset = SettingsStore.defaultExport.workspaceBarXOffset {
        didSet { scheduleSave() }
    }

    var workspaceBarYOffset = SettingsStore.defaultExport.workspaceBarYOffset {
        didSet { scheduleSave() }
    }

    var workspaceBarAccentColor = SettingsStore.defaultExport.workspaceBarAccentColor {
        didSet { scheduleSave() }
    }

    var workspaceBarTextColor = SettingsStore.defaultExport.workspaceBarTextColor {
        didSet { scheduleSave() }
    }

    var monitorBarSettings = SettingsStore.defaultExport.monitorBarSettings {
        didSet { scheduleSave() }
    }

    var appRules = SettingsStore.defaultExport.appRules {
        didSet { scheduleSave() }
    }

    var monitorGapSettings = SettingsStore.defaultExport.monitorGapSettings {
        didSet { scheduleSave() }
    }

    var monitorOrientationSettings = SettingsStore.defaultExport.monitorOrientationSettings {
        didSet { scheduleSave() }
    }

    var monitorNiriSettings = SettingsStore.defaultExport.monitorNiriSettings {
        didSet { scheduleSave() }
    }

    var preventSleepEnabled = SettingsStore.defaultExport.preventSleepEnabled {
        didSet { scheduleSave() }
    }

    var ipcEnabled = SettingsStore.defaultExport.ipcEnabled {
        didSet {
            guard oldValue != ipcEnabled else { return }
            onIPCEnabledChanged?(ipcEnabled)
            scheduleSave()
        }
    }

    var developerModeEnabled = SettingsStore.defaultExport.developerModeEnabled {
        didSet { scheduleSave() }
    }

    var ignoreMonitorIdentity = SettingsStore.defaultExport.ignoreMonitorIdentity {
        didSet { scheduleSave() }
    }

    var scrollGestureEnabled = SettingsStore.defaultExport.scrollGestureEnabled {
        didSet { scheduleSave() }
    }

    var scrollSensitivity = SettingsStore.defaultExport.scrollSensitivity {
        didSet { scheduleSave() }
    }

    var scrollModifierKey = ScrollModifierKey(
        rawValue: SettingsStore.defaultExport.scrollModifierKey
    ) ?? .optionShift {
        didSet { scheduleSave() }
    }

    var mouseResizeModifierKey = MouseResizeModifierKey(
        rawValue: SettingsStore.defaultExport.mouseResizeModifierKey
    ) ?? .option {
        didSet { scheduleSave() }
    }

    var gestureFingerCount = GestureFingerCount(
        rawValue: SettingsStore.defaultExport.gestureFingerCount
    ) ?? .three {
        didSet { scheduleSave() }
    }

    var gestureInvertDirection = SettingsStore.defaultExport.gestureInvertDirection {
        didSet { scheduleSave() }
    }

    var statusBarShowWorkspaceName = SettingsStore.defaultExport.statusBarShowWorkspaceName {
        didSet { scheduleSave() }
    }

    var statusBarShowAppNames = SettingsStore.defaultExport.statusBarShowAppNames {
        didSet { scheduleSave() }
    }

    var statusBarUseWorkspaceId = SettingsStore.defaultExport.statusBarUseWorkspaceId {
        didSet { scheduleSave() }
    }

    var commandPaletteLastMode = RuntimeStateStore.defaultCommandPaletteLastMode {
        didSet { runtimeState.commandPaletteLastMode = commandPaletteLastMode }
    }

    var appearanceMode = AppearanceMode(
        rawValue: SettingsStore.defaultExport.appearanceMode
    ) ?? .dark {
        didSet { scheduleSave() }
    }

    func loadPersistedWindowRestoreCatalog() -> PersistedWindowRestoreCatalog {
        runtimeState.windowRestoreCatalog ?? .empty
    }

    func savePersistedWindowRestoreCatalog(_ catalog: PersistedWindowRestoreCatalog) {
        runtimeState.windowRestoreCatalog = catalog.entries.isEmpty ? nil : catalog
    }

    init(
        persistence: SettingsFilePersistence = SettingsFilePersistence(),
        runtimeState: RuntimeStateStore = RuntimeStateStore(),
        autosaveEnabled: Bool = true
    ) {
        self.persistence = persistence
        self.runtimeState = runtimeState
        self.autosaveEnabled = autosaveEnabled
        commandPaletteLastMode = runtimeState.commandPaletteLastMode

        applyExport(
            persistence.load(),
            monitors: Monitor.current()
        )
        persistence.setExternalChangeHandler { [weak self] export in
            self?.handleExternalReload(export)
        }
    }

    var configDirectoryURL: URL {
        persistence.directoryURL
    }

    var settingsFileURL: URL {
        persistence.fileURL
    }

    func ensureConfigFilesAvailable() throws {
        let export = toExport()
        let fm = FileManager.default
        try fm.createDirectory(at: persistence.directoryURL, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: persistence.fileURL.path) {
            try SettingsTOMLCodec.encode(export).write(to: persistence.fileURL, options: .atomic)
        }
        if !fm.fileExists(atPath: persistence.hotkeysFileURL.path) {
            try HotkeysTOMLCodec.encode(export.hotkeyBindings)
                .write(to: persistence.hotkeysFileURL, options: .atomic)
        }
        if !fm.fileExists(atPath: persistence.workspacesFileURL.path) {
            try WorkspacesTOMLCodec.encode(export.workspaceConfigurations)
                .write(to: persistence.workspacesFileURL, options: .atomic)
        }
        if !fm.fileExists(atPath: persistence.appRulesDirectoryURL.path) {
            try AppRuleFileStore.write(export.appRules, to: persistence.appRulesDirectoryURL)
        }
        if !fm.fileExists(atPath: persistence.monitorsDirectoryURL.path) {
            try MonitorOverrideFileStore.write(
                bar: export.monitorBarSettings,
                gaps: export.monitorGapSettings,
                orientation: export.monitorOrientationSettings,
                niri: export.monitorNiriSettings,
                to: persistence.monitorsDirectoryURL
            )
        }
    }

    func flushNow() {
        if autosaveEnabled {
            persistence.flushNow()
        } else {
            persistence.save(toExport())
        }
        runtimeState.flushNow()
    }

    func toExport() -> SettingsExport {
        SettingsExport(
            hotkeysEnabled: hotkeysEnabled,
            focusFollowsMouse: focusFollowsMouse,
            moveMouseToFocusedWindow: moveMouseToFocusedWindow,
            focusFollowsWindowToMonitor: focusFollowsWindowToMonitor,
            mouseWarpEnabled: mouseWarpEnabled,
            mouseWarpMonitorOrder: mouseWarpMonitorOrder,
            mouseWarpAxis: mouseWarpAxis.rawValue,
            mouseWarpMargin: mouseWarpMargin,
            gapSize: gapSize,
            outerGapLeft: outerGapLeft,
            outerGapRight: outerGapRight,
            outerGapTop: outerGapTop,
            outerGapBottom: outerGapBottom,
            niriBalancedColumnCount: niriBalancedColumnCount,
            niriInfiniteLoop: niriInfiniteLoop,
            revealPartial: revealPartial.rawValue,
            niriLoneWindowMaxWidth: niriLoneWindowMaxWidth,
            niriColumnWidthPresets: niriColumnWidthPresets,
            niriDefaultColumnWidth: niriDefaultColumnWidth,
            workspaceConfigurations: workspaceConfigurations,
            bordersEnabled: bordersEnabled,
            borderWidth: borderWidth,
            borderColorRed: borderColorRed,
            borderColorGreen: borderColorGreen,
            borderColorBlue: borderColorBlue,
            borderColorAlpha: borderColorAlpha,
            hotkeyBindings: hotkeyBindings,
            workspaceBarEnabled: workspaceBarEnabled,
            workspaceBarShowLabels: workspaceBarShowLabels,
            workspaceBarShowFloatingWindows: workspaceBarShowFloatingWindows,
            workspaceBarShowTraceButton: workspaceBarShowTraceButton,
            workspaceBarWindowLevel: workspaceBarWindowLevel.rawValue,
            workspaceBarPosition: workspaceBarPosition.rawValue,
            workspaceBarNotchAware: workspaceBarNotchAware,
            workspaceBarDeduplicateAppIcons: workspaceBarDeduplicateAppIcons,
            workspaceBarHideEmptyWorkspaces: workspaceBarHideEmptyWorkspaces,
            workspaceBarReserveLayoutSpace: workspaceBarReserveLayoutSpace,
            workspaceBarHeight: workspaceBarHeight,
            workspaceBarBackgroundOpacity: workspaceBarBackgroundOpacity,
            workspaceBarXOffset: workspaceBarXOffset,
            workspaceBarYOffset: workspaceBarYOffset,
            workspaceBarAccentColor: workspaceBarAccentColor,
            workspaceBarTextColor: workspaceBarTextColor,
            workspaceBarLabelFontSize: 12,
            monitorBarSettings: monitorBarSettings,
            appRules: appRules,
            monitorGapSettings: monitorGapSettings,
            monitorOrientationSettings: monitorOrientationSettings,
            monitorNiriSettings: monitorNiriSettings,
            preventSleepEnabled: preventSleepEnabled,
            ipcEnabled: ipcEnabled,
            scrollGestureEnabled: scrollGestureEnabled,
            scrollSensitivity: scrollSensitivity,
            scrollModifierKey: scrollModifierKey.rawValue,
            mouseResizeModifierKey: mouseResizeModifierKey.rawValue,
            gestureFingerCount: gestureFingerCount.rawValue,
            gestureInvertDirection: gestureInvertDirection,
            statusBarShowWorkspaceName: statusBarShowWorkspaceName,
            statusBarShowAppNames: statusBarShowAppNames,
            statusBarUseWorkspaceId: statusBarUseWorkspaceId,
            appearanceMode: appearanceMode.rawValue,
            developerModeEnabled: developerModeEnabled,
            ignoreMonitorIdentity: ignoreMonitorIdentity,
            capabilityOverrides: [],
            settingsTOMLUnknownFields: settingsTOMLUnknownFields
        )
    }

    func applyExport(_ export: SettingsExport, monitors: [Monitor]) {
        let baseline = SettingsStore.defaultExport
        isApplyingExport = true
        defer { isApplyingExport = false }

        hotkeysEnabled = export.hotkeysEnabled
        focusFollowsMouse = export.focusFollowsMouse
        moveMouseToFocusedWindow = export.moveMouseToFocusedWindow
        focusFollowsWindowToMonitor = export.focusFollowsWindowToMonitor
        mouseWarpEnabled = export.mouseWarpEnabled
        mouseWarpMonitorOrder = export.mouseWarpMonitorOrder
        mouseWarpAxis = MouseWarpAxis(rawValue: export.mouseWarpAxis ?? baseline.mouseWarpAxis ?? "") ?? .horizontal
        mouseWarpMargin = export.mouseWarpMargin
        gapSize = export.gapSize
        outerGapLeft = export.outerGapLeft
        outerGapRight = export.outerGapRight
        outerGapTop = export.outerGapTop
        outerGapBottom = export.outerGapBottom

        niriBalancedColumnCount = export.niriBalancedColumnCount
        niriInfiniteLoop = export.niriInfiniteLoop
        revealPartial = RevealPartial(rawValue: export.revealPartial) ?? .default
        niriLoneWindowMaxWidth = SettingsStore.validatedLoneWindowMaxWidth(export.niriLoneWindowMaxWidth)
        niriColumnWidthPresets = SettingsStore.validatedPresets(
            export.niriColumnWidthPresets ?? baseline.niriColumnWidthPresets ?? SettingsStore.defaultColumnWidthPresets
        )
        niriDefaultColumnWidth = SettingsStore.validatedDefaultColumnWidth(export.niriDefaultColumnWidth)

        workspaceConfigurations = SettingsStore.normalizedWorkspaceConfigurations(
            export.workspaceConfigurations,
            monitors: monitors,
            ignoreIdentity: export.ignoreMonitorIdentity
        )

        bordersEnabled = export.bordersEnabled
        borderWidth = export.borderWidth
        borderColorRed = export.borderColorRed
        borderColorGreen = export.borderColorGreen
        borderColorBlue = export.borderColorBlue
        borderColorAlpha = export.borderColorAlpha

        hotkeyBindings = export.hotkeyBindings

        workspaceBarEnabled = export.workspaceBarEnabled
        workspaceBarShowLabels = export.workspaceBarShowLabels
        workspaceBarShowFloatingWindows = export.workspaceBarShowFloatingWindows
        workspaceBarShowTraceButton = export.workspaceBarShowTraceButton
        workspaceBarWindowLevel = WorkspaceBarWindowLevel(rawValue: export.workspaceBarWindowLevel) ?? .popup
        workspaceBarPosition = WorkspaceBarPosition(rawValue: export.workspaceBarPosition) ?? .overlappingMenuBar
        workspaceBarNotchAware = export.workspaceBarNotchAware
        workspaceBarDeduplicateAppIcons = export.workspaceBarDeduplicateAppIcons
        workspaceBarHideEmptyWorkspaces = export.workspaceBarHideEmptyWorkspaces
        workspaceBarReserveLayoutSpace = export.workspaceBarReserveLayoutSpace
        workspaceBarHeight = export.workspaceBarHeight
        workspaceBarBackgroundOpacity = export.workspaceBarBackgroundOpacity
        workspaceBarXOffset = export.workspaceBarXOffset
        workspaceBarYOffset = export.workspaceBarYOffset
        workspaceBarAccentColor = export.workspaceBarAccentColor
        workspaceBarTextColor = export.workspaceBarTextColor
        monitorBarSettings = SettingsStore.reboundMonitorSettings(
            export.monitorBarSettings,
            monitors: monitors,
            ignoreIdentity: export.ignoreMonitorIdentity
        )

        appRules = export.appRules
        monitorGapSettings = SettingsStore.reboundMonitorSettings(
            export.monitorGapSettings,
            monitors: monitors,
            ignoreIdentity: export.ignoreMonitorIdentity
        )
        monitorOrientationSettings = SettingsStore.reboundMonitorSettings(
            export.monitorOrientationSettings,
            monitors: monitors,
            ignoreIdentity: export.ignoreMonitorIdentity
        )
        monitorNiriSettings = SettingsStore.reboundMonitorSettings(
            export.monitorNiriSettings,
            monitors: monitors,
            ignoreIdentity: export.ignoreMonitorIdentity
        )

        preventSleepEnabled = export.preventSleepEnabled
        ipcEnabled = export.ipcEnabled
        scrollGestureEnabled = export.scrollGestureEnabled
        scrollSensitivity = export.scrollSensitivity
        scrollModifierKey = ScrollModifierKey(rawValue: export.scrollModifierKey) ?? .optionShift
        mouseResizeModifierKey = MouseResizeModifierKey(rawValue: export.mouseResizeModifierKey) ?? .option
        gestureFingerCount = GestureFingerCount(rawValue: export.gestureFingerCount) ?? .three
        gestureInvertDirection = export.gestureInvertDirection
        statusBarShowWorkspaceName = export.statusBarShowWorkspaceName
        statusBarShowAppNames = export.statusBarShowAppNames
        statusBarUseWorkspaceId = export.statusBarUseWorkspaceId

        appearanceMode = AppearanceMode(rawValue: export.appearanceMode) ?? .dark
        developerModeEnabled = export.developerModeEnabled
        ignoreMonitorIdentity = export.ignoreMonitorIdentity
        settingsTOMLUnknownFields = export.settingsTOMLUnknownFields
    }

    private func handleExternalReload(_ export: SettingsExport) {
        applyExport(export, monitors: Monitor.current())
        onExternalSettingsReloaded?()
    }

    private func scheduleSave() {
        guard autosaveEnabled, !isApplyingExport else { return }
        persistence.scheduleSave(toExport())
    }

    func resetHotkeysToDefaults() {
        hotkeyBindings = HotkeyBindingRegistry.defaults()
    }

    func updateBinding(for commandId: String, newBinding: KeyBinding) {
        updateTrigger(for: commandId, newTrigger: newBinding.isUnassigned ? .unassigned : .chord(newBinding))
    }

    func updateTrigger(for commandId: String, newTrigger: HotkeyTrigger) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == commandId }) else { return }
        hotkeyBindings[index] = HotkeyBinding(
            id: hotkeyBindings[index].id,
            command: hotkeyBindings[index].command,
            trigger: newTrigger
        )
    }

    func clearBinding(for commandId: String) {
        updateBinding(for: commandId, newBinding: .unassigned)
    }

    func resetBindings(for commandId: String) {
        guard let defaultBinding = HotkeyBindingRegistry.defaults().first(where: { $0.id == commandId }),
              let index = hotkeyBindings.firstIndex(where: { $0.id == commandId })
        else { return }
        hotkeyBindings[index] = defaultBinding
    }

    func findConflicts(for binding: KeyBinding, excluding commandId: String) -> [HotkeyBinding] {
        findConflicts(for: binding.isUnassigned ? .unassigned : .chord(binding), excluding: commandId)
    }

    func findConflicts(for trigger: HotkeyTrigger, excluding commandId: String) -> [HotkeyBinding] {
        hotkeyBindings.filter { hotkeyBinding in
            hotkeyBinding.id != commandId &&
                hotkeyBinding.binding.conflicts(with: trigger)
        }
    }

    func configuredWorkspaceNames() -> [String] {
        workspaceConfigurations.map(\.name)
    }

    func displayName(for workspaceName: String) -> String {
        workspaceConfigurations.first(where: { $0.name == workspaceName })?.effectiveDisplayName ?? workspaceName
    }

    func effectiveMouseWarpMonitorOrder(for monitors: [Monitor], axis: MouseWarpAxis? = nil) -> [String] {
        let sortedNames = (axis ?? mouseWarpAxis).sortedMonitors(monitors).map(\.name)
        guard !sortedNames.isEmpty else { return [] }

        var remainingCounts = sortedNames.reduce(into: [String: Int]()) { counts, name in
            counts[name, default: 0] += 1
        }
        var resolved: [String] = []

        for name in mouseWarpMonitorOrder {
            guard let remaining = remainingCounts[name], remaining > 0 else { continue }
            resolved.append(name)
            remainingCounts[name] = remaining - 1
        }

        for name in sortedNames {
            guard let remaining = remainingCounts[name], remaining > 0 else { continue }
            resolved.append(name)
            remainingCounts[name] = remaining - 1
        }

        return resolved
    }

    static func normalizedWorkspaceConfigurations(
        _ configs: [WorkspaceConfiguration],
        monitors: [Monitor] = [],
        ignoreIdentity: Bool = false
    ) -> [WorkspaceConfiguration] {
        var seen: Set<String> = []
        let rebound = configs.map { config in
            guard case let .specificDisplay(output) = config.monitorAssignment,
                  let resolvedMonitor = output.resolveMonitor(in: monitors, ignoreIdentity: ignoreIdentity)
            else {
                return config
            }

            var updated = config
            updated.monitorAssignment = .specificDisplay(OutputId(from: resolvedMonitor))
            return updated
        }

        let normalized = rebound
            .filter { WorkspaceIDPolicy.normalizeRawID($0.name) != nil }
            .filter { seen.insert($0.name).inserted }
            .sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }

        if normalized.isEmpty {
            return BuiltInSettingsDefaults.workspaceConfigurations
        }

        return normalized
    }

    private static func reboundMonitorSettings<T: MonitorSettingsType>(
        _ settings: [T],
        monitors: [Monitor],
        ignoreIdentity: Bool = false
    ) -> [T] {
        if ignoreIdentity {
            return reboundMonitorSettingsByPosition(settings, monitors: monitors)
        }

        return settings.map { setting in
            var rebound = setting
            let resolvedMonitor = reboundMonitor(
                displayId: rebound.monitorDisplayId,
                monitorName: rebound.monitorName,
                anchorPoint: nil,
                monitors: monitors,
                ignoreIdentity: false
            )
            applyResolvedMonitor(resolvedMonitor, to: &rebound)
            return rebound
        }
    }

    private static func reboundMonitorSettingsByPosition<T: MonitorSettingsType>(
        _ settings: [T],
        monitors: [Monitor]
    ) -> [T] {
        var rebound = settings
        var resolvedMonitorByIndex: [Int: Monitor] = [:]
        var usedMonitorIds = Set<Monitor.ID>()

        for index in rebound.indices {
            guard let displayId = rebound[index].monitorDisplayId,
                  let exact = monitors.first(where: { $0.displayId == displayId }),
                  usedMonitorIds.insert(exact.id).inserted
            else { continue }
            resolvedMonitorByIndex[index] = exact
        }

        let anchorMatches = rebound.indices.flatMap { index -> [(index: Int, monitor: Monitor, distance: CGFloat)] in
            guard resolvedMonitorByIndex[index] == nil,
                  let anchor = rebound[index].monitorAnchorPoint
            else { return [] }
            return monitors
                .filter { !usedMonitorIds.contains($0.id) }
                .map { (index: index, monitor: $0, distance: anchor.distanceSquared(to: $0.workspaceAnchorPoint)) }
        }
        .sorted { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            if lhs.index != rhs.index { return lhs.index < rhs.index }
            return monitorSortKey(lhs.monitor) < monitorSortKey(rhs.monitor)
        }

        var usedSettingIndices = Set(resolvedMonitorByIndex.keys)
        for match in anchorMatches {
            guard !usedSettingIndices.contains(match.index),
                  usedMonitorIds.insert(match.monitor.id).inserted
            else { continue }
            resolvedMonitorByIndex[match.index] = match.monitor
            usedSettingIndices.insert(match.index)
        }

        for index in rebound.indices where resolvedMonitorByIndex[index] == nil {
            let matches = monitors.filter {
                !usedMonitorIds.contains($0.id) && $0.name
                    .caseInsensitiveCompare(rebound[index].monitorName) == .orderedSame
            }
            guard matches.count == 1, let match = matches.first else { continue }
            resolvedMonitorByIndex[index] = match
            usedMonitorIds.insert(match.id)
        }

        for index in rebound.indices {
            applyResolvedMonitor(resolvedMonitorByIndex[index], to: &rebound[index])
        }
        return rebound
    }

    private static func applyResolvedMonitor<T: MonitorSettingsType>(_ monitor: Monitor?, to setting: inout T) {
        setting.monitorDisplayId = monitor?.displayId
        // Refresh the saved anchor whenever the monitor is currently connected, so a later
        // reconnect can match this override by layout position. When the monitor is absent,
        // keep the previously stored anchor.
        if let monitor {
            setting.monitorAnchorPoint = monitor.workspaceAnchorPoint
        }
    }

    private static func reboundMonitorDisplayId(
        _ displayId: CGDirectDisplayID?,
        monitorName: String,
        monitors: [Monitor]
    ) -> CGDirectDisplayID? {
        reboundMonitor(
            displayId: displayId,
            monitorName: monitorName,
            anchorPoint: nil,
            monitors: monitors,
            ignoreIdentity: false
        )?.displayId
    }

    private static func reboundMonitor(
        displayId: CGDirectDisplayID?,
        monitorName: String,
        anchorPoint: CGPoint?,
        monitors: [Monitor],
        ignoreIdentity: Bool
    ) -> Monitor? {
        if let displayId, let exact = monitors.first(where: { $0.displayId == displayId }) {
            return exact
        }
        if ignoreIdentity, let anchorPoint {
            return monitors.min {
                $0.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
                    < $1.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            }
        }
        let matches = monitors.filter { $0.name.caseInsensitiveCompare(monitorName) == .orderedSame }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    func barSettings(for monitor: Monitor) -> MonitorBarSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorBarSettings)
    }

    func barSettings(for monitorName: String) -> MonitorBarSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorBarSettings)
    }

    func updateBarSettings(_ settings: MonitorBarSettings) {
        MonitorSettingsStore.update(settings, in: &monitorBarSettings)
    }

    func removeBarSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorBarSettings)
    }

    func removeBarSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorBarSettings)
    }

    func resolvedBarSettings(for monitor: Monitor) -> ResolvedBarSettings {
        resolvedBarSettings(override: barSettings(for: monitor))
    }

    func resolvedBarSettings(for monitorName: String) -> ResolvedBarSettings {
        resolvedBarSettings(override: barSettings(for: monitorName))
    }

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
            windowLevel: override?.windowLevel ?? workspaceBarWindowLevel,
            height: override?.height ?? workspaceBarHeight,
            backgroundOpacity: override?.backgroundOpacity ?? workspaceBarBackgroundOpacity,
            xOffset: override?.xOffset ?? workspaceBarXOffset,
            yOffset: override?.yOffset ?? workspaceBarYOffset,
            accentColor: workspaceBarAccentColor,
            textColor: workspaceBarTextColor
        )
    }

    func appRule(for bundleId: String) -> AppRule? {
        appRules.first { $0.bundleId == bundleId }
    }

    func gapSettings(for monitor: Monitor) -> MonitorGapSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorGapSettings)
    }

    func gapSettings(for monitorName: String) -> MonitorGapSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorGapSettings)
    }

    func updateGapSettings(_ settings: MonitorGapSettings) {
        MonitorSettingsStore.update(settings, in: &monitorGapSettings)
    }

    func removeGapSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorGapSettings)
    }

    func removeGapSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorGapSettings)
    }

    func resolvedGapSettings(for monitor: Monitor) -> ResolvedGapSettings {
        let override = gapSettings(for: monitor)
        return ResolvedGapSettings(
            gapSize: (override?.gapSize ?? gapSize).clamped(to: 0 ... 64),
            outerGapLeft: (override?.outerGapLeft ?? outerGapLeft).clamped(to: 0 ... 64),
            outerGapRight: (override?.outerGapRight ?? outerGapRight).clamped(to: 0 ... 64),
            outerGapTop: (override?.outerGapTop ?? outerGapTop).clamped(to: 0 ... 64),
            outerGapBottom: (override?.outerGapBottom ?? outerGapBottom).clamped(to: 0 ... 64)
        )
    }

    func orientationSettings(for monitor: Monitor) -> MonitorOrientationSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorOrientationSettings)
    }

    func orientationSettings(for monitorName: String) -> MonitorOrientationSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorOrientationSettings)
    }

    func effectiveOrientation(for monitor: Monitor) -> Monitor.Orientation {
        if let override = orientationSettings(for: monitor),
           let orientation = override.orientation
        {
            return orientation
        }
        return monitor.autoOrientation
    }

    func updateOrientationSettings(_ settings: MonitorOrientationSettings) {
        MonitorSettingsStore.update(settings, in: &monitorOrientationSettings)
    }

    func removeOrientationSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorOrientationSettings)
    }

    func removeOrientationSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorOrientationSettings)
    }

    func niriSettings(for monitor: Monitor) -> MonitorNiriSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorNiriSettings)
    }

    func niriSettings(for monitorName: String) -> MonitorNiriSettings? {
        MonitorSettingsStore.get(for: monitorName, in: monitorNiriSettings)
    }

    func updateNiriSettings(_ settings: MonitorNiriSettings) {
        MonitorSettingsStore.update(settings, in: &monitorNiriSettings)
    }

    func removeNiriSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorNiriSettings)
    }

    func removeNiriSettings(for monitorName: String) {
        MonitorSettingsStore.remove(for: monitorName, from: &monitorNiriSettings)
    }

    func resolvedNiriSettings(for monitor: Monitor) -> ResolvedNiriSettings {
        resolvedNiriSettings(override: niriSettings(for: monitor))
    }

    func resolvedNiriSettings(for monitorName: String) -> ResolvedNiriSettings {
        resolvedNiriSettings(override: niriSettings(for: monitorName))
    }

    private func resolvedNiriSettings(override: MonitorNiriSettings?) -> ResolvedNiriSettings {
        let resolvedDefaultColumnWidth: DefaultColumnWidth
        if let balancedColumnCount = override?.balancedColumnCount,
           niriDefaultColumnWidth == nil
        {
            // balancedColumnCount only affects the Balanced column count. When the global mode is
            // Custom (non-nil defaultColumnWidth), preserve the custom fraction and ignore the
            // monitor count override so it doesn't silently defeat the global custom width.
            resolvedDefaultColumnWidth = .balanced(columns: balancedColumnCount.clamped(to: 1 ... 5))
        } else {
            resolvedDefaultColumnWidth = defaultColumnWidth
        }

        let resolvedLoneWindowPolicy: LoneWindowPolicy
        if let overridePolicy = override?.loneWindowPolicy {
            resolvedLoneWindowPolicy = overridePolicy
        } else {
            resolvedLoneWindowPolicy = loneWindowPolicy
        }

        return ResolvedNiriSettings(
            defaultColumnWidth: resolvedDefaultColumnWidth,
            loneWindowPolicy: resolvedLoneWindowPolicy,
            infiniteLoop: niriInfiniteLoop
        )
    }

    nonisolated static let defaultColumnWidthPresets: [Double] = BuiltInSettingsDefaults.niriColumnWidthPresets

    static func validatedPresets(_ presets: [Double]) -> [Double] {
        let result = presets.map { min(1.0, max(0.05, $0)) }
        if result.count < 2 {
            return defaultColumnWidthPresets
        }
        return result
    }

    static func validatedDefaultColumnWidth(_ width: Double?) -> Double? {
        guard let width else { return nil }
        return min(1.0, max(0.05, width))
    }

    static func validatedLoneWindowMaxWidth(_ width: Double?) -> Double? {
        guard let width else { return nil }
        return min(1.0, max(0.10, width))
    }

    private static func monitorSortKey(_ monitor: Monitor) -> (CGFloat, CGFloat, UInt32) {
        (monitor.frame.minX, -monitor.frame.maxY, monitor.displayId)
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
