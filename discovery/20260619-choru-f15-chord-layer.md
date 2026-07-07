# @choru custom F15 chord layer — Discovery

Groom 2026-07-07: still applicable — external-fork (`choru-k/nehir`) evaluation; the F15 chord-layer concept has not been ported to main (no chord engine, event tap, or `f15Enabled` settings exist) (verified against main 7a025b78).

Source branch: the `choru-k/nehir` fork on branch `choru` at `b47f7399` (feature commit touching this area: `7a34c1b1` — "Add custom features: native F15 chord layer, anchor zones, leader tree").

Compared against: upstream `guria/nehir` `main` at `7b731a51`.

Scope: started from `custom/f15.md` in the `choru` branch, then checked the named implementation files plus related config, command, leader, and test wiring. This is a discovery document only; no source checkout was modified.

---

## TL;DR

- The feature adds an opt-in global CGEvent tap that treats **F15 as a held chord-layer key** and maps hardcoded F15+key chords to existing nehir `HotkeyCommand`s. It also treats **double-tap F15** as a leader-palette opener.
- The core state machine is small and unit-tested, and the reason for a CGEvent tap is real: F15 is a normal key, not a Carbon modifier, so `RegisterEventHotKey` cannot express "F15 held + h".
- The current implementation is still very much an author's workflow port: F15 is the only layer key, the chord map is hardcoded, the leader defaults contain personal apps/zones, and enabling requires Input Monitoring plus likely Karabiner/external-keyboard setup for many Mac users.
- Mergeability is poor as-is because the branch bundles F15 with leader/zones/unified-config changes and also diverges from main in unrelated config and restore areas. The F15 idea should be considered separately from this branch shape.
- Verdict: **promising power-user concept, not ready to merge as a broad nehir feature as implemented.** Port only if it becomes a generic configurable chord/leader input feature with explicit docs/UI/permission handling.

---

## Feature behavior

Documented behavior in `custom/f15.md`:

- `custom/f15.md:3-9` describes native support for an F15-held chord layer and double-tap-F15 leader, replacing an external Hammerspoon setup.
- `custom/f15.md:5` correctly notes the technical constraint: F15 is not a macOS modifier, so Carbon hotkeys cannot represent held-F15 chords.
- `custom/f15.md:13-23` lists the default hardcoded map:
  - `h/l/j/k` → focus left/right/down/up
  - `Shift+h/l/j/k` → move window left/right/down/up
  - `f` → toggle column full width
  - `c` → expand column to available width
  - `0` → cycle column width
  - `-` / `=` → consume / expel window into/from column
  - `Esc` → cancel the layer
- `custom/f15.md:25` says TOML-configurable chords are deferred.
- `custom/f15.md:29-31` exposes only `[general].f15Enabled` and `[general].f15DoubleTapSeconds`.
- `custom/f15.md:35` notes the separate Input Monitoring permission requirement.

Main at `7b731a51` already knows F15 as a normal key symbol (`Sources/Nehir/Core/Input/KeySymbolMapper.swift:79`) and the key recorder accepts it (`Sources/Nehir/UI/KeyRecorderView.swift:180`), but there is no chord-layer engine, event tap, F15 settings, or leader mode in main.

---

## Implementation / evidence

### Pure F15 state machine

`Sources/Nehir/Core/Input/NehirF15ChordEngine.swift` is new relative to main.

Evidence:

- `NehirF15ChordEngine.swift:42-55` defines a pure `Action` / `Result` API returning either no action, a `HotkeyCommand`, or `openPalette`, plus whether the source event should be swallowed.
- `NehirF15ChordEngine.swift:57-64` stores enabled state, a clamped double-tap window, a hardcoded chord map, a 3s stale hold tracker, and the last F15 tap time.
- `NehirF15ChordEngine.swift:82-109` handles key down/up: F15 presses drive hold/double-tap state; chord keys are resolved only while the hold is active; `Esc` clears the layer; mapped key-ups are swallowed while held.
- `NehirF15ChordEngine.swift:113-125` treats a second non-repeat F15 keyDown within `doubleTapSeconds` as `.openPalette`.
- `NehirF15ChordEngine.swift:128-145` binds `kVK_F15` and hardcodes the v1 chord list through `KeySymbolMapper.fromHumanReadable`.

