import CoreGraphics
import Foundation

/// Reads and writes per-monitor overrides from `monitors.d/*.toml`.
///
/// Each file may contain `[match]`, `[niri]`, `[bar]`, and `[orientation]` sections.
enum MonitorOverrideFileStore {
    struct Documents {
        var bar: [MonitorBarSettings]
        var orientation: [MonitorOrientationSettings]
        var niri: [MonitorNiriSettings]
    }

    static func write(
        bar: [MonitorBarSettings],
        orientation: [MonitorOrientationSettings],
        niri: [MonitorNiriSettings],
        to directory: URL
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for fileURL in contents where fileURL.pathExtension == "toml" {
                try? fm.removeItem(at: fileURL)
            }
        }

        var keys: [MonitorKey: MonitorDocument] = [:]
        for item in bar {
            keys[MonitorKey(name: item.monitorName, displayId: item.monitorDisplayId), default: .init()].bar = item
        }
        for item in orientation {
            keys[MonitorKey(name: item.monitorName, displayId: item.monitorDisplayId), default: .init()].orientation = item
        }
        for item in niri {
            keys[MonitorKey(name: item.monitorName, displayId: item.monitorDisplayId), default: .init()].niri = item
        }

        for (key, document) in keys.sorted(by: { $0.key.name < $1.key.name }) {
            let fileURL = directory.appendingPathComponent(sanitizedFilename(for: key))
            try encode(key: key, document: document).write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func read(from directory: URL) -> Documents {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.nameKey], options: [.skipsHiddenFiles]) else {
            return Documents(bar: [], orientation: [], niri: [])
        }
        var result = Documents(bar: [], orientation: [], niri: [])
        for fileURL in contents.filter({ $0.pathExtension == "toml" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
                  let document = decode(content)
            else { continue }
            if let bar = document.bar { result.bar.append(bar) }
            if let orientation = document.orientation { result.orientation.append(orientation) }
            if let niri = document.niri { result.niri.append(niri) }
        }
        return result
    }

    private struct MonitorKey: Hashable {
        var name: String
        var displayId: CGDirectDisplayID?
    }

    private struct MonitorDocument {
        var bar: MonitorBarSettings?
        var orientation: MonitorOrientationSettings?
        var niri: MonitorNiriSettings?
    }

