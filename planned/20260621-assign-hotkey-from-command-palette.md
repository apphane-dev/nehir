# Assign a hotkey for an action from the command palette

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned
**Source discovery:** `discovery/20260621-assign-hotkey-from-command-palette.md`
**Related:** `planned/20260621-backlog-brainstorm.md` (idea #9; coordinate chord choice with
#11 fuzzy search — #4 cross-source search shipped in commit `1aa518bc` without
claiming a chord, see `completed/20260621-command-palette-fallback-all-sources.md`),
`completed/20260619-nehir-48-command-palette-hotkey-conflict.md`
(palette global-summon conflict path — shares `HotkeyBindingEditor`/`SettingsStore` pipeline).

Source references were refreshed against main `7a025b78` on 2026-07-07. `CommandPaletteController` still has no `recordingCommandId` / conflict-recording symbols, and `HotkeySettingsView.isNumberedGroupMember(_:)` remains private (currently around `Sources/Nehir/UI/HotkeySettingsView.swift:530`).

## TL;DR

Let the user assign, reassign, or clear the hotkey for the selected command
**right there in the command palette's Commands mode** (`⌘3`), instead of
context-switching to Settings → Hotkeys. The palette already lists every
bindable action, already renders each one's current chord as a badge
(`CommandPaletteShortcutBadge`, `CommandPaletteController.swift:1302`/`:1482`),
and already holds the `WMController`/`SettingsStore` handles needed to mutate a
binding. The entire capture → conflict-check → apply → re-register → persist
pipeline already exists and is reused verbatim (`KeyRecorderView` +
`HotkeyBindingEditor` + `SettingsStore` + `WMController.updateHotkeyBindings`).
This is an entry point + small controller state, **not** new infrastructure: no
new data model, config key, schema, or engine change.

Concretely: add one published `recordingCommandId: String?` to
`CommandPaletteController`, enter recording via a `Tab` chord on the selected
Commands row (mirroring the existing `InlineHint` pattern), render the reusable
`KeyRecorderView` in place of the footer while recording, and on capture call
the same `HotkeyBindingEditor.capture(_:for:settings:)` chokepoint the Hotkeys
tab uses. Surface conflicts with the existing `ConflictAlert`, keep the palette
open after assigning (so several actions can be bound in one visit), and carve
out numbered groups (`switchWorkspace.N`, `focusColumn.N`, …) as read-only for
v1 because they are edited as a 1–9 pattern, not as individual rows.

## Discovery corrections / decisions

The discovery recommendation is right at the product level. Corrections made
while porting to current main `7a025b78`:

1. **Use the `KeyBinding` overload of `HotkeyBindingEditor.capture`, not the
   `HotkeyTrigger` one.** The discovery's `commitRecording` pseudocode manually
   builds `HotkeyTrigger` via `binding.isUnassigned ? .unassigned : .chord(binding)`.
   That conversion already exists as
   `HotkeyBindingEditor.capture(_ newBinding: KeyBinding, for:settings:)`
   (`Sources/Nehir/UI/HotkeySettingsView.swift:22-28`), which delegates to the
   `HotkeyTrigger` overload at `:29`. Since `KeyRecorderView.onCapture` yields a
   `KeyBinding` directly, call the `KeyBinding` overload — less code, and it is
   exactly the path single-binding Hotkeys-tab rows take. Likewise prefer
   `SettingsStore.findConflicts(for: KeyBinding, excluding:)` (`SettingsStore.swift:609`)
   and `SettingsStore.updateBinding(for:newBinding:)` (`:588`) over hand-rolling
   the trigger conversion.
2. **No visibility promotion is needed.** The discovery hedged "verify
   visibility and promote if needed" for `HotkeyBindingEditor` and
   `ConflictAlert`. Verified: both are internal (no access modifier) —
   `@MainActor enum HotkeyBindingEditor` at `HotkeySettingsView.swift:20` and
   `struct ConflictAlert: Identifiable` at `HotkeySettingsView.swift:581`. They
   are already module-visible from `CommandPaletteController`; nothing to
   promote. (`HotkeyCaptureResult` at `:10` and `HotkeyTriggerMapping` at `:17`
   are likewise internal.)
