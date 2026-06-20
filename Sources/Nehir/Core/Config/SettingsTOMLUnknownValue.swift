import Foundation
import TOML

typealias SettingsTOMLUnknownFields = [String: [String: SettingsTOMLUnknownValue]]

/// Type-erased TOML value used to preserve settings.toml keys that this build does not model.
/// Comments and original formatting are intentionally not preserved; values round-trip through
/// the canonical TOML encoder.
enum SettingsTOMLUnknownValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case offsetDateTime(Date)
    case localDateTime(LocalDateTime)
    case localDate(LocalDate)
    case localTime(LocalTime)
    case array([SettingsTOMLUnknownValue])
    case table([String: SettingsTOMLUnknownValue])

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: SettingsTOMLDynamicKey.self) {
            var dict: [String: SettingsTOMLUnknownValue] = [:]
            for key in container.allKeys {
                dict[key.stringValue] = try container.decode(SettingsTOMLUnknownValue.self, forKey: key)
            }
            self = .table(dict)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var items: [SettingsTOMLUnknownValue] = []
            while !container.isAtEnd {
                items.append(try container.decode(SettingsTOMLUnknownValue.self))
            }
            self = .array(items)
            return
        }

        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .float(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(LocalDateTime.self) {
            self = .localDateTime(value)
        } else if let value = try? container.decode(LocalDate.self) {
            self = .localDate(value)
        } else if let value = try? container.decode(LocalTime.self) {
            self = .localTime(value)
        } else if let value = try? container.decode(Date.self) {
            self = .offsetDateTime(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported TOML value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .float(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .boolean(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .offsetDateTime(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .localDateTime(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .localDate(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .localTime(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .table(let values):
            var container = encoder.container(keyedBy: SettingsTOMLDynamicKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: SettingsTOMLDynamicKey(stringValue: key))
            }
        }
    }

    static func decodeUnknownFields<K: CodingKey & CaseIterable>(
        from decoder: Decoder,
        excluding _: K.Type
    ) throws -> [String: SettingsTOMLUnknownValue] where K.AllCases: Sequence, K.AllCases.Element == K {
        let knownKeys = Set(K.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: SettingsTOMLDynamicKey.self)
        var unknown: [String: SettingsTOMLUnknownValue] = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try container.decode(SettingsTOMLUnknownValue.self, forKey: key)
        }
        return unknown
    }
}

struct SettingsTOMLDynamicKey: CodingKey, ExpressibleByStringLiteral {
    var stringValue: String
    var intValue: Int? {
        nil
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init(stringLiteral value: String) {
        self.init(stringValue: value)
    }

    init?(intValue: Int) {
        return nil
    }
}

extension KeyedEncodingContainer where Key == SettingsTOMLDynamicKey {
    mutating func encodeUnknownFields(_ fields: [String: SettingsTOMLUnknownValue]) throws {
        for (key, value) in fields {
            try encode(value, forKey: .init(stringValue: key))
        }
    }
}
