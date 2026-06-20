// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

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
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal
    ) -> Bool {
        if direction.primaryStep(for: orientation) != nil {
            return consumeOrExpelWindow(
                node,
                direction: direction,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }

        guard direction.secondaryStep(for: orientation) != nil else { return false }

        let pureDecision = pureLayoutMoveDecision(
            node,
            direction: direction,
            in: workspaceId,
            allowEdgeWrap: true,
            orientation: orientation
        )
        switch pureDecision.plan {
        case .noChange:
            return false
        case let .verticalSwap(targetToken):
            let moved = moveWindowVertical(node, targetToken: targetToken)
            if moved {
                assertPureLayoutSnapshotMatches(pureDecision.expectedSnapshot, selectedWindow: node, in: workspaceId)
            }
            return moved
        case .unsupported:
            return moveWindowVertical(node, direction: direction, orientation: orientation)
        case .horizontalConsume,
             .horizontalExpel:
            return false
        }
    }

    private func moveWindowVertical(
        _ node: NiriWindow,
        direction: Direction,
        orientation: Monitor.Orientation
    ) -> Bool {
        guard let step = direction.secondaryStep(for: orientation) else { return false }
        let sibling = step > 0 ? node.nextSibling() : node.prevSibling()
        guard let targetSibling = sibling as? NiriWindow else { return false }
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

        node.swapWith(targetWindow)

        if let movedIndex = column.windowNodes.firstIndex(where: { $0 === node }) {
            column.setActiveTileIdx(movedIndex)
        }
        if column.displayMode == .tabbed {
            updateTabbedColumnVisibility(column: column)
        }

        return true
    }
}
