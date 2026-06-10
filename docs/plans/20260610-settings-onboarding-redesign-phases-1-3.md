# Settings, Onboarding & Menu Bar Redesign — Phases 1–3

## Overview

Implement the settings and menu bar redesign from `docs/plans/settings-and-onboarding-redesign.md`, covering three phases:

1. **Toggle Commands + Menu Cleanup** — expose boolean settings as palette/hotkey/IPC commands; slim the menu bar
2. **Developer Mode Gate** — hide debug tooling behind `developerModeEnabled`; keep Diagnostics always visible
3. **Settings Reorganization** — split General into General + Behavior; merge Gaps into Layout; absorb App Rules into sidebar

Phase 4 (Onboarding) is out of scope for this plan.

## Context (from discovery)

- **Key input files**: `Sources/Nehir/Core/Input/HotkeyCommand.swift`, `Sources/Nehir/Core/Input/ActionCatalog.swift`
- **IPC models**: `Sources/NehirIPC/IPCModels.swift` (IPCCommandName enum), `Sources/NehirIPC/IPCAutomationManifest.swift`
- **Command dispatch**: `Sources/Nehir/Core/Controller/CommandHandler.swift`
- **Settings store**: `Sources/Nehir/Core/Config/SettingsStore.swift` — already has `focusFollowsMouse`, `moveMouseToFocusedWindow`, `preventSleepEnabled`, `ipcEnabled`, `bordersEnabled`
- **Menu bar**: `Sources/Nehir/UI/StatusBar/StatusBarMenu.swift` — currently has toggles for focus, followMove, mouseToFocused, borders, workspaceBar, keepAwake, IPC
- **Settings UI**: `Sources/Nehir/UI/SettingsView.swift` — `GeneralSettingsTab` contains Theme, Gaps, Scroll Gestures, Mouse Resize, Focus, Status Bar
- **Settings sidebar**: `Sources/Nehir/UI/SettingsSection.swift` — 8 sections: general, diagnostics, niri, monitors, workspaces, borders, bar, hotkeys
- **Command palette**: `Sources/Nehir/UI/CommandPalette/` directory
- **HotkeySettings**: `Sources/Nehir/UI/HotkeySettingsView.swift`
- **IPC router**: `Sources/Nehir/IPC/IPCCommandRouter.swift`

## Development Approach

- **Testing approach**: Code first; manual verification in running app is the trust signal
- Complete each task fully before moving to the next
- Make small, focused changes; build must compile cleanly after each task
- No unit tests required; verify by building and running the app

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document blockers with ⚠️ prefix

## Solution Overview

- New `HotkeyCommand` cases for toggling settings; each wired into `CommandHandler`, `ActionCatalog`, `IPCModels`, `IPCAutomationManifest`
- `ActionSpec` gets a `requiresDeveloperMode: Bool` field and optional `stability: FeatureStability` field
- New shared `ExperimentalBadge` SwiftUI component used in menu rows and settings rows
- Menu bar stripped down to three quick-toggle rows + Settings/Config access
- `SettingsStore` gets `developerModeEnabled: Bool`; gating logic added to palette, hotkey settings, IPC router, and workspace bar
- New `BehaviorSettingsTab` extracted from `GeneralSettingsTab`; new `LayoutSettingsTab` merges Niri + Gaps
- `SettingsSection` enum updated; App Rules added as a sidebar section; sidebar gets diagnostic badge counts
- New `SettingInfo` component for inline consequence hints

---

## Implementation Steps

### Task 1: New HotkeyCommand toggle cases

**Files:**
- Modify: `Sources/Nehir/Core/Input/HotkeyCommand.swift`
- Modify: `Sources/Nehir/Core/Input/ActionCatalog.swift` (exhaustive switch stubs)
- Modify: `Sources/Nehir/Core/Config/HotkeyConfigMapping.swift` (if exhaustive)

