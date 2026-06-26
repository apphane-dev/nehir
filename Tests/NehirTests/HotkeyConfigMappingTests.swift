// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

@testable import Nehir
import Testing

@Suite struct HotkeyConfigMappingTests {
    @Test func isNumberedGroupMemberSharedHelper() {
        // Numbered-group slots (edited as a 1–9 pattern in the Hotkeys tab)…
        #expect(HotkeyConfigMapping.isNumberedGroupMember("switchWorkspace.1"))
        #expect(HotkeyConfigMapping.isNumberedGroupMember("switchWorkspace.0"))
        #expect(HotkeyConfigMapping.isNumberedGroupMember("focusColumn.8"))
        #expect(HotkeyConfigMapping.isNumberedGroupMember("moveToWorkspace.5"))
        #expect(HotkeyConfigMapping.isNumberedGroupMember("focusWindowInColumn.9"))
        #expect(HotkeyConfigMapping.isNumberedGroupMember("moveColumnToIndex.9"))

        // …are distinct from singleton actions, which stay assignable.
        #expect(!HotkeyConfigMapping.isNumberedGroupMember("rescueOffscreenWindows"))
        #expect(!HotkeyConfigMapping.isNumberedGroupMember("focusMonitorNext"))
        #expect(!HotkeyConfigMapping.isNumberedGroupMember("move.left"))
        #expect(!HotkeyConfigMapping.isNumberedGroupMember("switchWorkspace.next"))
    }
}