3. **`isNumberedGroupMember` is private — do not reuse it; add a shared helper.**
   The Hotkeys tab gates numbered groups with `private func isNumberedGroupMember(_:)`
   (`HotkeySettingsView.swift:520`), which is private to that view and therefore
   unreachable from the palette. The plan adds a single shared predicate (e.g. a
   `static func` on `HotkeyConfigMapping`, next to `numberedGroups` at
   `HotkeyConfigMapping.swift:17-46`) and has both call sites use it, rather
   than duplicating the `(0..<9)`/`internalIdPattern` scan in the palette.
4. **Decision: ship `Tab` as the entry chord (not `⌘K`).** `Tab` is unused by
   the palette today and reads as "move focus to the binding field". `⌘K` stays
   available as a redundant alias for a follow-up if discoverability testing
   asks for it. (Open Question 1 in the discovery.)
5. **Decision: ship Clear only, not Reset.** "Clear" maps to
   `SettingsStore.clearBinding(for:)` → `.unassigned`. "Reset to default"
   (`resetBindings(for:)`, `SettingsStore.swift:601`) stays in the Hotkeys tab;
   adding it to the palette doubles the row affordance for a power-user-only
   action. (Open Question 2.)
6. **Decision: Strategy A (reuse `KeyRecorderView` inline) is the primary
   implementation; Strategy B is the documented fallback, not a parallel path.**
   The plan implements A and specifies the exact fallback trigger (responder
   transfer flaky inside the borderless panel) at which the worker switches to
   B. Do not implement both.
7. **Line-number drift from the discovery (re-verified at `7a025b78`):**
   `CommandPaletteCommandItem` struct `:64-71` → `:63-70`; `CommandPaletteSelectionTrigger`
   `:78-81` → `:72-75`; `selectionTrigger(forKeyCode:modifierFlags:)` `:746-756`
   → `:738-748`; `CommandPaletteCommandRow` `:1474` → `:1464`; `CommandPalettePanel`
   `:118-122` → `:144-148`; `statusText`/`"Enter executes…"` `:1318-1320` →
   `statusText` at `:1180`, string at `:1189`; `selectCurrent`/`dismiss(.selection)`
   `:768` → `selectCurrent` `:767`, `dismiss` `:773`; `focusSearchField` async
   call `:295` → `:298`; `DestructiveConfirmationAlert.confirm` `:884`/`:896` →
   `:878`/`:884`; `WMController.updateHotkeyBindings` `:856-858` → `:862-864`;
   `DefaultHotkeyBindings.all()` `:9-11` → `:10-12`;
   `ActionCatalog.defaultHotkeyBindings()` `:99-105` → `:97-103`; unassigned-spec
   ids `:681/:689/:697/:705/:725` → `:686/:693/:700/:707/:721`;
   `SettingsStore.updateTrigger` `:589-596` → `:590-597`, `resetBindings` `:602-607`
   → `:601-606`; `HotkeyBindingEditor` `:15` → `:20`; `applyConflictResolution`
   `:66-74` → `:72-84`; `controller.updateHotkeyBindings` call site `:426` →
   `:427`. Citations in the rest of this plan use the corrected numbers.

## Scope

### Files to add/change

1. `Sources/Nehir/Core/Config/HotkeyConfigMapping.swift`
   - Add a shared numbered-group membership predicate so the palette and the
     Hotkeys tab share one source of truth. Next to `numberedGroups`
     (`:17-46`), expose e.g.
     `static func isNumberedGroupMember(_ bindingId: String) -> Bool`
     mirroring the private `HotkeySettingsView.isNumberedGroupMember`
     (`HotkeySettingsView.swift:520-526`): scan `numberedGroups`, for each
     `(0..<9)` build the internal id via `internalIdPattern`, compare.
2. `Sources/Nehir/UI/HotkeySettingsView.swift`
   - Replace the body of the private `isNumberedGroupMember(_:)` (`:520`) with a
     delegation to the new `HotkeyConfigMapping.isNumberedGroupMember(_:)`. No
     behavior change; removes duplication.
