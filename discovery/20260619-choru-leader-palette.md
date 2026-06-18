# choru custom Leader palette — discovery

Source branch: the `choru-k/nehir` fork on branch `choru` at `b47f7399`, compared against upstream `guria/nehir` `main` at `7b731a51`.

Starting point: `custom/leader.md` in the `choru` branch.

Scope: leader menu behavior, implementation files named by `custom/leader.md`, related command-palette/config/action/app-launch/F15 integration, and observed tests. The source and baseline revisions were inspected read-only.

---

## TL;DR

- The feature is a real, working-shaped prototype: a fourth Command Palette tab named **Leader**, populated from `~/.config/nehir/leader.json`, dispatching single-key actions, app launches, and submenu navigation.
- The narrow idea **does click** for keyboard-heavy users who want a mnemonic command tree. The strongest broadly useful slice is "configurable single-key command palette mode"; the weakest slice is the F15/dotfiles default workflow.
- Quality is prototype-level, not merge-ready. The data model advertises "exactly one of menu/app/action" but does not enforce it; invalid actions or missing app IDs fail silently; command-palette leader interaction lacks targeted tests; the default tree is author-specific and depends on separate Zones custom work.
- Mergeability risk is moderate-to-high because the branch is not a clean feature branch: the `7b731a51..b47f7399` diff spans 122 files and includes F15, Zones, settings, docs, restore/config changes, and unrelated deletions. A portable upstream patch should extract only the palette/tree concept and probably avoid making F15 the primary entry point.
- Recommendation: **do not merge this branch as-is**. Rework into a smaller, upstream-friendly command-palette feature with schema validation, UI/IPC entry points, tests for palette behavior, and generic defaults.

---

## Feature behavior

As documented in `custom/leader.md` and verified in code:

- Opening:
  - Double-tap F15 opens the Command Palette directly on the Leader tab when `[general].f15Enabled = true` and `leader.json` has `doubleTapOpensLeader = true`.
  - The normal Command Palette can switch to Leader with `⌘4`.
  - `doubleTapOpensLeader = false` falls back to toggling the normal palette.
- Menu model:
  - `~/.config/nehir/leader.json` contains `doubleTapOpensLeader`, `rootMenu`, and `menus`.
  - A menu item has `key`, `title`, and optionally `menu`, `app`, or `action`.
  - Submenus are a flat map keyed by menu name; a folder item descends when its `menu` exists.
- Interaction:
  - Printable single-key input activates the matching item immediately.
  - Folder items descend; `Esc`/Backspace pop one level or close at root.
  - Arrow keys plus Enter work through Command Palette selection.
- Dispatch:
  - `action` resolves through `ActionCatalog.spec(for:)` to a `HotkeyCommand`.
  - `app` activates a running `NSRunningApplication` by bundle identifier or opens the app via `NSWorkspace.urlForApplication(withBundleIdentifier:)`.

The shipped default tree is not generic: Slack, WezTerm, Kagi, Obsidian, Claude, ChatGPT, and author-named zones (`Meeting`, `Note`, `Cat`, `Duck`, `Web`, `AI`) are baked into `LeaderConfig.defaultMenus`.

---

## Implementation / evidence

### New config model and store

- `Sources/Nehir/Core/Config/LeaderConfig.swift:5-18` defines `LeaderMenuItem` with `key`, `title`, `menu`, `app`, and `action`.
- `Sources/Nehir/Core/Config/LeaderConfig.swift:23-49` defines `LeaderConfig`, defaulting missing `doubleTapOpensLeader`, `rootMenu`, and `menus` during JSON decoding.
- `Sources/Nehir/Core/Config/LeaderConfig.swift:51-90` hardcodes the default tree. This includes author-specific app bundle IDs and Zone actions.
- `Sources/Nehir/Core/Config/LeaderConfig.swift:100-111` implements `LeaderNavigator.items/resolve` as a pure resolver. A menu item with a missing submenu resolves as `.run(item)` rather than as a config error.
- `Sources/Nehir/Core/Config/LeaderConfigStore.swift:5-30` loads/seeds `~/.config/nehir/leader.json`, swallowing read/decode/write errors and falling back to defaults.

### Command Palette integration

- `Sources/Nehir/Core/CommandPaletteMode.swift` adds `case leader` and `displayName == "Leader"`.
- `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift:162-176` holds leader state (`leaderMenuStack`, `leaderConfig`, `leaderConfigProvider`) and renders breadcrumbs/status text.
- `CommandPaletteController.swift:266-280` implements `toggleLeader(wmController:)`, loading `leader.json` and opening/resetting the Leader tab.
- `CommandPaletteController.swift:311-320` reloads leader config on every palette show and initializes root selection when the selected mode is `.leader`.
- `CommandPaletteController.swift:798-825` handles leader keys: Esc/Delete, arrows, Return, and single printable keys without command/control/option modifiers.
- `CommandPaletteController.swift:838-861` resolves and dispatches leader keys to submenu, ActionCatalog command, or app activation.
- `CommandPaletteController.swift:924-938` adds `⌘4` to switch to Leader.
- `CommandPaletteController.swift:1210-1225` hides the search field in Leader mode; `:1289-1297` renders leader rows; `:1651-1675` defines the leader row UI.