This is the cleanest part of the feature: it is deterministic, small, and does not depend on AppKit/TCC.

### CGEvent tap owner

`Sources/Nehir/Core/Input/F15EventTap.swift` is new relative to main.

Evidence:

- `F15EventTap.swift:9-16` owns a `NehirF15ChordEngine`, event tap, run-loop source, one-shot permission prompt state, and status text.
- `F15EventTap.swift:35-48` removes any old tap, no-ops when disabled, checks `CGPreflightListenEventAccess()`, and calls `CGRequestListenEventAccess()` once if the user opted in but lacks Input Monitoring.
- `F15EventTap.swift:50-75` installs a `.cghidEventTap` for all keyDown/keyUp events, because non-F15 key events must be observed while F15 is held.
- `F15EventTap.swift:88-112` translates the state-machine result into either pass-through/swallow and dispatches commands via the same `HotkeyCommand` path; double-tap maps to `.openLeader`.
- `F15EventTap.swift:127-138` reads `CGEvent` fields in the nonisolated callback and enters the main actor with `MainActor.assumeIsolated`.

### Controller and command wiring

Evidence:

- `Sources/Nehir/Core/Controller/WMController.swift:101` adds `private let f15Tap = F15EventTap()`.
- `WMController.swift:234-236` routes F15 commands to `commandHandler.handleHotkeyCommand`, parallel to normal hotkeys.
- `WMController.swift:392-395` installs the tap only when normal hotkeys should be enabled and `settings.f15Enabled` is true; otherwise it removes the tap.
- `WMController.swift:400-408` writes a permissions-status JSON (Accessibility/Input Monitoring status and whether Input Monitoring is needed) into Nehir's runtime-state directory.
- `WMController.swift:3341-3342`, `Sources/Nehir/Core/Controller/CommandHandler.swift:180-181`, and `Sources/Nehir/Core/Input/HotkeyCommand.swift:74` add the `.openLeader` command route.

### Config wiring

Evidence:

