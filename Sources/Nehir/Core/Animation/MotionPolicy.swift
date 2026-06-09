import Observation

struct MotionSnapshot: Equatable, Sendable {
    let animationsEnabled: Bool

    static let enabled = MotionSnapshot(animationsEnabled: true)
    static let disabled = MotionSnapshot(animationsEnabled: false)
}

@MainActor @Observable
final class MotionPolicy {
    func snapshot() -> MotionSnapshot {
        .enabled
    }
}
