# Settings, Onboarding & Menu Bar Redesign

## Problem Statement

1. **Menu bar is a settings panel** — 6 toggles in the menu conflate "quick toggle" with "set-once preference"
2. **General tab is a dumping ground** — Theme, Status Bar, Gaps, Gestures, Mouse Resize are 5 unrelated concerns crammed into one tab
3. **Toggles are trapped in UI** — boolean settings like "Focus Follows Mouse" can only be changed via menu or settings, not from palette/hotkey/IPC
4. **Debug/trace features are scattered** — trace button lives in Workspace Bar settings, debug commands live in hotkey list, diagnostics is a standalone tab, App Rules is a separate window
5. **No onboarding** — first launch gives no guidance, users must discover features
6. **Settings don't explain consequences** — "Focus Follows Mouse" doesn't explain what it does or when it's useful

## Design Principles

- **Every boolean toggle is a command** — available via palette, hotkey, IPC
- **Menu bar is a launcher, not a settings panel** — quick access to a curated subset
- **Settings explain what and why** — every section has inline context, experimental features are tagged
- **Onboarding is optional but discoverable** — can be dismissed, re-opened from settings
- **Debug features are gated** — single toggle hides/shows all developer tooling

---

## 1. Feature Classification

### Stable Features
| Feature | Type | Exposure |
|---------|------|----------|
| Workspace Bar | Toggle + Config | Menu, Settings, Command |
| Workspace Bar Visibility | Command | Palette, Hotkey, IPC |
| Overview | Command | Palette, Hotkey, IPC |
| Keep Awake | Toggle | Settings, Command |
| Gaps / Margins | Config | Settings only |
| Niri Layout | Config | Settings only |
| Monitors | Config | Settings only |
| Workspaces | Config | Settings only |
| Hotkeys | Config | Settings only |
| App Rules | Config | Settings |
| Status Bar options | Config | Settings only |
| Theme | Config | Settings only |
| Scroll Gestures | Config | Settings only |
| Mouse Resize | Config | Settings only |
| IPC Enabled | Toggle | Settings, Command |

### Experimental Features (tagged with ⚗️)
| Feature | Type | Exposure |
|---------|------|----------|
| Focus Follows Mouse | Toggle | Menu, Settings, Command |
| Follow Window to Workspace | Toggle | Settings, Command |
| Mouse to Focused | Toggle | Settings, Command |
| Window Borders | Toggle + Config | Menu, Settings, Command |

### Diagnostics (always visible, proactively surfaced)
| Feature | Type | Exposure |
|---------|------|----------|
| Display & Dock Diagnostics | Config | Settings, Menu bar warning, Workspace Bar warning, Onboarding |
| Accessibility Permission | Prerequisite | Settings, Onboarding, App startup |

Diagnostics is NOT a debug feature — it verifies that macOS is configured correctly for Nehir to work well. It must be always visible and proactively pushed when issues are detected.

### Developer Features (gated by `developerModeEnabled`)
| Feature | Type | Exposure |
|---------|------|----------|
| Trace Capture Toggle | Command | Palette, Hotkey, IPC, Workspace Bar button |
| Dump Runtime State | Command | Palette, Hotkey, IPC |
| Reset Runtime State | Command | Palette, Hotkey, IPC |
| Restart Clearing State | Command | Palette, Hotkey, IPC |

---

## 2. Toggle Commands

### New HotkeyCommand Cases

```swift
// Added to HotkeyCommand
case toggleFocusFollowsMouse
case toggleFocusFollowsWindowToMonitor
case toggleMoveMouseToFocused
case toggleBordersEnabled
case togglePreventSleepEnabled
case toggleIPCEnabled
```

### ToggleCommand Metadata

```swift
struct ToggleSpec {
    let id: String
    let command: HotkeyCommand
    let title: String
    let stability: FeatureStability
    let requiresDeveloperMode: Bool
    let keywords: [String]
    let defaultBinding: KeyBinding
    let ipcCommandName: IPCCommandName?
}

enum FeatureStability: String, Codable {
    case stable
    case experimental
}
```

