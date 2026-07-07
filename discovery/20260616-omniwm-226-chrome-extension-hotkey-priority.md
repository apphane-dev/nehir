# OmniWM issue #226 — "Hotkeys overridden by Chrome extension shortcuts" — Discovery

Groom 2026-07-07: in flight — a plan exists (planned/20260621-omniwm-226-chrome-extension-hotkey-priority.md); still uses Carbon RegisterEventHotKey with no priority event-tap backend (verified against main 7a025b78).

Source issue: <https://github.com/BarutSRB/OmniWM/issues/226>
Scope of this doc: determine whether the issue applies to nehir,
and whether the suggested fix is safe to port.

All file/line references were verified against the Nehir source tree
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro
trace"). Re-verify before implementing; line numbers drift.

---

## TL;DR

- **nehir still registers command hotkeys with Carbon `RegisterEventHotKey`, so
  it has no earlier keyboard event tap that can preempt focused-app / Chrome
  extension shortcuts using the same chord.**
- **Verdict:** 🔴 **Open / Applies** — the upstream issue was closed
  `not_planned` as cleanup, not because a fix landed; nehir's hotkey path still
  matches the cited Carbon implementation.

## What the issue actually says

Reported 2026-04-10 against OmniWM `v0.4.7.3`, closed 2026-05-05 with
`state_reason=not_planned`. Reproduction: install a Chrome extension with a
shortcut such as Loom `Option+Shift+L`, bind OmniWM's Move Right to the same
chord, focus Chrome, and press the chord. Expected: OmniWM moves the window;
actual: Chrome opens the extension. The report says the hotkey works when a
non-Chrome app is focused.

The suggested fix is not an upstream patch. The reporter proposed replacing
Carbon hotkeys with a `CGEventTap` at `kCGHIDEventTap`/`kCGSessionEventTap`,
matching `keyDown`, returning `nil` to suppress consumed events, and then
running the OmniWM command. The maintainer initially said this needed planning
and might need a per-app / priority mode; the issue was later closed during
v0.4.8 cleanup with a request to re-report if it still reproduced.

## Provenance: is this nehir's code?

Yes. The cited Carbon hotkey implementation exists in nehir as
`Sources/Nehir/Core/Input/Hotkeys.swift`; `WMController` wires registered hotkey
commands into `CommandHandler`, and the default/catalogued Move Right command is
present.

The suggested event-tap architecture is not present for hotkey dispatch. The
only `CGEvent.tapCreate` call sites in nehir are mouse/gesture paths:
`MouseEventHandler.swift:253`, `MouseEventHandler.swift:285`,
`MouseWarpHandler.swift:86`, and `InteractiveMoveDemo.swift:725`. The only
keyboard global monitor found is the settings key recorder, not the runtime
hotkey dispatcher (`KeyRecorderView.swift:107`).

## The code in question

```swift
// Sources/Nehir/Core/Input/Hotkeys.swift:60
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
```

```swift
// Sources/Nehir/Core/Input/Hotkeys.swift:116
private func registerHotkeys() {
    unregisterAll()
    let plan = Self.registrationPlan(for: configuration.bindings)
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
}
```

```swift
// Sources/Nehir/Core/Controller/WMController.swift:227
hotkeys.onCommand = { [weak self] command in
    self?.commandHandler.handleHotkeyCommand(command)
}

// Sources/Nehir/Core/Controller/WMController.swift:276
updateHotkeyBindings(settings.hotkeyBindings)
setHotkeysEnabled(settings.hotkeysEnabled)
```

```swift
// Sources/Nehir/Core/Controller/WMController.swift:371
func reconcileEnabledAndHotkeysState() {
    // Onboarding suppresses both the layout engine and global hotkeys so the wizard
    // never moves real windows or intercepts the shortcuts it demonstrates.
    isEnabled = desiredEnabled && accessibilityPermissionGranted && !onboardingActive

    let shouldEnableHotkeys = desiredHotkeysEnabled
        && isEnabled
        && hasStartedServices
    hotkeysEnabled = shouldEnableHotkeys
    shouldEnableHotkeys ? hotkeys.start() : hotkeys.stop()
}
```

```swift
// Sources/Nehir/Core/Input/ActionCatalog.swift:384
action(
    id: "move.right",
    command: .move(.right),
    category: .move,
    binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey | shiftKey))
)
```

