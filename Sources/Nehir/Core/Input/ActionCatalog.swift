// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Carbon
import NehirIPC

enum FeatureStability {
    case stable
    case experimental
}

struct ActionSpec: Equatable {
    let id: String
    let command: HotkeyCommand
    let title: String
    let keywords: [String]
    let category: HotkeyCategory
    let defaultBinding: KeyBinding
    let ipcCommandName: IPCCommandName?
    let stability: FeatureStability
    let requiresDeveloperMode: Bool

    init(
        id: String,
        command: HotkeyCommand,
        title: String,
        keywords: [String] = [],
        category: HotkeyCategory,
        defaultBinding: KeyBinding,
        ipcCommandName: IPCCommandName? = nil,
        stability: FeatureStability = .stable,
        requiresDeveloperMode: Bool = false
    ) {
        self.id = id
        self.command = command
        self.title = title
        self.keywords = keywords
        self.category = category
        self.defaultBinding = defaultBinding
        self.ipcCommandName = ipcCommandName
        self.stability = stability
        self.requiresDeveloperMode = requiresDeveloperMode
    }

    var ipcDescriptor: IPCCommandDescriptor? {
        ipcCommandName.flatMap(IPCAutomationManifest.commandDescriptor(for:))
    }

    var ipcDescriptors: [IPCCommandDescriptor] {
        ipcCommandName.map(IPCAutomationManifest.commandDescriptors(for:)) ?? []
    }

    var searchTerms: [String] {
        ActionCatalog.uniqueTerms(
            [title, id]
                + keywords
                + ipcDescriptors.flatMap { [$0.path] + $0.commandWords }
        )
    }
}

