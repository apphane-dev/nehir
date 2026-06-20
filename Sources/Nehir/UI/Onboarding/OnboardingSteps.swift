// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case navigation
    case workspaceBar
    case experimental
    case done

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .welcome:
            "Meet Nehir"
        case .navigation:
            "Focus & Move"
        case .workspaceBar:
            "Workspace Bar"
        case .experimental:
            "Cutting-Edge Features"
        case .done:
            "You're All Set!"
        }
    }

    var bodyText: String {
        switch self {
        case .welcome:
            "Nehir arranges your windows into a continuous horizontal river. Columns are balanced automatically, meaning you spend less time resizing and more time working."
        case .navigation:
            "Navigate and arrange windows effortlessly with the keyboard. Moving a window merges it into a stack or creates a new column."
        case .workspaceBar:
            "Enable a small floating bar at the top of your screen to track your active workspaces at a glance. You can toggle this later from the menu bar icon."
        case .experimental:
            "These options are in active development. They provide advanced window management but may occasionally exhibit unexpected behavior."
        case .done:
            "Nehir is ready to use. You can revisit this tour anytime from Settings → General."
        }
    }

    var continueButtonTitle: String {
        self == .done ? "Start Using Nehir" : "Continue"
    }

    /// Height reserved for the animation/icon area. Full height for animated steps; a compact
    /// height for static-icon steps so their content fits the fixed-size window.
    var animationHeight: CGFloat {
        switch self {
        case .welcome,
             .navigation:
            200
        case .workspaceBar:
            100
        case .experimental,
             .done:
            80
        }
    }
}
