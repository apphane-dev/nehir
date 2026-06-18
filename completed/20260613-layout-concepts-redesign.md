# Layout Concepts Redesign

## Overview

Replace four overlapping column/single-window knobs with three honest concepts:

1. **Default new-column width** — `.balanced(columns: Int)` (= 1/N) or `.custom(fraction: Double)`.
   Collapses the former `niriMaxVisibleColumns` + `niriDefaultColumnWidth` split into one mental model. The UI
   "Visible Columns" slider disappears; the "Default New Column Width" section gains a
   Balanced/Custom picker with an N-columns stepper inside Balanced.

2. **Resize/cycle presets** — unchanged mechanics, updated defaults to 35/50/65/95 %.

3. **Lone-window policy** — `.fill` (fill the working area) or `.centered(maxWidthFraction: Double)`.
   Replaces `singleWindowAspectRatio` entirely. The lone-window predicate remains (1 column +
   1 window + not-tabbed + normal sizing); `.fill` outputs the full working area, while `.centered`
   outputs a width cap + centering instead of an aspect-derived size.

Scope: semantic redesign **and** plumbing normalization together. No backwards-compatibility
shims — old code paths that become redundant are deleted. Old config keys that no longer exist
will silently produce defaults.

TOML shape changes:
- Remove `singleWindowAspectRatio`.
- Add `loneWindowMaxWidth` (optional Double, absent = fill).
- Rename `maxVisibleColumns` to `balancedColumnCount` and keep `defaultColumnWidth` (optional Double) —
  together they map directly to `DefaultColumnWidth` with no migration code.

## Context (from discovery)

- Discovery doc: `completed/20260613-layout-settings-redundancy.md` — Part 2 (column
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
  bypasses the policy cap; the policy only defines the default initial state).
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

- ➕ Scope clarification: `LoneWindowPolicy.fill` now means an active lone-window layout that fills the working area, not "fall through to default column width".
- ➕ Scope clarification: lone-window policy affects only the default initial lone-window state; manual resize overrides must be uncapped by policy.
- ➕ UX/content pass: layout settings page copy must distinguish initial defaults, live spacing, one-window behavior, and resize presets for first-time users.
- ➕ Bug fix: invalidate cached layout spans when inner gaps or screen margins change to prevent stale-width jumps while dragging sliders.
- ➕ Scope addition: inner gap and screen margins now support per-monitor overrides in `monitors.d/*.toml` via `[gaps]` (`size`, `outerLeft`, `outerRight`, `outerTop`, `outerBottom`).
- ➕ Bug fix: runtime minimum sizes that fit the monitor visible frame but not the inset working frame must still be honored; constrained lone windows clamp back into the visible frame instead of leaking offscreen.
- ➕ Scope addition: lone-window workspaces participate in viewport snap/overscroll logic. Centering is represented as a viewport offset, not as a hard reset that ignores gestures.
- ➕ Refactor requirement: single-window viewport math is centralized in `SingleWindowViewportGeometry`; do not duplicate center-offset, zero-offset, or rendered-frame calculations in controllers.
- ➕ Bug fix: lone-window rendering now uses the raw viewport offset so scroll gestures visibly move the window; snap/bounds logic owns where the viewport settles. To preserve working-area margins, the snap grid omits the synthetic `±gap` edge snaps for columns that fill or exceed the viewport, because those snaps only shift a full-width column by one gap with no neighboring column to reveal. Center and far overscroll boundary snaps remain. Stale offsets from a policy/size/monitor change are reset to center by the relayout path detecting a change in the lone window's resolved width.
- ➕ Semantic correction: inner gap means spacing between adjacent stacked tiles only (secondary axis / vertical stacking). Monitor-edge padding comes exclusively from outer gaps.
- ➕ Correction: the primary-axis proportional column-width formula (`ProportionalSize.resolveProportionalSpan`, niri-compatible `(A - gaps)*p - gaps`) is intentionally KEPT unchanged. Its 2*gap slack is coupled to `ViewportSnapContext.fillsViewport`'s tolerance (also 2*gap) and acts as a sub-pixel rounding safety margin; removing it breaks 50/50 column fit and makes Reveal Partial "Default" fall back to center-snap. Only the secondary-axis gap accounting (tile stacking solver, tabbed shared frame, leading `secondaryGap` offset) was changed.
- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.

## Solution Overview

Two new Swift types anchor the redesign:

