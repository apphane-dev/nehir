import AppKit
import Foundation

enum RevealPartial: String, CaseIterable, Codable, Identifiable {
    case `default`
    case off
    case snapClosest
    case snapCenter

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .default: "Default"
        case .off: "Off"
        case .snapClosest: "Snap Closest"
        case .snapCenter: "Snap Center"
        }
    }
}

enum LoneWindowPolicy: Equatable, Identifiable, Codable {
    case fill
    case centered(maxWidthFraction: Double)

    var id: String {
        switch self {
        case .fill: "fill"
        case .centered: "centered"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, maxWidthFraction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "fill":
            self = .fill
        case "centered":
            self = .centered(maxWidthFraction: try container.decode(Double.self, forKey: .maxWidthFraction))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown lone window policy \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fill:
            try container.encode("fill", forKey: .kind)
        case let .centered(maxWidthFraction):
            try container.encode("centered", forKey: .kind)
            try container.encode(maxWidthFraction, forKey: .maxWidthFraction)
        }
    }
}

enum DefaultColumnWidth: Equatable {
    case balanced(columns: Int)
    case custom(fraction: Double)

    var fraction: Double {
        switch self {
        case let .balanced(columns): 1.0 / Double(max(1, columns))
        case let .custom(fraction): fraction
        }
    }
}

struct WorkingAreaContext {
    var workingFrame: CGRect
    var viewFrame: CGRect
    var scale: CGFloat
}

struct Struts {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static let zero = Struts()
}

func computeWorkingArea(
    parentArea: CGRect,
    scale: CGFloat,
    struts: Struts
) -> CGRect {
    var workingArea = parentArea

    workingArea.size.width = max(0, workingArea.size.width - struts.left - struts.right)
    workingArea.origin.x += struts.left

    workingArea.size.height = max(0, workingArea.size.height - struts.top - struts.bottom)
    workingArea.origin.y += struts.bottom

    let physicalX = ceil(workingArea.origin.x * scale) / scale
    let physicalY = ceil(workingArea.origin.y * scale) / scale

    let xDiff = min(workingArea.size.width, physicalX - workingArea.origin.x)
    let yDiff = min(workingArea.size.height, physicalY - workingArea.origin.y)

    workingArea.size.width -= xDiff
    workingArea.size.height -= yDiff
    workingArea.origin.x = physicalX
    workingArea.origin.y = physicalY

    return workingArea
}

struct NiriRenderStyle {
    var tabIndicatorWidth: CGFloat

    static let `default` = NiriRenderStyle(
        tabIndicatorWidth: 0
    )
}

final class NiriLayoutEngine {
    static let defaultPresetColumnWidthValues: [CGFloat] = [0.35, 0.50, 0.65, 0.95]
    static let defaultPresetColumnWidths: [PresetSize] = defaultPresetColumnWidthValues.map { .proportion($0) }
    static let defaultPresetWindowHeightValues: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    static let defaultPresetWindowHeights: [PresetSize] = defaultPresetWindowHeightValues.map { .proportion($0) }
    private static let presetMatchTolerance: CGFloat = 0.001

    var monitors: [Monitor.ID: NiriMonitor] = [:]
    var workspaceMonitorIndex: [WorkspaceDescriptor.ID: Monitor.ID] = [:]

    var roots: [WorkspaceDescriptor.ID: NiriRoot] = [:]

    var tokenToNode: [WindowToken: NiriWindow] = [:]

    var closingTokens: Set<WindowToken> = []

    var framePool: [WindowToken: CGRect] = [:]
    var hiddenPool: [WindowToken: HideSide] = [:]

    var balancedColumnCount: Int
    var infiniteLoop: Bool

    var revealPartial: RevealPartial = .default

    var loneWindowPolicy: LoneWindowPolicy = .fill

    var renderStyle: NiriRenderStyle = .default

    var interactiveResize: InteractiveResize?
    var interactiveMove: InteractiveMove?

    var resizeConfiguration = ResizeConfiguration.default
    var moveConfiguration = MoveConfiguration.default

