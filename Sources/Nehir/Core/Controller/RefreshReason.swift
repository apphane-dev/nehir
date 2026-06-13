import Foundation

enum RelayoutSchedulingPolicy: Equatable, Sendable {
    case plain
    case debounced(nanoseconds: UInt64, dropWhileBusy: Bool)

    var debounceInterval: UInt64 {
        switch self {
        case .plain:
            0
        case let .debounced(nanoseconds, _):
            nanoseconds
        }
    }

    var shouldDropWhileBusy: Bool {
        switch self {
        case .plain:
            false
        case let .debounced(_, dropWhileBusy):
            dropWhileBusy
        }
    }
}

enum RefreshRequestRoute: Equatable, Sendable {
    case fullRescan
    case relayout
    case immediateRelayout
    case visibilityRefresh
    case windowRemoval
}

private struct RefreshRouting: Equatable, Sendable {
    let route: RefreshRequestRoute
    let scheduling: RelayoutSchedulingPolicy

    init(
        route: RefreshRequestRoute,
        scheduling: RelayoutSchedulingPolicy = .plain
    ) {
        self.route = route
        self.scheduling = scheduling
    }
}

enum RefreshReason: String, CaseIterable, Sendable {
    case startup
    case appLaunched
    case unlock
    case activeSpaceChanged
    case monitorConfigurationChanged
    case appRulesChanged
    case workspaceConfigChanged
    case layoutConfigChanged
    case monitorSettingsChanged
    case gapsChanged
    case workspaceTransition
    case appActivationTransition
    case workspaceLayoutToggled
    case appTerminated
    case windowRuleReevaluation
    case layoutCommand
    case interactiveGesture
    case axWindowCreated
    case axWindowChanged
    case windowDestroyed
    case appHidden
    case appUnhidden
    case overviewMutation
}

extension RefreshReason {
    private static let routingTable: [RefreshReason: RefreshRouting] = [
        .startup: .init(route: .fullRescan),
        .appLaunched: .init(route: .fullRescan),
        .unlock: .init(route: .fullRescan),
        .activeSpaceChanged: .init(route: .fullRescan),
        .monitorConfigurationChanged: .init(route: .fullRescan),
        .appRulesChanged: .init(route: .fullRescan),
        .workspaceConfigChanged: .init(route: .fullRescan),
        .appTerminated: .init(route: .fullRescan),

        .layoutConfigChanged: .init(route: .relayout),
        .monitorSettingsChanged: .init(route: .relayout),
        .gapsChanged: .init(route: .relayout),
        .workspaceLayoutToggled: .init(route: .relayout),
        .windowRuleReevaluation: .init(route: .relayout),
        .axWindowCreated: .init(
            route: .relayout,
            scheduling: .debounced(nanoseconds: 4_000_000, dropWhileBusy: false)
        ),
        .axWindowChanged: .init(
            route: .relayout,
            scheduling: .debounced(nanoseconds: 8_000_000, dropWhileBusy: true)
        ),

        .workspaceTransition: .init(route: .immediateRelayout),
        .appActivationTransition: .init(route: .immediateRelayout),
        .layoutCommand: .init(route: .immediateRelayout),
        .interactiveGesture: .init(route: .immediateRelayout),
        .overviewMutation: .init(route: .immediateRelayout),

        .appHidden: .init(route: .visibilityRefresh),
        .appUnhidden: .init(route: .visibilityRefresh),

        .windowDestroyed: .init(route: .windowRemoval)
    ]

    static var hasCompleteRoutingTable: Bool {
        Set(routingTable.keys) == Set(allCases)
    }

    private var routing: RefreshRouting {
        guard let routing = Self.routingTable[self] else {
            preconditionFailure("Missing refresh routing for reason: \(self)")
        }
        return routing
    }

    var route: RefreshRequestRoute {
        routing.route
    }

    var scheduling: RelayoutSchedulingPolicy {
        routing.scheduling
    }
}
