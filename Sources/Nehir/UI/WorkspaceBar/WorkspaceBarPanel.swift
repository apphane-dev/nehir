import AppKit

@MainActor
final class WorkspaceBarPanel: NSPanel {
    var targetScreen: NSScreen?
    var targetFrame: NSRect?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let screenFrame: NSRect
        if let targetFrame {
            screenFrame = targetFrame
        } else if let constrainingScreen = targetScreen ?? screen {
            screenFrame = constrainingScreen.frame
        } else {
            return frameRect
        }

        var constrained = frameRect

        constrained.origin.x = max(screenFrame.minX, min(constrained.origin.x, screenFrame.maxX - constrained.width))
        constrained.origin.y = max(screenFrame.minY, min(constrained.origin.y, screenFrame.maxY - constrained.height))

        return constrained
    }
}
