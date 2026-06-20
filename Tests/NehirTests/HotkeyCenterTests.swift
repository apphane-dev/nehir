// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

@testable import Nehir
import Testing

@Suite struct HotkeyCenterTests {
    @Test func duplicateBindingsAcrossCommandsFailClosedWithDuplicateReason() {
        let shared = KeyBinding(keyCode: 1, modifiers: 2)
        let unique = KeyBinding(keyCode: 3, modifiers: 4)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "move.left", command: .move(.left), binding: shared),
                HotkeyBinding(id: "move.right", command: .move(.right), binding: shared),
                HotkeyBinding(id: "focus.left", command: .focus(.left), binding: unique)
            ]
        )

        #expect(plan.failures == [
            .move(.left): .duplicateBinding,
            .move(.right): .duplicateBinding
        ])
        #expect(plan.registrations == [
            HotkeyPlannedRegistration(binding: unique, command: .focus(.left))
        ])
    }

    @Test func unassignedBindingsAreIgnoredByRegistrationPlan() {
        let unique = KeyBinding(keyCode: 31, modifiers: 41)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "move.left", command: .move(.left), binding: .unassigned),
                HotkeyBinding(id: "move.right", command: .move(.right), binding: unique)
            ]
        )

        #expect(plan.failures.isEmpty)
        #expect(plan.registrations == [
            HotkeyPlannedRegistration(binding: unique, command: .move(.right))
        ])
    }

    @Test @MainActor func unchangedRuntimeConfigurationSkipsHotkeyRebuildUnlessForced() {
        let center = HotkeyCenter()
        defer { center.stop() }
        let bindings = [
            HotkeyBinding(
                id: "switchWorkspace.1",
                command: .switchWorkspace(1),
                binding: KeyBinding(keyCode: 19, modifiers: 2)
            )
        ]
        center.updateBindings(bindings)
        center.start()

        center.updateBindings(bindings)
        #expect(center.registrationFailures.isEmpty)

        center.updateBindings(bindings, force: true)
        #expect(center.registrationFailures.isEmpty)
    }
}
