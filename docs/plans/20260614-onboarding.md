# Onboarding — Phase 4

## Overview

Implement first-run onboarding, version-upgrade What's New, and settings migration for Nehir.
Three flows share one window controller:

1. **First-run wizard** — 7-step wizard shown on first launch; teaches tiling, accessibility, workspace bar, and experimental features
2. **What's New screen** — single-screen summary shown on version upgrade; content is developer-written, bundled per version
3. **Migration screen** — shown when stale/removed config keys are detected in `settings.toml` or it was recreated and renamed backup created; includes a "Fix with AI" button that copies a pre-filled AI prompt to clipboard

## Context (from discovery)

- `RuntimeStateStore` in `Sources/Nehir/Core/Config/RuntimeStateStore.swift` — pattern for persistence (atomic write, JSON, private permissions); `OnboardingStateStore` will mirror this pattern with its own file
- `NehirStoragePaths` — provides `stateDirectory` URL; `onboarding-state.json` lives there alongside `runtime-state.json`
- `AppDelegate.finishBootstrap()` in `Sources/Nehir/App/AppDelegate.swift` — hook for first-launch, version, and migration checks; `runtimeState` is constructed at L51
- `SettingsWindowController` in `Sources/Nehir/UI/SettingsWindowController.swift` — canonical pattern for `OnboardingWindowController` (singleton, `OwnedWindowRegistry`, `willCloseNotification` observer)
- `Bundle.main.appVersion` via `Sources/Nehir/Core/Support/Bundle+Extensions.swift` — returns `CFBundleShortVersionString`; use for version comparisons
- `AccessibilityPermissionMonitor.shared.isGranted` — existing live permission check for Accessibility step
- `ExperimentalBadge` at `Sources/Nehir/UI/ExperimentalBadge.swift` — reuse in Experimental Features step
- `SettingsStore` already has `focusFollowsMouse`, `bordersEnabled`, `workspaceBarEnabled`
- `GeneralSettingsTab` in `Sources/Nehir/UI/SettingsView.swift` — add "Re-run Setup Wizard" button here
- Changesets in `.changeset/` — source for What's New content prose

## Development Approach

- **Testing approach**: code first; build must compile cleanly after each task; manual verification in running app is the trust signal
- No unit tests required for onboarding UI
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: update this plan file when scope changes during implementation**

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document blockers with ⚠️ prefix

## Solution Overview

`OnboardingState` lives in a dedicated `onboarding-state.json` file in the state directory,
managed by a new `OnboardingStateStore` that mirrors the `RuntimeStateStore` persistence pattern
(atomic write via `rename(2)`, private permissions, JSON-encoded). It is intentionally separate
from `RuntimeStateStore` so that `debugResetRuntimeState`, `debugRestartClearingRuntimeState`,
and "start clean" commands — all of which clear or replace `runtime-state.json` — cannot
inadvertently wipe onboarding progress. The developer must delete `onboarding-state.json` manually
to reset onboarding state during development.

`OnboardingWindowController` (singleton, `@MainActor`) manages a single non-resizable NSWindow
hosting an `OnboardingView` SwiftUI root. Step routing is driven by an `OnboardingStep` enum;
each step renders via `OnboardingStepView` — an animation area (200 pt), title, body text,
optional control slot, and Next/Skip nav with progress dots.

Steps 1–3 (Welcome, Accessibility, Layout Basics) get SwiftUI Canvas animations. Steps 4–7 use
static SF Symbol icons. Accessibility step gates progression on permission; all others are skippable.

What's New and Migration are separate `NSWindow`-less flows presented through the same controller
as modal sheets over the wizard window, or independently if the wizard already ran.

Migration detection reads the raw `settings.toml` via `String(contentsOf:)` and looks for
known-removed key names. If found, the migration screen lists them with plain-language descriptions
and a "Fix with AI" button that writes a pre-filled prompt to the pasteboard.

