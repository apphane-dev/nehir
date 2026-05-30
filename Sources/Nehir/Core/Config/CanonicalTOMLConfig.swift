import Foundation

private extension CanonicalTOMLConfig {
    static func defaults() -> CanonicalTOMLConfig {
        CanonicalTOMLConfig(export: SettingsExport.defaults())
    }
}

private extension KeyedDecodingContainer {
    func decodeWithDefault<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) throws -> T {
        try decodeIfPresent(type, forKey: key) ?? defaultValue
    }
}

struct CanonicalTOMLConfig: Codable, Equatable {
    var general: General
    var focus: Focus
    var mouseWarp: MouseWarp
    var gaps: Gaps
    var niri: Niri
    var borders: Borders
    var workspaceBar: WorkspaceBar
    var gestures: Gestures
    var statusBar: StatusBar
    var appearance: Appearance

    struct General: Codable, Equatable {
        var hotkeysEnabled: Bool
        var preventSleepEnabled: Bool
        var ipcEnabled: Bool
        var animationsEnabled: Bool
    }

    struct Focus: Codable, Equatable {
        var followsMouse: Bool
        var moveMouseToFocusedWindow: Bool
        var followsWindowToMonitor: Bool
    }

    struct MouseWarp: Codable, Equatable {
        // monitorOrder is a flat string array for now; future revision may use a typed OutputId.
        var monitorOrder: [String]
        var axis: String?
        var margin: Int
    }

    struct Gaps: Codable, Equatable {
        var size: Double
        var outer: Outer

        struct Outer: Codable, Equatable {
            var left: Double
            var right: Double
            var top: Double
            var bottom: Double
        }
    }

    struct Niri: Codable, Equatable {
        var maxVisibleColumns: Int
        var infiniteLoop: Bool
        var centerFocusedColumn: String
        var alwaysCenterSingleColumn: Bool
        var singleWindowAspectRatio: String
        var columnWidthPresets: [Double]?
        var defaultColumnWidth: Double?
    }

    struct Borders: Codable, Equatable {
        var enabled: Bool
        var width: Double
        var color: Color

        struct Color: Codable, Equatable {
            var red: Double
            var green: Double
            var blue: Double
            var alpha: Double
        }
    }

    struct WorkspaceBar: Codable, Equatable {
        var enabled: Bool
        var showLabels: Bool
        var showFloatingWindows: Bool
        var windowLevel: String
        var position: String
        var notchAware: Bool
        var deduplicateAppIcons: Bool
        var hideEmptyWorkspaces: Bool
        var reserveLayoutSpace: Bool
        var height: Double
        var backgroundOpacity: Double
        var xOffset: Double
        var yOffset: Double
        var labelFontSize: Double
        var accentColor: Color?
        var textColor: Color?

        struct Color: Codable, Equatable {
            var red: Double
            var green: Double
            var blue: Double
            var alpha: Double

            init(red: Double, green: Double, blue: Double, alpha: Double) {
                self.red = red
                self.green = green
                self.blue = blue
                self.alpha = alpha
            }

            init(_ color: SettingsColor) {
                red = color.red
                green = color.green
                blue = color.blue
                alpha = color.alpha
            }

            var settingsColor: SettingsColor {
                SettingsColor(red: red, green: green, blue: blue, alpha: alpha)
            }
        }
    }

    struct Gestures: Codable, Equatable {
        var scrollEnabled: Bool
        var scrollSensitivity: Double
        var scrollModifierKey: String
        var mouseResizeModifierKey: String
        var fingerCount: Int
        var invertDirection: Bool
    }

    struct StatusBar: Codable, Equatable {
        var showWorkspaceName: Bool
        var showAppNames: Bool
        var useWorkspaceId: Bool
    }

    struct Appearance: Codable, Equatable {
        var mode: String
    }
}

