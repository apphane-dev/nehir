import CoreGraphics
import Foundation

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
