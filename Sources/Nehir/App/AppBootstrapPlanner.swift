import Foundation

enum AppBootstrapDecision: Equatable {
    case boot
}

enum AppBootstrapPlanner {
    static func decision() -> AppBootstrapDecision {
        .boot
    }
}
