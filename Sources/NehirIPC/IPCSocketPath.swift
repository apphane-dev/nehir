import Foundation

public enum IPCSocketPath {
    public static let environmentKey = "NEHIR_SOCKET"
    public static let secretSuffix = ".secret"

    public static func resolvedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        if let override = environment[environmentKey], !override.isEmpty {
            return override
        }

        if let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return cachesDirectory
                .appendingPathComponent("dev.guria.nehir", isDirectory: true)
                .appendingPathComponent("ipc.sock", isDirectory: false)
                .path
        }

        return NSString(string: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/dev.guria.nehir/ipc.sock")
    }

    public static func secretPath(forSocketPath socketPath: String) -> String {
        socketPath + secretSuffix
    }

    public static func resolvedSecretPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        secretPath(forSocketPath: resolvedPath(environment: environment, fileManager: fileManager))
    }
}
