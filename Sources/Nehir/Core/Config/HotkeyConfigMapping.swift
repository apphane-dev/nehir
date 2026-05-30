import Carbon
import Foundation

/// Maps between internal hotkey binding IDs (e.g., "switchWorkspace.0") and
/// the new human-readable TOML config keys (e.g., workspace.switch.1).
enum HotkeyConfigMapping {
    /// TOML section names in output order.
    static let sectionOrder: [String] = ["workspace", "focus", "move", "layout", "ui"]

    /// Numbered group definitions: each group expands to 9 bindings (1–9).
    /// The internalIdPattern uses `%d` for the index, with the specified offset.
    struct NumberedGroup {
        let section: String
        let key: String
        let internalIdPattern: String  // e.g., "switchWorkspace.%d"
        let indexOffset: Int           // offset from 1-based config to internal (0 or 0)
    }

    static let numberedGroups: [NumberedGroup] = [
        NumberedGroup(section: "workspace", key: "switch", internalIdPattern: "switchWorkspace.%d", indexOffset: -1),
        NumberedGroup(section: "workspace", key: "moveTo", internalIdPattern: "moveToWorkspace.%d", indexOffset: -1),
        NumberedGroup(section: "workspace", key: "moveColumnTo", internalIdPattern: "moveColumnToWorkspace.%d", indexOffset: -1),
        NumberedGroup(section: "focus", key: "column", internalIdPattern: "focusColumn.%d", indexOffset: -1),
        NumberedGroup(section: "focus", key: "windowInColumn", internalIdPattern: "focusWindowInColumn.%d", indexOffset: 0),
        NumberedGroup(section: "move", key: "columnToIndex", internalIdPattern: "moveColumnToIndex.%d", indexOffset: 0),
    ]

