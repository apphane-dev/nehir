# Settings, Onboarding & Menu Bar Redesign — Phases 1–3

## Overview

Implement the settings and menu bar redesign from `settings-and-onboarding-redesign.md`, covering three phases:

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

- [x] Add `case toggleFocusFollowsMouse` to `HotkeyCommand` enum
- [x] Add `case toggleFocusFollowsWindowToMonitor` (maps to `settings.focusFollowsWindowToMonitor`)
- [x] Add `case toggleMoveMouseToFocused`
- [x] Add `case toggleBordersEnabled`
- [x] Add `case togglePreventSleepEnabled`
- [x] Add `case toggleIPCEnabled`
- [x] In `ActionCatalog.swift`, update `displayName(for:)` switch — add display names for each new case (e.g., "Toggle Focus Follows Mouse", "Toggle Follow Window to Monitor", etc.)
- [x] In `ActionCatalog.swift`, update `ipcCommandName(for:)` switch — return `nil` for now (will be filled in Task 3/4)
- [x] Fix any other exhaustive switches in `HotkeyConfigMapping.swift` and `CommandHandler.swift` that now break (can return default/stub values)
- [x] Build must succeed before Task 2

### Task 2: Wire toggle commands into CommandHandler

**Files:**
- Modify: `Sources/Nehir/Core/Controller/CommandHandler.swift`

- [x] Add `case .toggleFocusFollowsMouse` — call `controller.setFocusFollowsMouse(!settings.focusFollowsMouse)` (or equivalent)
- [x] Add `case .toggleFocusFollowsWindowToMonitor` — toggle `settings.focusFollowsWindowToMonitor`
- [x] Add `case .toggleMoveMouseToFocused`
- [x] Add `case .toggleBordersEnabled`
- [x] Add `case .togglePreventSleepEnabled`
- [x] Add `case .toggleIPCEnabled`
- [x] Return appropriate `ExternalCommandResult` from each (confirm pattern matches existing toggle commands)

### Task 3: Add IPC command names for new toggles

**Files:**
- Modify: `Sources/NehirIPC/IPCModels.swift`
- Modify: `Sources/NehirIPC/IPCAutomationManifest.swift`

- [x] Add cases to `IPCCommandName` enum in `IPCModels.swift`:
  - `toggleFocusFollowsMouse = "toggle-focus-follows-mouse"`
  - `toggleFocusFollowsWindowToMonitor = "toggle-focus-follows-window-to-monitor"`
  - `toggleMoveMouseToFocused = "toggle-move-mouse-to-focused"`
  - `toggleBordersEnabled = "toggle-borders"`
  - `togglePreventSleepEnabled = "toggle-prevent-sleep"`
  - `toggleIPCEnabled = "toggle-ipc"`
- [x] Add corresponding `IPCCommandRequest` enum cases in `IPCModels.swift` (the `IPCCommandRequest` enum mirrors `IPCCommandName` with optional args — add a case for each new name)
- [x] Update `IPCCommandRequest.init(name:argumentValues:)` switch to handle each new case
- [x] Update `IPCCommandRequest` `Codable init(from:)` switch for each new case
- [x] Update `IPCCommandRequest.encode(to:)` switch for each new case
- [x] Update `IPCCommandRequest.name` computed property switch for each new case
- [x] Register each new command in `IPCAutomationManifest` with `IPCCommandDescriptor(commandWords: [...], name: .<case>, summary: "...")` call
- [x] Add handling for new `IPCCommandRequest` cases in `IPCCommandRouter.swift` — delegate to `CommandHandler`

### Task 4: Register toggle commands in ActionCatalog

**Files:**
- Modify: `Sources/Nehir/Core/Input/ActionCatalog.swift`

- [x] Add `FeatureStability` enum (`stable`, `experimental`) to `ActionCatalog.swift` (or a new `FeatureStability.swift`)
- [x] Add `stability: FeatureStability` field to `ActionSpec` (default `.stable`)
- [x] Add `ActionSpec` entries in `buildSpecs()` for each new toggle command, with appropriate category, title, keywords, `ipcCommandName`, and `stability`
  - `toggleFocusFollowsMouse` → stability `.experimental`
  - `toggleBordersEnabled` → stability `.experimental`
  - Others → stability `.stable`