- [ ] Add `case toggleFocusFollowsMouse` to `HotkeyCommand` enum
- [ ] Add `case toggleFocusFollowsWindowToMonitor` (maps to `settings.focusFollowsWindowToMonitor`)
- [ ] Add `case toggleMoveMouseToFocused`
- [ ] Add `case toggleBordersEnabled`
- [ ] Add `case togglePreventSleepEnabled`
- [ ] Add `case toggleIPCEnabled`
- [ ] In `ActionCatalog.swift`, update `displayName(for:)` switch — add display names for each new case (e.g., "Toggle Focus Follows Mouse", "Toggle Follow Window to Monitor", etc.)
- [ ] In `ActionCatalog.swift`, update `ipcCommandName(for:)` switch — return `nil` for now (will be filled in Task 3/4)
- [ ] Fix any other exhaustive switches in `HotkeyConfigMapping.swift` and `CommandHandler.swift` that now break (can return default/stub values)
- [ ] Build must succeed before Task 2

### Task 2: Wire toggle commands into CommandHandler

**Files:**
- Modify: `Sources/Nehir/Core/Controller/CommandHandler.swift`

- [ ] Add `case .toggleFocusFollowsMouse` — call `controller.setFocusFollowsMouse(!settings.focusFollowsMouse)` (or equivalent)
- [ ] Add `case .toggleFocusFollowsWindowToMonitor` — toggle `settings.focusFollowsWindowToMonitor`
- [ ] Add `case .toggleMoveMouseToFocused`
- [ ] Add `case .toggleBordersEnabled`
- [ ] Add `case .togglePreventSleepEnabled`
- [ ] Add `case .toggleIPCEnabled`
- [ ] Return appropriate `ExternalCommandResult` from each (confirm pattern matches existing toggle commands)

### Task 3: Add IPC command names for new toggles

**Files:**
- Modify: `Sources/NehirIPC/IPCModels.swift`
- Modify: `Sources/NehirIPC/IPCAutomationManifest.swift`

- [ ] Add cases to `IPCCommandName` enum in `IPCModels.swift`:
  - `toggleFocusFollowsMouse = "toggle-focus-follows-mouse"`
  - `toggleFocusFollowsWindowToMonitor = "toggle-focus-follows-window-to-monitor"`
  - `toggleMoveMouseToFocused = "toggle-move-mouse-to-focused"`
  - `toggleBordersEnabled = "toggle-borders"`
  - `togglePreventSleepEnabled = "toggle-prevent-sleep"`
  - `toggleIPCEnabled = "toggle-ipc"`
- [ ] Add corresponding `IPCCommandRequest` enum cases in `IPCModels.swift` (the `IPCCommandRequest` enum mirrors `IPCCommandName` with optional args — add a case for each new name)
- [ ] Update `IPCCommandRequest.init(name:argumentValues:)` switch to handle each new case
- [ ] Update `IPCCommandRequest` `Codable init(from:)` switch for each new case
- [ ] Update `IPCCommandRequest.encode(to:)` switch for each new case
- [ ] Update `IPCCommandRequest.name` computed property switch for each new case
- [ ] Register each new command in `IPCAutomationManifest` with `IPCCommandDescriptor(commandWords: [...], name: .<case>, summary: "...")` call
- [ ] Add handling for new `IPCCommandRequest` cases in `IPCCommandRouter.swift` — delegate to `CommandHandler`

### Task 4: Register toggle commands in ActionCatalog

**Files:**
- Modify: `Sources/Nehir/Core/Input/ActionCatalog.swift`

- [ ] Add `FeatureStability` enum (`stable`, `experimental`) to `ActionCatalog.swift` (or a new `FeatureStability.swift`)
- [ ] Add `stability: FeatureStability` field to `ActionSpec` (default `.stable`)
- [ ] Add `ActionSpec` entries in `buildSpecs()` for each new toggle command, with appropriate category, title, keywords, `ipcCommandName`, and `stability`
  - `toggleFocusFollowsMouse` → stability `.experimental`
  - `toggleBordersEnabled` → stability `.experimental`
  - Others → stability `.stable`