## What Goes Where

**Implementation Steps**: all Swift/SwiftUI code, window plumbing, hook wiring, content population.

**Post-Completion**: manual end-to-end walkthrough; test on clean install (delete `onboarding-state.json`).

---

## Implementation Steps

### Task 1: OnboardingStateStore

**Files:**
- Create: `Sources/Nehir/Core/Config/OnboardingStateStore.swift`

- [ ] Create `struct OnboardingState: Codable, Equatable` with fields:
  `lastOnboardingVersion: String? = nil` — nil = wizard never completed; value = app version at completion,
  `lastPresentedVersion: String? = nil`,
  `lastMigratedVersion: String? = nil`
  — Note: `completedSteps` is NOT included; wizard always restarts from step 1, so tracking per-step
  progress adds state with no reader (YAGNI)
- [ ] Create `@MainActor final class OnboardingStateStore` mirroring `RuntimeStateStore`:
  - `static let fileName = "onboarding-state.json"`
  - Instantiated in `AppDelegate`, passed by reference (no `shared` singleton on the store itself)
  - Same atomic-write pattern: temp file + `rename(2)`, private permissions (`S_IRUSR | S_IWUSR`), `deferSaves: Bool`
  - Same `load() -> OnboardingState`, `save(_ state:)`, `scheduleSave()`, `flushNow()` methods
  - Typed accessors: `lastOnboardingVersion`, `lastPresentedVersion`, `lastMigratedVersion`
  - Convenience read-only computed property: `var hasCompletedOnboarding: Bool { lastOnboardingVersion != nil }`
  - To mark wizard done: set `lastOnboardingVersion = Bundle.main.appVersion ?? "dev"`
- [ ] Build — fix any compile errors

### Task 2: OnboardingStep enum and step shell

**Files:**
- Create: `Sources/Nehir/UI/Onboarding/OnboardingSteps.swift`
- Create: `Sources/Nehir/UI/Onboarding/OnboardingStepView.swift`

- [ ] Create `enum OnboardingStep: String, CaseIterable, Identifiable` with 7 cases:
  `welcome`, `accessibility`, `layoutBasics`, `navigation`, `workspaceBar`, `experimental`, `done`
  — add `var id: String { rawValue }` and `var title: String`, `var bodyText: String` properties
- [ ] Create `OnboardingStepView<AnimationView: View, ControlView: View>: View` (or simpler
  non-generic version with `AnyView` slots) with layout:
  - Animation area: fixed 200 pt height `ZStack` placeholder (accepts content view)
  - `Text(step.title)` headline
  - `Text(step.bodyText)` caption, secondary foreground
  - Optional control slot (accepts content view)
  - Spacer
  - Bottom bar: Skip button (leading) + Continue/Finish button (trailing) + step dots (centered below)
- [ ] Step dots render as `Circle` filled/unfilled based on current index vs total
- [ ] Skip button hidden on `.done` step; Continue button label is "Start Using Nehir" on `.done`
- [ ] Build — fix any compile errors

### Task 3: OnboardingView and step routing

**Files:**
- Create: `Sources/Nehir/UI/Onboarding/OnboardingView.swift`

- [ ] Create `OnboardingView: View` with `onboardingStore: OnboardingStateStore` and
  `@ObservedObject` (or `@Bindable`) for `SettingsStore` dependency
- [ ] Track `currentStepIndex: Int` in `@State`; derive current step from `OnboardingStep.allCases`
- [ ] Route each step case to its content via `switch` — start with all steps showing only
  `OnboardingStepView` with placeholder animation and static text (no controls yet)
- [ ] `advance()`: increments index; on `.done` sets
  `onboardingStore.lastOnboardingVersion = Bundle.main.appVersion ?? "dev"`
- [ ] `skip()`: same as `advance()` for non-blocking steps; Accessibility step skip is allowed
  (user can proceed without granting permission)
- [ ] Build — fix any compile errors

