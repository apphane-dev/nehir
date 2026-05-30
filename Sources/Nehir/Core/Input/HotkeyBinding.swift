import Carbon
import Foundation

struct KeyBinding: Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let unassigned = KeyBinding(keyCode: UInt32.max, modifiers: 0)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var isUnassigned: Bool {
        keyCode == UInt32.max && modifiers == 0
    }

    var displayString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    var humanReadableString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.humanReadableString(keyCode: keyCode, modifiers: modifiers)
    }

    func conflicts(with other: KeyBinding) -> Bool {
        guard !isUnassigned, !other.isUnassigned else { return false }
        return keyCode == other.keyCode && modifiers == other.modifiers
    }
}

extension KeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let binding = KeySymbolMapper.fromHumanReadable(string)
        {
            self = binding
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(UInt32.self, forKey: .modifiers)
    }

    func encode(to encoder: Encoder) throws {
        if isUnassigned || KeySymbolMapper.keyName(keyCode) != "?" {
            var container = encoder.singleValueContainer()
            try container.encode(humanReadableString)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        }
    }
}

enum HotkeyTrigger: Equatable, Hashable {
    case unassigned
    case chord(KeyBinding)

    var isUnassigned: Bool {
        switch self {
        case .unassigned:
            return true
        case let .chord(binding):
            return binding.isUnassigned
        }
    }

    var displayString: String {
        switch self {
        case .unassigned:
            return "Unassigned"
        case let .chord(binding):
            return binding.displayString
        }
    }

    var humanReadableString: String {
        switch self {
        case .unassigned:
            return "Unassigned"
        case let .chord(binding):
            return binding.humanReadableString
        }
    }

    var chordBinding: KeyBinding? {
        guard case let .chord(binding) = self, !binding.isUnassigned else { return nil }
        return binding
    }

    func conflicts(with other: HotkeyTrigger) -> Bool {
        guard !isUnassigned, !other.isUnassigned else { return false }
        switch (self, other) {
        case let (.chord(lhs), .chord(rhs)):
            return lhs.conflicts(with: rhs)
        default:
            return false
        }
    }

    static func fromHumanReadable(_ string: String) -> HotkeyTrigger? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "Unassigned" { return .unassigned }
        if let binding = KeySymbolMapper.fromHumanReadable(trimmed) {
            return binding.isUnassigned ? .unassigned : .chord(binding)
        }
        return nil
    }
}

extension HotkeyTrigger: Codable {
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let trigger = HotkeyTrigger.fromHumanReadable(string)
        {
            self = trigger
            return
        }
        let binding = try KeyBinding(from: decoder)
        self = binding.isUnassigned ? .unassigned : .chord(binding)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .unassigned:
            var container = encoder.singleValueContainer()
            try container.encode(humanReadableString)
        case let .chord(binding):
            try binding.encode(to: encoder)
        }
    }
}

struct HotkeyBinding: Codable, Equatable, Identifiable {
    let id: String
    let command: HotkeyCommand
    var binding: HotkeyTrigger

    var category: HotkeyCategory {
        ActionCatalog.category(for: id) ?? .focus
    }

    init(id: String, command: HotkeyCommand, binding: KeyBinding) {
        self.init(id: id, command: command, trigger: binding.isUnassigned ? .unassigned : .chord(binding))
    }

    init(id: String, command: HotkeyCommand, trigger: HotkeyTrigger) {
        self.id = id
        self.command = command
        binding = HotkeyBindingRegistry.canonicalizeTrigger(trigger)
    }
}

extension HotkeyBinding {
    private enum CodingKeys: String, CodingKey {
        case id, binding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let trigger = try container.decodeIfPresent(HotkeyTrigger.self, forKey: .binding) ?? .unassigned
        guard let command = HotkeyBindingRegistry.command(for: id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Unknown hotkey binding id: \(id)"
            )
        }
        self = HotkeyBinding(id: id, command: command, trigger: trigger)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(binding, forKey: .binding)
    }
}

struct PersistedHotkeyBinding: Codable, Equatable {
    let id: String
    let binding: HotkeyTrigger

    private enum CodingKeys: String, CodingKey {
        case id, binding
    }

