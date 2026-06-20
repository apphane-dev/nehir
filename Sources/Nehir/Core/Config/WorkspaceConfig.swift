// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import NehirIPC

enum MonitorAssignment: Equatable, Hashable {
    case main
    case secondary
    case specificDisplay(OutputId)

    var displayName: String {
        switch self {
        case .main: "Main"
        case .secondary: "Secondary"
        case let .specificDisplay(output): output.name
        }
    }

    func toMonitorDescription() -> MonitorDescription {
        switch self {
        case .main: return .main
        case .secondary: return .secondary
        case let .specificDisplay(output): return .output(output)
        }
    }
}

extension MonitorAssignment: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, output
    }

    private enum AssignmentType: String, Codable {
        case main, secondary, specificDisplay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(AssignmentType.self, forKey: .type)
        switch type {
        case .main: self = .main
        case .secondary: self = .secondary
        case .specificDisplay:
            let output = try container.decode(OutputId.self, forKey: .output)
            self = .specificDisplay(output)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .main:
            try container.encode(AssignmentType.main, forKey: .type)
        case .secondary:
            try container.encode(AssignmentType.secondary, forKey: .type)
        case let .specificDisplay(output):
            try container.encode(AssignmentType.specificDisplay, forKey: .type)
            try container.encode(output, forKey: .output)
        }
    }
}

struct WorkspaceConfiguration: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var displayName: String?
    var monitorAssignment: MonitorAssignment

    var effectiveDisplayName: String {
        displayName.flatMap { $0.isEmpty ? nil : $0 } ?? name
    }

    init(
        id: UUID? = nil,
        name: String,
        displayName: String? = nil,
        monitorAssignment: MonitorAssignment = .main
    ) {
        self.id = id ?? Self.stableID(for: name)
        self.name = name
        self.displayName = displayName
        self.monitorAssignment = monitorAssignment
    }

    private static func stableID(for name: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in name.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return hash
        }

        let left = fnv(14_695_981_039_346_656_037)
        let right = fnv(10_995_116_282_11)
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0 ..< 8 {
            bytes[index] = UInt8((left >> UInt64((7 - index) * 8)) & 0xff)
            bytes[index + 8] = UInt8((right >> UInt64((7 - index) * 8)) & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    var sortOrder: Int {
        WorkspaceIDPolicy.workspaceNumber(from: name) ?? .max
    }
}
