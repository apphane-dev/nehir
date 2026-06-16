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

    enum CodingKeys: String, CodingKey, CaseIterable {
        case general, focus, mouseWarp, gaps, niri, borders, workspaceBar, gestures, statusBar, appearance
    }

    struct General: Codable, Equatable {
        var hotkeysEnabled: Bool
        var preventSleepEnabled: Bool
        var ipcEnabled: Bool
        var developerModeEnabled: Bool
        var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case hotkeysEnabled, preventSleepEnabled, ipcEnabled, developerModeEnabled
        }
    }

    struct Focus: Codable, Equatable {
        var followsMouse: Bool
        var moveMouseToFocusedWindow: Bool
        var followsWindowToMonitor: Bool
        var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case followsMouse, moveMouseToFocusedWindow, followsWindowToMonitor
        }
    }

    struct MouseWarp: Codable, Equatable {
        // monitorOrder is a flat string array for now; future revision may use a typed OutputId.
        var monitorOrder: [String]
        var axis: String?
        var margin: Int
        var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case monitorOrder, axis, margin
        }
    }

    struct Gaps: Codable, Equatable {
        var size: Double
        var outer: Outer
        var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case size, outer
        }

        struct Outer: Codable, Equatable {
            var left: Double
            var right: Double
            var top: Double
            var bottom: Double
            var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

            enum CodingKeys: String, CodingKey, CaseIterable {
                case left, right, top, bottom
            }
        }
    }

    struct Niri: Codable, Equatable {
        var balancedColumnCount: Int
        var infiniteLoop: Bool
        var revealPartial: String
        var loneWindowMaxWidth: Double?
        var columnWidthPresets: [Double]?
        var defaultColumnWidth: Double?
        var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case balancedColumnCount, infiniteLoop, revealPartial, loneWindowMaxWidth, columnWidthPresets, defaultColumnWidth
        }
    }

    struct Borders: Codable, Equatable {
        var enabled: Bool
        var width: Double
        var color: Color
        var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case enabled, width, color
        }

        struct Color: Codable, Equatable {
            var red: Double
            var green: Double
            var blue: Double
            var alpha: Double
            var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

            enum CodingKeys: String, CodingKey, CaseIterable {
                case red, green, blue, alpha
            }

            init(red: Double, green: Double, blue: Double, alpha: Double, unknownFields: [String: SettingsTOMLUnknownValue] = [:]) {
                self.red = red
                self.green = green
                self.blue = blue
                self.alpha = alpha
                self.unknownFields = unknownFields
            }
        }
    }

    struct WorkspaceBar: Codable, Equatable {
        var enabled: Bool
        var showLabels: Bool
        var showFloatingWindows: Bool
        var showTraceButton: Bool
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
        var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case enabled, showLabels, showFloatingWindows, showTraceButton, windowLevel, position, notchAware, deduplicateAppIcons, hideEmptyWorkspaces, reserveLayoutSpace, height, backgroundOpacity, xOffset, yOffset, labelFontSize, accentColor, textColor
        }

        struct Color: Codable, Equatable {
            var red: Double
            var green: Double
            var blue: Double
            var alpha: Double
            var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

            enum CodingKeys: String, CodingKey, CaseIterable {
                case red, green, blue, alpha
            }

            init(red: Double, green: Double, blue: Double, alpha: Double, unknownFields: [String: SettingsTOMLUnknownValue] = [:]) {
                self.red = red
                self.green = green
                self.blue = blue
                self.alpha = alpha
                self.unknownFields = unknownFields
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
        var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case scrollEnabled, scrollSensitivity, scrollModifierKey, mouseResizeModifierKey, fingerCount, invertDirection
        }
    }

    struct StatusBar: Codable, Equatable {
        var showWorkspaceName: Bool
        var showAppNames: Bool
        var useWorkspaceId: Bool
        var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case showWorkspaceName, showAppNames, useWorkspaceId
        }
    }

    struct Appearance: Codable, Equatable {
        var mode: String
        var unknownFields: [String: SettingsTOMLUnknownValue] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case mode
        }
    }
}