### ActionCatalog Extension

Each toggle gets an `ActionSpec` entry so it appears in:
- **Command Palette** → Commands tab, with stability badge
- **Hotkey Settings** → bindable
- **IPC** → `nehirctl toggle focus-follows-mouse`
- **Menu bar** → curated subset rendered from the same registry

### IPC Exposure

New IPC command names:
```
toggle-focus-follows-mouse
toggle-focus-follows-window-to-monitor
toggle-move-mouse-to-focused
toggle-borders
toggle-prevent-sleep
toggle-ipc
```

All follow the pattern: return the new state.

---

## 3. Developer Mode Gate

### SettingsStore Addition

```swift
var developerModeEnabled: Bool = false
```

Stored in `settings.toml` and `RuntimeState`.

### Gating Rules

When `developerModeEnabled == false`:
- `debugDumpRuntimeState`, `debugResetRuntimeState`, `debugRestartClearingRuntimeState`, `debugToggleTraceCapture` are **hidden** from:
  - Command Palette Commands list
  - Hotkey Settings section list
  - IPC command listing
- **Workspace Bar trace button** is hidden (regardless of `showTraceButton` setting)
- `showTraceButton` setting is hidden from Workspace Bar settings
- **Diagnostics tab** remains visible — it's not a debug tool, it's a prerequisite checker

When `developerModeEnabled == true`:
- All debug commands visible
- Trace button controlled by `showTraceButton` setting (existing behavior)

### Diagnostics: Always On, Proactively Surfaced

Diagnostics (`DisplayEnvironmentDiagnostics`) checks:
- Fixed Dock reserving screen space → causes visible strips on parked windows
- Horizontal display arrangement → causes window bleed between monitors
- Accessibility permission status → Nehir cannot function without it

These are **prerequisites**, not developer tools. The diagnostics section must:

1. **Always be in Settings sidebar** — not gated by developer mode
2. **Surface in menu bar** when warnings detected — show a warning row that links to diagnostics
3. **Surface in workspace bar** — existing `DisplayDiagnosticsBarButton` continues working
4. **Surface in onboarding** — Step 2 checks accessibility, Step 3 can mention Dock/display arrangement
5. **Surface on first launch** — if diagnostics detect issues at startup, show a notification-style banner

### Implementation

Add `requiresDeveloperMode: Bool` to `ActionSpec`. Filter in:
- `CommandPaletteController.buildCommandItems()` — skip dev-only when off
- `HotkeySettingsView` — skip sections when dev-only and off
- `IPCCommandRouter` — return error for dev-only commands when off
- `WorkspaceBarView` — check dev mode for trace button visibility

---

## 4. Menu Bar Redesign

### New Structure

```
Nehir v0.x                              [header]

── QUICK TOGGLES ──
☐ Focus Follows Mouse         ⚗️
☐ Window Borders              ⚗️
☐ Workspace Bar

── OPEN ──
▸ Settings…
▸ App Rules…

── CONFIG FILES ──
Reveal Config Folder
Edit settings.toml

── ──
Quit Nehir
```

**Changes from current:**
- Removed: Keep Awake, Mouse to Focused, Follow Window to Workspace (now commands only)
- Removed: IPC toggle (now command only; CLI install stays)
- Kept: Focus Follows Mouse (with ⚗️ badge), Window Borders (with ⚗️ badge), Workspace Bar
- IPC/CLI section: only shown when `ipcEnabled` or `developerModeEnabled`, shows CLI install status only
- Experimental items get a tinted "Experimental" suffix in the row

### Experimental Badge in Menu

`MenuToggleRowView` gets an `isExperimental: Bool` parameter. When true:
- Shows a small ⚗️ or pill badge after the label
- Tinted with `.orange` rather than default accent

---