3. `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift` (all UI +
   controller state; the bulk of the work)
   - **Controller state.** Add `@Published private(set) var recordingCommandId: String?`
     near the other transient state. `nil` == not recording.
   - **Reset on dismiss.** In `dismiss(reason:)` (`:773`), set
     `recordingCommandId = nil` alongside the existing `searchText = ""`,
     `selectedItemID = nil`, `commandItems = []` cleanup, so a dismissed palette
     never resumes recording.
   - **Early-return guard.** At the top of `handleKeyDown(_:)` (`:705`), add
     `if recordingCommandId != nil { return false }` so the palette's own
     `.keyDown` monitor (`installEventMonitor`, `:690`) passes every key through
     to the embedded `KeyRecorderView` (which is first responder) while
     recording. This is the one-line fix for the two-local-monitor collision.
   - **Entry chord.** In the `default:` branch of `handleKeyDown` (`:705`),
     before the existing `selectionTrigger` lookup, handle `Tab` (keyCode `48`)
     when `selectedMode == .commands`, a command is selected, the selection is
     not a numbered-group member (`HotkeyConfigMapping.isNumberedGroupMember`),
     and `recordingCommandId == nil`: set `recordingCommandId` to the selected
     `CommandPaletteCommandItem.id`. Bare `Tab` only — no modifiers — so it
     cannot clash with `⌘1`/`⌘2`/`⌘3` mode shortcuts or `⇧↩` alternate.
   - **Clear affordance.** When the selected command already has a binding
     (`bindingDisplay != nil`), the inline hint reads "Clear Shortcut ⇥" and
     `Tab` instead calls `clearSelectedCommandBinding()`; when unassigned, the
     hint reads "Assign Shortcut ⇥". (Decision 5: no Reset.)
   - **Inline hint.** Mirror `selectedWindowHint` (`:321`): add
     `selectedCommandHint(isAssigned:)` returning
     `InlineHint(title: "Assign Shortcut"|"Clear Shortcut", shortcut: "⇥")`,
     rendered on the selected command row only, the same way
     `CommandPaletteWindowRow` renders `summonHint` (`:1410-1417`).
   - **Footer status text.** In `statusText` (`:1180`), when
     `controller.recordingCommandId != nil` return
     `"Press a key combination… Esc to cancel."` regardless of mode; otherwise
     keep the per-mode strings (`:1189` for `.commands`).
   - **Recording widget (Strategy A).** In the SwiftUI body that renders
     `statusText` (`:1090`), when `controller.recordingCommandId != nil`,
     replace the footer text with an embedded
     `KeyRecorderView(accessibilityLabel:onCapture:onCancel:)` (same init shape
     as `HotkeySettingsView.swift:768-771`). Wire:
     - `onCapture: { commitRecording($0) }`
     - `onCancel: { cancelRecording() }`
     - Give it `.frame(minWidth: 180, idealWidth: 210, minHeight: 34)` like the
       Hotkeys tab (`:772`).
   - **`commitRecording(_ binding: KeyBinding)`.** New private method:
     ```swift
     guard let id = recordingCommandId, let wmController else { return }
     let reserved = isReservedPaletteChord(binding)        // see Risk 4
     guard !reserved else { pendingConflictAlert = makeReservedChordAlert(for: id); return }
     switch HotkeyBindingEditor.capture(binding, for: id, settings: wmController.settings) {
     case .applied:
         wmController.updateHotkeyBindings(wmController.settings.hotkeyBindings)
         commandItems = buildCommandItems(from: wmController)   // refresh badges
         finishRecording()
     case let .conflict(alert):
         pendingConflictAlert = alert
     }
     ```
     Use the `KeyBinding` overload (`HotkeySettingsView.swift:22-28`); do not
     hand-build `HotkeyTrigger` (Decision 1).
   - **`clearSelectedCommandBinding()`.** New private method: for the selected
     id, `wmController.settings.clearBinding(for: id)` (`SettingsStore.swift:598`)
     → `wmController.updateHotkeyBindings(...)` → rebuild `commandItems`. No
     conflict possible on clear; no alert.
   - **`finishRecording()` / `cancelRecording()`.** Both set
     `recordingCommandId = nil` and re-`focusSearchField()` (`:1001`) so the
     search field regains focus (the recorder took it via
     `window.makeFirstResponder(self)` at `KeyRecorderView.swift:121`).
   - **`pendingConflictAlert`.** New `@Published var pendingConflictAlert: ConflictAlert?`
     driving a modal sheet over the panel (see below). Cleared on
     dismiss/resolve/cancel.
   - **Conflict sheet.** Present `pendingConflictAlert.message`
     (`HotkeySettingsView.swift:609-617`: *"This key combination is already used
     by \"X\". Do you want to replace it?"*) as a modal sheet over
     `CommandPalettePanel` (`:144`), mirroring how destructive confirmations are
     surfaced via `DestructiveConfirmationAlert.confirm(...)` in
     `performSelectionAction` (`:878`). "Replace" calls
     `HotkeyBindingEditor.applyConflictResolution(alert, settings:)`
     (`HotkeySettingsView.swift:72`) → `updateHotkeyBindings` → rebuild
     `commandItems` → `finishRecording()`; "Cancel" clears the alert and returns
     to recording (or to the selected row — see implementation step 4).
   - **Reserved-chord guard.** Add `isReservedPaletteChord(_:) -> Bool`
     rejecting bare `⌘1`/`⌘2`/`⌘3`, `Esc`, `↑`/`↓`, `↩`/⇧↩, and `Tab` — the
     palette's own navigation chords — so a recorded binding cannot shadow
     in-palette navigation (Risk 4). On a reserved chord, show a notice (reuse
     `HotkeyNoticeAlert`, `HotkeySettingsView.swift:623`, or a palette-local
     equivalent) and stay in recording.