    var windowMovementAnimationConfig: SpringConfig = .niriWindowMovement
    var animationClock: AnimationClock?
    var displayRefreshRate: Double = 60.0

    var presetColumnWidths: [PresetSize] = NiriLayoutEngine.defaultPresetColumnWidths
    var presetWindowHeights: [PresetSize] = NiriLayoutEngine.defaultPresetWindowHeights
    var defaultColumnWidth: CGFloat? = nil

    var resizeTraceSink: ((String) -> Void)?
    private(set) var resizeCommandGeneration: UInt64 = 0

    func nextResizeCommandId() -> UInt64 {
        resizeCommandGeneration += 1
        return resizeCommandGeneration
    }

    init(balancedColumnCount: Int = 2, infiniteLoop: Bool = false) {
        self.balancedColumnCount = max(1, min(5, balancedColumnCount))
        self.infiniteLoop = infiniteLoop
    }

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot {
        if let existing = roots[workspaceId] {
            return existing
        }
        let root = NiriRoot(workspaceId: workspaceId)
        roots[workspaceId] = root
        return root
    }

    func claimEmptyColumnIfWorkspaceEmpty(in root: NiriRoot) -> NiriContainer? {
        guard root.allWindows.isEmpty else { return nil }

        let emptyColumns = root.columns.filter(\.children.isEmpty)
        guard let target = emptyColumns.first else { return nil }

        for column in emptyColumns.dropFirst() {
            column.remove()
        }

        return target
    }

    func removeEmptyColumnsIfWorkspaceEmpty(in root: NiriRoot) {
        guard root.allWindows.isEmpty else { return }

        let emptyColumns = root.columns.filter(\.children.isEmpty)
        for column in emptyColumns {
            column.remove()
        }
    }

    func resolvedColumnResetWidth(in workspaceId: WorkspaceDescriptor
        .ID) -> (proportion: CGFloat, presetWidthIdx: Int?)
    {
        let resolvedDefaultColumnWidth = effectiveDefaultColumnWidth(in: workspaceId)
        let width = CGFloat(resolvedDefaultColumnWidth.fraction)
        switch resolvedDefaultColumnWidth {
        case .custom:
            return (width, matchingPresetIndex(for: width))
        case .balanced:
            return (width, nil)
        }
    }

    func initializeNewColumnWidth(_ column: NiriContainer, in workspaceId: WorkspaceDescriptor.ID) {
        let resolvedWidth = resolvedColumnResetWidth(in: workspaceId)
        column.width = .proportion(resolvedWidth.proportion)
        column.presetWidthIdx = resolvedWidth.presetWidthIdx

        column.cachedWidth = 0
        column.isFullWidth = false
        column.savedWidth = nil
        column.hasManualSingleWindowWidthOverride = false
        column.widthAnimation = nil
        column.targetWidth = nil
    }

    private func matchingPresetIndex(for width: CGFloat) -> Int? {
        presetColumnWidths.firstIndex { preset in
            guard case let .proportion(presetWidth) = preset.kind else { return false }
            return abs(presetWidth - width) <= Self.presetMatchTolerance
        }
    }

