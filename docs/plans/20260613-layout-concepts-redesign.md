# Layout Concepts Redesign

## Overview

Replace four overlapping column/single-window knobs with three honest concepts:

1. **Default new-column width** — `.balanced(columns: Int)` (= 1/N) or `.custom(fraction: Double)`.
   Collapses `niriMaxVisibleColumns` + `niriDefaultColumnWidth` into one mental model. The UI
   "Visible Columns" slider disappears; the "Default New Column Width" section gains a
   Balanced/Custom picker with an N-columns stepper inside Balanced.

2. **Resize/cycle presets** — unchanged mechanics, updated defaults to 35/50/65/95 %.

3. **Lone-window policy** — `.fill` (no constraint) or `.centered(maxWidthFraction: Double)`.
   Replaces `singleWindowAspectRatio` entirely. The lone-window predicate remains (1 column +
   1 window + not-tabbed + normal sizing); the output is a width cap + centering instead of an
   aspect-derived size.

Scope: semantic redesign **and** plumbing normalization together. No backwards-compatibility
shims — old code paths that become redundant are deleted. Old config keys that no longer exist
will silently produce defaults.

TOML shape changes:
- Remove `single_window_aspect_ratio` key (old configs default to `.fill`).
- Add `lone_window_max_width` (optional Double, absent = fill).
- Keep `max_visible_columns` (Int) and `default_column_width` (optional Double) — they map
  directly to `DefaultColumnWidth` with no migration code.

## Context (from discovery)

- Discovery doc: `docs/plans/discovery/20260613-layout-settings-redundancy.md` — Part 2 (column
  collision) and Part 3 (single-window treatment) drive the semantic changes; Part 1 (plumbing)
  motivates doing both together.
- Config layer: `Sources/Nehir/Core/Config/` — SettingsStore, SettingsExport, BuiltInSettingsDefaults,
  CanonicalTOMLConfig, MonitorNiriSettings, MonitorOverrideFileStore.
- Layout engine: `Sources/Nehir/Core/Layout/Niri/` — NiriLayoutEngine.swift (enums +
  `singleWindowLayoutContext`), NiriLayout.swift (`resolvedSingleWindowRect` /
  `aspectFittedSingleWindowRect`), NiriLayoutEngine+ColumnOps, +Sizing, +Animation, +Monitors,
  +ViewportCommands.
- UI: `Sources/Nehir/UI/SettingsView.swift` — `GlobalNiriSettingsSection` (L271),
  `MonitorNiriSettingsSection` (L405).
- Reveal Partial interaction: `NiriLayoutEngine+ViewportCommands.swift:72,82` — `fillsViewport`
  check must remain correct when a lone centered window doesn't fill the viewport width.
- `NiriNode.hasManualSingleWindowWidthOverride` — stays meaningful in centered mode (manual resize
  stays capped at `maxWidthFraction`).
- Glossary: `docs/glossary.md` — update with new concept names.
- IPC: `docs/IPC-CLI.md` — check if `single_window_aspect_ratio` is exposed there.

## Development Approach

- **Testing approach**: implement → ask user to confirm in app → write unit tests after confirmation.
- **No tests touched until user confirms the feature works.**
- Complete each task fully before moving to the next.
- **No backwards-compatibility shims.** Redundant code is deleted, not kept behind aliases.
- **CRITICAL: update this plan file when scope changes during implementation.**

## Testing Strategy

- **Manual app testing**: after each task touching UI or engine, ask user to exercise the layout
  settings panel and a live single-window workspace.
- **Unit tests**: written in a dedicated final task, only after user signs off on the feature.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.

## Solution Overview

Two new Swift types anchor the redesign:

```swift
// Replaces SingleWindowAspectRatio
enum LoneWindowPolicy: Equatable {
    case fill
    case centered(maxWidthFraction: Double)   // 0.0–1.0, fraction of working area width
}

// Collapses niriMaxVisibleColumns + niriDefaultColumnWidth
enum DefaultColumnWidth: Equatable {
    case balanced(columns: Int)               // column width = 1/columns
    case custom(fraction: Double)             // explicit fraction 0.05–1.0

    var fraction: Double {
        switch self {
        case .balanced(let n): 1.0 / Double(n)
        case .custom(let f): f
        }
    }
}
```

