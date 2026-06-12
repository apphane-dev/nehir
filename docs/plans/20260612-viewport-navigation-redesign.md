# Viewport Navigation Redesign

## Overview

Implement the design specified in `docs/viewport-navigation-spec.md`. Replaces three loosely
coupled settings (`CenterFocusedColumn`, `AlwaysCenterSingleColumn`, `ScrollReveal`) and
ad-hoc reveal logic with a unified snap grid and a visibility-state-based reveal policy.
Adds two new `scrollViewport(.left/.right)` commands that step through snap points.

Key benefits:
- Centering emerges naturally from the snap grid — no dedicated toggle needed
- Reveal behaviour is predictable: determined by what the user can see, not what triggered focus
- Keyboard users can opt out of auto-reveal for clipped columns (`revealPartial = .off`)

## Context (from discovery)

- **Primary files:** `ViewportState+Gestures.swift`, `ViewportState+Geometry.swift`,
  `ViewportState+ColumnTransitions.swift`, `NiriNavigation.swift`,
  `NiriLayoutEngine+ViewportCommands.swift`, `AXEventHandler.swift`,
  `MouseEventHandler.swift`, `NiriLayoutEngine.swift`
- **Settings files:** `SettingsStore.swift`, `SettingsExport.swift`,
  `CanonicalTOMLConfig.swift`, `MonitorNiriSettings.swift`, `BehaviorSettingsTab.swift`,
  `WMController.swift`
- **Command plumbing:** `HotkeyCommand.swift`, `IPCModels.swift`, `ActionCatalog.swift`,
  `CommandHandler.swift`
- Snap logic today lives in `findSnapPointsAndTarget` (`ViewportState+Gestures.swift`) —
  per-column `snapPair(left, right)` with center-on-overflow; does not match the spec grid
- Reveal today is triggered in `AXEventHandler.focusConfirmed` (policy check) and inline in
  `NiriNavigation.ensureSelectionVisible` → `ViewportState.ensureContainerVisible`; both
  dispatch through `CenterFocusedColumn` in `computeVisibleOffset`
- FFM already passes `ensureVisible: false, preserveViewportAnchor: true` to `activateNode`;
  no AX-confirm scroll guard specific to FFM exists beyond `scrollReveal == .keyboardAndCommands`
- No "clipped" column state exists today — only `ContainerVisibilityState.visible / .hidden(edge)`

## Development Approach

- **Testing approach:** Regular (code first, then tests)
- Complete each task fully before moving to the next
- Make small, focused changes — compile after each task
- Tests are required for each task before moving on
- All tests must pass before starting next task

## Testing Strategy

- **Unit tests:** required for snap grid computation, column visibility helper, reveal decision
- **Manual / integration:** gesture snap, scrollViewport commands, reveal scenarios from the
  spec's Use Cases section (see Verification section below)

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix

## Solution Overview

Four phases, each independently shippable:

1. **Snap grid** — new per-column {left-edge, right-edge, center (>30%)} grid replaces
   `findSnapPointsAndTarget`; shared helper used by gesture release and scrollViewport commands
2. **`scrollViewport` commands** — step through snap points; park active column when it
   becomes hidden, transfer focus to nearest visible column
3. **Visibility-based reveal** — `ColumnVisibility` helper, `RevealPartial` setting, FFM
   source tracking, updated keyboard-nav and AX-confirm reveal paths
4. **Settings cleanup** — remove three obsolete settings/enums, add `revealPartial` picker,
   delete dead code paths

## Technical Details

### New types

```swift
// SnapGrid.swift (or ViewportState+Geometry.swift)
struct SnapPoint {
    let offset: CGFloat
    let columnIndex: Int
    enum Kind { case leftEdge, rightEdge, center }
    let kind: Kind
}

// NiriLayoutEngine.swift
enum RevealPartial: String, CaseIterable, Codable { case off, snapClosest, snapCenter }

// ViewportState+Geometry.swift (or NiriLayout.swift)
enum ColumnVisibility {
    case fullyVisible
    case clipped(AxisHideEdge)
    case parked(AxisHideEdge)
}
```

### Snap grid rules

`computeSnapGrid(columns:gap:viewportWidth:) -> [SnapPoint]`:
- Left-edge snap: `offset = columnX`
- Right-edge snap: `offset = columnX + columnWidth - viewportWidth`
- Center snap: only when `columnWidth > 0.30 * viewportWidth`; `offset = columnX + columnWidth/2 - viewportWidth/2`
- Sort by offset, deduplicate within pixel tolerance

### Column visibility classification