- [ ] Update `ipcCommandName(for:)` switch to return the correct `IPCCommandName` case for each new command (replacing the `nil` stubs from Task 1)
- [ ] Verify `ActionCatalog.allSpecs()` returns new entries (build check)

### Task 5: ExperimentalBadge component

**Files:**
- Create: `Sources/Nehir/UI/ExperimentalBadge.swift`

- [ ] Create `ExperimentalBadge: View` with flask icon + "Experimental" label in orange capsule
- [ ] Create `ExperimentalBadge` with no parameters (renders inline)
- [ ] Build and verify it renders when the app runs

### Task 6: Slim the menu bar

**Files:**
- Modify: `Sources/Nehir/UI/StatusBar/StatusBarMenu.swift`

- [ ] Remove Keep Awake toggle row from menu
- [ ] Remove Mouse to Focused toggle row from menu
- [ ] Remove Follow Window to Monitor toggle row from menu (keyed as `"focusFollowsWindowToMonitor"` in the current code)
- [ ] Remove IPC toggle row from menu (IPC/CLI section: keep only CLI install status, shown only when `ipcEnabled || developerModeEnabled`)
- [ ] Add `⚗️ Experimental` suffix to Focus Follows Mouse row label (or use `MenuToggleRowView` parameter)
- [ ] Add `⚗️ Experimental` suffix to Window Borders row label
- [ ] Verify final menu structure: header → quick toggles (Focus, Borders, Workspace Bar) → Open (Settings, App Rules) → Config Files → Quit

### Task 7: Add developerModeEnabled to settings

**Files:**
- Modify: `Sources/Nehir/Core/Config/SettingsStore.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsExport.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsTOMLCodec.swift`

- [ ] Add `var developerModeEnabled: Bool` to `SettingsStore` (default `false`, with `didSet` notification)
- [ ] Add `developerModeEnabled: Bool` to `SettingsExport` struct
- [ ] Update `SettingsExport.defaults()` to include `developerModeEnabled: false`
- [ ] Add encode/decode in `SettingsTOMLCodec`
- [ ] Wire `settingsStore.developerModeEnabled` into encode/decode round-trip (build check)

### Task 8: Add requiresDeveloperMode to ActionSpec and gate debug commands

**Files:**
- Modify: `Sources/Nehir/Core/Input/ActionCatalog.swift`
- Modify: `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift` (or equivalent file building palette items)
- Modify: `Sources/Nehir/UI/HotkeySettingsView.swift`
- Modify: `Sources/Nehir/IPC/IPCCommandRouter.swift`

- [ ] Add `requiresDeveloperMode: Bool` to `ActionSpec` (default `false`)
- [ ] Mark `debugDumpRuntimeState`, `debugResetRuntimeState`, `debugRestartClearingRuntimeState`, `debugToggleTraceCapture` with `requiresDeveloperMode: true`
- [ ] In `CommandPaletteController` (wherever Commands tab items are built): filter out specs where `requiresDeveloperMode && !settings.developerModeEnabled`
- [ ] In `HotkeySettingsView`: skip rendering sections/rows for dev-only specs when developer mode is off
- [ ] In `IPCCommandRouter`: return an appropriate error result for dev-only commands when developer mode is off
- [ ] Verify: with `developerModeEnabled = false`, debug commands absent from palette and hotkey list

### Task 9: Gate workspace bar trace button by developer mode

**Files:**
- Modify: `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift` (or wherever `DisplayDiagnosticsBarButton` / trace button is rendered)
- Modify: `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift`

- [ ] Conditionally hide the trace button in `WorkspaceBarView` when `!settings.developerModeEnabled`
- [ ] Conditionally hide `showTraceButton` setting row in `WorkspaceBarSettingsTab` when `!settings.developerModeEnabled`
- [ ] Add "Developer Mode" toggle to `GeneralSettingsTab` in `SettingsView.swift` (it stays in General; Task 12 will move it to `BehaviorSettingsTab`)
- [ ] Build and verify