`SingleWindowLayoutContext` gets `maxWidthFraction: Double` instead of `aspectRatio: CGFloat`.
`aspectFittedSingleWindowRect()` is replaced by `centeredLoneWindowRect(maxWidthFraction:)`.

SettingsExport shape changes:
- Remove `niriSingleWindowAspectRatio: String`; add `niriLoneWindowMaxWidth: Double?`.
- Keep `niriMaxVisibleColumns: Int` and `niriDefaultColumnWidth: Double?` (direct `DefaultColumnWidth`
  encoding: nil fraction = balanced, non-nil = custom).

## What Goes Where

**Implementation Steps**: all Swift/UI code changes, TOML codec, glossary.

**Post-Completion**:
- Manual verification on an ultrawide display (≥ 3440px) at various `maxWidthFraction` values.
- Check `docs/IPC-CLI.md` for `single_window_aspect_ratio` exposure and update if needed.

---

## Implementation Steps

### Task 1: Define `LoneWindowPolicy` and `DefaultColumnWidth` types

**Files:**
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift`

- [ ] Delete `enum SingleWindowAspectRatio` (L22–52) entirely.
- [ ] Add `enum LoneWindowPolicy: Equatable` with cases `.fill` and `.centered(maxWidthFraction: Double)`.
  Include `var id: String` computed from the case (`"fill"` / `"centered"`) for picker use.
- [ ] Add `enum DefaultColumnWidth: Equatable` with cases `.balanced(columns: Int)` and
  `.custom(fraction: Double)`. Add `var fraction: Double` computed property.
- [ ] Update `struct SingleWindowLayoutContext` (L229–233): replace `aspectRatio: CGFloat` with
  `maxWidthFraction: Double`.
- [ ] In `singleWindowLayoutContext()` (L235–261): leave a typed TODO (`// TODO: Task 4 — wire
  effectiveLoneWindowPolicy`) and keep it non-functional (return nil) until Task 4.
- [ ] Build — fix all compile errors introduced by removing `SingleWindowAspectRatio`.

### Task 2: Update config model

**Files:**
- Modify: `Sources/Nehir/Core/Config/SettingsExport.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsStore.swift`
- Modify: `Sources/Nehir/Core/Config/BuiltInSettingsDefaults.swift`
- Modify: `Sources/Nehir/Core/Config/MonitorNiriSettings.swift`

- [ ] **SettingsExport**: remove `niriSingleWindowAspectRatio: String`; add
  `niriLoneWindowMaxWidth: Double?`. Update `defaults()` to set `niriLoneWindowMaxWidth: nil`.
- [ ] **SettingsStore**: remove `niriSingleWindowAspectRatio` var; add `niriLoneWindowMaxWidth: Double?`
  with `didSet { scheduleSave() }`. Add computed `loneWindowPolicy: LoneWindowPolicy`
  (nil → `.fill`, value → `.centered(maxWidthFraction:)`). Add computed
  `defaultColumnWidth: DefaultColumnWidth` (nil `niriDefaultColumnWidth` → `.balanced(columns:
  niriMaxVisibleColumns)`, non-nil → `.custom`). Update `toExport()` and `applyExport(_:monitors:)`.
- [ ] **BuiltInSettingsDefaults**: change `niriColumnWidthPresets` to `[0.35, 0.50, 0.65, 0.95]`.
- [ ] **MonitorNiriSettings** (override struct): remove `singleWindowAspectRatio: SingleWindowAspectRatio?`;
  add `loneWindowMaxWidth: Double?`. Keep `maxVisibleColumns: Int?` for per-monitor balanced count
  override. **ResolvedNiriSettings**: remove `singleWindowAspectRatio`; add `loneWindowPolicy:
  LoneWindowPolicy`; replace `maxVisibleColumns: Int` with `defaultColumnWidth: DefaultColumnWidth`.
  Update init and `SettingsStore.resolvedNiriSettings(for:)` merge logic.
- [ ] Build and fix compile errors.
- [ ] Ask user to launch app, open Layout settings — verify the panel loads without crash.

### Task 3: Update TOML codecs

**Files:**
- Modify: `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
- Modify: `Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift`