`columnVisibility(for index:columns:gap:viewportOffset:viewportWidth:) -> ColumnVisibility`:
- If `ContainerVisibilityState == .hidden(edge)` → `.parked(edge)`
- Else if column rect fully inside viewport → `.fullyVisible`
- Else → `.clipped(edge)`

### Reveal decision table

| Target visibility | Source | Action |
|---|---|---|
| `fullyVisible` | any | no-op |
| `parked` | any | animate to closest snap |
| `clipped` | FFM | no-op |
| `clipped` | non-FFM + `.off` | no-op |
| `clipped` | non-FFM + `.snapClosest` | animate to closest snap |
| `clipped` | non-FFM + `.snapCenter` | animate to center snap |

### FFM source tracking

Add `pendingFFMFocusToken: WindowToken? = nil` to `ViewportState`.
Set in `activateFocusFollowsMouseTarget` before `activateNode`; read and cleared in
`AXEventHandler.focusConfirmed`.

---

## Implementation Steps

### Task 1: Snap grid helper

**Files:**
- Create or modify: `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift`

- [ ] add `SnapPoint` struct with `offset`, `columnIndex`, `Kind` (leftEdge/rightEdge/center)
- [ ] implement `computeSnapGrid(columns:gap:viewportWidth:)` producing sorted, deduplicated snap points per the rules above
- [ ] add `closest(to offset:)` and `next(after offset: direction:)` helpers on `[SnapPoint]`
- [ ] write unit tests for `computeSnapGrid` covering: left/right edge snaps, center snap present when width > 30%, center snap absent when width == 30%, deduplication, strip with mixed-width columns
- [ ] run tests — must pass before Task 2

### Task 2: Update gesture release to use new snap grid

**Files:**
- Modify: `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift`

- [ ] replace `findSnapPointsAndTarget` body with a call to `computeSnapGrid`, then pick the snap point nearest to `projectedViewPos`
- [ ] derive `activeColumnIndex` from the winning `SnapPoint.columnIndex`
- [ ] keep `endGesturePreservingCurrentOffset` path unchanged (modifier-bypass)
- [ ] verify `correctedGestureTargetOffset` / spring animation still wired correctly
- [ ] write or update tests for gesture-snap-to-nearest covering: snap to left-edge, snap to right-edge, snap to center, no snap (preserving offset)
- [ ] run tests — must pass before Task 3

### Task 3: `scrollViewport` commands — plumbing

**Files:**
- Modify: `Sources/Nehir/Core/Input/HotkeyCommand.swift`
- Modify: `Sources/Nehir/IPC/IPCModels.swift` (or wherever `IPCCommandName` lives)
- Modify: `Sources/Nehir/Core/Input/ActionCatalog.swift`
- Modify: `Sources/Nehir/Core/Controller/CommandHandler.swift`

- [ ] add `.scrollViewportLeft` and `.scrollViewportRight` cases to `HotkeyCommand`
- [ ] add corresponding IPC command names
- [ ] register default bindings `Cmd+Option+[` and `Cmd+Option+]` in `ActionCatalog`
- [ ] add handler in `CommandHandler` calling `niriLayoutHandler.scrollViewport(direction:)`
- [ ] run tests — must pass before Task 4

### Task 4: `scrollViewport` — layout engine implementation

**Files:**
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`

- [ ] implement `scrollViewport(direction:)`:
  1. call `computeSnapGrid` for the active workspace
  2. find snap nearest to current `viewOffsetPixels.current()`
  3. step to next snap in requested direction (clamp at strip edges if none)
  4. check if active column becomes `.hidden(edge)` at new offset → transfer `activeColumnIndex` to nearest visible column
  5. animate to new offset via `animateToOffset`
  6. call `syncViewportSelectionToActiveColumn`
- [ ] write tests for: step right advances snap, step left retreats snap, focus transfers when active column parks, clamps at strip edges
- [ ] run tests — must pass before Task 5

### Task 5: Column visibility helper + `RevealPartial` enum

**Files:**
- Modify: `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift`

- [ ] add `ColumnVisibility` enum (`.fullyVisible`, `.clipped(AxisHideEdge)`, `.parked(AxisHideEdge)`)
- [ ] implement `columnVisibility(for index:columns:gap:viewportOffset:viewportWidth:)`
- [ ] add `RevealPartial` enum (`.off`, `.snapClosest`, `.snapCenter`) to `NiriLayoutEngine.swift`
- [ ] add `revealPartial: RevealPartial` property to `NiriLayoutEngine`
- [ ] write unit tests for `columnVisibility` covering: fully visible, clipped left, clipped right, parked left, parked right
- [ ] run tests — must pass before Task 6

### Task 6: FFM source tracking

**Files:**
- Modify: `Sources/Nehir/Core/Layout/Niri/ViewportState.swift`
- Modify: `Sources/Nehir/Core/Controller/MouseEventHandler.swift`

- [ ] add `pendingFFMFocusToken: WindowToken? = nil` to `ViewportState`
- [ ] in `activateFocusFollowsMouseTarget`, set `state.pendingFFMFocusToken = target.token` immediately before calling `activateNode`
- [ ] run tests — must pass before Task 7

### Task 7: Visibility-based reveal — AX confirm path

**Files:**
- Modify: `Sources/Nehir/Core/Controller/AXEventHandler.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`

- [ ] add `scrollToReveal(columnIndex:snapGrid:isFFM:state:)` to `NiriLayoutEngine+ViewportCommands.swift` implementing the reveal decision table above
- [ ] in `AXEventHandler.focusConfirmed`, read and clear `pendingFFMFocusToken` to determine `isFFM`
- [ ] replace the `FocusRevealPolicy` block with a call to `scrollToReveal`; keep existing guards (gesture in progress, `allowsSelectionOffscreen`)
- [ ] write tests for `scrollToReveal` covering all rows of the decision table
- [ ] run tests — must pass before Task 8

### Task 8: Visibility-based reveal — keyboard nav path

**Files:**
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/ViewportState+ColumnTransitions.swift`

