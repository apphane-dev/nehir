import AppKit
import Carbon
import SwiftUI

/// Interactive playground for the "Move With Shortcuts" step. Models Niri's consume-or-expel
/// move semantics: moving a window that shares a column **expels** it into its own column;
/// moving a solo window **collocates** it into the neighbour column (stacking). The same
/// focus/move/workspace/palette operations are reachable via a real 3-finger trackpad
/// gesture, tap, and keyboard.
@MainActor
final class MoveDemoModel: ObservableObject {
    struct Window: Identifiable, Equatable {
        let id: Int
        let symbol: String
    }

    struct Column: Identifiable, Equatable {
        let id: Int
        var windows: [Window]
        var count: Int { windows.count }
    }

    struct Workspace: Identifiable, Equatable {
        let id: Int
        let label: String
        var columns: [Column]
    }

    struct PaletteAction: Identifiable, Hashable {
        let id: String
        let title: String
        let bindingID: String?
        let action: String
    }

    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var currentWorkspaceIndex: Int = 0
    @Published private(set) var focusedColumnId: Int
    @Published private(set) var focusedWindowId: Int

    /// Horizontal scroll position (left-origin). `0` shows the leftmost columns; the track
    /// is offset by `-scrollX`.
    @Published var scrollX: CGFloat = 0

    @Published var dragColumnId: Int?
    @Published var dragTranslation: CGFloat = 0
    @Published var isLiveDragging = false

    @Published var paletteOpen = false
    @Published var paletteSelection = 0

    private var columnIdSeed: Int

    // Fixed geometry so scroll math is deterministic (never derived from measured layout).
    let viewportWidth: CGFloat = 150
    let columnWidth: CGFloat = 48
    let columnHeight: CGFloat = 88
    let columnSpacing: CGFloat = 8
    let windowSpacing: CGFloat = 3

    var slotWidth: CGFloat { columnWidth + columnSpacing }

    let paletteActions: [PaletteAction] = [
        PaletteAction(id: "focus.left", title: "Focus Left", bindingID: "focus.left", action: "focus.left"),
        PaletteAction(id: "focus.right", title: "Focus Right", bindingID: "focus.right", action: "focus.right"),
        PaletteAction(id: "focus.up", title: "Focus Up", bindingID: "focus.up", action: "focus.up"),
        PaletteAction(id: "focus.down", title: "Focus Down", bindingID: "focus.down", action: "focus.down"),
        PaletteAction(id: "move.left", title: "Move Window Left", bindingID: "move.left", action: "move.left"),
        PaletteAction(id: "move.right", title: "Move Window Right", bindingID: "move.right", action: "move.right"),
        PaletteAction(id: "move.up", title: "Move Window Up", bindingID: "moveWindowUp", action: "move.up"),
        PaletteAction(id: "move.down", title: "Move Window Down", bindingID: "moveWindowDown", action: "move.down"),
        PaletteAction(id: "ws.prev", title: "Previous Workspace", bindingID: "switchWorkspace.previous", action: "ws.prev"),
        PaletteAction(id: "ws.next", title: "Next Workspace", bindingID: "switchWorkspace.next", action: "ws.next")
    ]

    private static let symbols = ["macwindow", "doc.text", "chart.bar", "envelope", "photo", "music.note", "book", "rectangle.3.group"]

