import Foundation

enum ExternalCommandResult: Equatable, Sendable, Error {
    case executed
    case ignoredDisabled
    case ignoredOverview
    case staleWindowId
    case notFound
    case invalidArguments
    case invalidState
    case requiresDeveloperMode
    case internalError
}