- [ ] replace the `state.ensureContainerVisible` call in `ensureSelectionVisible` with `scrollToReveal(columnIndex:..., isFFM: false, state:)`
- [ ] `CenterFocusedColumn` dispatch in `computeVisibleOffset` is no longer called from this path — confirm no other callers; delete or leave for Task 9
- [ ] run tests — must pass before Task 9

### Task 9: Settings cleanup

**Files:**
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsStore.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsExport.swift`
- Modify: `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
- Modify: `Sources/Nehir/Core/Layout/MonitorNiriSettings.swift`
- Modify: `Sources/Nehir/UI/BehaviorSettingsTab.swift`
- Modify: `Sources/Nehir/Core/Controller/WMController.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift`

- [ ] remove `CenterFocusedColumn` enum + `centerFocusedColumn` property from `NiriLayoutEngine`
- [ ] remove `alwaysCenterSingleColumn` property from `NiriLayoutEngine`
- [ ] remove `FocusRevealPolicy` enum from `NiriLayoutEngine.swift`
- [ ] remove `niriScrollReveal`, `niriCenterFocusedColumn`, `niriAlwaysCenterSingleColumn` from `SettingsStore`
- [ ] remove corresponding fields from `SettingsExport` and `CanonicalTOMLConfig` (silently ignored on read for migration compat — add a comment)
- [ ] remove `centerFocusedColumn` and `alwaysCenterSingleColumn` from `ResolvedNiriSettings`
- [ ] add `SettingsStore.revealPartial: RevealPartial = .snapClosest`
- [ ] add `updateNiriConfig(revealPartial:)` path through `WMController` → `NiriLayoutHandler` → `engine.revealPartial`
- [ ] delete `computeVisibleOffset` (now dead code) from `ViewportState+Geometry.swift`
- [ ] update `BehaviorSettingsTab`: remove three obsolete pickers; add `revealPartial` picker; rename "Right Mouse Resize Modifier" → "Mouse Modifier"
- [ ] fix all resulting compiler errors
- [ ] run tests — must pass before Task 10

### Task 10: Verify acceptance criteria

- [ ] gesture snap: fast trackpad scroll lands on column edge or center snap, never between columns
- [ ] center snap threshold: column at exactly 30% of viewport → no center snap; column at 31% → center snap present
- [ ] `Cmd+Option+]` steps right through snaps; active column parks and focus transfers at the correct step
- [ ] reveal — parked: keyboard-navigate to fully offscreen column → viewport scrolls to closest edge snap
- [ ] reveal — clipped + FFM: move cursor to visible portion of clipped column → focus changes, viewport stays
- [ ] reveal — clipped + keyboard + `revealPartial=.off` → no scroll
- [ ] reveal — clipped + keyboard + `revealPartial=.snapCenter` → viewport centers on target column
- [ ] Settings UI: only `Reveal Partial` picker appears in Navigation section (no CenterFocusedColumn, AlwaysCenterSingleColumn, or ScrollReveal)
- [ ] run full test suite

### Task 11: Update documentation

- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Test all Use Cases from `docs/viewport-navigation-spec.md` with real windows on a physical display
- Verify TOML config round-trip: old config with `center-focused-column` / `scroll-reveal` loads without crash and ignores the removed keys
- Verify `revealPartial` persists correctly across app restarts