    /// Non-numbered singleton mappings: section.key → internalId
    static let singletons: [(section: String, key: String, internalId: String)] = [
        // workspace
        ("workspace", "backAndForth", "workspaceBackAndForth"),
        ("workspace", "next", "switchWorkspace.next"),
        ("workspace", "previous", "switchWorkspace.previous"),
        // focus
        ("focus", "left", "focus.left"),
        ("focus", "down", "focus.down"),
        ("focus", "up", "focus.up"),
        ("focus", "right", "focus.right"),
        ("focus", "previous", "focusPrevious"),
        ("focus", "downOrLeft", "focusDownOrLeft"),
        ("focus", "upOrRight", "focusUpOrRight"),
        ("focus", "windowTop", "focusWindowTop"),
        ("focus", "windowBottom", "focusWindowBottom"),
        ("focus", "windowDownOrTop", "focusWindowDownOrTop"),
        ("focus", "windowUpOrBottom", "focusWindowUpOrBottom"),
        ("focus", "windowOrWorkspaceDown", "focusWindowOrWorkspaceDown"),
        ("focus", "windowOrWorkspaceUp", "focusWindowOrWorkspaceUp"),
        ("focus", "columnFirst", "focusColumnFirst"),
        ("focus", "columnLast", "focusColumnLast"),
        ("focus", "monitorNext", "focusMonitorNext"),
        ("focus", "monitorPrevious", "focusMonitorPrevious"),
        ("focus", "monitorLast", "focusMonitorLast"),
        // move
        ("move", "left", "move.left"),
        ("move", "down", "move.down"),
        ("move", "up", "move.up"),
        ("move", "right", "move.right"),
        ("move", "windowDown", "moveWindowDown"),
        ("move", "windowUp", "moveWindowUp"),
        ("move", "windowDownOrToWorkspaceDown", "moveWindowDownOrToWorkspaceDown"),
        ("move", "windowUpOrToWorkspaceUp", "moveWindowUpOrToWorkspaceUp"),
        ("move", "windowToWorkspaceUp", "moveWindowToWorkspaceUp"),
        ("move", "windowToWorkspaceDown", "moveWindowToWorkspaceDown"),
        ("move", "columnToWorkspaceUp", "moveColumnToWorkspaceUp"),
        ("move", "columnToWorkspaceDown", "moveColumnToWorkspaceDown"),
        ("move", "columnLeft", "moveColumn.left"),
        ("move", "columnRight", "moveColumn.right"),
        ("move", "columnToFirst", "moveColumnToFirst"),
        ("move", "columnToLast", "moveColumnToLast"),
        ("move", "consumeOrExpelLeft", "consumeOrExpelWindowLeft"),
        ("move", "consumeOrExpelRight", "consumeOrExpelWindowRight"),
        ("move", "consumeIntoColumn", "consumeWindowIntoColumn"),
        ("move", "expelFromColumn", "expelWindowFromColumn"),
        // layout
        ("layout", "toggleFullscreen", "toggleFullscreen"),
        ("layout", "toggleNativeFullscreen", "toggleNativeFullscreen"),
        ("layout", "toggleColumnTabbed", "toggleColumnTabbed"),
        ("layout", "toggleColumnFullWidth", "toggleColumnFullWidth"),
        ("layout", "expandColumnToAvailable", "expandColumnToAvailableWidth"),
        ("layout", "cycleColumnWidthForward", "cycleColumnWidthForward"),
        ("layout", "cycleColumnWidthBackward", "cycleColumnWidthBackward"),
        ("layout", "cycleWindowWidthForward", "cycleWindowWidthForward"),
        ("layout", "cycleWindowWidthBackward", "cycleWindowWidthBackward"),
        ("layout", "cycleWindowHeightForward", "cycleWindowHeightForward"),
        ("layout", "cycleWindowHeightBackward", "cycleWindowHeightBackward"),
        ("layout", "decreaseColumnWidth", "setColumnWidth.decrease10Percent"),
        ("layout", "increaseColumnWidth", "setColumnWidth.increase10Percent"),
        ("layout", "decreaseWindowWidth", "setWindowWidth.decrease10Percent"),
        ("layout", "increaseWindowWidth", "setWindowWidth.increase10Percent"),
        ("layout", "decreaseWindowHeight", "setWindowHeight.decrease10Percent"),
        ("layout", "increaseWindowHeight", "setWindowHeight.increase10Percent"),
        ("layout", "resetWindowHeight", "resetWindowHeight"),
        ("layout", "balanceSizes", "balanceSizes"),
        ("layout", "centerColumn", "centerColumn"),
        ("layout", "centerVisibleColumns", "centerVisibleColumns"),
        ("layout", "toggleFocusedFloating", "toggleFocusedWindowFloating"),
        ("layout", "assignScratchpad", "assignFocusedWindowToScratchpad"),
        ("layout", "toggleScratchpad", "toggleScratchpadWindow"),
        ("layout", "raiseAllFloating", "raiseAllFloatingWindows"),
        ("layout", "rescueOffscreen", "rescueOffscreenWindows"),
        // ui
        ("ui", "commandPalette", "openCommandPalette"),
        ("ui", "menuAnywhere", "openMenuAnywhere"),
        ("ui", "toggleOverview", "toggleOverview"),
        ("ui", "toggleWorkspaceBar", "toggleWorkspaceBarVisibility"),
    ]

    // MARK: - Lookup caches

    private static let configKeyToInternalId: [String: String] = {
        var map: [String: String] = [:]
        for s in singletons {
            map["\(s.section).\(s.key)"] = s.internalId
        }
        for g in numberedGroups {
            for n in 1...9 {
                let configKey = "\(g.section).\(g.key).\(n)"
                let internalIdx = n + g.indexOffset
                let internalId = String(format: g.internalIdPattern, internalIdx)
                map[configKey] = internalId
            }
        }
        return map
    }()

    private static let internalIdToConfigKey: [String: String] = {
        var map: [String: String] = [:]
        for (k, v) in configKeyToInternalId {
            map[v] = k
        }
        return map
    }()

    static func internalId(forConfigKey configKey: String) -> String? {
        configKeyToInternalId[configKey]
    }

    static func configKey(forInternalId id: String) -> String? {
        internalIdToConfigKey[id]
    }

    /// Returns the section name for a given internal binding ID.
    static func section(forInternalId id: String) -> String? {
        guard let configKey = configKey(forInternalId: id) else { return nil }
        return String(configKey.prefix(while: { $0 != "." }))
    }

    /// Digit key codes for keys 1-9 on the keyboard.
    static let digitKeyCodes: [UInt32] = {
        [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
        ]
    }()
}