```swift
// Replaces SingleWindowAspectRatio
enum LoneWindowPolicy: Equatable {
    case fill                                // fill working area when the lone-window predicate holds
    case centered(maxWidthFraction: Double)  // 0.0–1.0, fraction of working area width
}

// Collapses the former niriMaxVisibleColumns + niriDefaultColumnWidth split
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

Session decisions added during implementation:
- `SingleWindowViewportGeometry` is the source of truth for lone-window viewport rects, center offsets,
  and rendered-frame offsetting. Callers may prepare/seed this geometry, but must not rederive the math.
- Lone-window viewport offset uses the same coordinate meaning as regular columns. The initial/resting
  offset is explicitly seeded to the geometry's `centerOffset`; non-center offsets represent active
  gesture movement or side/overscroll snaps and must survive ordinary relayout.
- Runtime window minimum constraints are relaxed only when they exceed the monitor visible frame, not merely
  because they exceed the inset working frame after outer gaps/workspace bar reservations.
- Inner gaps are internal separators only. Top/bottom/left/right monitor edge spacing must be configured
  through outer gaps/screen margins.

SettingsExport shape changes:
- Remove `niriSingleWindowAspectRatio: String`; add `niriLoneWindowMaxWidth: Double?`.
- Rename `niriMaxVisibleColumns: Int` to `niriBalancedColumnCount: Int`; keep
  `niriDefaultColumnWidth: Double?` (direct `DefaultColumnWidth` encoding: nil fraction = balanced,
  non-nil = custom).

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

- [x] Delete `enum SingleWindowAspectRatio` (L22–52) entirely.
- [x] Add `enum LoneWindowPolicy: Equatable` with cases `.fill` and `.centered(maxWidthFraction: Double)`.
  Include `var id: String` computed from the case (`"fill"` / `"centered"`) for picker use.
- [x] Add `enum DefaultColumnWidth: Equatable` with cases `.balanced(columns: Int)` and
  `.custom(fraction: Double)`. Add `var fraction: Double` computed property.
- [x] Update `struct SingleWindowLayoutContext` (L229–233): replace `aspectRatio: CGFloat` with
  `maxWidthFraction: Double`.
- [x] In `singleWindowLayoutContext()` (L235–261): leave a typed TODO (`// TODO: Task 4 — wire
  effectiveLoneWindowPolicy`) and keep it non-functional (return nil) until Task 4.
- [x] Build — fix all compile errors introduced by removing `SingleWindowAspectRatio`.

### Task 2: Update config model

**Files:**
- Modify: `Sources/Nehir/Core/Config/SettingsExport.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsStore.swift`
- Modify: `Sources/Nehir/Core/Config/BuiltInSettingsDefaults.swift`
- Modify: `Sources/Nehir/Core/Config/MonitorNiriSettings.swift`

- [x] **SettingsExport**: remove `niriSingleWindowAspectRatio: String`; add
  `niriLoneWindowMaxWidth: Double?`. Update `defaults()` to set `niriLoneWindowMaxWidth: nil`.
- [x] **SettingsStore**: remove `niriSingleWindowAspectRatio` var; add `niriLoneWindowMaxWidth: Double?`
  with `didSet { scheduleSave() }`. Add computed `loneWindowPolicy: LoneWindowPolicy`
  (nil → `.fill`, value → `.centered(maxWidthFraction:)`). Add computed
  `defaultColumnWidth: DefaultColumnWidth` (nil `niriDefaultColumnWidth` → `.balanced(columns:
  niriBalancedColumnCount)`, non-nil → `.custom`). Rename `niriMaxVisibleColumns` to
  `niriBalancedColumnCount`. Update `toExport()` and `applyExport(_:monitors:)`.
- [x] **BuiltInSettingsDefaults**: change `niriColumnWidthPresets` to `[0.35, 0.50, 0.65, 0.95]`.
- [x] **MonitorNiriSettings** (override struct): remove `singleWindowAspectRatio: SingleWindowAspectRatio?`;
  add `loneWindowPolicy: LoneWindowPolicy?` where `nil` means inherit, `.fill` explicitly overrides to Fill,
  and `.centered(maxWidthFraction:)` explicitly overrides to Centered. Rename `maxVisibleColumns: Int?` to
  `balancedColumnCount: Int?` for the per-monitor balanced count override. **ResolvedNiriSettings**: remove
  `singleWindowAspectRatio`; add `loneWindowPolicy: LoneWindowPolicy`; replace the old count field with
  `defaultColumnWidth: DefaultColumnWidth`.
  Update init and `SettingsStore.resolvedNiriSettings(for:)` merge logic.
- [x] Build and fix compile errors.
- [ ] Ask user to launch app, open Layout settings — verify the panel loads without crash.

### Task 3: Update TOML codecs

**Files:**
- Modify: `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
- Modify: `Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift`

