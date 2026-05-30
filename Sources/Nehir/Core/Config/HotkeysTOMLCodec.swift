import Foundation

/// Encodes and decodes hotkey bindings to/from the `hotkeys.toml` format.
///
/// Format:
/// ```toml
/// [workspace]
/// switch = "Modifier+{N}"
/// moveTo = "Modifier+Shift+{N}"
/// backAndForth = "Modifier+Control+Tab"
///
/// [focus]
/// left = "Modifier+Left Arrow"
/// ```
///
/// The `{N}` syntax expands to 9 bindings (1–9) using digit keys.
enum HotkeysTOMLCodec {
    struct Document {
        var modifierTrigger: ModifierKeyTrigger
        var bindings: [HotkeyBinding]
    }

    // MARK: - Encode

    static func encode(_ bindings: [HotkeyBinding]) -> Data {
        encode(bindings, modifierTrigger: .default)
    }

    static func encode(_ bindings: [HotkeyBinding], modifierTrigger: ModifierKeyTrigger) -> Data {
        var bindingMap: [String: String] = [:]
        for binding in bindings {
            guard let configKey = HotkeyConfigMapping.configKey(forInternalId: binding.id) else { continue }
            bindingMap[configKey] = binding.binding.humanReadableString
        }

        var lines: [String] = []
        lines.append("modifierTrigger = \(quoted(modifierTrigger.humanReadableString))")
        for section in HotkeyConfigMapping.sectionOrder {
            lines.append("")
            lines.append("[\(section)]")

            // Handle numbered groups
            for group in HotkeyConfigMapping.numberedGroups where group.section == section {
                emitNumberedGroup(group, bindings: &bindingMap, into: &lines)
            }

            // Handle singletons
            for singleton in HotkeyConfigMapping.singletons where singleton.section == section {
                let configKey = "\(singleton.section).\(singleton.key)"
                if let value = bindingMap.removeValue(forKey: configKey) {
                    lines.append("\(singleton.key) = \(quoted(value))")
                }
            }
        }

        let output = lines.joined(separator: "\n") + "\n"
        return Data(output.utf8)
    }

    private static func emitNumberedGroup(
        _ group: HotkeyConfigMapping.NumberedGroup,
        bindings: inout [String: String],
        into lines: inout [String]
    ) {
        var values: [String] = []
        for n in 1...9 {
            let key = "\(group.section).\(group.key).\(n)"
            values.append(bindings[key] ?? "Unassigned")
        }

        // Try to collapse into {N} pattern
        if let pattern = detectDigitPattern(values) {
            lines.append("\(group.key) = \(quoted(pattern))")
        } else if values.allSatisfy({ $0 == "Unassigned" }) {
            // All unassigned — emit a single "Unassigned" with {N} to show the group exists
            lines.append("\(group.key) = \"Unassigned\"")
        } else {
            // Emit individually
            for (idx, value) in values.enumerated() {
                lines.append("\"\(group.key).\(idx + 1)\" = \(quoted(value))")
            }
        }

        // Remove from map
        for n in 1...9 {
            bindings.removeValue(forKey: "\(group.section).\(group.key).\(n)")
        }
    }

    /// Detect if 9 binding strings follow a pattern like "Modifier+{digit}".
    private static func detectDigitPattern(_ values: [String]) -> String? {
        guard values.count == 9 else { return nil }
        let digitNames = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

        var prefix: String?
        var suffix: String?

        for (idx, value) in values.enumerated() {
            if value == "Unassigned" { return nil }
            let digit = digitNames[idx]
            guard let range = value.range(of: digit, options: .backwards) else { return nil }
            let p = String(value[value.startIndex..<range.lowerBound])
            let s = String(value[range.upperBound..<value.endIndex])
            if let existingPrefix = prefix, existingPrefix != p { return nil }
            if let existingSuffix = suffix, existingSuffix != s { return nil }
            prefix = p
            suffix = s
        }

        guard let prefix, let suffix else { return nil }
        return "\(prefix){N}\(suffix)"
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value)\""
    }

    // MARK: - Decode

    static func decode(_ data: Data, defaults: [HotkeyBinding]) -> [HotkeyBinding] {
        decodeDocument(data, defaults: defaults).bindings
    }

    static func decodeDocument(_ data: Data, defaults: [HotkeyBinding]) -> Document {
        guard let string = String(data: data, encoding: .utf8) else {
            return Document(modifierTrigger: .default, bindings: defaults)
        }
        return decodeDocument(string: string, defaults: defaults)
    }

    static func decode(string: String, defaults: [HotkeyBinding]) -> [HotkeyBinding] {
        decodeDocument(string: string, defaults: defaults).bindings
    }

    static func decodeDocument(string: String, defaults: [HotkeyBinding]) -> Document {
        // Parse TOML manually since we need to handle {N} expansion and dotted keys
        var overrides: [String: String] = [:]
        var modifierTrigger = ModifierKeyTrigger.default
        var currentSection = ""

        for line in string.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Section header
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !trimmed.hasPrefix("[[") {
                currentSection = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            // Key = "value"
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            var rawKey = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            // Strip quotes from key if present (for dotted keys like "switch.3")
            if rawKey.hasPrefix("\"") && rawKey.hasSuffix("\"") {
                rawKey = String(rawKey.dropFirst().dropLast())
            }

            // Extract string value (strip quotes)
            guard let value = extractStringValue(rawValue) else { continue }

            if currentSection.isEmpty, rawKey == "modifierTrigger" {
                modifierTrigger = ModifierKeyTrigger.fromHumanReadable(value) ?? .default
            } else if value.contains("{N}") {
                // Expand {N} pattern
                let digitNames = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
                for (idx, digit) in digitNames.enumerated() {
                    let expanded = value.replacingOccurrences(of: "{N}", with: digit)
                    let configKey = "\(currentSection).\(rawKey).\(idx + 1)"
                    if let internalId = HotkeyConfigMapping.internalId(forConfigKey: configKey) {
                        overrides[internalId] = expanded
                    }
                }
            } else if rawKey.contains(".") {
                // Numbered override like "switch.3" = "Custom"
                let configKey = "\(currentSection).\(rawKey)"
                if let internalId = HotkeyConfigMapping.internalId(forConfigKey: configKey) {
                    overrides[internalId] = value
                }
            } else {
                // Singleton key
                let configKey = "\(currentSection).\(rawKey)"
                if let internalId = HotkeyConfigMapping.internalId(forConfigKey: configKey) {
                    overrides[internalId] = value
                } else {
                    // Could be a numbered group with value "Unassigned" (collapsed form)
                    for group in HotkeyConfigMapping.numberedGroups
                        where group.section == currentSection && group.key == rawKey {
                        for n in 1...9 {
                            let expandedKey = "\(currentSection).\(rawKey).\(n)"
                            if let id = HotkeyConfigMapping.internalId(forConfigKey: expandedKey) {
                                overrides[id] = value
                            }
                        }
                    }
                }
            }
        }

        // Apply overrides
        let bindings = defaults.map { binding in
            guard let override = overrides[binding.id],
                  let trigger = HotkeyTrigger.fromHumanReadable(override)
            else {
                return binding
            }
            return HotkeyBinding(id: binding.id, command: binding.command, trigger: trigger)
        }
        return Document(modifierTrigger: modifierTrigger, bindings: bindings)
    }

    private static func extractStringValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return nil
    }
}