### Task 10: Diagnostics sidebar badge and proactive menu warning

**Files:**
- Modify: `Sources/Nehir/UI/SettingsSidebar.swift`
- Modify: `Sources/Nehir/UI/StatusBar/StatusBarMenu.swift`

- [ ] In `SettingsSidebar`, compute the diagnostics issue count locally (call `DisplayEnvironmentDiagnostics.current()` and check `AccessibilityPermissionMonitor.shared.isGranted`) — keep this logic in the sidebar view, not in the `SettingsSection` enum (which has no access to runtime state)
- [ ] Render a badge showing the issue count next to the Diagnostics sidebar row
- [ ] In `StatusBarMenu`, add an "⚠️ ISSUES DETECTED" section at the top (after header, before QUICK TOGGLES) when `DisplayEnvironmentDiagnostics.current()` has issues or accessibility is not granted
- [ ] Include summary text + "Open Diagnostics" action in that warning section
- [ ] Section is completely absent when no issues exist

### Task 11: Enhanced Diagnostics tab with Accessibility status

**Files:**
- Modify: `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift`

- [ ] Add an "Accessibility" section at the top of the diagnostics tab
- [ ] Show granted/denied status using `AccessibilityPermissionMonitor.shared.isGranted` (verify the monitor API)
- [ ] Show "Open System Settings" button when not granted
- [ ] Add explanatory text: "Nehir needs Accessibility access to observe and manage windows."

### Task 12: BehaviorSettingsTab (new tab view only)

**Files:**
- Create: `Sources/Nehir/UI/BehaviorSettingsTab.swift`
- Modify: `Sources/Nehir/UI/SettingsView.swift`

Note: `SettingsSection` enum cases `.behavior` and `.layout` are added in Task 15. Tasks 12 and 13 create the tab view structs and strip content from `GeneralSettingsTab`; `SettingsDetailView` routing is wired in Task 15.

- [ ] Create `BehaviorSettingsTab: View` with sections:
  - Focus: `focusFollowsMouse` (⚗️), `focusFollowsWindowToMonitor`, `moveMouseToFocusedWindow`
  - Power: `preventSleepEnabled` (also move Developer Mode toggle here from General)
  - Scroll Gestures (moved from General)
  - Mouse Resize (moved from General)
- [ ] Add `SettingInfo` consequence hints for each toggle (copy text from design doc section 10)
- [ ] Remove these controls from `GeneralSettingsTab` in `SettingsView.swift`
- [ ] Verify `GeneralSettingsTab` now contains only: Theme picker + Status Bar section
- [ ] Build must succeed (new struct exists but is not yet routed in sidebar)

### Task 13: LayoutSettingsTab (merged Niri + Gaps, view only)

**Files:**
- Create: `Sources/Nehir/UI/LayoutSettingsTab.swift`
- Modify: `Sources/Nehir/UI/SettingsView.swift`

- [ ] Create `LayoutSettingsTab: View` with:
  - Section "Gaps & Margins": Inner Gaps slider + Outer Margins sliders (moved from General)
  - Section "Niri Layout": all existing Niri controls (moved from `NiriSettingsTab` / existing Niri section)
- [ ] Remove Gaps section from `GeneralSettingsTab` in `SettingsView.swift`
- [ ] Keep `.niri` routing intact in `SettingsDetailView` for now — it will be replaced in Task 15; `NiriSettingsTab` can be left as a stub or deleted, as long as the build succeeds
- [ ] Build must succeed before Task 14

### Task 14: App Rules absorbed into settings sidebar

**Files:**
- Modify: `Sources/Nehir/UI/SettingsSection.swift`
- Modify: `Sources/Nehir/UI/SettingsSidebar.swift`
- Modify: `Sources/Nehir/UI/SettingsDetailView.swift`