    private static func encode(key: MonitorKey, document: MonitorDocument) -> String {
        var lines: [String] = []
        lines.append("[match]")
        lines.append("name = \(quoted(key.name))")
        if let displayId = key.displayId { lines.append("displayId = \(displayId)") }

        if let niri = document.niri {
            lines.append("")
            lines.append("[niri]")
            if let v = niri.maxVisibleColumns { lines.append("maxVisibleColumns = \(v)") }
            if let v = niri.centerFocusedColumn { lines.append("centerFocusedColumn = \(quoted(v.rawValue))") }
            if let v = niri.alwaysCenterSingleColumn { lines.append("alwaysCenterSingleColumn = \(v)") }
            if let v = niri.singleWindowAspectRatio { lines.append("singleWindowAspectRatio = \(quoted(v.rawValue))") }
            if let v = niri.infiniteLoop { lines.append("infiniteLoop = \(v)") }
        }

        if let bar = document.bar {
            lines.append("")
            lines.append("[bar]")
            if let v = bar.enabled { lines.append("enabled = \(v)") }
            if let v = bar.showLabels { lines.append("showLabels = \(v)") }
            if let v = bar.showFloatingWindows { lines.append("showFloatingWindows = \(v)") }
            if let v = bar.deduplicateAppIcons { lines.append("deduplicateAppIcons = \(v)") }
            if let v = bar.hideEmptyWorkspaces { lines.append("hideEmptyWorkspaces = \(v)") }
            if let v = bar.reserveLayoutSpace { lines.append("reserveLayoutSpace = \(v)") }
            if let v = bar.notchAware { lines.append("notchAware = \(v)") }
            if let v = bar.position { lines.append("position = \(quoted(v.rawValue))") }
            if let v = bar.windowLevel { lines.append("windowLevel = \(quoted(v.rawValue))") }
            if let v = bar.height { lines.append("height = \(formatNumber(v))") }
            if let v = bar.backgroundOpacity { lines.append("backgroundOpacity = \(formatNumber(v))") }
            if let v = bar.xOffset { lines.append("xOffset = \(formatNumber(v))") }
            if let v = bar.yOffset { lines.append("yOffset = \(formatNumber(v))") }
        }

        if let orientation = document.orientation, let value = orientation.orientation {
            lines.append("")
            lines.append("[orientation]")
            lines.append("orientation = \(quoted(value.rawValue))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func decode(_ content: String) -> MonitorDocument? {
        var currentSection = ""
        var fields: [String: [String: String]] = [:]
        for rawLine in content.components(separatedBy: "\n") {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            fields[currentSection, default: [:]][key] = value
        }

        guard let match = fields["match"], let name = extractString(match["name"]) else { return nil }
        let displayId = match["displayId"].flatMap { CGDirectDisplayID($0.trimmingCharacters(in: .whitespaces)) }
        var document = MonitorDocument()

        if let niri = fields["niri"] {
            document.niri = MonitorNiriSettings(
                monitorName: name,
                monitorDisplayId: displayId,
                maxVisibleColumns: niri["maxVisibleColumns"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                centerFocusedColumn: niri["centerFocusedColumn"].flatMap(extractString).flatMap(CenterFocusedColumn.init(rawValue:)),
                alwaysCenterSingleColumn: niri["alwaysCenterSingleColumn"].flatMap(extractBool),
                singleWindowAspectRatio: niri["singleWindowAspectRatio"].flatMap(extractString).flatMap(SingleWindowAspectRatio.init(rawValue:)),
                infiniteLoop: niri["infiniteLoop"].flatMap(extractBool)
            )
        }

        if let bar = fields["bar"] {
            document.bar = MonitorBarSettings(
                monitorName: name,
                monitorDisplayId: displayId,
                enabled: bar["enabled"].flatMap(extractBool),
                showLabels: bar["showLabels"].flatMap(extractBool),
                showFloatingWindows: bar["showFloatingWindows"].flatMap(extractBool),
                deduplicateAppIcons: bar["deduplicateAppIcons"].flatMap(extractBool),
                hideEmptyWorkspaces: bar["hideEmptyWorkspaces"].flatMap(extractBool),
                reserveLayoutSpace: bar["reserveLayoutSpace"].flatMap(extractBool),
                notchAware: bar["notchAware"].flatMap(extractBool),
                position: bar["position"].flatMap(extractString).flatMap(WorkspaceBarPosition.init(rawValue:)),
                windowLevel: bar["windowLevel"].flatMap(extractString).flatMap(WorkspaceBarWindowLevel.init(rawValue:)),
                height: bar["height"].flatMap(extractDouble),
                backgroundOpacity: bar["backgroundOpacity"].flatMap(extractDouble),
                xOffset: bar["xOffset"].flatMap(extractDouble),
                yOffset: bar["yOffset"].flatMap(extractDouble)
            )
        }

        if let orientation = fields["orientation"] {
            document.orientation = MonitorOrientationSettings(
                monitorName: name,
                monitorDisplayId: displayId,
                orientation: orientation["orientation"].flatMap(extractString).flatMap(Monitor.Orientation.init(rawValue:))
            )
        }

        return document
    }

    private static func sanitizedFilename(for key: MonitorKey) -> String {
        let base = key.name.lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return (base.isEmpty ? "monitor" : base) + ".toml"
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for (idx, char) in line.enumerated() {
            if escaped { escaped = false }
            else if char == "\\" { escaped = true }
            else if char == "\"" { inString.toggle() }
            else if char == "#", !inString { return String(line.prefix(idx)) }
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

    private static func extractBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static func extractDouble(_ raw: String) -> Double? {
        Double(raw.trimmingCharacters(in: .whitespaces))
    }
}