    init() {
        // ws0: 7 columns, one pre-stacked (2 windows) so expel is visible immediately.
        let ws0: [Column] = [
            Column(id: 0, windows: [Window(id: 0, symbol: Self.symbols[0])]),
            Column(id: 1, windows: [Window(id: 1, symbol: Self.symbols[1]), Window(id: 2, symbol: Self.symbols[2])]),
            Column(id: 2, windows: [Window(id: 3, symbol: Self.symbols[3])]),
            Column(id: 3, windows: [Window(id: 4, symbol: Self.symbols[4])]),
            Column(id: 4, windows: [Window(id: 5, symbol: Self.symbols[5])]),
            Column(id: 5, windows: [Window(id: 6, symbol: Self.symbols[6])]),
            Column(id: 6, windows: [Window(id: 7, symbol: Self.symbols[7])])
        ]
        let ws1Symbols = Self.symbols
        let ws1: [Column] = (0..<4).map { i in
            Column(id: 100 + i, windows: [Window(id: 100 + i, symbol: ws1Symbols[i])])
        }
        let ws2Symbols = Self.symbols
        let ws2: [Column] = (0..<9).map { i in
            let symbol = ws2Symbols[(i + 2) % ws2Symbols.count]
            return Column(id: 200 + i, windows: [Window(id: 200 + i, symbol: symbol)])
        }
        workspaces = [
            Workspace(id: 0, label: "1", columns: ws0),
            Workspace(id: 1, label: "2", columns: ws1),
            Workspace(id: 2, label: "3", columns: ws2)
        ]
        columnIdSeed = 1000
        focusedColumnId = ws0.first?.id ?? 0
        focusedWindowId = ws0.first?.windows.first?.id ?? 0
    }

    private func nextColumnId() -> Int {
        columnIdSeed += 1
        return columnIdSeed
    }

    // MARK: Derived

    var currentWorkspace: Workspace { workspaces[currentWorkspaceIndex] }

    private var focusedColumnIndex: Int? {
        workspaces[currentWorkspaceIndex].columns.firstIndex { $0.id == focusedColumnId }
    }

    var contentWidth: CGFloat {
        CGFloat(max(currentWorkspace.columns.count, 1)) * slotWidth - columnSpacing
    }

    var maxScroll: CGFloat { max(0, contentWidth - viewportWidth) }

    func clampedScroll(_ x: CGFloat) -> CGFloat { min(max(x, 0), maxScroll) }

    /// The scroll value that centers `columnId` within the viewport, computed against `columns`
    /// (so callers can pass the post-mutation layout before committing it).
    private func scrollCentering(columns: [Column], columnId: Int) -> CGFloat {
        guard let i = columns.firstIndex(where: { $0.id == columnId }) else { return scrollX }
        let columnCenter = CGFloat(i) * slotWidth + columnWidth / 2
        return clampedScroll(columnCenter - viewportWidth / 2)
    }

    private func scrollCentering(columnId: Int) -> CGFloat {
        scrollCentering(columns: currentWorkspace.columns, columnId: columnId)
    }

    /// Applies focus + scroll changes inside a single animation transaction so the column
    /// highlight and the viewport track move in lockstep (not two desynced animations).
    /// During a live 3-finger drag, changes apply instantly — no animation.
    private func animateFocusIfNeeded(_ changes: () -> Void) {
        if isLiveDragging {
            changes()
        } else {
            withAnimation(.easeInOut(duration: 0.28), changes)
        }
    }

    private func ensureFocusedVisible() {
        let target = scrollCentering(columnId: focusedColumnId)
        guard abs(target - scrollX) > 0.5 else { return }
        animateFocusIfNeeded { self.scrollX = target }
    }

    // MARK: Focus

    func focusColumn(_ id: Int) {
        guard let col = currentWorkspace.columns.first(where: { $0.id == id }) else { return }
        let targetScroll = scrollCentering(columnId: id)
        animateFocusIfNeeded {
            focusedColumnId = id
            focusedWindowId = col.windows.first?.id ?? focusedWindowId
            scrollX = targetScroll
        }
    }

    /// Focuses a specific window within a column by stack index.
    func focusWindow(columnId: Int, index: Int) {
        guard let col = currentWorkspace.columns.first(where: { $0.id == columnId }) else { return }
        let clamped = min(max(index, 0), col.windows.count - 1)
        let targetScroll = scrollCentering(columnId: columnId)
        animateFocusIfNeeded {
            focusedColumnId = columnId
            focusedWindowId = col.windows.indices.contains(clamped) ? col.windows[clamped].id : focusedWindowId
            scrollX = targetScroll
        }
    }

