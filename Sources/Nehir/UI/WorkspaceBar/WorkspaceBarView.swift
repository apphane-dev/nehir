// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Observation
import SwiftUI

struct WorkspaceBarItem: Identifiable, Equatable {
    let id: WorkspaceDescriptor.ID
    let name: String
    let rawName: String
    let isFocused: Bool
    let tiledWindows: [WorkspaceBarWindowItem]
    let floatingWindows: [WorkspaceBarWindowItem]
    /// True when this workspace lives on a different display than the bar it is
    /// rendered on. Foreign pills are appended after the local workspaces behind
    /// a divider and grouped under a display icon. Plain-click switches their
    /// home display; shift-click moves the focused window there.
    let isForeign: Bool
    let homeMonitorName: String?
    let homeMonitorLabel: String?
    /// Whether this workspace is the active one on its home display. Distinct
    /// from `isFocused` (active *on this monitor*): a foreign workspace can be
    /// active over there without being this display's focused workspace.
    let isActiveOnHomeDisplay: Bool

    init(
        id: WorkspaceDescriptor.ID,
        name: String,
        rawName: String,
        isFocused: Bool,
        tiledWindows: [WorkspaceBarWindowItem],
        floatingWindows: [WorkspaceBarWindowItem],
        isForeign: Bool = false,
        homeMonitorName: String? = nil,
        homeMonitorLabel: String? = nil,
        isActiveOnHomeDisplay: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rawName = rawName
        self.isFocused = isFocused
        self.tiledWindows = tiledWindows
        self.floatingWindows = floatingWindows
        self.isForeign = isForeign
        self.homeMonitorName = homeMonitorName
        self.homeMonitorLabel = homeMonitorLabel
        self.isActiveOnHomeDisplay = isActiveOnHomeDisplay
    }

    var windows: [WorkspaceBarWindowItem] {
        tiledWindows + floatingWindows
    }
}

struct WorkspaceBarProjection: Equatable {
    let items: [WorkspaceBarItem]
    let sticky: WorkspaceBarStickyItem?
    let scratchpad: WorkspaceBarScratchpadItem?
    let isViewportScrollLocked: Bool

    /// Every workspace shown across all monitors — the full target set for the
    /// window-icon *Move to Workspace ▸* submenu. Unlike `items` (scoped to this
    /// monitor), this includes workspaces on other displays so a window can be
    /// moved between monitors.
    let moveTargets: [WorkspaceBarWindowMoveTarget]
}

struct WorkspaceBarWindowItem: Identifiable, Equatable {
    let id: WindowToken
    let windowId: Int
    let appName: String
    let icon: NSImage?
    let isFocused: Bool
    let isSelected: Bool
    let windowCount: Int
    let allWindows: [WorkspaceBarWindowInfo]

    static func == (lhs: WorkspaceBarWindowItem, rhs: WorkspaceBarWindowItem) -> Bool {
        lhs.id == rhs.id
            && lhs.windowId == rhs.windowId
            && lhs.appName == rhs.appName
            && lhs.icon === rhs.icon
            && lhs.isFocused == rhs.isFocused
            && lhs.isSelected == rhs.isSelected
            && lhs.windowCount == rhs.windowCount
            && lhs.allWindows == rhs.allWindows
    }
}

struct WorkspaceBarWindowInfo: Identifiable, Equatable {
    let id: WindowToken
    let windowId: Int
    let title: String
    let isFocused: Bool
    let isSelected: Bool
}

struct WorkspaceBarStickyItem: Identifiable, Equatable {
    let windows: [WorkspaceBarWindowItem]

    var id: String {
        "sticky"
    }
}

struct WorkspaceBarScratchpadItem: Identifiable, Equatable {
    let window: WorkspaceBarWindowItem
    let isVisible: Bool
    let workspaceId: WorkspaceDescriptor.ID
    let workspaceName: String
    let rawWorkspaceName: String

    var id: WindowToken {
        window.id
    }
}

struct WorkspaceBarSnapshot: Equatable {
    let projection: WorkspaceBarProjection
    let showLabels: Bool
    let backgroundOpacity: Double
    let barHeight: CGFloat
    let hasDisplayDiagnosticsWarning: Bool
    let showScrollLockButton: Bool
    let accentColor: SettingsColor?
    let textColor: SettingsColor?

    var items: [WorkspaceBarItem] {
        projection.items
    }

    var sticky: WorkspaceBarStickyItem? {
        projection.sticky
    }