    init(id: String, binding: KeyBinding) {
        self.init(id: id, trigger: binding.isUnassigned ? .unassigned : .chord(binding))
    }

    init(id: String, trigger: HotkeyTrigger) {
        self.id = id
        binding = HotkeyBindingRegistry.canonicalizeTrigger(trigger)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        binding = try container.decodeIfPresent(HotkeyTrigger.self, forKey: .binding) ?? .unassigned
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(binding, forKey: .binding)
    }
}

enum HotkeyBindingRegistry {
    private static let defaultBindings = DefaultHotkeyBindings.all()
    private static let bindingsByID = Dictionary(
        defaultBindings.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func defaults() -> [HotkeyBinding] {
        defaultBindings
    }

    static func command(for id: String) -> HotkeyCommand? {
        bindingsByID[id]?.command
    }

    static func makeBinding(id: String, binding: KeyBinding) -> HotkeyBinding? {
        guard let defaultBinding = bindingsByID[id] else { return nil }
        return HotkeyBinding(id: id, command: defaultBinding.command, binding: binding)
    }

    static func makeBinding(id: String, trigger: HotkeyTrigger) -> HotkeyBinding? {
        guard let defaultBinding = bindingsByID[id] else { return nil }
        return HotkeyBinding(id: id, command: defaultBinding.command, trigger: trigger)
    }

    static func canonicalize(_ persisted: [PersistedHotkeyBinding]) -> [HotkeyBinding] {
        var overrides: [String: HotkeyTrigger] = [:]
        var explicitOverrideIDs: Set<String> = []

        for entry in persisted {
            let normalizedBinding = canonicalizeTrigger(entry.binding)
            guard bindingsByID[entry.id] != nil else { continue }
            explicitOverrideIDs.insert(entry.id)
            overrides[entry.id] = normalizedBinding
        }

        return defaultBindings.map { binding in
            guard explicitOverrideIDs.contains(binding.id) else { return binding }
            let override = overrides[binding.id] ?? .unassigned
            return HotkeyBinding(id: binding.id, command: binding.command, trigger: override)
        }
    }

    static func canonicalizeBinding(_ binding: KeyBinding) -> KeyBinding {
        binding.isUnassigned ? .unassigned : binding
    }

    static func canonicalizeTrigger(_ trigger: HotkeyTrigger) -> HotkeyTrigger {
        switch trigger {
        case .unassigned:
            return .unassigned
        case let .chord(binding):
            return binding.isUnassigned ? .unassigned : .chord(binding)
        }
    }

    static func decodePersistedBindings(from data: Data) -> [HotkeyBinding]? {
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        let decoder = JSONDecoder()
        var persisted: [PersistedHotkeyBinding] = []
        for rawEntry in rawArray {
            guard JSONSerialization.isValidJSONObject(rawEntry),
                  let entryData = try? JSONSerialization.data(withJSONObject: rawEntry),
                  let entry = try? decoder.decode(PersistedHotkeyBinding.self, from: entryData)
            else {
                continue
            }
            persisted.append(entry)
        }

        return canonicalize(persisted)
    }

    static func canonicalizedJSONArray(from rawArray: Any) -> Any {
        guard let entries = rawArray as? [Any] else {
            return encodedJSONArray(for: defaultBindings)
        }

        let decoder = JSONDecoder()
        var persisted: [PersistedHotkeyBinding] = []
        for rawEntry in entries {
            guard JSONSerialization.isValidJSONObject(rawEntry),
                  let entryData = try? JSONSerialization.data(withJSONObject: rawEntry),
                  let entry = try? decoder.decode(PersistedHotkeyBinding.self, from: entryData)
            else {
                continue
            }
            persisted.append(entry)
        }

        return encodedJSONArray(for: canonicalize(persisted))
    }

    private static func encodedJSONArray(for bindings: [HotkeyBinding]) -> Any {
        guard let data = try? JSONEncoder().encode(bindings),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }
        return json
    }
}

enum HotkeyCategory: String, CaseIterable {
    case workspace = "Workspace"
    case focus = "Focus"
    case move = "Move Window"
    case monitor = "Monitor"
    case layout = "Layout"
    case column = "Column"
}