extension CanonicalTOMLConfig {
    init(export: SettingsExport) {
        general = General(
            hotkeysEnabled: export.hotkeysEnabled,
            preventSleepEnabled: export.preventSleepEnabled,
            ipcEnabled: export.ipcEnabled,
            animationsEnabled: export.animationsEnabled
        )
        focus = Focus(
            followsMouse: export.focusFollowsMouse,
            moveMouseToFocusedWindow: export.moveMouseToFocusedWindow,
            followsWindowToMonitor: export.focusFollowsWindowToMonitor
        )
        mouseWarp = MouseWarp(
            monitorOrder: export.mouseWarpMonitorOrder,
            axis: export.mouseWarpAxis,
            margin: export.mouseWarpMargin
        )
        gaps = Gaps(
            size: export.gapSize,
            outer: Gaps.Outer(
                left: export.outerGapLeft,
                right: export.outerGapRight,
                top: export.outerGapTop,
                bottom: export.outerGapBottom
            )
        )
        niri = Niri(
            maxVisibleColumns: export.niriMaxVisibleColumns,
            infiniteLoop: export.niriInfiniteLoop,
            centerFocusedColumn: export.niriCenterFocusedColumn,
            alwaysCenterSingleColumn: export.niriAlwaysCenterSingleColumn,
            singleWindowAspectRatio: export.niriSingleWindowAspectRatio,
            columnWidthPresets: export.niriColumnWidthPresets,
            defaultColumnWidth: export.niriDefaultColumnWidth
        )
        borders = Borders(
            enabled: export.bordersEnabled,
            width: export.borderWidth,
            color: Borders.Color(
                red: export.borderColorRed,
                green: export.borderColorGreen,
                blue: export.borderColorBlue,
                alpha: export.borderColorAlpha
            )
        )
        workspaceBar = WorkspaceBar(
            enabled: export.workspaceBarEnabled,
            showLabels: export.workspaceBarShowLabels,
            showFloatingWindows: export.workspaceBarShowFloatingWindows,
            windowLevel: export.workspaceBarWindowLevel,
            position: export.workspaceBarPosition,
            notchAware: export.workspaceBarNotchAware,
            deduplicateAppIcons: export.workspaceBarDeduplicateAppIcons,
            hideEmptyWorkspaces: export.workspaceBarHideEmptyWorkspaces,
            reserveLayoutSpace: export.workspaceBarReserveLayoutSpace,
            height: export.workspaceBarHeight,
            backgroundOpacity: export.workspaceBarBackgroundOpacity,
            xOffset: export.workspaceBarXOffset,
            yOffset: export.workspaceBarYOffset,
            labelFontSize: export.workspaceBarLabelFontSize,
            accentColor: export.workspaceBarAccentColor.map(WorkspaceBar.Color.init),
            textColor: export.workspaceBarTextColor.map(WorkspaceBar.Color.init)
        )
        gestures = Gestures(
            scrollEnabled: export.scrollGestureEnabled,
            scrollSensitivity: export.scrollSensitivity,
            scrollModifierKey: export.scrollModifierKey,
            mouseResizeModifierKey: export.mouseResizeModifierKey,
            fingerCount: export.gestureFingerCount,
            invertDirection: export.gestureInvertDirection
        )
        statusBar = StatusBar(
            showWorkspaceName: export.statusBarShowWorkspaceName,
            showAppNames: export.statusBarShowAppNames,
            useWorkspaceId: export.statusBarUseWorkspaceId
        )
        appearance = Appearance(mode: export.appearanceMode)
    }