- [x] Update `ipcCommandName(for:)` switch to return the correct `IPCCommandName` case for each new command (replacing the `nil` stubs from Task 1)
- [x] Verify `ActionCatalog.allSpecs()` returns new entries (build check)

### Task 5: ExperimentalBadge component

**Files:**
- Create: `Sources/Nehir/UI/ExperimentalBadge.swift`

- [x] Create `ExperimentalBadge: View` with flask icon + "Experimental" label in orange capsule
- [x] Create `ExperimentalBadge` with no parameters (renders inline)
- [x] Build and verify it renders when the app runs

### Task 6: Slim the menu bar

**Files:**
- Modify: `Sources/Nehir/UI/StatusBar/StatusBarMenu.swift`

- [x] Remove Keep Awake toggle row from menu
- [x] Remove Mouse to Focused toggle row from menu
- [x] Remove Follow Window to Monitor toggle row from menu (keyed as `"focusFollowsWindowToMonitor"` in the current code)
- [x] Remove IPC toggle row from menu (IPC/CLI section: keep only CLI install status, shown only when `ipcEnabled || developerModeEnabled`)
- [x] Add `⚗️ Experimental` suffix to Focus Follows Mouse row label (or use `MenuToggleRowView` parameter)
- [x] Add `⚗️ Experimental` suffix to Window Borders row label
- [x] Verify final menu structure: header → quick toggles (Focus, Borders, Workspace Bar) → Open (Settings, App Rules) → Config Files → Quit

### Task 7: Add developerModeEnabled to settings

**Files:**
- Modify: `Sources/Nehir/Core/Config/SettingsStore.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsExport.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsTOMLCodec.swift`

- [x] Add `var developerModeEnabled: Bool` to `SettingsStore` (default `false`, with `didSet` notification)
- [x] Add `developerModeEnabled: Bool` to `SettingsExport` struct
- [x] Update `SettingsExport.defaults()` to include `developerModeEnabled: false`
- [x] Add encode/decode in `SettingsTOMLCodec`
- [x] Wire `settingsStore.developerModeEnabled` into encode/decode round-trip (build check)

### Task 8: Add requiresDeveloperMode to ActionSpec and gate debug commands

**Files:**
- Modify: `Sources/Nehir/Core/Input/ActionCatalog.swift`
- Modify: `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift` (or equivalent file building palette items)
- Modify: `Sources/Nehir/UI/HotkeySettingsView.swift`
- Modify: `Sources/Nehir/IPC/IPCCommandRouter.swift`

- [x] Add `requiresDeveloperMode: Bool` to `ActionSpec` (default `false`)
- [x] Mark `debugDumpRuntimeState`, `debugResetRuntimeState`, `debugRestartClearingRuntimeState`, `debugToggleTraceCapture` with `requiresDeveloperMode: true`
- [x] In `CommandPaletteController` (wherever Commands tab items are built): filter out specs where `requiresDeveloperMode && !settings.developerModeEnabled`
- [x] In `HotkeySettingsView`: skip rendering sections/rows for dev-only specs when developer mode is off
- [x] In `IPCCommandRouter`: return an appropriate error result for dev-only commands when developer mode is off
- [x] Verify: with `developerModeEnabled = false`, debug commands absent from palette and hotkey list

### Task 9: Gate workspace bar trace button by developer mode

**Files:**
- Modify: `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift` (or wherever `DisplayDiagnosticsBarButton` / trace button is rendered)
- Modify: `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift`

- [x] Conditionally hide the trace button in `WorkspaceBarView` when `!settings.developerModeEnabled`
- [x] Conditionally hide `showTraceButton` setting row in `WorkspaceBarSettingsTab` when `!settings.developerModeEnabled`
- [x] Add "Developer Mode" toggle to `GeneralSettingsTab` in `SettingsView.swift` (it stays in General; Task 12 will move it to `BehaviorSettingsTab`)
- [x] Build and verify

