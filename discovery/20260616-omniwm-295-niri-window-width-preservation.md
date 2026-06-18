# OmniWM issue #295 — "[Niri] Windows do not keep their current width when moved to another workspace on another screen" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/295>
Scope of this doc: determine whether the issue applies to nehir, and identify
the likely code path to fix.

All file/line references were verified against `worktree-calm-meadow-6229` at
`b7ac7e5` ("Add more issues dicoveries"). Re-verify before implementing; line
numbers drift.

---

## TL;DR

- **Relevant and currently reproducible by code inspection.** Nehir's Niri
  window-to-workspace transfer path creates/claims a target column and resets
  it to the target workspace's default column width instead of preserving the
  moved window's source column width.
- The reset happens in
  `NiriLayoutEngine.moveWindowToWorkspace(...)` via
  `initializeNewColumnWidth(...)`:
  - `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:13-44`
  - `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:223-233`
- For an empty target workspace, the resulting single-window workspace uses the
  target workspace lone-window policy. With the default `.fill` policy, that is
  **100% width**, matching the issue report: a 50% window moved to another
  workspace/screen becomes full width.
- There is an existing regression test that codifies the current reset behavior:
  `moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn` at
  `Tests/NehirTests/NiriLayoutEngineTests.swift:3670-3697`. That test passed
  locally, so the behavior is intentional in current tests but conflicts with
  the issue's expected behavior.
- **Verdict:** issue #295 applies to nehir. A fix should preserve/copy the
  source column's width state when moving an individual window into a newly
  created or claimed target column, with tests updated to reflect the desired
  Niri-compatible behavior.

---

## Upstream issue summary

The reporter describes this scenario:

1. Resize a window to 50% width on workspace A.
2. Move that window to workspace B on another screen.
3. Actual: the moved window becomes 100% width.
4. Expected: the window remains 50%, relative to the current/target screen.

This maps directly onto nehir's Niri column model: window width is effectively
column width for a single-window column/workspace.

---

## User-facing command path in nehir

Moving a window to a workspace on another monitor is handled here:

```swift
// Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:824
func moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction) {
    guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, workspaceIndex) + 1) else { return }
    moveWindowToWorkspaceOnMonitor(rawWorkspaceID: rawWorkspaceID, monitorDirection: monitorDirection)
}
```

The raw-ID overload resolves the adjacent monitor and target workspace, then
transfers the selected/command-target window:

```swift
// Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:829-848
func moveWindowToWorkspaceOnMonitor(rawWorkspaceID: String, monitorDirection: Direction) {
    guard let controller else { return }
    guard let token = controller.managedCommandTargetToken() else { return }
    guard let currentMonitorId = interactionMonitorId(for: controller)
    else { return }
    guard let currentWorkspaceId = controller.workspaceManager.workspace(for: token) else { return }

    guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
        from: currentMonitorId,
        direction: monitorDirection
    ) else { return }

    guard let targetWsId = controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
    else { return }
    guard controller.workspaceManager.monitorId(for: targetWsId) == targetMonitor.id else { return }

    let transferResult = transferWindowFromSourceEngine(
        token: token, from: currentWorkspaceId, to: targetWsId
    )
    guard transferResult.succeeded else { return }
```

`transferWindowFromSourceEngine(...)` delegates to the Niri engine:

```swift
// Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:460-471
if let sourceWsId,
   let engine = controller.niriEngine,
   let windowNode = engine.findNode(for: token)
{
    var sourceState = controller.workspaceManager.niriViewportState(for: sourceWsId)
    var targetState = controller.workspaceManager.niriViewportState(for: targetWsId)
    if let result = engine.moveWindowToWorkspace(
        windowNode,
        from: sourceWsId,
        to: targetWsId,
        sourceState: &sourceState,
        targetState: &targetState
    ) {
```

---

## The problematic engine behavior

`moveWindowToWorkspace(...)` currently detaches the window, creates or claims a
target column, initializes that column with target-workspace defaults, and only
then appends the moved window:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:28-44
let targetRoot = ensureRoot(for: targetWorkspaceId)