    /// Hit-tests the canvas at `screenX`. Returns the column id and the window stack index
    /// under the point (so clicking a stacked window focuses that specific window, not just
    /// the top of the stack). `canvasWidth` is the drawn width; `scrollX` is the current scroll.
    /// The first column's left edge sits at `(canvasWidth - viewportWidth)/2 - scrollX`.
    func resolveHit(screenX: CGFloat, canvasWidth: CGFloat) -> (columnId: Int, windowIndex: Int)? {
        guard !currentWorkspace.columns.isEmpty else { return nil }
        let trackOriginX = (canvasWidth - viewportWidth) / 2 - scrollX
        let rel = screenX - trackOriginX
        let idx = Int(rel / slotWidth)
        let clampedIdx = min(max(idx, 0), currentWorkspace.columns.count - 1)
        let column = currentWorkspace.columns[clampedIdx]
        // Approximate window index from the vertical hit is handled by the caller (we only
        // get x here); default to the focused-or-first window in the resolved column.
        let windowIndex = column.windows.firstIndex(where: { $0.id == focusedWindowId }) ?? 0
        return (column.id, windowIndex)
    }

    /// Resolves a hit including the vertical position so stacked windows are individually
    /// selectable. `y` is relative to the track's vertical center.
    func resolveHit(screenX: CGFloat, screenY: CGFloat, canvasWidth: CGFloat, canvasHeight: CGFloat) -> (columnId: Int, windowIndex: Int)? {
        guard let xy = resolveHit(screenX: screenX, canvasWidth: canvasWidth) else { return nil }
        let column = currentWorkspace.columns.first(where: { $0.id == xy.columnId }) ?? currentWorkspace.columns[0]
        guard column.windows.count > 1 else { return xy }
        // Window tiles divide the column height; map y → stack index.
        let columnTop = (canvasHeight - columnHeight) / 2
        let relY = screenY - columnTop
        let available = columnHeight - 6 - CGFloat(column.windows.count - 1) * windowSpacing
        let tileHeight = available / CGFloat(column.windows.count)
        let idx = Int(relY / (tileHeight + windowSpacing))
        let clamped = min(max(idx, 0), column.windows.count - 1)
        return (xy.columnId, clamped)
    }

    func focusLeft() {
        guard let i = focusedColumnIndex, i > 0 else { return }
        focusColumn(currentWorkspace.columns[i - 1].id)
    }

    func focusRight() {
        guard let i = focusedColumnIndex, i < currentWorkspace.columns.count - 1 else { return }
        focusColumn(currentWorkspace.columns[i + 1].id)
    }

    func focusUp() {
        guard let col = currentWorkspace.columns.first(where: { $0.id == focusedColumnId }),
              let i = col.windows.firstIndex(where: { $0.id == focusedWindowId }),
              i > 0
        else { return }
        animateFocusIfNeeded { focusedWindowId = col.windows[i - 1].id }
    }

    func focusDown() {
        guard let col = currentWorkspace.columns.first(where: { $0.id == focusedColumnId }),
              let i = col.windows.firstIndex(where: { $0.id == focusedWindowId }),
              i < col.windows.count - 1
        else { return }
        animateFocusIfNeeded { focusedWindowId = col.windows[i + 1].id }
    }

    // MARK: Move (consume-or-expel)

