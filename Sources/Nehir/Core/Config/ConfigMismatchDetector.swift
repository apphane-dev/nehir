import Foundation
import TOML

/// Detects config keys present in `settings.toml` that the current config schema doesn't
/// recognize.
///
/// No migration manifest is maintained. The valid key set is derived from the schema itself
/// via a round trip: the raw file is decoded into `CanonicalTOMLConfig` (Codable silently
/// drops keys not in `CodingKeys`) and re-encoded. Any key present in the raw file but absent
/// from the re-encoded output is a mismatch. When the schema changes (keys added or removed),
/// the round trip reflects it automatically — nothing to update here.
///
/// Returns the unrecognized key paths in their original case. Empty when the file
/// is missing or unparseable.
func detectConfigMismatches(in settingsFileURL: URL) -> [String] {
    guard FileManager.default.fileExists(atPath: settingsFileURL.path),
          let data = try? Data(contentsOf: settingsFileURL)
    else {
        return []
    }

    // All key paths present in the raw file (original case; de-duplicated).
    var rawKeyPaths: [String] = []
    var rawKeyPathsLowered = Set<String>()
    if let rawTree = try? TOMLDecoder().decode(AnyTOML.self, from: data) {
        AnyTOML.collectKeyPaths(rawTree, into: &rawKeyPaths, lowercased: &rawKeyPathsLowered)
    }

    // Round trip through the real schema: decode → re-encode → collect surviving key paths.
    // Unknown keys are dropped during decode, so they won't appear in the re-encoded output.
    var schemaKeyPathsLowered = Set<String>()
    if let canonical = try? TOMLDecoder().decode(CanonicalTOMLConfig.self, from: data),
       let reencoded = try? SettingsTOMLCodec.encode(canonical.toSettingsExport()),
       let schemaTree = try? TOMLDecoder().decode(AnyTOML.self, from: reencoded) {
        var throwaway: [String] = []
        AnyTOML.collectKeyPaths(schemaTree, into: &throwaway, lowercased: &schemaKeyPathsLowered)
    }

    return rawKeyPaths.filter { !schemaKeyPathsLowered.contains($0.lowercased()) }
}

/// Recursively decodable wrapper that reconstructs a TOML tree generically, used only to
/// enumerate every key path present in the file. The value content is discarded.
private enum AnyTOML: Decodable {
    case table([String: AnyTOML])
    case array([AnyTOML])
    case other

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: AnyTOMLKey.self) {
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

private struct AnyTOMLKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