let fallbackSelection = fallbackSelectionOnRemoval(removing: window.id, in: sourceWorkspaceId)

window.detach()

let targetColumn: NiriContainer
if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: targetRoot) {
    initializeNewColumnWidth(existingColumn, in: targetWorkspaceId)
    targetColumn = existingColumn
} else {
    let newColumn = NiriContainer()
    initializeNewColumnWidth(newColumn, in: targetWorkspaceId)
    targetRoot.appendChild(newColumn)
    targetColumn = newColumn
}
targetColumn.appendChild(window)
```

The initializer deliberately resets width-related state:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:223-233
func initializeNewColumnWidth(_ column: NiriContainer, in workspaceId: WorkspaceDescriptor.ID) {
    let resolvedWidth = resolvedColumnResetWidth(in: workspaceId)
    column.width = .proportion(resolvedWidth.proportion)
    column.presetWidthIdx = resolvedWidth.presetWidthIdx

    column.cachedWidth = 0
    column.isFullWidth = false
    column.savedWidth = nil
    column.hasManualSingleWindowWidthOverride = false
    column.widthAnimation = nil
    column.targetWidth = nil
}
```

For a default Niri setup, this means:

- target workspace default width often resolves to the balanced/default column
  width, not the source column's manually resized width;
- `hasManualSingleWindowWidthOverride` is cleared;
- in an empty target workspace, the lone-window layout path then ignores the
  column width and uses the target lone-window policy.

