# A1 — Pure Niri engine extraction for onboarding movement/focus

**Status:** completed — shipped on `main` in `b1844dd8` ("Extract pure layout reducer and drive move demo through it"). All five A1 acceptance criteria are met: `Sources/Nehir/Core/PureLayout/` holds the pure model/reducer/invariant code (`PureDirection`, `PureLayoutModels`, `PureLayoutReducer`, `PureLayoutInvariants`) with a clean boundary (no `AppKit`/`AX`/`SkyLight`/runtime-type references); `PureLayoutReducerTests`, `PureLayoutAgreementTests`, and `PureLayoutBoundaryTests` all exist; and `InteractiveMoveDemo.MoveDemoModel` now stores a `CoreWorld<Int, Int>` and delegates focus/move/workspace-switch to `PureLayoutReducer`. The follow-on commits `98d00e4c` ("Route Niri focus and move decisions through pure layout"), `c2915f44` ("Drive Niri window moves from pure layout plans"), and `49d6b3f3` ("Assert Niri layout mutations match pure reducer results") went beyond A1 into the live runtime path — the A2 territory this plan explicitly left as a non-goal — so A1's scope is a strict subset of what landed. (A discovery note already records this landing: `discovery/20260625-upstream-post-roadmap-candidates.md`.) Moved from `planned/` to `completed/` on 2026-06-27.
**Source discovery:** `discovery/20260618-pure-niri-engine-extraction.md`  
**Parent architecture note:** `discovery/20260618-worldstore-pure-engine-reuse.md`  
**Verified against:** main Nehir source tree at `4e54d4a1` on 2026-06-19. Re-verify before editing; line numbers and helper names may drift.

## TL;DR

Extract the first, deliberately small pure Niri core under
`Sources/Nehir/Core/PureLayout/` and make onboarding delegate to it. A1 covers
only the semantics already duplicated by `InteractiveMoveDemo.MoveDemoModel`:

- focus left/right/up/down;
- move left/right using consume-or-expel;
- move up/down within a stack;
- switch workspace in the onboarding model's ordered workspace list.

Do **not** refactor the live runtime command path in A1. The real
`NiriLayoutEngine` is used only as an agreement-test oracle for movement/focus
structure. AX/AppKit/SkyLight frame writes, animation, monitor topology, and
`ViewportState` application remain untouched.

The three known divergences are resolved here as A1 decisions:

1. **Storage convention:** adopt the real engine convention: storage index `0`
   is visual bottom; `.up` means storage index `+1`; `.down` means `-1`.
2. **Consume insertion:** a consumed solo window is inserted at storage index `0`
   in the target column and becomes the active tile.
3. **Edge wrap:** pure reducer has `PureLayoutConfig.infiniteLoop`, default
   `false`; no-wrap is the default onboarding behavior and the default real
   engine behavior.

## Ground rules

- Add files inside the existing `Nehir` target, not a new SwiftPM target. The
  package currently links AppKit/ApplicationServices/Carbon/Metal/SkyLight from
  the `Nehir` target, and shared primitives are not target-split yet.
- Files under `Sources/Nehir/Core/PureLayout/` may import only `Foundation` and,
  if geometry is actually needed later, `CoreGraphics`. For A1 models/reducer,
  prefer `Foundation` only.
- The pure layer must not reference `AppKit`, `ApplicationServices`,
  `AXUIElement`, `SkyLight`, `WindowToken`, `NiriNode`, `NiriLayoutEngine`,
  `ViewportState`, `Monitor`, or `WorkspaceDescriptor`.
- The demo remains SwiftUI/AppKit code; only its layout semantics move behind a
  pure reducer.
- Do not port upstream `WorldStore`, `EventIntake`, `IntentLedger`,
  `DeadlineWheel`, or `SurfaceReconciler`.

## Existing seams to re-verify

