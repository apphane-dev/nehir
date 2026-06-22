# Assign a hotkey for an action from the command palette

Source: handwritten backlog list captured 2026-06-21, idea **#9** — *"Assign
hotkey for an action from the command palette."* Triage doc for that idea. See
`planned/20260621-backlog-brainstorm.md` for the full raw list.

All source/line references were verified against the main Nehir source tree at
`56573ba2` ("Fix focus-follows-mouse blocked by click-through overlays (#64)")
on 2026-06-21. Re-verify before implementing; line numbers drift.

This is a discovery document. No source was modified.

---

## TL;DR

- Today, rebinding a Nehir action requires leaving the command palette, opening
  Settings → Hotkeys, finding the action in a flat/category list, and recording
  a new chord there. The command palette's **Commands** mode (`⌘3`) already
  lists *every* bindable action, already shows each one's current binding as a
  badge, and already holds a reference to the `WMController` + `SettingsStore`
  needed to change a binding — but it offers no way to *set* a binding.
- The idea is to let the user assign (or clear) the hotkey for the selected
  command **right there in the palette**, with the same record-a-chord flow the
  Hotkeys tab uses. It is a pure convenience/affordance feature: no new data
  model, no new config surface, no engine change. Every piece of plumbing
  already exists and is reused.
- **All command-palette commands are bindable.** `ActionCatalog.defaultHotkeyBindings()`
  emits a `HotkeyBinding` for *every* spec (including `.unassigned` ones), and
  `DefaultHotkeyBindings.all()` is exactly that list, so `SettingsStore.hotkeyBindings`
  has an entry for every id the palette can show. "Assign from palette" works
  for the whole Commands source with no special-casing.
- The one real implementation risk is **event-monitor collision**: the palette
  installs its own local `.keyDown` monitor (`installEventMonitor`) for
  `⌘1`/`⌘2`/`⌘3`/Esc/arrows/Enter, and the reusable `KeyRecorderView` installs
  its *own* local + global monitors. Two local `.keyDown` monitors compete
  (whichever returns `nil` consumes the event). The fix is either to suspend
  the palette's monitor while recording, or to factor the `NSEvent → KeyBinding`
  conversion out of `KeyRecorderNSView` into a shared helper and reinterpret keys
  inside the palette's own monitor when a `recordingCommandId` is set.
- **Recommendation: pursue**, as a small `planned/` item scoped to the Commands
  mode. Reuse `KeyRecorderView` + `HotkeyBindingEditor.capture` + the existing
  `ConflictAlert`. Enter recording via a single chord on the selected command
  (recommended `Tab`) plus an inline row affordance, surface conflicts inline,
  and keep the palette open after assigning so the user can bind several actions
  in one visit. Co-design the entry chord with backlog #4/#11 (palette search
  changes) only to the extent of not stealing a chord those will want.

---

## Prior work (do not duplicate)

Checked `discovery/`, `planned/`, `completed/`, `noop/`. Related, but **not**
this idea:

- `discovery/20260619-nehir-48-command-palette-hotkey-conflict.md` — about the
  palette's *global* summon hotkey (`Option+Command+Space`, `openCommandPalette`)
  and a diagnostics ask for registration conflicts. Touches the same hotkey
  registration path but is about *detecting* conflicts for the one palette-open
  chord, not about *assigning* per-action bindings from inside the palette. The
  conflict-detection facts there (`HotkeyRegistrationFailureReason`,
  `RegisterEventHotKey` return codes) are re-verified and reused below.
- `discovery/20260621-command-palette-fallback-all-sources.md` — about *which
  sources* the palette searches (cross-source fallback / unified mode). Operates
  on the same controller and the same Commands source, but is about search
  results, not about rebinding. Its structural map of `CommandPaletteController`
  (mode picker, `selectedMode`, `filteredCommandItems`, `resolvedSelectionAction`,
  `CommandPaletteSelectionID`) is assumed here and not re-derived.
- `discovery/20260619-choru-leader-palette.md` — a fourth palette mode (`.leader`)
  on the `choru-k` fork. Relevant only as precedent that `CommandPaletteMode` and
  the `⌘N` mode shortcuts extend cleanly; it does not rebind actions.