    func root(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot? {
        roots[workspaceId]
    }

    func columns(in workspaceId: WorkspaceDescriptor.ID) -> [NiriContainer] {
        guard let root = roots[workspaceId] else { return [] }
        return root.columns
    }

    struct SingleWindowLayoutContext {
        let container: NiriContainer
        let window: NiriWindow
        let maxWidthFraction: Double
    }

    func singleWindowLayoutContext(in workspaceId: WorkspaceDescriptor.ID) -> SingleWindowLayoutContext? {
        let maxWidthFraction: Double = switch effectiveLoneWindowPolicy(in: workspaceId) {
        case .fill: 1.0
        case let .centered(maxWidthFraction): maxWidthFraction
        }

        let workspaceColumns = columns(in: workspaceId)
        guard workspaceColumns.count == 1,
              let column = workspaceColumns.first,
              !column.isTabbed
        else {
            return nil
        }

        let windows = column.windowNodes
        guard windows.count == 1,
              let window = windows.first,
              window.sizingMode == .normal
        else {
            return nil
        }

        return SingleWindowLayoutContext(
            container: column,
            window: window,
            maxWidthFraction: maxWidthFraction
        )
    }

    func loneWindowIntentionallyDoesNotFillViewport(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard singleWindowLayoutContext(in: workspaceId) != nil,
              case let .centered(maxWidthFraction) = effectiveLoneWindowPolicy(in: workspaceId)
        else {
            return false
        }
        return maxWidthFraction < 1.0
    }

    func wrapIndex(_ idx: Int, total: Int, in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        guard total > 0 else { return nil }
        if effectiveInfiniteLoop(in: workspaceId) {
            let modulo = total
            return ((idx % modulo) + modulo) % modulo
        } else {
            return (idx >= 0 && idx < total) ? idx : nil
        }
    }

    func findNode(by id: NodeId) -> NiriNode? {
        for root in roots.values {
            if let found = root.findNode(by: id) {
                return found
            }
        }
        return nil
    }

    func findNode(for token: WindowToken) -> NiriWindow? {
        tokenToNode[token]
    }

    func findNode(for handle: WindowHandle) -> NiriWindow? {
        findNode(for: handle.id)
    }

    func column(of node: NiriNode) -> NiriContainer? {
        var current = node
        while let parent = current.parent {
            if parent is NiriRoot {
                return current as? NiriContainer
            }
            current = parent
        }
        return nil
    }

    func columnIndex(of column: NiriNode, in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        columns(in: workspaceId).firstIndex { $0 === column }
    }

    func activateWindow(_ nodeId: NodeId) {
        guard let node = findNode(by: nodeId),
              let col = column(of: node) else { return }
        let windowNodes = col.windowNodes
        let idx = windowNodes.firstIndex(where: { $0.id == nodeId }) ?? 0
        col.setActiveTileIdx(idx)
    }

    func columnX(at index: Int, columns: [NiriContainer], gaps: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        for i in 0 ..< index where i < columns.count {
            x += columns[i].cachedWidth + gaps
        }
        return x
    }

    func findColumn(containing window: NiriWindow, in workspaceId: WorkspaceDescriptor.ID) -> NiriContainer? {
        guard let col = column(of: window),
              let root = col.parent as? NiriRoot,
              roots[workspaceId]?.id == root.id else { return nil }
        return col
    }

    func updateConfiguration(
        balancedColumnCount: Int? = nil,
        infiniteLoop: Bool? = nil,
        revealPartial: RevealPartial? = nil,
        loneWindowPolicy: LoneWindowPolicy? = nil,
        presetColumnWidths: [PresetSize]? = nil,
        defaultColumnWidth: CGFloat?? = nil
    ) {
        if let max = balancedColumnCount {
            self.balancedColumnCount = max.clamped(to: 1 ... 5)
        }
        if let loop = infiniteLoop {
            self.infiniteLoop = loop
        }
        if let revealPartial {
            self.revealPartial = revealPartial
        }
        if let loneWindowPolicy {
            self.loneWindowPolicy = loneWindowPolicy
        }
        // Double optional distinguishes "no config change" from "set Auto/nil".
        if let defaultColumnWidth {
            self.defaultColumnWidth = defaultColumnWidth?.clamped(to: 0.05 ... 1.0)
        }

        if let presets = presetColumnWidths, !presets.isEmpty {
            self.presetColumnWidths = presets
            resetAllPresetWidthIndices()
        }
    }

    func invalidateCachedLayoutSpans() {
        for root in roots.values {
            for child in root.children {
                guard let column = child as? NiriContainer else { continue }
                column.cachedWidth = 0
                column.cachedHeight = 0
            }
        }
    }

    private func resetAllPresetWidthIndices() {
        for root in roots.values {
            for child in root.children {
                if let column = child as? NiriContainer {
                    column.presetWidthIdx = nil
                }
            }
        }
    }
}
