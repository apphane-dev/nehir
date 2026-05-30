import Carbon
import Foundation

struct KeyBinding: Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let usesModifier: Bool

    static let unassigned = KeyBinding(keyCode: UInt32.max, modifiers: 0)

    init(keyCode: UInt32, modifiers: UInt32, usesModifier: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.usesModifier = usesModifier
    }

    var isUnassigned: Bool {
        keyCode == UInt32.max && modifiers == 0 && !usesModifier
    }

    var displayString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.displayString(keyCode: keyCode, modifiers: modifiers, usesModifier: usesModifier)
    }

    var humanReadableString: String {
        if isUnassigned {
            return "Unassigned"
        }
        return KeySymbolMapper.humanReadableString(keyCode: keyCode, modifiers: modifiers, usesModifier: usesModifier)
    }

    func conflicts(with other: KeyBinding, modifierTrigger: ModifierKeyTrigger) -> Bool {
        guard !isUnassigned, !other.isUnassigned, keyCode == other.keyCode else { return false }
        if modifiers == other.modifiers && usesModifier == other.usesModifier {
            return true
        }
        return carbonCompatibilityBinding(for: modifierTrigger) == other ||
            other.carbonCompatibilityBinding(for: modifierTrigger) == self
    }

    func carbonCompatibilityBinding(for modifierTrigger: ModifierKeyTrigger) -> KeyBinding? {
        guard usesModifier, !isUnassigned else { return nil }
        if let modifier = modifierTrigger.carbonCompatibilityModifierMask {
            guard modifiers & modifier == 0 else { return nil }
            return KeyBinding(keyCode: keyCode, modifiers: modifiers | modifier)
        }
        guard modifierTrigger == .system, modifiers == 0 else { return nil }
        return KeyBinding(keyCode: keyCode, modifiers: KeySymbolMapper.realHyperModifiers)
    }
}

extension KeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, usesModifier
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
        usesModifier = try container.decodeIfPresent(Bool.self, forKey: .usesModifier) ?? false
    }

    func encode(to encoder: Encoder) throws {
        if isUnassigned || KeySymbolMapper.keyName(keyCode) != "?" {
            var container = encoder.singleValueContainer()
            try container.encode(humanReadableString)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
            if usesModifier {
                try container.encode(usesModifier, forKey: .usesModifier)
            }
        }
    }
}

enum ModifierKeyTrigger: Equatable, Hashable {
    case system
    case modifier(UInt32)
    case key(UInt32)
    case mouseButton(Int64)

    static let `default`: ModifierKeyTrigger = .modifier(UInt32(optionKey | cmdKey))

    var displayString: String {
        switch self {
        case .system:
            return "⌃⌥⇧⌘"
        case let .modifier(modifier):
            return KeySymbolMapper.modifierSymbols(modifier)
        case let .key(keyCode):
            return KeySymbolMapper.keySymbol(keyCode)
        case let .mouseButton(button):
            return "Mouse \(button)"
        }
    }

    var humanReadableString: String {
        switch self {
        case .system:
            return "Control+Option+Shift+Command"
        case let .modifier(modifier):
            return KeySymbolMapper.modifierNames(modifier)
        case let .key(keyCode):
            return KeySymbolMapper.keyName(keyCode)
        case let .mouseButton(button):
            return "MouseButton\(button)"
        }
    }

    var requiresEventTap: Bool {
        switch self {
        case .system,
             .modifier:
            return false
        case .key,
             .mouseButton:
            return true
        }
    }

    var keyboardKeyCode: UInt32? {
        guard case let .key(keyCode) = self else { return nil }
        return keyCode
    }

    var mouseButtonNumber: Int64? {
        guard case let .mouseButton(button) = self else { return nil }
        return button
    }

    var modifierMaskToExclude: UInt32 {
        switch self {
        case .system,
             .mouseButton:
            return 0
        case let .modifier(modifier):
            return modifier
        case let .key(keyCode):
            return Self.modifierMask(for: keyCode)
        }
    }

    var carbonCompatibilityModifierMask: UInt32? {
        guard case let .modifier(modifier) = self else { return nil }
        return modifier
    }

    func matchesPhysicalKeyCode(_ keyCode: UInt32) -> Bool {
        switch self {
        case .system,
             .mouseButton:
            return false
        case let .key(triggerKeyCode):
            return keyCode == triggerKeyCode
        case let .modifier(modifier):
            return Self.modifierMask(for: keyCode) == modifier
        }
    }

    static func fromHumanReadable(_ string: String) -> ModifierKeyTrigger? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.localizedCaseInsensitiveCompare("System Modifier") == .orderedSame ||
            trimmed.localizedCaseInsensitiveCompare("Real Modifier") == .orderedSame ||
            trimmed.localizedCaseInsensitiveCompare("Control+Option+Shift+Command") == .orderedSame
        {
            return .system
        }

        let compactMouse = trimmed.replacingOccurrences(of: " ", with: "")
        if compactMouse.lowercased().hasPrefix("mousebutton"),
           let button = Int64(compactMouse.dropFirst("MouseButton".count)),
           button >= 2
        {
            return .mouseButton(button)
        }

        if let modifier = Self.modifierMask(named: trimmed) {
            return .modifier(modifier)
        }

        // Handle combined modifiers like "Option+Command"
        if trimmed.contains("+") {
            let parts = trimmed.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
            var combined: UInt32 = 0
            var allValid = true
            for part in parts {
                if let mask = Self.modifierMask(named: part) {
                    combined |= mask
                } else {
                    allValid = false
                    break
                }
            }
            if allValid && combined != 0 {
                return .modifier(combined)
            }
        }

        if let keyCode = KeySymbolMapper.keyCode(named: trimmed) {
            return .key(keyCode)
        }

        return nil
    }

    static func modifierMask(for keyCode: UInt32) -> UInt32 {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift:
            return UInt32(shiftKey)
        case kVK_Control, kVK_RightControl:
            return UInt32(controlKey)
        case kVK_Option, kVK_RightOption:
            return UInt32(optionKey)
        case kVK_Command, kVK_RightCommand:
            return UInt32(cmdKey)
        default:
            return 0
        }
    }

    static func modifierMask(named name: String) -> UInt32? {
        switch name.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "").lowercased() {
        case "shift":
            return UInt32(shiftKey)
        case "control":
            return UInt32(controlKey)
        case "option":
            return UInt32(optionKey)
        case "command":
            return UInt32(cmdKey)
        default:
            return nil
        }
    }
}

extension ModifierKeyTrigger: Codable {
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let trigger = ModifierKeyTrigger.fromHumanReadable(string)
        {
            self = trigger
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Invalid modifier key trigger")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(humanReadableString)
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

    func conflicts(with other: HotkeyTrigger, modifierTrigger: ModifierKeyTrigger) -> Bool {
        guard !isUnassigned, !other.isUnassigned else { return false }
        switch (self, other) {
        case let (.chord(lhs), .chord(rhs)):
            return lhs.conflicts(with: rhs, modifierTrigger: modifierTrigger)
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