extension CanonicalTOMLConfig {
    init(export: SettingsExport) {
        let unknown = export.settingsTOMLUnknownFields
        general = General(
            hotkeysEnabled: export.hotkeysEnabled,
            preventSleepEnabled: export.preventSleepEnabled,
            ipcEnabled: export.ipcEnabled,
            developerModeEnabled: export.developerModeEnabled,
            unknownFields: unknown["general"] ?? [:]
        )
        focus = Focus(
            followsMouse: export.focusFollowsMouse,
            moveMouseToFocusedWindow: export.moveMouseToFocusedWindow,
            followsWindowToMonitor: export.focusFollowsWindowToMonitor,
            unknownFields: unknown["focus"] ?? [:]
        )
        mouseWarp = MouseWarp(
            monitorOrder: export.mouseWarpMonitorOrder,
            axis: export.mouseWarpAxis,
            margin: export.mouseWarpMargin,
            unknownFields: unknown["mouseWarp"] ?? [:]
        )
        gaps = Gaps(
            size: export.gapSize,
            outer: Gaps.Outer(
                left: export.outerGapLeft,
                right: export.outerGapRight,
                top: export.outerGapTop,
                bottom: export.outerGapBottom,
                unknownFields: unknown["gaps.outer"] ?? [:]
            ),
            unknownFields: unknown["gaps"] ?? [:]
        )
        niri = Niri(
            balancedColumnCount: export.niriBalancedColumnCount,
            infiniteLoop: export.niriInfiniteLoop,
            revealPartial: export.revealPartial,
            loneWindowMaxWidth: export.niriLoneWindowMaxWidth,
            columnWidthPresets: export.niriColumnWidthPresets,
            defaultColumnWidth: export.niriDefaultColumnWidth,
            unknownFields: unknown["niri"] ?? [:]
        )
        borders = Borders(
            enabled: export.bordersEnabled,
            width: export.borderWidth,
            color: Borders.Color(
                red: export.borderColorRed,
                green: export.borderColorGreen,
                blue: export.borderColorBlue,
                alpha: export.borderColorAlpha,
                unknownFields: unknown["borders.color"] ?? [:]
            ),
            unknownFields: unknown["borders"] ?? [:]
        )
        workspaceBar = WorkspaceBar(
            enabled: export.workspaceBarEnabled,
            showLabels: export.workspaceBarShowLabels,
            showFloatingWindows: export.workspaceBarShowFloatingWindows,
            showTraceButton: export.workspaceBarShowTraceButton,
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
            accentColor: export.workspaceBarAccentColor.map { color in
                var encoded = WorkspaceBar.Color(color)
                encoded.unknownFields = unknown["workspaceBar.accentColor"] ?? [:]
                return encoded
            },
            textColor: export.workspaceBarTextColor.map { color in
                var encoded = WorkspaceBar.Color(color)
                encoded.unknownFields = unknown["workspaceBar.textColor"] ?? [:]
                return encoded
            },
            unknownFields: unknown["workspaceBar"] ?? [:]
        )
        gestures = Gestures(
            scrollEnabled: export.scrollGestureEnabled,
            scrollSensitivity: export.scrollSensitivity,
            scrollModifierKey: export.scrollModifierKey,
            mouseResizeModifierKey: export.mouseResizeModifierKey,
            fingerCount: export.gestureFingerCount,
            invertDirection: export.gestureInvertDirection,
            unknownFields: unknown["gestures"] ?? [:]
        )
        statusBar = StatusBar(
            showWorkspaceName: export.statusBarShowWorkspaceName,
            showAppNames: export.statusBarShowAppNames,
            useWorkspaceId: export.statusBarUseWorkspaceId,
            unknownFields: unknown["statusBar"] ?? [:]
        )
        appearance = Appearance(mode: export.appearanceMode, unknownFields: unknown["appearance"] ?? [:])
    }