    func toSettingsExport() -> SettingsExport {
        return SettingsExport(
            hotkeysEnabled: general.hotkeysEnabled,
            focusFollowsMouse: focus.followsMouse,
            moveMouseToFocusedWindow: focus.moveMouseToFocusedWindow,
            focusFollowsWindowToMonitor: focus.followsWindowToMonitor,
            mouseWarpMonitorOrder: mouseWarp.monitorOrder,
            mouseWarpAxis: mouseWarp.axis,
            mouseWarpMargin: mouseWarp.margin,
            gapSize: gaps.size,
            outerGapLeft: gaps.outer.left,
            outerGapRight: gaps.outer.right,
            outerGapTop: gaps.outer.top,
            outerGapBottom: gaps.outer.bottom,
            niriMaxVisibleColumns: niri.maxVisibleColumns,
            niriInfiniteLoop: niri.infiniteLoop,
            niriCenterFocusedColumn: niri.centerFocusedColumn,
            niriAlwaysCenterSingleColumn: niri.alwaysCenterSingleColumn,
            niriSingleWindowAspectRatio: niri.singleWindowAspectRatio,
            niriColumnWidthPresets: niri.columnWidthPresets,
            niriDefaultColumnWidth: niri.defaultColumnWidth,
            workspaceConfigurations: BuiltInSettingsDefaults.workspaceConfigurations,
            bordersEnabled: borders.enabled,
            borderWidth: borders.width,
            borderColorRed: borders.color.red,
            borderColorGreen: borders.color.green,
            borderColorBlue: borders.color.blue,
            borderColorAlpha: borders.color.alpha,
            hotkeyBindings: HotkeyBindingRegistry.defaults(),
            workspaceBarEnabled: workspaceBar.enabled,
            workspaceBarShowLabels: workspaceBar.showLabels,
            workspaceBarShowFloatingWindows: workspaceBar.showFloatingWindows,
            workspaceBarWindowLevel: workspaceBar.windowLevel,
            workspaceBarPosition: workspaceBar.position,
            workspaceBarNotchAware: workspaceBar.notchAware,
            workspaceBarDeduplicateAppIcons: workspaceBar.deduplicateAppIcons,
            workspaceBarHideEmptyWorkspaces: workspaceBar.hideEmptyWorkspaces,
            workspaceBarReserveLayoutSpace: workspaceBar.reserveLayoutSpace,
            workspaceBarHeight: workspaceBar.height,
            workspaceBarBackgroundOpacity: workspaceBar.backgroundOpacity,
            workspaceBarXOffset: workspaceBar.xOffset,
            workspaceBarYOffset: workspaceBar.yOffset,
            workspaceBarAccentColor: workspaceBar.accentColor?.settingsColor,
            workspaceBarTextColor: workspaceBar.textColor?.settingsColor,
            workspaceBarLabelFontSize: workspaceBar.labelFontSize,
            monitorBarSettings: [],
            appRules: BuiltInSettingsDefaults.appRules,
            monitorOrientationSettings: [],
            monitorNiriSettings: [],
            preventSleepEnabled: general.preventSleepEnabled,
            ipcEnabled: general.ipcEnabled,
            scrollGestureEnabled: gestures.scrollEnabled,
            scrollSensitivity: gestures.scrollSensitivity,
            scrollModifierKey: gestures.scrollModifierKey,
            mouseResizeModifierKey: gestures.mouseResizeModifierKey,
            gestureFingerCount: gestures.fingerCount,
            gestureInvertDirection: gestures.invertDirection,
            statusBarShowWorkspaceName: statusBar.showWorkspaceName,
            statusBarShowAppNames: statusBar.showAppNames,
            statusBarUseWorkspaceId: statusBar.useWorkspaceId,
            animationsEnabled: general.animationsEnabled,
            appearanceMode: appearance.mode
        )
    }
}

// MARK: - Hand-edit tolerant decoding (missing keys use defaults)

extension CanonicalTOMLConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults()
        general = try container.decodeWithDefault(General.self, forKey: .general, default: d.general)
        focus = try container.decodeWithDefault(Focus.self, forKey: .focus, default: d.focus)
        mouseWarp = try container.decodeWithDefault(MouseWarp.self, forKey: .mouseWarp, default: d.mouseWarp)
        gaps = try container.decodeWithDefault(Gaps.self, forKey: .gaps, default: d.gaps)
        niri = try container.decodeWithDefault(Niri.self, forKey: .niri, default: d.niri)
        borders = try container.decodeWithDefault(Borders.self, forKey: .borders, default: d.borders)
        workspaceBar = try container.decodeWithDefault(WorkspaceBar.self, forKey: .workspaceBar, default: d.workspaceBar)
        gestures = try container.decodeWithDefault(Gestures.self, forKey: .gestures, default: d.gestures)
        statusBar = try container.decodeWithDefault(StatusBar.self, forKey: .statusBar, default: d.statusBar)
        appearance = try container.decodeWithDefault(Appearance.self, forKey: .appearance, default: d.appearance)
    }
}

