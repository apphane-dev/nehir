// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

/// Miniature recreation of the real workspace bar (see `WorkspaceBarView`). Shows the bar's
/// actual shape — a rounded bar of workspace pills — and animates focus cycling between
/// workspaces so the user sees "this bar tracks active workspaces".
///
/// Reflects the live content settings (`showLabels`, `showFloatingWindows`,
/// `showScrollLockButton`, `deduplicateAppIcons`, `hideEmptyWorkspaces`) so the onboarding toggles preview changes
/// in real time. Floating windows are rendered inside their owning workspace pill, matching the
/// real bar. The focus tour only visits non-empty workspaces so toggling "Hide Empty" can never
/// strand the highlight on a pill that just vanished.
struct WorkspaceBarAnimation: View {
    let showLabels: Bool
    let showFloatingWindows: Bool
    let showScrollLockButton: Bool
    let deduplicateAppIcons: Bool
    let hideEmptyWorkspaces: Bool

    @State private var isAnimating = false
    @State private var focusedWorkspace = 0
    @State private var animationTask: Task<Void, Never>?

    private struct MockWindow: Identifiable {
        let id = UUID()
        let symbol: String
    }

    private struct MockWorkspace: Identifiable {
        let id: Int
        let label: String
        let tiledWindows: [MockWindow]
        let floatingWindows: [MockWindow]
    }

    // Workspace 4 is floating-only so "Show Floating Windows" demonstrates the same ownership
    // rules as the real bar: floating windows belong to a workspace and count as occupancy only
    // when floating windows are visible in the bar. Workspace 5 is truly empty so "Hide Empty
    // Workspaces" always has an obvious effect. Workspace 1 has two `doc.text` tiled windows so
    // "Group Windows by App" can collapse them into a single badge.
    private let workspaces: [MockWorkspace] = [
        MockWorkspace(
            id: 0,
            label: "1",
            tiledWindows: [
                MockWindow(symbol: "macwindow"),
                MockWindow(symbol: "doc.text"),
                MockWindow(symbol: "doc.text")
            ],
            floatingWindows: []
        ),
        MockWorkspace(
            id: 1,
            label: "2",
            tiledWindows: [
                MockWindow(symbol: "chart.bar"),
                MockWindow(symbol: "envelope"),
                MockWindow(symbol: "doc.text")
            ],
            floatingWindows: [MockWindow(symbol: "bubble.left")]
        ),
        MockWorkspace(
            id: 2,
            label: "3",
            tiledWindows: [MockWindow(symbol: "music.note")],
            floatingWindows: []
        ),
        MockWorkspace(
            id: 3,
            label: "4",
            tiledWindows: [],
            floatingWindows: [
                MockWindow(symbol: "rectangle.on.rectangle"),
                MockWindow(symbol: "note.text")
            ]
        ),
        MockWorkspace(
            id: 4,
            label: "5",
            tiledWindows: [],
            floatingWindows: []
        )
    ]
    private let iconSize: CGFloat = 11
    private let pillHeight: CGFloat = 26
    private let cornerRadius: CGFloat = 6
    private let workspaceSpacing: CGFloat = 8

    /// Workspaces shown in the bar. A truly empty workspace drops out when "Hide Empty" is on;
    /// a floating-only workspace also drops out when floating windows are hidden, matching
    /// `WorkspaceBarDataSource.hasBarVisibleOccupancy`.
    private var visibleWorkspaces: [MockWorkspace] {
        hideEmptyWorkspaces
            ? workspaces.filter(hasBarVisibleOccupancy)
            : workspaces
    }

    private func hasBarVisibleOccupancy(_ workspace: MockWorkspace) -> Bool {
        !workspace.tiledWindows.isEmpty || (showFloatingWindows && !workspace.floatingWindows.isEmpty)
    }

