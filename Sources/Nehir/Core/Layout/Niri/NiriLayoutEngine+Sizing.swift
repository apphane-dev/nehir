import AppKit
import Foundation

extension NiriLayoutEngine {
    private enum ResolvedPresetWidth {
        case tile(CGFloat)
        case window(CGFloat)
    }

    private enum ResizeWidthSource: String {
        case cachedWidth
        case resolvedSpec
        case presetCycle
        case fullWidthToggle
        case availableWidthExpansion
    }

    private func fmt(_ value: CGFloat?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.1f", value)
    }

    private func widthSpecDescription(_ width: ProportionalSize) -> String {
        switch width {
        case let .proportion(proportion):
            return String(format: "proportion(%.4f)", proportion)
        case let .fixed(width):
            return String(format: "fixed(%.1f)", width)
        }
    }

    private func windowWidthSnapshot(_ window: NiriWindow?) -> String {
        guard let window else { return "window=nil" }
        let maxWidth = window.constraints.maxSize.width > 0 ? fmt(window.constraints.maxSize.width) : "none"
        return [
            "window=\(window.token.windowId)",
            "resolved=\(fmt(window.resolvedWidth))",
            "frame=\(fmt(window.frame?.width))",
            "min=\(fmt(window.constraints.minSize.width))",
            "max=\(maxWidth)",
            "mode=\(window.sizingMode)"
        ].joined(separator: ",")
    }

    private func widthAnimationSnapshot(_ column: NiriContainer) -> String {
        let now = animationClock?.now() ?? CACurrentMediaTime()
        guard let animation = column.widthAnimation else {
            return "anim=none"
        }
        return [
            "animCurrent=\(fmt(CGFloat(animation.value(at: now))))",
            "animFrom=\(fmt(CGFloat(animation.from)))",
            "animTarget=\(fmt(CGFloat(animation.target)))",
            "animVelocity=\(fmt(CGFloat(animation.velocity(at: now))))",
            "targetWidth=\(fmt(column.targetWidth))"
        ].joined(separator: ",")
    }

    private func columnWidthSnapshot(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat,
        window: NiriWindow? = nil
    ) -> String {
        let currentSpec = column.isFullWidth ? ProportionalSize.proportion(1) : column.width
        let resolvedSpec = resolvedColumnPixels(
            currentSpec,
            for: column,
            workingFrame: workingFrame,
            gaps: gaps
        )
        let columnIndex = columnIndex(of: column, in: workspaceId).map(String.init) ?? "nil"
        return [
            "columnIndex=\(columnIndex)",
            "widthSpec=\(widthSpecDescription(column.width))",
            "effectiveSpec=\(widthSpecDescription(currentSpec))",
            "cached=\(fmt(column.cachedWidth))",
            "resolvedSpec=\(fmt(resolvedSpec))",
            "targetWidth=\(fmt(column.targetWidth))",
            "presetIdx=\(column.presetWidthIdx.map(String.init) ?? "nil")",
            "full=\(column.isFullWidth)",
            "manual=\(column.hasManualSingleWindowWidthOverride)",
            widthAnimationSnapshot(column),
            windowWidthSnapshot(window ?? column.activeWindow ?? column.windowNodes.first)
        ].joined(separator: " ")
    }

    private func traceResize(_ message: @autoclosure () -> String) {
        guard resizeTraceSink != nil || LayoutTrace.isEnabled else { return }
        let text = message()
        resizeTraceSink?(text)
        LayoutTrace.log("resizeTrace \(text)")
    }

    private func cachedWidthForResizeStart(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        if column.cachedWidth <= 0 {
            if let singleWindowContext = singleWindowLayoutContext(in: workspaceId),
               singleWindowContext.container === column
            {
                column.cachedWidth = resolvedSingleWindowRect(
                    for: singleWindowContext,
                    in: workingFrame,
                    scale: 1.0,
                    gaps: gaps
                ).width
            } else {
                column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
            }
        }

        return column.cachedWidth
    }