    func toSettingsExport() -> SettingsExport {
        var unknown: SettingsTOMLUnknownFields = [:]
        func add(_ path: String, _ fields: [String: SettingsTOMLUnknownValue]) {
            if !fields.isEmpty { unknown[path] = fields }
        }
        add("general", general.unknownFields)
        add("focus", focus.unknownFields)
        add("mouseWarp", mouseWarp.unknownFields)
        add("gaps", gaps.unknownFields)
        add("gaps.outer", gaps.outer.unknownFields)
        add("niri", niri.unknownFields)
        add("borders", borders.unknownFields)
        add("borders.color", borders.color.unknownFields)
        add("workspaceBar", workspaceBar.unknownFields)
        if let accentColor = workspaceBar.accentColor { add("workspaceBar.accentColor", accentColor.unknownFields) }
        if let textColor = workspaceBar.textColor { add("workspaceBar.textColor", textColor.unknownFields) }
        add("gestures", gestures.unknownFields)
        add("statusBar", statusBar.unknownFields)
        add("appearance", appearance.unknownFields)

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
            niriBalancedColumnCount: niri.balancedColumnCount,
            niriInfiniteLoop: niri.infiniteLoop,
            revealPartial: niri.revealPartial,
            niriLoneWindowMaxWidth: niri.loneWindowMaxWidth,
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
            workspaceBarShowTraceButton: workspaceBar.showTraceButton,
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
            monitorGapSettings: [],
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
            appearanceMode: appearance.mode,
            developerModeEnabled: general.developerModeEnabled,
            settingsTOMLUnknownFields: unknown
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(general, forKey: .general)
        try container.encode(focus, forKey: .focus)
        try container.encode(mouseWarp, forKey: .mouseWarp)
        try container.encode(gaps, forKey: .gaps)
        try container.encode(niri, forKey: .niri)
        try container.encode(borders, forKey: .borders)
        try container.encode(workspaceBar, forKey: .workspaceBar)
        try container.encode(gestures, forKey: .gestures)
        try container.encode(statusBar, forKey: .statusBar)
        try container.encode(appearance, forKey: .appearance)
    }
}

extension CanonicalTOMLConfig.General {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().general
        hotkeysEnabled = try container.decodeWithDefault(Bool.self, forKey: .hotkeysEnabled, default: d.hotkeysEnabled)
        preventSleepEnabled = try container.decodeWithDefault(Bool.self, forKey: .preventSleepEnabled, default: d.preventSleepEnabled)
        ipcEnabled = try container.decodeWithDefault(Bool.self, forKey: .ipcEnabled, default: d.ipcEnabled)
        developerModeEnabled = try container.decodeWithDefault(Bool.self, forKey: .developerModeEnabled, default: d.developerModeEnabled)
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(hotkeysEnabled, forKey: "hotkeysEnabled")
        try container.encode(preventSleepEnabled, forKey: "preventSleepEnabled")
        try container.encode(ipcEnabled, forKey: "ipcEnabled")
        try container.encode(developerModeEnabled, forKey: "developerModeEnabled")
        try container.encodeUnknownFields(unknownFields)
    }
}

extension CanonicalTOMLConfig.Focus {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().focus
        followsMouse = try container.decodeWithDefault(Bool.self, forKey: .followsMouse, default: d.followsMouse)
        moveMouseToFocusedWindow = try container.decodeWithDefault(Bool.self, forKey: .moveMouseToFocusedWindow, default: d.moveMouseToFocusedWindow)
        followsWindowToMonitor = try container.decodeWithDefault(Bool.self, forKey: .followsWindowToMonitor, default: d.followsWindowToMonitor)
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(followsMouse, forKey: "followsMouse")
        try container.encode(moveMouseToFocusedWindow, forKey: "moveMouseToFocusedWindow")
        try container.encode(followsWindowToMonitor, forKey: "followsWindowToMonitor")
        try container.encodeUnknownFields(unknownFields)
    }
}