- [ ] **CanonicalTOMLConfig.Niri struct** (L60–65): remove `singleWindowAspectRatio: String`;
  add `loneWindowMaxWidth: Double?`. Keep `maxVisibleColumns: Int` and `defaultColumnWidth: Double?`.
  Remove any CodingKey case for `singleWindowAspectRatio`.
- [ ] **`CanonicalTOMLConfig.init(export:)`** (L174–179): map `niriLoneWindowMaxWidth →
  loneWindowMaxWidth`; remove old `singleWindowAspectRatio` line.
- [ ] **`CanonicalTOMLConfig.toSettingsExport()`** (L240–245): map `loneWindowMaxWidth →
  niriLoneWindowMaxWidth`. Remove old line.
- [ ] **`CanonicalTOMLConfig.init(from decoder:)`** (L366–371): remove `singleWindowAspectRatio`
  decode; add `loneWindowMaxWidth = try container.decodeIfPresent(Double.self, forKey: .loneWindowMaxWidth)`.
- [ ] **MonitorOverrideFileStore** (L138): remove `singleWindowAspectRatio` extract; add
  `loneWindowMaxWidth` extract (Double? from the niri dict).
- [ ] Build and fix compile errors.
- [ ] Ask user to restart app with an existing config — confirm no crash and settings load.

### Task 4: Update layout engine mechanics

