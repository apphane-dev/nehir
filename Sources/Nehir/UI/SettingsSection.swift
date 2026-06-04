import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case diagnostics
    case niri
    case monitors
    case workspaces
    case borders
    case bar
    case hotkeys

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .general: "General"
        case .diagnostics: "Diagnostics"
        case .niri: "Niri Layout"
        case .monitors: "Monitors"
        case .workspaces: "Workspaces"
        case .borders: "Borders"
        case .bar: "Workspace Bar"
        case .hotkeys: "Hotkeys"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .diagnostics: "exclamationmark.triangle"
        case .niri: "scroll"
        case .monitors: "display"
        case .workspaces: "rectangle.3.group"
        case .borders: "square.dashed"
        case .bar: "menubar.rectangle"
        case .hotkeys: "keyboard"
        }
    }
}

enum SettingsSectionGroup: String, CaseIterable, Identifiable {
    case basics = "Basics"
    case layouts = "Layouts"
    case workspace = "Workspace"
    case input = "Input"

    var id: String {
        rawValue
    }

    var sections: [SettingsSection] {
        switch self {
        case .basics:
            [.general, .diagnostics]
        case .layouts:
            [.niri, .monitors]
        case .workspace:
            [.workspaces, .borders, .bar]
        case .input:
            [.hotkeys]
        }
    }
}