- [x] **CanonicalTOMLConfig.Niri struct** (L60–65): remove `singleWindowAspectRatio: String`;
  add `loneWindowMaxWidth: Double?`. Rename `maxVisibleColumns: Int` to `balancedColumnCount: Int`
  and keep `defaultColumnWidth: Double?`. Remove any CodingKey case for `singleWindowAspectRatio`.
- [x] **`CanonicalTOMLConfig.init(export:)`** (L174–179): map `niriLoneWindowMaxWidth →
  loneWindowMaxWidth`; remove old `singleWindowAspectRatio` line; write `balancedColumnCount`.
- [x] **`CanonicalTOMLConfig.toSettingsExport()`** (L240–245): map `loneWindowMaxWidth →
  niriLoneWindowMaxWidth`. Remove old line.
- [x] **`CanonicalTOMLConfig.init(from decoder:)`** (L366–371): remove `singleWindowAspectRatio`
  decode; add `loneWindowMaxWidth = try container.decodeIfPresent(Double.self, forKey: .loneWindowMaxWidth)`;
  decode `balancedColumnCount`.
- [x] **MonitorOverrideFileStore**: use tri-state `loneWindowPolicy = "fill" | "centered"`
  plus `loneWindowMaxWidth` for centered width. Bare `loneWindowMaxWidth` without
  `loneWindowPolicy = "centered"` is ignored.
- [x] Build and fix compile errors.
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

- [x] **NiriLayoutEngine.swift**: replace `var singleWindowAspectRatio: SingleWindowAspectRatio`
  (L128) with `var loneWindowPolicy: LoneWindowPolicy = .fill`; rename the balanced-count engine field.
  Update `configure(...)` (L332/345).
- [x] **`singleWindowLayoutContext()`**: resolve TODO from Task 1 — apply the lone-window predicate
  for both `.fill` and `.centered(let maxWidthFraction)` from `effectiveLoneWindowPolicy(in:)`;
  store `maxWidthFraction` in the context (`1.0` for `.fill`).
- [x] **NiriLayoutEngine+Monitors.swift**: rename `effectiveSingleWindowAspectRatio(for:)` and
  `effectiveSingleWindowAspectRatio(in:)` to `effectiveLoneWindowPolicy(for:)` / `(in:)`, returning
  `LoneWindowPolicy` from `ResolvedNiriSettings.loneWindowPolicy`. Remove all `SingleWindowAspectRatio`
  references.
- [x] **NiriLayout.swift**: delete `aspectFittedSingleWindowRect()`. Add
  `centeredLoneWindowRect(maxWidthFraction: Double, workingFrame: CGRect) -> CGRect`:
  `let w = workingFrame.width * maxWidthFraction; let x = workingFrame.midX - w/2`.
  Full height (workingFrame). Update `resolvedSingleWindowRect()` to use the new helper for both
  the normal and manual-override paths (manual override stays centered, uncapped by policy).
- [x] **Single-window viewport behavior**: add `SingleWindowViewportGeometry` and make lone-window
  layout/target-frame/gesture/viewport-command paths share it. Side snap points and overscroll must work
  in a one-window workspace; relayout must not reset explicit snapped offsets back to center.
- [x] **`resolvedColumnResetWidth()`**: route default-width resolution through
  `effectiveDefaultColumnWidth(in:) -> DefaultColumnWidth`, backed by
  `ResolvedNiriSettings.defaultColumnWidth`.
- [x] **NiriLayoutEngine+ColumnOps.swift**: use the same `effectiveDefaultColumnWidth(in:).fraction`
  path for move-animation width fallback.
- [x] **NiriLayoutEngine+Sizing.swift L103** and **NiriLayoutEngine+Animation.swift L286–290**:
  update `SingleWindowLayoutContext` usage to use `maxWidthFraction` instead of `aspectRatio`.
- [x] **Reveal Partial / `fillsViewport`** (ViewportCommands.swift L72, L82): if the lone-window
  context is active for the target workspace (centered policy holds), the layout intentionally
  does not fill the viewport — ensure `fillsViewport` returns false in this case so Reveal Partial
  default behavior does not mis-snap.
- [x] **Inner vs outer gaps (secondary axis only)**: stacked-tile gap accounting (`NiriAxisSolver`, tabbed shared-frame solver, `layoutContainer` leading `secondaryGap`, target-frame fallback height) no longer reserves edge padding; gaps are only between adjacent stacked tiles. The primary-axis proportional column formula is unchanged.
- [x] Delete redundant balanced-count helpers; `DefaultColumnWidth` owns width semantics.
- [x] Build and fix compile errors.
- [ ] Ask user to test: set Lone Window to Centered 60%, open a single-window workspace, verify
  the window is narrower and centered; open a second window and verify normal column layout resumes.
  Also verify Reveal Partial scrolling is unaffected.

