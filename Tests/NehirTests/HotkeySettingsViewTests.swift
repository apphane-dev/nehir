// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Carbon
import Foundation
@testable import Nehir
import Testing

struct HotkeySettingsViewTests {
    @Test func hotkeyDisplayModelSearchMatchesPhysicalShortcutTerms() {
        let binding = HotkeyBinding(
            id: "focusLeft",
            command: .focus(.left),
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | cmdKey))
        )

        #expect(binding.binding.displayString == "⌥⌘K")
        #expect(HotkeySettingsDisplayModel.matchesSearch("Command", binding: binding))
        #expect(!HotkeySettingsDisplayModel.matchesSearch("Hyper", binding: binding))
    }

    @Test func numberedWorkspaceHotkeysCollapseToPatternDisplay() throws {
        let bindings = try switchWorkspaceDefaults()

        #expect(HotkeySettingsDisplayModel.numberedGroupDisplayString(for: bindings) == "⌥⌘{N}")
        #expect(HotkeySettingsDisplayModel.numberedGroupHumanReadableString(for: bindings) == "Option+Command+{N}")
        #expect(HotkeySettingsDisplayModel.matchesSearch(
            "workspace",
            groupTitle: "Switch Workspace {N}",
            bindings: bindings
        ))
        #expect(HotkeySettingsDisplayModel.matchesSearch(
            "Command",
            groupTitle: "Switch Workspace {N}",
            bindings: bindings
        ))
    }

    @Test func numberedWorkspaceHotkeysShowCustomWhenPatternDiverges() throws {
        var bindings = try switchWorkspaceDefaults()
        bindings[2] = HotkeyBinding(
            id: "switchWorkspace.2",
            command: .switchWorkspace(2),
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))
        )

        #expect(HotkeySettingsDisplayModel.numberedGroupDisplayString(for: bindings) == "Custom per-number")
    }

    private func switchWorkspaceDefaults() throws -> [HotkeyBinding] {
        let defaults = HotkeyBindingRegistry.defaults()
        return try (0 ..< 9).map { index in
            try #require(defaults.first { $0.id == "switchWorkspace.\(index)" })
        }
    }
}