    var body: some View {
        VStack(spacing: 18) {
            bar
            // Screen-edge cue: the bar sits at the top of the screen.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 180, height: 3)
        }
        .onAppear { startLoop() }
        .onChange(of: showFloatingWindows) { _, _ in
            restartLoopIfAnimating()
        }
        .onChange(of: hideEmptyWorkspaces) { _, _ in
            restartLoopIfAnimating()
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
            isAnimating = false
        }
    }

    private var bar: some View {
        HStack(spacing: workspaceSpacing) {
            ForEach(visibleWorkspaces) { ws in
                workspacePill(ws)
            }

            if showScrollLockButton {
                scrollLockButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
                }
        }
        .animation(.easeInOut(duration: 0.3), value: focusedWorkspace)
        .animation(.easeInOut(duration: 0.2), value: hideEmptyWorkspaces)
        .animation(.easeInOut(duration: 0.2), value: showFloatingWindows)
        .animation(.easeInOut(duration: 0.2), value: showScrollLockButton)
    }

    private var scrollLockButton: some View {
        Image(systemName: "lock.open")
            .font(.system(size: max(10, iconSize), weight: .semibold))
            .foregroundStyle(Color.secondary)
            .frame(width: pillHeight, height: pillHeight)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.75)
                    }
            }
            .accessibilityLabel("Viewport Scroll Lock")
    }

    private func workspacePill(_ ws: MockWorkspace) -> some View {
        let isFocused = ws.id == focusedWorkspace
        return HStack(spacing: 5) {
            if showLabels || !hasBarVisibleOccupancy(ws) {
                Text(ws.label)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 10)
            }
            ForEach(Array(displayedWindows(ws.tiledWindows).enumerated()), id: \.offset) { _, item in
                windowIcon(symbol: item.symbol, count: item.count, isFocused: isFocused)
            }
            if showFloatingWindows && !ws.floatingWindows.isEmpty {
                floatingWindowGroup(ws.floatingWindows, isFocused: isFocused)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: pillHeight)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                    }
            }
        }
        .contentShape(Rectangle())
    }

    /// Collapses duplicate app icons into a single icon with a count badge when
    /// "Group Windows by App" is on; otherwise renders every window icon individually.
    private func displayedWindows(_ windows: [MockWindow]) -> [(symbol: String, count: Int)] {
        if !deduplicateAppIcons {
            return windows.map { (symbol: $0.symbol, count: 1) }
        }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for window in windows {
            if counts[window.symbol] == nil { order.append(window.symbol) }
            counts[window.symbol, default: 0] += 1
        }
        return order.map { (symbol: $0, count: counts[$0] ?? 0) }
    }

    private func windowIcon(symbol: String, count: Int, isFocused: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: iconSize))
            .foregroundStyle(isFocused ? Color.primary : Color.secondary)
            .overlay(alignment: .bottomTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 9, height: 9)
                        .background(Capsule().fill(Color.accentColor))
                        .overlay(Capsule().strokeBorder(.white, lineWidth: 0.5))
                        .offset(x: 3, y: 3)
                }
            }
    }

    private func floatingWindowGroup(_ windows: [MockWindow], isFocused: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: max(9, iconSize * 0.58), weight: .medium))
                .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                .accessibilityHidden(true)
            ForEach(Array(displayedWindows(windows).enumerated()), id: \.offset) { _, item in
                windowIcon(symbol: item.symbol, count: item.count, isFocused: isFocused)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: max(16, pillHeight - 2))
        .background {
            Capsule(style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.75)
                }
        }
    }

    private func restartLoopIfAnimating() {
        guard isAnimating else { return }
        startLoop()
    }

    private func startLoop() {
        animationTask?.cancel()
        isAnimating = true
        animationTask = Task { @MainActor in
            while isAnimating && !Task.isCancelled {
                // Only tour non-empty workspaces; the empty pill is illustrative, not a focus
                // target, so toggling "Hide Empty" can't leave the highlight stranded.
                for ws in workspaces where hasBarVisibleOccupancy(ws) {
                    guard isAnimating, !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        focusedWorkspace = ws.id
                    }
                    try? await Task.sleep(for: .milliseconds(1100))
                }
            }
        }
    }
}