    /// Niri move-left/right. A window that shares a column **expels** into its own new column
    /// (placed on the moved-toward side); a solo window **collocates** into the neighbour
    /// column (stacking), and its now-empty source column collapses.
    func moveFocusedWindow(direction: Int) {
        guard direction == -1 || direction == 1 else { return }
        guard let i = focusedColumnIndex else { return }
        var cols = currentWorkspace.columns
        guard let winIndex = cols[i].windows.firstIndex(where: { $0.id == focusedWindowId }) else { return }

        if cols[i].windows.count > 1 {
            // EXPEL: pull the focused window into a new solo column on the direction side.
            let window = cols[i].windows.remove(at: winIndex)
            let newColumn = Column(id: nextColumnId(), windows: [window])
            let insertIndex = direction == 1 ? i + 1 : i
            let clamped = min(max(insertIndex, 0), cols.count)
            cols.insert(newColumn, at: clamped)
            commitMove(columns: cols, focusedColumnId: newColumn.id, focusedWindowId: window.id)
        } else {
            // CONSUME: collocate into the neighbour column on the direction side; source collapses.
            let target = i + direction
            guard cols.indices.contains(target) else { return }
            let window = cols[i].windows[0]
            cols.remove(at: i)
            // After removing source at i, resolve the neighbour's new index:
            //  - direction == 1  (neighbour was i+1) → shifts down to i
            //  - direction == -1 (neighbour was i-1) → stays at i-1
            let resolvedTarget = direction == 1 ? i : i - 1
            cols[resolvedTarget].windows.append(window)
            commitMove(columns: cols, focusedColumnId: cols[resolvedTarget].id, focusedWindowId: window.id)
        }
    }

    /// Commits a move: structure change + focus + scroll all in one animation transaction so the
    /// reflow, highlight, and viewport track stay in sync.
    private func commitMove(columns: [Column], focusedColumnId: Int, focusedWindowId: Int) {
        let targetScroll = scrollCentering(columns: columns, columnId: focusedColumnId)
        animateFocusIfNeeded {
            workspaces[currentWorkspaceIndex].columns = columns
            self.focusedColumnId = focusedColumnId
            self.focusedWindowId = focusedWindowId
            scrollX = targetScroll
        }
    }

    // MARK: ⌥-drag column reorder

    func beginColumnDrag() {
        dragColumnId = focusedColumnId
        dragTranslation = 0
    }

    func updateDrag(relativeX: CGFloat) {
        dragTranslation = relativeX
    }

    func endColumnDrag() {
        guard let id = dragColumnId,
              let from = currentWorkspace.columns.firstIndex(where: { $0.id == id })
        else {
            cancelColumnDrag()
            return
        }
        let rawOffset = Int((dragTranslation / max(slotWidth, 1)).rounded())
        let to = min(max(from + rawOffset, 0), currentWorkspace.columns.count - 1)
        if to != from {
            let col = workspaces[currentWorkspaceIndex].columns.remove(at: from)
            workspaces[currentWorkspaceIndex].columns.insert(col, at: to)
        }
        cancelColumnDrag()
        ensureFocusedVisible()
    }

    func cancelColumnDrag() {
        dragColumnId = nil
        dragTranslation = 0
    }

    /// Reorders a column by `delta` positions (used by ⌥-scroll / ⌥-drag).
    func reorderColumn(columnId: Int, by delta: Int) {
        guard let from = currentWorkspace.columns.firstIndex(where: { $0.id == columnId }) else { return }
        let to = min(max(from + delta, 0), currentWorkspace.columns.count - 1)
        guard to != from else { return }
        let col = workspaces[currentWorkspaceIndex].columns.remove(at: from)
        workspaces[currentWorkspaceIndex].columns.insert(col, at: to)
        ensureFocusedVisible()
    }

    // MARK: Workspace

    func switchWorkspace(by delta: Int) {
        let next = currentWorkspaceIndex + delta
        guard workspaces.indices.contains(next) else { return }
        animateFocusIfNeeded {
            currentWorkspaceIndex = next
            scrollX = 0
            focusedColumnId = workspaces[next].columns.first?.id ?? focusedColumnId
            focusedWindowId = workspaces[next].columns.first?.windows.first?.id ?? focusedWindowId
        }
    }

    // MARK: Palette

    func togglePalette() { paletteOpen ? closePalette() : openPalette() }
    func openPalette() { paletteOpen = true; paletteSelection = 0 }
    func closePalette() { paletteOpen = false }

    func paletteSelectNext() {
        guard paletteOpen else { return }
        paletteSelection = (paletteSelection + 1) % paletteActions.count
    }

