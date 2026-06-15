import SwiftUI

/// Miniature recreation of the real workspace bar (see `WorkspaceBarView`). Shows the bar's
/// actual shape — a rounded bar of workspace pills plus a scratchpad capsule — and animates
/// focus cycling between workspaces so the user sees "this bar tracks active workspaces".
///
/// Reflects the live content settings (`showLabels`, `showFloatingWindows`,
/// `deduplicateAppIcons`, `hideEmptyWorkspaces`) so the onboarding toggles preview changes
/// in real time. The focus tour only visits non-empty workspaces so toggling "Hide Empty" can
/// never strand the highlight on a pill that just vanished.
struct WorkspaceBarAnimation: View {
    let showLabels: Bool
    let showFloatingWindows: Bool
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
        let windows: [MockWindow]
    }

    // Workspace 4 is empty so "Hide Empty Workspaces" has something to hide. Workspace 1 has
    // two `doc.text` windows so "Group Windows by App" can collapse them into a single badge.
    private let workspaces: [MockWorkspace] = [
        MockWorkspace(id: 0, label: "1", windows: [
            MockWindow(symbol: "macwindow"),
            MockWindow(symbol: "doc.text"),
            MockWindow(symbol: "doc.text")
        ]),
        MockWorkspace(id: 1, label: "2", windows: [
            MockWindow(symbol: "chart.bar"),
            MockWindow(symbol: "envelope"),
            MockWindow(symbol: "doc.text")
        ]),
        MockWorkspace(id: 2, label: "3", windows: [MockWindow(symbol: "music.note")]),
        MockWorkspace(id: 3, label: "4", windows: [])
    ]

    private let scratchpad = [MockWindow(symbol: "rectangle.on.rectangle")]
    private let iconSize: CGFloat = 11
    private let pillHeight: CGFloat = 26
    private let cornerRadius: CGFloat = 6
    private let workspaceSpacing: CGFloat = 8

    /// Workspaces shown in the bar. The empty workspace drops out when "Hide Empty" is on.
    private var visibleWorkspaces: [MockWorkspace] {
        hideEmptyWorkspaces
            ? workspaces.filter { !$0.windows.isEmpty }
            : workspaces
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
            if showFloatingWindows {
                scratchpadPill
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
    }

    private func workspacePill(_ ws: MockWorkspace) -> some View {
        let isFocused = ws.id == focusedWorkspace
        return HStack(spacing: 5) {
            if showLabels {
                Text(ws.label)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 10)
            }
            ForEach(Array(displayedWindows(ws.windows).enumerated()), id: \.offset) { _, item in
                windowIcon(symbol: item.symbol, count: item.count, isFocused: isFocused)
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

    private var scratchpadPill: some View {
        HStack(spacing: 3) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(scratchpad) { window in
                Image(systemName: window.symbol)
                    .font(.system(size: iconSize))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: max(16, pillHeight - 4))
        .background {
            Capsule(style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.75)
                }
        }
    }

    private func startLoop() {
        animationTask?.cancel()
        isAnimating = true
        animationTask = Task { @MainActor in
            while isAnimating && !Task.isCancelled {
                // Only tour non-empty workspaces; the empty pill is illustrative, not a focus
                // target, so toggling "Hide Empty" can't leave the highlight stranded.
                for ws in workspaces where !ws.windows.isEmpty {
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
