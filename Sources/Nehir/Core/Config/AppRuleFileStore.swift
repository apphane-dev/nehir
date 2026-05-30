import Foundation

/// Reads and writes app rules from `apprules.d/*.toml` — one file per rule.
///
/// Each file uses flat TOML with `[match]` and `[effect]` sections:
/// ```toml
/// [match]
/// bundleId = "com.google.Chrome"
///
/// [effect]
/// minWidth = 500
/// minHeight = 375
/// ```
enum AppRuleFileStore {
    // MARK: - Encode (write directory)

    static func write(_ rules: [AppRule], to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Remove existing .toml files
        if let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for fileURL in contents where fileURL.pathExtension == "toml" {
                try? fm.removeItem(at: fileURL)
            }
        }

        for (index, rule) in rules.enumerated() {
            let filename = sanitizedFilename(for: rule)
            let fileURL = directory.appendingPathComponent(filename)
            let content = encode(rule, order: index)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        try writeInactiveSamples(to: directory)
    }

    static func encode(_ rule: AppRule) -> String {
        encode(rule, order: nil)
    }

    static func encode(_ rule: AppRule, order: Int?) -> String {
        var lines: [String] = []
        lines.append("id = \(quoted(rule.id.uuidString))")
        if let order { lines.append("order = \(order)") }
        if !lines.isEmpty { lines.append("") }
        lines.append("[match]")
        lines.append("bundleId = \(quoted(rule.bundleId))")
        if let v = rule.appNameSubstring { lines.append("appName = \(quoted(v))") }
        if let v = rule.titleSubstring { lines.append("titleSubstring = \(quoted(v))") }
        if let v = rule.titleRegex { lines.append("titleRegex = \(quoted(v))") }
        if let v = rule.axRole { lines.append("axRole = \(quoted(v))") }
        if let v = rule.axSubrole { lines.append("axSubrole = \(quoted(v))") }

        var effectLines: [String] = []
        if let layout = rule.layout { effectLines.append("layout = \(quoted(layout.rawValue))") }
        if let w = rule.minWidth { effectLines.append("minWidth = \(formatNumber(w))") }
        if let h = rule.minHeight { effectLines.append("minHeight = \(formatNumber(h))") }
        if let ws = rule.assignToWorkspace { effectLines.append("assignToWorkspace = \(quoted(ws))") }

        if !effectLines.isEmpty {
            lines.append("")
            lines.append("[effect]")
            lines.append(contentsOf: effectLines)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Decode (read directory)

    static func read(from directory: URL) -> [AppRule] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let tomlFiles = contents
            .filter { $0.pathExtension == "toml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return tomlFiles.compactMap { fileURL -> (Int?, AppRule)? in
            guard let data = try? String(contentsOf: fileURL, encoding: .utf8),
                  let decoded = decodeWithOrder(data, sourceFile: fileURL.lastPathComponent)
            else { return nil }
            return decoded
        }
        .sorted { lhs, rhs in
            switch (lhs.0, rhs.0) {
            case let (left?, right?): left < right
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): false
            }
        }
        .map(\.1)
    }

    static func decode(_ content: String, sourceFile: String = "") -> AppRule? {
        decodeWithOrder(content, sourceFile: sourceFile)?.1
    }

    private static func decodeWithOrder(_ content: String, sourceFile: String = "") -> (Int?, AppRule)? {
        var currentSection = ""
        var documentFields: [String: String] = [:]
        var matchFields: [String: String] = [:]
        var effectFields: [String: String] = [:]

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            switch currentSection {
            case "": documentFields[key] = rawValue
            case "match": matchFields[key] = rawValue
            case "effect": effectFields[key] = rawValue
            default: break
            }
        }

        guard let bundleId = extractString(matchFields["bundleId"]) else { return nil }

        let rule = AppRule(
            id: extractString(documentFields["id"]).flatMap(UUID.init(uuidString:))
                ?? stableID(for: sourceFile, bundleId: bundleId),
            bundleId: bundleId,
            appNameSubstring: extractString(matchFields["appName"]),
            titleSubstring: extractString(matchFields["titleSubstring"]),
            titleRegex: extractString(matchFields["titleRegex"]),
            axRole: extractString(matchFields["axRole"]),
            axSubrole: extractString(matchFields["axSubrole"]),
            layout: extractString(effectFields["layout"]).flatMap(WindowRuleLayoutAction.init(rawValue:)),
            assignToWorkspace: extractString(effectFields["assignToWorkspace"]),
            minWidth: extractDouble(effectFields["minWidth"]),
            minHeight: extractDouble(effectFields["minHeight"])
        )
        return (documentFields["order"].flatMap(extractInt), rule)
    }

    // MARK: - Samples

    private static func writeInactiveSamples(to directory: URL) throws {
        let samples: [(String, String)] = [
            (
                "pip-floating.toml.sample",
                """
                # Inactive sample. Rename to `.toml` and edit values to enable.
                # Float browser Picture-in-Picture windows.
                [match]
                bundleId = "com.apple.Safari"
                titleSubstring = "Picture in Picture"

                [effect]
                layout = "float"
                minWidth = 320
                minHeight = 180
                """
            ),
            (
                "dialog-floating.toml.sample",
                """
                # Inactive sample. Rename to `.toml` and edit values to enable.
                # Float dialogs while sending their parent app to a named workspace.
                [match]
                bundleId = "com.example.productivity-app"
                axRole = "AXDialog"
                axSubrole = "AXStandardWindow"

                [effect]
                layout = "float"
                assignToWorkspace = "3"
                minWidth = 480
                minHeight = 320
                """
            ),
            (
                "title-regex-workspace.toml.sample",
                """
                # Inactive sample. Rename to `.toml` and edit values to enable.
                # Match complex titles and route the window to a named workspace.
                [match]
                bundleId = "com.example.MyApp"
                titleRegex = "(?i)(server|logs|deploy)"

                [effect]
                assignToWorkspace = "6"
                minWidth = 900
                minHeight = 500
                """
            )
        ]

        for (filename, content) in samples {
            let fileURL = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func stableID(for filename: String, bundleId: String) -> UUID {
        let seed = filename.isEmpty ? bundleId : filename
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((hash >> UInt64((7 - i) * 8)) & 0xff) }
        hash = hash &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        for i in 0..<8 { bytes[i + 8] = UInt8((hash >> UInt64((7 - i) * 8)) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Helpers

    private static func sanitizedFilename(for rule: AppRule) -> String {
        let base = rule.bundleId
            .replacingOccurrences(of: ".", with: "-")
            .lowercased()

        var name = base
        if let titleSub = rule.titleSubstring {
            let suffix = titleSub
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "-")
                .lowercased()
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            if !suffix.isEmpty {
                name += "-\(suffix)"
            }
        }
        return name + ".toml"
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value)\""
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func extractString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            let result = String(trimmed.dropFirst().dropLast())
            return result.isEmpty ? nil : result
        }
        return nil
    }

    private static func extractDouble(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespaces))
    }

    private static func extractInt(_ raw: String) -> Int? {
        Int(raw.trimmingCharacters(in: .whitespaces))
    }
}
