import Foundation
@testable import Nehir
import Testing

@Suite struct SpringAnimationTests {
    @Test func niriHorizontalViewMovementUsesReferenceConstantsAndCurve() {
        let config = SpringConfig.niriHorizontalViewMovement

        #expect(config.dampingRatio == 1.0)
        #expect(config.stiffness == 800.0)
        #expect(config.epsilon == 0.0001)

        let animation = SpringAnimation(
            from: 0,
            to: 100,
            startTime: 0,
            config: config
        )

        #expect(abs(animation.value(at: 0) - 0) < 0.0001)
        #expect(abs(animation.value(at: 0.05) - 41.3064282489) < 0.0001)
        #expect(animation.isComplete(at: 0.326))
        #expect(abs(animation.value(at: 0.326) - 100) < 0.0001)
    }

    @Test func springValueUsesNiriNumericalStabilityClamp() {
        let animation = SpringAnimation(
            from: 0,
            to: 1,
            initialVelocity: 1_000_000,
            startTime: 0,
            config: SpringConfig(dampingRatio: 0.1, stiffness: 1, epsilon: 0.0001)
        )

        #expect(animation.value(at: 0.001) <= 11)
    }
}

@Suite struct SwipeTrackerTests {
    @Test func ignoresOutOfOrderTimestampsLikeNiri() {
        let tracker = SwipeTracker()
        tracker.push(delta: 10, timestamp: 1.0)
        tracker.push(delta: 20, timestamp: 0.5)

        #expect(tracker.position == 10)
        #expect(tracker.velocity() == 0)
    }

    @Test func preservesSubMillisecondVelocityLikeNiri() {
        let tracker = SwipeTracker()
        tracker.push(delta: 1, timestamp: 1.0)
        tracker.push(delta: 1, timestamp: 1.0005)

        #expect(abs(tracker.velocity() - 4_000) < 0.001)
    }
}
