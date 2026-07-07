# OmniWM #226 — Chrome extension hotkey priority

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned
**Source discovery:** `discovery/20260616-omniwm-226-chrome-extension-hotkey-priority.md`
**Upstream reference:** <https://github.com/BarutSRB/OmniWM/issues/226> (closed `not_planned`; nehir picks it up)
**Related shipped work:** `completed/20260619-nehir-48-command-palette-hotkey-conflict.md` (Diagnostics for Carbon-registration conflicts + curated co-fire advisories — explicitly scoped #226 *out*)

All source references were re-verified against the main Nehir source tree on
2026-06-21. Re-verify before editing; line numbers drift.

## TL;DR

nehir registers every command hotkey through Carbon `RegisterEventHotKey`
(`Sources/Nehir/Core/Input/Hotkeys.swift:134`). That layer has no way to preempt
a focused app — or a Chrome extension shortcut — that claims the same chord:
when the focused app wins, the Nehir command simply never dispatches and there
is no suppression layer anywhere in the runtime keyboard path. (The only
`CGEvent.tapCreate` sites in Nehir are mouse/gesture: `MouseEventHandler.swift:284`,
`MouseWarpHandler.swift:92`, `InteractiveMoveDemo.swift:877`. The only global
keyboard monitor is the settings key recorder, `KeyRecorderView.swift:113`, not
the runtime dispatcher.)

This plan adds an **opt-in priority hotkey backend** that installs a keyboard
`CGEvent.tapCreate` at `.cghidEventTap` with `.defaultTap`, matches incoming
`keyDown` events against the registered Nehir bindings, and on a match returns
`nil` (suppressing the event before either Carbon's hot-key manager or the
focused app sees it) and dispatches the Nehir command itself. It is gated behind
a new `hotkeyPriorityMode` setting (default **off** → today's Carbon behavior is
unchanged), carries a small per-app exclusion list so users can carve out apps
that must win (remote-desktop/VM, specific Chrome profiles), and degrades
gracefully to Carbon when Input Monitoring permission is not granted. This is
the direction the discovery recommends ("design a priority hotkey backend") while
honoring its hard warning: **do not** add unconditional HID-tap suppression —
make it mode-switched with an explicit per-app escape hatch.

## Discovery corrections / decisions

The discovery's product recommendation holds; the line numbers and one tap-site
claim drifted. Corrections adopted in this plan (all re-verified on 2026-06-21):

1. **Tap-site count.** The discovery lists four `CGEvent.tapCreate` call sites
   (`MouseEventHandler.swift:253`/`:285`, `MouseWarpHandler.swift:86`,
   `InteractiveMoveDemo.swift:725`). Main has **three**, and `MouseEventHandler`
   has only one tap (`state.eventTap`), not two — there is no separate
   `gestureTap` there. Correct sites:
   `MouseEventHandler.swift:284` (`eventTap`, `.cgSessionEventTap`, `.defaultTap`),
   `MouseWarpHandler.swift:92` (`eventTap`),
   `InteractiveMoveDemo.swift:877` (`gestureTap`). None are keyboard.
2. **Hotkeys.swift drift.** Discovery → actual: `import Carbon` `:1`→`:8`;
   `HotkeyRegistrationFailureReason` `:24`→`:30`; `start()` `:60`→`:66`;
   `InstallEventHandler` `:84`→`:90`; `registerHotkeys()` `:116`→`:122`;
   `RegisterEventHotKey` `:128`→`:134`; `markSystemReservedFailure` call `:140`→`:146`
   and def `:153`→`:161`; `registrationPlan(for:)` `:170`→`:178`; duplicate-binding
   detection `:197`→`:205`/`:207`.
3. **WMController.swift drift.** `hotkeys.onCommand` `:227`→`:304`;
   `updateHotkeyBindings`/`setHotkeysEnabled` calls `:276`→`:353`/`:354`;
   `reconcileEnabledAndHotkeysState()` `:371`→`:448`; `hotkeys.start/stop` `:371`→`:457`;
   `hotkeyRegistrationFailures` (cited via the #48 doc as `:806`)→`:881`.
4. **ActionCatalog.swift drift.** `move.right` `:384`→`:390` (`id: "move.right"`
   is at `:390`, the `action(` opener is a few lines above); `openCommandPalette`
   `:667`→`:672`.
5. **CommandHandler.swift drift.** `handleHotkeyCommand` `:17`→`:23`;
   `performCommand` `:47`; `case let .move(direction)` `:48`→`:59`.
6. **KeyRecorderView.swift drift.** Local monitor `:107`, global monitor `:113`
   (discovery cited `:97`/`:107`).
7. **HotkeySettingsView.swift drift.** The "may be reserved by the system" string
   is at `:746` (discovery cited `:716`); `HotkeyBindingRow` is at `:686`,
   `failureMessage(for:)` at `:741`.
8. **Decision — keep Carbon as the default, gate the new backend.** The discovery
   floats "replace Carbon" but also warns against unconditional suppression. This
   plan makes the event-tap backend an **opt-in mode** (`hotkeyPriorityMode`),
   leaving Carbon (and the #48 Diagnostics that depend on
   `registrationFailures`) intact for everyone who does not opt in.
9. **Decision — in priority mode, do not call `RegisterEventHotKey`.** Run
   `registrationPlan(for:)` (keeps `.duplicateBinding` detection and the failure
   map populated for Diagnostics) but skip the Carbon register call, so the HID
   tap is the sole dispatcher and there is no double-dispatch window. Tradeoff:
   priority mode cannot observe Carbon `eventHotKeyExistsErr` conflicts —
   acceptable for an opt-in feature, covered for known defaults by the #48
   advisory catalog.

## Scope

### Files to add/change

1. **`Sources/Nehir/Core/Input/HotkeyPriorityPolicy.swift`** (new)
   - Pure value type. Decides, given a matched chord + the frontmost app's bundle
     id + the user's exclusion list, whether Nehir should `.consume` or
     `.passThrough`. No AppKit/CGEvent imports in the decision core (takes a
     `String` bundle id), so it is unit-testable without a live tap.
   ```swift
   enum HotkeyDispatchDecision: Equatable { case consume, passThrough }

   enum HotkeyPriorityPolicy {
       static func decide(
           frontmostBundleID: String?,
           excludedBundleIDs: Set<String>
       ) -> HotkeyDispatchDecision
   }
   ```
   Rule: `.passThrough` iff `frontmostBundleID` is non-nil and is in
   `excludedBundleIDs`; otherwise `.consume`. (Default-on-consume is the whole
   point of priority mode — Nehir wins everywhere except where the user opts an
   app out.)

2. **`Sources/Nehir/Core/Input/HotkeyEventTap.swift`** (new)
   - Owns the keyboard `CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
     options: .defaultTap, eventsOfInterest: mask, callback:userInfo:)`, where
     `mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)`.
   - Holds the `CFMachPort?`, the `CFRunLoopSource?`, a `[KeyBinding: HotkeyCommand]`
     match table (rebuilt from `registrationPlan(for:)` output), the current
     `HotkeyPriorityPolicy` inputs, and an `onCommand: ((HotkeyCommand) -> Void)?`.
   - The callback:
     1. Reads `event.getIntegerValueField(.keyboardEventAutorepeat)`; if non-zero,
        return the event **unchanged** (never consume auto-repeat).
     2. On `.flagsChanged`, return the event unchanged (only `keyDown` matches).
     3. On `.keyDown`, derive `(keyCode, modifiers)` via
        `event.getIntegerValueField(.keyboardEventKeycode)` and
        `event.flags → Carbon modifier mask` (reuse `KeyBinding`'s `(keyCode,
        modifiers)` shape from `HotkeyBinding.swift:10`); look up the match table.
     4. If no match, return the event unchanged.
     5. If match, resolve `frontmostBundleID` (`NSWorkspace.shared.frontmostApplication?.bundleIdentifier`),
        call `HotkeyPriorityPolicy.decide(...)`; on `.passThrough` return the event
        unchanged, on `.consume` dispatch `onCommand?(command)` on the main actor
        and `return nil`.
   - Mirrors `MouseEventHandler.swift:284`–`:298` for run-loop plumbing
     (`CFMachPortCreateRunLoopSource` + `CFRunLoopAddSource(..., .commonModes)` +
     `CGEvent.tapEnable(tap:enable:)`) and for teardown
     (`CGEvent.tapEnable(tap:enable:false)`, `CFRunLoopRemoveSource`,
     `CFMachPortInvalidate`).
   - `start()` returns a `Bool` success: if `CGEvent.tapCreate` returns `nil`
     (Input Monitoring not granted), return `false` so the caller can fall back.

3. **`Sources/Nehir/Core/Input/Hotkeys.swift`** (change)
   - Add `enum HotkeyDispatchMode { case carbon, priority }` and a
     `var mode: HotkeyDispatchMode = .carbon` on `HotkeyCenter` (default `.carbon`
     preserves today's behavior byte-for-byte).
   - Split `registerHotkeys()` (`:122`):
     - **Always** run `Self.registrationPlan(for:)` and store
       `registrationFailures` (keeps `.duplicateBinding` detection and the
       `WMController.hotkeyRegistrationFailures` surface at `:881` working in
       both modes).
     - In `.carbon`: call `RegisterEventHotKey` (`:134`) as today.
     - In `.priority`: skip `RegisterEventHotKey`; instead rebuild the
       `HotkeyEventTap` match table from the plan's registrations and (re)start
       the tap.
   - Extend `start()` (`:66`) / `stop()` (`:95`) to start/stop whichever backend
     the current `mode` selects. `updateBindings(_:force:)` (`:107`) must refresh
     both the Carbon registrations and the event-tap match table.
   - Add `var lastBackendStartFailed: Bool` (set when priority mode's
     `tapCreate` returned `nil`) for Diagnostics.

4. **`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`** (change)
   - Add to `General` (alongside `hotkeysEnabled` at `:38`):
     `var hotkeyPriorityMode: String  // "carbon" | "priority", default "carbon"`
     and `var hotkeyPriorityExcludedBundleIDs: [String]`.
   - Mirror into the `Settings` construction (`:252`, `:371`) with defaults
     `hotkeyPriorityMode: "carbon"`, `hotkeyPriorityExcludedBundleIDs: []`.

5. **`Sources/Nehir/Core/Config/SettingsExport.swift`** (change)
   - Add `var hotkeyPriorityMode: String` and
     `var hotkeyPriorityExcludedBundleIDs: [String]` next to `hotkeysEnabled`
     (`:20`) and `hotkeyBindings` (`:50`), defaulting to `"carbon"` / `[]`
     (`:111`-area defaults).

6. **`Sources/Nehir/Core/Config/HotkeyConfigMapping.swift`** (change)
   - Map the two new TOML keys under `[general]`:
     `hotkeyPriorityMode` ↔ `settings.hotkeyPriorityMode`,
     `hotkeyPriorityExcludedBundleIDs` ↔ `settings.hotkeyPriorityExcludedBundleIDs`.
   - Verify load→export round-trip and that the keys are accepted (not flagged as
     unknown by `detectUnknownKeys`, per
     `completed/20260616-unified-config-diagnostics-and-migration-policy.md`).

7. **`Sources/Nehir/Core/Controller/WMController.swift`** (change)
   - In `reconcileEnabledAndHotkeysState()` (`:448`): before
     `hotkeys.start()`/`hotkeys.stop()` (`:457`), set
     `hotkeys.mode = settings.hotkeyPriorityMode == "priority" ? .priority : .carbon`
     and push the exclusion list. If priority mode was requested but
     `hotkeys.lastBackendStartFailed` is true after `start()`, leave
     `hotkeys.mode` reported as `.carbon` for Diagnostics and do **not** crash —
     the user simply gets today's behavior with a diagnostic row.
   - Expose `var hotkeyDispatchMode: HotkeyDispatchMode { hotkeys.mode }` and
     `var hotkeyPriorityBackendAvailable: Bool { !hotkeys.lastBackendStartFailed }`
     near `hotkeyRegistrationFailures` (`:881`) for UI/Diagnostics.

8. **`Sources/Nehir/UI/HotkeySettingsView.swift`** (change)
   - Add a "Priority mode" section (near the existing failure-hint surface,
     `HotkeyBindingRow` at `:686`, `failureMessage(for:)` at `:741`):
     - A toggle bound to `hotkeyPriorityMode == "priority"`.
     - Explanatory copy: *"Priority mode intercepts shortcuts before the focused
       app, so a Nehir command wins even when an app or browser extension claims
       the same chord. Requires Input Monitoring permission. Standard mode is
       recommended unless an app is swallowing your shortcuts."*
     - A `TextEditor`/list for `hotkeyPriorityExcludedBundleIDs` (bundle ids,
       one per line) with helper copy: *"Apps here keep their shortcuts even in
       priority mode (e.g. remote-desktop or VM apps)."*
   - When `controller.hotkeyPriorityBackendAvailable == false` and priority mode
     is on, show an inline warning: *"Priority mode needs Input Monitoring
       permission (System Settings → Privacy & Security). Nehir is using standard
       mode until granted."*

### Non-goals

- Do **not** remove or change the Carbon default. Priority mode is opt-in.
- Do **not** suppress unconditionally — the backend is mode-gated and carries an
  explicit per-app exclusion list.
- Do **not** add per-binding granularity (one global mode + one exclusion list,
  not a per-chord priority flag).
- Do **not** change `KeyRecorderView` (`Sources/Nehir/UI/KeyRecorderView.swift`)
  — settings capture stays exactly as-is.
- Do **not** touch the mouse/gesture event taps
  (`MouseEventHandler.swift:284`, `MouseWarpHandler.swift:92`,
  `InteractiveMoveDemo.swift:877`).
- Do **not** remap chords, change keyboard-layout/non-Latin handling, or alter
  `CommandHandler` dispatch (`:23`/`:47`).
- Do **not** attempt active liveness probing (register + synthesize + observe).
- Do **not** extend the `HotkeyAdvisoryCatalog` from #48 with Chrome-extension
  specifics — that catalog is for *system* co-fires; #226's fix is the backend,
  not more advisories.

## Exact implementation plan

### Phase 1 — Pure policy + matcher (no live tap, fully testable)

1. Create `Sources/Nehir/Core/Input/HotkeyPriorityPolicy.swift` with the
   `decide(frontmostBundleID:excludedBundleIDs:)` rule above.
2. Add a pure chord-matcher helper (can live in `HotkeyEventTap.swift` as a
   `static func match(keyCode:modifiers:in:) -> HotkeyCommand?` that takes the
   `[KeyBinding: HotkeyCommand]` table). This is testable without `CGEvent`.
3. Write `Tests/NehirTests/HotkeyPriorityPolicyTests.swift` (see Tests).

### Phase 2 — Event-tap backend

1. Create `Sources/Nehir/Core/Input/HotkeyEventTap.swift` with `start() -> Bool`,
   `stop()`, `updateMatchTable(_:)`, and the callback above. Mirror the
   run-loop/teardown pattern verbatim from `MouseEventHandler.swift:284`–`:316`.
2. Handle auto-repeat (`keyboardEventAutorepeat`) and `.flagsChanged` as
   no-consume.
3. Return `false` from `start()` when `CGEvent.tapCreate` returns `nil`.

### Phase 3 — Wire the mode into `HotkeyCenter`

1. Add `HotkeyDispatchMode` and the `mode`/`lastBackendStartFailed` fields.
2. Split `registerHotkeys()` (`:122`) into always-plan + mode-conditional
   register (Carbon) vs. tap-rebuild (priority).
3. Extend `start()`/`stop()`/`updateBindings(_:force:)` to drive the selected
   backend.

### Phase 4 — Settings + config round-trip

1. Add the two fields to `CanonicalTOMLConfig.swift` (`:38`-area and the two
   `Settings` builders at `:252`/`:371`), `SettingsExport.swift` (`:20`/`:50`),
   and the mapping in `HotkeyConfigMapping.swift`.
2. Add a round-trip test asserting `priority` + a non-empty exclusion list
   survives export→load and that `unknownKeys` does not flag the new keys.

### Phase 5 — Controller wiring + UI

1. In `WMController.reconcileEnabledAndHotkeysState()` (`:448`), set
   `hotkeys.mode` and push the exclusion list before `:457`.
2. Expose `hotkeyDispatchMode` / `hotkeyPriorityBackendAvailable`
   (near `:881`).
3. Add the Hotkey settings section in `HotkeySettingsView.swift` (toggle +
   exclusion list + permission warning).

### Phase 6 — Diagnostics hook (optional, low-risk)

Surface `hotkeyPriorityBackendAvailable == false` as a `HotkeyAdvisoryIssue`
(reusing the #48 shape from `SettingsDiagnosticsIssue.swift`) so the Diagnostics
hub + sidebar badge warn when priority mode was requested but fell back. This is
additive; skip if it risks scope creep.

## Tests

### `Tests/NehirTests/HotkeyPriorityPolicyTests.swift` (new)

1. `consumeWhenFrontmostAppNotExcluded` — bundle `"com.apple.TextEdit"`, exclusion
   `{}` → `.consume`.
2. `consumeWhenFrontmostAppIsNil` — `nil` bundle, any exclusion → `.consume`
   (never block on unknown frontmost).
3. `passThroughWhenFrontmostAppExcluded` — bundle `"com.google.Chrome"`,
   exclusion `{"com.google.Chrome"}` → `.passThrough`.
4. `exclusionIsExactBundleIDMatch` — `"com.google.Chrome"` vs exclusion
   `{"chrome"}` → `.consume` (no substring matching).

### `Tests/NehirTests/HotkeyEventTapMatcherTests.swift` (new, pure — no live tap)

1. `matchReturnsCommandForRegisteredChord` — table with `Option+Shift+L → .move(.right)`
   (the issue's reproduction chord, mirroring the `move.right` default at
   `ActionCatalog.swift:390`), query with the same `(keyCode, modifiers)` → that
   command.
2. `matchReturnsNilForUnregisteredChord` — same table, query `Cmd+Q` → nil.
3. `matchIsExactModifierSensitive` — `Option+Shift+L` vs `Shift+L` → nil for the
   latter.
4. `autoRepeatNeverMatches` — the matcher's pre-filter rejects events flagged
   autorepeat (feed the predicate a synthetic "isAutorepeat=true" input).
5. `unassignedBindingsAreIgnored` — table built from a plan containing an
   `.unassigned` binding (`HotkeyBinding.swift:76`) never matches.

### `Tests/NehirTests/HotkeyConfigMappingTests.swift` (extend)

- `hotkeyPriorityModeRoundTripsPriority` — set `"priority"` + exclusion list,
  export, reload, assert equality.
- `hotkeyPriorityModeDefaultsToCarbon` — absent keys → `"carbon"` / `[]`.
- `unknownKeysDoesNotFlagNewHotkeyPriorityKeys` — regression against the
  unified-diagnostics policy.

### `HotkeyCenter` regression

- Existing Carbon-path tests stay green with `mode == .carbon` (the default). Add
  one test asserting `mode == .priority` does **not** call `RegisterEventHotKey`
  (inject a spy or assert via the `refs`/`idToAction` state staying empty while
  the match table is populated).

Manual regression (cannot be automated without HID permission + a real second
app): bind `move.right` to `Option+Shift+L`, install a Chrome extension using the
same chord (e.g. Loom), enable priority mode, focus Chrome, press the chord →
Nehir moves the window and the extension does **not** fire. Add Chrome's bundle
id to the exclusion list → extension fires and Nehir does not. Disable priority
mode → today's behavior (extension wins).

## Validation

```bash
swift build
swift test --filter HotkeyPriorityPolicy
swift test --filter HotkeyEventTapMatcher
swift test --filter HotkeyConfigMapping
swift test --filter HotkeyConflictDiagnostics   # #48 suite still green
swift test --filter Hotkeys                      # carbon-path regression
```

Manual:

1. `mise run …` (or the project's run target) with `hotkeyPriorityMode = "priority"`.
2. On first launch, grant **Input Monitoring** to Nehir (System Settings →
   Privacy & Security). Confirm `hotkeyPriorityBackendAvailable == true` (no
   fallback warning in Hotkey settings).
3. Reproduce the issue: Nehir command + Chrome extension on `Option+Shift+L`,
   focus Chrome, press → Nehir wins.
4. Add `com.google.Chrome` to the exclusion list → Chrome wins.
5. Deny Input Monitoring, relaunch → priority mode falls back to Carbon, the
   permission warning appears, and no hotkeys are lost.

Changeset (minor; confirm release policy): "Add an opt-in priority hotkey
backend (keyboard event tap) so Nehir commands win over focused-app and browser
extension shortcuts (OmniWM #226)."

## Risks and mitigations

- **Input Monitoring permission required.** `CGEvent.tapCreate(.cghidEventTap,
  .defaultTap)` returns `nil` without it. Mitigation: `start()` returns `Bool`;
  on failure, fall back to Carbon for the session and surface a Diagnostics
  advisory + inline Hotkey-settings warning. Never leave the user without
  hotkeys.
- **Double dispatch / ordering.** In priority mode we skip
  `RegisterEventHotKey`, so only the HID tap dispatches; no double-fire window.
  The HID tap at `.cghidEventTap` is the earliest user-space interception point,
  so returning `nil` suppresses before both Carbon's hot-key manager and the
  focused app. Validate the ordering claim manually during Phase 5.
- **Auto-repeat storms.** A held chord would re-fire the command every repeat.
  Mitigation: explicitly pass through events with `keyboardEventAutorepeat != 0`.
- **Over-suppression / user lockout.** Unconditional suppression would make
  legitimate app/extension shortcuts impossible. Mitigation: the feature is
  off-by-default and carries a per-app exclusion list; default-on-consume is the
  product intent (the bug report wants Nehir to win), with the exclusion list as
  the escape hatch the upstream maintainer asked about.
- **Frontmost-app resolution on the tap thread.** `NSWorkspace.frontmostApplication`
  is main-actor-ish; read it carefully (the callback runs on the tap's run-loop
  source, which we add to `CFRunLoopGetMain()`). Cache the frontmost bundle id
  on `.flagsChanged` if profiling shows cost; do not block the tap thread.
- **Loss of Carbon-conflict detection in priority mode.** Without
  `RegisterEventHotKey` we cannot see `eventHotKeyExistsErr`. Acceptable for an
  opt-in mode; known system co-fires are still covered by the #48 advisory
  catalog. Document in the settings copy.
- **Key layout / non-Latin chords.** Matching on `(keyCode, modifiers)` (hardware
  key code, not character) is layout-independent and matches how Carbon already
  keys bindings (`Hotkeys.swift:134` uses `registration.binding.keyCode`). No new
  layout handling is introduced.
- **Config round-trip / unknown-keys.** New keys must be registered in
  `HotkeyConfigMapping` or `detectUnknownKeys` will flag them on existing user
  configs after upgrade. Covered by the round-trip test.

## Follow-ups (out of scope)

- Per-binding priority flags (each chord individually set to Nehir-wins /
  app-wins) — deferred until the global mode + exclusion list proves
  insufficient.
- A "priority mode recommended" advisory that auto-suggests enabling priority
  mode when a Nehir chord silently never dispatches under a focused app — needs
  dispatch telemetry the Carbon path cannot provide today.
- Extending `HotkeyAdvisoryCatalog` (#48) with curated known app/extension
  conflicts beyond the command-palette default — a data change, not in scope.
- Investigating `kCGSessionEventTap` vs `kCGHIDEventTap` for parity with the
  mouse taps (`MouseEventHandler.swift:284` uses `.cgSessionEventTap`) if HID-tap
  permission friction is high in the field.