### Actions, command handler, app launch, IPC

- `Sources/Nehir/Core/Input/ActionCatalog.swift:554-563` adds Zone action IDs used by the default leader tree (`focusZone.N`, `moveWindowToZone.N`), but those are part of the separate Zones feature.
- `ActionCatalog.swift:688-692` already has `openCommandPalette`; `:946-947` gives `openLeader` a title, but `:1094-1097` maps `.openLeader` to no IPC command/name. Grep found no `openLeader` in `Sources/NehirIPC`, so this is not externally invokable through IPC in the inspected branch.
- `Sources/Nehir/Core/Controller/CommandHandler.swift:178-181` dispatches `.openLeader` to `WMController.openLeaderPalette()`.
- `Sources/Nehir/Core/Controller/WMController.swift:3337-3342` exposes `openCommandPalette()` and `openLeaderPalette()` wrappers.
- `CommandPaletteController.swift:853-861` performs app launch/focus directly with `NSWorkspace`, not through the command catalog.

### F15 integration

- `Sources/Nehir/Core/Input/NehirF15ChordEngine.swift:39-67` defines a pure state machine with hold state and a configurable double-tap window.
- `NehirF15ChordEngine.swift:83-125` handles F15 key-down/up, double-tap detection, escape cancellation, stale-hold behavior, and chord dispatch.
- `NehirF15ChordEngine.swift:130-149` hardcodes a Hammerspoon-like F15 chord map; comments say configurable chords are deferred.
- `Sources/Nehir/Core/Input/F15EventTap.swift:35-75` installs/removes a HID-level CGEvent tap when enabled and Input Monitoring is granted.
- `F15EventTap.swift:100-110` maps double-tap to `.openLeader`.
- `Sources/Nehir/Core/Controller/WMController.swift:231-235` routes both hotkeys and F15 commands through `CommandHandler`.
- `WMController.swift:392-395` installs/removes the F15 tap only when hotkeys are enabled, the app is enabled, services have started, and `settings.f15Enabled` is true.
- `Sources/Nehir/Core/Config/SettingsExport.swift`, `SettingsStore.swift`, and `CanonicalTOMLConfig.swift` add `[general].f15Enabled` and `f15DoubleTapSeconds`; grep found no Settings UI control for these fields, only TOML/config exposure.

---

## Tests / validation observed

Tests present in the custom branch:

- `Tests/NehirTests/LeaderConfigTests.swift:6-55`
  - verifies default root/folders and some default app/action entries;
  - verifies default action IDs resolve through `ActionCatalog`;
  - verifies partial JSON defaults;
  - verifies resolve-descend-run-miss behavior;
  - explicitly expects a missing submenu folder to resolve as `.run`, which becomes a no-op on dispatch.
- `Tests/NehirTests/NehirF15ChordEngineTests.swift:17-78`
  - covers held F15 chord dispatch, shift chord dispatch, double-tap open-palette action, slow second tap, escape cancel, unmapped-key pass-through, stale hold, and no-F15 pass-through.
- Existing `Tests/NehirTests/CommandPaletteControllerTests.swift:475-484` still only asserts `modeHint` for Windows and Menu; no observed test covers `⌘4`, leader tab rendering, `toggleLeader`, `leaderPopOrDismiss`, `activateLeaderKey`, app dispatch, action dispatch, or `doubleTapOpensLeader = false` fallback.

---

## Quality concerns

