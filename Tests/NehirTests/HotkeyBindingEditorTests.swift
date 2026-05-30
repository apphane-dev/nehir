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
}
