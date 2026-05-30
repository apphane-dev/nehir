import Foundation

struct NehirStoragePaths: Equatable {
    let configDirectory: URL
    let stateDirectory: URL

    static var live: NehirStoragePaths {
        resolve()
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> NehirStoragePaths {
        let homeDirectory = homeDirectory.standardizedFileURL
        return NehirStoragePaths(
            configDirectory: directory(
                environmentKey: "XDG_CONFIG_HOME",
                fallbackBase: homeDirectory.appendingPathComponent(".config", isDirectory: true),
                environment: environment
            ),
            stateDirectory: directory(
                environmentKey: "XDG_STATE_HOME",
                fallbackBase: homeDirectory.appendingPathComponent(".local/state", isDirectory: true),
                environment: environment
            )
        )
    }

    private static func directory(
        environmentKey: String,
        fallbackBase: URL,
        environment: [String: String]
    ) -> URL {
        baseDirectory(
            environmentKey: environmentKey,
            fallbackBase: fallbackBase,
            environment: environment
        )
        .appendingPathComponent("nehir", isDirectory: true)
        .standardizedFileURL
    }

    private static func baseDirectory(
        environmentKey: String,
        fallbackBase: URL,
        environment: [String: String]
    ) -> URL {
        guard let path = environment[environmentKey], path.hasPrefix("/") else {
            return fallbackBase.standardizedFileURL
        }

        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
