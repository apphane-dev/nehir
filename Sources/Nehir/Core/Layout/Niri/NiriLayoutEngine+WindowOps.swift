import AppKit
import Foundation

extension NiriLayoutEngine {
    func moveWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        switch direction {
        case .down,
             .up:
            switch pureLayoutMovePlan(node, direction: direction, in: workspaceId, allowEdgeWrap: true) {
            case .noChange:
                return false
            case let .verticalSwap(targetToken):
                return moveWindowVertical(node, targetToken: targetToken)
            case .unsupported:
                return moveWindowVertical(node, direction: direction)
            case .horizontalConsume,
                 .horizontalExpel:
                return false
            }
        case .left,
             .right:
            return consumeOrExpelWindow(
                node,
                direction: direction,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
        }
    }

    private func moveWindowVertical(_ node: NiriWindow, direction: Direction) -> Bool {
        let sibling: NiriNode?
        switch direction {
        case .up:
            sibling = node.nextSibling()
        case .down:
            sibling = node.prevSibling()
        default:
            return false
        }

        guard let targetSibling = sibling as? NiriWindow else {
            return false
        }

        return moveWindowVertical(node, targetWindow: targetSibling)
    }

    private func moveWindowVertical(_ node: NiriWindow, targetToken: WindowToken) -> Bool {
        guard let targetWindow = findNode(for: targetToken) else { return false }
        return moveWindowVertical(node, targetWindow: targetWindow)
    }

    private func moveWindowVertical(_ node: NiriWindow, targetWindow: NiriWindow) -> Bool {
        guard let column = node.parent as? NiriContainer,
              targetWindow.parent === column,
              targetWindow !== node
        else {
            return false
        }

        let nodeIdx = column.windowNodes.firstIndex { $0 === node }
        let siblingIdx = column.windowNodes.firstIndex { $0 === targetWindow }

        node.swapWith(targetWindow)

        if column.displayMode == .tabbed, let nIdx = nodeIdx, let sIdx = siblingIdx {
            if nIdx == column.activeTileIdx {
                column.setActiveTileIdx(sIdx)
            } else if sIdx == column.activeTileIdx {
                column.setActiveTileIdx(nIdx)
            }
        }

        return true
    }
}
