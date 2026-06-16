import Darwin
import Foundation

struct SettingsMigrationPostponeRecord: Codable, Equatable {
    var appVersion: String
    var postponedAt: Date
}

struct SettingsMigrationState: Codable, Equatable {
    var postponed: [String: SettingsMigrationPostponeRecord] = [:]
}

final class SettingsMigrationStateStore {
    nonisolated static let defaultDirectoryURL = NehirStoragePaths.live.stateDirectory
    nonisolated static let fileName = "settings-migration-state.json"
    nonisolated static var fileURL: URL {
        defaultDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    let directoryURL: URL
    let fileURL: URL

    private var state: SettingsMigrationState

    init(directory: URL = SettingsMigrationStateStore.defaultDirectoryURL) {
        directoryURL = directory
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        state = Self.readState(from: fileURL)
    }

    func load() -> SettingsMigrationState {
        state
    }

    func isPostponed(migrationID: String, currentAppVersion: String) -> Bool {
        state.postponed[migrationID]?.appVersion == currentAppVersion
    }

    func postpone(migrationID: String, currentAppVersion: String, date: Date = Date()) throws {
        state.postponed[migrationID] = SettingsMigrationPostponeRecord(
            appVersion: currentAppVersion,
            postponedAt: date
        )
        try writeState(state)
    }

    func clearPostpone(migrationID: String) throws {
        state.postponed[migrationID] = nil
        try writeState(state)
    }

    private func writeState(_ state: SettingsMigrationState) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Self.applyPermissions(S_IRWXU, to: directoryURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try Self.writePrivateData(data, to: fileURL)
    }

    private static func writePrivateData(_ data: Data, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp", isDirectory: false)

        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            try applyPermissions(S_IRUSR | S_IWUSR, to: tempURL)
            try replaceItem(at: fileURL, with: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private static func applyPermissions(_ permissions: mode_t, to url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.chmod(path, permissions)
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath -> CInt in
            guard let sourcePath else { return -1 }
            return destinationURL.withUnsafeFileSystemRepresentation { destinationPath -> CInt in
                guard let destinationPath else { return -1 }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func readState(from url: URL) -> SettingsMigrationState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SettingsMigrationState()
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SettingsMigrationState.self, from: data)
        } catch {
            fputs("[SettingsMigrationStateStore] Failed to load \(url.path): \(error.localizedDescription)\n", stderr)
            return SettingsMigrationState()
        }
    }
}
