// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

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