- `Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift`
  - `MoveDemoModel` owns local `Window`, `Column`, `Workspace` structs and local
    focus state.
  - `focusUp()` currently decrements the array index; `focusDown()` increments.
  - `moveFocusedWindow(direction:)` expels stacked windows into a new solo column
    and consumes solo windows into a neighbor with `append`.
  - `moveFocusedWindowVertical(direction:)` swaps array indices by `direction`.
  - `switchWorkspace(by:)` is bounded and resets focus/scroll to the destination.
  - `columnView` renders `ForEach(column.windows)` top-to-bottom.
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WindowOps.swift`
  - `moveWindowVertical(.up)` uses `nextSibling()`; `.down` uses `prevSibling()`.
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift`
  - `consumeOrExpelWindow` sends stacked columns through `expelWindow`.
  - solo-window consume uses `moveWindowToColumn(..., targetInsertionPolicy: .visualBottom,
    activateInsertedWindowInTarget: true)`.
  - `.visualBottom` returns insertion index `0`.
- `Sources/Nehir/Core/Layout/Niri/NiriNode.swift`
  - documents: storage index `0` is visual bottom; overlay index `0` is visual top.
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift`
  - `wrapIndex` honors effective `infiniteLoop`; default engine init has
    `infiniteLoop: false`.
- Existing test helpers live in `Tests/NehirTests/NiriLayoutEngineTests.swift`,
  including `makeTestHandle`, monitor fixtures, and simple manual root/column
  construction patterns.

## Pure model shape

Create these files:

- `Sources/Nehir/Core/PureLayout/PureDirection.swift`
- `Sources/Nehir/Core/PureLayout/PureLayoutModels.swift`
- `Sources/Nehir/Core/PureLayout/PureLayoutReducer.swift`
- `Sources/Nehir/Core/PureLayout/PureLayoutInvariants.swift`

Recommended A1 API:

```swift
enum PureDirection: Equatable {
    case left, right, up, down

    var horizontalStep: Int? { get } // left -1, right +1
    var verticalStorageStep: Int? { get } // down -1, up +1
}

struct PureLayoutConfig: Equatable {
    var infiniteLoop: Bool = false
}

struct CoreColumnID: Hashable, Equatable {
    var rawValue: Int
}

struct CoreWindow<ID: Hashable>: Equatable {
    var id: ID
}

struct CoreColumn<ID: Hashable>: Equatable {
    var id: CoreColumnID
    /// Storage order, not visual order. Index 0 is visual bottom.
    var windows: [CoreWindow<ID>]
    /// Storage index of the active/focused tile within this column.
    var activeWindowIndex: Int
}

struct CoreWorkspace<WSID: Hashable, ID: Hashable>: Equatable {
    var id: WSID
    var columns: [CoreColumn<ID>]
    /// Nil only when the workspace has zero columns/windows.
    var activeColumnIndex: Int?
}

