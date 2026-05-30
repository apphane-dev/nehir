import Carbon
import Foundation
@testable import Nehir
import Testing

private func makeHotkeyEditorDefaults() -> UserDefaults {
    let suiteName = "HotkeyBindingEditorTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Suite @MainActor struct HotkeyBindingEditorTests {
    @Test func capturingBindingAssignsPreviouslyUnassignedAction() {
        let settings = SettingsStore(defaults: makeHotkeyEditorDefaults())
        let newBinding = KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))

        settings.clearBinding(for: "move.left")
        let result = HotkeyBindingEditor.capture(newBinding, for: "move.left", settings: settings)

        switch result {
        case .applied:
            break
        case .conflict:
            Issue.record("Expected binding capture to succeed for an unassigned action")
        }

        #expect(settings.hotkeyBindings.first { $0.id == "move.left" }?.binding == .chord(newBinding))
    }

    @Test func capturingDuplicateBindingReturnsConflictWithoutMutatingEitherAction() {
        let settings = SettingsStore(defaults: makeHotkeyEditorDefaults())
        let shared = KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))
        let originalTarget = KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey))

        settings.updateBinding(for: "move.left", newBinding: shared)
        settings.updateBinding(for: "move.right", newBinding: originalTarget)

        let result = HotkeyBindingEditor.capture(shared, for: "move.right", settings: settings)

        switch result {
        case .applied:
            Issue.record("Expected duplicate capture to produce a conflict")
        case let .conflict(alert):
            #expect(alert.targetActionId == "move.right")
            #expect(alert.newTrigger == .chord(shared))
            #expect(alert.conflictingCommands == ["Move Left"])
        }

        #expect(settings.hotkeyBindings.first { $0.id == "move.left" }?.binding == .chord(shared))
        #expect(settings.hotkeyBindings.first { $0.id == "move.right" }?.binding == .chord(originalTarget))
    }

    @Test func applyingConflictResolutionMovesOwnershipToTheNewAction() {
        let settings = SettingsStore(defaults: makeHotkeyEditorDefaults())
        let shared = KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))
        let originalTarget = KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey))

        settings.updateBinding(for: "move.left", newBinding: shared)
        settings.updateBinding(for: "move.right", newBinding: originalTarget)

        let result = HotkeyBindingEditor.capture(shared, for: "move.right", settings: settings)
        guard case let .conflict(alert) = result else {
            Issue.record("Expected duplicate capture to produce a conflict alert")
            return
        }

        HotkeyBindingEditor.applyConflictResolution(alert, settings: settings)

        #expect(settings.hotkeyBindings.first { $0.id == "move.left" }?.binding == .unassigned)
        #expect(settings.hotkeyBindings.first { $0.id == "move.right" }?.binding == .chord(shared))
    }

    @Test func conflictCaptureLeavesStateUnchangedUntilUserConfirmsReplacement() {
        let settings = SettingsStore(defaults: makeHotkeyEditorDefaults())
        let shared = KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))
        let originalTarget = KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey))

        settings.updateBinding(for: "move.left", newBinding: shared)
        settings.updateBinding(for: "move.right", newBinding: originalTarget)

        _ = HotkeyBindingEditor.capture(shared, for: "move.right", settings: settings)

        #expect(settings.hotkeyBindings.first { $0.id == "move.left" }?.binding == .chord(shared))
        #expect(settings.hotkeyBindings.first { $0.id == "move.right" }?.binding == .chord(originalTarget))
    }

    @Test func capturingNumberedGroupConflictDoesNotMutateUntilConfirmed() {
        let settings = SettingsStore(defaults: makeHotkeyEditorDefaults())
        let conflictingBinding = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(controlKey))
        settings.updateBinding(for: "move.left", newBinding: conflictingBinding)

        let mappings = (0..<9).map { index in
            HotkeyTriggerMapping(
                id: "switchWorkspace.\(index)",
                trigger: .chord(
                    KeyBinding(
                        keyCode: HotkeyConfigMapping.digitKeyCodes[index],
                        modifiers: UInt32(controlKey)
                    )
                )
            )
        }

        let result = HotkeyBindingEditor.capture(mappings: mappings, settings: settings)

        switch result {
        case .applied:
            Issue.record("Expected numbered group capture to produce a conflict")
        case let .conflict(alert):
            #expect(alert.mappings == mappings)
            #expect(alert.conflictingCommands == ["Move Left"])
        }

        #expect(settings.hotkeyBindings.first { $0.id == "move.left" }?.binding == .chord(conflictingBinding))
        #expect(settings.hotkeyBindings.first { $0.id == "switchWorkspace.0" }?.binding != mappings[0].trigger)
    }

    @Test func applyingNumberedGroupConflictResolutionClearsExternalConflicts() {
        let settings = SettingsStore(defaults: makeHotkeyEditorDefaults())
        let conflictingBinding = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(controlKey))
        settings.updateBinding(for: "move.left", newBinding: conflictingBinding)

        let mappings = (0..<9).map { index in
            HotkeyTriggerMapping(
                id: "switchWorkspace.\(index)",
                trigger: .chord(
                    KeyBinding(
                        keyCode: HotkeyConfigMapping.digitKeyCodes[index],
                        modifiers: UInt32(controlKey)
                    )
                )
            )
        }
        guard case let .conflict(alert) = HotkeyBindingEditor.capture(mappings: mappings, settings: settings) else {
            Issue.record("Expected numbered group capture to produce a conflict")
            return
        }

        HotkeyBindingEditor.applyConflictResolution(alert, settings: settings)

        #expect(settings.hotkeyBindings.first { $0.id == "move.left" }?.binding == .unassigned)
        #expect(settings.hotkeyBindings.first { $0.id == "switchWorkspace.0" }?.binding == mappings[0].trigger)
        #expect(settings.hotkeyBindings.first { $0.id == "switchWorkspace.8" }?.binding == mappings[8].trigger)
    }
}