extension CanonicalTOMLConfig.General {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().general
        hotkeysEnabled = try container.decodeWithDefault(Bool.self, forKey: .hotkeysEnabled, default: d.hotkeysEnabled)
        preventSleepEnabled = try container.decodeWithDefault(Bool.self, forKey: .preventSleepEnabled, default: d.preventSleepEnabled)
        ipcEnabled = try container.decodeWithDefault(Bool.self, forKey: .ipcEnabled, default: d.ipcEnabled)
        animationsEnabled = try container.decodeWithDefault(Bool.self, forKey: .animationsEnabled, default: d.animationsEnabled)
    }
}

extension CanonicalTOMLConfig.Focus {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().focus
        followsMouse = try container.decodeWithDefault(Bool.self, forKey: .followsMouse, default: d.followsMouse)
        moveMouseToFocusedWindow = try container.decodeWithDefault(Bool.self, forKey: .moveMouseToFocusedWindow, default: d.moveMouseToFocusedWindow)
        followsWindowToMonitor = try container.decodeWithDefault(Bool.self, forKey: .followsWindowToMonitor, default: d.followsWindowToMonitor)
    }
}

extension CanonicalTOMLConfig.MouseWarp {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().mouseWarp
        monitorOrder = try container.decodeWithDefault([String].self, forKey: .monitorOrder, default: d.monitorOrder)
        axis = try container.decodeIfPresent(String.self, forKey: .axis)
        margin = try container.decodeWithDefault(Int.self, forKey: .margin, default: d.margin)
    }
}

extension CanonicalTOMLConfig.Gaps {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().gaps
        size = try container.decodeWithDefault(Double.self, forKey: .size, default: d.size)
        outer = try container.decodeWithDefault(Outer.self, forKey: .outer, default: d.outer)
    }
}

extension CanonicalTOMLConfig.Gaps.Outer {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().gaps.outer
        left = try container.decodeWithDefault(Double.self, forKey: .left, default: d.left)
        right = try container.decodeWithDefault(Double.self, forKey: .right, default: d.right)
        top = try container.decodeWithDefault(Double.self, forKey: .top, default: d.top)
        bottom = try container.decodeWithDefault(Double.self, forKey: .bottom, default: d.bottom)
    }
}

extension CanonicalTOMLConfig.Niri {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().niri
        maxVisibleColumns = try container.decodeWithDefault(Int.self, forKey: .maxVisibleColumns, default: d.maxVisibleColumns)
        infiniteLoop = try container.decodeWithDefault(Bool.self, forKey: .infiniteLoop, default: d.infiniteLoop)
        centerFocusedColumn = try container.decodeWithDefault(String.self, forKey: .centerFocusedColumn, default: d.centerFocusedColumn)
        alwaysCenterSingleColumn = try container.decodeWithDefault(Bool.self, forKey: .alwaysCenterSingleColumn, default: d.alwaysCenterSingleColumn)
        singleWindowAspectRatio = try container.decodeWithDefault(String.self, forKey: .singleWindowAspectRatio, default: d.singleWindowAspectRatio)
        columnWidthPresets = try container.decodeIfPresent([Double].self, forKey: .columnWidthPresets)
        defaultColumnWidth = try container.decodeIfPresent(Double.self, forKey: .defaultColumnWidth)
    }
}

extension CanonicalTOMLConfig.Borders {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().borders
        enabled = try container.decodeWithDefault(Bool.self, forKey: .enabled, default: d.enabled)
        width = try container.decodeWithDefault(Double.self, forKey: .width, default: d.width)
        color = try container.decodeWithDefault(Color.self, forKey: .color, default: d.color)
    }
}

