// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import NehirIPC

// MARK: - SettingsExport

struct SettingsColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

struct SettingsExport: Equatable, Sendable {
    var hotkeysEnabled: Bool
    var focusFollowsMouse: Bool
    var moveMouseToFocusedWindow: Bool
    var focusFollowsWindowToMonitor: Bool
    var mouseWarpEnabled: Bool
    var mouseWarpMonitorOrder: [String]
    var mouseWarpAxis: String?
    var mouseWarpMargin: Int
    var gapSize: Double
    var outerGapLeft: Double
    var outerGapRight: Double
    var outerGapTop: Double
    var outerGapBottom: Double

    var niriBalancedColumnCount: Int
    var niriInfiniteLoop: Bool
    var revealStyle: String
    var niriLoneWindowMaxWidth: Double?
    var niriColumnWidthPresets: [Double]?
    var niriDefaultColumnWidth: Double?

    var workspaceConfigurations: [WorkspaceConfiguration]

    var bordersEnabled: Bool
    var borderWidth: Double
    var borderColorRed: Double
    var borderColorGreen: Double
    var borderColorBlue: Double
    var borderColorAlpha: Double

    var hotkeyBindings: [HotkeyBinding]

    var workspaceBarEnabled: Bool
    var workspaceBarShowLabels: Bool
    var workspaceBarShowFloatingWindows: Bool
    var workspaceBarShowTraceButton: Bool
    var workspaceBarShowScrollLockButton: Bool
    var workspaceBarWindowLevel: String
    var workspaceBarPosition: String
    var workspaceBarNotchAware: Bool
    var workspaceBarDeduplicateAppIcons: Bool
    var workspaceBarHideEmptyWorkspaces: Bool
    var workspaceBarReserveLayoutSpace: Bool
    var workspaceBarHeight: Double
    var workspaceBarBackgroundOpacity: Double
    var workspaceBarXOffset: Double
    var workspaceBarYOffset: Double
    var workspaceBarAccentColor: SettingsColor?
    var workspaceBarTextColor: SettingsColor?
    var workspaceBarLabelFontSize: Double
    var monitorBarSettings: [MonitorBarSettings]

    var appRules: [AppRule]
    var monitorGapSettings: [MonitorGapSettings]
    var monitorOrientationSettings: [MonitorOrientationSettings]
    var monitorNiriSettings: [MonitorNiriSettings]

    var preventSleepEnabled: Bool
    var ipcEnabled: Bool
    var scrollGestureEnabled: Bool
    var scrollSensitivity: Double
    var scrollModifierKey: String
    var mouseResizeModifierKey: String
    var gestureFingerCount: Int
    var gestureInvertDirection: Bool
    var statusBarShowWorkspaceName: Bool
    var statusBarShowAppNames: Bool
    var statusBarUseWorkspaceId: Bool

    var appearanceMode: String

    var developerModeEnabled: Bool
    var debugBarEnabled: Bool
    var debugTraceExportCopiesFile: Bool
    var viewportTraceVerbosity: String
    var backgroundTraceRetentionSeconds: TimeInterval
    var backgroundTraceMaxBytes: Int

    /// When enabled, monitor matching during restore ignores the monitor model/name and
    /// resolves displays by layout position (anchor-point geometry) instead, so apps,
    /// workspaces, and per-monitor settings stay on the same monitor across reconnects of
    /// different monitor sets (e.g. home vs office).
    var ignoreMonitorIdentity: Bool

    var capabilityOverrides: [WindowCapabilityProfileTOMLOverride] = []

    /// Unknown keys decoded from settings.toml under known schema tables, grouped by table path.
    /// This is not app state; it exists only so load→mutate→save does not destroy config
    /// written by a newer version or by hand.
    var settingsTOMLUnknownFields: SettingsTOMLUnknownFields = [:]
}

// MARK: - Defaults & Diffing

extension SettingsExport {
    static func defaults() -> SettingsExport {
        SettingsExport(
            hotkeysEnabled: true,
            focusFollowsMouse: false,
            moveMouseToFocusedWindow: false,
            focusFollowsWindowToMonitor: false,
            mouseWarpEnabled: true,
            mouseWarpMonitorOrder: [],
            mouseWarpAxis: MouseWarpAxis.horizontal.rawValue,
            mouseWarpMargin: 1,
            gapSize: 16,
            outerGapLeft: 0,
            outerGapRight: 0,
            outerGapTop: 0,
            outerGapBottom: 0,
            niriBalancedColumnCount: 2,
            niriInfiniteLoop: false,
            revealStyle: RevealStyle.auto.rawValue,
            niriLoneWindowMaxWidth: nil,
            niriColumnWidthPresets: BuiltInSettingsDefaults.niriColumnWidthPresets,
            niriDefaultColumnWidth: nil,
            workspaceConfigurations: BuiltInSettingsDefaults.workspaceConfigurations,
            bordersEnabled: false,
            borderWidth: 5.0,
            borderColorRed: 0.084585202284378935,
            borderColorGreen: 1.0,
            borderColorBlue: 0.97930003794467602,
            borderColorAlpha: 1.0,
            hotkeyBindings: HotkeyBindingRegistry.defaults(),
            workspaceBarEnabled: true,
            workspaceBarShowLabels: true,
            workspaceBarShowFloatingWindows: false,
            workspaceBarShowTraceButton: false,
            workspaceBarShowScrollLockButton: false,
            workspaceBarWindowLevel: WorkspaceBarWindowLevel.popup.rawValue,
            workspaceBarPosition: WorkspaceBarPosition.overlappingMenuBar.rawValue,
            workspaceBarNotchAware: true,
            workspaceBarDeduplicateAppIcons: false,
            workspaceBarHideEmptyWorkspaces: false,
            workspaceBarReserveLayoutSpace: false,
            workspaceBarHeight: 24.0,
            workspaceBarBackgroundOpacity: 0.1,
            workspaceBarXOffset: 0.0,
            workspaceBarYOffset: 0.0,
            workspaceBarAccentColor: nil,
            workspaceBarTextColor: nil,
            workspaceBarLabelFontSize: 12,
            monitorBarSettings: [],
            appRules: BuiltInSettingsDefaults.appRules,
            monitorGapSettings: [],
            monitorOrientationSettings: [],
            monitorNiriSettings: [],
            preventSleepEnabled: false,
            ipcEnabled: false,
            scrollGestureEnabled: true,
            scrollSensitivity: 5.0,
            scrollModifierKey: ScrollModifierKey.optionShift.rawValue,
            mouseResizeModifierKey: MouseResizeModifierKey.option.rawValue,
            gestureFingerCount: GestureFingerCount.three.rawValue,
            gestureInvertDirection: true,
            statusBarShowWorkspaceName: false,
            statusBarShowAppNames: false,
            statusBarUseWorkspaceId: false,
            appearanceMode: AppearanceMode.dark.rawValue,
            developerModeEnabled: false,
            debugBarEnabled: true,
            debugTraceExportCopiesFile: false,
            viewportTraceVerbosity: ViewportTraceVerbosity.standard.rawValue,
            backgroundTraceRetentionSeconds: 0,
            backgroundTraceMaxBytes: 64 * 1024 * 1024,
            ignoreMonitorIdentity: false,
            capabilityOverrides: []
        )
    }
}
