import Foundation

enum BuildVersion {
    /// Version display string.
    /// In debug builds inside a git repo, shows the commit hash (with `*` for dirty).
    /// Otherwise uses the bundle version from Info.plist.
    static var display: String {
        #if DEBUG
        if let gitVersion = gitVersionString() {
            return gitVersion
        }
        #endif
        return Bundle.main.appVersion ?? "dev"
    }

    #if DEBUG
    private static func gitVersionString() -> String? {
        let gitPath = ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let gitPath else { return nil }

        let executableURL = URL(fileURLWithPath: gitPath)

        guard let hash = run(executableURL, arguments: ["rev-parse", "--short=6", "HEAD"]) else {
            return nil
        }

        let isDirty = run(executableURL, arguments: ["diff", "--quiet", "HEAD"]) == nil
        return isDirty ? "\(hash)*" : hash
    }

    private static func run(_ executableURL: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let resourcePath = Bundle.main.resourcePath {
            process.currentDirectoryURL = URL(fileURLWithPath: resourcePath).deletingLastPathComponent()
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
    #endif
}
