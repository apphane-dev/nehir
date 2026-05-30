@preconcurrency import AppKit
import Carbon
import Foundation

enum HotkeyRegistrationAction: Equatable {
    case command(HotkeyCommand)
}

struct HotkeyPlannedRegistration: Equatable {
    let binding: KeyBinding
    let action: HotkeyRegistrationAction

    init(binding: KeyBinding, command: HotkeyCommand) {
        self.binding = binding
        action = .command(command)
    }

    init(binding: KeyBinding, action: HotkeyRegistrationAction) {
        self.binding = binding
        self.action = action
    }
}

enum HotkeyRegistrationFailureReason: Equatable {
    case duplicateBinding
    case modifierLeaderConflict
    case unsupportedModifierKeys
    case eventTapUnavailable
    case systemReserved
}

struct HotkeyRegistrationPlan: Equatable {
    let registrations: [HotkeyPlannedRegistration]
    let virtualModifierRegistrations: [HotkeyPlannedRegistration]
    var failures: [HotkeyCommand: HotkeyRegistrationFailureReason]
}

struct HotkeyRuntimeConfiguration: Equatable {
    let bindings: [HotkeyBinding]
    let modifierTrigger: ModifierKeyTrigger

    init(
        bindings: [HotkeyBinding] = [],
        modifierTrigger: ModifierKeyTrigger = .default
    ) {
        self.bindings = bindings
        self.modifierTrigger = modifierTrigger
    }
}

enum VirtualModifierKeyDownDecision: Equatable {
    case passThrough
    case suppress
    case dispatch(HotkeyRegistrationAction)
}

struct SmallValueSet<Element: Equatable>: Equatable {
    private var first: Element?
    private var second: Element?
    private var third: Element?
    private var fourth: Element?
    private var overflow: [Element] = []

    var isEmpty: Bool {
        first == nil && second == nil && third == nil && fourth == nil && overflow.isEmpty
    }

    mutating func reserveCapacity(_ capacity: Int) {
        overflow.reserveCapacity(max(0, capacity - 4))
    }

    func contains(_ value: Element) -> Bool {
        first == value || second == value || third == value || fourth == value || overflow.contains(value)
    }

    mutating func insert(_ value: Element) {
        guard !contains(value) else { return }
        if first == nil {
            first = value
        } else if second == nil {
            second = value
        } else if third == nil {
            third = value
        } else if fourth == nil {
            fourth = value
        } else {
            overflow.append(value)
        }
    }

    @discardableResult
    mutating func remove(_ value: Element) -> Element? {
        if first == value {
            first = nil
            return value
        }
        if second == value {
            second = nil
            return value
        }
        if third == value {
            third = nil
            return value
        }
        if fourth == value {
            fourth = nil
            return value
        }
        guard let index = overflow.firstIndex(of: value) else { return nil }
        return overflow.remove(at: index)
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        first = nil
        second = nil
        third = nil
        fourth = nil
        overflow.removeAll(keepingCapacity: keepingCapacity)
    }
}

struct VirtualModifierEventState: Equatable {
    var isActive = false
    var consumedKeyCodes = SmallValueSet<UInt32>()
    var consumedMouseButtons = SmallValueSet<Int64>()

    mutating func reset() {
        isActive = false
        consumedKeyCodes.removeAll(keepingCapacity: true)
        consumedMouseButtons.removeAll(keepingCapacity: true)
    }

    mutating func handleTriggerMouseDown(_ button: Int64, trigger: ModifierKeyTrigger) -> Bool {
        guard trigger.mouseButtonNumber == button else { return false }
        isActive = true
        consumedMouseButtons.insert(button)
        return true
    }

    mutating func handleTriggerMouseUp(_ button: Int64, trigger: ModifierKeyTrigger) -> Bool {
        guard trigger.mouseButtonNumber == button else {
            return consumedMouseButtons.remove(button) != nil
        }
        isActive = false
        consumedMouseButtons.remove(button)
        return true
    }

    mutating func handleTriggerKeyDown(_ keyCode: UInt32, trigger: ModifierKeyTrigger) -> Bool {
        guard trigger.keyboardKeyCode == keyCode else { return false }
        isActive = true
        consumedKeyCodes.insert(keyCode)
        return true
    }

    mutating func handleTriggerKeyUp(_ keyCode: UInt32, trigger: ModifierKeyTrigger) -> Bool {
        guard trigger.keyboardKeyCode == keyCode else {
            return consumedKeyCodes.remove(keyCode) != nil
        }
        isActive = false
        consumedKeyCodes.remove(keyCode)
        return true
    }