## 5. Settings Reorganization

### New Tab Structure

```
General           Appearance theme + Status Bar options
Behavior          Focus Follows Mouse, Follow Window, Mouse to Focused,
                    Keep Awake, Scroll Gestures, Mouse Resize
Layout            Niri Layout + Gaps & Margins (merged)
Monitors          Mouse warp + orientation (unchanged)
Workspaces        Workspace configs (unchanged)
Workspace Bar     Bar settings (unchanged, trace button gated by dev mode)
Borders           Border settings (unchanged, tagged experimental)
Hotkeys           Hotkey editor (unchanged, dev commands gated)
App Rules         Absorbed from separate window into sidebar
Diagnostics       Display & Dock diagnostics + Accessibility status (always visible)
```

### Changes from Current

| Before | After | Reason |
|--------|-------|--------|
| General (5 concerns) | Split into General + Behavior | Single responsibility |
| Gaps in General | Moved to Layout tab (merged with Niri Layout) | Related to layout |
| App Rules (separate window) | Tab in settings sidebar | Reduces window proliferation |
| Diagnostics (always visible) | Stays always visible, enhanced with Accessibility status | Prerequisites are not debug tools |
| Workspace Bar: trace button | Gated by dev mode | Debug feature |
| Diagnostics tab (display only) | Enhanced: adds Accessibility permission status | Single place for all prerequisite checks |

### General Tab (Slimmed)

```swift
struct GeneralSettingsTab: View {
    // Appearance
    //   Theme picker
    //   Caption explaining scope

    // Status Bar
    //   Show Workspace toggle
    //   Use Workspace Number toggle
    //   Show Focused App toggle
}
```

### Behavior Tab (New)

```swift
struct BehaviorSettingsTab: View {
    // Focus
    //   ☐ Focus Follows Mouse          ⚗️ Experimental
    //     "Focus moves to the window under the cursor without clicking.
    //      Useful when you primarily use keyboard shortcuts."
    //   ☐ Follow Window to Workspace
    //     "When a window is moved to another workspace, also switch to it."
    //   ☐ Move Mouse to Focused
    //     "Move the cursor to the center of a window when it receives focus."

    // Power
    //   ☐ Keep Awake
    //     "Prevent the display from sleeping while Nehir is running."

    // Scroll Gestures
    //   (existing controls, unchanged)

    // Mouse Resize
    //   (existing controls, unchanged)
}
```

### Layout Tab (Merged Niri + Gaps)

```swift
struct LayoutSettingsTab: View {
    // Section: Gaps & Margins
    //   Inner Gaps slider
    //   Outer Margins: Left, Right, Top, Bottom sliders

    // Section: Niri Layout
    //   (all existing Niri controls)
}
```

### Experimental Feature Badge Component

```swift
struct ExperimentalBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flask")
                .font(.caption2)
            Text("Experimental")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.orange.opacity(0.12), in: Capsule())
    }
}
```

Used in settings rows and menu rows for experimental features.

---

## 6. Enhanced Setting Descriptions

### Design

Every setting section gets a richer description system:

```swift
struct SettingInfo: View {
    let text: String
    let consequence: String?    // what changes when you toggle this
    let animation: AnyView?     // optional inline animation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let consequence {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption2)
                    Text(consequence)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
```

### Example: Focus Follows Mouse

```swift
Toggle("Focus Follows Mouse", isOn: $settings.focusFollowsMouse)
SettingInfo(
    text: "Focus moves to the window under the cursor without clicking.",
    consequence: "Activating this may interfere with drag-and-drop to overlapping windows."
)
```

### Example: Inner Gaps

```swift
SettingsSliderRow(label: "Inner Gaps", value: $settings.gapSize, ...)
SettingInfo(
    text: "Space between tiled windows. Set to 0 for seamless tiling.",
    consequence: nil  // visual enough that no consequence note needed
)
```

### When to Use Consequence Notes