### Task 5: UI redesign

**Files:**
- Modify: `Sources/Nehir/UI/SettingsView.swift`

- [x] **`GlobalNiriSettingsSection`** (L271–403):
  - Remove the "Visible Columns" `SettingsSliderRow` (L293–306).
  - Remove `Picker("Single Window Width", ...)` and its caption (L308–316).
  - Restructure "Default New Column Width" section:
    - Segmented picker Balanced | Custom (binding to `settings.defaultColumnWidth` mode).
    - Balanced: stepper "Fit N columns" binding to `settings.niriBalancedColumnCount` (1–5).
    - Custom: existing % text field binding to `settings.niriDefaultColumnWidth`.
  - Add `Section("Lone Window")`:
    - Segmented picker Fill | Centered.
    - When Centered: `LabeledContent("Max Width")` text field binding to
      `settings.niriLoneWindowMaxWidth` (in %, 10–95, stored as fraction).
    - Caption: "On a workspace with one window, cap its width and center it."
  - Rename "Column Width Cycle Presets" → "Resize Presets".
- [x] **`MonitorNiriSettingsSection`** (L405–450):
  - Replace `OverridableSlider("Visible Columns", ...)` with an `OverridablePicker`/control for
    the balanced column count (`ms.balancedColumnCount` override, inherits global balanced N).
  - Replace `OverridablePicker("Single Window Width", ...)` with `OverridablePicker("Lone Window", ...)`
    binding to tri-state `ms.loneWindowPolicy` override (`nil` = inherits global, `.fill` = explicit Fill,
    `.centered` = explicit Centered).
- [x] Build and fix compile errors.
- [ ] Ask user to exercise every section: Balanced/Custom toggle, N stepper, Lone Window Centered
  max-width field, per-monitor overrides.

### Task 6: Update glossary

**Files:**
- Modify: `docs/glossary.md`

- [x] Remove `SingleWindowAspectRatio` and old `maxVisibleColumns` entries (if present).
- [x] Add `DefaultColumnWidth` — two modes: balanced (= 1/N columns) and custom (explicit fraction).
- [x] Add `LoneWindowPolicy` — fill vs centered-with-max-width; note the predicate conditions.
- [x] Document column-width resolution precedence (use viewport-schema notation if the file already
  uses that style):
  ```text
  column width resolution (highest wins):
    1. LoneWindowPolicy.fill / .centered — only when lone-window predicate holds
    2. DefaultColumnWidth.custom(fraction)
    3. DefaultColumnWidth.balanced(columns) → 1/N
  ```

### Task 7: Write unit tests (after user confirms feature works)

**Files:**
- Modify: relevant `*Tests.swift` files

- [ ] `DefaultColumnWidth.fraction` computed property (balanced and custom cases).
- [ ] `centeredLoneWindowRect`: width = workingFrame.width × maxWidthFraction, horizontally centered.
- [ ] `resolvedColumnResetWidth` with `.balanced(columns: 3)` returns 1/3.
- [ ] `singleWindowLayoutContext` returns full-width context for `.fill`, capped context for `.centered`.
- [ ] `CanonicalTOMLConfig` encode/decode round-trip: `loneWindowMaxWidth` survives.
- [ ] `fillsViewport` returns false when lone-window centered context is active.
- [ ] Lone-window viewport geometry: center offset, side snap rendering, and target-frame output share the same math.
- [ ] Inner gap semantics (secondary axis): single/tabbed tiles touch the working-frame edge when outer gaps are zero;
  stacked tiles only have gaps between adjacent siblings. Primary-axis column widths still use the
  niri-compatible formula and are intentionally out of scope.
- [ ] Runtime-minimum visible-frame regression: a constrained lone window larger than the inset working
  frame but fitting the monitor visible frame remains onscreen.
- [ ] Run full test suite — all pass before closing this task.

### Task 8: Acceptance and cleanup

- [ ] Verify lone-window centering on a simulated wide workspace.
- [ ] Verify switching Balanced ↔ Custom preserves the stored column count in Balanced.
- [ ] Verify Reveal Partial "Default" scrolls correctly with and without lone-window policy active.
- [ ] Verify per-monitor overrides for both controls.
- [x] Check `docs/IPC-CLI.md` — update if `single_window_aspect_ratio` is documented there. (No exposure found.)
- [ ] Move this plan to `completed/`.

## Post-Completion

- Manual test on an actual ultrawide display (≥ 3440px) at `maxWidthFraction` 0.5, 0.6, 0.75.
- Confirm manual resize of a lone centered window is not capped by `maxWidthFraction` and stays centered.