4. `Sources/Nehir/UI/KeyRecorderView.swift`
   - **No change under Strategy A.** Reused as-is. (Under the Strategy B
     fallback only: extract `KeyRecorderNSView.binding(from:)` (`:156`),
     `carbonModifiersFromNSEvent`, and `isSpecialKey` into a shared static, e.g.
     `KeyCapture.binding(from:allowsBareKeys:)`, so the palette's own monitor can
     interpret events. Do not attempt unless the Strategy-A spike fails — see
     Risks.)
5. Tests under `Tests/NehirTests/` (see Tests section).

### Non-goals

- Do **not** change the WM engine, hotkey registration (`Hotkeys.swift`), the
  Carbon hotkey path, `hotkeys.toml` schema, or `HotkeysTOMLCodec`.
- Do **not** add a new `HotkeyCommand`, `ActionSpec`, config key, or IPC command.
  This is a second entry point into the existing binding pipeline, not a new
  capability.
- Do **not** allow assigning numbered-group bindings (`switchWorkspace.N`,
  `focusColumn.N`, `moveToWorkspace.N`, `moveColumnToWorkspace.N`,
  `focusWorkspaceAnywhere.N`, `moveColumnToIndex.N`, `focusWindowInColumn.N`)
  from the palette in v1 — those are edited as a 1–9 pattern in the Hotkeys tab
  (`HotkeyConfigMapping.swift:17-46`). Render their palette rows read-only (no
  assign/clear affordance). This also sidesteps backlog #22's `{N}`-template
  rework.
- Do **not** offer "Reset to default" from the palette (Decision 5); it stays in
  the Hotkeys tab.
- Do **not** persist a half-started recording across palette reopens; `dismiss`
  clears `recordingCommandId` (Discovery Open Question 6).
- Do **not** change the palette's global-summon hotkey or its conflict
  diagnostics — that is `completed/20260619-nehir-48-command-palette-hotkey-conflict.md`.
- Do **not** implement Strategy B unless the Strategy-A responder spike fails.
- Do **not** add mouse right-click / context-menu entry in this task (backlog
  #18 covers the action-bar surface; a palette-row context menu is a possible
  follow-up).

## Exact implementation plan

### Phase 1 — Shared numbered-group predicate (unblocks palette gating)

