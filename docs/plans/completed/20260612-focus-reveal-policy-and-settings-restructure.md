# Focus Reveal Policy and Settings Restructure

> **Superseded:** This plan documents an intermediate design that was removed before the final viewport navigation redesign shipped. The current implementation uses snap-grid based viewport navigation and the `RevealPartial` setting (`.default`, `.off`, `.snapClosest`, `.snapCenter`). There is no `FocusRevealPolicy`, `scroll-reveal`, or persistent `allowsSelectionOffscreen` behavior in the current code. See `docs/viewport-navigation-spec.md` and `docs/plans/20260612-viewport-navigation-redesign.md` for current behavior.

## Historical Overview

This superseded intermediate proposal grouped three related changes that were later replaced by the snap-grid redesign:

1. **Bug fix**: FFM (focus-follows-mouse) incorrectly scrolls the viewport into view on native AX focus confirmation. FFM activates with `ensureVisible: false, preserveViewportAnchor: true`, which sets `allowsSelectionOffscreen = true` — but the AX confirmation path requires `activeRequest?.token == entry.token` too, which is always nil for FFM since it never creates a managed request.

2. **New feature**: `FocusRevealPolicy` setting — controls whether focusing a window via keyboard/command, mouse, or any source causes the viewport to scroll to reveal it. Default `always` preserves current behavior. User-desired: `keyboardAndCommands`.

3. **Settings restructure**: `centerFocusedColumn`, `alwaysCenterSingleColumn`, and `infiniteLoop` are focus/navigation behavior, not structural layout. Moving them from Layout → Gestures & Focus. Per-monitor overrides for these three fields are removed (breaking change, will be documented).

## Context (from discovery)

- **Bug site**: `Sources/Nehir/Core/Controller/AXEventHandler.swift:1732–1745`
- **Settings pipeline**: enum in `NiriLayoutEngine.swift` → `SettingsExport` → `CanonicalTOMLConfig.Niri` → `SettingsStore` → read directly in `AXEventHandler`
- **Per-monitor overrides**: `MonitorNiriSettings.swift` holds `centerFocusedColumn?`, `alwaysCenterSingleColumn?`, `infiniteLoop?` — all three are being removed
- **UI**: `BehaviorSettingsTab.swift` (Gestures & Focus), `SettingsView.swift` `GlobalNiriSettingsSection` + `MonitorNiriSettingsSection`
- **No existing tests** for viewport preservation in `AXEventHandlerTests.swift`

## Development Approach

- **Testing**: Development first — implement each task, wait for user confirmation, then add tests
- Complete each task fully before moving to the next
- User confirms behavior before tests are written

## Solution Overview

**Bug fix** (one line): change `(state.allowsSelectionOffscreen && activeRequest?.token == entry.token)` → `state.allowsSelectionOffscreen`. The `activeRequest` requirement was overly strict — FFM legitimately sets `allowsSelectionOffscreen` without a managed request.

**FocusRevealPolicy**: new enum in `NiriLayoutEngine.swift`, wired through `SettingsExport` → `CanonicalTOMLConfig` → `SettingsStore`. Consumed directly from `controller.settings` in `AXEventHandler`. Not passed through `updateNiriConfig`/`NiriLayoutHandler` since it's not a layout engine property.

**Restructure**: Remove `centerFocusedColumn`, `alwaysCenterSingleColumn`, `infiniteLoop` from `MonitorNiriSettings`. Update `SettingsStore.resolvedNiriSettings` to use only global values for those three. Move UI controls to `BehaviorSettingsTab` Focus section.

**Revised `preserveActiveViewport` condition:**
```swift
let nehirInitiated = activeRequest?.token == entry.token || state.allowsSelectionOffscreen
let policy = controller.settings.niriScrollReveal
let preserveActiveViewport = state.viewOffsetPixels.isGesture
    || state.viewOffsetPixels.isAnimating
    || state.allowsSelectionOffscreen                                        // Fix 1: FFM
    || (!nehirInitiated && policy == .keyboardAndCommands)                   // Fix 2: click
    || policy == .never
```

## Implementation Steps

### Task 1: Fix FFM viewport bug in AXEventHandler

**Files:**
- Modify: `Sources/Nehir/Core/Controller/AXEventHandler.swift`
- Modify: `Tests/NehirTests/AXEventHandlerTests.swift`

- [ ] In `AXEventHandler.swift` around line 1734, change condition from `(state.allowsSelectionOffscreen && activeRequest?.token == entry.token)` to `state.allowsSelectionOffscreen`
- [ ] Write test: FFM-activated window should not scroll viewport on AX focus confirmation (allowsSelectionOffscreen=true, activeRequest=nil → preserveActiveViewport=true)
- [ ] Write test: unrelated app focus steal should still scroll (allowsSelectionOffscreen=false, activeRequest=nil → preserveActiveViewport=false)
- [ ] Run tests — must pass before Task 2

### Task 2: Add FocusRevealPolicy enum and wire through settings pipeline