    func paletteSelectPrev() {
        guard paletteOpen else { return }
        paletteSelection = (paletteSelection - 1 + paletteActions.count) % paletteActions.count
    }

    func executePaletteSelection() {
        guard paletteOpen, paletteActions.indices.contains(paletteSelection) else { return }
        execute(paletteActions[paletteSelection].action)
    }

    func execute(_ action: String) {
        switch action {
        case "focus.left": focusLeft()
        case "focus.right": focusRight()
        case "focus.up": focusUp()
        case "focus.down": focusDown()
        case "move.left": moveFocusedWindow(direction: -1)
        case "move.right": moveFocusedWindow(direction: 1)
        case "move.up": moveFocusedWindowVertical(direction: -1)
        case "move.down": moveFocusedWindowVertical(direction: 1)
        case "ws.prev": switchWorkspace(by: -1)
        case "ws.next": switchWorkspace(by: 1)
        default: break
        }
        closePalette()
    }

    /// Moves the focused window up/down within its column stack (reorders the stack).
    func moveFocusedWindowVertical(direction: Int) {
        guard direction == -1 || direction == 1 else { return }
        guard let colIndex = focusedColumnIndex else { return }
        var cols = currentWorkspace.columns
        guard let winIndex = cols[colIndex].windows.firstIndex(where: { $0.id == focusedWindowId }) else { return }
        let target = winIndex + direction
        guard cols[colIndex].windows.indices.contains(target) else { return }
        cols[colIndex].windows.swapAt(winIndex, target)
        workspaces[currentWorkspaceIndex].columns = cols
    }
}

struct InteractiveMoveDemo: View {
    @StateObject private var model = MoveDemoModel()
    @State private var keyMonitor: Any?
    @State private var threeFingerGestureTap: ThreeFingerGestureTapController?