1. In `HotkeyConfigMapping.swift` (`:17-46`), add
   `static func isNumberedGroupMember(_ bindingId: String) -> Bool` that scans
   `numberedGroups` and `(0..<9)` against `internalIdPattern` exactly as the
   private `HotkeySettingsView.isNumberedGroupMember` does
   (`HotkeySettingsView.swift:520-526`).
2. In `HotkeySettingsView.swift`, replace the private helper body (`:520-526`)
   with `HotkeyConfigMapping.isNumberedGroupMember(bindingId)`. Add/adjust a
   unit test if one exists for the private helper; otherwise rely on the new
   shared tests below.

### Phase 2 — Controller recording state + dismiss cleanup

3. Add `@Published private(set) var recordingCommandId: String?` and
   `@Published var pendingConflictAlert: ConflictAlert?` to
   `CommandPaletteController`.
4. In `dismiss(reason:)` (`:773`), reset both to `nil` with the other transient
   fields.
5. Add `finishRecording()` and `cancelRecording()` private helpers: both nil out
   `recordingCommandId`; both call `focusSearchField()` (`:1001`).

### Phase 3 — Entry chord + early-return guard

6. At the top of `handleKeyDown(_:)` (`:705`), add
   `if recordingCommandId != nil { return false }` (pass-through to the
   recorder).
7. In the `default:` branch of `handleKeyDown`, before the
   `Self.selectionTrigger(...)` lookup (`:738`), handle keyCode `48` (`Tab`)
   when `selectedMode == .commands` and an item is selected:
   - If `HotkeyConfigMapping.isNumberedGroupMember(selectedId)` → no-op (read-only).
   - Else if the selected item is assigned → `clearSelectedCommandBinding()`.
   - Else → `recordingCommandId = selectedId`.
   Bare `Tab` only (guard `relevantModifiers.isEmpty`). Do not consume `Tab`
   outside `.commands` mode.

### Phase 4 — Capture, apply, clear, conflict UX

8. Add `commitRecording(_ binding: KeyBinding)` as specified in Scope step 3.
   Use `HotkeyBindingEditor.capture(_:for:settings:)` (the `KeyBinding` overload,
   `HotkeySettingsView.swift:22-28`).
9. Add `clearSelectedCommandBinding()` (Scope step 3): clear → re-register →
   rebuild `commandItems` → `finishRecording()`.
10. Add `isReservedPaletteChord(_:) -> Bool` and wire it as the first check in
    `commitRecording` (Scope step 3, Risk 4).
11. Present `pendingConflictAlert` as a modal sheet in the SwiftUI body:
    - "Replace" → `HotkeyBindingEditor.applyConflictResolution(alert, settings:)`
      (`:72`) → `updateHotkeyBindings` → rebuild → `finishRecording()`.
    - "Cancel" → clear alert; return focus to search field but keep the same
      command selected (do not auto-re-enter recording).

### Phase 5 — Inline hint + footer text + recorder widget

12. Add `selectedCommandHint(isAssigned: Bool) -> InlineHint?` (Scope step 3),
    render it on the selected command row (mirror `summonHint` in
    `CommandPaletteWindowRow`, `:1410-1417`).
13. Branch `statusText` (`:1180`) on `recordingCommandId != nil` to show the
    recording prompt; otherwise keep existing per-mode text.
14. In the footer render site (`:1090`), swap the status `Text` for an embedded
    `KeyRecorderView` when recording (Scope step 3). Confirm the recorder
    becomes first responder inside `CommandPalettePanel` (`:144`,
    `canBecomeKey == true`) — this is the Strategy-A spike (Risk 1).

### Phase 6 — Strategy-A spike decision point

15. Manually verify (or add a focused test) that inside the borderless panel the
    embedded `KeyRecorderView` reliably takes first responder and receives the
    chord before the search field steals focus back. If it does **not**, switch
    to Strategy B: extract `KeyRecorderNSView.binding(from:)` (`:156`) +
    `carbonModifiersFromNSEvent` + `isSpecialKey` into `KeyCapture.binding(from:allowsBareKeys:)`,
    drop the embedded `KeyRecorderView`, and reinterpret keys inside the
    palette's own monitor (the `recordingCommandId != nil` branch of
    `handleKeyDown` instead of the early-return guard). Do not implement both.

