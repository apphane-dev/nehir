// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import os

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
    private static let logger = Logger(subsystem: "com.nehir", category: "config")

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
        if let manage = rule.manage { effectLines.append("manage = \(quoted(manage.rawValue))") }
        if let layout = rule.layout { effectLines.append("layout = \(quoted(layout.rawValue))") }
        if let sticky = rule.sticky { effectLines.append("sticky = \(sticky ? "true" : "false")") }
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
        let tomlFiles = tomlFiles(in: directory)

        return tomlFiles.compactMap { fileURL -> (Int?, AppRule)? in
            guard let data = try? String(contentsOf: fileURL, encoding: .utf8) else {
                warn("App rule \(fileURL.lastPathComponent): skipping unreadable file")
                return nil
            }
            guard let decoded = decodeWithOrder(data, sourceFile: fileURL.lastPathComponent) else { return nil }
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

    static func diagnostics(from directory: URL) -> [AppRuleFileDiagnosticIssue] {
        tomlFiles(in: directory).compactMap { fileURL in
            guard let data = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return AppRuleFileDiagnosticIssue(
                    fileURL: fileURL,
                    messages: ["File could not be read as UTF-8."],
                    canClean: false
                )
            }

            let result = diagnostics(for: data)
            guard !result.messages.isEmpty else { return nil }
            return AppRuleFileDiagnosticIssue(
                fileURL: fileURL,
                messages: result.messages,
                canClean: result.canClean
            )
        }
    }

    @discardableResult
    static func cleanIgnoredEntries(fileURL: URL) throws -> URL {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        guard let (order, rule) = decodeWithOrder(content, sourceFile: fileURL.lastPathComponent) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let backupURL = try createTimestampedBackup(for: fileURL)
        try encode(rule, order: order).write(to: fileURL, atomically: true, encoding: .utf8)
        return backupURL
    }

    private static func tomlFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "toml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func decodeWithOrder(_ content: String, sourceFile: String = "") -> (Int?, AppRule)? {
        let sourceLabel = sourceFile.isEmpty ? "<memory>" : sourceFile
        var currentSection = ""
        var documentFields: [String: String] = [:]
        var matchFields: [String: String] = [:]
        var effectFields: [String: String] = [:]

        func warn(_ message: String) {
            Self.warn("App rule \(sourceLabel): \(message)")
        }

        func store(
            _ key: String,
            value rawValue: String,
            in fields: inout [String: String],
            section: String,
            lineNumber: Int
        ) {
            if fields.updateValue(rawValue, forKey: key) != nil {
                warn("line \(lineNumber): duplicate \(section).\(key); using the last value")
            }
        }

        for parsedLine in parsedLines(from: content) {
            let lineNumber = parsedLine.number
            let trimmed = parsedLine.text

            if trimmed.hasPrefix("[") {
                guard trimmed.hasSuffix("]") else {
                    warn("line \(lineNumber): skipping malformed section header")
                    continue
                }

                let section = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                guard !section.isEmpty else {
                    currentSection = ""
                    warn("line \(lineNumber): skipping empty section header")
                    continue
                }

                currentSection = section
                switch section {
                case "match",
                     "effect": break
                default:
                    warn("line \(lineNumber): ignoring unknown section [\(section)]")
                }
                continue
            }

            guard let eqIndex = trimmed.firstIndex(of: "=") else {
                warn("line \(lineNumber): skipping malformed line without '='")
                continue
            }
            let key = String(trimmed[trimmed.startIndex ..< eqIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                warn("line \(lineNumber): skipping malformed line with an empty key")
                continue
            }

            switch currentSection {
            case "":
                switch key {
                case "id",
                     "order": store(
                        key,
                        value: rawValue,
                        in: &documentFields,
                        section: "document",
                        lineNumber: lineNumber
                    )
                default: warn("line \(lineNumber): ignoring unknown document key \(key)")
                }
            case "match":
                switch key {
                case "bundleId",
                     "appName",
                     "titleSubstring",
                     "titleRegex",
                     "axRole",
                     "axSubrole":
                    store(key, value: rawValue, in: &matchFields, section: "match", lineNumber: lineNumber)
                default:
                    warn("line \(lineNumber): ignoring unknown match key \(key)")
                }
            case "effect":
                switch key {
                case "manage",
                     "layout",
                     "sticky",
                     "minWidth",
                     "minHeight",
                     "assignToWorkspace":
                    store(key, value: rawValue, in: &effectFields, section: "effect", lineNumber: lineNumber)
                default:
                    warn("line \(lineNumber): ignoring unknown effect key \(key)")
                }
            default:
                warn("line \(lineNumber): ignoring key \(key) in unknown section [\(currentSection)]")
            }
        }

        func stringField(_ fields: [String: String], _ key: String, path: String) -> String? {
            guard let raw = fields[key] else { return nil }
            guard let value = extractString(raw) else {
                warn("ignoring \(path); expected a non-empty quoted string")
                return nil
            }
            return value
        }

        func doubleField(_ fields: [String: String], _ key: String, path: String) -> Double? {
            guard let raw = fields[key] else { return nil }
            guard let value = extractDouble(raw) else {
                warn("ignoring \(path); expected a number")
                return nil
            }
            return value
        }

        func boolField(_ fields: [String: String], _ key: String, path: String) -> Bool? {
            guard let raw = fields[key] else { return nil }
            guard let value = extractBool(raw) else {
                warn("ignoring \(path); expected true or false")
                return nil
            }
            return value
        }

        func manageField() -> WindowRuleManageAction? {
            guard let raw = effectFields["manage"] else { return nil }
            guard let value = extractString(raw) else {
                warn("ignoring effect.manage; expected a quoted string")
                return nil
            }
            guard let action = WindowRuleManageAction(rawValue: value) else {
                warn("ignoring effect.manage; unknown value \(value)")
                return nil
            }
            return action
        }

        func layoutField() -> WindowRuleLayoutAction? {
            guard let raw = effectFields["layout"] else { return nil }
            guard let value = extractString(raw) else {
                warn("ignoring effect.layout; expected a quoted string")
                return nil
            }
            guard let action = WindowRuleLayoutAction(rawValue: value) else {
                warn("ignoring effect.layout; unknown value \(value)")
                return nil
            }
            return action
        }

        let id = stringField(documentFields, "id", path: "document.id").flatMap { value -> UUID? in
            guard let uuid = UUID(uuidString: value) else {
                warn("ignoring document.id; expected a UUID string")
                return nil
            }
            return uuid
        }

        let order = documentFields["order"].flatMap { raw -> Int? in
            guard let value = extractInt(raw) else {
                warn("ignoring document.order; expected an integer")
                return nil
            }
            return value
        }

        guard let bundleId = stringField(matchFields, "bundleId", path: "match.bundleId") else {
            warn("skipping file; missing or invalid required match.bundleId")
            return nil
        }

        let rule = AppRule(
            id: id ?? stableID(for: sourceFile, bundleId: bundleId),
            bundleId: bundleId,
            appNameSubstring: stringField(matchFields, "appName", path: "match.appName"),
            titleSubstring: stringField(matchFields, "titleSubstring", path: "match.titleSubstring"),
            titleRegex: stringField(matchFields, "titleRegex", path: "match.titleRegex"),
            axRole: stringField(matchFields, "axRole", path: "match.axRole"),
            axSubrole: stringField(matchFields, "axSubrole", path: "match.axSubrole"),
            manage: manageField(),
            layout: layoutField(),
            assignToWorkspace: stringField(effectFields, "assignToWorkspace", path: "effect.assignToWorkspace"),
            minWidth: doubleField(effectFields, "minWidth", path: "effect.minWidth"),
            minHeight: doubleField(effectFields, "minHeight", path: "effect.minHeight"),
            sticky: boolField(effectFields, "sticky", path: "effect.sticky")
        )
        return (order, rule)
    }

    private struct AppRuleDiagnostics {
        let messages: [String]
        let canClean: Bool
    }

    private static func diagnostics(for content: String) -> AppRuleDiagnostics {
        var currentSection = ""
        var documentFields: [String: String] = [:]
        var matchFields: [String: String] = [:]
        var effectFields: [String: String] = [:]
        var messages: [String] = []

        func append(_ lineNumber: Int?, _ message: String) {
            if let lineNumber {
                messages.append("Line \(lineNumber): \(message)")
            } else {
                messages.append(message)
            }
        }

        func store(
            _ key: String,
            value rawValue: String,
            in fields: inout [String: String],
            path: String,
            lineNumber: Int
        ) {
            if fields.updateValue(rawValue, forKey: key) != nil {
                append(lineNumber, "duplicate \(path).\(key); the last value is used")
            }
        }

        for parsedLine in parsedLines(from: content) {
            let lineNumber = parsedLine.number
            let trimmed = parsedLine.text

            if trimmed.hasPrefix("[") {
                guard trimmed.hasSuffix("]") else {
                    append(lineNumber, "malformed section header")
                    continue
                }

                let section = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                guard !section.isEmpty else {
                    currentSection = ""
                    append(lineNumber, "empty section header")
                    continue
                }

                currentSection = section
                switch section {
                case "match",
                     "effect": break
                default:
                    append(lineNumber, "unknown section [\(section)]")
                }
                continue
            }

            guard let eqIndex = trimmed.firstIndex(of: "=") else {
                append(lineNumber, "malformed line without '='")
                continue
            }

            let key = String(trimmed[trimmed.startIndex ..< eqIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                append(lineNumber, "empty key")
                continue
            }

            switch currentSection {
            case "":
                switch key {
                case "id",
                     "order": store(
                        key,
                        value: rawValue,
                        in: &documentFields,
                        path: "document",
                        lineNumber: lineNumber
                    )
                default: append(lineNumber, "unknown document key \(key)")
                }
            case "match":
                switch key {
                case "bundleId",
                     "appName",
                     "titleSubstring",
                     "titleRegex",
                     "axRole",
                     "axSubrole":
                    store(key, value: rawValue, in: &matchFields, path: "match", lineNumber: lineNumber)
                default:
                    append(lineNumber, "unknown match key \(key)")
                }
            case "effect":
                switch key {
                case "manage",
                     "layout",
                     "sticky",
                     "minWidth",
                     "minHeight",
                     "assignToWorkspace":
                    store(key, value: rawValue, in: &effectFields, path: "effect", lineNumber: lineNumber)
                default:
                    append(lineNumber, "unknown effect key \(key)")
                }
            default:
                append(lineNumber, "key \(key) is ignored because section [\(currentSection)] is unknown")
            }
        }

        appendInvalidString(documentFields["id"], path: "document.id", to: &messages)
        if let rawID = documentFields["id"], let id = extractString(rawID), UUID(uuidString: id) == nil {
            messages.append("document.id is not a valid UUID string")
        }
        if let rawOrder = documentFields["order"], extractInt(rawOrder) == nil {
            messages.append("document.order is not a valid integer")
        }

        let validBundleId = extractString(matchFields["bundleId"]) != nil
        if matchFields["bundleId"] == nil {
            messages.append("match.bundleId is required and must be a non-empty quoted string")
        } else {
            appendInvalidString(matchFields["bundleId"], path: "match.bundleId", to: &messages)
        }
        for key in ["appName", "titleSubstring", "titleRegex", "axRole", "axSubrole"] {
            appendInvalidString(matchFields[key], path: "match.\(key)", to: &messages)
        }

        appendInvalidEnum(
            effectFields["manage"],
            path: "effect.manage",
            validValues: WindowRuleManageAction.allCases.map(\.rawValue),
            to: &messages
        )
        appendInvalidEnum(
            effectFields["layout"],
            path: "effect.layout",
            validValues: WindowRuleLayoutAction.allCases.map(\.rawValue),
            to: &messages
        )
        appendInvalidString(effectFields["assignToWorkspace"], path: "effect.assignToWorkspace", to: &messages)
        if let rawMinWidth = effectFields["minWidth"], extractDouble(rawMinWidth) == nil {
            messages.append("effect.minWidth is not a valid number")
        }
        if let rawMinHeight = effectFields["minHeight"], extractDouble(rawMinHeight) == nil {
            messages.append("effect.minHeight is not a valid number")
        }
        if let rawSticky = effectFields["sticky"], extractBool(rawSticky) == nil {
            messages.append("effect.sticky must be true or false")
        }

        return AppRuleDiagnostics(messages: messages, canClean: validBundleId)
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
                sticky = true
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
        for i in 0 ..< 8 { bytes[i] = UInt8((hash >> UInt64((7 - i) * 8)) & 0xff) }
        hash = hash &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        for i in 0 ..< 8 { bytes[i + 8] = UInt8((hash >> UInt64((7 - i) * 8)) & 0xff) }
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

    private struct ParsedLine {
        let number: Int
        let text: String
    }

    private static func parsedLines(from content: String) -> [ParsedLine] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return normalized.components(separatedBy: "\n").enumerated().compactMap { offset, line in
            let trimmed = stripInlineComment(from: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ParsedLine(number: offset + 1, text: trimmed)
        }
    }

    private static func stripInlineComment(from line: String) -> String {
        var result = ""
        var isInString = false
        var isEscaped = false

        for character in line {
            if character == "#", !isInString {
                break
            }

            result.append(character)

            if isEscaped {
                isEscaped = false
            } else if character == "\\", isInString {
                isEscaped = true
            } else if character == "\"" {
                isInString.toggle()
            }
        }

        return result
    }

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

    private static func extractBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func extractInt(_ raw: String) -> Int? {
        Int(raw.trimmingCharacters(in: .whitespaces))
    }

    private static func appendInvalidString(_ raw: String?, path: String, to messages: inout [String]) {
        guard let raw, extractString(raw) == nil else { return }
        messages.append("\(path) must be a non-empty quoted string")
    }

    private static func appendInvalidEnum(
        _ raw: String?,
        path: String,
        validValues: [String],
        to messages: inout [String]
    ) {
        guard let raw else { return }
        guard let value = extractString(raw) else {
            messages.append("\(path) must be a quoted string")
            return
        }
        if !validValues.contains(value) {
            messages
                .append("\(path) has unknown value \(value); expected one of \(validValues.joined(separator: ", "))")
        }
    }

    private static func createTimestampedBackup(for fileURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension
        let backupName = fileExtension.isEmpty
            ? "\(baseName)-\(stamp).backup"
            : "\(baseName)-\(stamp).\(fileExtension).backup"

        var backupURL = directory.appendingPathComponent(backupName, isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: backupURL.path) {
            let suffixedName = fileExtension.isEmpty
                ? "\(baseName)-\(stamp)-\(suffix).backup"
                : "\(baseName)-\(stamp)-\(suffix).\(fileExtension).backup"
            backupURL = directory.appendingPathComponent(suffixedName, isDirectory: false)
            suffix += 1
        }

        try fileManager.copyItem(at: fileURL, to: backupURL)
        return backupURL
    }

    private static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
}