extension CanonicalTOMLConfig.MouseWarp {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().mouseWarp
        monitorOrder = try container.decodeWithDefault([String].self, forKey: .monitorOrder, default: d.monitorOrder)
        axis = try container.decodeIfPresent(String.self, forKey: .axis)
        margin = try container.decodeWithDefault(Int.self, forKey: .margin, default: d.margin)
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(monitorOrder, forKey: "monitorOrder")
        try container.encodeIfPresent(axis, forKey: "axis")
        try container.encode(margin, forKey: "margin")
        try container.encodeUnknownFields(unknownFields)
    }
}

extension CanonicalTOMLConfig.Gaps {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().gaps
        size = try container.decodeWithDefault(Double.self, forKey: .size, default: d.size)
        outer = try container.decodeWithDefault(Outer.self, forKey: .outer, default: d.outer)
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(size, forKey: "size")
        try container.encode(outer, forKey: "outer")
        try container.encodeUnknownFields(unknownFields)
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
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(left, forKey: "left")
        try container.encode(right, forKey: "right")
        try container.encode(top, forKey: "top")
        try container.encode(bottom, forKey: "bottom")
        try container.encodeUnknownFields(unknownFields)
    }
}

extension CanonicalTOMLConfig.Niri {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().niri
        balancedColumnCount = try container.decodeWithDefault(Int.self, forKey: .balancedColumnCount, default: d.balancedColumnCount)
        infiniteLoop = try container.decodeWithDefault(Bool.self, forKey: .infiniteLoop, default: d.infiniteLoop)
        revealPartial = try container.decodeWithDefault(String.self, forKey: .revealPartial, default: d.revealPartial)
        loneWindowMaxWidth = try container.decodeIfPresent(Double.self, forKey: .loneWindowMaxWidth)
        columnWidthPresets = try container.decodeIfPresent([Double].self, forKey: .columnWidthPresets)
        defaultColumnWidth = try container.decodeIfPresent(Double.self, forKey: .defaultColumnWidth)
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(balancedColumnCount, forKey: "balancedColumnCount")
        try container.encode(infiniteLoop, forKey: "infiniteLoop")
        try container.encode(revealPartial, forKey: "revealPartial")
        try container.encodeIfPresent(loneWindowMaxWidth, forKey: "loneWindowMaxWidth")
        try container.encodeIfPresent(columnWidthPresets, forKey: "columnWidthPresets")
        try container.encodeIfPresent(defaultColumnWidth, forKey: "defaultColumnWidth")
        try container.encodeUnknownFields(unknownFields)
    }
}

extension CanonicalTOMLConfig.Borders {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().borders
        enabled = try container.decodeWithDefault(Bool.self, forKey: .enabled, default: d.enabled)
        width = try container.decodeWithDefault(Double.self, forKey: .width, default: d.width)
        color = try container.decodeWithDefault(Color.self, forKey: .color, default: d.color)
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(enabled, forKey: "enabled")
        try container.encode(width, forKey: "width")
        try container.encode(color, forKey: "color")
        try container.encodeUnknownFields(unknownFields)
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
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(red, forKey: "red")
        try container.encode(green, forKey: "green")
        try container.encode(blue, forKey: "blue")
        try container.encode(alpha, forKey: "alpha")
        try container.encodeUnknownFields(unknownFields)
    }
}

