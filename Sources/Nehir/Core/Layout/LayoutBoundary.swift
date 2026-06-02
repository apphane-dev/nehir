import AppKit
import Foundation

struct LayoutWindowSnapshot {
    let token: WindowToken
    let constraints: WindowSizeConstraints
    let layoutConstraints: WindowSizeConstraints
    let hiddenState: WindowModel.HiddenState?
    let layoutReason: LayoutReason
    let showsNativeFullscreenPlaceholder: Bool
    let resizePlaceholderState: ResizePlaceholderState?

    var isNativeFullscreenSuspended: Bool {
        layoutReason == .nativeFullscreen
    }

    var effectiveResizeMinimumSize: CGSize {
        guard let resizePlaceholderState else { return constraints.minSize }
        return CGSize(
            width: max(constraints.minSize.width, resizePlaceholderState.minimumSize.width),
            height: max(constraints.minSize.height, resizePlaceholderState.minimumSize.height)
        )
    }

    func needsResizePlaceholder(for frame: CGRect) -> Bool {
        guard layoutReason == .standard, !constraints.isFixed else { return false }
        guard hiddenState == nil else { return false }
        let minimumSize = effectiveResizeMinimumSize
        let tolerance: CGFloat = 0.5
        return frame.width + tolerance < minimumSize.width || frame.height + tolerance < minimumSize.height
    }
}

struct LayoutMonitorSnapshot {
    let monitorId: Monitor.ID
    let displayId: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let workingFrame: CGRect
    let scale: CGFloat
    let orientation: Monitor.Orientation
}

struct WorkspaceRefreshInput {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    let windows: [LayoutWindowSnapshot]
    let isActiveWorkspace: Bool
}

struct NiriWindowRemovalSeed {
    let removedNodeIds: [NodeId]
    let oldFrames: [WindowToken: CGRect]
}

struct NiriWorkspaceSnapshot {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    let windows: [LayoutWindowSnapshot]
    let viewportState: ViewportState
    let preferredWorkspaceFocusToken: WindowToken?
    let confirmedManagedFocusToken: WindowToken?
    let activeFocusRequestToken: WindowToken?
    let hasCompletedInitialRefresh: Bool
    let useScrollAnimationPath: Bool
    let removalSeed: NiriWindowRemovalSeed?
    let gap: CGFloat
    let outerGaps: LayoutGaps.OuterGaps
    let displayRefreshRate: Double
    let isActiveWorkspace: Bool
}

struct LayoutFrameChange {
    let token: WindowToken
    let frame: CGRect
    let forceApply: Bool
}

struct LayoutRestoreChange {
    let token: WindowToken
    let hiddenState: WindowModel.HiddenState
}

enum LayoutVisibilityChange {
    case show(WindowToken)
    case hide(WindowToken, side: HideSide)
}

struct LayoutFocusedFrame {
    let token: WindowToken
    let frame: CGRect
}

struct NativeFullscreenPlaceholderChange {
    let token: WindowToken
    let frame: CGRect
    let selected: Bool
}

struct ResizePlaceholderChange {
    let token: WindowToken
    let frame: CGRect
    let minimumSize: CGSize
    let selected: Bool
}

// `frameChanges` imply active, restore-eligible windows for this pass.
// `visibilityChanges` are reserved for explicit hide/show transitions.
struct WorkspaceLayoutDiff {
    var frameChanges: [LayoutFrameChange] = []
    var visibilityChanges: [LayoutVisibilityChange] = []
    var restoreChanges: [LayoutRestoreChange] = []
    var nativeFullscreenPlaceholders: [NativeFullscreenPlaceholderChange] = []
    var resizePlaceholders: [ResizePlaceholderChange] = []
    var focusedFrame: LayoutFocusedFrame?
}

struct WorkspaceSessionPatch {
    let workspaceId: WorkspaceDescriptor.ID
    var viewportState: ViewportState?
    var rememberedFocusToken: WindowToken?
}

struct WorkspaceSessionTransfer {
    var sourcePatch: WorkspaceSessionPatch?
    var targetPatch: WorkspaceSessionPatch?
}

enum AnimationDirective {
    case none
    case startNiriScroll(workspaceId: WorkspaceDescriptor.ID)
    case activateWindow(token: WindowToken)
    case updateTabbedOverlays
}

struct RefreshVisibilityEffect {
    let activeWorkspaceIds: Set<WorkspaceDescriptor.ID>
}

struct RefreshExecutionEffects {
    var visibility: RefreshVisibilityEffect?
    var requestWorkspaceBarRefresh: Bool = false
    var updateTabbedOverlays: Bool = false
    var refreshFocusedBorderForVisibilityState: Bool = false
    var focusValidationWorkspaceIds: [WorkspaceDescriptor.ID] = []
    var markInitialRefreshComplete: Bool = false
    var drainDeferredCreatedWindows: Bool = false
    var subscribeManagedWindows: Bool = false
}

struct WorkspaceLayoutPlan {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    var sessionPatch: WorkspaceSessionPatch
    var diff: WorkspaceLayoutDiff
    var animationDirectives: [AnimationDirective] = []
}

typealias RefreshPostLayoutAction = @MainActor () -> Void

struct RefreshExecutionPlan {
    var workspacePlans: [WorkspaceLayoutPlan] = []
    var effects: RefreshExecutionEffects = .init()
    var postLayoutActions: [RefreshPostLayoutAction] = []
}