    private func tabOffset(for column: NiriContainer) -> CGFloat {
        column.isEffectivelyTabbed ? renderStyle.tabIndicatorWidth : 0
    }

    private func columnWidth(forWindowWidth windowWidth: CGFloat, in column: NiriContainer) -> CGFloat {
        windowWidth + tabOffset(for: column)
    }

    private func windowWidth(forColumnWidth columnWidth: CGFloat, in column: NiriContainer) -> CGFloat {
        max(0, columnWidth - tabOffset(for: column))
    }

    private func resolvedColumnPixels(
        _ width: ProportionalSize,
        for column: NiriContainer,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        let rawWidth: CGFloat = switch width {
        case let .proportion(proportion):
            ProportionalSize.resolveProportionalSpan(proportion, availableSpace: workingFrame.width, gaps: gaps)
        case let .fixed(fixed):
            fixed
        }

        let bounds = column.widthBounds()
        var result = max(bounds.min, rawWidth)
        if let maxWidth = bounds.max {
            result = min(result, max(maxWidth, bounds.min))
        }
        return result
    }

    private func resolvedPresetWidth(
        _ preset: PresetSize,
        for column: NiriContainer,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> ResolvedPresetWidth {
        switch preset.kind {
        case let .proportion(proportion):
            .tile(
                resolvedColumnPixels(
                    .proportion(proportion),
                    for: column,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            )
        case let .fixed(fixed):
            .window(fixed)
        }
    }

    private func currentWindowWidth(
        _ window: NiriWindow?,
        in column: NiriContainer,
        fallbackColumnWidth: CGFloat
    ) -> CGFloat {
        if let resolved = window?.resolvedWidth, resolved > 0 {
            return resolved
        }
        if let frameWidth = window?.frame?.width, frameWidth > 0 {
            return frameWidth
        }
        return windowWidth(forColumnWidth: fallbackColumnWidth, in: column)
    }

    private func columnWidthSpec(
        for change: NiriSizeChange,
        currentSpec: ProportionalSize,
        currentPixels: CGFloat,
        column: NiriContainer,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> ProportionalSize {
        switch change {
        case let .setFixed(fixed):
            let windowWidth = fixed.clamped(to: 1 ... NiriSizeChange.maxPixels)
            return .fixed(columnWidth(forWindowWidth: windowWidth, in: column))
        case let .setProportion(proportion):
            return .proportion((proportion / 100).clamped(to: 0 ... NiriSizeChange.maxProportion))
        case let .adjustFixed(delta):
            return .fixed((currentPixels + delta).clamped(to: 1 ... NiriSizeChange.maxPixels))
        case let .adjustProportion(delta):
            let currentProportion: CGFloat
            switch currentSpec {
            case let .proportion(proportion):
                currentProportion = proportion
            case .fixed:
                let full = workingFrame.width - gaps
                if full == 0 {
                    currentProportion = 1
                } else {
                    currentProportion = (currentPixels + gaps) / full
                }
            }
            return .proportion((currentProportion + delta / 100).clamped(to: 0 ... NiriSizeChange.maxProportion))
        }
    }

    private func applyColumnWidth(
        _ column: NiriContainer,
        width newWidth: ProportionalSize,
        presetIndex: Int?,
        previousWidth: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        commandId: UInt64? = nil,
        commandKind: String? = nil,
        source: ResizeWidthSource? = nil,
        targetWindow: NiriWindow? = nil
    ) {
        cancelInteractiveResize(for: column, in: workspaceId)

        column.width = newWidth
        column.presetWidthIdx = presetIndex
        column.isFullWidth = false
        column.savedWidth = nil
        column.hasManualSingleWindowWidthOverride = true

        let targetPixels = resolvedColumnPixels(
            newWidth,
            for: column,
            workingFrame: workingFrame,
            gaps: gaps
        )

        let beforeAnimation = widthAnimationSnapshot(column)
        let didStartWidthAnimation = column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate,
            animated: motion.animationsEnabled
        )
        if let commandId, let commandKind, let source {
            traceResize(
                "cmd=\(commandId) apply kind=\(commandKind) source=\(source.rawValue) "
                    + "previous=\(fmt(previousWidth)) targetPixels=\(fmt(targetPixels)) "
                    + "newSpec=\(widthSpecDescription(newWidth)) presetIdx=\(presetIndex.map(String.init) ?? "nil") "
                    + "animations=\(motion.animationsEnabled) didStartAnimation=\(didStartWidthAnimation) "
                    + "beforeAnim{\(beforeAnimation)} after{\(columnWidthSnapshot(column, in: workspaceId, workingFrame: workingFrame, gaps: gaps, window: targetWindow))}"
            )
        }

        ensureSelectionVisibleForPendingWidth(
            column,
            targetWidth: targetPixels,
            previousWidth: previousWidth,
            restorePreviousWidthAfterFit: didStartWidthAnimation,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    private func ensureSelectionVisibleForPendingWidth(
        _ column: NiriContainer,
        targetWidth: CGFloat,
        previousWidth: CGFloat,
        restorePreviousWidthAfterFit: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard let window = column.windowNodes.first else { return }

        func revealTargetWidth() {
            ensureSelectionVisible(
                node: window,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            ensureColumnWidthVisible(
                column,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }

        if restorePreviousWidthAfterFit {
            column.cachedWidth = targetWidth
            defer { column.cachedWidth = previousWidth }
            revealTargetWidth()
        } else {
            column.cachedWidth = targetWidth
            revealTargetWidth()
        }
    }

    private func ensureColumnWidthVisible(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        let columns = self.columns(in: workspaceId)
        guard let columnIndex = columnIndex(of: column, in: workspaceId) else { return }
        let context = makeViewportSnapContext(columns: columns, state: state, workingFrame: workingFrame, gaps: gaps)
        let viewStart = context.currentViewStart(in: state)
        guard case .fullyVisible = context.visibility(of: columnIndex, viewportOffset: viewStart, in: state) else {
            guard let targetSnap = context.snapPoints(for: columnIndex).closest(to: viewStart) else { return }
            state.animateToOffset(
                context.targetOffset(for: targetSnap, in: state),
                motion: motion,
                scale: displayScale(in: workspaceId)
            )
            return
        }
    }

    private func cancelInteractiveResize(
        for column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let resize = interactiveResize, resize.workspaceId == workspaceId else { return }
        guard let resizeWindow = findNode(by: resize.windowId) as? NiriWindow,
              let resizeColumn = findColumn(containing: resizeWindow, in: workspaceId),
              resizeColumn === column
        else {
            return
        }

        clearInteractiveResize()
    }

    func calculateVerticalPixelsPerWeightUnit(
        column: NiriContainer,
        monitorFrame: CGRect,
        gaps: LayoutGaps
    ) -> CGFloat {
        let windows = column.children
        guard !windows.isEmpty else { return 0 }

        let totalWeight = windows.reduce(CGFloat(0)) { $0 + $1.size }
        guard totalWeight > 0 else { return 0 }

        let totalGaps = CGFloat(windows.count + 1) * gaps.vertical
        let usableHeight = monitorFrame.height - totalGaps

        return usableHeight / totalWeight
    }

    func setWindowSizingMode(
        _ window: NiriWindow,
        motion: MotionSnapshot,
        mode: SizingMode,
        state: inout ViewportState
    ) {
        let previousMode = window.sizingMode

        if previousMode == mode {
            return
        }

        if previousMode == .fullscreen, mode == .normal {
            if let savedHeight = window.savedHeight {
                window.height = savedHeight
                window.savedHeight = nil
            }

            if let savedOffset = state.viewOffsetToRestore {
                state.animateViewOffsetRestore(savedOffset, motion: motion)
            }
        }

        if previousMode == .normal, mode == .fullscreen {
            window.savedHeight = window.height
            state.saveViewOffsetForFullscreen()
            window.stopMoveAnimations()
        }

        window.sizingMode = mode
    }

    func toggleFullscreen(
        _ window: NiriWindow,
        motion: MotionSnapshot,
        state: inout ViewportState
    ) {
        let newMode: SizingMode = window.sizingMode == .fullscreen ? .normal : .fullscreen
        setWindowSizingMode(window, motion: motion, mode: newMode, state: &state)
    }

    func toggleColumnWidth(
        _ column: NiriContainer,
        forwards: Bool,
        targetWindow: NiriWindow? = nil,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard !presetColumnWidths.isEmpty else { return }
        let commandId = nextResizeCommandId()
        let commandKind = "toggleColumnWidth(\(forwards ? "forward" : "backward"))"

        let previousWidth = cachedWidthForResizeStart(
            column,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        )

        let presetCount = presetColumnWidths.count
        let targetWindow = targetWindow ?? column.activeWindow ?? column.windowNodes.first

        let nextIdx: Int
        let wrappedPresetBoundary: Bool
        if !column.isFullWidth, let currentIdx = column.presetWidthIdx {
            let rawNextIdx = forwards ? currentIdx + 1 : currentIdx - 1
            wrappedPresetBoundary = rawNextIdx < 0 || rawNextIdx >= presetCount
            nextIdx = (rawNextIdx + presetCount) % presetCount
        } else {
            wrappedPresetBoundary = false
            let currentTile: CGFloat
            if let singleWindowContext = singleWindowLayoutContext(in: workspaceId),
               singleWindowContext.container === column,
               !column.hasManualSingleWindowWidthOverride
            {
                currentTile = resolvedColumnPixels(
                    column.width,
                    for: column,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            } else {
                currentTile = previousWidth
            }
            let currentWindow = currentWindowWidth(
                targetWindow,
                in: column,
                fallbackColumnWidth: currentTile
            )

            if forwards {
                nextIdx = presetColumnWidths.firstIndex { preset in
                    switch resolvedPresetWidth(preset, for: column, workingFrame: workingFrame, gaps: gaps) {
                    case let .tile(resolved):
                        currentTile + 1 < resolved
                    case let .window(resolved):
                        currentWindow + 1 < resolved
                    }
                } ?? (presetCount - 1)
            } else {
                let matchingIndex = presetColumnWidths.lastIndex { preset in
                    switch resolvedPresetWidth(preset, for: column, workingFrame: workingFrame, gaps: gaps) {
                    case let .tile(resolved):
                        resolved + 1 < currentTile
                    case let .window(resolved):
                        resolved + 1 < currentWindow
                    }
                }
                nextIdx = matchingIndex ?? 0
            }
        }

        let currentSpec = column.isFullWidth ? ProportionalSize.proportion(1) : column.width
        let newWidth = columnWidthSpec(
            for: NiriSizeChange(presetColumnWidths[nextIdx]),
            currentSpec: currentSpec,
            currentPixels: previousWidth,
            column: column,
            workingFrame: workingFrame,
            gaps: gaps
        )
        traceResize(
            "cmd=\(commandId) compute kind=\(commandKind) source=\(ResizeWidthSource.presetCycle.rawValue) "
                + "previous=\(fmt(previousWidth)) currentSpec=\(widthSpecDescription(currentSpec)) "
                + "wrappedBoundary=\(wrappedPresetBoundary) nextPreset=\(nextIdx) newSpec=\(widthSpecDescription(newWidth)) "
                + "state{\(columnWidthSnapshot(column, in: workspaceId, workingFrame: workingFrame, gaps: gaps, window: targetWindow))}"
        )

        applyColumnWidth(
            column,
            width: newWidth,
            presetIndex: nextIdx,
            previousWidth: previousWidth,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            commandId: commandId,
            commandKind: commandKind,
            source: .presetCycle,
            targetWindow: targetWindow
        )
    }

    func toggleWindowWidth(
        _ window: NiriWindow,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard let column = findColumn(containing: window, in: workspaceId) else { return }
        toggleColumnWidth(
            column,
            forwards: forwards,
            targetWindow: window,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func setColumnWidth(
        _ column: NiriContainer,
        change: NiriSizeChange,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        commandKind: String = "setColumnWidth",
        targetWindow: NiriWindow? = nil
    ) {
        let commandId = nextResizeCommandId()
        let previousWidth = cachedWidthForResizeStart(
            column,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        )
        let currentSpec = column.isFullWidth ? ProportionalSize.proportion(1) : column.width
        let currentPixels = resolvedColumnPixels(
            currentSpec,
            for: column,
            workingFrame: workingFrame,
            gaps: gaps
        )
        let newWidth = columnWidthSpec(
            for: change,
            currentSpec: currentSpec,
            currentPixels: currentPixels,
            column: column,
            workingFrame: workingFrame,
            gaps: gaps
        )
        traceResize(
            "cmd=\(commandId) compute kind=\(commandKind) change=\(change) source=\(ResizeWidthSource.resolvedSpec.rawValue) "
                + "previous=\(fmt(previousWidth)) currentPixels=\(fmt(currentPixels)) "
                + "currentSpec=\(widthSpecDescription(currentSpec)) newSpec=\(widthSpecDescription(newWidth)) "
                + "state{\(columnWidthSnapshot(column, in: workspaceId, workingFrame: workingFrame, gaps: gaps, window: targetWindow))}"
        )

        applyColumnWidth(
            column,
            width: newWidth,
            presetIndex: nil,
            previousWidth: previousWidth,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            commandId: commandId,
            commandKind: commandKind,
            source: .resolvedSpec,
            targetWindow: targetWindow
        )
    }

    func setWindowWidth(
        _ window: NiriWindow,
        change: NiriSizeChange,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard let column = findColumn(containing: window, in: workspaceId) else { return }
        setColumnWidth(
            column,
            change: change,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            commandKind: "setWindowWidth",
            targetWindow: window
        )
    }

    func toggleFullWidth(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        let commandId = nextResizeCommandId()
        let commandKind = "toggleFullWidth"
        let workingAreaWidth = workingFrame.width
        let previousWidth = cachedWidthForResizeStart(
            column,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        )
        let targetPixels: CGFloat
        cancelInteractiveResize(for: column, in: workspaceId)

        if column.isFullWidth {
            column.isFullWidth = false
            if let saved = column.savedWidth {
                column.width = saved
                column.savedWidth = nil
            }
            column.hasManualSingleWindowWidthOverride = true
            switch column.width {
            case .proportion(let p):
                targetPixels = ProportionalSize.resolveProportionalSpan(p, availableSpace: workingAreaWidth, gaps: gaps)
            case .fixed(let f):
                targetPixels = f
            }
        } else {
            column.savedWidth = column.width
            column.isFullWidth = true
            column.presetWidthIdx = nil
            column.hasManualSingleWindowWidthOverride = true
            targetPixels = resolvedColumnPixels(.proportion(1), for: column, workingFrame: workingFrame, gaps: gaps)
        }

        traceResize(
            "cmd=\(commandId) compute kind=\(commandKind) source=\(ResizeWidthSource.fullWidthToggle.rawValue) "
                + "previous=\(fmt(previousWidth)) targetPixels=\(fmt(targetPixels)) "
                + "state{\(columnWidthSnapshot(column, in: workspaceId, workingFrame: workingFrame, gaps: gaps))}"
        )
        let beforeAnimation = widthAnimationSnapshot(column)
        let didStartWidthAnimation = column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate,
            animated: motion.animationsEnabled
        )
        traceResize(
            "cmd=\(commandId) apply kind=\(commandKind) source=\(ResizeWidthSource.fullWidthToggle.rawValue) "
                + "previous=\(fmt(previousWidth)) targetPixels=\(fmt(targetPixels)) "
                + "animations=\(motion.animationsEnabled) didStartAnimation=\(didStartWidthAnimation) "
                + "beforeAnim{\(beforeAnimation)} after{\(columnWidthSnapshot(column, in: workspaceId, workingFrame: workingFrame, gaps: gaps))}"
        )

        ensureSelectionVisibleForPendingWidth(
            column,
            targetWidth: targetPixels,
            previousWidth: previousWidth,
            restorePreviousWidthAfterFit: didStartWidthAnimation,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func expandColumnToAvailableWidth(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard !column.isFullWidth else { return }
        guard column.windowNodes.allSatisfy({ $0.sizingMode == .normal }) else { return }

        let columns = self.columns(in: workspaceId)
        guard let activeColumnIndex = columnIndex(of: column, in: workspaceId) else { return }

        for candidate in columns where candidate.cachedWidth <= 0 {
            candidate.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
        }

        let viewX = state.columnX(
            at: state.activeColumnIndex.clamped(to: 0 ... max(0, columns.count - 1)),
            columns: columns,
            gap: gaps
        ) + state.viewOffsetPixels.target()

        var widthTaken: CGFloat = 0
        var leftmostColX: CGFloat?
        var activeColX: CGFloat?
        var activeColumnWasFullyVisible = false
        var countedNonActiveColumn = false

        for idx in columns.indices {
            let colX = state.columnX(at: idx, columns: columns, gap: gaps)
            if colX < viewX + gaps {
                continue
            }

            if leftmostColX == nil {
                leftmostColX = colX
            }

            let width = columns[idx].cachedWidth
            if viewX + workingFrame.width < colX + width + gaps {
                break
            }

            if idx == activeColumnIndex {
                activeColumnWasFullyVisible = true
                activeColX = colX
            } else {
                countedNonActiveColumn = true
            }

            widthTaken += width + gaps
        }

        guard activeColumnWasFullyVisible else { return }

        let availableWidth = workingFrame.width - gaps - widthTaken
        guard availableWidth > 0 else { return }

        if !countedNonActiveColumn {
            toggleFullWidth(
                column,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            return
        }

        guard let leftmostColX, let activeColX else { return }

        let commandId = nextResizeCommandId()
        let commandKind = "expandColumnToAvailableWidth"
        let previousWidth = cachedWidthForResizeStart(
            column,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        )
        let targetWidth = (column.cachedWidth + availableWidth).clamped(to: 1 ... NiriSizeChange.maxPixels)
        traceResize(
            "cmd=\(commandId) compute kind=\(commandKind) source=\(ResizeWidthSource.availableWidthExpansion.rawValue) "
                + "previous=\(fmt(previousWidth)) available=\(fmt(availableWidth)) target=\(fmt(targetWidth)) "
                + "viewX=\(fmt(viewX)) activeColX=\(fmt(activeColX)) leftmostColX=\(fmt(leftmostColX)) "
                + "state{\(columnWidthSnapshot(column, in: workspaceId, workingFrame: workingFrame, gaps: gaps))}"
        )
        applyColumnWidth(
            column,
            width: .fixed(targetWidth),
            presetIndex: nil,
            previousWidth: previousWidth,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            commandId: commandId,
            commandKind: commandKind,
            source: .availableWidthExpansion
        )

        let context = makeViewportSnapContext(columns: columns, state: state, workingFrame: workingFrame, gaps: gaps)
        let targetOffset = context.targetOffset(
            forViewportStart: leftmostColX - gaps,
            activeColumnIndex: state.activeColumnIndex.clamped(to: 0 ... max(0, columns.count - 1)),
            in: state
        )
        state.animateToOffset(
            targetOffset,
            motion: motion,
            scale: displayScale(in: workspaceId)
        )
    }

    private func currentWindowHeight(_ window: NiriWindow) -> CGFloat {
        switch window.height {
        case let .fixed(height):
            height
        case .auto,
             .preset:
            window.resolvedHeight ?? window.frame?.height ?? max(1, window.heightWeight)
        }
    }

    private func convertHeightsToAuto(in column: NiriContainer) {
        let windows = column.windowNodes
        guard !windows.isEmpty else { return }

        let heights = windows.map { max(1, $0.resolvedHeight ?? $0.frame?.height ?? $0.heightWeight) }
        let median = max(1, heights.sorted()[heights.count / 2])

        for (window, height) in zip(windows, heights) {
            window.height = .auto(weight: height / median)
        }
    }

    private func resolvedPresetHeight(
        _ preset: PresetSize,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        switch preset.kind {
        case let .proportion(proportion):
            ProportionalSize.resolveProportionalSpan(proportion, availableSpace: workingFrame.height, gaps: gaps)
        case let .fixed(fixed):
            fixed
        }
    }

    func setWindowHeight(
        _ window: NiriWindow,
        change: NiriSizeChange,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard let column = findColumn(containing: window, in: workspaceId) else { return }
        cancelInteractiveResize(for: column, in: workspaceId)

        if window.height.isAuto {
            convertHeightsToAuto(in: column)
        }

        let currentWindowPixels = currentWindowHeight(window)
        let full = workingFrame.height - gaps
        let currentProportion = full == 0 ? 1 : (currentWindowPixels + gaps) / full

        var windowHeight: CGFloat = switch change {
        case let .setFixed(fixed):
            fixed
        case let .setProportion(proportion):
            ProportionalSize.resolveProportionalSpan(proportion / 100, availableSpace: workingFrame.height, gaps: gaps)
        case let .adjustFixed(delta):
            currentWindowPixels + delta
        case let .adjustProportion(delta):
            ProportionalSize.resolveProportionalSpan(currentProportion + delta / 100, availableSpace: workingFrame.height, gaps: gaps)
        }

        let minHeightTaken: CGFloat
        if column.isEffectivelyTabbed {
            minHeightTaken = 0
        } else {
            minHeightTaken = column.windowNodes
                .filter { $0 !== window }
                .reduce(CGFloat(0)) { partial, otherWindow in
                    partial + max(1, otherWindow.constraints.minSize.height) + gaps
                }
        }

        let heightLeft = max(1, workingFrame.height - minHeightTaken)
        windowHeight = min(heightLeft, windowHeight)
        windowHeight = window.constraints.clampHeight(windowHeight)
        window.height = .fixed(windowHeight.clamped(to: 1 ... NiriSizeChange.maxPixels))
        window.savedHeight = nil
        if window.sizingMode == .maximized {
            window.sizingMode = .normal
        }
    }

    func resetWindowHeight(
        _ window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let column = findColumn(containing: window, in: workspaceId) else { return }
        cancelInteractiveResize(for: column, in: workspaceId)

        if column.isEffectivelyTabbed {
            for tile in column.windowNodes {
                tile.height = .auto(weight: 1)
                tile.savedHeight = nil
            }
        } else {
            window.height = .auto(weight: 1)
            window.savedHeight = nil
        }
    }

    func toggleWindowHeight(
        _ window: NiriWindow,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        guard !presetWindowHeights.isEmpty else { return }
        guard let column = findColumn(containing: window, in: workspaceId) else { return }
        cancelInteractiveResize(for: column, in: workspaceId)

        if window.height.isAuto {
            convertHeightsToAuto(in: column)
        }

        let presetCount = presetWindowHeights.count
        let nextIdx: Int
        switch window.height {
        case let .preset(currentIdx) where window.sizingMode != .maximized:
            if forwards {
                nextIdx = (currentIdx + 1) % presetCount
            } else {
                nextIdx = (currentIdx - 1 + presetCount) % presetCount
            }
        default:
            let current = currentWindowHeight(window)
            if forwards {
                nextIdx = presetWindowHeights.firstIndex { preset in
                    current + 1 < resolvedPresetHeight(preset, workingFrame: workingFrame, gaps: gaps)
                } ?? 0
            } else {
                nextIdx = presetWindowHeights.lastIndex { preset in
                    resolvedPresetHeight(preset, workingFrame: workingFrame, gaps: gaps) + 1 < current
                } ?? (presetCount - 1)
            }
        }

        window.height = .preset(nextIdx)
        window.savedHeight = nil
        if window.sizingMode == .maximized {
            window.sizingMode = .normal
        }
    }
}

private extension NiriSizeChange {
    init(_ preset: PresetSize) {
        switch preset.kind {
        case let .proportion(proportion):
            self = .setProportion(proportion * 100)
        case let .fixed(fixed):
            self = .setFixed(fixed)
        }
    }
}
