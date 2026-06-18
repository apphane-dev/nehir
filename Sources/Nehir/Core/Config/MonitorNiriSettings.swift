import CoreGraphics
import Foundation

struct MonitorNiriSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID?
    var monitorAnchorPoint: CGPoint?

    var balancedColumnCount: Int?
    var loneWindowPolicy: LoneWindowPolicy?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayId: CGDirectDisplayID? = nil,
        monitorAnchorPoint: CGPoint? = nil,
        balancedColumnCount: Int? = nil,
        loneWindowPolicy: LoneWindowPolicy? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayId = monitorDisplayId
        self.monitorAnchorPoint = monitorAnchorPoint
        self.balancedColumnCount = balancedColumnCount
        self.loneWindowPolicy = loneWindowPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayId, monitorAnchorPoint, balancedColumnCount, loneWindowPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        monitorAnchorPoint = try container.decodeIfPresent(CGPoint.self, forKey: .monitorAnchorPoint)
        balancedColumnCount = try container.decodeIfPresent(Int.self, forKey: .balancedColumnCount)
        loneWindowPolicy = try container.decodeIfPresent(LoneWindowPolicy.self, forKey: .loneWindowPolicy)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try container.encodeIfPresent(monitorDisplayId, forKey: .monitorDisplayId)
        try container.encodeIfPresent(monitorAnchorPoint, forKey: .monitorAnchorPoint)
        try container.encodeIfPresent(balancedColumnCount, forKey: .balancedColumnCount)
        try container.encodeIfPresent(loneWindowPolicy, forKey: .loneWindowPolicy)
    }
}

struct ResolvedNiriSettings: Equatable {
    let defaultColumnWidth: DefaultColumnWidth
    let loneWindowPolicy: LoneWindowPolicy
    let infiniteLoop: Bool
}