```swift
// Sources/Nehir/Core/Controller/CommandHandler.swift:17
func handleHotkeyCommand(_ command: HotkeyCommand) -> ExternalCommandResult {
    guard let controller else { return .notFound }
    guard controller.isEnabled else { return .ignoredDisabled }
    if case let .focus(direction) = command,
       controller.navigateOverviewSelection(direction)
    {
        return .executed
    }
    return performCommand(command)
}

// Sources/Nehir/Core/Controller/CommandHandler.swift:48
switch command {
case let .focus(direction):
    controller.niriLayoutHandler.focusNeighbor(direction: direction)
case .focusPrevious:
    focusPreviousInNiri()
case let .move(direction):
    moveWindow(direction: direction)
```

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift:253
state.eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: callback,
    userInfo: nil
)

// Sources/Nehir/Core/Controller/MouseEventHandler.swift:285
state.gestureTap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: gestureMask,
    callback: gestureCallback,
    userInfo: nil
)
```

```swift
// Sources/Nehir/UI/KeyRecorderView.swift:101
localEventMonitor = NSEvent.addLocalMonitorForEvents(
    matching: [.keyDown]
) { [weak self] event in
    guard let self else { return event }
    return self.handleKeyEvent(event) ? nil : event
}
globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
    matching: [.keyDown]
) { [weak self] event in
    _ = self?.handleKeyEvent(event)
}
```

## Why it applies

The upstream premise is present: nehir imports Carbon for hotkeys and registers
each configured command via `RegisterEventHotKey` (`Hotkeys.swift:1`,
`Hotkeys.swift:128`). Runtime delivery also depends on Carbon's
`kEventHotKeyPressed` application event handler (`Hotkeys.swift:64`,
`Hotkeys.swift:84`), after which `WMController` forwards the command to
`CommandHandler` (`WMController.swift:227`, `CommandHandler.swift:17`).

Nothing in that runtime path sees raw keyboard `keyDown` events before Chrome or
a Chrome extension can use them. The existing `CGEventTap` sites are for mouse,
scroll, and gestures only (`MouseEventHandler.swift:230`,
`MouseEventHandler.swift:270`, `MouseWarpHandler.swift:68`,
`InteractiveMoveDemo.swift:708`); the hotkey key recorder's global monitor is
settings UI capture only (`KeyRecorderView.swift:97`, `KeyRecorderView.swift:107`).
So if macOS/Chrome routes a conflicting focused-app or extension shortcut ahead
of Carbon delivery, nehir has no suppression layer and the Nehir command simply
does not dispatch.

nehir does detect two local registration-time problems — duplicate Nehir
bindings and failed Carbon registration (`Hotkeys.swift:197`,
`Hotkeys.swift:140`) — and exposes the failure as "may be reserved by the
system" in settings (`HotkeySettingsView.swift:716`). That does not cover the
reported symptom when Carbon registration succeeds but the focused app still
wins a conflicting shortcut while focused. The triage note asked to validate the
Chrome/app shortcut interaction; by inspection, the interaction remains
unmitigated.

## Recommendation

Own a nehir action: design a priority hotkey backend instead of assuming Carbon
is sufficient. The likely direction is a runtime keyboard `CGEventTap` for
registered chords, with explicit rules for when Nehir should consume a chord
versus let the focused app receive it. Do not blindly add unconditional HID-tap
suppression for every configured chord: upstream's maintainer comment already
flags the need for app-priority / mode-switch behavior, and unconditional
suppression would make legitimate Chrome/app shortcuts impossible when users
want the app to win.

If a full event-tap backend is deferred, document the limitation in hotkey
settings and improve diagnostics so a successfully registered Carbon hotkey that
never dispatches under a focused app is distinguishable from a registration
failure.

## Suggested tests

- Manual regression: bind a Nehir command to a Chrome extension shortcut (for
  example Loom `Option+Shift+L`), focus Chrome, press the chord, and verify the
  chosen priority policy is honored.
- Unit/fixture coverage for the future dispatcher: given a registered chord and
  a focused-app allow/deny policy, assert whether the event tap returns `nil`
  and dispatches the command or passes the `keyDown` through unchanged.
- Settings/diagnostic coverage: verify duplicate Nehir bindings still report
  `.duplicateBinding`, Carbon registration failures still report
  `.systemReserved`, and focused-app priority conflicts are surfaced separately
  if diagnostics are added.