### Task 10: Diagnostics sidebar badge and proactive menu warning

**Files:**
- Modify: `Sources/Nehir/UI/SettingsSidebar.swift`
- Modify: `Sources/Nehir/UI/StatusBar/StatusBarMenu.swift`

- [x] In `SettingsSidebar`, compute the diagnostics issue count locally (call `DisplayEnvironmentDiagnostics.current()` and check `AccessibilityPermissionMonitor.shared.isGranted`) — keep this logic in the sidebar view, not in the `SettingsSection` enum (which has no access to runtime state)
- [x] Render a badge showing the issue count next to the Diagnostics sidebar row
- [x] In `StatusBarMenu`, add an "⚠️ ISSUES DETECTED" section at the top (after header, before QUICK TOGGLES) when `DisplayEnvironmentDiagnostics.current()` has issues or accessibility is not granted
- [x] Include summary text + "Open Diagnostics" action in that warning section
- [x] Section is completely absent when no issues exist

### Task 11: Enhanced Diagnostics tab with Accessibility status

**Files:**
- Modify: `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift`

- [x] Add an "Accessibility" section at the top of the diagnostics tab
- [x] Show granted/denied status using `AccessibilityPermissionMonitor.shared.isGranted` (verify the monitor API)
- [x] Show "Open System Settings" button when not granted
- [x] Add explanatory text: "Nehir needs Accessibility access to observe and manage windows."

### Task 12: BehaviorSettingsTab (new tab view only)

**Files:**
- Create: `Sources/Nehir/UI/BehaviorSettingsTab.swift`
- Modify: `Sources/Nehir/UI/SettingsView.swift`

Note: `SettingsSection` enum cases `.behavior` and `.layout` are added in Task 15. Tasks 12 and 13 create the tab view structs and strip content from `GeneralSettingsTab`; `SettingsDetailView` routing is wired in Task 15.

- [x] Create `BehaviorSettingsTab: View` with sections:
  - Focus: `focusFollowsMouse` (⚗️), `focusFollowsWindowToMonitor`, `moveMouseToFocusedWindow`
  - Power: `preventSleepEnabled` (also move Developer Mode toggle here from General)
  - Scroll Gestures (moved from General)
  - Mouse Resize (moved from General)
- [x] Add `SettingInfo` consequence hints for each toggle (copy text from design doc section 10)
- [x] Remove these controls from `GeneralSettingsTab` in `SettingsView.swift`
- [x] Verify `GeneralSettingsTab` now contains only: Theme picker + Status Bar section
- [x] Build must succeed (new struct exists but is not yet routed in sidebar)

### Task 13: LayoutSettingsTab (merged Niri + Gaps, view only)

**Files:**
- Create: `Sources/Nehir/UI/LayoutSettingsTab.swift`
- Modify: `Sources/Nehir/UI/SettingsView.swift`

- [x] Create `LayoutSettingsTab: View` with:
  - Section "Gaps & Margins": Inner Gaps slider + Outer Margins sliders (moved from General)
  - Section "Niri Layout": all existing Niri controls (moved from `NiriSettingsTab` / existing Niri section)
- [x] Remove Gaps section from `GeneralSettingsTab` in `SettingsView.swift`
- [x] Keep `.niri` routing intact in `SettingsDetailView` for now — it will be replaced in Task 15; `NiriSettingsTab` can be left as a stub or deleted, as long as the build succeeds
- [x] Build must succeed before Task 14

### Task 14: App Rules absorbed into settings sidebar

**Files:**
- Modify: `Sources/Nehir/UI/SettingsSection.swift`
- Modify: `Sources/Nehir/UI/SettingsSidebar.swift`
- Modify: `Sources/Nehir/UI/SettingsDetailView.swift`

- [x] Add `.appRules` case to `SettingsSection` enum with appropriate icon (`"list.bullet.rectangle"` or similar)
- [x] Add `.appRules` to the relevant `SettingsSectionGroup`
- [x] In `SettingsDetailView`, render existing `AppRulesView` for `.appRules` section
- [x] Verify the existing `AppRulesWindowController` can be retired or that the sidebar path replaces it cleanly (keep the window controller if menu item still needs it, otherwise remove)

