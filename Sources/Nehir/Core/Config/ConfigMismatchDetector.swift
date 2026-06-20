// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import TOML

/// Detects config keys present in `settings.toml` that the current config schema doesn't
/// recognize.
///
/// Unknown keys are diagnostics, not startup blockers. This detector compares the raw TOML
/// tree to the schema key paths derived from `CanonicalTOMLConfig.CodingKeys`, so it remains
/// preservation-aware: keys captured by the codec's unknown-field overflow are still reported
/// here because they are not modeled app settings.
///
/// Returns the unrecognized key paths in their original case. Empty when the file is missing
/// or unparseable; parse/decode failures are handled by startup recovery, not this list.
func detectUnknownKeys(in settingsFileURL: URL) -> [String] {
    guard FileManager.default.fileExists(atPath: settingsFileURL.path),
          let data = try? Data(contentsOf: settingsFileURL)
    else {
        return []
    }

    guard let rawTree = try? TOMLDecoder().decode(AnyTOML.self, from: data) else {
        return []
    }

    var rawKeyPaths: [String] = []
    var rawKeyPathsLowered = Set<String>()
    AnyTOML.collectKeyPaths(rawTree, into: &rawKeyPaths, lowercased: &rawKeyPathsLowered)

    let known = CanonicalTOMLConfig.knownKeyPathsLowercased
    return rawKeyPaths.filter { !known.contains($0.lowercased()) }
}

/// Deprecated compatibility wrapper. Unknown keys no longer represent a bootstrap mismatch;
/// use `detectUnknownKeys(in:)` for non-blocking Diagnostics issues.
func detectConfigMismatches(in settingsFileURL: URL) -> [String] {
    detectUnknownKeys(in: settingsFileURL)
}

/// Removes unknown keys from a settings.toml file, preserving all modeled values. Creates a
/// timestamped backup of the original first, then rewrites the file with the unknown keys
/// dropped. The live `SettingsStore` clears its cached unknown fields when its file watcher
/// reloads this rewrite. Throws on read/decode/write failure.
@discardableResult
func cleanUnknownSettingsKeys(fileURL: URL) throws -> URL {
    let backupURL = try createTimestampedSettingsBackup(for: fileURL)
    let data = try Data(contentsOf: fileURL)
    var export = try SettingsTOMLCodec.decode(data)
    export.settingsTOMLUnknownFields = [:]
    let clean = try SettingsTOMLCodec.encode(export)
    try clean.write(to: fileURL, options: .atomic)
    return backupURL
}

private func createTimestampedSettingsBackup(for fileURL: URL) throws -> URL {
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

extension CanonicalTOMLConfig {
    static var knownKeyPathsLowercased: Set<String> {
        var paths = Set<String>()
        func add(_ path: String) {
            paths.insert(path.lowercased())
        }
        func addTable<K: CodingKey & CaseIterable>(_ table: CodingKeys, _: K.Type) where K.AllCases: Sequence,
            K.AllCases.Element == K
        {
            add(table.stringValue)
            for key in K.allCases {
                add("\(table.stringValue).\(key.stringValue)")
            }
        }
        func addNested<K: CodingKey & CaseIterable>(_ parent: String, _: K.Type) where K.AllCases: Sequence,
            K.AllCases.Element == K
        {
            add(parent)
            for key in K.allCases {
                add("\(parent).\(key.stringValue)")
            }
        }

        addTable(.general, General.CodingKeys.self)
        addTable(.focus, Focus.CodingKeys.self)
        addTable(.mouseWarp, MouseWarp.CodingKeys.self)
        addTable(.gaps, Gaps.CodingKeys.self)
        addNested("gaps.outer", Gaps.Outer.CodingKeys.self)
        addTable(.niri, Niri.CodingKeys.self)
        addTable(.borders, Borders.CodingKeys.self)
        addNested("borders.color", Borders.Color.CodingKeys.self)
        addTable(.workspaceBar, WorkspaceBar.CodingKeys.self)
        addNested("workspaceBar.accentColor", WorkspaceBar.Color.CodingKeys.self)
        addNested("workspaceBar.textColor", WorkspaceBar.Color.CodingKeys.self)
        addTable(.gestures, Gestures.CodingKeys.self)
        addTable(.statusBar, StatusBar.CodingKeys.self)
        addTable(.appearance, Appearance.CodingKeys.self)
        return paths
    }
}

/// Recursively decodable wrapper that reconstructs a TOML tree generically, used only to
/// enumerate every key path present in the file. The value content is discarded.
private enum AnyTOML: Decodable {
    case table([String: AnyTOML])
    case array([AnyTOML])
    case other

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: SettingsTOMLDynamicKey.self) {
            var dict: [String: AnyTOML] = [:]
            for key in container.allKeys {
                dict[key.stringValue] = (try? container.decode(AnyTOML.self, forKey: key)) ?? .other
            }
            self = .table(dict)
        } else if var array = try? decoder.unkeyedContainer() {
            var items: [AnyTOML] = []
            while !array.isAtEnd {
                items.append((try? array.decode(AnyTOML.self)) ?? .other)
            }
            self = .array(items)
        } else {
            self = .other
        }
    }

    static func collectKeyPaths(
        _ value: AnyTOML,
        parentPath: [String] = [],
        into ordered: inout [String],
        lowercased: inout Set<String>
    ) {
        switch value {
        case .table(let dict):
            for (key, child) in dict {
                let path = parentPath + [key]
                let displayPath = path.joined(separator: ".")
                let loweredPath = displayPath.lowercased()
                if lowercased.insert(loweredPath).inserted {
                    ordered.append(displayPath)
                }
                collectKeyPaths(child, parentPath: path, into: &ordered, lowercased: &lowercased)
            }
        case .array(let items):
            for item in items {
                collectKeyPaths(item, parentPath: parentPath, into: &ordered, lowercased: &lowercased)
            }
        case .other:
            break
        }
    }
}