    var body: some View {
        VStack(spacing: 8) {
            canvas
            workspaceDots
            hint
        }
        .padding(.horizontal, 16)
        .onAppear { installKeyMonitor(); installThreeFingerGestureTap() }
        .onDisappear { removeKeyMonitor(); removeThreeFingerGestureTap() }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                HStack(spacing: model.columnSpacing) {
                    ForEach(model.currentWorkspace.columns) { column in
                        columnView(column)
                    }
                }
                // The ZStack centers this HStack at (w - contentWidth)/2. To make the
                // viewport act as a left-origin scroll window (scrollX=0 shows the leftmost
                // column, scrollX=maxScroll shows the rightmost), offset by maxScroll/2 so the
                // track's left edge starts at the viewport's left edge, then subtract scrollX.
                // Off-screen columns stay visible (dimmed by distance) — the dashed rectangle is
                // just an indicator of the scrollable viewport, not a clip mask.
                .offset(x: model.maxScroll / 2 - model.scrollX)
                .id(model.currentWorkspace.id)
                .animation(.easeInOut(duration: 0.28), value: model.currentWorkspace.id)
                .animation(.easeInOut(duration: 0.28), value: model.currentWorkspace.columns.count)

                viewportFrame

                if model.paletteOpen {
                    paletteOverlay(in: geo.size)
                }
            }
            .frame(width: w, height: geo.size.height)
            .contentShape(Rectangle())
            // Click to focus (native tap location via SpatialTapGesture). Uses the full 2D
            // point so stacked windows are individually selectable, not just the top of the stack.
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if let hit = model.resolveHit(
                            screenX: value.location.x,
                            screenY: value.location.y,
                            canvasWidth: w,
                            canvasHeight: geo.size.height
                        ) {
                            model.focusWindow(columnId: hit.columnId, index: hit.windowIndex)
                        }
                    }
            )
        }
        .frame(height: 140)
    }

    private var viewportFrame: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .frame(width: model.viewportWidth, height: model.columnHeight + 16)
            .allowsHitTesting(false)
            .overlay(alignment: .top) {
                Text("Visible Area")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: -9)
            }
    }

    private func columnView(_ column: MoveDemoModel.Column) -> some View {
        let isFocused = column.id == model.focusedColumnId
        let isDragging = column.id == model.dragColumnId
        return VStack(spacing: model.windowSpacing) {
            ForEach(column.windows) { window in
                windowTile(window,
                          focused: isFocused && window.id == model.focusedWindowId,
                          stackCount: column.windows.count)
            }
        }
        .padding(3)
        .frame(width: model.columnWidth, height: model.columnHeight)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.accentColor.opacity(0.18) : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2),
                            lineWidth: isFocused ? 1.5 : 0.75
                        )
                }
        }
        .offset(x: isDragging ? model.dragTranslation : 0)
        .scaleEffect(isDragging ? 1.04 : 1.0)
        .opacity(isDragging ? 0.9 : 1.0)
        .animation(.easeInOut(duration: 0.28), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: column.windows.count)
    }

    private func windowTile(_ window: MoveDemoModel.Window, focused: Bool, stackCount: Int) -> some View {
        let available = model.columnHeight - 6 - CGFloat(max(stackCount - 1, 0)) * model.windowSpacing
        let tileHeight = max(available / CGFloat(max(stackCount, 1)), 14)
        return ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(focused ? Color.accentColor.opacity(0.55) : Color.accentColor.opacity(0.28))
            Image(systemName: window.symbol)
                .font(.system(size: min(12, tileHeight * 0.5)))
                .foregroundStyle(.primary)
        }
        .frame(width: model.columnWidth - 8, height: tileHeight)
    }

    // MARK: Workspace dots

    private var workspaceDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, ws in
                let active = index == model.currentWorkspaceIndex
                Button {
                    let delta = index - model.currentWorkspaceIndex
                    if delta != 0 { model.switchWorkspace(by: delta) }
                } label: {
                    Text(ws.label)
                        .font(.caption2.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                        .frame(width: 18, height: 18)
                        .background(active ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var hint: some View {
        Text("Try it: three-finger swipe, click to focus, or use shortcuts")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
    }

    // MARK: Palette overlay

    private func paletteOverlay(in size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.25)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture { model.closePalette() }

            VStack(alignment: .leading, spacing: 1) {
                Text("Command Palette")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                ForEach(Array(model.paletteActions.enumerated()), id: \.element.id) { index, action in
                    let selected = index == model.paletteSelection
                    Button { model.execute(action.action) } label: {
                        HStack(spacing: 8) {
                            Text(action.title).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            Text(shortcut(for: action.bindingID))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 230)
            .padding(.bottom, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        }
        .frame(width: size.width, height: size.height)
        .transition(.opacity)
    }

    private func shortcut(for bindingID: String?) -> String {
        guard let bindingID,
              let binding = ActionCatalog.defaultHotkeyBindings().first(where: { $0.id == bindingID })?.binding,
              !binding.isUnassigned
        else { return "" }
        return binding.displayString
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if mods.contains(.command) && mods.contains(.option), Int(event.keyCode) == kVK_Space {
                model.togglePalette()
                return nil
            }

            if model.paletteOpen {
                switch Int(event.keyCode) {
                case kVK_Escape: model.closePalette(); return nil
                case kVK_UpArrow: model.paletteSelectPrev(); return nil
                case kVK_DownArrow: model.paletteSelectNext(); return nil
                case kVK_Return: model.executePaletteSelection(); return nil
                default: return event
                }
            }

            // Workspace switch: ⌃⌥⌘ ←/→
            if mods.contains(.control) && mods.contains(.option) && mods.contains(.command) {
                switch Int(event.keyCode) {
                case kVK_LeftArrow: model.switchWorkspace(by: -1); return nil
                case kVK_RightArrow: model.switchWorkspace(by: 1); return nil
                default: break
                }
            }

            // Focus: ⌥ ← → ↑ ↓   Move window: ⌥⇧ ← → ↑ ↓
            if mods.contains(.option) {
                let shift = mods.contains(.shift)
                switch Int(event.keyCode) {
                case kVK_LeftArrow:
                    if shift { model.moveFocusedWindow(direction: -1) } else { model.focusLeft() }
                    return nil
                case kVK_RightArrow:
                    if shift { model.moveFocusedWindow(direction: 1) } else { model.focusRight() }
                    return nil
                case kVK_UpArrow:
                    if shift { model.moveFocusedWindowVertical(direction: -1) } else { model.focusUp() }
                    return nil
                case kVK_DownArrow:
                    if shift { model.moveFocusedWindowVertical(direction: 1) } else { model.focusDown() }
                    return nil
                default: break
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    // MARK: 3-finger trackpad gesture

    private func installThreeFingerGestureTap() {
        removeThreeFingerGestureTap()
        let tap = ThreeFingerGestureTapController(
            onDelta: { [weak model] delta in
                guard let model, !model.paletteOpen else { return }
                model.isLiveDragging = true
                model.scrollX = model.clampedScroll(model.scrollX - delta)
            },
            onEnd: { [weak model] in
                // Gesture lifted → subsequent click/keyboard focus should animate, not jump.
                model?.isLiveDragging = false
            }
        )
        tap.start()
        threeFingerGestureTap = tap
    }

    private func removeThreeFingerGestureTap() {
        threeFingerGestureTap?.stop()
        threeFingerGestureTap = nil
        model.isLiveDragging = false
    }
}

/// Mirrors Nehir's real gesture input path for the onboarding demo: a listen-only HID event
/// tap receiving `.gesture` events, converted to `NSEvent` so we can inspect `allTouches()`.
/// Only exactly three active touches produce scroll deltas. Two-finger scroll-wheel events and
/// generic pan recognizers are intentionally ignored.
@MainActor
private final class ThreeFingerGestureTapController {
    private var gestureTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastAverageX: CGFloat?
    /// True while exactly three touches are active; cleared when the count drops below 3 so
    /// we can signal gesture end and let the host stop suppressing focus/move animations.
    private var inThreeFingerGesture = false

    private let onDelta: @MainActor (CGFloat) -> Void
    private let onEnd: @MainActor () -> Void
    private let multiplier: CGFloat = 1_000
    private let deadzone: CGFloat = 0.00025

    init(
        onDelta: @escaping @MainActor (CGFloat) -> Void,
        onEnd: @escaping @MainActor () -> Void = {}
    ) {
        self.onDelta = onDelta
        self.onEnd = onEnd
    }

    func start() {
        stop()
        let mask: CGEventMask = UInt64(NSEvent.EventTypeMask.gesture.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<ThreeFingerGestureTapController>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.gestureTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            controller.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        gestureTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        )

        if let gestureTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gestureTap, 0)
            if let runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CGEvent.tapEnable(tap: gestureTap, enable: true)
        }
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let gestureTap {
            CGEvent.tapEnable(tap: gestureTap, enable: false)
            self.gestureTap = nil
        }
        lastAverageX = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        guard type.rawValue == NSEvent.EventType.gesture.rawValue,
              let nsEvent = NSEvent(cgEvent: event)
        else { return }

        let activeTouches = nsEvent.allTouches().filter { touch in
            touch.phase != .ended && touch.phase != .cancelled
        }

        guard activeTouches.count == 3 else {
            lastAverageX = nil
            if inThreeFingerGesture {
                inThreeFingerGesture = false
                onEnd()
            }
            return
        }
        inThreeFingerGesture = true

        let averageX = activeTouches.reduce(CGFloat(0)) { partial, touch in
            partial + touch.normalizedPosition.x
        } / CGFloat(activeTouches.count)

        guard let previous = lastAverageX else {
            lastAverageX = averageX
            return
        }

        let rawDelta = averageX - previous
        lastAverageX = averageX
        guard abs(rawDelta) >= deadzone else { return }

        let delta = rawDelta * multiplier
        onDelta(delta)
    }
}