### Task 15: SettingsSection enum update, SettingInfo component, and final wiring

**Files:**
- Modify: `Sources/Nehir/UI/SettingsSection.swift`
- Create: `Sources/Nehir/UI/SettingInfo.swift`
- Modify: `Sources/Nehir/UI/SettingsSidebar.swift`
- Modify: `Sources/Nehir/UI/SettingsDetailView.swift`
- Modify: `Sources/Nehir/UI/BehaviorSettingsTab.swift`

- [x] Add `.behavior` and `.layout` cases to `SettingsSection` enum (with display name, icon, and group membership)
- [x] Remove `.niri` case (renamed to `.layout`) from `SettingsSection` — fixed exhaustive switches referencing `.niri`
- [x] Update `SettingsSectionGroup` groupings: Basics = `[.general, .behavior]`; Layouts = `[.layout, .monitors, .workspaces]`; Workspace = `[.bar, .borders]`; Input = `[.hotkeys, .appRules, .diagnostics]`
- [x] Update `SettingsDetailView` to route `.behavior` → `BehaviorSettingsTab`, `.layout` → `LayoutSettingsTab`
- [x] Update `SettingsSidebar` to render new section list (iterates `SettingsSectionGroup.allCases` — automatic)
- [x] Create `SettingInfo: View` with `text: String` and optional `consequence: String?` parameters
- [x] Add `ExperimentalBadge` inline in `BehaviorSettingsTab` for `focusFollowsMouse` and in `BorderSettingsTab` for `bordersEnabled`
- [x] Verify sidebar shows: General, Behavior, Layout, Monitors, Workspaces, Workspace Bar, Borders, App Rules, Hotkeys, Diagnostics

### Task 16: Verify acceptance criteria

- [x] Build succeeds with zero errors
- [x] Toggle commands appear in Command Palette (focus-follows-mouse, borders, prevent-sleep, IPC)
- [x] Experimental toggles show ⚗️ badge in menu and in settings
- [x] Menu bar has only 3 quick toggles (Focus, Borders, Workspace Bar) + Open + Config + Quit
- [x] Debug commands (dump/reset/restart state, trace) hidden from palette when developerModeEnabled=false
- [x] Debug commands visible when developerModeEnabled=true
- [x] Diagnostics tab shows Accessibility status
- [x] Diagnostics sidebar badge shows issue count
- [x] Menu bar shows warning section when diagnostics issues exist
- [x] Settings sidebar has: General, Behavior, Layout, Monitors, Workspaces, Workspace Bar, Borders, App Rules, Hotkeys, Diagnostics
- [x] Sidebar section groups reflect the new structure (General group: General+Behavior; Layouts group: Layout+Monitors+Workspaces; etc.)
- [x] BehaviorSettingsTab has Focus/Power/Scroll/MouseResize sections
- [x] LayoutSettingsTab has Gaps + Niri sections
- [x] GeneralSettingsTab has only Theme + Status Bar

### Task 17: Update documentation

- [x] Update CLAUDE.md if new patterns or conventions were established
- [x] Move this plan to `completed/`

---

## Post-Completion

**Manual verification**:
- Run the app, open Command Palette → verify new toggle commands appear with experimental badges
- Toggle `developerModeEnabled` in settings → verify debug commands appear/disappear in palette and hotkey settings
- Simulate a diagnostics warning → verify menu bar warning section appears
- Open Settings → walk through all tabs to confirm new layout

**External**:
- `nehirctl` CLI: verify new IPC command names work (`nehirctl command toggle-focus-follows-mouse`)
- Confirm existing IPC commands are unaffected

---

## Final Structure (as implemented)

### Settings sidebar