- [ ] Add `.appRules` case to `SettingsSection` enum with appropriate icon (`"list.bullet.rectangle"` or similar)
- [ ] Add `.appRules` to the relevant `SettingsSectionGroup`
- [ ] In `SettingsDetailView`, render existing `AppRulesView` for `.appRules` section
- [ ] Verify the existing `AppRulesWindowController` can be retired or that the sidebar path replaces it cleanly (keep the window controller if menu item still needs it, otherwise remove)

### Task 15: SettingsSection enum update, SettingInfo component, and final wiring

**Files:**
- Modify: `Sources/Nehir/UI/SettingsSection.swift`
- Create: `Sources/Nehir/UI/SettingInfo.swift`
- Modify: `Sources/Nehir/UI/SettingsSidebar.swift`
- Modify: `Sources/Nehir/UI/SettingsDetailView.swift`
- Modify: `Sources/Nehir/UI/BehaviorSettingsTab.swift`

- [ ] Add `.behavior` and `.layout` cases to `SettingsSection` enum (with display name, icon, and group membership)
- [ ] Remove `.niri` case (or rename to `.layout`) from `SettingsSection` — fix any exhaustive switches referencing `.niri`
- [ ] Update `SettingsSectionGroup` groupings: General group = `[.general, .behavior]`; Layouts group = `[.layout, .monitors, .workspaces]`; Workspace group = `[.bar, .borders]`; Other = `[.appRules, .hotkeys, .diagnostics]` (adjust to match existing pattern)
- [ ] Update `SettingsDetailView` to route `.behavior` → `BehaviorSettingsTab`, `.layout` → `LayoutSettingsTab` (this is the first time these tab views are reachable from the UI)
- [ ] Update `SettingsSidebar` to render new section list (`.behavior` and `.layout` now appear)
- [ ] Create `SettingInfo: View` with `text: String` and optional `consequence: String?` parameters
- [ ] Add `ExperimentalBadge` inline in `BehaviorSettingsTab` for experimental toggles (`focusFollowsMouse`, `bordersEnabled`)
- [ ] Verify sidebar shows: General, Behavior, Layout, Monitors, Workspaces, Workspace Bar, Borders, App Rules, Hotkeys, Diagnostics

### Task 16: Verify acceptance criteria

- [ ] Build succeeds with zero errors
- [ ] Toggle commands appear in Command Palette (focus-follows-mouse, borders, prevent-sleep, IPC)
- [ ] Experimental toggles show ⚗️ badge in menu and in settings
- [ ] Menu bar has only 3 quick toggles (Focus, Borders, Workspace Bar) + Open + Config + Quit
- [ ] Debug commands (dump/reset/restart state, trace) hidden from palette when developerModeEnabled=false
- [ ] Debug commands visible when developerModeEnabled=true
- [ ] Diagnostics tab shows Accessibility status
- [ ] Diagnostics sidebar badge shows issue count
- [ ] Menu bar shows warning section when diagnostics issues exist
- [ ] Settings sidebar has: General, Behavior, Layout, Monitors, Workspaces, Workspace Bar, Borders, App Rules, Hotkeys, Diagnostics
- [ ] Sidebar section groups reflect the new structure (General group: General+Behavior; Layouts group: Layout+Monitors+Workspaces; etc.)
- [ ] BehaviorSettingsTab has Focus/Power/Scroll/MouseResize sections
- [ ] LayoutSettingsTab has Gaps + Niri sections
- [ ] GeneralSettingsTab has only Theme + Status Bar

### Task 17: Update documentation

- [ ] Update CLAUDE.md if new patterns or conventions were established
- [ ] Move this plan to `docs/plans/completed/`

---

## Post-Completion

**Manual verification**:
- Run the app, open Command Palette → verify new toggle commands appear with experimental badges
- Toggle `developerModeEnabled` in settings → verify debug commands appear/disappear in palette and hotkey settings
- Simulate a diagnostics warning → verify menu bar warning section appears
- Open Settings → walk through all tabs to confirm new layout

**External**:
- `nehirctl` CLI: verify new IPC command names work (`nehirctl toggle focus-follows-mouse`)
- Confirm existing IPC commands are unaffected