    mutating func handleTriggerFlagsChanged(
        keyCode: UInt32,
        flags: CGEventFlags,
        trigger: ModifierKeyTrigger
    ) -> Bool {
        guard trigger.keyboardKeyCode == keyCode else { return false }

        if let modifierActive = Self.modifierFlagIsActive(for: keyCode, flags: flags) {
            if consumedKeyCodes.contains(keyCode) {
                isActive = false
            } else {
                isActive = modifierActive
            }
        } else if keyCode == UInt32(kVK_CapsLock) {
            isActive = flags.contains(.maskAlphaShift)
        } else {
            isActive = true
        }

        if isActive {
            consumedKeyCodes.insert(keyCode)
        } else {
            consumedKeyCodes.remove(keyCode)
        }
        return true
    }

    mutating func consumeKeyCode(_ keyCode: UInt32) {
        consumedKeyCodes.insert(keyCode)
    }

    mutating func handleKeyDown(
        keyCode: UInt32,
        isAutorepeat: Bool,
        trigger: ModifierKeyTrigger,
        action: HotkeyRegistrationAction?
    ) -> VirtualModifierKeyDownDecision {
        if handleTriggerKeyDown(keyCode, trigger: trigger) {
            return .suppress
        }
        guard isActive else {
            return consumedKeyCodes.contains(keyCode) ? .suppress : .passThrough
        }

        guard let action else {
            return .passThrough
        }
        if isAutorepeat {
            return .suppress
        }
        consumeKeyCode(keyCode)
        return .dispatch(action)
    }

    private static func modifierFlagIsActive(for keyCode: UInt32, flags: CGEventFlags) -> Bool? {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift:
            return flags.contains(.maskShift)
        case kVK_Control, kVK_RightControl:
            return flags.contains(.maskControl)
        case kVK_Option, kVK_RightOption:
            return flags.contains(.maskAlternate)
        case kVK_Command, kVK_RightCommand:
            return flags.contains(.maskCommand)
        default:
            return nil
        }
    }
}

@MainActor
final class HotkeyCenter {
    var onCommand: ((HotkeyCommand) -> Void)?
    var virtualModifierTapSetupOverride: (() -> Bool)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var isRunning = false
    private var idToAction: [UInt32: HotkeyRegistrationAction] = [:]

    private var configuration = HotkeyRuntimeConfiguration()
    private var virtualModifierRegistrations: [KeyBinding: HotkeyRegistrationAction] = [:]
    private var virtualModifierTap: CFMachPort?
    private var virtualModifierRunLoopSource: CFRunLoopSource?
    private var virtualModifierState = VirtualModifierEventState()
    private var pendingCommands: [HotkeyCommand] = []
    private var pendingDrainScheduled = false

