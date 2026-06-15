// SPDX-License-Identifier: GPL-2.0-only
import Darwin
import Foundation

/// Persists a single "last seen" app version as a plain-text file.
///
/// Two facts collapse into one:
/// - **File existence** = onboarding has been completed (a missing file re-presents the wizard).
/// - **File content**    = the version last seen by the user (onboarding finish *or* What's New
///   acknowledgement), compared against the running version to decide whether to auto-show
///   What's New.
///
/// This replaces the previous two-field JSON state. With one version, a user who just finished
/// onboarding at v1.0 won't be re-shown What's New for v1.0 on the next launch (the file already
/// records v1.0) — What's New is reachable instead via the onboarding final screen and the menu.
@MainActor
final class OnboardingStateStore {
    nonisolated static let defaultDirectoryURL = NehirStoragePaths.live.stateDirectory
    nonisolated static let fileName = "onboarding-version"
    nonisolated static var fileURL: URL {
        defaultDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    let directoryURL: URL
    let fileURL: URL

    private let deferSaves: Bool
    private var version: String?
    private var pendingVersion: String?
    private var saveScheduled = false

    init(
        directory: URL = OnboardingStateStore.defaultDirectoryURL,
        deferSaves: Bool = true
    ) {
        directoryURL = directory
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.deferSaves = deferSaves
        version = Self.readVersion(from: fileURL)
    }

    /// `true` when onboarding has been completed at least once (the version file exists).
    var hasCompletedOnboarding: Bool {
        version != nil
    }

    /// The version string recorded when the user last finished onboarding or acknowledged
    /// What's New. `nil` until the wizard is completed.
    var lastSeenVersion: String? {
        version
    }

    /// Records `version` as the last-seen version and persists it.
    func record(version: String) {
        guard self.version != version || pendingVersion != version else { return }
        self.version = version
        pendingVersion = version
        scheduleSave()
    }

    func flushNow() {
        guard let pendingVersion else { return }
        self.pendingVersion = nil
        write(pendingVersion)
    }

    private func scheduleSave() {
        if !deferSaves {
            if let pendingVersion {
                self.pendingVersion = nil
                write(pendingVersion)
            }
            return
        }

        guard !saveScheduled else { return }
        saveScheduled = true

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            saveScheduled = false
            flushNow()
        }
    }

    private func write(_ version: String) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Self.applyPermissions(S_IRWXU, to: directoryURL)
            let data = Data((version + "\n").utf8)
            try Self.writePrivateData(data, to: fileURL)
        } catch {
            fputs("[OnboardingStateStore] Failed to save \(fileURL.path): \(error.localizedDescription)\n", stderr)
        }
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

    /// Reads the plain-text version (first non-empty line, trimmed). Returns `nil` if the file
    /// is missing or empty.
    private static func readVersion(from url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
