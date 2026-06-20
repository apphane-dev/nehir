// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case about
    case behavior
    case layout
    case monitors
    case workspaces
    case borders
    case bar
    case appRules
    case hotkeys
    case diagnostics

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .general: "General"
        case .about: "About"
        case .behavior: "Gestures & Focus"
        case .layout: "Layout"
        case .monitors: "Monitors"
        case .workspaces: "Workspaces"
        case .borders: "Borders"
        case .bar: "Workspace Bar"
        case .appRules: "App Rules"
        case .hotkeys: "Hotkeys"
        case .diagnostics: "Diagnostics"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .about: "info.circle"
        case .behavior: "slider.horizontal.3"
        case .layout: "square.split.2x1"
        case .monitors: "display"
        case .workspaces: "rectangle.3.group"
        case .borders: "square.dashed"
        case .bar: "menubar.rectangle"
        case .appRules: "list.bullet.rectangle"
        case .hotkeys: "keyboard"
        case .diagnostics: "exclamationmark.triangle"
        }
    }
}

enum SettingsSectionGroup: String, CaseIterable, Identifiable {
    case app = ""
    case layouts = "Layout"
    case appearance = "Appearance"
    case input = "Input"

    var id: String {
        rawValue
    }

    var displayName: String? {
        rawValue.isEmpty ? nil : rawValue
    }

    var sections: [SettingsSection] {
        switch self {
        case .app:
            [.general, .about, .diagnostics]
        case .layouts:
            [.layout, .monitors, .workspaces, .appRules]
        case .appearance:
            [.bar, .borders]
        case .input:
            [.behavior, .hotkeys]
        }
    }
}
