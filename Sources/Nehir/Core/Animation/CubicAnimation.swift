import Foundation
import QuartzCore

struct CubicConfig {
    let duration: Double

    init(duration: Double = 0.3) {
        self.duration = max(0.01, duration)
    }

    static let `default` = CubicConfig()
}

final class CubicAnimation {
    private let from: Double
    private let target: Double
    private let startTime: TimeInterval
    private let initialVelocity: Double
    let config: CubicConfig

    init(
        from: Double,
        to: Double,
        startTime: TimeInterval,
        initialVelocity: Double = 0,
        config: CubicConfig = .default
    ) {
        self.from = from
        target = to
        self.startTime = startTime
        self.config = config
        self.initialVelocity = Self.clampedInitialVelocity(
            from: from,
            target: to,
            velocity: initialVelocity,
            duration: config.duration
        )
    }

    private static func clampedInitialVelocity(
        from: Double,
        target: Double,
        velocity: Double,
        duration: Double
    ) -> Double {
        let range = target - from
        guard abs(range) > 0.001, abs(velocity) > 0.001 else { return 0 }

        let maxTangentMagnitude = abs(range) * 3.0
        let tangent = velocity * duration
        let clampedTangent: Double
        if range > 0 {
            clampedTangent = min(max(tangent, 0), maxTangentMagnitude)
        } else {
            clampedTangent = max(min(tangent, 0), -maxTangentMagnitude)
        }
        return clampedTangent / duration
    }

    func value(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        let progress = min(1.0, elapsed / config.duration)
        if abs(initialVelocity) > 0.001 {
            let p2 = progress * progress
            let p3 = p2 * progress
            let h00 = 2.0 * p3 - 3.0 * p2 + 1.0
            let h10 = p3 - 2.0 * p2 + progress
            let h01 = -2.0 * p3 + 3.0 * p2
            return h00 * from + h10 * initialVelocity * config.duration + h01 * target
        }
        let easedProgress = 1.0 - pow(1.0 - progress, 3)

        return from + easedProgress * (target - from)
    }

    func isComplete(at time: TimeInterval) -> Bool {
        let elapsed = max(0, time - startTime)
        return elapsed >= config.duration
    }

    func velocity(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        let progress = min(1.0, elapsed / config.duration)
        if progress >= 1.0 { return 0 }
        if abs(initialVelocity) > 0.001 {
            let p2 = progress * progress
            let dh00 = 6.0 * p2 - 6.0 * progress
            let dh10 = 3.0 * p2 - 4.0 * progress + 1.0
            let dh01 = -6.0 * p2 + 6.0 * progress
            return (
                dh00 * from + dh10 * initialVelocity * config.duration + dh01 * target
            ) / config.duration
        }

        let derivative = 3.0 * pow(1.0 - progress, 2)
        return derivative * (target - from) / config.duration
    }
}