Use `consequence` when the setting:
- Affects system behavior beyond the app (Keep Awake, IPC)
- Has edge cases or known issues (Focus Follows Mouse can conflict with drag-and-drop)
- Is experimental (explain stability expectation)
- Changes what the user sees in a non-obvious way (Reserve Space for Workspace Bar changes layout)

---

## 7. Onboarding Flow

### Overview

A multi-step onboarding wizard presented on first launch. Can be dismissed at any step and re-opened from Settings → General.

### State Tracking

```swift
// RuntimeStateStore
struct OnboardingState: Codable, Equatable {
    var hasCompletedOnboarding: Bool = false
    var completedSteps: Set<OnboardingStep.ID> = []
    var lastPresentedVersion: String?
}

enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case accessibility
    case layoutBasics
    case navigation
    case workspaceBar
    case hotkeys
    case experimental
    case done

    var id: String { rawValue }
}
```

### Entry Points

1. **First launch** — `AppDelegate.finishBootstrap()` checks `hasCompletedOnboarding`. If false, presents onboarding after bootstrap.
2. **Settings → General** — "Re-run Setup Wizard" button.
3. **Version upgrade** — `lastPresentedVersion` vs current version. Could show a "What's New" variant (future).

### Onboarding Window

A single SwiftUI window with step-by-step navigation:

