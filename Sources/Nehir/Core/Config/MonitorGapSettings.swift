// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics
import Foundation

enum GapLimits {
    /// Inclusive range enforced for resolved inner and outer gaps, in points.
    /// Values set in `settings.toml` or monitor overrides up to this ceiling are
    /// honored by the layout resolver.
    static let range: ClosedRange<Double> = 0 ... 256

    /// Interactive range exposed by the Settings sliders. Deliberately narrower
    /// than `range` to keep the control ergonomic: values above this still apply
    /// (from `settings.toml` or monitor overrides) and render at their true value,
    /// with the slider thumb pinned at the upper bound.
    static let sliderRange: ClosedRange<Double> = 0 ... 64
}

struct MonitorGapSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID?
    var monitorAnchorPoint: CGPoint?

    var gapSize: Double?
    var outerGapLeft: Double?
    var outerGapRight: Double?
    var outerGapTop: Double?
    var outerGapBottom: Double?

    var hasOverrides: Bool {
        gapSize != nil || outerGapLeft != nil || outerGapRight != nil || outerGapTop != nil || outerGapBottom != nil
    }

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayId: CGDirectDisplayID? = nil,
        monitorAnchorPoint: CGPoint? = nil,
        gapSize: Double? = nil,
        outerGapLeft: Double? = nil,
        outerGapRight: Double? = nil,
        outerGapTop: Double? = nil,
        outerGapBottom: Double? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayId = monitorDisplayId
        self.monitorAnchorPoint = monitorAnchorPoint
        self.gapSize = gapSize
        self.outerGapLeft = outerGapLeft
        self.outerGapRight = outerGapRight
        self.outerGapTop = outerGapTop
        self.outerGapBottom = outerGapBottom
    }
}

struct ResolvedGapSettings: Equatable {
    let gapSize: Double
    let outerGapLeft: Double
    let outerGapRight: Double
    let outerGapTop: Double
    let outerGapBottom: Double

    var outerGaps: LayoutGaps.OuterGaps {
        LayoutGaps.OuterGaps(
            left: CGFloat(outerGapLeft),
            right: CGFloat(outerGapRight),
            top: CGFloat(outerGapTop),
            bottom: CGFloat(outerGapBottom)
        )
    }
}