## Tests

All tests are added to `Tests/NehirTests/CommandPaletteControllerTests.swift`
unless noted. The harness already builds a real
`WMController(settings: SettingsStore(defaults: makeCommandPaletteTestDefaults()))`
(`:20`) and drives `controller.toggle(wmController:)` / `.show(wmController:)`.

- **`assignBindingFromPaletteAppliesFreeChord`** — switch to `.commands`,
  select an unassigned singleton action (e.g. `rescueOffscreenWindows`,
  `ActionCatalog.swift:686`), call the new test-friendly
  `commitRecordingForTests(_:)` (thin wrapper over `commitRecording`) with a
  chord no other action uses; assert `wmController.settings.hotkeyBindings`
  now maps that id to the chord, the rebuilt item's `bindingDisplay` is
  non-nil and equals the chord, and `recordingCommandId` is `nil`.
- **`assignBindingFromPaletteSurfacesConflictAndDoesNotMutate`** — assign a
  chord already used by another action; assert `pendingConflictAlert` is
  set, its `conflictingCommands` names the loser, and `hotkeyBindings` is
  unchanged. Then drive "Replace" and assert the loser became `.unassigned`
  and the selected id took the chord.
- **`clearBindingFromPaletteRevertsToUnassigned`** — assign then clear; assert
  the binding reverted to `.unassigned` and `bindingDisplay` is `nil`.
- **`numberedGroupRowsAreNotAssignableFromPalette`** — select a numbered-group
  member (e.g. `switchWorkspace.1`); assert `Tab` does not enter recording
  (`recordingCommandId` stays `nil`) and the row shows no assign hint.
- **`reservedPaletteChordIsRejectedDuringRecording`** — while recording,
  capture `⌘3` (a mode shortcut); assert it is rejected, `hotkeyBindings`
  unchanged, and recording continues (or a reserved-chord notice is shown).
- **`dismissClearsRecordingState`** — enter recording, then
  `dismiss(reason: .cancel)`; assert `recordingCommandId == nil` and
  `pendingConflictAlert == nil`. Re-show and assert the palette does not
  start in recording mode.
- **`paletteStaysOpenAfterAssign`** — after `commitRecording` succeeds, assert
  `controller.isVisible` is still true and the same command remains selected.
- **`HotkeyConfigMappingTests.isNumberedGroupMemberSharedHelper`** (in the
  existing config test file, or a new one) — assert the shared helper returns
  `true` for `switchWorkspace.1`/`focusColumn.9` and `false` for
  `rescueOffscreenWindows`/`focusMonitorNext`.
- **No-regression:** existing `selectionTriggerHandlesReturnAndKeypadEnter`
  (`CommandPaletteControllerTests.swift:508`), `selectedWindowHint…` (`:489`),
  and the `HotkeyBindingEditor.capture` Hotkeys-tab tests stay green (the
  shared pipeline is untouched).

The record/capture widget (`KeyRecorderView`) needs no new tests under Strategy
A — it is unmodified.

## Validation

```bash
swift build
swift test --filter CommandPaletteControllerTests
swift test --filter HotkeyConfigMapping
swift test --filter HotkeySettingsViewTests      # if present; else the config round-trip suite
# Manual:
#   1. Open the palette (Option+Cmd+Space), switch to Commands (⌘3).
#   2. Select an unassigned action (e.g. "Rescue Off-Screen Floating Windows"),
#      press Tab → footer becomes a recorder; press a free chord → badge appears
#      on the row, palette stays open.
#   3. Select an assigned action, press Tab → binding clears.
#   4. Record a chord already used by another action → conflict sheet; Replace
#      swaps, Cancel returns to the row.
#   5. Select a numbered-group row (e.g. "Switch to Workspace 1") → no assign
#      hint, Tab does nothing.
#   6. Record ⌘3 while recording → rejected as a reserved chord.
```

Changeset (minor): "Assign, reassign, or clear a command's hotkey from the
command palette (Commands mode)."

## Risks and mitigations