The single-window width resolver makes that last step explicit:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:700-707
private func resolvedSingleWindowWidth(
    for context: SingleWindowLayoutContext,
    in workingFrame: CGRect,
    gaps: CGFloat
) -> CGFloat {
    guard context.container.hasManualSingleWindowWidthOverride else {
        return workingFrame.width * CGFloat(context.maxWidthFraction.clamped(to: 0.0 ... 1.0))
    }
```

With the default lone-window policy `.fill`, `maxWidthFraction` is `1.0`, so the
moved window becomes full width after the transfer.

---

## Existing tests confirm the current reset behavior

Nehir already has a test that expects `moveWindowToWorkspace(...)` to use the
**target default** width:

```swift
// Tests/NehirTests/NiriLayoutEngineTests.swift:3670-3697
@Test func moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn() {
    let engine = NiriLayoutEngine(balancedColumnCount: 3)
    engine.presetColumnWidths = [.proportion(0.85), .proportion(1.0), .proportion(0.5)]
    engine.defaultColumnWidth = 0.7
    let sourceWorkspaceId = UUID()
    let targetWorkspaceId = UUID()

    let window = engine.addWindow(handle: makeTestHandle(), to: sourceWorkspaceId, afterSelection: nil)
    var sourceState = ViewportState()
    var targetState = ViewportState()

    let moved = engine.moveWindowToWorkspace(
        window,
        from: sourceWorkspaceId,
        to: targetWorkspaceId,
        sourceState: &sourceState,
        targetState: &targetState
    )

    guard let targetColumn = engine.columns(in: targetWorkspaceId).first else {
        Issue.record("Expected target column after workspace move")
        return
    }

    #expect(moved != nil)
    #expect(targetColumn.width == .proportion(0.7))
    #expect(targetColumn.presetWidthIdx == nil)
}
```

I ran the targeted test locally:

```bash
swift test --filter NiriLayoutEngineTests/moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn
```

It passed, confirming that the current codebase still implements the reset-to-
target-default behavior.

This test likely needs to be replaced or narrowed when fixing #295, because the
new desired behavior is to preserve the moved window/source column width rather
than reset to the target workspace default.

---

## Why moving a whole column is different

`moveColumnToWorkspace(...)` moves the existing `NiriContainer` object to the
target root:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:59-80
column.detach()

targetRoot.appendChild(column)
```

Because the column itself moves, its width fields (`width`, `presetWidthIdx`,
`isFullWidth`, `savedWidth`, `hasManualSingleWindowWidthOverride`, cached/target
width, etc.) are not reinitialized. Therefore this issue is specifically about
moving an **individual window** into a target workspace, not moving a whole
column.

---

## Existing helper that may be relevant

`NiriLayoutEngine+ColumnOps.swift` already contains a private helper for copying
column width state:

```swift
private func copyColumnWidthState(from sourceColumn: NiriContainer, to targetColumn: NiriContainer) {
    targetColumn.width = sourceColumn.width
    targetColumn.presetWidthIdx = sourceColumn.presetWidthIdx
    targetColumn.isFullWidth = sourceColumn.isFullWidth
    targetColumn.savedWidth = sourceColumn.savedWidth
    targetColumn.hasManualSingleWindowWidthOverride = sourceColumn.hasManualSingleWindowWidthOverride
    targetColumn.cachedWidth = 0
    targetColumn.widthAnimation = nil
    targetColumn.targetWidth = nil
}
```

It is currently private to the `ColumnOps` file, so `WorkspaceOps` cannot call
it. A fix could either move/generalize this helper or introduce a workspace-
move-specific equivalent.

The important behavioral point is that preserving a proportional source width
such as `.proportion(0.5)` naturally gives the issue's requested "50% relative
to the current screen" behavior on the target monitor.

---

## Recommended fix direction

Likely change:

1. Capture the source column before detaching the window.
2. When `moveWindowToWorkspace(...)` creates or claims a target column for the
   moved window, copy the source column's width state into that target column
   instead of blindly calling `initializeNewColumnWidth(...)`.
3. Ensure the target column has `hasManualSingleWindowWidthOverride == true`
   when the source width came from an explicit/manual resize, so the single-
   window layout path does not collapse back to `.fill`.
4. Reset animation/cache fields as needed (`cachedWidth = 0`,
   `widthAnimation = nil`, `targetWidth = nil`) so the new monitor's working
   frame resolves the copied proportional width freshly.

Questions to settle during implementation:

- Should this preserve **all** source column widths, or only manual widths?
  The issue asks for preserving a user-resized 50% width. Preserving only when
  `sourceColumn.hasManualSingleWindowWidthOverride` is true may minimize
  behavior changes.
- How should fixed pixel widths behave across monitors of different sizes?
  The issue explicitly says "50% relative to current screen," so proportional
  widths are straightforward. Fixed widths might reasonably remain fixed pixels,
  but that should be decided and tested.
- If the target workspace is non-empty, should the new target column still copy
  the source column width? For Niri-like behavior, probably yes: moving the
  window should preserve its column width independent of target occupancy.

---

## Suggested tests

Add/adjust tests in `Tests/NehirTests/NiriLayoutEngineTests.swift`:

1. **Empty target workspace preserves proportional width**
   - Source column: `.proportion(0.5)`,
     `hasManualSingleWindowWidthOverride = true`.
   - Move window to empty target workspace.
   - Expect target column width `.proportion(0.5)` and manual override true.
   - Calculate layout on a different-width target monitor and expect ~50% of
     that monitor's working width, not 100%.

2. **Claimed empty target column also preserves width**
   - Ensure target root has an empty placeholder column.
   - Move window into it.
   - Expect copied width state, not target default.

3. **Existing current test update**
   - Replace or rewrite
     `moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn`, because
     its current assertion is the behavior reported as a bug.

4. **Whole-column move remains unchanged**
   - Keep coverage that `moveColumnToWorkspace(...)` preserves the original
     column and leaves source/target selection correct.

---

## Verdict

Issue #295 is relevant for nehir and identifies a real behavior mismatch with
expected Niri-style width preservation. The bug is localized to
`NiriLayoutEngine.moveWindowToWorkspace(...)` resetting the target column width
state during individual-window workspace moves. The fix should preserve the
source column's width state for the moved window's new target column and update
existing tests that currently encode the reset-to-default behavior.