### Task 4: Step controls (Accessibility, Workspace Bar, Experimental, Done)

**Files:**
- Modify: `Sources/Nehir/UI/Onboarding/OnboardingView.swift`

- [ ] **Accessibility step**: control slot shows status row:
  - If `AccessibilityPermissionMonitor.shared.isGranted`: green checkmark + "Accessibility access granted" text
  - If not granted: `Button("Open System Settings")` that calls `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)`
  - Live-update via `onReceive(AccessibilityPermissionMonitor.shared.isGrantedPublisher)` or
    `@State var isGranted` polled via `.onAppear` + `Timer` (check existing monitor API for observation)
- [ ] **Navigation step**: control slot shows a VStack of shortcut rows:
  `Opt+←/→/↑/↓ · Focus windows`,
  `Opt+Shift+←/→ · Move windows`,
  `Ctrl+Opt+Cmd+←/→ · Switch workspace`,
  `Opt+Space · Command Palette`
  — use monospaced font for key part, secondary foreground for description part
- [ ] **Workspace Bar step**: control slot shows `Toggle("Enable Workspace Bar", isOn: $settings.workspaceBarEnabled)`
- [ ] **Experimental Features step**: control slot shows two `Toggle` rows:
  `Toggle("Focus Follows Mouse", isOn: $settings.focusFollowsMouse)` with `ExperimentalBadge` inline
  `Toggle("Window Borders", isOn: $settings.bordersEnabled)` with `ExperimentalBadge` inline
- [ ] **Done step**: no control slot; Continue button reads "Start Using Nehir", calls `advance()` which sets `hasCompletedOnboarding = true` and the controller closes the window
- [ ] Build — fix any compile errors; verify controls bind to settings

### Task 5: OnboardingWindowController

**Files:**
- Create: `Sources/Nehir/UI/Onboarding/OnboardingWindowController.swift`

- [ ] Create `@MainActor final class OnboardingWindowController` mirroring `SettingsWindowController` pattern:
  - `static let shared = OnboardingWindowController()`
  - `private var window: NSWindow?`
  - `private let ownedWindowRegistry = OwnedWindowRegistry.shared`
  - `private var willCloseObserverToken: NSObjectProtocol?`
- [ ] `func show(settings: SettingsStore, onboardingStore: OnboardingStateStore)`:
  - If window exists, bring to front and return
  - Create `NSHostingController(rootView: OnboardingView(onboardingStore: onboardingStore, settings: settings))`
  - Create `NSWindow`: non-resizable, `styleMask = [.titled, .closable]`, size 480×580, centered
  - Register with `ownedWindowRegistry`; set `isReleasedWhenClosed = false`
  - Add `willCloseNotification` observer: unregisters window, nils `self.window`, calls `onboardingStore.flushNow()`
- [ ] `func dismiss()`: calls `window?.close()`
- [ ] Build — fix any compile errors

### Task 6: First-launch hook and Settings entry point

**Files:**
- Modify: `Sources/Nehir/App/AppDelegate.swift`
- Modify: `Sources/Nehir/UI/SettingsView.swift`

- [ ] Add `private var onboardingStateStore: OnboardingStateStore?` to `AppDelegate`
- [ ] In `AppDelegate.finishBootstrap()`, construct `OnboardingStateStore` alongside `RuntimeStateStore`:
  ```swift
  let onboardingStore = OnboardingStateStore(directory: storagePaths.stateDirectory)
  self.onboardingStateStore = onboardingStore
  ```
- [ ] After `statusBarController?.setup()`, add first-launch check:
  ```swift
  if onboardingStore.lastOnboardingVersion == nil {
      OnboardingWindowController.shared.show(settings: settings, onboardingStore: onboardingStore)
  }
  ```
  — use `DispatchQueue.main.async` if needed to defer until after app activation
