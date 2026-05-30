import AppKit
import SwiftUI

enum SettingsFileAction {
    case revealConfigFolder
    case openMainSettingsFile
}

@MainActor
enum SettingsFileWorkflow {
    static func perform(
        _ action: SettingsFileAction,
        settings: SettingsStore,
        openFile: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        revealFile: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) throws -> SettingsFileStatus {
        try settings.ensureConfigFilesAvailable()

        switch action {
        case .revealConfigFolder:
            revealFile([settings.configDirectoryURL])
            return .revealedConfigFolder
        case .openMainSettingsFile:
            guard openFile(settings.settingsFileURL) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return .openedSettingsFile
        }
    }
}

enum SettingsFileStatus: Equatable {
    case revealedConfigFolder
    case openedSettingsFile
    case error(String)

    var message: String {
        switch self {
        case .revealedConfigFolder: "Config folder revealed in Finder"
        case .openedSettingsFile: "settings.toml opened"
        case let .error(msg): "Error: \(msg)"
        }
    }

    var icon: String {
        switch self {
        case .openedSettingsFile,
             .revealedConfigFolder: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .openedSettingsFile,
             .revealedConfigFolder: .green
        case .error: .red
        }
    }
}