- `Sources/Nehir/Core/Config/SettingsExport.swift:15-16` adds `f15Enabled` and `f15DoubleTapSeconds`; defaults are `false` and `0.3` at `SettingsExport.swift:102-103`.
- `Sources/Nehir/Core/Config/SettingsStore.swift:262-267` stores the two values and saves on mutation; `SettingsStore.swift:403-404` and `:477-478` include them in export/apply.
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:36-43`, `:236-237`, `:353-354`, `:462-463`, and `:474-475` add TOML decode/encode support under `[general]`.
- `Tests/NehirTests/Fixtures/canonical-settings.toml:31-32` includes the two fields.

I did not find a Settings UI toggle or public `docs/CONFIGURATION.md` entry for F15; configuration is documented only in `custom/f15.md`.

### Leader integration related to double-tap

The double-tap path depends on a separate leader feature added in the same branch.

Evidence:

- `Sources/Nehir/Core/CommandPaletteMode.swift:3-14` adds `.leader` as a fourth command palette mode.
- `Sources/Nehir/Core/Config/LeaderConfig.swift:23-48` defines configurable leader JSON structure, and `:52-91` seeds default menus.
- `Sources/Nehir/Core/Config/LeaderConfigStore.swift:4-25` loads or seeds `~/.config/nehir/leader.json`.
- `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift:266-283` opens/refocuses the palette on the leader tab, unless `leader.json` sets `doubleTapOpensLeader = false`.
- `CommandPaletteController.swift:798-855` handles single-key leader navigation and dispatches app/action items.
- `custom/leader.md` documents the user-facing leader menu and explicitly says double-tap F15 opens it.

This means the F15 double-tap behavior is not independently mergeable unless `.openLeader` and the leader palette are accepted too, or double-tap is retargeted to the existing command palette.

---

## Tests / validation observed

Static validation performed during discovery:

- source revision verified as `b47f7399`; comparison baseline verified as upstream `main` `7b731a51`.
- inspection checkouts were clean before review.
- `git diff --name-status 7b731a51..b47f7399 -- ...` confirmed the F15/leader/config files are branch additions/modifications relative to main.
- `git diff --check 7b731a51..b47f7399 -- ...` reported no whitespace errors for the inspected F15/leader/config paths.

Tests present in the branch:

- `Tests/NehirTests/NehirF15ChordEngineTests.swift:17-75` covers core engine behavior: hold+chord command, shifted chord, double-tap, slow non-double tap, escape cancel, unmapped key pass-through, stale hold timeout, and chord without F15 ignored.
- `Tests/NehirTests/LeaderConfigTests.swift:5-53` covers leader default tree shape, action-id resolution through `ActionCatalog`, partial JSON defaults, navigation descent/run/miss behavior, and missing submenu behavior.

Test coverage gaps:

- No unit/integration test for `F15EventTap` installation, TCC-denied behavior, tap-disabled re-enable behavior, or `WMController` install/remove gating.
- No explicit round-trip assertion for `[general].f15Enabled` / `f15DoubleTapSeconds` beyond the canonical fixture containing the fields.
- No manual runtime validation evidence for real F15/RCmd→F15/Karabiner flows or Input Monitoring prompting.

---

## Quality concerns

1. **Hardcoded chord map.** `NehirF15ChordEngine.swift:130-145` explicitly defers TOML-configurable chords. This is acceptable for a personal branch, but not for a general nehir feature.
2. **F15-specific input model.** The design is named and wired around F15, not a generic "leader/chord key". Many Mac users do not have an F15 key and would need Karabiner, an external keyboard, or a non-obvious remap.
3. **Leader defaults are personal.** `LeaderConfig.defaultMenus` includes Slack, WezTerm, Kagi, Obsidian, Claude, ChatGPT, and named zones such as Meeting/Note/Cat/Duck/Web/AI. The JSON is configurable, but seeded personal defaults are not wide-audience defaults.
4. **Permission UX is thin.** The tap correctly checks Input Monitoring, but the visible behavior is "F15 does nothing" unless the user reads the custom doc/status. There is no Settings UI affordance in the inspected branch.
5. **Event-tap path is under-tested.** The pure engine is tested; the privileged global-input layer is not. This is the highest-risk runtime part.
6. **`MainActor.assumeIsolated` deserves scrutiny.** The tap is installed on `CFRunLoopGetMain()`, so the callback is plausibly main-threaded, but this is brittle enough to merit a focused runtime/Thread Sanitizer check before merging.
7. **Disabled engine still has behavior if called directly.** `NehirF15ChordEngine.handle(...)` does not guard `isEnabled`; correctness relies on `F15EventTap` not calling it when disabled. That is probably fine internally but makes the pure type less self-contained than its API suggests.
8. **No public configuration documentation.** `docs/CONFIGURATION.md` had no F15/leader entry in this branch; only `custom/f15.md` and `custom/leader.md` explain it.

---

## Mergeability risks

- **Branch scope is too large.** The same custom commit/branch adds F15, leader, zones, config changes, docs, and unrelated controller/layout behavior. F15 should not be reviewed as part of the whole branch diff.
- **Config conflicts with main.** The branch modifies `SettingsExport`, `SettingsStore`, and `CanonicalTOMLConfig` in the same area where main has `ignoreMonitorIdentity`. The diff from `7b731a51` shows that field removed while adding F15/zones fields, so a direct merge risks regressing main behavior.
- **Double-tap depends on leader.** F15 hold-chords could be ported alone, but double-tap currently requires `HotkeyCommand.openLeader`, `.leader` palette mode, `LeaderConfig`, and command-palette UI changes.
- **Permission-status side effect is bundled.** `WMController.writePermissionStatus()` writes state JSON every hotkey reconcile. That may be useful for the author's SketchyBar setup, but it is unrelated to core F15 chord semantics and should be reviewed separately.
- **Hardcoded commands may drift.** The chord list refers to command cases such as `.toggleColumnFullWidth`, `.expandColumnToAvailableWidth`, `.consumeWindowIntoColumn`, and `.expelWindowFromColumn`. These are stable enough now, but a configurable action-id layer would reduce source-level coupling.
- **No migration story for existing hotkey users.** Main already permits F15 as a normal recorded key. The feature introduces a separate global tap and swallowing behavior, so interactions with a user-assigned F15 hotkey need explicit policy and tests.

---

## Usefulness / wide-audience assessment

The **idea** clicks for a subset of nehir users: keyboard-centric tiling-window users often want a modal prefix/chord namespace so they do not burn global `cmd/ctrl/option/shift` combinations. A held layer key plus a leader menu is a familiar pattern from Vim, tmux, Hammerspoon, Karabiner, QMK, and aerospace-style power-user workflows.

However, the current **F15 incarnation** is narrow:

- F15 is obscure on current Mac keyboards; the likely happy path is "I already remap Right Command to F15 in Karabiner," which is exactly a dotfiles workflow.
- The hardcoded chord map mirrors one user's Hammerspoon setup rather than a discoverable/default nehir command grammar.
- The most polished part, the leader menu, ships seeded with personal apps and zone names.
- The feature requires Input Monitoring, which is a higher-trust permission than normal Carbon hotkeys and can be hard for users to diagnose when denied.

Wide-audience fit would improve substantially if the feature were reframed as:

- a configurable **chord layer / leader key** feature,
- with F15 merely one possible trigger,
- no personal default app bundle IDs,
- Settings UI and public docs,
- and tests for tap install/permission behavior.

As-is, it is best understood as a strong prototype for author's dotfiles replacement, not a ready product feature.

---

## Recommendation / verdict

**Verdict: 🟡 promising concept; do not merge as-is.**

Recommended path:

1. Split F15 hold-chords from the larger custom branch.
2. Decide whether nehir wants a generic chord-layer product feature. If yes, make it configurable and documented before merge.
3. Treat the leader menu as either a separate feature or a dependency with non-personal defaults.
4. Drop or isolate the permission-status JSON write unless it is independently accepted as public app behavior.

A narrow, acceptable first upstream shape could be:

- disabled by default,
- one configurable trigger key defaulting to F15,
- configurable chord entries referencing existing `ActionCatalog` action IDs,
- double-tap target configurable between existing command palette and optional leader,
- explicit Settings UI copy explaining Input Monitoring,
- pure engine tests plus a small injectable event-tap installer abstraction for permission/install tests.

---

## Concrete follow-up work

1. **Create a minimal F15/chord-only patch branch** from main, excluding zones, personal leader defaults, permission-status file writes, and unrelated controller/config changes.
2. **Make chords configurable** via `settings.toml` or a dedicated JSON, using `ActionCatalog` action IDs instead of hardcoded `HotkeyCommand` cases.
3. **Add non-personal defaults** or ship no default layer until the user opts in with explicit config.
4. **Add docs and UI.** Update `docs/CONFIGURATION.md` and Settings/Onboarding with Input Monitoring guidance and a visible disabled/permission-denied state.
5. **Add tests** for disabled engine behavior, config round-trip, controller install/remove gating, double-tap target policy, and F15 interaction with an existing single-key F15 hotkey.
6. **Runtime-validate the event tap** on macOS with Input Monitoring granted/denied, tap-disabled timeout, key-repeat, key-up modifier drift, and Karabiner Right-Command-to-F15 remap.
7. **Review privacy/security posture** for a global key event tap: document exactly what is listened to, what is swallowed, and that no keystrokes are persisted.