- [ ] In `applicationWillTerminate`, add `onboardingStateStore?.flushNow()`
- [ ] In `GeneralSettingsTab` in `SettingsView.swift`, add a button row in the General section:
  `Button("Re-run Setup Wizard") { OnboardingWindowController.shared.show(settings: settings, onboardingStore: onboardingStore) }`
  — add `SettingInfo(text: "Walk through the onboarding steps again.", consequence: nil)` below it
- [ ] Build and manually verify: delete `runtime-state.json`, launch app — wizard should appear

### Task 7: SwiftUI animations (Welcome, Accessibility, Layout Basics)

**Files:**
- Create: `Sources/Nehir/UI/Onboarding/Animations/WelcomeAnimation.swift`
- Create: `Sources/Nehir/UI/Onboarding/Animations/AccessibilityAnimation.swift`
- Create: `Sources/Nehir/UI/Onboarding/Animations/LayoutBasicsAnimation.swift`
- Modify: `Sources/Nehir/UI/Onboarding/OnboardingView.swift`

- [ ] `WelcomeAnimation: View` — three `RoundedRectangle` tiles fade in sequentially,
  then arrange into a balanced row; loop via `Task.sleep` + `withAnimation`
  (< 80 lines, no external assets, uses `Color.accentColor.opacity(0.3)` for tiles)
- [ ] `AccessibilityAnimation: View` — lock icon (`Image(systemName: "lock.fill")`) scales up,
  then cross-fades to checkmark (`Image(systemName: "checkmark.circle.fill")`) if granted,
  stays as lock if not; re-evaluates on `isGranted` change
- [ ] `LayoutBasicsAnimation: View` — three columns, one highlighted as "focused" cycles left/right
  with scroll offset animation; matches `TileLayoutAnimation` sketch from discovery doc; loop via `Task`
- [ ] Wire each animation view into the corresponding step's animation slot in `OnboardingView`
- [ ] Build — verify animations play without crash; check they loop and don't leak tasks on view dismiss
  (use `@State var isAnimating` guard + cancellation on `.onDisappear`)

### Task 8: What's New screen

**Files:**
- Create: `Sources/Nehir/UI/Onboarding/WhatsNewContent.swift`
- Create: `Sources/Nehir/UI/Onboarding/WhatsNewView.swift`
- Modify: `Sources/Nehir/App/AppDelegate.swift`

- [ ] Create `enum WhatsNewContent` with `static let entries: [String: [String]]` — a dictionary
  keyed by version string (`"0.1.0"`) mapping to an array of plain-language bullet strings;
  populate with current release changes (derived from `.changeset/` files):
  - Settings redesign, new Behavior/Layout tabs
  - Six new toggle commands (focus, borders, sleep, IPC, etc.)
  - App Rules inline editor
  - Developer Mode gate for debug commands
  - Diagnostics accessibility status
- [ ] Create `WhatsNewView: View` with `version: String`, `bullets: [String]`, `onDismiss: () -> Void`:
  - Header: "What's New in Nehir \(version)"
  - ScrollView of bullet rows (checkmark icon + text)
  - "Got it" button calls `onDismiss`
- [ ] In `AppDelegate.finishBootstrap()`, after the first-launch check:
  ```swift
  let currentVersion = Bundle.main.appVersion ?? "dev"
  if onboardingStore.hasCompletedOnboarding,
     onboardingStore.lastPresentedVersion != currentVersion,
     let bullets = WhatsNewContent.entries[currentVersion] {
      OnboardingWindowController.shared.showWhatsNew(version: currentVersion, bullets: bullets,
          onboardingStore: onboardingStore)
  }
  ```
- [ ] Add `showWhatsNew(version:bullets:onboardingStore:)` to `OnboardingWindowController`: creates a window
  hosting `WhatsNewView`; sets `onboardingStore.lastPresentedVersion = version` in the `willCloseNotification`
  observer — NOT in the "Got it" button handler, so traffic-light close is also treated as acknowledgment