1. **Two local `.keyDown` monitors (Strategy A).** The palette's
   `installEventMonitor` (`CommandPaletteController.swift:690`) and
   `KeyRecorderNSView.localEventMonitor` (`KeyRecorderView.swift:107`) both match
   `.keyDown`; the first to return `nil` consumes. **Mitigation:** the
   `recordingCommandId != nil` early-return at the top of `handleKeyDown`
   (`:705`) makes the palette's monitor pass-through while recording, and the
   recorder takes first responder (`KeyRecorderView.swift:121`). **Fallback:** if
   first-responder transfer is unreliable inside the borderless
   `CommandPalettePanel` (`:144`), switch to Strategy B (no second monitor) —
   Phase 6 is the decision point.
2. **First-responder tug-of-war with the search field.** The palette focuses the
   search field on show (`focusSearchField` via `DispatchQueue.main.async` at
   `:298`). **Mitigation:** `finishRecording()`/`cancelRecording()` re-call
   `focusSearchField()` (`:1001`) so the next keystroke goes to search, not
   nowhere.
3. **Global monitor / Input Monitoring prompt.** `KeyRecorderNSView` installs a
   global `.keyDown` monitor (`KeyRecorderView.swift:113`). Nehir already
   requires Accessibility and typically Input Monitoring for window management,
   so this is very likely a non-issue. **Mitigation:** if a fresh-install prompt
   appears, switch to Strategy B (no global monitor). Confirm Nehir already
   holds Input Monitoring in normal operation before shipping.
4. **Recording a palette-reserved chord.** `⌘1`/`⌘2`/`⌘3`, `Esc`, `↑`/`↓`,
   `↩`/`⇧↩`, and `Tab` are the palette's own navigation keys.
   `KeyRecorderNSView.binding(from:)` (`:156`) already rejects bare
   non-function keys (`allowsBareKeys == false`), so bare arrows/Enter/Tab are
   dropped; but `⌘1` etc. would be accepted and then both recorded *and*
   trigger a mode switch. `findConflicts` catches conflicts with other Nehir
   commands, not with palette-internal chords. **Mitigation:** the
   `isReservedPaletteChord` guard in `commitRecording` rejects these before
   `HotkeyBindingEditor.capture`; a notice tells the user to pick another chord.
5. **Numbered-group isolation.** Assigning one `switchWorkspace.N` slot in
   isolation via `updateTrigger` would diverge from the 1–9 pattern model and
   produce a `hotkeys.toml` that no longer round-trips through the group
   editor. **Mitigation:** v1 gates numbered-group rows as read-only via the
   shared `HotkeyConfigMapping.isNumberedGroupMember` predicate (Decision 3).
6. **Discoverability.** A chord alone is invisible to mouse-first users.
   **Mitigation:** the selected-row `InlineHint` + the footer status text cover
   keyboard users; a per-row glyph for mouse users is an explicit follow-up, not
   v1.
7. **Conflict-sheet vs. palette dismissal ordering.** Presenting a modal sheet
   over the panel must not trigger `panelDidResignKey` → `dismiss`. **Mitigation:**
   mirror the existing `DestructiveConfirmationAlert` sheet path
   (`performSelectionAction`, `:878`), which already runs over the panel without
   dismissing it.

## Follow-ups (out of scope)

- `⌘K` as a redundant alias for the `Tab` assign chord (Decision 4 / Open
  Question 1), if discoverability testing asks for it.
- "Reset to default" from the palette (Decision 5 / Open Question 2).
- Mouse-first entry: a per-row record glyph or right-click context menu on a
  palette command row ( overlaps backlog #18's action-bar surface).
- Lifting the numbered-group read-only restriction once backlog #22
  (`{N}`-template rework) lands, so pattern bindings can be edited coherently
  from the palette.
- Coordination with backlog #4 (cross-source search) and #11 (fuzzy search):
  those change *how/where* matches are found and are orthogonal to *rebinding*
  the selected match, but they may want to claim chords — keep `Tab` for assign
  and leave `⌘K`/`⌘L`/etc. available for them. Update (2026-06-22): #4 shipped
  (commit `1aa518bc`) without claiming any chord, so this coordination now
  applies only to #11 (fuzzy search).