1. **Schema promise is stronger than implementation.** `custom/leader.md` says each item has exactly one of `menu`, `app`, or `action`, but `LeaderMenuItem` accepts all three optionals with no validation. Dispatch prioritizes action over app; a present valid `menu` wins only in `LeaderNavigator`; malformed combinations are silent.
2. **Invalid configs fail silently.** `LeaderConfigStore.loadOrSeed` falls back to defaults on any read/decode error and attempts to rewrite defaults. That keeps the app safe, but can surprise users by masking JSON mistakes.
3. **Missing submenu behavior is poor.** Tests bless a missing submenu as `.run`; dispatch then closes the palette and usually does nothing. A user typo in `menu` should likely stay open and surface an error.
4. **Action/app failures are not visible.** Unknown `action` IDs and unknown bundle IDs close the palette without feedback. This is especially painful for a hand-edited JSON file.
5. **Case/key collision validation is absent.** Duplicate keys in one menu are possible; first match wins. Shifted keys such as `H`/`L` are distinct, but no UI or validation warns about duplicates or non-printable/multi-character keys.
6. **Command Palette behavior is under-tested.** The most user-visible parts are untested: mode shortcut `⌘4`, no-search-field leader view, submenu stack, Escape/backspace pop, action dispatch, app launch, and fallback from `doubleTapOpensLeader = false`.
7. **F15 path is niche and permission-heavy.** It requires Input Monitoring and assumes users have or want an F15 key/layer (often via Karabiner). That is acceptable as an optional shortcut, but weak as the primary story.
8. **Defaults are dotfiles-shaped.** The default tree mirrors one user's Hammerspoon setup and references custom Zones, specific apps, and personalized zone names.

---

## Mergeability risks

- **Branch shape:** `git diff --stat 7b731a51..b47f7399` reports 122 changed files and mixes Leader with Zones, F15 chord layer, settings/config changes, monitor/restore changes, docs, and test deletions. This is not directly reviewable as a Leader-only patch.
- **Dependency on custom Zones:** default leader actions use `focusZone.N` and `moveWindowToZone.N`, which do not exist on main and are implemented by separate custom code. Porting Leader alone requires changing defaults or also porting a stable action namespace.
- **Settings/config surface:** F15 fields are TOML-only and not surfaced in Settings UI. If upstream expects UI parity for settings, this is incomplete.
- **IPC asymmetry:** `.openLeader` is a `HotkeyCommand` and display title, but not an IPC command in the inspected branch. External automation cannot open Leader directly except by simulating the F15 path or opening the palette and using UI shortcuts.
- **Command Palette mode persistence:** because `.leader` is a normal `CommandPaletteMode`, selecting Leader manually can become the persisted last mode. That may be okay, but it changes future normal palette opens into a no-search, key-tree mode unless intentionally designed.
- **TCC/runtime complexity:** the F15 tap uses `.defaultTap` to swallow key events and requires Input Monitoring. It should be reviewed separately from the leader menu itself.

---

## Usefulness / wide-audience assessment

The core idea has real appeal beyond the author's dotfiles workflow, but only after reframing:

- **Broadly useful:** a configurable mnemonic command tree inside the Command Palette. This is valuable for users who remember keys by category (`m` move, `s` switch, `a` apps) and want faster command execution than fuzzy search.
- **Somewhat useful:** app activation by bundle ID. It overlaps with launchers, but integrating app focus/launch with window-manager actions can be convenient.
- **Niche:** F15 double-tap as the default entry point. Many users lack F15, do not run Karabiner, or will resist Input Monitoring for a shortcut layer.
- **Too personal:** the default menu. Slack/WezTerm/Kagi/Obsidian/Claude/ChatGPT and named zones are not good upstream defaults.

Verdict on "does it click?": **yes as a generic leader palette, no as the branch's current F15 + personal default tree package.** The concept should be sold as a Command Palette mode or configurable command hierarchy first, with F15 as an optional binding.

---

## Recommendation / verdict

**Verdict: promising concept, not merge-ready.**

Do not merge `b47f7399` directly. Extract a narrow Leader feature if the project wants this interaction pattern:

1. Keep the Command Palette `.leader` tab and pure resolver idea.
2. Replace author-specific defaults with generic command examples or an empty/seeded template.
3. Make entry points generic: assignable hotkey, command-palette mode shortcut, and IPC command; treat F15 as optional follow-up.
4. Add config validation and visible error reporting before closing the palette on malformed actions/apps/menus.
5. Add focused tests for palette-controller behavior and dispatch.

---

## Concrete follow-up work

1. **Split the patch:** isolate Leader files/changes from F15, Zones, settings redesign, and unrelated branch changes.
2. **Define a schema validator:** enforce exactly one target (`menu`/`app`/`action`), unique single-character keys per menu, valid root menu, valid submenu references, and resolvable action IDs.
3. **Improve config UX:** show parse/validation errors in the Leader tab and avoid overwriting a bad user file silently.
4. **Add Command Palette tests:** `⌘4`, `toggleLeader`, root reset, submenu descend/pop, Enter on selection, no-op miss, action dispatch, app dispatch stub, and `doubleTapOpensLeader = false` fallback.
5. **Add an upstream-friendly entry point:** an `openLeader` ActionCatalog/IPC command and/or configurable hotkey binding independent of F15.
6. **Rework defaults:** use generic built-in actions only; avoid Zones unless Zones is merged first.
7. **Separate F15 review:** keep `NehirF15ChordEngine` as a separate optional feature with UI exposure for enable/timeout, permission status, and configurable chords if desired.