- [ ] Build — verify: set `lastPresentedVersion` to `null` in `onboarding-state.json`, relaunch — What's New appears

### Task 9: Migration screen and "Fix with AI"

**Files:**
- Create: `Sources/Nehir/Core/Config/SettingsMigrationManifest.swift`
- Create: `Sources/Nehir/UI/Onboarding/MigrationView.swift`
- Modify: `Sources/Nehir/App/AppDelegate.swift`

- [ ] Create `struct SettingsMigrationEntry` with `removedKey: String`, `replacedBy: String?`,
  `description: String`; and `enum SettingsMigrationManifest` with `static let entries: [SettingsMigrationEntry]`
  — initial entries for the layout concepts redesign:
  - `single_window_aspect_ratio` → `lone_window_max_width` — "Single-window sizing is now controlled by Lone Window Policy"
  - `max_visible_columns` → `balanced_column_count` — "Max Visible Columns is now Balanced Column Count under Default Column Width"
- [ ] Create `func detectMigrationsNeeded(in settingsFileURL: URL) -> [SettingsMigrationEntry]` (free function
  or static method): reads file as `String`, then checks **line by line** — skip blank lines and lines whose
  trimmed content starts with `#`; match remaining lines against `line.trimmingCharacters(in: .whitespaces).hasPrefix(key + " =") || ...hasPrefix(key + "=")` for each `removedKey`; return matching entries
- [ ] Write unit tests for `detectMigrationsNeeded`:
  - Returns entry when key present as a top-level assignment
  - Does NOT return entry for a commented-out key (`# single_window_aspect_ratio = ...`)
  - Does NOT return entry for a key that merely contains the search string as a suffix (`my_single_window_aspect_ratio = ...`)
  - Returns empty when file does not exist
- [ ] Create `MigrationView: View` with `entries: [SettingsMigrationEntry]`, `settingsFileURL: URL`,
  `onBackUpAndReset: () throws -> Void`, `onDismiss: () -> Void`:
  - Header: "A Quick Config Update Needed"
  - Explanation (apologetic, explains the intentional trade-off, sets future expectation):
    > "Sorry for the inconvenience. Nehir intentionally avoids automatic config migration to keep
    > its codebase simple and reliable — silent rewrites can introduce subtle bugs that are hard
    > to debug. In future versions, as the config surface stabilises, Nehir will handle this on
    > its own. For now, an AI assistant can do it in seconds."
  - List of entries: removed key → replacement description (monospaced key names, plain-language description)
  - Caption below list: "These keys are currently ignored. Nehir uses built-in defaults in their place."
  - Primary: **"Back Up + Copy AI Prompt"** button:
    1. Backs up `settings.toml` → `settings.toml.backup`:
       `try? FileManager.default.removeItem(at: backupURL)` (silently remove existing backup first),
       then `try FileManager.default.copyItem(at: settingsFileURL, to: backupURL)`
       — `copyItem` throws if destination exists, so the remove-first pattern is required
    2. Builds prompt string and copies to `NSPasteboard.general`
    3. Shows inline "Backed up to settings.toml.backup — Prompt copied" confirmation label (not an alert)
    4. Prompt format:
       ```
       I use Nehir (a macOS tiling window manager). My settings.toml has config keys that were
       removed or renamed in the latest version. I've saved a backup to settings.toml.backup.
       Please read that file and rewrite settings.toml using the current key names.

       Renamed/removed keys:
       [list each: removedKey → replacedBy: description]

       Backup path: [backupURL.path]
       ```
  - Secondary: **"I'll Fix It Manually"** button calls `onDismiss` (app continues with defaults; no backup taken)
- [ ] Add `showMigration(entries:settingsFileURL:onboardingStore:currentVersion:)` to `OnboardingWindowController`:
  sets `onboardingStore.lastMigratedVersion = currentVersion` in the `willCloseNotification` observer —
  NOT in AppDelegate and NOT in the button handler, so:
  - Quit while window open → `lastMigratedVersion` not set → migration fires again next launch ✓
  - "I'll Fix It Manually" → window closes → `willCloseNotification` fires → version recorded, won't show again ✓
  - "Back Up + Copy AI Prompt" → same path ✓