    private(set) var registrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]

    deinit {
        MainActor.assumeIsolated {
            stopVirtualModifierTap()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            MainActor.assumeIsolated {
                center.dispatch(id: hotKeyID.id)
            }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, selfPtr, &handler)

        registerHotkeys()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        unregisterAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    func updateBindings(
        _ newBindings: [HotkeyBinding],
        modifierTrigger newModifierTrigger: ModifierKeyTrigger = .default,
        force: Bool = false
    ) {
        let nextConfiguration = HotkeyRuntimeConfiguration(
            bindings: newBindings,
            modifierTrigger: newModifierTrigger
        )
        guard force || nextConfiguration != configuration else { return }
        configuration = nextConfiguration
        if isRunning {
            registerHotkeys()
        }
    }

    private func unregisterAll() {
        for ref in refs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        idToAction.removeAll()
        pendingCommands.removeAll()
        pendingDrainScheduled = false
        virtualModifierRegistrations.removeAll()
        stopVirtualModifierTap()
    }

    private func registerHotkeys() {
        unregisterAll()
        let plan = Self.registrationPlan(
            for: configuration.bindings,
            modifierTrigger: configuration.modifierTrigger
        )
        virtualModifierRegistrations = Dictionary(
            plan.virtualModifierRegistrations.map { ($0.binding, $0.action) },
            uniquingKeysWith: { first, _ in first }
        )
        var virtualModifierUnavailableActions: [HotkeyRegistrationAction] = []
        if !virtualModifierRegistrations.isEmpty, configuration.modifierTrigger.requiresEventTap, !setupVirtualModifierTapIfNeeded() {
            virtualModifierUnavailableActions = Array(virtualModifierRegistrations.values)
            virtualModifierRegistrations.removeAll()
        }
        registrationFailures = plan.failures
        var nextId: UInt32 = 1

        for registration in plan.registrations {
            guard registrationFailuresForAction(registration.action).isEmpty else {
                continue
            }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4F4D_4E49), id: nextId)
            let status = RegisterEventHotKey(
                registration.binding.keyCode,
                registration.binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                idToAction[nextId] = registration.action
            } else {
                markSystemReservedFailure(for: registration.action)
            }
            nextId += 1
        }

        for action in virtualModifierUnavailableActions {
            markEventTapUnavailableFailure(for: action)
        }
    }

    private func registrationFailuresForAction(_ action: HotkeyRegistrationAction) -> [HotkeyRegistrationFailureReason] {
        switch action {
        case let .command(command):
            return registrationFailures[command].map { [$0] } ?? []
        }
    }

    private func markSystemReservedFailure(for action: HotkeyRegistrationAction) {
        switch action {
        case let .command(command):
            registrationFailures[command] = .systemReserved
        }
    }

    private func markEventTapUnavailableFailure(for action: HotkeyRegistrationAction) {
        switch action {
        case let .command(command):
            if registrationFailures[command] == nil {
                registrationFailures[command] = .eventTapUnavailable
            }
        }
    }

    private func dispatch(id: UInt32) {
        guard let action = idToAction[id] else { return }
        switch action {
        case let .command(command):
            onCommand?(command)
        }
    }

    private func setupVirtualModifierTapIfNeeded() -> Bool {
        if virtualModifierTap != nil { return true }
        if let virtualModifierTapSetupOverride {
            return virtualModifierTapSetupOverride()
        }
        let eventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                center.handleVirtualModifierEvent(type: type, event: event)
            }
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        virtualModifierTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        )
        guard let tap = virtualModifierTap else { return false }
        virtualModifierRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = virtualModifierRunLoopSource else {
            virtualModifierTap = nil
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopVirtualModifierTap() {
        virtualModifierState.reset()
        if let source = virtualModifierRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            virtualModifierRunLoopSource = nil
        }
        if let tap = virtualModifierTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            virtualModifierTap = nil
        }
    }

    private func handleVirtualModifierEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            if let tap = virtualModifierTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            virtualModifierState.reset()
            return Unmanaged.passUnretained(event)
        case .otherMouseDown:
            return handleVirtualModifierMouseDown(event)
        case .otherMouseUp:
            return handleVirtualModifierMouseUp(event)
        case .keyDown:
            return handleVirtualModifierKeyDown(event)
        case .keyUp:
            return handleVirtualModifierKeyUp(event)
        case .flagsChanged:
            return handleVirtualModifierFlagsChanged(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleVirtualModifierMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard virtualModifierState.handleTriggerMouseDown(button, trigger: configuration.modifierTrigger) else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func handleVirtualModifierMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        return virtualModifierState.handleTriggerMouseUp(button, trigger: configuration.modifierTrigger)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    private func handleVirtualModifierKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = matchingModifiers(from: event.flags)
        let action: HotkeyRegistrationAction?
        if virtualModifierState.isActive {
            action = virtualModifierRegistrations[
                KeyBinding(keyCode: keyCode, modifiers: modifiers, usesModifier: true)
            ]
        } else {
            action = nil
        }
        let decision = virtualModifierState.handleKeyDown(
            keyCode: keyCode,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            trigger: configuration.modifierTrigger,
            action: action
        )
        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .suppress:
            return nil
        case let .dispatch(action):
            dispatchCommandLater(action)
            return nil
        }
    }

    private func handleVirtualModifierKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        return virtualModifierState.handleTriggerKeyUp(keyCode, trigger: configuration.modifierTrigger)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    private func handleVirtualModifierFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard virtualModifierState.handleTriggerFlagsChanged(keyCode: keyCode, flags: event.flags, trigger: configuration.modifierTrigger) else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func dispatchCommandLater(_ action: HotkeyRegistrationAction) {
        switch action {
        case let .command(command):
            pendingCommands.append(command)
            guard !pendingDrainScheduled else { return }
            pendingDrainScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.drainPendingCommands()
            }
        }
    }

    private func drainPendingCommands() {
        pendingDrainScheduled = false
        var index = 0
        while index < pendingCommands.count {
            let command = pendingCommands[index]
            index += 1
            onCommand?(command)
        }
        pendingCommands.removeAll(keepingCapacity: true)
    }

    private func matchingModifiers(from flags: CGEventFlags) -> UInt32 {
        Self.carbonModifiers(from: flags) & ~configuration.modifierTrigger.modifierMaskToExclude
    }

    private static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }
}

