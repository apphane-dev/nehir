import Foundation

enum ProjectionInvalidation: Hashable {
    case workspaceProjection
    case focusProjection
    case layoutProjection
    case displayProjection
    case settingsProjection
}

struct ProjectionInvalidationRequest: Hashable {
    var kind: ProjectionInvalidation
    var reason: String

    init(_ kind: ProjectionInvalidation, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}