enum ActionCatalog {
    private static let digitCodes: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
    ]

    private static let specs: [ActionSpec] = buildSpecs()
    private static let specsByID = Dictionary(
        uniqueKeysWithValues: specs.map { ($0.id, $0) }
    )

    static func allSpecs() -> [ActionSpec] {
        specs
    }

    static func spec(for id: String) -> ActionSpec? {
        specsByID[id]
    }

    static func spec(for command: HotkeyCommand) -> ActionSpec? {
        specs.first { $0.command == command }
    }

    static func title(for command: HotkeyCommand) -> String? {
        spec(for: command)?.title
    }

    static func category(for id: String) -> HotkeyCategory? {
        spec(for: id)?.category
    }

    static func defaultHotkeyBindings() -> [HotkeyBinding] {
        specs.map { spec in
            HotkeyBinding(
                id: spec.id,
                command: spec.command,
                binding: spec.defaultBinding
            )
        }
    }

    static func matchesSearch(_ query: String, binding: HotkeyBinding) -> Bool {
        let normalizedQuery = normalizedSearchTerm(query)
        guard !normalizedQuery.isEmpty else { return true }

        guard let spec = spec(for: binding.id) else {
            return binding.command.displayName.localizedCaseInsensitiveContains(query)
                || binding.binding.displayString.localizedCaseInsensitiveContains(query)
                || binding.binding.humanReadableString.localizedCaseInsensitiveContains(query)
        }

        return spec.searchTerms.contains { normalizedSearchTerm($0).contains(normalizedQuery) }
            || normalizedSearchTerm(binding.binding.displayString).contains(normalizedQuery)
            || normalizedSearchTerm(binding.binding.humanReadableString).contains(normalizedQuery)
    }

    static func uniqueTerms(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { raw in
            let normalized = normalizedSearchTerm(raw)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return raw
        }
    }

    static func normalizedSearchTerm(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildSpecs() -> [ActionSpec] {
        var specs: [ActionSpec] = []

        for (idx, code) in digitCodes.enumerated() {
            specs.append(
                action(
                    id: "switchWorkspace.\(idx)",
                    command: .switchWorkspace(idx),
                    category: .workspace,
                    binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | cmdKey))
                )
            )
            specs.append(
                action(
                    id: "moveToWorkspace.\(idx)",
                    command: .moveToWorkspace(idx),
                    category: .workspace,
                    binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | shiftKey))
                )
            )
        }

        specs.append(
            action(
                id: "workspaceBackAndForth",
                command: .workspaceBackAndForth,
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | controlKey)),
                keywords: ["back and forth", "previous workspace"]
            )
        )

        specs.append(contentsOf: [
            action(
                id: "switchWorkspace.next",
                command: .switchWorkspaceNext,
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey | optionKey | cmdKey))
            ),
            action(
                id: "switchWorkspace.previous",
                command: .switchWorkspacePrevious,
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey | cmdKey))
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "focus.left",
                command: .focus(.left),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focus.down",
                command: .focus(.down),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focus.up",
                command: .focus(.up),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focus.right",
                command: .focus(.right),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey))
            )
        ])

        specs.append(
            action(
                id: "focusPrevious",
                command: .focusPrevious,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey)),
                keywords: ["last focused", "recent window"]
            )
        )

        specs.append(contentsOf: [
            action(
                id: "focusDownOrLeft",
                command: .focusDownOrLeft,
                category: .focus,
                binding: .unassigned
            ),
            action(
                id: "focusUpOrRight",
                command: .focusUpOrRight,
                category: .focus,
                binding: .unassigned
            ),
            action(
                id: "focusWindowTop",
                command: .focusWindowTop,
                category: .focus,
                binding: .unassigned
            ),
            action(
                id: "focusWindowBottom",
                command: .focusWindowBottom,
                category: .focus,
                binding: .unassigned
            ),
            action(
                id: "focusWindowDownOrTop",
                command: .focusWindowDownOrTop,
                category: .focus,
                binding: .unassigned
            ),
            action(
                id: "focusWindowUpOrBottom",
                command: .focusWindowUpOrBottom,
                category: .focus,
                binding: .unassigned
            ),
            action(
                id: "focusWindowOrWorkspaceDown",
                command: .focusWindowOrWorkspaceDown,
                category: .focus,
                binding: .unassigned
            ),
            action(
                id: "focusWindowOrWorkspaceUp",
                command: .focusWindowOrWorkspaceUp,
                category: .focus,
                binding: .unassigned
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "scrollViewport.left",
                command: .scrollViewportLeft,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: UInt32(optionKey | cmdKey)),
                keywords: ["viewport left", "snap left"]
            ),
            action(
                id: "scrollViewport.right",
                command: .scrollViewportRight,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: UInt32(optionKey | cmdKey)),
                keywords: ["viewport right", "snap right"]
            ),
            action(
                id: "toggleViewportScrollLock",
                command: .toggleViewportScrollLock,
                category: .layout,
                binding: .unassigned,
                keywords: ["lock", "pin", "freeze viewport"]
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "moveWindowToWorkspaceUp",
                command: .moveWindowToWorkspaceUp,
                category: .workspace,
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: KeySymbolMapper.realHyperModifiers)
            ),
            action(
                id: "moveWindowToWorkspaceDown",
                command: .moveWindowToWorkspaceDown,
                category: .workspace,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_DownArrow),
                    modifiers: KeySymbolMapper.realHyperModifiers
                )
            ),
            action(
                id: "moveColumnToWorkspaceUp",
                command: .moveColumnToWorkspaceUp,
                category: .workspace,
                binding: .unassigned
            ),
            action(
                id: "moveColumnToWorkspaceDown",
                command: .moveColumnToWorkspaceDown,
                category: .workspace,
                binding: .unassigned
            )
        ])

        for idx in 0 ..< 9 {
            specs.append(
                action(
                    id: "moveColumnToWorkspace.\(idx)",
                    command: .moveColumnToWorkspace(idx),
                    category: .workspace,
                    binding: .unassigned
                )
            )
        }

        for direction in [Direction.left, .right, .up, .down] {
            specs.append(
                action(
                    id: "swapWorkspaceWithMonitor.\(direction.rawValue)",
                    command: .swapWorkspaceWithMonitor(direction),
                    category: .workspace,
                    binding: .unassigned
                )
            )
        }

        for idx in 0 ..< 9 {
            specs.append(
                action(
                    id: "focusWorkspaceAnywhere.\(idx)",
                    command: .focusWorkspaceAnywhere(idx),
                    category: .workspace,
                    binding: .unassigned
                )
            )
        }

        for idx in 0 ..< 9 {
            for direction in [Direction.left, .right, .up, .down] {
                specs.append(
                    action(
                        id: "moveWindowToWorkspaceOnMonitor.\(idx).\(direction.rawValue)",
                        command: .moveWindowToWorkspaceOnMonitor(workspaceIndex: idx, monitorDirection: direction),
                        category: .workspace,
                        binding: .unassigned
                    )
                )
            }
        }

        specs.append(contentsOf: [
            action(
                id: "move.left",
                command: .move(.left),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(
                id: "move.down",
                command: .move(.down),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(
                id: "move.up",
                command: .move(.up),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(
                id: "move.right",
                command: .move(.right),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey | shiftKey))
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "moveWindowDown",
                command: .moveWindowDown,
                category: .move,
                binding: .unassigned
            ),
            action(
                id: "moveWindowUp",
                command: .moveWindowUp,
                category: .move,
                binding: .unassigned
            ),
            action(
                id: "moveWindowDownOrToWorkspaceDown",
                command: .moveWindowDownOrToWorkspaceDown,
                category: .move,
                binding: .unassigned
            ),
            action(
                id: "moveWindowUpOrToWorkspaceUp",
                command: .moveWindowUpOrToWorkspaceUp,
                category: .move,
                binding: .unassigned
            ),
            action(
                id: "consumeOrExpelWindowLeft",
                command: .consumeOrExpelWindowLeft,
                category: .move,
                binding: .unassigned
            ),
            action(
                id: "consumeOrExpelWindowRight",
                command: .consumeOrExpelWindowRight,
                category: .move,
                binding: .unassigned
            ),
            action(
                id: "consumeWindowIntoColumn",
                command: .consumeWindowIntoColumn,
                category: .move,
                binding: .unassigned
            ),
            action(
                id: "expelWindowFromColumn",
                command: .expelWindowFromColumn,
                category: .move,
                binding: .unassigned
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "focusMonitorNext",
                command: .focusMonitorNext,
                category: .monitor,
                binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey | cmdKey))
            ),
            action(
                id: "focusMonitorPrevious",
                command: .focusMonitorPrevious,
                category: .monitor,
                binding: .unassigned
            ),
            action(
                id: "focusMonitorLast",
                command: .focusMonitorLast,
                category: .monitor,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey | cmdKey))
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "toggleFullscreen",
                command: .toggleFullscreen,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey))
            ),
            action(
                id: "toggleNativeFullscreen",
                command: .toggleNativeFullscreen,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey | shiftKey | cmdKey))
            ),
            action(
                id: "moveColumn.left",
                command: .moveColumn(.left),
                category: .column,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_LeftArrow),
                    modifiers: KeySymbolMapper.realHyperModifiers
                )
            ),
            action(
                id: "moveColumn.right",
                command: .moveColumn(.right),
                category: .column,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_RightArrow),
                    modifiers: KeySymbolMapper.realHyperModifiers
                )
            ),
            action(
                id: "moveColumnToFirst",
                command: .moveColumnToFirst,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_Home), modifiers: UInt32(optionKey | controlKey))
            ),
            action(
                id: "moveColumnToLast",
                command: .moveColumnToLast,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_End), modifiers: UInt32(optionKey | controlKey))
            ),
            action(
                id: "toggleColumnTabbed",
                command: .toggleColumnTabbed,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | shiftKey | cmdKey))
            ),
            action(
                id: "focusColumnFirst",
                command: .focusColumnFirst,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_Home), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focusColumnLast",
                command: .focusColumnLast,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_End), modifiers: UInt32(optionKey))
            )
        ])

        for (idx, code) in digitCodes.enumerated() {
            specs.append(
                action(
                    id: "focusColumn.\(idx)",
                    command: .focusColumn(idx),
                    category: .focus,
                    binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | controlKey))
                )
            )
        }

        for idx in 1 ... 9 {
            specs.append(
                action(
                    id: "focusWindowInColumn.\(idx)",
                    command: .focusWindowInColumn(idx),
                    category: .focus,
                    binding: .unassigned
                )
            )
        }

        for idx in 1 ... 9 {
            specs.append(
                action(
                    id: "moveColumnToIndex.\(idx)",
                    command: .moveColumnToIndex(idx),
                    category: .column,
                    binding: .unassigned
                )
            )
        }

        specs.append(contentsOf: [
            action(
                id: "cycleColumnWidthForward",
                command: .cycleColumnWidthForward,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(optionKey))
            ),
            action(
                id: "cycleColumnWidthBackward",
                command: .cycleColumnWidthBackward,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(optionKey))
            ),
            action(
                id: "cycleWindowWidthForward",
                command: .cycleWindowWidthForward,
                category: .column,
                binding: .unassigned
            ),
            action(
                id: "cycleWindowWidthBackward",
                command: .cycleWindowWidthBackward,
                category: .column,
                binding: .unassigned
            ),
            action(
                id: "cycleWindowHeightForward",
                command: .cycleWindowHeightForward,
                category: .column,
                binding: .unassigned
            ),
            action(
                id: "cycleWindowHeightBackward",
                command: .cycleWindowHeightBackward,
                category: .column,
                binding: .unassigned
            ),
            action(
                id: "toggleColumnFullWidth",
                command: .toggleColumnFullWidth,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(
                id: "expandColumnToAvailableWidth",
                command: .expandColumnToAvailableWidth,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | controlKey))
            ),
            action(
                id: "resetWindowHeight",
                command: .resetWindowHeight,
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | controlKey))
            ),
            action(
                id: "setColumnWidth.decrease10Percent",
                command: .setColumnWidth(.adjustProportion(-10)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey)),
                keywords: ["shrink column", "resize column"]
            ),
            action(
                id: "setColumnWidth.increase10Percent",
                command: .setColumnWidth(.adjustProportion(10)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey)),
                keywords: ["grow column", "resize column"]
            ),
            action(
                id: "setWindowWidth.decrease10Percent",
                command: .setWindowWidth(.adjustProportion(-10)),
                category: .column,
                binding: .unassigned,
                keywords: ["shrink window", "resize window"]
            ),
            action(
                id: "setWindowWidth.increase10Percent",
                command: .setWindowWidth(.adjustProportion(10)),
                category: .column,
                binding: .unassigned,
                keywords: ["grow window", "resize window"]
            ),
            action(
                id: "setWindowHeight.decrease10Percent",
                command: .setWindowHeight(.adjustProportion(-10)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["shorter window", "resize window"]
            ),
            action(
                id: "setWindowHeight.increase10Percent",
                command: .setWindowHeight(.adjustProportion(10)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["taller window", "resize window"]
            ),
            action(
                id: "balanceSizes",
                command: .balanceSizes,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | shiftKey))
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "openCommandPalette",
                command: .openCommandPalette,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | cmdKey)),
                keywords: ["palette", "search", "commands", "menu"]
            ),
            action(
                id: "raiseAllFloatingWindows",
                command: .raiseAllFloatingWindows,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["float", "floating", "raise"]
            ),
            action(
                id: "rescueOffscreenWindows",
                command: .rescueOffscreenWindows,
                category: .layout,
                binding: .unassigned,
                keywords: ["rescue", "offscreen", "off-screen"]
            ),
            action(
                id: "toggleFocusedWindowFloating",
                command: .toggleFocusedWindowFloating,
                category: .layout,
                binding: .unassigned,
                keywords: ["float", "floating"]
            ),
            action(
                id: "toggleFocusedWindowSticky",
                command: .toggleFocusedWindowSticky,
                category: .layout,
                binding: .unassigned,
                keywords: ["sticky", "pin", "all workspaces", "picture in picture", "pip"]
            ),
            action(
                id: "assignFocusedWindowToScratchpad",
                command: .assignFocusedWindowToScratchpad,
                category: .layout,
                binding: .unassigned,
                keywords: ["scratchpad"]
            ),
            action(
                id: "toggleScratchpadWindow",
                command: .toggleScratchpadWindow,
                category: .layout,
                binding: .unassigned,
                keywords: ["scratchpad"]
            ),
            action(
                id: "openMenuAnywhere",
                command: .openMenuAnywhere,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(optionKey | cmdKey)),
                keywords: ["menu", "anywhere"]
            ),
            action(
                id: "openSettings",
                command: .openSettings,
                category: .focus,
                binding: .unassigned,
                keywords: ["settings", "preferences", "configure", "config"]
            ),
            action(
                id: "createAppRuleForFocusedWindow",
                command: .createAppRuleForFocusedWindow,
                category: .focus,
                binding: .unassigned,
                keywords: ["app rule", "rule", "bundle", "focused window", "create rule"]
            ),
            action(
                id: "debug.dumpRuntimeState",
                command: .debugDumpRuntimeState,
                category: .debugging,
                binding: .unassigned,
                keywords: ["debug", "runtime", "state", "dump", "clipboard", "trace"],
                requiresDeveloperMode: true
            ),
            action(
                id: "debug.resetRuntimeState",
                command: .debugResetRuntimeState,
                category: .debugging,
                binding: .unassigned,
                keywords: ["debug", "runtime", "state", "reset", "clear", "rebuild"],
                requiresDeveloperMode: true
            ),
            action(
                id: "debug.restartClearingRuntimeState",
                command: .debugRestartClearingRuntimeState,
                category: .debugging,
                binding: .unassigned,
                keywords: ["debug", "restart", "relaunch", "runtime", "state", "clear", "reset"],
                requiresDeveloperMode: true
            ),
            action(
                id: "debug.toggleTraceCapture",
                command: .debugToggleTraceCapture,
                category: .debugging,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey | cmdKey)),
                keywords: ["debug", "trace", "tracing", "capture", "runtime", "events", "toggle", "start", "stop"],
                requiresDeveloperMode: true
            ),
            action(
                id: "toggleWorkspaceBarVisibility",
                command: .toggleWorkspaceBarVisibility,
                category: .focus,
                binding: .unassigned,
                keywords: ["workspace bar", "bar"]
            ),
            action(
                id: "toggleOverview",
                command: .toggleOverview,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(optionKey | cmdKey)),
                keywords: ["overview"]
            )
        ])

        specs.append(contentsOf: [
            action(
                id: "toggleFocusFollowsMouse",
                command: .toggleFocusFollowsMouse,
                category: .focus,
                binding: .unassigned,
                keywords: ["focus follows mouse", "hover focus"],
                stability: .experimental
            ),
            action(
                id: "toggleFocusFollowsWindowToMonitor",
                command: .toggleFocusFollowsWindowToMonitor,
                category: .focus,
                binding: .unassigned,
                keywords: ["follow window", "window to monitor"]
            ),
            action(
                id: "toggleMoveMouseToFocused",
                command: .toggleMoveMouseToFocused,
                category: .focus,
                binding: .unassigned,
                keywords: ["move mouse", "warp cursor", "mouse to focused"]
            ),
            action(
                id: "toggleBordersEnabled",
                command: .toggleBordersEnabled,
                category: .layout,
                binding: .unassigned,
                keywords: ["borders", "window border"],
                stability: .experimental
            ),
            action(
                id: "togglePreventSleepEnabled",
                command: .togglePreventSleepEnabled,
                category: .layout,
                binding: .unassigned,
                keywords: ["keep awake", "prevent sleep", "display sleep"]
            ),
            action(
                id: "toggleIPCEnabled",
                command: .toggleIPCEnabled,
                category: .layout,
                binding: .unassigned,
                keywords: ["ipc", "cli", "socket"]
            )
        ])

        return specs
    }

    private static func action(
        id: String,
        command: HotkeyCommand,
        category: HotkeyCategory,
        binding: KeyBinding,
        keywords: [String] = [],
        stability: FeatureStability = .stable,
        requiresDeveloperMode: Bool = false
    ) -> ActionSpec {
        let title = displayName(for: command)
        return ActionSpec(
            id: id,
            command: command,
            title: title,
            keywords: uniqueTerms(keywords + [title, id]),
            category: category,
            defaultBinding: defaultBinding(for: binding),
            ipcCommandName: ipcCommandName(for: command),
            stability: stability,
            requiresDeveloperMode: requiresDeveloperMode
        )
    }

    private static func defaultBinding(for binding: KeyBinding) -> KeyBinding {
        guard !binding.isUnassigned else { return binding }
        if binding.modifiers == KeySymbolMapper.realHyperModifiers {
            return binding
        }
        guard binding.modifiers & UInt32(optionKey) != 0,
              binding.modifiers & UInt32(cmdKey) == 0
        else {
            return binding
        }
        return KeyBinding(
            keyCode: binding.keyCode,
            modifiers: binding.modifiers | UInt32(cmdKey)
        )
    }

    private static func displayName(for command: HotkeyCommand) -> String {
        switch command {
        case let .focus(dir): "Focus \(dir.displayName)"
        case .focusPrevious: "Focus Previous Window"
        case let .move(dir): "Move \(dir.displayName)"
        case let .moveToWorkspace(idx): "Move to Workspace \(idx + 1)"
        case .moveWindowToWorkspaceUp: "Move Window to Workspace Up"
        case .moveWindowToWorkspaceDown: "Move Window to Workspace Down"
        case let .moveColumnToWorkspace(idx): "Move Column to Workspace \(idx + 1)"
        case .moveColumnToWorkspaceUp: "Move Column to Workspace Up"
        case .moveColumnToWorkspaceDown: "Move Column to Workspace Down"
        case let .switchWorkspace(idx): "Switch to Workspace \(idx + 1)"
        case .switchWorkspaceNext: "Switch to Next Workspace"
        case .switchWorkspacePrevious: "Switch to Previous Workspace"
        case .focusMonitorPrevious: "Focus Previous Monitor"
        case .focusMonitorNext: "Focus Next Monitor"
        case .focusMonitorLast: "Focus Last Monitor"
        case .toggleFullscreen: "Toggle Fullscreen"
        case .toggleNativeFullscreen: "Toggle Native Fullscreen"
        case let .moveColumn(dir): "Move Column \(dir.displayName)"
        case .moveColumnToFirst: "Move Column to First"
        case .moveColumnToLast: "Move Column to Last"
        case let .moveColumnToIndex(idx): "Move Column to Index \(idx)"
        case .moveWindowDown: "Move Window Down"
        case .moveWindowUp: "Move Window Up"
        case .moveWindowDownOrToWorkspaceDown: "Move Window Down or to Workspace Down"
        case .moveWindowUpOrToWorkspaceUp: "Move Window Up or to Workspace Up"
        case .consumeOrExpelWindowLeft: "Consume or Expel Window Left"
        case .consumeOrExpelWindowRight: "Consume or Expel Window Right"
        case .consumeWindowIntoColumn: "Consume Window into Column"
        case .expelWindowFromColumn: "Expel Window from Column"
        case .toggleColumnTabbed: "Toggle Column Tabbed"
        case .focusDownOrLeft: "Traverse Backward"
        case .focusUpOrRight: "Traverse Forward"
        case let .focusWindowInColumn(idx): "Focus Window \(idx) in Column"
        case .focusWindowTop: "Focus Top Window"
        case .focusWindowBottom: "Focus Bottom Window"
        case .focusWindowDownOrTop: "Focus Down or Top"
        case .focusWindowUpOrBottom: "Focus Up or Bottom"
        case .focusWindowOrWorkspaceDown: "Focus Window or Workspace Down"
        case .focusWindowOrWorkspaceUp: "Focus Window or Workspace Up"
        case .focusColumnFirst: "Focus First Column"
        case .focusColumnLast: "Focus Last Column"
        case let .focusColumn(idx): "Focus Column \(idx + 1)"
        case .scrollViewportLeft: "Scroll Viewport Left"
        case .scrollViewportRight: "Scroll Viewport Right"
        case .toggleViewportScrollLock: "Toggle Viewport Scroll Lock"
        case .cycleColumnWidthForward: "Cycle Column Width Forward"
        case .cycleColumnWidthBackward: "Cycle Column Width Backward"
        case .cycleWindowWidthForward: "Cycle Window Width Forward"
        case .cycleWindowWidthBackward: "Cycle Window Width Backward"
        case .cycleWindowHeightForward: "Cycle Window Height Forward"
        case .cycleWindowHeightBackward: "Cycle Window Height Backward"
        case .toggleColumnFullWidth: "Toggle Column Full Width"
        case .expandColumnToAvailableWidth: "Expand Column to Available Width"
        case .resetWindowHeight: "Reset Window Height"
        case let .setColumnWidth(change): "Set Column Width \(sizeChangeDisplayName(change))"
        case let .setWindowWidth(change): "Set Window Width \(sizeChangeDisplayName(change))"
        case let .setWindowHeight(change): "Set Window Height \(sizeChangeDisplayName(change))"
        case let .swapWorkspaceWithMonitor(dir): "Swap Workspace with \(dir.displayName) Monitor"
        case .balanceSizes: "Balance Sizes"
        case .workspaceBackAndForth: "Switch to Last Active Workspace"
        case let .focusWorkspaceAnywhere(idx): "Focus Workspace \(idx + 1) Anywhere"
        case let .moveWindowToWorkspaceOnMonitor(wsIdx, monDir): "Move Window to Workspace \(wsIdx + 1) on \(monDir.displayName) Monitor"
        case .openCommandPalette: "Toggle Command Palette"
        case .raiseAllFloatingWindows: "Raise All Floating Windows"
        case .rescueOffscreenWindows: "Rescue Off-Screen Floating Windows"
        case .toggleFocusedWindowFloating: "Toggle Focused Window Floating"
        case .toggleFocusedWindowSticky: "Toggle Focused Window Sticky"
        case .assignFocusedWindowToScratchpad: "Assign Focused Window to Scratchpad"
        case .toggleScratchpadWindow: "Toggle Scratchpad Window"
        case .openMenuAnywhere: "Open Menu Anywhere"
        case .openSettings: "Open Settings"
        case .createAppRuleForFocusedWindow: "Create App Rule for Focused Window…"
        case .debugDumpRuntimeState: "Debug: Dump Runtime State"
        case .debugResetRuntimeState: "Debug: Reset Runtime State"
        case .debugRestartClearingRuntimeState: "Debug: Restart Clearing Runtime State"
        case .debugToggleTraceCapture: "Debug: Toggle Trace Capture"
        case .toggleWorkspaceBarVisibility: "Toggle Workspace Bar"
        case .toggleOverview: "Toggle Overview"
        case .toggleFocusFollowsMouse: "Toggle Focus Follows Mouse"
        case .toggleFocusFollowsWindowToMonitor: "Toggle Follow Window to Workspace"
        case .toggleMoveMouseToFocused: "Toggle Move Mouse to Focused"
        case .toggleBordersEnabled: "Toggle Window Borders"
        case .togglePreventSleepEnabled: "Toggle Keep Awake"
        case .toggleIPCEnabled: "Toggle IPC"
        }
    }

    private static func ipcCommandName(for command: HotkeyCommand) -> IPCCommandName? {
        switch command {
        case .focus:
            .focus
        case .focusPrevious:
            .focusPrevious
        case .focusDownOrLeft:
            .focusDownOrLeft
        case .focusUpOrRight:
            .focusUpOrRight
        case .focusWindowInColumn:
            .focusWindowInColumn
        case .focusWindowTop:
            .focusWindowTop
        case .focusWindowBottom:
            .focusWindowBottom
        case .focusWindowDownOrTop:
            .focusWindowDownOrTop
        case .focusWindowUpOrBottom:
            .focusWindowUpOrBottom
        case .focusWindowOrWorkspaceDown:
            .focusWindowOrWorkspaceDown
        case .focusWindowOrWorkspaceUp:
            .focusWindowOrWorkspaceUp
        case .focusColumn:
            .focusColumn
        case .focusColumnFirst:
            .focusColumnFirst
        case .focusColumnLast:
            .focusColumnLast
        case .scrollViewportLeft:
            .scrollViewportLeft
        case .scrollViewportRight:
            .scrollViewportRight
        case .toggleViewportScrollLock:
            .toggleViewportScrollLock
        case .move:
            .move
        case .moveWindowDown:
            .moveWindowDown
        case .moveWindowUp:
            .moveWindowUp
        case .moveWindowDownOrToWorkspaceDown:
            .moveWindowDownOrToWorkspaceDown
        case .moveWindowUpOrToWorkspaceUp:
            .moveWindowUpOrToWorkspaceUp
        case .consumeOrExpelWindowLeft:
            .consumeOrExpelWindowLeft
        case .consumeOrExpelWindowRight:
            .consumeOrExpelWindowRight
        case .consumeWindowIntoColumn:
            .consumeWindowIntoColumn
        case .expelWindowFromColumn:
            .expelWindowFromColumn
        case .switchWorkspace:
            .switchWorkspace
        case .switchWorkspaceNext:
            .switchWorkspaceNext
        case .switchWorkspacePrevious:
            .switchWorkspacePrevious
        case .workspaceBackAndForth:
            .switchWorkspaceBackAndForth
        case .focusWorkspaceAnywhere:
            .switchWorkspaceAnywhere
        case .moveToWorkspace:
            .moveToWorkspace
        case .moveWindowToWorkspaceUp:
            .moveToWorkspaceUp
        case .moveWindowToWorkspaceDown:
            .moveToWorkspaceDown
        case .moveWindowToWorkspaceOnMonitor:
            .moveToWorkspaceOnMonitor
        case .focusMonitorPrevious:
            .focusMonitorPrevious
        case .focusMonitorNext:
            .focusMonitorNext
        case .focusMonitorLast:
            .focusMonitorLast
        case .moveColumn:
            .moveColumn
        case .moveColumnToFirst:
            .moveColumnToFirst
        case .moveColumnToLast:
            .moveColumnToLast
        case .moveColumnToIndex:
            .moveColumnToIndex
        case .moveColumnToWorkspace:
            .moveColumnToWorkspace
        case .moveColumnToWorkspaceUp:
            .moveColumnToWorkspaceUp
        case .moveColumnToWorkspaceDown:
            .moveColumnToWorkspaceDown
        case .toggleColumnTabbed:
            .toggleColumnTabbed
        case .cycleColumnWidthForward:
            .cycleColumnWidthForward
        case .cycleColumnWidthBackward:
            .cycleColumnWidthBackward
        case .cycleWindowWidthForward:
            .cycleWindowWidthForward
        case .cycleWindowWidthBackward:
            .cycleWindowWidthBackward
        case .cycleWindowHeightForward:
            .cycleWindowHeightForward
        case .cycleWindowHeightBackward:
            .cycleWindowHeightBackward
        case .toggleColumnFullWidth:
            .toggleColumnFullWidth
        case .expandColumnToAvailableWidth:
            .expandColumnToAvailableWidth
        case .resetWindowHeight:
            .resetWindowHeight
        case .setColumnWidth:
            .setColumnWidth
        case .setWindowWidth:
            .setWindowWidth
        case .setWindowHeight:
            .setWindowHeight
        case .swapWorkspaceWithMonitor:
            .swapWorkspaceWithMonitor
        case .balanceSizes:
            .balanceSizes
        case .openCommandPalette:
            .openCommandPalette
        case .raiseAllFloatingWindows:
            .raiseAllFloatingWindows
        case .rescueOffscreenWindows:
            .rescueOffscreenWindows
        case .toggleFullscreen:
            .toggleFullscreen
        case .toggleNativeFullscreen:
            .toggleNativeFullscreen
        case .toggleOverview:
            .toggleOverview
        case .toggleWorkspaceBarVisibility:
            .toggleWorkspaceBar
        case .toggleFocusedWindowFloating:
            .toggleFocusedWindowFloating
        case .toggleFocusedWindowSticky:
            .toggleFocusedWindowSticky
        case .assignFocusedWindowToScratchpad:
            .scratchpadAssign
        case .toggleScratchpadWindow:
            .scratchpadToggle
        case .openMenuAnywhere:
            .openMenuAnywhere
        case .openSettings:
            .openSettings
        case .createAppRuleForFocusedWindow:
            // Intentionally no headless IPC/CLI form: this command opens an
            // interactive App Rules editor the user must finish by hand.
            // Returning nil here is what keeps the NehirIPC module (the
            // command-request/router/manifest surface) out of scope for v1.
            nil
        case .debugDumpRuntimeState:
            .debugDumpRuntimeState
        case .debugResetRuntimeState:
            .debugResetRuntimeState
        case .debugRestartClearingRuntimeState:
            .debugRestartClearingRuntimeState
        case .debugToggleTraceCapture:
            .debugToggleTraceCapture
        case .toggleFocusFollowsMouse:
            .toggleFocusFollowsMouse
        case .toggleFocusFollowsWindowToMonitor:
            .toggleFocusFollowsWindowToMonitor
        case .toggleMoveMouseToFocused:
            .toggleMoveMouseToFocused
        case .toggleBordersEnabled:
            .toggleBordersEnabled
        case .togglePreventSleepEnabled:
            .togglePreventSleepEnabled
        case .toggleIPCEnabled:
            .toggleIPCEnabled
        }
    }

    private static func sizeChangeDisplayName(_ change: NiriSizeChange) -> String {
        switch change {
        case let .setFixed(value):
            "Fixed \(Int(value))px"
        case let .setProportion(value):
            "\(Int(value))%"
        case let .adjustFixed(value):
            "\(value >= 0 ? "+" : "")\(Int(value))px"
        case let .adjustProportion(value):
            "\(value >= 0 ? "+" : "")\(Int(value))%"
        }
    }
}