**Files:**
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Animation.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Monitors.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`

- [ ] **NiriLayoutEngine.swift**: replace `var singleWindowAspectRatio: SingleWindowAspectRatio`
  (L128) with `var loneWindowPolicy: LoneWindowPolicy = .fill`. Update `configure(...)` (L332/345).
- [ ] **`singleWindowLayoutContext()`**: resolve TODO from Task 1 — guard on
  `.centered(let maxWidthFraction)` from `effectiveLoneWindowPolicy(in:)`; store
  `maxWidthFraction` in the context. Return nil for `.fill`.
- [ ] **NiriLayoutEngine+Monitors.swift**: rename `effectiveSingleWindowAspectRatio(for:)` and
  `effectiveSingleWindowAspectRatio(in:)` to `effectiveLoneWindowPolicy(for:)` / `(in:)`, returning
  `LoneWindowPolicy` from `ResolvedNiriSettings.loneWindowPolicy`. Remove all `SingleWindowAspectRatio`
  references.
- [ ] **NiriLayout.swift**: delete `aspectFittedSingleWindowRect()`. Add
  `centeredLoneWindowRect(maxWidthFraction: Double, workingFrame: CGRect) -> CGRect`:
  `let w = workingFrame.width * maxWidthFraction; let x = workingFrame.midX - w/2`.
  Full height (workingFrame). Update `resolvedSingleWindowRect()` to use the new helper for both
  the normal and manual-override paths (manual override stays centered, capped at `maxWidthFraction`).
- [ ] **`resolvedColumnResetWidth()`** (NiriLayoutEngine.swift L191–197): replace
  `1.0 / CGFloat(effectiveMaxVisibleColumns(...))` with `effectiveDefaultColumnWidth(in:).fraction`.
  Add helper `effectiveDefaultColumnWidth(in:) -> DefaultColumnWidth` reading from
  `ResolvedNiriSettings.defaultColumnWidth`.
- [ ] **NiriLayoutEngine+ColumnOps.swift L394**: replace `effectiveMaxVisibleColumns` call with
  `effectiveDefaultColumnWidth(in:).fraction`.
- [ ] **NiriLayoutEngine+Sizing.swift L103** and **NiriLayoutEngine+Animation.swift L286–290**:
  update `SingleWindowLayoutContext` usage to use `maxWidthFraction` instead of `aspectRatio`.
- [ ] **Reveal Partial / `fillsViewport`** (ViewportCommands.swift L72, L82): if the lone-window
  context is active for the target workspace (centered policy holds), the layout intentionally
  does not fill the viewport — ensure `fillsViewport` returns false in this case so Reveal Partial
  default behavior does not mis-snap.
- [ ] Delete any remaining `effectiveMaxVisibleColumns` helpers that are now dead code.
- [ ] Build and fix compile errors.
- [ ] Ask user to test: set Lone Window to Centered 60%, open a single-window workspace, verify
  the window is narrower and centered; open a second window and verify normal column layout resumes.
  Also verify Reveal Partial scrolling is unaffected.

### Task 5: UI redesign

**Files:**
- Modify: `Sources/Nehir/UI/SettingsView.swift`

- [ ] **`GlobalNiriSettingsSection`** (L271–403):
  - Remove the "Visible Columns" `SettingsSliderRow` (L293–306).
  - Remove `Picker("Single Window Width", ...)` and its caption (L308–316).
  - Restructure "Default New Column Width" section:
    - Segmented picker Balanced | Custom (binding to `settings.defaultColumnWidth` mode).
    - Balanced: stepper "Fit N columns" binding to `settings.niriMaxVisibleColumns` (1–5).
    - Custom: existing % text field binding to `settings.niriDefaultColumnWidth`.
  - Add `Section("Lone Window")`:
    - Segmented picker Fill | Centered.
    - When Centered: `LabeledContent("Max Width")` text field binding to
      `settings.niriLoneWindowMaxWidth` (in %, 10–95, stored as fraction).
    - Caption: "On a workspace with one window, cap its width and center it."
  - Rename "Column Width Cycle Presets" → "Resize Presets".
- [ ] **`MonitorNiriSettingsSection`** (L405–450):
  - Replace `OverridableSlider("Visible Columns", ...)` with an `OverridablePicker`/control for
    the balanced column count (`ms.maxVisibleColumns` override, inherits global balanced N).
  - Replace `OverridablePicker("Single Window Width", ...)` with `OverridablePicker("Lone Window", ...)`
    binding to `ms.loneWindowMaxWidth` override (nil = inherits global).
- [ ] Build and fix compile errors.
- [ ] Ask user to exercise every section: Balanced/Custom toggle, N stepper, Lone Window Centered
  max-width field, per-monitor overrides.

### Task 6: Update glossary

**Files:**
- Modify: `docs/glossary.md`

- [ ] Remove `SingleWindowAspectRatio` and `maxVisibleColumns` entries (if present).
- [ ] Add `DefaultColumnWidth` — two modes: balanced (= 1/N columns) and custom (explicit fraction).
- [ ] Add `LoneWindowPolicy` — fill vs centered-with-max-width; note the predicate conditions.
- [ ] Document column-width resolution precedence (use viewport-schema notation if the file already
  uses that style):
  ```
  column width resolution (highest wins):
    1. LoneWindowPolicy.centered — only when lone-window predicate holds
    2. DefaultColumnWidth.custom(fraction)
    3. DefaultColumnWidth.balanced(columns) → 1/N
  ```

### Task 7: Write unit tests (after user confirms feature works)

**Files:**
- Modify: relevant `*Tests.swift` files

- [ ] `DefaultColumnWidth.fraction` computed property (balanced and custom cases).
- [ ] `centeredLoneWindowRect`: width = workingFrame.width × maxWidthFraction, horizontally centered.
- [ ] `resolvedColumnResetWidth` with `.balanced(columns: 3)` returns 1/3.
- [ ] `singleWindowLayoutContext` returns nil for `.fill`, non-nil for `.centered`.
- [ ] `CanonicalTOMLConfig` encode/decode round-trip: `loneWindowMaxWidth` survives.
- [ ] `fillsViewport` returns false when lone-window centered context is active.
- [ ] Run full test suite — all pass before closing this task.

### Task 8: Acceptance and cleanup

- [ ] Verify lone-window centering on a simulated wide workspace.
- [ ] Verify switching Balanced ↔ Custom preserves the stored column count in Balanced.
- [ ] Verify Reveal Partial "Default" scrolls correctly with and without lone-window policy active.
- [ ] Verify per-monitor overrides for both controls.
- [ ] Check `docs/IPC-CLI.md` — update if `single_window_aspect_ratio` is documented there.
- [ ] Move this plan to `docs/plans/completed/`.

## Post-Completion

- Manual test on an actual ultrawide display (≥ 3440px) at `maxWidthFraction` 0.5, 0.6, 0.75.
- Confirm manual resize of a lone centered window is capped at `maxWidthFraction` and stays centered.
