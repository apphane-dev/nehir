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

@MainActor
private func makeOtherMouseEvent(type: NSEvent.EventType, buttonNumber: Int64) -> NSEvent {
    let cgType: CGEventType = type == .otherMouseDown ? .otherMouseDown : .otherMouseUp
    let source = CGEventSource(stateID: .hidSystemState)
    guard let cgButton = CGMouseButton(rawValue: UInt32(buttonNumber)),
          let cgEvent = CGEvent(
              mouseEventSource: source,
              mouseType: cgType,
              mouseCursorPosition: .zero,
              mouseButton: cgButton
          )
    else {
        fatalError("Failed to create key recorder mouse test event")
    }
    cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
    guard let event = NSEvent(cgEvent: cgEvent) else {
        fatalError("Failed to bridge key recorder mouse test event")
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

    @Test func chordModeNormalizesAllModifiersToSemanticHyper() {
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
            KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: 0, usesModifier: true)
        ])
    }

    @Test func modifierTriggerRecorderCapturesKeyboardKeys() {
        let view = ModifierTriggerRecorderNSView(frame: .zero)
        var captured: [ModifierKeyTrigger] = []
        view.onCapture = { captured.append($0) }

        let event = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_F18),
            modifierFlags: [],
            characters: "",
            charactersIgnoringModifiers: ""
        )

        view.keyDown(with: event)

        #expect(captured == [.key(UInt32(kVK_F18))])
    }

    @Test func modifierTriggerRecorderCapturesModifierFamily() {
        let view = ModifierTriggerRecorderNSView(frame: .zero)
        var captured: [ModifierKeyTrigger] = []
        view.onCapture = { captured.append($0) }

        let event = makeKeyRecorderEvent(
            type: .flagsChanged,
            keyCode: UInt16(kVK_RightOption),
            modifierFlags: .option,
            characters: "",
            charactersIgnoringModifiers: ""
        )

        view.flagsChanged(with: event)

        #expect(captured == [.modifier(UInt32(optionKey))])
    }

    @Test func modifierTriggerRecorderCapturesMouseButtons() {
        let view = ModifierTriggerRecorderNSView(frame: .zero)
        var captured: [ModifierKeyTrigger] = []
        view.onCapture = { captured.append($0) }

        view.otherMouseDown(with: makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 4))

        #expect(captured == [.mouseButton(4)])
    }

    @Test func configuredCapsHyperRecordsSemanticChord() {
        let view = KeyRecorderNSView(frame: .zero)
        view.modifierTrigger = .key(UInt32(kVK_CapsLock))
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let capsEvent = makeKeyRecorderEvent(
            type: .flagsChanged,
            keyCode: UInt16(kVK_CapsLock),
            modifierFlags: .capsLock,
            characters: "",
            charactersIgnoringModifiers: ""
        )
        let chordEvent = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_S),
            modifierFlags: .capsLock,
            characters: "s",
            charactersIgnoringModifiers: "s"
        )

        view.flagsChanged(with: capsEvent)
        view.keyDown(with: chordEvent)

        #expect(captured == [
            KeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: 0, usesModifier: true)
        ])
    }

    @Test func configuredOptionHyperRecordsLeftAndRightOptionAsSemanticChord() {
        let leftView = KeyRecorderNSView(frame: .zero)
        let rightView = KeyRecorderNSView(frame: .zero)
        leftView.modifierTrigger = .modifier(UInt32(optionKey))
        rightView.modifierTrigger = .modifier(UInt32(optionKey))
        var leftCaptured: [KeyBinding] = []
        var rightCaptured: [KeyBinding] = []
        leftView.onCapture = { leftCaptured.append($0) }
        rightView.onCapture = { rightCaptured.append($0) }

        let leftTrigger = makeKeyRecorderEvent(
            type: .flagsChanged,
            keyCode: UInt16(kVK_Option),
            modifierFlags: .option,
            characters: "",
            charactersIgnoringModifiers: ""
        )
        let rightTrigger = makeKeyRecorderEvent(
            type: .flagsChanged,
            keyCode: UInt16(kVK_RightOption),
            modifierFlags: .option,
            characters: "",
            charactersIgnoringModifiers: ""
        )
        let chordEvent = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_S),
            modifierFlags: .option,
            characters: "s",
            charactersIgnoringModifiers: "s"
        )

        leftView.flagsChanged(with: leftTrigger)
        leftView.keyDown(with: chordEvent)
        rightView.flagsChanged(with: rightTrigger)
        rightView.keyDown(with: chordEvent)

        let expected = KeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: 0, usesModifier: true)
        #expect(leftCaptured == [expected])
        #expect(rightCaptured == [expected])
    }

    @Test func configuredKeyboardHyperRecordsNextKeyAsSemanticChord() {
        let view = KeyRecorderNSView(frame: .zero)
        view.modifierTrigger = .key(UInt32(kVK_F18))
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let triggerEvent = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_F18),
            modifierFlags: [],
            characters: "",
            charactersIgnoringModifiers: ""
        )
        let chordEvent = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_S),
            modifierFlags: [],
            characters: "s",
            charactersIgnoringModifiers: "s"
        )

        view.keyDown(with: triggerEvent)
        view.keyDown(with: chordEvent)

        #expect(captured == [
            KeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: 0, usesModifier: true)
        ])
    }

    @Test func configuredModifierHyperReleaseDoesNotStayActiveWhenMatchingFlagRemains() {
        let view = KeyRecorderNSView(frame: .zero)
        view.modifierTrigger = .key(UInt32(kVK_Shift))
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let triggerDown = makeKeyRecorderEvent(
            type: .flagsChanged,
            keyCode: UInt16(kVK_Shift),
            modifierFlags: .shift,
            characters: "",
            charactersIgnoringModifiers: ""
        )
        let semanticChord = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_S),
            modifierFlags: .shift,
            characters: "S",
            charactersIgnoringModifiers: "s"
        )
        let triggerUpWithOtherShiftHeld = makeKeyRecorderEvent(
            type: .flagsChanged,
            keyCode: UInt16(kVK_Shift),
            modifierFlags: .shift,
            characters: "",
            charactersIgnoringModifiers: ""
        )
        let bareChord = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_H),
            modifierFlags: [],
            characters: "h",
            charactersIgnoringModifiers: "h"
        )

        view.flagsChanged(with: triggerDown)
        view.keyDown(with: semanticChord)
        view.flagsChanged(with: triggerUpWithOtherShiftHeld)
        view.keyDown(with: bareChord)

        #expect(captured == [
            KeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: 0, usesModifier: true)
        ])
    }

    @Test func configuredMouseHyperRecordsNextKeyAsSemanticChord() {
        let view = KeyRecorderNSView(frame: .zero)
        view.modifierTrigger = .mouseButton(4)
        var captured: [KeyBinding] = []
        view.onCapture = { captured.append($0) }

        let chordEvent = makeKeyRecorderEvent(
            keyCode: UInt16(kVK_ANSI_S),
            modifierFlags: [],
            characters: "s",
            charactersIgnoringModifiers: "s"
        )

        view.otherMouseDown(with: makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 4))
        view.keyDown(with: chordEvent)
        view.otherMouseUp(with: makeOtherMouseEvent(type: .otherMouseUp, buttonNumber: 4))

        #expect(captured == [
            KeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: 0, usesModifier: true)
        ])
    }

}