- `planned/20260621-backlog-brainstorm.md`:
  - **#11** *"Fuzzy search in the command palette"* — changes *how* each source
    matches; orthogonal to *rebinding* the selected match. No overlap.
  - **#22** *"Make all numbered hotkeys use `{N}` template"* — config-format
    change for numbered groups; would not be exposed from the palette (numbered
    groups are intentionally edited as a 1–9 *pattern* in the Hotkeys tab, see
    `HotkeySettingsView.swift`'s `startNumberedGroupRecording`, and don't map to
    a single palette row). Out of scope here.
  - **#25** *"Shortcut presets"* — swapping whole binding *sets*; complementary,
    not overlapping.
  - **#18** *"Right-click actions in the action bar"* — a different surface
    (action bar, not palette). A right-click context menu on a palette row is one
    *possible* entry point for this idea (see Open Questions), but #18 itself is
    not the palette.

Nothing in the repo implements "assign binding from the palette" today: a grep
of `Sources/Nehir/UI/CommandPalette/` and `Sources/Nehir/Core/CommandPaletteMode.swift`
for `assign`, `record`, `configureKeybind`, `setShortcut`, `updateTrigger` returns
nothing in the palette code path.

---

## What the idea means for Nehir

The palette is Nehir's keyboard launcher. Its Commands mode is already the
canonical, searchable index of every action Nehir can perform — and each row
already renders the action's current shortcut as a `CommandPaletteShortcutBadge`
(`bindingDisplay`, `CommandPaletteController.swift:1482`). The natural next step,
found in VS Code, Raycast, Linear, and most modern launchers, is: when the user
has selected a command, let them **bind or rebind it in place** rather than
context-switching to a separate settings screen.

Concretely the feature removes two friction points:

1. **Discovery round-trip.** A user who finds an action via the palette and
   wants it on a key today must memorize the action name, open Settings →
   Hotkeys, re-search for it, and record there. The palette already did the
   search; throwing it away is the friction.
2. **Unassigned actions stay unassigned.** Several useful actions ship with
   `binding: .unassigned` (e.g. `rescueOffscreenWindows`, `toggleFocusedWindowFloating`,
   `assignFocusedWindowToScratchpad`, `toggleScratchpadWindow`, `openSettings` —
   `ActionCatalog.swift:681`, `:689`, `:697`, `:705`, `:725`). Today their
   `bindingDisplay` is `nil`, so the palette shows them with no badge and no
   hint that they are bindable. An in-palette "assign" affordance makes these
   first-class instead of hidden behind Settings.

The feature is a convenience/affordance layer only. It does not add a new
binding source, a new config key, or a new IPC command; it is a second entry
point into the existing binding pipeline.

---

## Current behavior (with source citations)

### The Commands source already carries everything needed to rebind

Each command row is a `CommandPaletteCommandItem`:

```swift
// Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift:64-71
struct CommandPaletteCommandItem: Identifiable {
    let id: String            // == ActionSpec.id == HotkeyBinding.id
    let command: HotkeyCommand
    let title: String
    let category: HotkeyCategory
    let bindingDisplay: String?
    let searchTerms: [String]
}
```

`id` is the **same** string used as `HotkeyBinding.id` (and as the
`HotkeyConfigMapping` internal id). The items are built straight from the
catalog, keyed against the live bindings to render the current chord:

```swift
// CommandPaletteController.swift:498-515
private func buildCommandItems(from wmController: WMController) -> [CommandPaletteCommandItem] {
    let bindingsByID = Dictionary(
        uniqueKeysWithValues: wmController.settings.hotkeyBindings.map { ($0.id, $0.binding) }
    )
    let developerModeEnabled = wmController.settings.developerModeEnabled
    return ActionCatalog.allSpecs()
        .filter { !$0.requiresDeveloperMode || developerModeEnabled }
        .map { spec in
            let trigger = bindingsByID[spec.id]
            let bindingDisplay = trigger.flatMap { $0.isUnassigned ? nil : $0.displayString }
            return CommandPaletteCommandItem(
                id: spec.id,
                command: spec.command,
                title: spec.title,
                category: spec.category,
                bindingDisplay: bindingDisplay,
                searchTerms: spec.searchTerms
            )
        }
}
```