struct CoreWorld<WSID: Hashable, ID: Hashable>: Equatable {
    var workspaces: [CoreWorkspace<WSID, ID>]
    var activeWorkspaceIndex: Int
    var nextColumnID: Int
    var config: PureLayoutConfig
}
```

Why this shape:

- `activeWindowIndex` mirrors the real engine's `NiriContainer.activeTileIdx` and
  lets horizontal focus choose the target column's active tile rather than always
  the first item.
- `CoreColumnID` gives the demo stable `Identifiable` column ids and lets the
  reducer create expel columns without knowing about `NiriContainer`.
- `nextColumnID` keeps expel-column id generation deterministic and pure.
- Empty workspaces are represented as `columns == []` and
  `activeColumnIndex == nil`. A1 does not implement add/remove-window commands,
  so it does not need the real engine's empty-column claiming behavior.

Convenience computed properties are useful but should stay pure:

```swift
extension CoreWorkspace {
    var activeColumn: CoreColumn<ID>? { get }
    var focusedWindowID: ID? { get }
}
```

## Reducer semantics

All reducer entry points return a new world or mutate `inout`; choose one style
and keep it consistent. The easiest test shape is pure return values:

```swift
enum PureLayoutReducer {
    static func focus<WSID, ID>(
        _ direction: PureDirection,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID>

    static func moveFocusedWindow<WSID, ID>(
        _ direction: PureDirection,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID>

    static func switchWorkspace<WSID, ID>(
        by delta: Int,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID>

    static func focusWindow<WSID, ID>(
        columnIndex: Int,
        windowStorageIndex: Int,
        in world: CoreWorld<WSID, ID>
    ) -> CoreWorld<WSID, ID>
}
```

### Focus left/right

- Resolve the active workspace and active column.
- Target column index is `activeColumnIndex ± 1`.
- If target is outside bounds:
  - wrap only when `world.config.infiniteLoop == true`;
  - otherwise return `world` unchanged.
- Clamp target column's `activeWindowIndex` into its window range.
- Set `activeColumnIndex` to target.
- Preserve all structure.

### Focus up/down

- Use storage convention:
  - `.up` → `activeWindowIndex + 1`;
  - `.down` → `activeWindowIndex - 1`.
- If outside column bounds, return unchanged.
- Update only the active column's `activeWindowIndex`.

### Move left/right — expel branch

When the active column contains more than one window:

1. Remove the active window from the source column.
2. Clamp the source column's `activeWindowIndex` after removal.
3. Create a new column with `id = CoreColumnID(rawValue: world.nextColumnID)`,
   `windows = [movedWindow]`, and `activeWindowIndex = 0`.
4. Increment `nextColumnID`.
5. Insert the new column on the moved-toward side:
   - `.right`: after the source column;
   - `.left`: before the source column.
6. Focus the new column and moved window.
7. Validate invariants.

### Move left/right — consume branch

When the active column contains exactly one window:

1. Resolve neighbor index with the same no-wrap/wrap policy as focus.
2. If no neighbor, return unchanged.
3. Remove the source column.
4. Resolve the target column's index after source removal:
   - moving right: neighbor was `source + 1`, then shifts to `source`;
   - moving left: neighbor was `source - 1`, remains `source - 1`;
   - wrapped moves need the same remove-then-find-by-column-id approach to avoid
     index mistakes.
5. Insert the moved window at storage index `0` of the target column
   (visual bottom).
6. Set target column `activeWindowIndex = 0` so the consumed window is active.
7. Focus the target column.
8. Validate invariants.

### Move up/down

- Resolve storage step using the real convention (`up = +1`, `down = -1`).
- If target index is out of bounds, return unchanged.
- Swap the active window with the target storage index.
- Set `activeWindowIndex` to the target index so the moved window stays focused.

### Switch workspace

For A1, mirror the onboarding behavior, not the full runtime workspace manager:

- `delta` is bounded by `workspaces.indices` unless a later explicit config says
  otherwise. Do not wrap workspaces in A1.
- Set `activeWorkspaceIndex` to the destination.
- Set destination focus to the first column and that column's visual top tile for
  visual continuity. Because storage index `0` is visual bottom, visual top is
  `windows.count - 1`.
- If the destination has no windows, set `activeColumnIndex = nil`.
- The demo still owns scroll reset (`scrollX = 0`) outside the reducer.

## Invariants

`PureLayoutInvariants.validate(_:)` should return `[PureLayoutInvariantViolation]`
or throw; tests can assert the result is empty.

Required checks:

- `activeWorkspaceIndex` is in bounds when `workspaces` is non-empty.
- A non-empty workspace has `activeColumnIndex` in bounds; an empty workspace has
  `activeColumnIndex == nil`.
- No column with `windows.isEmpty` exists.
- Every non-empty column has `activeWindowIndex` in bounds.
- Window ids are unique within the whole world.
- Column ids are unique within a workspace.
- `nextColumnID` is greater than every integer `CoreColumnID.rawValue` generated
  by the demo seed path.

Run the invariant validator in reducer tests after every command. In production
reducer code, prefer debug assertions rather than fatal runtime behavior.

## Phase 1 — Add pure core and reducer tests only

No call-site changes yet.

Add `Tests/NehirTests/PureLayoutReducerTests.swift` with command-level tests:

1. `focusHorizontalMovesBetweenColumnsWithoutChangingStructure`
2. `focusHorizontalDoesNotWrapByDefaultAtEdges`
3. `focusHorizontalWrapsWhenInfiniteLoopEnabled`
4. `focusVerticalUsesStorageBottomConvention`
5. `moveVerticalSwapsWithStorageUpAndDown`
6. `moveHorizontalExpelsStackedWindowIntoNewColumnOnDirectionSide`
7. `moveHorizontalConsumesSoloWindowIntoNeighborVisualBottom`
8. `moveHorizontalDoesNotConsumePastEdgeByDefault`
9. `moveHorizontalWrapsAtEdgeWhenInfiniteLoopEnabled`
10. `switchWorkspaceSelectsDestinationFirstVisibleTile`
11. `invariantsRejectEmptyColumnsDuplicateWindowIDsAndInvalidFocus`

Use tiny worlds such as:

```swift
// Visual top is the last storage element.
// Column A visual: [A2, A1], storage: [A1, A2]
columns: [
    CoreColumn(id: .init(rawValue: 0), windows: [A1, A2], activeWindowIndex: 1),
    CoreColumn(id: .init(rawValue: 1), windows: [B1], activeWindowIndex: 0)
]
```

## Phase 2 — Add real-engine agreement tests

Add `Tests/NehirTests/PureLayoutAgreementTests.swift`. The tests should not use
AX frames or controller command paths; they build a minimal real `NiriLayoutEngine`
state and compare only structural outcomes.

Agreement snapshot shape:

```swift
struct AgreementSnapshot<ID: Hashable & Equatable>: Equatable {
    var columns: [[ID]]        // real storage order; index 0 visual bottom
    var activeColumnIndex: Int?
    var focusedWindowID: ID?
}
```

Harness outline:

- Build a pure `CoreWorld<UUID, WindowToken>` and a real `NiriLayoutEngine` from
  the same storage-order fixture.
- Real engine setup can manually create `NiriRoot`, `NiriContainer`, and
  `NiriWindow` nodes, append them in storage order, set `activeTileIdx`, and
  register `engine.tokenToNode[token] = window`.
- For focus commands:
  - pure: `PureLayoutReducer.focus`;
  - real: call `engine.focusTarget(...)`, then set `ViewportState.selectedNodeId`
    to the returned node id.
- For move commands:
  - pure: `PureLayoutReducer.moveFocusedWindow`;
  - real: find the selected `NiriWindow` and call `engine.moveWindow(...)` with a
    simple `workingFrame` and gap.
- Before focus/move calls that need widths, resolve/cache simple column widths as
  existing `NiriLayoutEngineTests` do.
- Compare only:
  - column count;
  - window-token order per column in storage order;
  - focused token;
  - active column index if it is stable for the command.
- Do **not** assert animation displacement, scroll offsets, `selectionProgress`,
  `viewOffsetPixels`, frame writes, hidden/tabbed visibility, or monitor state.

Agreement scripts to cover:

1. focus left/right in a three-column world;
2. focus up/down in a stacked column;
3. move up/down in a stacked column;
4. expel left/right from a stacked column;
5. consume left/right from a solo column into a neighbor;
6. no-wrap edge consume/focus with `infiniteLoop == false`;
7. wrap edge consume/focus with `infiniteLoop == true`.

During implementation, it is acceptable to land the first version of these tests
as known failures to expose the three divergences. The final A1 changeset should
remove known-failure markers; agreement tests must be green.

## Phase 3 — Refactor onboarding to delegate to the pure reducer

Change `MoveDemoModel` so movement/focus/workspace semantics are stored in a
`CoreWorld<Int, Int>` and executed through `PureLayoutReducer`.

Recommended model split:

- Keep local UI-only structs `Window`, `Column`, `Workspace` as derived view
  DTOs if that minimizes SwiftUI churn.
- Store symbols outside the core, for example `private var symbolsByWindowID:
  [Int: String]`.
- Replace `@Published private(set) var workspaces`, `currentWorkspaceIndex`,
  `focusedColumnId`, and `focusedWindowId` with one published core field:

```swift
@Published private var world: CoreWorld<Int, Int>
```

and computed compatibility properties:

```swift
var workspaces: [Workspace] { /* map core storage to UI DTOs */ }
var currentWorkspaceIndex: Int { world.activeWorkspaceIndex }
var focusedColumnId: Int { /* active column id rawValue */ }
var focusedWindowId: Int { /* active column active window id */ }
```

If keeping the existing published properties is less invasive, update them from
core after each reducer call, but do not keep independent semantic state that can
drift.

### Preserve visual order

The demo currently renders each column top-to-bottom with `ForEach(column.windows)`.
After adopting real storage order, storage index `0` is visual bottom. Preserve
the visual layout by flipping at the boundary:

- initialize existing stacked demo columns in storage-bottom order, or convert
  legacy arrays with `reversed()` when building `CoreWorld`;
- render stacked tiles with visual order (`column.windows.reversed()` if the UI
  DTO exposes storage order);
- map vertical hit-test visual index to storage index using
  `storageIndex = count - 1 - visualIndex`;
- `focusColumn(_:)` should focus the first visible tile, which is storage
  `count - 1`, unless the target column already has an active tile that should be
  preserved for horizontal focus.

### Delegate methods

Replace method bodies with reducer calls plus UI side effects:

- `focusLeft/right/up/down` → `PureLayoutReducer.focus`.
- `moveFocusedWindow(direction:)` → map `-1/+1` to `.left/.right`, then
  `moveFocusedWindow`.
- `moveFocusedWindowVertical(direction:)` → map existing demo direction to pure
  direction carefully:
  - old `direction == -1` was visual up;
  - pure `.up` is storage `+1`.
- `switchWorkspace(by:)` → `PureLayoutReducer.switchWorkspace`, plus `scrollX = 0`.
- `focusWindow(columnId:index:)` and `resolveHit(...)` → convert column id and
  visual index to reducer `columnIndex` and storage index.

Keep these UI behaviors outside the reducer:

- `scrollX`, `scrollCentering`, `ensureFocusedVisible`;
- drag state and column reorder helpers;
- palette open/selection;
- animation transactions;
- SwiftUI rendering and shortcuts;
- three-finger gesture tap plumbing.

`reorderColumn(columnId:by:)` can remain demo-local in A1. It is a UI teaching
interaction, not part of real consume-or-expel semantics.

## Phase 4 — Demo regression tests

Add or update onboarding-focused tests if the project has SwiftUI/model tests.
At minimum add model-level tests that do not require rendering:

1. initial demo snapshot matches the pre-refactor visible column/window order;
2. clicking/focusing a stacked window maps visual index to the correct storage
   index;
3. `move.up` and `move.down` produce the same visible order as before the
   storage flip;
4. consume into a stacked neighbor visually places the consumed window at the
   bottom, matching real storage index `0`;
5. workspace switch still resets scroll and selects the first visible tile.

If screenshot or scene tests exist, add one compact before/after check for the
initial onboarding step and a stacked-column move. If no screenshot harness
exists, do not build one just for A1; use deterministic model snapshots.

## Phase 5 — Guard the pure boundary

Add a test or script-level guard. A Swift Testing test is preferable because it
runs in CI without relying on shell negation details:

- `Tests/NehirTests/PureLayoutBoundaryTests.swift`
- Read files under `Sources/Nehir/Core/PureLayout/`.
- Fail if the content contains any forbidden token:
  - `import AppKit`
  - `import ApplicationServices`
  - `AXUIElement`
  - `SkyLight`
  - `WindowToken`
  - `NiriNode`
  - `NiriLayoutEngine`
  - `ViewportState`
  - `WorkspaceDescriptor`
  - `Monitor.` / `Monitor(`

Keep the shell validation too:

```bash
! rg -n 'import AppKit|import ApplicationServices|AXUIElement|SkyLight|WindowToken|NiriNode|NiriLayoutEngine|ViewportState|WorkspaceDescriptor|\bMonitor\b' Sources/Nehir/Core/PureLayout
```

## Acceptance

- `Sources/Nehir/Core/PureLayout/` exists and contains only pure model/reducer/
  invariant code.
- Boundary guard passes: no AppKit/AX/SkyLight/runtime type references in the
  pure directory.
- `PureLayoutReducerTests` pass and cover focus, move, edge wrapping,
  workspace switching, and invariant failures.
- `PureLayoutAgreementTests` pass against `NiriLayoutEngine` for the A1 command
  scripts and compare structure/focus only.
- `MoveDemoModel` no longer contains independent implementations of:
  - focus left/right/up/down;
  - consume-or-expel left/right;
  - vertical stack swap up/down;
  - workspace index switching.
- The onboarding demo remains visually unchanged after the storage-order flip:
  visible stacked order and keyboard/palette/gesture outcomes match the old demo.
- No production AX frame-write path, controller command path, or live runtime
  `NiriLayoutEngine` behavior is refactored in A1.

## Validation

```bash
swift build
swift test --filter PureLayoutReducerTests
swift test --filter PureLayoutAgreementTests
swift test --filter PureLayoutBoundaryTests
swift test --filter NiriLayoutEngineTests

# Boundary guard, useful locally even if a Swift test also exists:
! rg -n 'import AppKit|import ApplicationServices|AXUIElement|SkyLight|WindowToken|NiriNode|NiriLayoutEngine|ViewportState|WorkspaceDescriptor|\bMonitor\b' Sources/Nehir/Core/PureLayout
```

Manual onboarding check:

1. Open the onboarding move/shortcut step.
2. Confirm the initial stacked column looks unchanged.
3. Use keyboard, palette, click, and three-finger gesture paths for:
   - focus left/right/up/down;
   - move left/right;
   - move up/down;
   - previous/next workspace.
4. Confirm scroll/highlight animations still move together.

## Risks and mitigations

- **R-A1.1 — Visual stack flip regression (HIGH).** The core changes storage
  order, while SwiftUI renders visually. Mitigate by reversing at render/hit-test
  boundaries and adding model snapshot tests for visible order.
- **R-A1.2 — Agreement harness overreaches (MED).** Real `NiriLayoutEngine`
  includes animation, viewport, tabbed mode, sizing, and monitor details. Mitigate
  by comparing only structure/focus and using non-tabbed, fixed-width fixtures.
- **R-A1.3 — Workspace-switch semantics are not real runtime semantics (MED).**
  A1 switch support is for onboarding's ordered fake workspaces only. Do not use
  it as a `WorkspaceManager` replacement.
- **R-A1.4 — Pure model grows runtime tentacles (MED).** Enforce the boundary
  with a CI test and keep runtime adapters outside `PureLayout/`.
- **R-A1.5 — Column id generation leaks demo assumptions (LOW).** A1 uses
  integer `CoreColumnID` for deterministic demo expel columns. If the real
  runtime consumes the core in A2, revisit column identity before wiring it into
  production.

## Explicit non-goals

- No new SwiftPM target in A1.
- No `WorldStore` port.
- No effect-plan interpreter yet; that is A2.
- No live runtime command-path refactor.
- No AX frame-write, focus-request, monitor, Space topology, or `ViewportState`
  behavior changes.
- No tabbed/overflow-tabbed semantics in the pure reducer.
- No sizing, constraints, preset widths, balanced columns, fullscreen, scratchpad,
  or hotkey/palette modeling in the pure reducer.

## Follow-up after A1

Proceed to A2 only after reducer tests, agreement tests, and onboarding visual
checks are green. A2 may introduce a narrow pure `LayoutPlan`/`LayoutEffect`
boundary for one command path, with real-runtime and demo interpreters. If A1
requires many runtime-specific exceptions, pause the architecture track and
record that the current Niri semantics are still too coupled for safe extraction.