extension CanonicalTOMLConfig.Borders.Color {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().borders.color
        red = try container.decodeWithDefault(Double.self, forKey: .red, default: d.red)
        green = try container.decodeWithDefault(Double.self, forKey: .green, default: d.green)
        blue = try container.decodeWithDefault(Double.self, forKey: .blue, default: d.blue)
        alpha = try container.decodeWithDefault(Double.self, forKey: .alpha, default: d.alpha)
    }
}

extension CanonicalTOMLConfig.WorkspaceBar {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().workspaceBar
        enabled = try container.decodeWithDefault(Bool.self, forKey: .enabled, default: d.enabled)
        showLabels = try container.decodeWithDefault(Bool.self, forKey: .showLabels, default: d.showLabels)
        showFloatingWindows = try container.decodeWithDefault(Bool.self, forKey: .showFloatingWindows, default: d.showFloatingWindows)
        windowLevel = try container.decodeWithDefault(String.self, forKey: .windowLevel, default: d.windowLevel)
        position = try container.decodeWithDefault(String.self, forKey: .position, default: d.position)
        notchAware = try container.decodeWithDefault(Bool.self, forKey: .notchAware, default: d.notchAware)
        deduplicateAppIcons = try container.decodeWithDefault(Bool.self, forKey: .deduplicateAppIcons, default: d.deduplicateAppIcons)
        hideEmptyWorkspaces = try container.decodeWithDefault(Bool.self, forKey: .hideEmptyWorkspaces, default: d.hideEmptyWorkspaces)
        reserveLayoutSpace = try container.decodeWithDefault(Bool.self, forKey: .reserveLayoutSpace, default: d.reserveLayoutSpace)
        height = try container.decodeWithDefault(Double.self, forKey: .height, default: d.height)
        backgroundOpacity = try container.decodeWithDefault(Double.self, forKey: .backgroundOpacity, default: d.backgroundOpacity)
        xOffset = try container.decodeWithDefault(Double.self, forKey: .xOffset, default: d.xOffset)
        yOffset = try container.decodeWithDefault(Double.self, forKey: .yOffset, default: d.yOffset)
        labelFontSize = try container.decodeWithDefault(Double.self, forKey: .labelFontSize, default: d.labelFontSize)
        accentColor = try container.decodeIfPresent(Color.self, forKey: .accentColor)
        textColor = try container.decodeIfPresent(Color.self, forKey: .textColor)
    }
}

extension CanonicalTOMLConfig.Gestures {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().gestures
        scrollEnabled = try container.decodeWithDefault(Bool.self, forKey: .scrollEnabled, default: d.scrollEnabled)
        scrollSensitivity = try container.decodeWithDefault(Double.self, forKey: .scrollSensitivity, default: d.scrollSensitivity)
        scrollModifierKey = try container.decodeWithDefault(String.self, forKey: .scrollModifierKey, default: d.scrollModifierKey)
        mouseResizeModifierKey = try container.decodeWithDefault(String.self, forKey: .mouseResizeModifierKey, default: d.mouseResizeModifierKey)
        fingerCount = try container.decodeWithDefault(Int.self, forKey: .fingerCount, default: d.fingerCount)
        invertDirection = try container.decodeWithDefault(Bool.self, forKey: .invertDirection, default: d.invertDirection)
    }
}

extension CanonicalTOMLConfig.StatusBar {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().statusBar
        showWorkspaceName = try container.decodeWithDefault(Bool.self, forKey: .showWorkspaceName, default: d.showWorkspaceName)
        showAppNames = try container.decodeWithDefault(Bool.self, forKey: .showAppNames, default: d.showAppNames)
        useWorkspaceId = try container.decodeWithDefault(Bool.self, forKey: .useWorkspaceId, default: d.useWorkspaceId)
    }
}

extension CanonicalTOMLConfig.Appearance {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().appearance
        mode = try container.decodeWithDefault(String.self, forKey: .mode, default: d.mode)
    }
}