So the palette already (a) shows every bindable action, (b) knows the current
binding for each, and (c) holds the id needed to change it.

### The controller already has the handles needed to mutate bindings

```swift
// CommandPaletteController.swift:188
private weak var wmController: WMController?
```

`wmController.settings` is the live `SettingsStore` (used above at `:500`/`:502`),
and `WMController.updateHotkeyBindings` re-registers Carbon hotkeys after a
change:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:856-858
func updateHotkeyBindings(_ bindings: [HotkeyBinding], force: Bool = false) {
    hotkeys.updateBindings(bindings, force: force)
}
```

### Every palette command has a bindable slot (this is the key enabler)

`DefaultHotkeyBindings.all()` is literally `ActionCatalog.defaultHotkeyBindings()`:

```swift
// Sources/Nehir/Core/Input/DefaultHotkeyBindings.swift:9-11
static func all() -> [HotkeyBinding] {
    ActionCatalog.defaultHotkeyBindings()
}
```

…and `ActionCatalog.defaultHotkeyBindings()` (`Sources/Nehir/Core/Input/ActionCatalog.swift:99-105`)
maps **every** spec — including those whose `defaultBinding` is `.unassigned` —
into a `HotkeyBinding`. `SettingsStore.hotkeyBindings` is seeded from that list
and therefore contains an entry for every spec id. Consequently
`SettingsStore.updateTrigger(for:newTrigger:)` will find an index for *any*
command the palette can show:

```swift
// Sources/Nehir/Core/Config/SettingsStore.swift:589-596
func updateTrigger(for commandId: String, newTrigger: HotkeyTrigger) {
    guard let index = hotkeyBindings.firstIndex(where: { $0.id == commandId }) else { return }
    hotkeyBindings[index] = HotkeyBinding(
        id: hotkeyBindings[index].id,
        command: hotkeyBindings[index].command,
        trigger: newTrigger
    )
}
```

`hotkeyBindings` has `didSet { scheduleSave() }` (`SettingsStore.swift:163-165`),
so a change from the palette auto-persists to `hotkeys.toml` via
`HotkeysTOMLCodec`. No extra persistence work is needed.

### The reusable capture + apply pipeline already exists

**Capture** — `KeyRecorderView` is a self-contained `NSViewRepresentable`
(`Sources/Nehir/UI/KeyRecorderView.swift:11-31`). Its backing `KeyRecorderNSView`
installs both a local and a global `.keyDown` monitor, converts the press to a
`KeyBinding`, and calls back:

```swift
// KeyRecorderView.swift:13-15
var allowsBareKeys: Bool = false
let onCapture: (KeyBinding) -> Void
let onCancel: () -> Void
```

```swift
// KeyRecorderView.swift:103-152 (abbreviated)
private func startRecording() {
    ...
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { ... handleKeyEvent($0) ... }
    globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { ... handleKeyEvent($0) ... }
    DispatchQueue.main.async { ... window.makeFirstResponder(self) ... }
}
...
private func handleKeyEvent(_ event: NSEvent) -> Bool {
    if event.keyCode == UInt16(kVK_Escape) { ...; onCancel?(); return true }
    guard let binding = binding(from: event) else { return false }
    ...; onCapture?(binding); return true
}

