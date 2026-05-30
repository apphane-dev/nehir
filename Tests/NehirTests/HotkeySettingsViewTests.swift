import Carbon
import Foundation
@testable import Nehir
import Testing

struct HotkeySettingsViewTests {
    @Test func hotkeyDisplayModelUsesNehirModifierTerminology() {
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: 0, usesModifier: true)
        let trigger = HotkeyTrigger.chord(binding)

        #expect(binding.displayString == "Modifier+K")
        #expect(binding.humanReadableString == "Modifier+K")
        #expect(HotkeySettingsDisplayModel.displayString(for: binding) == "Nehir+K")
        #expect(HotkeySettingsDisplayModel.humanReadableString(for: binding) == "Nehir modifier+K")
        #expect(HotkeySettingsDisplayModel.displayString(for: trigger) == "Nehir+K")
        #expect(HotkeySettingsDisplayModel.humanReadableString(for: trigger) == "Nehir modifier+K")
    }

    @Test func hotkeyDisplayModelSearchMatchesVisibleNehirTerminology() {
        let binding = HotkeyBinding(
            id: "focusLeft",
            command: .focus(.left),
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: 0, usesModifier: true)
        )

        #expect(binding.binding.displayString == "Modifier+K")
        #expect(HotkeySettingsDisplayModel.matchesSearch("Nehir", binding: binding))
        #expect(HotkeySettingsDisplayModel.matchesSearch("Nehir modifier", binding: binding))
        #expect(!HotkeySettingsDisplayModel.matchesSearch("Hyper", binding: binding))
    }

}