**Files:**
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsExport.swift`
- Modify: `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsStore.swift`
- Modify: `Sources/Nehir/Core/Controller/AXEventHandler.swift`

- [ ] Add `FocusRevealPolicy` enum to `NiriLayoutEngine.swift` alongside `CenterFocusedColumn`:
  ```swift
  enum FocusRevealPolicy: String, CaseIterable, Codable, Identifiable {
      case always
      case keyboardAndCommands
      case never
  }
  ```
  with `displayName` and `id` computed properties
- [ ] Add `niriScrollReveal: String` to `SettingsExport`
- [ ] Add default value `niriScrollReveal: FocusRevealPolicy.always.rawValue` to `SettingsExport.default`
- [ ] Add `scrollReveal: String` to `CanonicalTOMLConfig.Niri`; add `scrollReveal` to `CanonicalTOMLConfig.Niri` default and TOML export/import
- [ ] Add `var niriScrollReveal: FocusRevealPolicy` property to `SettingsStore` with `didSet { scheduleSave() }`; wire load/save following same pattern as `niriCenterFocusedColumn`
- [ ] In `AXEventHandler.swift`, expand `preserveActiveViewport` to apply the policy (full condition from Solution Overview above)
- [ ] Write test: policy `.keyboardAndCommands` + native focus (no activeRequest, no allowsSelectionOffscreen) → preserveActiveViewport=true
- [ ] Write test: policy `.never` → preserveActiveViewport=true regardless
- [ ] Write test: policy `.always` → default behavior, no preservation for native focus
- [ ] Run tests — must pass before Task 3

### Task 3: Remove per-monitor overrides for focus/navigation settings

**Files:**
- Modify: `Sources/Nehir/Core/Config/MonitorNiriSettings.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsStore.swift`

- [ ] Remove `centerFocusedColumn`, `alwaysCenterSingleColumn`, `infiniteLoop` from `MonitorNiriSettings` struct (fields, init params, `CodingKeys`, encode/decode)
- [ ] Keep `maxVisibleColumns` and `singleWindowAspectRatio` in `MonitorNiriSettings` (they are genuinely per-monitor)
- [ ] In `SettingsStore.resolvedNiriSettings(for:)`, remove per-monitor override application for the three removed fields — use global values directly
- [ ] Check if `ResolvedNiriSettings` still needs those fields (it should — the engine still reads them, they're just global now); no change needed there
- [ ] Run tests — must pass before Task 4

### Task 4: Restructure UI — move settings to Gestures & Focus

**Files:**
- Modify: `Sources/Nehir/UI/BehaviorSettingsTab.swift`
- Modify: `Sources/Nehir/UI/SettingsView.swift`

- [ ] In `BehaviorSettingsTab.swift`, add a "Navigation" section with:
  - `centerFocusedColumn` Picker (moved from GlobalNiriSettingsSection)
  - `alwaysCenterSingleColumn` Toggle (moved)
  - `infiniteLoop` Toggle (moved, was "Wrap Navigation at Edges")
  - `niriScrollReveal` Picker (new)
  - `focusFollowsWindowToMonitor` Toggle (moved from Focus section; name: "Follow Window to Workspace", description: "When moving a window to another workspace, switches your active workspace to follow it.")
  - Wire `.onChange` for each to appropriate `controller.updateNiriConfig` / settings update calls
- [ ] In `SettingsView.swift` `GlobalNiriSettingsSection`, remove `centerFocusedColumn`, `alwaysCenterSingleColumn`, `infiniteLoop` rows
- [ ] In `SettingsView.swift` `MonitorNiriSettingsSection`, remove `centerFocusedColumn`, `alwaysCenterSingleColumn`, `infiniteLoop` override rows (keep `maxVisibleColumns` and `singleWindowAspectRatio` overrides)
- [ ] Verify Layout tab no longer shows those three settings
- [ ] Run tests — must pass before Task 5

### Task 5: Create changeset entry

**Files:**
- Create: `.changeset/20260612022904-focus-reveal-policy-and-settings-restructure.md`

- [ ] Create changeset file documenting breaking changes (use minor as we still in pre 1.0):
  - Per-monitor overrides for `center-focused-column`, `always-center-single-column`, `infinite-loop` removed from TOML monitor settings
  - These settings are now global-only, accessible in Gestures & Focus → Navigation
  - New `scroll-reveal` setting added (values: `always` | `keyboard-and-commands` | `never`, default `always`)
  - Bug fix: focus-follows-mouse no longer scrolls viewport on AX focus confirmation
  - Bug fix: Move Cursor to Focused Window no longer warps after trackpad gesture snap-back

### Task 6: Verify acceptance criteria

- [ ] FFM hover focus does not scroll viewport into view
- [ ] Click focus on overflowed window with `scrollReveal = keyboardAndCommands` preserves viewport
- [ ] Click focus with `scrollReveal = always` still scrolls (default behavior preserved)
- [ ] Keyboard navigation / layout commands still scroll to reveal focused window
- [ ] Layout tab no longer shows center-focused-column, always-center-single-column, wrap-navigation
- [ ] Gestures & Focus Navigation section shows: `centerFocusedColumn`, `alwaysCenterSingleColumn`, `infiniteLoop`, `niriScrollReveal`, `focusFollowsWindowToMonitor`
- [ ] Monitor overrides section no longer shows those three fields
- [ ] Run full test suite: `swift test`
- [ ] Move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Open app, set `scrollReveal = keyboardAndCommands`, hover FFM over overflowed window → viewport should not move
- Click on overflowed window → viewport should not move
- Press keyboard focus hotkey to navigate to offscreen column → viewport should scroll
- Verify settings UI in Gestures & Focus shows all moved settings with correct values

**Breaking change documentation:**
- Update CHANGELOG / release notes with breaking change details from changeset
- If TOML config docs exist, update the `[niri]` section documentation
