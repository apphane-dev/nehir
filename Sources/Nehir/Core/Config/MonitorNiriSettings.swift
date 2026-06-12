import CoreGraphics
import Foundation

struct MonitorNiriSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID?

    var maxVisibleColumns: Int?
    var singleWindowAspectRatio: SingleWindowAspectRatio?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayId: CGDirectDisplayID? = nil,
        maxVisibleColumns: Int? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayId = monitorDisplayId
        self.maxVisibleColumns = maxVisibleColumns
        self.singleWindowAspectRatio = singleWindowAspectRatio
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayId, maxVisibleColumns, singleWindowAspectRatio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        maxVisibleColumns = try container.decodeIfPresent(Int.self, forKey: .maxVisibleColumns)
        singleWindowAspectRatio = try container.decodeIfPresent(String.self, forKey: .singleWindowAspectRatio)
            .flatMap { SingleWindowAspectRatio(rawValue: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try container.encodeIfPresent(monitorDisplayId, forKey: .monitorDisplayId)
        try container.encodeIfPresent(maxVisibleColumns, forKey: .maxVisibleColumns)
        try container.encodeIfPresent(singleWindowAspectRatio?.rawValue, forKey: .singleWindowAspectRatio)
    }
}

struct ResolvedNiriSettings: Equatable {
    let maxVisibleColumns: Int
    let centerFocusedColumn: CenterFocusedColumn
    let alwaysCenterSingleColumn: Bool
    let singleWindowAspectRatio: SingleWindowAspectRatio
    let infiniteLoop: Bool
}