    var scratchpad: WorkspaceBarScratchpadItem? {
        projection.scratchpad
    }

    var moveTargets: [WorkspaceBarWindowMoveTarget] {
        projection.moveTargets
    }
}

@MainActor @Observable
final class WorkspaceBarModel {
    var snapshot: WorkspaceBarSnapshot

    init(snapshot: WorkspaceBarSnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
struct WorkspaceBarView: View {
    let model: WorkspaceBarModel
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onMoveFocusedWindowToWorkspace: (WorkspaceBarItem) -> Void
    let onFocusWindow: (WindowToken) -> Void
    let onActivateScratchpad: () -> Void
    let onOpenCommandPalette: () -> Void
    let onToggleViewportScrollLock: () -> Void
    let onOpenDiagnostics: () -> Void
    let onCreateAppRuleForWindow: (WindowToken) -> Void
    let onToggleWindowFloating: (WindowToken) -> Void
    let onToggleWindowSticky: (WindowToken) -> Void
    let onToggleScratchpadAssignment: (WindowToken) -> Void
    let onSummonWindowRight: (WindowToken) -> Void
    let onCloseWindow: (WindowToken) -> Void
    let onMoveWindowToWorkspace: (WindowToken, WorkspaceDescriptor.ID) -> Void
    let onToggleScratchpadVisible: () -> Void

    var body: some View {
        WorkspaceBarContentView(
            snapshot: model.snapshot,
            animationsEnabled: true,
            onFocusWorkspace: onFocusWorkspace,
            onMoveFocusedWindowToWorkspace: onMoveFocusedWindowToWorkspace,
            onFocusWindow: onFocusWindow,
            onActivateScratchpad: onActivateScratchpad,
            onOpenCommandPalette: onOpenCommandPalette,
            onToggleViewportScrollLock: onToggleViewportScrollLock,
            onOpenDiagnostics: onOpenDiagnostics,
            onCreateAppRuleForWindow: onCreateAppRuleForWindow,
            onToggleWindowFloating: onToggleWindowFloating,
            onToggleWindowSticky: onToggleWindowSticky,
            onToggleScratchpadAssignment: onToggleScratchpadAssignment,
            onSummonWindowRight: onSummonWindowRight,
            onCloseWindow: onCloseWindow,
            onMoveWindowToWorkspace: onMoveWindowToWorkspace,
            onToggleScratchpadVisible: onToggleScratchpadVisible
        )
    }
}

@MainActor
struct WorkspaceBarMeasurementView: View {
    let snapshot: WorkspaceBarSnapshot

    var body: some View {
        WorkspaceBarContentView(
            snapshot: snapshot,
            animationsEnabled: false,
            onFocusWorkspace: { _ in },
            onMoveFocusedWindowToWorkspace: { _ in },
            onFocusWindow: { _ in },
            onActivateScratchpad: {},
            onOpenCommandPalette: {},
            onToggleViewportScrollLock: {},
            onOpenDiagnostics: {},
            onCreateAppRuleForWindow: { _ in },
            onToggleWindowFloating: { _ in },
            onToggleWindowSticky: { _ in },
            onToggleScratchpadAssignment: { _ in },
            onSummonWindowRight: { _ in },
            onCloseWindow: { _ in },
            onMoveWindowToWorkspace: { _, _ in },
            onToggleScratchpadVisible: {}
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A target workspace offered by a window icon's *Move to Workspace ▸*
/// submenu (all realized workspaces across monitors).
struct WorkspaceBarWindowMoveTarget: Identifiable, Hashable {
    let id: WorkspaceDescriptor.ID
    let name: String
}

private struct ForeignWorkspaceItemGroup: Identifiable {
    let id: String
    let items: [WorkspaceBarItem]
}

/// Bundle of right-click actions threaded from the controller through the bar
/// to each window icon. Bundling keeps `WindowIconView` a value type without a
/// long parameter list.
struct WorkspaceBarWindowActions {
    let onToggleFloating: (WindowToken) -> Void
    let onToggleSticky: (WindowToken) -> Void
    let onToggleScratchpadAssignment: (WindowToken) -> Void
    let onCreateAppRule: (WindowToken) -> Void
    let onSummonRight: (WindowToken) -> Void
    let onClose: (WindowToken) -> Void
    let onMoveToWorkspace: (WindowToken, WorkspaceDescriptor.ID) -> Void
    let moveTargets: [WorkspaceBarWindowMoveTarget]
    let scratchpadSlotOccupied: Bool
}

func workspaceBarMoveTargetsExcludingCurrentWorkspace(
    _ targets: [WorkspaceBarWindowMoveTarget],
    currentWorkspaceId: WorkspaceDescriptor.ID
) -> [WorkspaceBarWindowMoveTarget] {
    targets.filter { $0.id != currentWorkspaceId }
}

@MainActor
private struct WorkspaceBarContentView: View {
    let snapshot: WorkspaceBarSnapshot
    let animationsEnabled: Bool
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onMoveFocusedWindowToWorkspace: (WorkspaceBarItem) -> Void
    let onFocusWindow: (WindowToken) -> Void
    let onActivateScratchpad: () -> Void
    let onOpenCommandPalette: () -> Void
    let onToggleViewportScrollLock: () -> Void
    let onOpenDiagnostics: () -> Void
    let onCreateAppRuleForWindow: (WindowToken) -> Void
    let onToggleWindowFloating: (WindowToken) -> Void
    let onToggleWindowSticky: (WindowToken) -> Void
    let onToggleScratchpadAssignment: (WindowToken) -> Void
    let onSummonWindowRight: (WindowToken) -> Void
    let onCloseWindow: (WindowToken) -> Void
    let onMoveWindowToWorkspace: (WindowToken, WorkspaceDescriptor.ID) -> Void
    let onToggleScratchpadVisible: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var itemHeight: CGFloat {
        max(16, snapshot.barHeight - 4)
    }

    private var iconSize: CGFloat {
        max(12, itemHeight - 6)
    }

    /// Workspaces on this display, rendered as full pills with window icons.
    private var localItems: [WorkspaceBarItem] {
        snapshot.items.filter { !$0.isForeign }
    }

    /// Workspaces from other displays, rendered as compact navigation pills
    /// behind a divider. Empty when the per-display toggle is off.
    private var foreignItems: [WorkspaceBarItem] {
        snapshot.items.filter { $0.isForeign }
    }

    /// Foreign workspaces grouped by display so the display icon appears once per
    /// group instead of repeating a display label in every pill.
    private var foreignItemGroups: [ForeignWorkspaceItemGroup] {
        var order: [String] = []
        var grouped: [String: [WorkspaceBarItem]] = [:]
        for item in foreignItems {
            let key = item.homeMonitorLabel ?? item.homeMonitorName ?? "Display"
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(item)
        }
        return order.compactMap { key in
            grouped[key].map { ForeignWorkspaceItemGroup(id: key, items: $0) }
        }
    }

    private let workspaceSpacing: CGFloat = 8
    private let windowSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 6

    private var effectiveAnimationsEnabled: Bool {
        animationsEnabled && !accessibilityReduceMotion
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(snapshot.backgroundOpacity)
            : Color.black.opacity(snapshot.backgroundOpacity * 0.5)
    }

    private var accentColor: Color? {
        snapshot.accentColor?.swiftUIColor
    }

    private var textColor: Color? {
        snapshot.textColor?.swiftUIColor
    }

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    /// Workspaces across all monitors offered by the *Move to Workspace ▸*
    /// submenu (the window's own workspace is excluded per icon later).
    private var windowMoveTargets: [WorkspaceBarWindowMoveTarget] {
        snapshot.moveTargets
    }

    /// True when the single scratchpad slot is held, so the window-icon
    /// *Assign to Scratchpad* item is disabled.
    private var scratchpadSlotOccupied: Bool {
        snapshot.scratchpad != nil
    }

    private var windowActions: WorkspaceBarWindowActions {
        WorkspaceBarWindowActions(
            onToggleFloating: onToggleWindowFloating,
            onToggleSticky: onToggleWindowSticky,
            onToggleScratchpadAssignment: onToggleScratchpadAssignment,
            onCreateAppRule: onCreateAppRuleForWindow,
            onSummonRight: onSummonWindowRight,
            onClose: onCloseWindow,
            onMoveToWorkspace: onMoveWindowToWorkspace,
            moveTargets: windowMoveTargets,
            scratchpadSlotOccupied: scratchpadSlotOccupied
        )
    }

    var body: some View {
        HStack(spacing: workspaceSpacing) {
            ForEach(localItems, id: \.id) { item in
                WorkspaceItemView(
                    item: item,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    windowSpacing: windowSpacing,
                    cornerRadius: cornerRadius,
                    animationsEnabled: effectiveAnimationsEnabled,
                    showLabels: snapshot.showLabels,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: { onFocusWorkspace(item) },
                    onMoveFocusedWindowToWorkspace: { onMoveFocusedWindowToWorkspace(item) },
                    onFocusWindow: onFocusWindow,
                    windowActions: windowActions
                )
            }

            if !foreignItemGroups.isEmpty {
                Divider()
                    .frame(height: itemHeight)
                    .opacity(0.4)
                    .accessibilityHidden(true)

                ForEach(foreignItemGroups) { group in
                    ForeignWorkspaceGroupView(
                        group: group,
                        iconSize: iconSize,
                        itemHeight: itemHeight,
                        cornerRadius: cornerRadius,
                        animationsEnabled: effectiveAnimationsEnabled,
                        accentColor: accentColor,
                        textColor: textColor,
                        onFocusWorkspace: onFocusWorkspace,
                        onMoveFocusedWindowToWorkspace: onMoveFocusedWindowToWorkspace
                    )
                }
            }

            if let sticky = snapshot.sticky {
                StickyPillView(
                    item: sticky,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    animationsEnabled: effectiveAnimationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow,
                    actions: windowActions
                )
            }

            if let scratchpad = snapshot.scratchpad {
                ScratchpadPillView(
                    item: scratchpad,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    animationsEnabled: effectiveAnimationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onActivateScratchpad: onActivateScratchpad,
                    onToggleScratchpadVisible: onToggleScratchpadVisible,
                    onUnassignScratchpad: { onToggleScratchpadAssignment(scratchpad.window.id) }
                )
            }

            if snapshot.showScrollLockButton {
                ScrollLockBarButton(
                    isLocked: snapshot.projection.isViewportScrollLocked,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    accentColor: accentColor,
                    textColor: textColor,
                    onToggle: onToggleViewportScrollLock
                )
            }

            if snapshot.hasDisplayDiagnosticsWarning {
                DisplayDiagnosticsBarButton(
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    onOpenDiagnostics: onOpenDiagnostics
                )
            }

            CommandPaletteBarButton(
                iconSize: iconSize,
                itemHeight: itemHeight,
                accentColor: accentColor,
                textColor: textColor,
                onOpenCommandPalette: onOpenCommandPalette
            )
        }
        .padding(.horizontal, 4)
        .frame(height: itemHeight + 4)
        .background {
            if accessibilityReduceTransparency {
                barShape.fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
            } else {
                barShape
                    .fill(backgroundColor)
                    .background(.ultraThinMaterial, in: barShape)
            }

            barShape.strokeBorder(
                colorSchemeContrast == .increased
                    ? Color.primary.opacity(0.45)
                    : Color.secondary.opacity(0.18),
                lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
            )
        }
    }
}

@MainActor
private struct WorkspaceItemView: View {
    let item: WorkspaceBarItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let windowSpacing: CGFloat
    let cornerRadius: CGFloat
    let animationsEnabled: Bool
    let showLabels: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWorkspace: () -> Void
    let onMoveFocusedWindowToWorkspace: () -> Void
    let onFocusWindow: (WindowToken) -> Void
    let windowActions: WorkspaceBarWindowActions

    @State private var isHovered = false

    /// Move targets scoped to this workspace item: the other workspaces visible
    /// on this monitor (the current one is excluded so the submenu never offers
    /// a no-op move into the window's own workspace).
    private var scopedWindowActions: WorkspaceBarWindowActions {
        WorkspaceBarWindowActions(
            onToggleFloating: windowActions.onToggleFloating,
            onToggleSticky: windowActions.onToggleSticky,
            onToggleScratchpadAssignment: windowActions.onToggleScratchpadAssignment,
            onCreateAppRule: windowActions.onCreateAppRule,
            onSummonRight: windowActions.onSummonRight,
            onClose: windowActions.onClose,
            onMoveToWorkspace: windowActions.onMoveToWorkspace,
            moveTargets: workspaceBarMoveTargetsExcludingCurrentWorkspace(
                windowActions.moveTargets,
                currentWorkspaceId: item.id
            ),
            scratchpadSlotOccupied: windowActions.scratchpadSlotOccupied
        )
    }

    var body: some View {
        HStack(spacing: windowSpacing) {
            if showLabels {
                WorkspaceLabelButton(
                    item: item,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: onFocusWorkspace,
                    onMoveFocusedWindowToWorkspace: onMoveFocusedWindowToWorkspace
                )

                if !item.windows.isEmpty {
                    Divider()
                        .frame(height: iconSize)
                        .padding(.horizontal, 2)
                        .accessibilityHidden(true)
                }
            } else if item.windows.isEmpty {
                WorkspaceLabelButton(
                    item: item,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: onFocusWorkspace,
                    onMoveFocusedWindowToWorkspace: onMoveFocusedWindowToWorkspace
                )
            }

            ForEach(item.tiledWindows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isSelected: window.isSelected,
                    isInFocusedWorkspace: item.isFocused,
                    context: .tiled,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow,
                    actions: scopedWindowActions
                )
            }

            if !item.tiledWindows.isEmpty && !item.floatingWindows.isEmpty {
                Divider()
                    .frame(height: iconSize)
                    .padding(.horizontal, 2)
                    .accessibilityHidden(true)
            }

            if !item.floatingWindows.isEmpty {
                FloatingWindowsGroupView(
                    windows: item.floatingWindows,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    isInFocusedWorkspace: item.isFocused,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow,
                    actions: scopedWindowActions
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(height: itemHeight)
        .background {
            if item.isFocused || isHovered {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.regularMaterial)
                    .overlay {
                        if item.isFocused {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(accentColor ?? .accentColor, lineWidth: 1)
                        }
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onFocusWorkspace()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button {
                onFocusWorkspace()
            } label: {
                Label("Focus Workspace \(item.name)", systemImage: "arrow.right.square")
            }
            Button {
                onMoveFocusedWindowToWorkspace()
            } label: {
                Label("Move Focused Window Here", systemImage: "arrowshape.turn.up.right")
            }
            Divider()
            Text("Shift-click also moves one window here.")
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct WorkspaceLabelButton: View {
    let item: WorkspaceBarItem
    let accentColor: Color?
    let textColor: Color?
    let onFocusWorkspace: () -> Void
    let onMoveFocusedWindowToWorkspace: () -> Void

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedLabelColor: Color {
        textColor ?? (item.isFocused ? resolvedAccentColor : .secondary)
    }

    var body: some View {
        Button(action: onFocusWorkspace) {
            Text(item.name)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(resolvedLabelColor)
                .frame(minWidth: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Right-click workspace label: *Focus* equals left-click. The
        // *Move Workspace to Monitor ▸* item is omitted until Nehir #62 lands.
        .contextMenu {
            Button {
                onFocusWorkspace()
            } label: {
                Label("Focus", systemImage: "rectangle.center.inset.filled")
            }
            Button {
                onMoveFocusedWindowToWorkspace()
            } label: {
                Label("Move Focused Window Here", systemImage: "arrowshape.turn.up.right")
            }
            Divider()
            Text("Shift-click also moves one window here.")
        }
        .accessibilityLabel("Workspace \(item.name)")
        .accessibilityValue(item.isFocused ? "Focused" : "")
        .help(
            "Focus workspace \(item.name). Shift-click or right-click to move the focused window here."
        )
    }
}

@MainActor
private struct ForeignWorkspaceGroupView: View {
    let group: ForeignWorkspaceItemGroup
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let cornerRadius: CGFloat
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onMoveFocusedWindowToWorkspace: (WorkspaceBarItem) -> Void

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "display")
                .font(.system(size: max(9, iconSize * 0.58), weight: .medium))
                .foregroundStyle(resolvedSecondaryTextColor.opacity(0.75))
                .accessibilityHidden(true)

            ForEach(group.items, id: \.id) { item in
                ForeignWorkspaceItemView(
                    item: item,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    cornerRadius: cornerRadius,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: { onFocusWorkspace(item) },
                    onMoveFocusedWindowToWorkspace: { onMoveFocusedWindowToWorkspace(item) }
                )
            }
        }
    }
}

@MainActor
private struct ForeignWorkspaceItemView: View {
    let item: WorkspaceBarItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let cornerRadius: CGFloat
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWorkspace: () -> Void
    let onMoveFocusedWindowToWorkspace: () -> Void

    @State private var isHovered = false

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var accessibilityLabel: String {
        var label = "Workspace \(item.name)"
        if let home = item.homeMonitorName {
            label += " on \(home)"
        }
        return label
    }

    var body: some View {
        Button(action: onFocusWorkspace) {
            HStack(spacing: 4) {
                if item.isActiveOnHomeDisplay {
                    Circle()
                        .fill(resolvedAccentColor)
                        .frame(width: max(4, iconSize * 0.28), height: max(4, iconSize * 0.28))
                        .accessibilityHidden(true)
                }
                Text(item.name)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(textColor ?? .primary)
                    .frame(minWidth: 16)
            }
            .padding(.horizontal, 6)
            .frame(height: itemHeight)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(animationsEnabled ? .easeInOut(duration: 0.12) : nil, value: isHovered)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(isHovered ? 0.16 : 0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.6)
                }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        // Right-click mirrors the local workspace pill: *Focus* equals left-click
        // (and honors shift to move the focused window); *Move Focused Window
        // Here* is the explicit shift-click shortcut.
        .contextMenu {
            Button {
                onFocusWorkspace()
            } label: {
                Label("Focus Workspace \(item.name)", systemImage: "arrow.right.square")
            }
            Button {
                onMoveFocusedWindowToWorkspace()
            } label: {
                Label("Move Focused Window Here", systemImage: "arrowshape.turn.up.right")
            }
            Divider()
            Text("Shift-click also moves one window here.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(item.isActiveOnHomeDisplay ? "Active on home display" : "")
        .help(
            "Workspace \(item.name) on \(item.homeMonitorName ?? "another display"). Click to switch that display; shift-click to move the focused window there."
        )
    }
}

@MainActor
private struct FloatingWindowsGroupView: View {
    let windows: [WorkspaceBarWindowItem]
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let isInFocusedWorkspace: Bool
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowToken) -> Void
    let actions: WorkspaceBarWindowActions

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: max(10, iconSize * 0.58), weight: .medium))
                .foregroundStyle(resolvedSecondaryTextColor)
                .accessibilityHidden(true)

            ForEach(windows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isSelected: window.isSelected,
                    isInFocusedWorkspace: isInFocusedWorkspace,
                    context: .floating,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow,
                    actions: actions
                )
            }
        }
        .padding(.horizontal, 5)
        .frame(height: max(16, itemHeight - 2))
        .background {
            Capsule(style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.75)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating windows")
    }
}

@MainActor
private struct StickyPillView: View {
    let item: WorkspaceBarStickyItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowToken) -> Void
    let actions: WorkspaceBarWindowActions

    @State private var isHovered = false

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    private var isFocused: Bool {
        item.windows.contains(where: \.isFocused)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "pin.fill")
                .font(.system(size: max(10, iconSize * 0.64), weight: .semibold))
                .foregroundStyle(isFocused ? resolvedAccentColor : resolvedSecondaryTextColor)
                .accessibilityHidden(true)

            ForEach(item.windows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isSelected: window.isSelected,
                    isInFocusedWorkspace: true,
                    context: .floating,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow,
                    actions: actions
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: itemHeight)
        .contentShape(Capsule(style: .continuous))
        .background {
            Capsule(style: .continuous)
                .fill(isFocused ? resolvedAccentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isFocused ? resolvedAccentColor : Color.secondary.opacity(0.36),
                            lineWidth: isFocused ? 1.2 : 0.8
                        )
                }
        }
        .scaleEffect(isHovered ? 1.03 : 1)
        .animation(animationsEnabled ? .easeInOut(duration: 0.12) : nil, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sticky windows")
        .help("Sticky windows stay visible across workspace changes. Right-click a window for actions.")
    }
}

@MainActor
private struct ScratchpadPillView: View {
    let item: WorkspaceBarScratchpadItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onActivateScratchpad: () -> Void
    let onToggleScratchpadVisible: () -> Void
    let onUnassignScratchpad: () -> Void

    @State private var isHovered = false

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        Button(action: onActivateScratchpad) {
            HStack(spacing: 5) {
                Image(systemName: "tray.fill")
                    .font(.system(size: max(10, iconSize * 0.64), weight: .semibold))
                    .foregroundStyle(item.window.isFocused ? resolvedAccentColor : resolvedSecondaryTextColor)
                    .accessibilityHidden(true)

                AppIconImage(icon: item.window.icon)
                    .frame(width: iconSize, height: iconSize)
                    .opacity(item.window.isFocused ? 1 : 0.82)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: itemHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .animation(animationsEnabled ? .easeInOut(duration: 0.12) : nil, value: isHovered)
        .animation(animationsEnabled ? .easeInOut(duration: 0.15) : nil, value: item.window.isFocused)
        .background {
            Capsule(style: .continuous)
                .fill(item.window.isFocused ? resolvedAccentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            item.window.isFocused ? resolvedAccentColor : Color.secondary
                                .opacity(item.isVisible ? 0.36 : 0.22),
                            lineWidth: item.window.isFocused ? 1.2 : 0.8
                        )
                }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        // Right-click scratchpad pill: *Toggle Visible / Unassign / Focus*.
        // *Focus* mirrors the pill's left-click activation.
        .contextMenu {
            Button {
                onToggleScratchpadVisible()
            } label: {
                Label(item.isVisible ? "Hide" : "Show", systemImage: "eye")
            }
            Button(role: .destructive) {
                onUnassignScratchpad()
            } label: {
                Label("Unassign from Scratchpad", systemImage: "tray")
            }
            Button {
                onActivateScratchpad()
            } label: {
                Label("Focus", systemImage: "rectangle.center.inset.filled")
            }
        }
        .accessibilityLabel("Scratchpad")
        .accessibilityValue(accessibilityValue)
        .help(
            "Scratchpad: \(item.window.appName), \(item.isVisible ? "visible" : "hidden"). Right-click for more actions."
        )
    }

    private var scale: CGFloat {
        if item.window.isFocused {
            1.04
        } else if isHovered {
            1.03
        } else {
            1
        }
    }

    private var accessibilityValue: String {
        var parts = [item.window.appName, item.isVisible ? "Visible" : "Hidden"]
        if item.window.isFocused {
            parts.append("Focused")
        }
        parts.append("Workspace \(item.workspaceName)")
        return parts.joined(separator: ", ")
    }
}

private enum WorkspaceBarWindowContext {
    case tiled
    case floating

    var label: String {
        switch self {
        case .tiled:
            "window"
        case .floating:
            "floating window"
        }
    }
}

@MainActor
private struct WindowIconView: View {
    let window: WorkspaceBarWindowItem
    let iconSize: CGFloat
    let isFocused: Bool
    let isSelected: Bool
    let isInFocusedWorkspace: Bool
    let context: WorkspaceBarWindowContext
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowToken) -> Void
    let actions: WorkspaceBarWindowActions

    @State private var isHovered = false
    @State private var showingWindowList = false

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    var body: some View {
        Button {
            if window.windowCount > 1 {
                showingWindowList = true
            } else {
                onFocusWindow(window.id)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                AppIconImage(icon: window.icon)
                    .frame(width: iconSize, height: iconSize)
                    .opacity(opacity)
                    .shadow(color: resolvedAccentColor.opacity(glowOpacity), radius: glowRadius)
                    .accessibilityHidden(true)

                if window.windowCount > 1 {
                    WindowCountBadge(count: window.windowCount, iconSize: iconSize, textColor: textColor)
                        .offset(x: iconSize * 0.2, y: -iconSize * 0.1)
                }
            }
            .frame(minWidth: max(16, iconSize + 4), minHeight: max(16, iconSize + 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .animation(animationsEnabled ? .easeInOut(duration: 0.15) : nil, value: isFocused)
        .animation(animationsEnabled ? .easeInOut(duration: 0.15) : nil, value: isSelected)
        .animation(animationsEnabled ? .easeInOut(duration: 0.1) : nil, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        // Right-click window icon: *Toggle Floating; Assign to Scratchpad;
        // Create App Rule; Move to Workspace ▸; Summon Right; Close; Windows…*. Acts on
        // this window's token, not focus.
        .contextMenu {
            Button {
                actions.onToggleFloating(window.id)
            } label: {
                Label("Toggle Floating", systemImage: "rectangle")
            }
            Button {
                actions.onToggleSticky(window.id)
            } label: {
                Label("Toggle Sticky", systemImage: "pin")
            }
            Button {
                actions.onToggleScratchpadAssignment(window.id)
            } label: {
                Label("Assign to Scratchpad", systemImage: "tray")
            }
            .disabled(actions.scratchpadSlotOccupied)
            if !actions.moveTargets.isEmpty {
                Menu {
                    ForEach(actions.moveTargets) { target in
                        Button(target.name) {
                            actions.onMoveToWorkspace(window.id, target.id)
                        }
                    }
                } label: {
                    Label("Move to Workspace", systemImage: "arrow.right.square")
                }
            }
            Button {
                actions.onCreateAppRule(window.id)
            } label: {
                Label("Create App Rule for This Window…", systemImage: "slider.horizontal.3")
            }
            Button {
                actions.onSummonRight(window.id)
            } label: {
                Label("Summon Right", systemImage: "arrow.right.to.line")
            }
            Divider()
            Button(role: .destructive) {
                actions.onClose(window.id)
            } label: {
                Label("Close", systemImage: "xmark.rectangle")
            }
            if window.windowCount > 1 {
                Divider()
                Button {
                    showingWindowList = true
                } label: {
                    Label("Windows…", systemImage: "list.bullet")
                }
            }
        }
        .sheet(isPresented: $showingWindowList) {
            WindowListSheet(
                windows: window.allWindows,
                appName: window.appName,
                accentColor: accentColor,
                textColor: textColor,
                onFocusWindow: { token in
                    onFocusWindow(token)
                    showingWindowList = false
                }
            )
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .help("\(window.appName). Right-click for more actions.")
    }

    private var opacity: Double {
        if isFocused || isSelected {
            1.0
        } else if isInFocusedWorkspace {
            0.4
        } else {
            0.5
        }
    }

    private var scale: CGFloat {
        if isFocused {
            1.1
        } else if isHovered {
            1.05
        } else {
            1.0
        }
    }

    private var glowRadius: CGFloat {
        if isFocused { 4 }
        else if isSelected { 3 }
        else { 0 }
    }

    private var glowOpacity: Double {
        if isFocused { 0.5 }
        else if isSelected { 0.22 }
        else { 0 }
    }

    private var accessibilityLabel: String {
        if window.windowCount > 1 {
            "\(window.appName), \(window.windowCount) \(context.label)s"
        } else {
            "Focus \(window.appName) \(context.label)"
        }
    }

    private var accessibilityValue: String {
        if isFocused { "Focused" }
        else if isSelected { "Selected" }
        else { "" }
    }
}

@MainActor
private struct AppIconImage: View {
    let icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
    }
}

@MainActor
private struct WindowCountBadge: View {
    let count: Int
    let iconSize: CGFloat
    let textColor: Color?

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(textColor ?? .primary)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5)
                    }
            )
            .frame(minWidth: max(12, iconSize * 0.55), minHeight: max(12, iconSize * 0.55))
            .accessibilityHidden(true)
    }
}

@MainActor
private struct DisplayDiagnosticsBarButton: View {
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let onOpenDiagnostics: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpenDiagnostics) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: max(10, iconSize * 0.7), weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(width: itemHeight, height: itemHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Display Diagnostics Warning")
        .help("Open Display and Dock Diagnostics")
    }
}

@MainActor
private struct ScrollLockBarButton: View {
    let isLocked: Bool
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let accentColor: Color?
    let textColor: Color?
    let onToggle: () -> Void

    @State private var isHovered = false

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                .font(.system(size: max(10, iconSize * 0.7), weight: .medium))
                .foregroundStyle(isLocked ? resolvedAccentColor : resolvedSecondaryTextColor.opacity(0.75))
                .frame(width: itemHeight, height: itemHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .background {
            if isHovered || isLocked {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isLocked ? resolvedAccentColor.opacity(0.16) : Color.primary.opacity(0.08))
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(isLocked ? "Viewport Scroll Lock On" : "Viewport Scroll Lock Off")
        .help(isLocked ?
            "Background automatic reveals are locked. Direct navigation and manual scrolling still work — click to unlock." :
            "Lock background automatic reveal scrolling. Direct navigation and manual scrolling keep working while locked.")
    }
}

@MainActor
private struct CommandPaletteBarButton: View {
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let accentColor: Color?
    let textColor: Color?
    let onOpenCommandPalette: () -> Void

    @State private var isHovered = false

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        Button(action: onOpenCommandPalette) {
            Image(systemName: "command")
                .font(.system(size: max(10, iconSize * 0.7), weight: .medium))
                .foregroundStyle(resolvedSecondaryTextColor)
                .frame(width: itemHeight, height: itemHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Command Palette")
        .help("Open Command Palette")
    }
}

@MainActor
private struct WindowListSheet: View {
    let windows: [WorkspaceBarWindowInfo]
    let appName: String
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowToken) -> Void
    @Environment(\.dismiss) private var dismiss

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedPrimaryTextColor: Color {
        textColor ?? .primary
    }

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(appName)
                    .font(.headline)
                    .padding()
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .padding()
            }
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            List(windows) { windowInfo in
                Button {
                    onFocusWindow(windowInfo.id)
                } label: {
                    HStack {
                        Text(windowInfo.title)
                            .foregroundStyle(windowInfo
                                .isFocused ? resolvedPrimaryTextColor : resolvedSecondaryTextColor)
                        Spacer()
                        if windowInfo.isFocused {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(resolvedAccentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }
}