#if DEBUG
extension HotkeyCenter {
    func prepareVirtualModifierForTesting(
        modifierTrigger: ModifierKeyTrigger,
        registrations: [KeyBinding: HotkeyRegistrationAction],
        isActive: Bool = false
    ) {
        configuration = HotkeyRuntimeConfiguration(
            bindings: configuration.bindings,
            modifierTrigger: modifierTrigger
        )
        virtualModifierRegistrations = registrations
        virtualModifierState.reset()
        virtualModifierState.isActive = isActive
    }

    func handleVirtualModifierEventForTesting(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        handleVirtualModifierEvent(type: type, event: event)
    }

    func drainPendingCommandsForTesting() {
        drainPendingCommands()
    }
}
#endif

extension HotkeyCenter {
    nonisolated static func registrationPlan(
        for bindings: [HotkeyBinding],
        modifierTrigger: ModifierKeyTrigger = .default
    ) -> HotkeyRegistrationPlan {
        struct DirectCandidate {
            let command: HotkeyCommand
            let binding: KeyBinding
        }

        var directOwners: [KeyBinding: [HotkeyCommand]] = [:]
        var directCandidates: [DirectCandidate] = []
        var failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]

        func mark(_ command: HotkeyCommand, _ reason: HotkeyRegistrationFailureReason) {
            if failures[command] == nil {
                failures[command] = reason
            }
        }

        func usesUnsupportedModifierCombo(_ binding: KeyBinding) -> Bool {
            guard binding.usesModifier else { return false }
            if modifierTrigger == .system {
                return binding.modifiers != 0
            }
            let excludedModifiers = modifierTrigger.modifierMaskToExclude
            return excludedModifiers != 0 && binding.modifiers & excludedModifiers != 0
        }

        for binding in bindings {
            switch binding.binding {
            case .unassigned:
                continue
            case let .chord(keyBinding):
                guard !keyBinding.isUnassigned else { continue }
                directOwners[keyBinding, default: []].append(binding.command)
                directCandidates.append(DirectCandidate(command: binding.command, binding: keyBinding))
            }
        }

        for owners in directOwners.values where owners.count > 1 {
            for command in owners {
                mark(command, .duplicateBinding)
            }
        }

        for lhsIndex in directCandidates.indices {
            for rhsIndex in directCandidates.indices where rhsIndex > lhsIndex {
                let lhs = directCandidates[lhsIndex]
                let rhs = directCandidates[rhsIndex]
                guard lhs.binding.conflicts(with: rhs.binding, modifierTrigger: modifierTrigger) else { continue }
                mark(lhs.command, .duplicateBinding)
                mark(rhs.command, .duplicateBinding)
            }
        }

        for candidate in directCandidates where candidate.binding.physicalKeyConflicts(with: modifierTrigger) {
            mark(candidate.command, .modifierLeaderConflict)
        }

        for candidate in directCandidates where usesUnsupportedModifierCombo(candidate.binding) {
            mark(candidate.command, .unsupportedModifierKeys)
        }


        var registrations: [HotkeyPlannedRegistration] = []
        var virtualModifierRegistrations: [HotkeyPlannedRegistration] = []
        for candidate in directCandidates {
            let binding = candidate.binding
            let command = candidate.command
            guard failures[command] == nil else { continue }
            if binding.usesModifier, modifierTrigger.requiresEventTap {
                virtualModifierRegistrations.append(HotkeyPlannedRegistration(binding: binding, command: command))
            }
            let carbonBinding = binding.usesModifier && modifierTrigger.requiresEventTap
                ? nil
                : binding.carbonCompatibilityBinding(for: modifierTrigger) ?? (binding.usesModifier ? nil : binding)
            if let carbonBinding {
                registrations.append(HotkeyPlannedRegistration(binding: carbonBinding, command: command))
            }
        }

        return HotkeyRegistrationPlan(
            registrations: registrations,
            virtualModifierRegistrations: virtualModifierRegistrations,
            failures: failures
        )
    }
}

private extension KeyBinding {
    func physicalKeyConflicts(with modifierTrigger: ModifierKeyTrigger) -> Bool {
        guard !isUnassigned else { return false }
        return modifierTrigger.matchesPhysicalKeyCode(keyCode)
    }
}
