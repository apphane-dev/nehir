@testable import Nehir
import Carbon
import CoreGraphics
import Testing

private func makeHotkeyKeyboardEvent(
    keyCode: UInt32,
    flags: CGEventFlags = [],
    autorepeat: Bool = false
) -> CGEvent {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) else {
        fatalError("Failed to create hotkey keyboard event")
    }
    event.flags = flags
    event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
    return event
}

private func makeHotkeyOtherMouseEvent(type: CGEventType, buttonNumber: Int64) -> CGEvent {
    let source = CGEventSource(stateID: .hidSystemState)
    guard let button = CGMouseButton(rawValue: UInt32(buttonNumber)),
          let event = CGEvent(
              mouseEventSource: source,
              mouseType: type,
              mouseCursorPosition: .zero,
              mouseButton: button
          )
    else {
        fatalError("Failed to create hotkey mouse event")
    }
    event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
    return event
}

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

    @Test func systemSemanticHyperBindingsRegisterLiteralCompatibilityOnly() {
        let semantic = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: 0, usesModifier: true)
        let literal = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: KeySymbolMapper.realHyperModifiers)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "switchWorkspace.1", command: .switchWorkspace(1), binding: semantic)
            ],
            modifierTrigger: .system
        )

        #expect(plan.failures.isEmpty)
        #expect(plan.registrations == [
            HotkeyPlannedRegistration(binding: literal, command: .switchWorkspace(1))
        ])
        #expect(plan.virtualModifierRegistrations.isEmpty)
    }

    @Test func optionModifierSemanticHyperBindingsRegisterOptionCompatibilityOnly() {
        let semantic = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: 0, usesModifier: true)
        let literal = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey))
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "switchWorkspace.1", command: .switchWorkspace(1), binding: semantic)
            ],
            modifierTrigger: .modifier(UInt32(optionKey))
        )

        #expect(plan.failures.isEmpty)
        #expect(plan.registrations == [
            HotkeyPlannedRegistration(binding: literal, command: .switchWorkspace(1))
        ])
        #expect(plan.virtualModifierRegistrations.isEmpty)
    }

    @Test func customSemanticHyperBindingsRegisterVirtualTriggerOnly() {
        let semantic = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: 0, usesModifier: true)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "switchWorkspace.1", command: .switchWorkspace(1), binding: semantic)
            ],
            modifierTrigger: .key(UInt32(kVK_CapsLock))
        )

        #expect(plan.failures.isEmpty)
        #expect(plan.registrations.isEmpty)
        #expect(plan.virtualModifierRegistrations == [
            HotkeyPlannedRegistration(binding: semantic, command: .switchWorkspace(1))
        ])
    }

    @Test func systemSemanticHyperWithExtraModifiersFailsClosed() {
        let semantic = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(shiftKey), usesModifier: true)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "moveToWorkspace.1", command: .moveToWorkspace(1), binding: semantic)
            ],
            modifierTrigger: .system
        )

        #expect(plan.failures == [.moveToWorkspace(1): .unsupportedModifierKeys])
        #expect(plan.registrations.isEmpty)
        #expect(plan.virtualModifierRegistrations.isEmpty)
    }

    @Test func optionModifierSemanticHyperWithExtraModifiersPreservesExtraModifiers() {
        let semantic = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(shiftKey), usesModifier: true)
        let literal = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey | shiftKey))
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "moveToWorkspace.1", command: .moveToWorkspace(1), binding: semantic)
            ],
            modifierTrigger: .modifier(UInt32(optionKey))
        )

        #expect(plan.failures.isEmpty)
        #expect(plan.registrations == [
            HotkeyPlannedRegistration(binding: literal, command: .moveToWorkspace(1))
        ])
        #expect(plan.virtualModifierRegistrations.isEmpty)
    }

    @Test func customSemanticHyperWithExtraModifiersIsVirtualOnly() {
        let semantic = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(shiftKey), usesModifier: true)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "moveToWorkspace.1", command: .moveToWorkspace(1), binding: semantic)
            ],
            modifierTrigger: .key(UInt32(kVK_CapsLock))
        )

        #expect(plan.failures.isEmpty)
        #expect(plan.registrations.isEmpty)
        #expect(plan.virtualModifierRegistrations == [
            HotkeyPlannedRegistration(binding: semantic, command: .moveToWorkspace(1))
        ])
    }

    @Test func customModifierHyperWithSameExtraModifierFailsClosed() {
        let semantic = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(shiftKey), usesModifier: true)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "moveToWorkspace.1", command: .moveToWorkspace(1), binding: semantic)
            ],
            modifierTrigger: .key(UInt32(kVK_Shift))
        )

        #expect(plan.failures == [.moveToWorkspace(1): .unsupportedModifierKeys])
        #expect(plan.registrations.isEmpty)
        #expect(plan.virtualModifierRegistrations.isEmpty)
    }

    @Test func semanticHyperConflictsWithLiteralAllModifierCompatibilityChord() {
        let semantic = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: 0, usesModifier: true)
        let literal = KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: KeySymbolMapper.realHyperModifiers)
        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "switchWorkspace.1", command: .switchWorkspace(1), binding: semantic),
                HotkeyBinding(id: "focus.left", command: .focus(.left), binding: literal)
            ],
            modifierTrigger: .system
        )

        #expect(plan.failures == [
            .switchWorkspace(1): .duplicateBinding,
            .focus(.left): .duplicateBinding
        ])
        #expect(plan.registrations.isEmpty)
        #expect(plan.virtualModifierRegistrations.isEmpty)
    }

    @Test func directBindingMatchingCustomHyperTriggerFailsRegistration() {
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(shiftKey), usesModifier: true)

        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "focus.left", command: .focus(.left), binding: binding)
            ],
            modifierTrigger: .key(UInt32(kVK_ANSI_S))
        )

        #expect(plan.failures == [.focus(.left): .modifierLeaderConflict])
        #expect(plan.registrations.isEmpty)
        #expect(plan.virtualModifierRegistrations.isEmpty)
    }

    @Test func directBindingMatchingOptionModifierFamilyFailsRegistration() {
        let binding = KeyBinding(keyCode: UInt32(kVK_RightOption), modifiers: 0)

        let plan = HotkeyCenter.registrationPlan(
            for: [
                HotkeyBinding(id: "focus.left", command: .focus(.left), binding: binding)
            ],
            modifierTrigger: .modifier(UInt32(optionKey))
        )

        #expect(plan.failures == [.focus(.left): .modifierLeaderConflict])
        #expect(plan.registrations.isEmpty)
        #expect(plan.virtualModifierRegistrations.isEmpty)
    }

    @Test func capsLockFlagsChangedUsesFlagStateInsteadOfToggling() {
        var state = VirtualModifierEventState()
        let trigger = ModifierKeyTrigger.key(UInt32(kVK_CapsLock))

        let firstPressHandled = state.handleTriggerFlagsChanged(
            keyCode: UInt32(kVK_CapsLock),
            flags: .maskAlphaShift,
            trigger: trigger
        )
        #expect(firstPressHandled)
        #expect(state.isActive)

        let repeatedActiveFlagsHandled = state.handleTriggerFlagsChanged(
            keyCode: UInt32(kVK_CapsLock),
            flags: .maskAlphaShift,
            trigger: trigger
        )
        #expect(repeatedActiveFlagsHandled)
        #expect(state.isActive)

        let releaseHandled = state.handleTriggerFlagsChanged(
            keyCode: UInt32(kVK_CapsLock),
            flags: [],
            trigger: trigger
        )
        #expect(releaseHandled)
        #expect(!state.isActive)
    }

    @Test func modifierHyperFlagsChangedUsesPhysicalKeyIdentityWhenAggregateFlagStaysActive() {
        var state = VirtualModifierEventState()
        let trigger = ModifierKeyTrigger.key(UInt32(kVK_Shift))

        let pressHandled = state.handleTriggerFlagsChanged(
            keyCode: UInt32(kVK_Shift),
            flags: .maskShift,
            trigger: trigger
        )
        #expect(pressHandled)
        #expect(state.isActive)

        let releaseHandled = state.handleTriggerFlagsChanged(
            keyCode: UInt32(kVK_Shift),
            flags: .maskShift,
            trigger: trigger
        )
        #expect(releaseHandled)
        #expect(!state.isActive)
    }

    @Test func virtualHyperPassesThroughUnregisteredAutorepeatWithoutConsuming() {
        var state = VirtualModifierEventState(isActive: true)
        let trigger = ModifierKeyTrigger.key(UInt32(kVK_CapsLock))
        let initialDecision = state.handleKeyDown(
            keyCode: UInt32(kVK_Delete),
            isAutorepeat: false,
            trigger: trigger,
            action: nil
        )
        let repeatDecision = state.handleKeyDown(
            keyCode: UInt32(kVK_Delete),
            isAutorepeat: true,
            trigger: trigger,
            action: nil
        )

        #expect(initialDecision == .passThrough)
        #expect(repeatDecision == .passThrough)
        #expect(!state.consumedKeyCodes.contains(UInt32(kVK_Delete)))
    }

    @Test func registeredVirtualHyperSuppressesInitialAndRepeatKeyDowns() {
        var state = VirtualModifierEventState(isActive: true)
        let trigger = ModifierKeyTrigger.key(UInt32(kVK_CapsLock))
        let action = HotkeyRegistrationAction.command(.focus(.left))

        let initialDecision = state.handleKeyDown(
            keyCode: UInt32(kVK_ANSI_S),
            isAutorepeat: false,
            trigger: trigger,
            action: action
        )
        let repeatDecision = state.handleKeyDown(
            keyCode: UInt32(kVK_ANSI_S),
            isAutorepeat: true,
            trigger: trigger,
            action: action
        )

        #expect(initialDecision == .dispatch(action))
        #expect(repeatDecision == .suppress)
        #expect(state.consumedKeyCodes.contains(UInt32(kVK_ANSI_S)))
    }

    @Test func mouseButtonVirtualHyperDispatchesAndSuppressesRegisteredKey() {
        var state = VirtualModifierEventState()
        let trigger = ModifierKeyTrigger.mouseButton(4)
        let action = HotkeyRegistrationAction.command(.focus(.left))

        let triggerDownHandled = state.handleTriggerMouseDown(4, trigger: trigger)
        #expect(triggerDownHandled)
        #expect(state.isActive)

        let initialDecision = state.handleKeyDown(
            keyCode: UInt32(kVK_ANSI_S),
            isAutorepeat: false,
            trigger: trigger,
            action: action
        )
        let repeatDecision = state.handleKeyDown(
            keyCode: UInt32(kVK_ANSI_S),
            isAutorepeat: true,
            trigger: trigger,
            action: action
        )

        #expect(initialDecision == .dispatch(action))
        #expect(repeatDecision == .suppress)
        #expect(state.consumedKeyCodes.contains(UInt32(kVK_ANSI_S)))
        let keyUpHandled = state.handleTriggerKeyUp(UInt32(kVK_ANSI_S), trigger: trigger)
        #expect(keyUpHandled)
        #expect(!state.consumedKeyCodes.contains(UInt32(kVK_ANSI_S)))
        let triggerUpHandled = state.handleTriggerMouseUp(4, trigger: trigger)
        #expect(triggerUpHandled)
        #expect(!state.isActive)
    }

    @Test func mouseButtonVirtualHyperPassesThroughUnregisteredKey() {
        var state = VirtualModifierEventState()
        let trigger = ModifierKeyTrigger.mouseButton(4)

        let triggerDownHandled = state.handleTriggerMouseDown(4, trigger: trigger)
        #expect(triggerDownHandled)
        let initialDecision = state.handleKeyDown(
            keyCode: UInt32(kVK_ANSI_S),
            isAutorepeat: false,
            trigger: trigger,
            action: nil
        )
        let repeatDecision = state.handleKeyDown(
            keyCode: UInt32(kVK_ANSI_S),
            isAutorepeat: true,
            trigger: trigger,
            action: nil
        )

        #expect(initialDecision == .passThrough)
        #expect(repeatDecision == .passThrough)
        #expect(!state.consumedKeyCodes.contains(UInt32(kVK_ANSI_S)))
    }

    @Test @MainActor func virtualModifierTapUnavailableFailsVirtualHyperCommands() {
        let center = HotkeyCenter()
        defer { center.stop() }
        center.virtualModifierTapSetupOverride = { false }
        center.updateBindings(
            [
                HotkeyBinding(
                    id: "switchWorkspace.1",
                    command: .switchWorkspace(1),
                    binding: KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(shiftKey), usesModifier: true)
                )
            ],
            modifierTrigger: .key(UInt32(kVK_CapsLock))
        )

        center.start()

        #expect(center.registrationFailures == [.switchWorkspace(1): .eventTapUnavailable])
    }

    @Test @MainActor func unchangedRuntimeConfigurationSkipsHotkeyRebuildUnlessForced() {
        let center = HotkeyCenter()
        defer { center.stop() }
        var virtualModifierTapSetupCalls = 0
        let bindings = [
            HotkeyBinding(
                id: "switchWorkspace.1",
                command: .switchWorkspace(1),
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: 0, usesModifier: true)
            )
        ]
        center.virtualModifierTapSetupOverride = {
            virtualModifierTapSetupCalls += 1
            return true
        }
        center.updateBindings(
            bindings,
            modifierTrigger: .key(UInt32(kVK_CapsLock))
        )

        center.start()
        #expect(virtualModifierTapSetupCalls == 1)

        center.updateBindings(
            bindings,
            modifierTrigger: .key(UInt32(kVK_CapsLock))
        )
        #expect(virtualModifierTapSetupCalls == 1)

        center.updateBindings(
            bindings,
            modifierTrigger: .key(UInt32(kVK_CapsLock)),
            force: true
        )
        #expect(virtualModifierTapSetupCalls == 2)
    }
}