```
┌─────────────────────────────────────────────────┐
│                                                 │
│  [Animation Area - 200pt]                       │
│  ┌─────────────────────────────────────────┐    │
│  │                                         │    │
│  │   (animated illustration of the         │    │
│  │    concept being explained)             │    │
│  │                                         │    │
│  └─────────────────────────────────────────┘    │
│                                                 │
│  Step Title                                     │
│  Explanatory text about this feature and        │
│  what it does. 2-3 lines max.                   │
│                                                 │
│  ┌─────────────────────────────────────────┐    │
│  │  Inline setting control (toggle/picker) │    │
│  └─────────────────────────────────────────┘    │
│                                                 │
│  Consequence hint: "This does X when enabled"   │
│                                                 │
│                                                 │
│  [Skip]                        [Continue →]     │
│  ● ○ ○ ○ ○ ○ ○ ○  (step dots)                  │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Step Details

#### Step 1: Welcome
- **Animation**: Nehir logo with a subtle fade-in, tiles arranging
- **Text**: "Nehir is a tiling window manager for macOS. It arranges your windows automatically so you don't have to resize and position them manually."
- **Control**: None
- **Skip to**: Accessibility step

#### Step 2: Accessibility Permission
- **Animation**: macOS Security & Privacy icon → checkmark transition
- **Text**: "Nehir needs Accessibility access to observe and manage your windows."
- **Control**: "Open System Settings" button (gray checkmark if already granted)
- **Skip to**: Next (can't proceed without permission, but can dismiss)

#### Step 3: Layout Basics
- **Animation**: Abstract window tiles sliding into a Niri scroll layout — columns scrolling left/right, a focused window highlighted
- **Text**: "Windows are arranged in a scrolling column layout. The focused column stays centered, and you scroll left or right to see others."
- **Control**: 
  - Inner Gaps slider (preview in animation)
  - "Visible Columns" picker (1-5, animation adjusts)
- **Consequence**: "Gaps add breathing room. Start with 8px and adjust later."

#### Step 4: Navigation
- **Animation**: Keyboard shortcut keys lighting up as the animation shows focus moving between windows
- **Text**: "Use keyboard shortcuts to navigate. The most important ones are shown below."
- **Control**: None (read-only display of key shortcuts)
- **Display**: 
  ```
  Opt + ←/→/↑/↓   Focus windows
  Opt + Shift + ←/→   Move windows
  Ctrl+Opt+Cmd + ←/→   Switch workspace
  Opt + Space   Command Palette
  ```

#### Step 5: Workspace Bar
- **Animation**: Workspace bar sliding in at the top of the screen, showing workspace tabs with app icons
- **Text**: "The workspace bar shows your workspaces and open windows. You can click to switch workspaces."
- **Control**: Toggle "Enable Workspace Bar"
- **Consequence**: "The bar floats above other windows. You can customize its appearance later in Settings."

#### Step 6: Hotkey Setup
- **Animation**: Keyboard with keys lighting up
- **Text**: "Nehir uses Option-based shortcuts by default. You can rebind any shortcut in Settings."
- **Control**: "Open Hotkey Settings" button (optional, skips to next if pressed)
- **Skip**: Yes, defaults are fine for most users

#### Step 7: Experimental Features
- **Animation**: Flask icon with "Experimental" badge fading in
- **Text**: "Some features are experimental — they work but may have edge cases. You can enable them now or later."
- **Controls**:
  - ☐ Focus Follows Mouse — "Focus moves to window under cursor"
  - ☐ Window Borders — "Show a border around the focused window"
- **Consequence**: "These can be toggled anytime from the menu bar or Settings → Behavior."

#### Step 8: Done
- **Animation**: Checkmark with confetti-like tile animation
- **Text**: "You're all set! Access Settings from the menu bar icon or press Opt+Cmd+Space for the command palette."
- **Control**: "Start Using Nehir" button

### Animation Implementation

Animations are SwiftUI `TimelineView` + `Canvas` or pre-rendered Lottie/JSON:

**Option A: SwiftUI Canvas** (recommended for first pass)
- Draw abstract window rectangles with `.animation()` modifiers
- Low asset overhead, scales with system appearance
- Keep each animation to < 100 lines

```swift
struct TileLayoutAnimation: View {
    @State private var columns: [CGFloat] = [0.3, 0.4, 0.3]
    @State private var focusedIndex = 1
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, width in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(index == focusedIndex ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15))
                        .frame(width: geo.size.width * width, height: geo.size.height)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(index == focusedIndex ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                }
            }
        }
        .onAppear { startAnimation() }
    }

    private func startAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        // Cycle focus and resize columns to show scrolling behavior
        Task {
            for i in 0..<6 {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeInOut(duration: 0.6)) {
                    focusedIndex = (i + 1) % 3
                    columns = shuffledWidths()
                }
            }
            isAnimating = false
            startAnimation()
        }
    }
}
```

**Option B: Lottie** (future enhancement)
- Higher visual quality, designer-friendly
- Requires asset bundle

### Window Management

```swift
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show(settings: SettingsStore, controller: WMController) { ... }
    func dismiss() { ... }
}
```

- Single window, non-resizable, centered
- Registers with `OwnedWindowRegistry`
- Dismissible at any step (saves progress to `RuntimeStateStore`)
- Re-openable from Settings → General → "Re-run Setup Wizard"

---

## 8. Implementation Phases

### Phase 1: Toggle Commands + Menu Cleanup
**Scope**: Small, independent, high value

1. Add toggle `HotkeyCommand` cases to `HotkeyCommand` enum
2. Add `ActionSpec` entries to `ActionCatalog.buildSpecs()` for each toggle
3. Handle new commands in `CommandHandler.performCommand()`
4. Add IPC command names to `IPCCommandName` and `IPCAutomationManifest`
5. Slim menu bar — remove Keep Awake, Mouse to Focused, Follow Window to Workspace toggles
6. Add experimental badge to menu rows for Focus Follows Mouse and Borders
7. Add `ExperimentalBadge` SwiftUI component

**Files changed**: `HotkeyCommand.swift`, `ActionCatalog.swift`, `CommandHandler.swift`, `IPCModels.swift`, `IPCAutomationManifest.swift`, `StatusBarMenu.swift`, new `ExperimentalBadge.swift`

### Phase 2: Developer Mode Gate
**Scope**: Medium, affects multiple UI surfaces

1. Add `developerModeEnabled` to `SettingsStore` + `SettingsExport` + TOML codec
2. Add `requiresDeveloperMode` to `ActionSpec`
3. Gate debug commands in `CommandPaletteController`, `HotkeySettingsView`, `IPCCommandRouter`
4. Gate trace button in `WorkspaceBarView` and trace settings in `WorkspaceBarSettingsTab`
5. Gate Diagnostics tab visibility in `SettingsSection` / `SettingsSidebar`
6. Add "Developer Mode" toggle to Settings → General

**Files changed**: `SettingsStore.swift`, `ActionCatalog.swift`, `CommandPaletteController.swift`, `HotkeySettingsView.swift`, `IPCCommandRouter.swift`, `WorkspaceBarView.swift`, `WorkspaceBarSettingsTab.swift`, `SettingsSection.swift`, `SettingsSidebar.swift`, `SettingsExport.swift`, `SettingsTOMLCodec.swift`

### Phase 3: Settings Reorganization
**Scope**: Medium, mostly UI reshuffling

1. Create `BehaviorSettingsTab` — extract focus/gesture/sleep controls from General
2. Create merged `LayoutSettingsTab` — Niri + Gaps sections
3. Slim `GeneralSettingsTab` — theme + status bar only
4. Move App Rules into settings sidebar as a section (keep existing `AppRulesView` as detail)
5. Update `SettingsSection` and `SettingsSectionGroup` enums
6. Add `SettingInfo` component with consequence hints
7. Add experimental badges to relevant settings rows

**Files changed**: New `BehaviorSettingsTab.swift`, `SettingsSection.swift`, `SettingsSidebar.swift`, `SettingsDetailView.swift`, `GeneralSettingsTab` (in `SettingsView.swift`), new `SettingInfo.swift`, `SettingsWindowController.swift`

### Phase 4: Onboarding
**Scope**: Large, new subsystem

1. Add `OnboardingState` to `RuntimeStateStore`
2. Create `OnboardingStep` enum with step definitions
3. Create `OnboardingView` with step-by-step navigation
4. Create animation views for each step (SwiftUI Canvas)
5. Create `OnboardingWindowController`
6. Hook into `AppDelegate.finishBootstrap()` for first-launch detection
7. Add "Re-run Setup Wizard" to Settings → General

**Files changed**: New `Onboarding/` directory in `Sources/Nehir/UI/`, `RuntimeStateStore.swift`, `AppDelegate.swift`, `GeneralSettingsTab`

---

## 9. Diagnostics: Proactive Surfacing

Diagnostics must reach the user where they are, not require them to find it.

### 9.1 Current State

- **Workspace Bar**: Yellow warning triangle button appears when `hasDisplayDiagnosticsWarning == true`. Opens Settings → Diagnostics. ✅ Good.
- **Settings**: Diagnostics tab exists in sidebar. ✅ But buried under "Basics" group.
- **Menu bar**: No diagnostics presence. ❌
- **First launch**: No automatic diagnostics check. ❌

### 9.2 Proposed: Three-Tier Surfacing

#### Tier 1: Always Present (Settings)

Diagnostics stays in Settings sidebar, but:
- Moves to top-level visibility (not buried in a group)
- Expands beyond display/Dock to also show:
  - **Accessibility Permission** status (granted/denied)
  - **Display arrangement** warnings
  - **Dock** warnings
- Shows a badge/warning count on the sidebar icon when issues exist

```swift
// SettingsSection.swift — diagnostics gets a warning badge
var sidebarBadge: Int? {
    switch self {
    case .diagnostics:
        DisplayEnvironmentDiagnostics.current().issues.count +
        (AccessibilityPermissionMonitor.shared.isGranted ? 0 : 1)
    default: nil
    }
}
```

Sidebar row:
```
⚠️ Diagnostics                    2
```

#### Tier 2: Proactive Push (Menu Bar + Workspace Bar)

**Menu bar** — add a warning section when diagnostics have issues:

```
── ⚠️ ISSUES DETECTED ──        (only when warnings exist)
  Fixed Dock on Built-in Display
  ▸ Open Diagnostics
