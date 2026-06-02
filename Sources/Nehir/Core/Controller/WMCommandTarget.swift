import Foundation

struct WMCommandTarget: Equatable {
    enum Source: Equatable {
        case layoutSelection
        case confirmedManagedFocus
        case frontmostManagedFallback
    }

    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let source: Source
}