- [ ] **Migration detection runs at the TOP of `AppDelegate.finishBootstrap()`, before `SettingsStore` is constructed** — ensures backup captures the original raw file:
  ```swift
  // Phase 0: config drift — MUST run before SettingsStore is constructed
  let onboardingStore = OnboardingStateStore(directory: storagePaths.stateDirectory)
  self.onboardingStateStore = onboardingStore
  let currentVersion = Bundle.main.appVersion ?? "dev"
  let settingsURL = storagePaths.configDirectory.appendingPathComponent("settings.toml")
  if onboardingStore.lastMigratedVersion != currentVersion {
      let stale = detectMigrationsNeeded(in: settingsURL)
      if !stale.isEmpty {
          OnboardingWindowController.shared.showMigration(entries: stale, settingsFileURL: settingsURL,
              onboardingStore: onboardingStore, currentVersion: currentVersion)
      } else {
          // No stale keys: mark silently so we don't run detection every launch
          onboardingStore.lastMigratedVersion = currentVersion
      }
  }

  // Phase 1: normal bootstrap
  let settings = SettingsStore(...)
  ...
  ```
  — `lastMigratedVersion` is set immediately only when no stale keys are found (nothing for the user to do);
  when stale keys ARE found, it's deferred to window close so the screen re-shows if the app is quit mid-review
- [ ] Build — verify: add `single_window_aspect_ratio = "1.6"` to `settings.toml`, relaunch — migration screen appears; clicking "Back Up + Copy AI Prompt" creates `settings.toml.backup` and copies prompt; "Dismiss" closes without backup; relaunch after dismissal — migration screen does NOT reappear (gated by `lastMigratedVersion`)

### Task 10: Verify acceptance criteria

- [ ] Clean launch (delete `onboarding-state.json`): wizard appears, all 7 steps navigate, Done closes window
- [ ] Dismiss mid-wizard: state is saved; re-open from Settings → General shows wizard from step 1
  (re-run always starts from step 1 regardless of saved progress — wizard is short enough)
- [ ] Workspace Bar and Experimental Feature toggles in wizard actually change settings live
- [ ] Accessibility step: open System Settings button works; checkmark appears when permission granted
- [ ] Animations loop without crashes; AccessibilityAnimation reflects current permission state
- [ ] Version bump (`lastPresentedVersion` cleared): What's New screen appears after wizard
- [ ] `single_window_aspect_ratio` in settings.toml: migration screen appears before first settings write
- [ ] "Back Up + Copy AI Prompt": creates `settings.toml.backup`, copies non-empty prompt to clipboard, shows inline confirmation
- [ ] "Dismiss": closes without creating backup; migration screen does not reappear next launch (gated by `lastMigratedVersion`)
- [ ] No duplicate window registrations if show() called while window is already open
- [ ] Build with zero errors and zero warnings introduced by this feature

### Task 11: Update documentation

**Files:**
- Modify: `CLAUDE.md` (if new patterns established)
- Move: this plan to `docs/plans/completed/`

- [ ] Check if `CLAUDE.md` needs updating (new file layout in `UI/Onboarding/`)
- [ ] Move this plan to `docs/plans/completed/20260614-onboarding.md`

---

## Post-Completion

**Manual verification:**
- Full flow on a fresh user account (no existing state files)
- Verify `runtimeState.flushNow()` is called on window close so state survives crash-restart
- Check window appears centered on primary display, not off-screen on secondary display edge cases

**Future work (out of scope for this plan):**
- Version-upgrade step filtering (show only steps relevant to new features)
- Lottie animations as a quality upgrade
- What's New entries for versions > current (populate per future release)
