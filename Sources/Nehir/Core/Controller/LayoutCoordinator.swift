import AppKit
import Foundation

/// The narrow layout-command surface that command logic depends on, instead of
/// reaching through the concrete `NiriLayoutHandler` or live `niriEngine`.
///
/// The member set is derived from command-level capabilities — nothing
/// speculative. Layout-pipeline internals (`layoutWithNiriEngine`,
/// `registerScrollAnimation`, `insertWindow`, `updateTabbedColumnOverlays`,
/// `hasScrollAnimation`, …) and low-level engine-context escape hatches
/// deliberately stay off this protocol: they are refresh-pipeline plumbing or
/// Niri implementation details, not the layout command surface.
@MainActor protocol LayoutCoordinator: AnyObject {
    // Focus / movement
    func focusNeighbor(direction: Direction)
    func focusPrevious()
    func focusDownOrLeft()
    func focusUpOrRight()
    func focusWindowInColumn(index: Int)
    func focusWindowTop()
    func focusWindowBottom()
    func focusWindowDownOrTop()
    func focusWindowUpOrBottom()
    func focusWindowOrWorkspace(direction: Direction)
    func focusColumnFirst()
    func focusColumnLast()
    func focusColumn(index: Int)

    @discardableResult func moveWindow(direction: Direction) -> NiriWindowMoveResult
    func moveWindowOrToAdjacentWorkspace(direction: Direction)
    func moveColumn(direction: Direction)
    func moveColumnToFirst()
    func moveColumnToLast()
    func moveColumnToIndex(index: Int)
    func consumeOrExpelWindow(direction: Direction)
    func consumeWindowIntoColumn()
    func expelWindowFromColumn()
    func toggleFullscreen()
    func toggleColumnTabbed()

    // Sizing
    func cycleSize(forward: Bool)
    func cycleWindowWidth(forward: Bool)
    func cycleWindowHeight(forward: Bool)
    func toggleColumnFullWidth()
    func expandColumnToAvailableWidth()
    func resetWindowHeight()
    func setColumnWidth(_ change: NiriSizeChange)
    func setWindowWidth(_ change: NiriSizeChange)
    func setWindowHeight(_ change: NiriSizeChange)
    func balanceSizes()

    // Viewport
    func scrollViewport(direction: Direction)

}

// Conformance is free: `NiriLayoutHandler` already implements every requirement
// with matching signatures. If a future signature drifts, fix this protocol to
// match the concrete method — never edit the concrete method to satisfy it.
extension NiriLayoutHandler: LayoutCoordinator {}