private func binding(from event: NSEvent) -> KeyBinding? {        // :156
    let carbonModifiers = carbonModifiersFromNSEvent(event)
    let requiresModifier = !isSpecialKey(Int(event.keyCode))
    guard allowsBareKeys || !requiresModifier || carbonModifiers != 0 else { return nil }
    return KeyBinding(keyCode: UInt32(event.keyCode), modifiers: normalizedHyperModifiers(carbonModifiers))
}
```

`binding(from:)` enforces the "no bare keys unless allowed" rule and the
function-key exception — exactly the policy a palette recorder wants.

**Apply** — `HotkeyBindingEditor.capture` is the single chokepoint the Hotkeys
tab uses to commit a recorded chord:

```swift
// Sources/Nehir/UI/HotkeySettingsView.swift:29-44
static func capture(
    _ newTrigger: HotkeyTrigger,
    for actionId: String,
    settings: SettingsStore
) -> HotkeyCaptureResult {
    let conflicts = settings.findConflicts(for: newTrigger, excluding: actionId)
    guard conflicts.isEmpty else {
        return .conflict(
            ConflictAlert(
                targetActionId: actionId,
                newTrigger: newTrigger,
                conflictingCommands: conflicts.map(\.command.displayName)
            )
        )
    }
    settings.updateTrigger(for: actionId, newTrigger: newTrigger)
    return .applied
}
```

`settings.findConflicts(for:excluding:)` (`SettingsStore.swift:613-618`) returns
the existing bindings that claim the same chord. The Hotkeys tab then calls
`controller.updateHotkeyBindings(settings.hotkeyBindings)` to re-register
(`HotkeySettingsView.swift:426`). Every one of those calls is reachable from the
palette controller too.

### Where the entry-point affordance would live

Two existing UX patterns to mirror:

- **Per-row inline hint on the selected row.** Window mode already shows a
  context-sensitive secondary-action hint on the selected row only:
  ```swift
  // CommandPaletteController.swift:321-325
  static func selectedWindowHint(isSummonRightAvailable: Bool) -> InlineHint? {
      guard isSummonRightAvailable else { return nil }
      return InlineHint(title: "Summon Right", shortcut: "⇧↩")
  }
  ```
  …rendered in `CommandPaletteWindowRow` (`:1396-1402`). The same shape
  ("Assign Shortcut", "<chord>") fits a selected command row.
- **Footer status text.** Commands mode currently advertises its primary action:
  ```swift
  // CommandPaletteController.swift:1318-1320 (statusText)
  case .commands:
      "Enter executes the selected command."
  ```
  This is the natural place to surface the assign chord when a command is
  selected and no recording is in progress, and to surface "Press a key
  combination… Esc to cancel" while recording.

### Event handling the palette already owns

The palette installs one local `.keyDown` monitor at show time and routes every
key through `handleKeyDown`:

```swift
// CommandPaletteController.swift:690-696
private func installEventMonitor() {
    removeEventMonitor()
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, isVisible else { return event }
        return handleKeyDown(event) ? nil : event
    }
}
```

`handleKeyDown` (`:705-731`) handles `⌘1`/`⌘2`/`⌘3` (mode shortcuts),
`Esc` (cancel), `↑`/`↓` (move selection), and `Return`/`Enter` (primary) and
`⇧↩` (alternate) via `selectionTrigger(forKeyCode:modifierFlags:)` (`:746-756`).
`CommandPaletteSelectionTrigger` today has exactly two cases — `.primary` and
`.alternate` (`:78-81`). There is no third slot, so an "assign" action needs
either a dedicated chord that enters a recording *mode* (recommended) rather
than a third selection trigger.

---

## Where / how it would be implemented

All changes are confined to `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift`
plus a small shared extraction in `Sources/Nehir/UI/KeyRecorderView.swift`. No
engine, config-file, schema, or IPC changes required.

### 1. Controller recording state

Add a published `recordingCommandId: String?` to `CommandPaletteController`.
When non-nil, the palette is in recording mode for that command id and the
footer/row UI reflects it. Reset it in `dismiss(reason:)` (`:786`) alongside the
other transient state so a dismissed palette never resumes recording.

### 2. Enter recording from the selected command

Add an entry point invoked by a chord on the selected Commands row. Two
reasonable shapes:

- **(a) Dedicated chord (recommended).** Handle a new chord in `handleKeyDown`
  only when `selectedMode == .commands` and a command is selected — e.g.
  `Tab` (currently unused by the palette) or `⌘K` (the near-universal "configure
  keybinding" chord; VS Code uses it). `Tab` is the lighter touch because it
  needs no modifiers and reads as "move focus to the binding field".
- **(b) Inline button on the row.** Render a small keyboard glyph / "Record"
  button in `CommandPaletteCommandRow` (`:1474`) that sets `recordingCommandId`.
  More discoverable for mouse users; redundant with (a) for keyboard users.

Ship (a); add (b) only if discoverability testing asks for it. Mirror the
existing inline-hint pattern: when a command is selected and not recording, show
an `InlineHint(title: "Assign Shortcut", shortcut: "⇥")` (or `⌘K`) on the
selected row, the same way `selectedWindowHint` adorns the selected window row.

### 3. Capture the chord (resolve the monitor collision)

Two viable strategies. Pick one; do not do both.

- **Strategy A — reuse `KeyRecorderView` inline.** When `recordingCommandId !=
  nil`, render a `KeyRecorderView` (the existing `NSViewRepresentable`) in place
  of the footer or as an overlay row. It installs its own local + global
  monitors and becomes first responder. **The palette's own
  `installEventMonitor` local monitor is still active** and runs first; to avoid
  it eating the recording keys (or double-handling), make `handleKeyDown`
  early-return `false` (pass the event through) whenever `recordingCommandId !=
  nil`. This is a one-line guard at the top of `handleKeyDown` and is the
  smallest correct change.
- **Strategy B — record inside the palette's own monitor.** Extract the
  `NSEvent → KeyBinding` conversion (`KeyRecorderNSView.binding(from:)`,
  `:156-169`, plus `carbonModifiersFromNSEvent` and `isSpecialKey`) into a
  shared static, e.g. `KeyCapture.binding(from:allowsBareKeys:)`. In
  `handleKeyDown`, when `recordingCommandId != nil`, interpret the event with
  that helper: `Esc` cancels, a valid chord calls `commitRecording(_:)`, an
  invalid press (bare key when disallowed) is ignored. No second monitor at all,
  so no collision and no first-responder juggling.

Strategy A maximizes reuse and keeps the recording widget visually identical to
the Hotkeys tab (good for familiarity); Strategy A's cost is coordinating two
monitors and a first-responder swap inside a borderless `NSPanel`. Strategy B is
more self-contained and avoids the panel/responder subtlety, at the cost of a
small refactor of `KeyRecorderView`. **Recommendation: start with Strategy A**
(reuse is high-value and the early-return guard is trivial); fall back to
Strategy B if the responder/panel interaction proves fiddly in the borderless
panel (`CommandPalettePanel`, `:118-122`, `canBecomeKey == true`).

### 4. Apply the chord, surface conflicts, re-register

On capture, call the exact pipeline the Hotkeys tab uses:

```swift
// pseudocode inside CommandPaletteController
func commitRecording(_ binding: KeyBinding) {
    guard let id = recordingCommandId, let wmController else { return }
    let trigger: HotkeyTrigger = binding.isUnassigned ? .unassigned : .chord(binding)
    switch HotkeyBindingEditor.capture(trigger, for: id, settings: wmController.settings) {
    case .applied:
        wmController.updateHotkeyBindings(wmController.settings.hotkeyBindings)
        commandItems = buildCommandItems(from: wmController)   // refresh badges
        recordingCommandId = nil
    case let .conflict(alert):
        pendingConflictAlert = alert                            // show inline (see #5)
    }
}
```

Note `HotkeyBindingEditor` and `ConflictAlert` are currently `internal`-ish types
in `Sources/Nehir/UI/HotkeySettingsView.swift` (`:15`, `:581`); they are
file-scoped only if marked `private`. Verify visibility at implementation time
and promote if needed (they are already used across the Hotkeys UI, so they are
not `private` to a single view body).

### 5. Conflict and cancel UX

- **Conflict.** Reuse `ConflictAlert` (`HotkeySettingsView.swift:581-617`),
  whose `message` already reads *"This key combination is already used by
  \"X\". Do you want to replace it?"* On "Replace", call
  `HotkeyBindingEditor.applyConflictResolution(alert, settings:)`
  (`HotkeySettingsView.swift:66-74`), which clears the losing binding(s) and
  applies the new one, then `updateHotkeyBindings` + refresh. Present the alert
  with the same mechanism the palette already uses for destructive confirmations
  (`DestructiveConfirmationAlert.confirm(...)` in `performSelectionAction`,
  `CommandPaletteController.swift:884`/`:896`) — i.e. a modal sheet over the
  panel, not a separate window.
- **Cancel.** `Esc` during recording cancels (`KeyRecorderView`'s `onCancel`);
  clear `recordingCommandId`. Note `Esc` already dismisses the whole palette
  outside recording (`handleKeyDown` `:717`), so the recording guard must
  intercept `Esc` *first* — Strategy A's `KeyRecorderView` does this naturally
  because it becomes first responder; under Strategy B the
  `recordingCommandId != nil` branch in `handleKeyDown` must handle `Esc`
  before the dismiss branch.
- **Clearing a binding.** Offer "Clear" alongside "Assign": when the selected
  command already has a binding, the inline hint can read "Clear Shortcut ⇥" /
  "Reassign ⌘K". Clearing calls `settings.clearBinding(for:)`
  (`SettingsStore.swift:598-600`) → `updateHotkeyBindings` → refresh.

### 6. Keep the palette open after assigning

Unlike `selectCurrent` (which `dismiss(reason: .selection)` at `:768`), a
binding change should **not** dismiss the palette — the user typically wants to
bind several actions in one visit. After `commitRecording`, stay open, rebuild
`commandItems` so the badge updates live (`:498`), keep the same selection, and
return focus to the search field. `dismiss` must still clear
`recordingCommandId` for safety.

### 7. Tests

The harness in `Tests/NehirTests/CommandPaletteControllerTests.swift` already
constructs a real `WMController(settings: SettingsStore(defaults: ...))`
(`:20`) and drives `controller.toggle(wmController:)` / `.show(wmController:)`
plus test hooks (`setMenuLoadingStateForTests`, `:433`). Add:

- **Apply:** switch to `.commands`, select an unassigned action (e.g.
  `rescueOffscreenWindows`), call the new `commitRecording(_:)` (or a
  test-friendly `assignBinding(for:newBinding:)` wrapper) with a free chord;
  assert `wmController.settings.hotkeyBindings` now has that chord for the id,
  the item's `bindingDisplay` updated, and `recordingCommandId` cleared.
- **Conflict:** assign a chord already used by another action; assert the
  controller produces a `pendingConflictAlert` and does **not** mutate
  `hotkeyBindings`. Resolve it (applyConflictResolution) and assert the losing
  binding became `.unassigned` and the new one took the chord.
- **Clear:** assign then clear; assert the binding reverts to `.unassigned` (or
  the spec default — see Open Questions) and the badge disappears.
- **Lifecycle:** `dismiss` while `recordingCommandId != nil` clears it; showing
  the palette again never starts in recording mode.
- **Coverage of the existing path:** re-run the Hotkeys-tab binding tests (if
  any call `HotkeyBindingEditor.capture` directly) unchanged to prove the shared
  pipeline is not perturbed.

The record/capture widget itself (`KeyRecorderView`) needs no new tests — it is
unmodified under Strategy A.

---

## Risks and unknowns

1. **Two local `.keyDown` monitors (Strategy A).** The palette's
   `installEventMonitor` (`:690`) and `KeyRecorderNSView`'s
   `localEventMonitor` (`KeyRecorderView.swift:107`) both match `.keyDown`.
   `NSEvent` local handlers run in registration order; the first to return `nil`
   consumes. The mitigation is the early-return guard in `handleKeyDown` when
   `recordingCommandId != nil`, plus letting `KeyRecorderView` take first
   responder. **Unknown:** whether `CommandPalettePanel` (borderless,
   `canBecomeKey == true`, `:120`) reliably transfers first responder to an
   embedded `NSViewRepresentable` without the search field stealing it back —
   needs a quick spike. If flaky, switch to Strategy B (no second monitor).
2. **First-responder vs. the search field.** The palette focuses the search
   field on show (`focusSearchField`, called from `show` via
   `DispatchQueue.main.async` at `:295`). Entering recording must move focus to
   the recorder and leaving recording must return it to the search field, or the
   user's next keystrokes go nowhere. `KeyRecorderNSView.startRecording` already
   does `window.makeFirstResponder(self)` (`KeyRecorderView.swift:124-126`); the
   palette must re-`focusSearchField()` on commit/cancel.
3. **Global monitor privacy prompt.** `KeyRecorderNSView` installs a *global*
   `.keyDown` monitor (`:113`). In the Hotkeys tab this is fine because the
   Settings window is frontmost. Inside the palette (also an `NSPanel` that
   becomes key) it should likewise be fine, but a global monitor can trigger an
   Input Monitoring prompt on a fresh install if Nehir isn't already granted.
   Since Nehir already requires Accessibility (and typically Input Monitoring)
   for its core window-management duties, this is likely a non-issue — but
   confirm Nehir already holds Input Monitoring in normal operation; if not,
   prefer Strategy B (no global monitor).
4. **Recording a chord that the palette itself uses.** If the user records
   `⌘1`/`⌘2`/`⌘3` (mode shortcuts), `Esc`, `↑`/`↓`, or `↩`, those are the
   palette's own navigation keys. `KeyRecorderNSView.binding(from:)` requires a
   modifier for non-function keys by default (`allowsBareKeys == false`), so
   bare arrows/Enter are already rejected; but `⌘1` etc. would be accepted and
   would then both be recorded *and* (after the early-return guard is lifted on
   commit) trigger a mode switch. The pipeline's `findConflicts` will catch
   conflicts with *other Nehir commands*, but not with the palette's own
   non-bindable chords. **Mitigation:** after capture, additionally reject (or
   warn on) any chord equal to a palette-reserved chord before committing. Low
   effort; fold into `commitRecording`.
5. **Default vs. unassigned semantics on "Clear".** `settings.clearBinding(for:)`
   sets `.unassigned` (`SettingsStore.swift:598-600`); `resetBindings(for:)`
   restores the spec *default* (`:602-607`). The Hotkeys tab exposes both
   ("Clear" and "Reset"). The palette should at minimum offer Clear; offering
   Reset too is a nice-to-have but adds UI weight. Decide in Open Questions.
6. **Discoverability.** A chord alone is invisible to mouse-first users. The
   inline row hint (mirroring `selectedWindowHint`) plus footer status text
   covers keyboard users; a small per-row glyph covers mouse users. Without at
   least one persistent cue the feature will be found only by accident.
7. **Scope creep into numbered groups.** Numbered groups (`switchWorkspace.N`,
   `focusColumn.N`, etc.) are edited as a *1–9 pattern* in the Hotkeys tab, not
   as individual bindings (`HotkeyConfigMapping.NumberedGroup`,
   `startNumberedGroupRecording`). Each numbered binding is a separate row in
   the palette, so assigning one in isolation is technically possible via
   `updateTrigger`, but it would diverge from the pattern model and produce a
  `hotkeys.toml` that no longer round-trips through the group editor cleanly.
   **Mitigation:** for the first cut, only allow assigning *singleton* (non-
   numbered) actions from the palette; show numbered-group rows as read-only or
   hide the assign affordance on them. (This also sidesteps backlog #22's
   `{N}`-template rework.)

---

## Open questions

1. **Entry chord.** `Tab`, `⌘K`, or both? `Tab` is the lightest and unused by
   the palette today; `⌘K` is the cross-editor convention. Recommendation: ship
   `Tab` (or `⌘K`) first and let the other be a redundant alias if requested.
2. **Clear vs. Reset.** Does the palette offer only "Clear" (→ `.unassigned`),
   or also "Reset to default" (→ spec default)? Lean: only Clear, to keep the
   row affordance minimal; Reset stays in the Hotkeys tab for the power users
   who already know to look there.
3. **Recording widget placement.** Replace the footer status row with the
   recorder while recording (Strategy A), or float a small recorder overlay
   below the selected row? Footer-replacement is simpler and matches the
   "recording" mental model of the Hotkeys tab.
4. **Numbered groups.** Confirm they are out of scope for v1 (hide/disable the
   assign affordance on `switchWorkspace.N`, `focusColumn.N`, etc.) — these are
   the bindings whose id matches a `HotkeyConfigMapping.NumberedGroup.internalIdPattern`.
5. **Should assigning auto-switch the user to Commands mode?** No — the
   affordance is only meaningful there. If the user invokes the assign chord in
   Windows or Menu mode, either no-op or briefly hint "Switch to Commands (⌘3)
   to assign a shortcut." Recommendation: no-op; the inline hint only renders in
   Commands mode.
6. **Persistence of the recording across palette reopens.** Should a half-
   started recording survive `dismiss`? No — `dismiss` clears it (see #6 above).
   Recording is a transient, within-session mode.

---

## Recommendation

**Pursue, as a small `planned/` item scoped to the Commands mode.**

Why:

- The palette already lists every bindable action, shows each one's current
  binding, and holds the `WMController`/`SettingsStore` handles needed to change
  it. The entire capture → conflict-check → apply → re-register → persist
  pipeline already exists and is reusable verbatim (`KeyRecorderView` +
  `HotkeyBindingEditor` + `SettingsStore.updateTrigger`/`clearBinding` +
  `WMController.updateHotkeyBindings`). The feature is an **entry point + small
  controller state**, not new infrastructure.
- It materially improves two real frictions: the discovery round-trip (find in
  palette → re-find in Settings) and the invisibility of intentionally-
  unassigned actions (`rescueOffscreenWindows`, `toggleFocusedWindowFloating`,
  scratchpad actions, `openSettings`). The latter is the more valuable of the
  two: those actions ship unbound and the palette is the only place that lists
  them all in one searchable view.
- Risk is contained. The only non-trivial unknown is the event-monitor /
  first-responder interaction inside the borderless panel (Strategy A), and
  there is a clean fallback (Strategy B: record inside the palette's own monitor
  via a small extraction from `KeyRecorderView`). Neither strategy touches the
  WM engine, config schema, hotkey registration, or persistence.
- It does **not** conflict with the sibling palette ideas. #4 (cross-source
  search) and #11 (fuzzy) change *how/where* matches are found; this idea
  operates on a *selected* match and is orthogonal. The only coordination is
  chord selection (don't pick a chord #4/#11 will want for navigation) — easy,
  since the palette has several free chords (`Tab`, `⌘K`, `⌘L`, …).

Sizing hint: one published `recordingCommandId` + one `commitRecording(_:)` +
one `handleKeyDown` guard + one inline `InlineHint` + one conflict/cancel sheet
branch in the view + ~4 tests. Call it a half-day to a day including the
Strategy-A/Strategy-B spike.

---

## Related

- Discovery: `discovery/20260619-nehir-48-command-palette-hotkey-conflict.md` —
  the palette's global summon hotkey and the Carbon registration-conflict path.
  Re-verified here at `56573ba2`; the `HotkeyBindingEditor`/`SettingsStore`
  pipeline facts above are the same ones that doc's diagnostics proposal would
  surface.
- Discovery: `discovery/20260621-command-palette-fallback-all-sources.md` —
  structural map of `CommandPaletteController` (modes, selection, dispatch) this
  doc builds on without re-deriving. Its Variant A (fallback on empty) shipped
  in commit `1aa518bc`; see `completed/20260621-command-palette-fallback-all-sources.md`.
- Discovery: `discovery/20260619-choru-leader-palette.md` — precedent for adding
  palette modes / `⌘N` shortcuts and for dispatching commands via the catalog.
- Backlog: `planned/20260621-backlog-brainstorm.md` **#11** (fuzzy search) and
  **#4** (cross-source search) — orthogonal; coordinate only on chord choice.
  **#4** shipped (commit `1aa518bc`) without claiming a chord, so coordination
  now applies only to **#11**. **#22** (`{N}` template) and **#25** (presets)
  are the reason numbered groups are recommended out of scope for v1.
