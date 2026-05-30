import AppKit
import Carbon
@testable import Nehir
import Testing

@MainActor
private func makeKeyRecorderEvent(
    type: NSEvent.EventType = .keyDown,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String,
    charactersIgnoringModifiers: String
) -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        fatalError("Failed to create key recorder test event")
    }
    return event
}

@Suite(.serialized) @MainActor struct KeyRecorderViewTests {
    @Test func keyDownCapturesPhysicalTopRowKeyForCzechStyleCharacters() {
        let view = KeyRecorderNSView(frame: .zero)
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let event = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_1),
            modifierFlags: .command,
            characters: "+",
            charactersIgnoringModifiers: "+"
        )

        view.keyDown(with: event)

        #expect(captured == [
            KeyBinding(
                keyCode: UInt32(kVK_ANSI_1),
                modifiers: UInt32(cmdKey)
            )
        ])
    }

    @Test func performKeyEquivalentCapturesCommandBindingsBeforeAppKitSwallowsThem() {
        let view = KeyRecorderNSView(frame: .zero)
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let event = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_1),
            modifierFlags: .command,
            characters: "+",
            charactersIgnoringModifiers: "+"
        )

        let handled = view.performKeyEquivalent(with: event)

        #expect(handled == true)
        #expect(captured == [
            KeyBinding(
                keyCode: UInt32(kVK_ANSI_1),
                modifiers: UInt32(cmdKey)
            )
        ])
    }

    @Test func bareKeyModeAllowsBarePrintableKeys() {
        let view = KeyRecorderNSView(frame: .zero)
        view.allowsBareKeys = true
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let event = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_H),
            modifierFlags: [],
            characters: "h",
            charactersIgnoringModifiers: "h"
        )

        view.keyDown(with: event)

        #expect(captured == [
            KeyBinding(
                keyCode: UInt32(kVK_ANSI_H),
                modifiers: 0
            )
        ])
    }

    @Test func chordModeRejectsBarePrintableKeys() {
        let view = KeyRecorderNSView(frame: .zero)
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let event = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_H),
            modifierFlags: [],
            characters: "h",
            charactersIgnoringModifiers: "h"
        )

        view.keyDown(with: event)

        #expect(captured.isEmpty)
    }

    @Test func chordModeRecordsRealHyperAsPhysicalHyper() {
        let view = KeyRecorderNSView(frame: .zero)
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let event = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_K),
            modifierFlags: [.control, .option, .shift, .command],
            characters: "K",
            charactersIgnoringModifiers: "k"
        )

        view.keyDown(with: event)

        #expect(captured == [
            KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: KeySymbolMapper.realHyperModifiers)
        ])
    }
}