| Sidebar section | Tab contents |
|-----------------|-------------|
| **General** | Appearance (Theme picker), Status Bar (workspace/app display), Power (Prevent Display Sleep), Developer (Developer Mode toggle), Command Line (nehirctl install/remove) |
| **Behavior** | Focus (Focus Follows Mouse ⚗️, Follow Window to Monitor, Move Cursor to Focused Window), Scroll Gestures (enable, sensitivity, fingers, direction, snap, mouse modifier), Mouse Resize (modifier key) |
| **Layout** | Inner Gaps (gap size), Outer Margins (left/right/top/bottom), Column Layout + Default New Column Width + Column Width Cycle Presets — all with per-monitor scope selector |
| **Monitors** | Mouse Warp (axis, trigger margin), Warp Order (click to select for orientation), Monitor Orientation (per-selected monitor) |
| **Workspaces** | Workspace Configurations list (add/edit/delete) |
| **Workspace Bar** | Workspace Bar (content toggles), Position & Level (position, window level, notch-aware, reserve space), Position Offset (X/Y), Appearance (height, opacity, colors) — all with per-monitor scope |
| **Borders** | Enable Window Borders ⚗️ with inline DisclosureGroup for color/width/opacity |
| **App Rules** | Split-pane list (left) + inline add/edit detail pane (right) with macOS-native +/− footer |
| **Hotkeys** | Search field, bindings list (filtered), Reset to Defaults at bottom |
| **Diagnostics** | Accessibility permission status, display environment issues |

Sidebar section groups: **Basics** (General, Behavior) · **Layout** (Layout, Monitors, Workspaces) · **Workspace** (Workspace Bar, Borders) · **Input** (Hotkeys, App Rules, Diagnostics)

### Status bar menu structure

```
[Header: workspace info]
[⚠️ ISSUES DETECTED section — only when diagnostics problems exist]
  Summary text + Open Diagnostics
Focus Follows Mouse ⚗️         [toggle]
Window Borders ⚗️              [toggle]
Workspace Bar                  [toggle]
---
Open Settings
Open App Rules
---
Config Files
  Open settings.toml
  Reveal Config Folder
---
Quit Nehir
```

### IPC changes

- 6 new toggle commands: `toggle-focus-follows-mouse`, `toggle-focus-follows-window-to-monitor`, `toggle-move-mouse-to-focused`, `toggle-borders`, `toggle-prevent-sleep`, `toggle-ipc`
- IPC enable/disable removed from status bar menu; controlled via `ipc_enabled` in `settings.toml` (or `toggle-ipc` once running)
- CLI install/remove moved from status bar menu to **Settings → General → Command Line**
- Debug commands (`debug dump-runtime-state`, etc.) require Developer Mode; hidden from palette and hotkeys when off

### UX refinements (beyond original plan tasks)

- **Hotkeys tab**: removed awkward "Defaults"/"Shortcuts" section headers; replaced with search field at top; moved Reset to Defaults button to bottom; fixed ⊗ clear button column alignment via `.opacity()`/`.allowsHitTesting()` instead of conditional rendering
- **App Rules tab**: replaced modal `AppRuleAddSheet` with inline `AppRuleAddPane` detail panel; added macOS-native +/− footer buttons; Escape to dismiss; tap-to-deselect
- **Workspace Bar settings**: "Group Windows by App" (was "Deduplicate App Icons"); Reserve Space moved to Position & Level section; Notch-Aware moved to Position & Level with corrected caption
- **Layout settings**: Split "Gaps & Margins" into separate "Inner Gaps" and "Outer Margins" sections
- **Monitors settings**: Simplified orientation section — removed redundant Auto-detected/Current rows; renamed picker to "Orientation"; auto-detection status folded into caption; removed per-row subtitle from Warp Order rows
- **Default New Column Width**: Width Mode segmented picker wrapped in LabeledContent for visual consistency with other segmented pickers
- **Stepper controls**: Removed redundant value label next to text field in `SettingsNumberStepperRow` and `OverridableStepper`
- **Label consistency**: "Niri Layout" → "Column Layout"; "Infinite Loop Navigation" → "Wrap Navigation at Edges"; "Single Window Ratio" → "Single Window Width"; "Use Workspace Number" → "Show Number Instead of Name"; "Deduplicate App Icons" → "Group Windows by App"