```

This section appears at the top of the menu (after the header), before QUICK TOGGLES.
When no issues exist, this section is completely hidden.

Implementation:
- `StatusBarMenuBuilder` reads `DisplayEnvironmentDiagnostics.current()` on `buildMenu()`
- Also checks `AccessibilityPermissionMonitor.shared.isGranted`
- If any issues, inserts a warning section with summary text and action row

**Workspace bar** — existing behavior continues (yellow warning button).

#### Tier 3: Startup Notification (First Launch / Issue Onset)

On first launch (or when new diagnostics issues appear for the first time), show a **native macOS notification**:

```
Nehir
⚠️ Display configuration issues detected
Fixed Dock and display arrangement may cause visual artifacts.
Click to open Diagnostics.
```

Implementation:
- `AppDelegate.finishBootstrap()` runs diagnostics after setup
- Compares against `RuntimeState.lastSeenDiagnosticsHash`
- If hash changed and issues exist, post `UNUserNotificationCenter` notification
- Clicking notification opens Settings → Diagnostics
- Requires `UNUserNotificationCenter` permission request (one-time)

```swift
// RuntimeState addition
var lastSeenDiagnosticsHash: String?
```

### 9.3 Enhanced Diagnostics Tab

Current diagnostics only checks Dock + display arrangement. Expand to include:

```swift
struct DisplayDiagnosticsSettingsTab: View {
    // Section: Accessibility
    //   ✅ Accessibility access granted / ⚠️ Accessibility access needed
    //   [Open System Settings] button when not granted
    //   Explanation of what Nehir needs it for

