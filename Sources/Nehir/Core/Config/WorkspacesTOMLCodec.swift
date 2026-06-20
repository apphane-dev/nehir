import CoreGraphics
import Foundation
import NehirIPC

/// Human-readable workspace list in `workspaces.toml`.
///
/// Canonical format:
/// ```toml
/// [1]
/// monitor = "main"
///
/// [6]
/// displayName = "❤️"
/// monitor = "secondary"
/// ```
///
/// Legacy `[[workspace]]` arrays are still decoded during the migration window,
/// but new writes use keyed tables.
enum WorkspacesTOMLCodec {
    static func encode(_ workspaces: [WorkspaceConfiguration]) -> Data {
        var lines: [String] = []
        for workspace in workspaces.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(tableKey(workspace.name))]")
            if let displayName = workspace.displayName, !displayName.isEmpty {
                lines.append("displayName = \(quoted(displayName))")
            }
            switch workspace.monitorAssignment {
            case .main:
                lines.append("monitor = \"main\"")
            case .secondary:
                lines.append("monitor = \"secondary\"")
            case let .specificDisplay(output):
                lines.append("monitor = \"specific\"")
                lines.append("monitorName = \(quoted(output.name))")
                lines.append("monitorDisplayId = \(output.displayId)")
                if let anchor = output.anchorPoint {
                    lines.append("monitorAnchorX = \(anchor.x)")
                    lines.append("monitorAnchorY = \(anchor.y)")
                }
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func decode(_ data: Data, defaults: [WorkspaceConfiguration]) -> [WorkspaceConfiguration] {
        guard let string = String(data: data, encoding: .utf8) else { return defaults }
        let decoded = decode(string: string)
        return decoded.isEmpty ? defaults : decoded
    }

    static func decode(string: String) -> [WorkspaceConfiguration] {
        parseRows(string).compactMap { row in
            guard let name = row.name else { return nil }
            let monitor = extractString(row.values["monitor"]) ?? "main"
            let assignment: MonitorAssignment
            switch monitor {
            case "main": assignment = .main
            case "secondary": assignment = .secondary
            case "specific":
                guard let monitorName = extractString(row.values["monitorName"]),
                      let displayIdRaw = row.values["monitorDisplayId"],
                      let displayId = UInt32(displayIdRaw.trimmingCharacters(in: .whitespaces))
                else { assignment = .main
                    break
                }
                let anchorPoint = parseAnchorPoint(
                    x: row.values["monitorAnchorX"],
                    y: row.values["monitorAnchorY"]
                )
                assignment = .specificDisplay(
                    OutputId(displayId: displayId, name: monitorName, anchorPoint: anchorPoint)
                )
            default:
                assignment = .main
            }
            return WorkspaceConfiguration(
                name: name,
                displayName: extractString(row.values["displayName"]),
                monitorAssignment: assignment
            )
        }
    }

    static func containsLegacyWorkspaceArray(string: String) -> Bool {
        for rawLine in string.components(separatedBy: "\n") {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line == "[[workspace]]" {
                return true
            }
        }
        return false
    }

    private struct Row {
        var name: String?
        var values: [String: String]
    }

    private enum SectionKind {
        case none
        case legacyWorkspace
        case keyedWorkspace(name: String)
        case ignored
    }

    private static func parseRows(_ string: String) -> [Row] {
        var rows: [Row] = []
        var currentValues: [String: String] = [:]
        var currentKind: SectionKind = .none

        func flushCurrent() {
            switch currentKind {
            case .legacyWorkspace:
                rows.append(Row(name: extractString(currentValues["name"]), values: currentValues))
            case let .keyedWorkspace(name):
                rows.append(Row(name: name, values: currentValues))
            case .none,
                 .ignored:
                break
            }
            currentValues = [:]
        }

        for rawLine in string.components(separatedBy: "\n") {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                flushCurrent()
                currentKind = sectionKind(for: line)
                continue
            }

            guard shouldCollectValues(in: currentKind), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            currentValues[key] = value
        }
        flushCurrent()

        return rows
    }

    private static func shouldCollectValues(in kind: SectionKind) -> Bool {
        switch kind {
        case .legacyWorkspace,
             .keyedWorkspace:
            return true
        case .none,
             .ignored:
            return false
        }
    }

    private static func sectionKind(for line: String) -> SectionKind {
        if line == "[[workspace]]" {
            return .legacyWorkspace
        }

        guard line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[["), !line.hasSuffix("]]"),
              line.count >= 2
        else {
            return .ignored
        }

        let rawName = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard let name = parseTableName(rawName), WorkspaceIDPolicy.normalizeRawID(name) != nil else {
            return .ignored
        }
        return .keyedWorkspace(name: name)
    }

    private static func parseTableName(_ rawName: String) -> String? {
        if rawName.hasPrefix("\"") && rawName.hasSuffix("\"") {
            return extractString(rawName)
        }
        guard !rawName.contains(".") else { return nil }
        return rawName.isEmpty ? nil : rawName
    }

    private static func tableKey(_ value: String) -> String {
        // TOML 1.0 bare keys allow only ASCII A-Z a-z 0-9 _ -. Unicode letters/numerals
        // (é, α, superscripts, etc.) must be emitted quoted.
        guard value.allSatisfy({
            ("a" ... "z").contains($0) || ("A" ... "Z").contains($0) || ("0" ... "9")
                .contains($0) || $0 == "_" || $0 == "-"
        }), !value.isEmpty else {
            return quoted(value)
        }
        return value
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for (idx, char) in line.enumerated() {
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if char == "#", !inString {
                return String(line.prefix(idx))
            }
        }
        return line
    }

    private static func parseAnchorPoint(x: String?, y: String?) -> CGPoint? {
        guard let x, let y,
              let anchorX = Double(x.trimmingCharacters(in: .whitespaces)),
              let anchorY = Double(y.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return CGPoint(x: anchorX, y: anchorY)
    }

    private static func extractString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 else { return nil }
        let value = String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return value.isEmpty ? nil : value
    }
}
