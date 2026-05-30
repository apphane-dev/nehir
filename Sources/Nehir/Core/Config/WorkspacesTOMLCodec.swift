import Foundation

/// Human-readable workspace list in `workspaces.toml`.
///
/// ```toml
/// [[workspace]]
/// name = "1"
/// monitor = "main"
///
/// [[workspace]]
/// name = "6"
/// displayName = "❤️"
/// monitor = "secondary"
/// ```
enum WorkspacesTOMLCodec {
    static func encode(_ workspaces: [WorkspaceConfiguration]) -> Data {
        var lines: [String] = []
        for workspace in workspaces.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if !lines.isEmpty { lines.append("") }
            lines.append("[[workspace]]")
            lines.append("name = \(quoted(workspace.name))")
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
        var rows: [[String: String]] = []
        var current: [String: String]?

        for rawLine in string.components(separatedBy: "\n") {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "[[workspace]]" {
                if let current { rows.append(current) }
                current = [:]
                continue
            }
            guard var row = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            row[key] = value
            current = row
        }
        if let current { rows.append(current) }

        return rows.compactMap { row in
            guard let name = extractString(row["name"]) else { return nil }
            let monitor = extractString(row["monitor"]) ?? "main"
            let assignment: MonitorAssignment
            switch monitor {
            case "main": assignment = .main
            case "secondary": assignment = .secondary
            case "specific":
                guard let monitorName = extractString(row["monitorName"]),
                      let displayIdRaw = row["monitorDisplayId"],
                      let displayId = UInt32(displayIdRaw.trimmingCharacters(in: .whitespaces))
                else { assignment = .main; break }
                assignment = .specificDisplay(OutputId(displayId: displayId, name: monitorName))
            default:
                assignment = .main
            }
            return WorkspaceConfiguration(
                name: name,
                displayName: extractString(row["displayName"]),
                monitorAssignment: assignment
            )
        }
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