    // Section: Status
    //   (existing summary)

    // Section: Display and Dock Recommendations
    //   (existing issues list)

    // Section: Detected Displays
    //   (existing monitor list)
}
```

The Accessibility section is always shown, giving a single unified view of all prerequisites.

---

## 10. Setting Descriptions Reference

Complete list of consequence hints for all settings:

| Setting | Description | Consequence Hint |
|---------|-------------|------------------|
| Focus Follows Mouse | Focus moves to the window under the cursor without clicking. | May interfere with drag-and-drop to overlapping windows. |
| Follow Window to Workspace | Switch to a workspace when a window is moved there. | Without this, moving a window with ⇧Opt+1 switches workspace but keeps focus on the original. |
| Mouse to Focused | Move the cursor to the center of a window when it receives focus. | Works best with keyboard-driven navigation. |
| Keep Awake | Prevent the display from sleeping while Nehir is running. | Overrides macOS sleep timer until disabled. |
| Window Borders | Draw a configurable border around the focused window. | Uses a transparent overlay window; may briefly appear in screen recordings. |
| Workspace Bar | Show a floating bar with workspace indicators and window icons. | Floats above tiled windows by default. Change level in Workspace Bar settings. |
| Reserve Layout Space | Reduce the tiled area to make room for the workspace bar. | Without this, the bar overlaps windows. |
| IPC Enabled | Allow external tools (nehirctl CLI) to control Nehir. | Opens a Unix domain socket. Only enable if you use the CLI or scripts. |
| Scroll Gestures | Use trackpad or mouse scroll to navigate between windows. | Configure finger count and sensitivity below. |
| Mouse Resize Modifier | Hold this modifier + right-click drag to resize tiled windows. | No modifier means right-click drag always resizes. |
| Diagnostics (accessibility) | Nehir needs Accessibility access to observe and manage windows. | Without this, Nehir cannot detect or arrange windows. |
| Diagnostics (dock) | A fixed Dock reserves screen space that Nehir cannot use for windows. | Auto-hide Dock is recommended for seamless tiling. |
| Diagnostics (displays) | Side-by-side displays can cause parked windows to bleed across monitors. | Arrange displays vertically in System Settings for best results. |