extension CanonicalTOMLConfig.WorkspaceBar {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().workspaceBar
        enabled = try container.decodeWithDefault(Bool.self, forKey: .enabled, default: d.enabled)
        showLabels = try container.decodeWithDefault(Bool.self, forKey: .showLabels, default: d.showLabels)
        showFloatingWindows = try container.decodeWithDefault(Bool.self, forKey: .showFloatingWindows, default: d.showFloatingWindows)
        showTraceButton = try container.decodeWithDefault(Bool.self, forKey: .showTraceButton, default: d.showTraceButton)
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
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(enabled, forKey: "enabled")
        try container.encode(showLabels, forKey: "showLabels")
        try container.encode(showFloatingWindows, forKey: "showFloatingWindows")
        try container.encode(showTraceButton, forKey: "showTraceButton")
        try container.encode(windowLevel, forKey: "windowLevel")
        try container.encode(position, forKey: "position")
        try container.encode(notchAware, forKey: "notchAware")
        try container.encode(deduplicateAppIcons, forKey: "deduplicateAppIcons")
        try container.encode(hideEmptyWorkspaces, forKey: "hideEmptyWorkspaces")
        try container.encode(reserveLayoutSpace, forKey: "reserveLayoutSpace")
        try container.encode(height, forKey: "height")
        try container.encode(backgroundOpacity, forKey: "backgroundOpacity")
        try container.encode(xOffset, forKey: "xOffset")
        try container.encode(yOffset, forKey: "yOffset")
        try container.encode(labelFontSize, forKey: "labelFontSize")
        try container.encodeIfPresent(accentColor, forKey: "accentColor")
        try container.encodeIfPresent(textColor, forKey: "textColor")
        try container.encodeUnknownFields(unknownFields)
    }
}

extension CanonicalTOMLConfig.WorkspaceBar.Color {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().workspaceBar.accentColor ?? CanonicalTOMLConfig.WorkspaceBar.Color(red: 0, green: 0, blue: 0, alpha: 1)
        red = try container.decodeWithDefault(Double.self, forKey: .red, default: d.red)
        green = try container.decodeWithDefault(Double.self, forKey: .green, default: d.green)
        blue = try container.decodeWithDefault(Double.self, forKey: .blue, default: d.blue)
        alpha = try container.decodeWithDefault(Double.self, forKey: .alpha, default: d.alpha)
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(red, forKey: "red")
        try container.encode(green, forKey: "green")
        try container.encode(blue, forKey: "blue")
        try container.encode(alpha, forKey: "alpha")
        try container.encodeUnknownFields(unknownFields)
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
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(scrollEnabled, forKey: "scrollEnabled")
        try container.encode(scrollSensitivity, forKey: "scrollSensitivity")
        try container.encode(scrollModifierKey, forKey: "scrollModifierKey")
        try container.encode(mouseResizeModifierKey, forKey: "mouseResizeModifierKey")
        try container.encode(fingerCount, forKey: "fingerCount")
        try container.encode(invertDirection, forKey: "invertDirection")
        try container.encodeUnknownFields(unknownFields)
    }
}

extension CanonicalTOMLConfig.StatusBar {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().statusBar
        showWorkspaceName = try container.decodeWithDefault(Bool.self, forKey: .showWorkspaceName, default: d.showWorkspaceName)
        showAppNames = try container.decodeWithDefault(Bool.self, forKey: .showAppNames, default: d.showAppNames)
        useWorkspaceId = try container.decodeWithDefault(Bool.self, forKey: .useWorkspaceId, default: d.useWorkspaceId)
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(showWorkspaceName, forKey: "showWorkspaceName")
        try container.encode(showAppNames, forKey: "showAppNames")
        try container.encode(useWorkspaceId, forKey: "useWorkspaceId")
        try container.encodeUnknownFields(unknownFields)
    }
}

extension CanonicalTOMLConfig.Appearance {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanonicalTOMLConfig.defaults().appearance
        mode = try container.decodeWithDefault(String.self, forKey: .mode, default: d.mode)
        unknownFields = try SettingsTOMLUnknownValue.decodeUnknownFields(from: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        try container.encode(mode, forKey: "mode")
        try container.encodeUnknownFields(unknownFields)
    }
}
