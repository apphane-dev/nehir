# Resize Command Target Discovery

Date: 2026-07-13

## Question

Why did the column-width commands resize and reveal a window that was outside the
current viewport instead of the visible column the user expected?

## Executive answer

The commands did not choose a target from the viewport contents. They chose the
Niri workspace's `selectedNodeId`.

At the problematic invocation, workspace state had diverged:

- the viewport was parked around columns 2–4 with `activeColumnIndex=3` and
  `currentViewStart=2536.5`;
- the visible interaction preference was window `47320`;
- `selectedNodeId` and confirmed managed focus pointed to VS Code Insiders window
  `47324` in column 5;
- column 5 began at logical x `5085.0`, and window `47324` was physically parked
  offscreen right at x `2055` beside the `{{8,7},{2040,1251}}` viewport.

`cycleSize(forward:)` trusts `selectedNodeId`, finds its containing column, and
passes that column to the sizing engine. It does not consult
`activeColumnIndex`, `preferredWorkspaceFocusToken`, or viewport visibility
(`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1836-1852`). The engine
then deliberately ensures that resized column is visible, which explains the
large viewport jump after the command
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:265-340`).

The surprising behavior therefore has two parts:

1. **Immediate cause:** resize targeting means “the stored selected Niri node,”
   not “the visible/active column.”
2. **Precondition:** focus-validation state had restored the old confirmed
   window as `selectedNodeId` without moving `activeColumnIndex` or the viewport,
   leaving an offscreen selection. The trace proves the state transition. The
   source contains a focus-validation path with exactly those write semantics,
   although the standard-verbosity capture does not attribute the transition to
   a specific caller.

## What happened

All values below are copied into this document so the finding does not depend on
an external trace file.

### 1. Window `47324` was initially selected and visible

VS Code Insiders window `WindowToken(pid: 35186, windowId: 47324)` was admitted
into workspace `D8ECBE1E-DB12-49EB-A643-93701DB1320D` as column 5. At that time:

```text
activeColumnIndex=5
currentViewStart=4062.0
selected=w47324
preferredFocus=WindowToken(pid: 35186, windowId: 47324)
confirmedFocus=WindowToken(pid: 35186, windowId: 47324)
```

The first two commands were consistent with that state:

```text
cmd=1 kind=toggleColumnWidth(forward) columnIndex=5 window=47324
previous=1011.0 newSpec=proportion(0.6500) targetPixels=1316.1

cmd=2 kind=toggleColumnWidth(forward) columnIndex=5 window=47324
previous=1316.1 newSpec=proportion(0.9500) targetPixels=1926.3
```

After command 2 the viewport settled at `currentViewStart=5028.1`, still on
column 5.

### 2. Trackpad navigation moved the viewport and layout selection left

The user then scrolled left. Gesture completion first selected window `47320`
in column 4 and then window `42538` in column 3. The final stable state at
11:41:05 was:

```text
activeColumnIndex=3
currentViewStart=2536.5
targetViewStart=2536.5
selected=w42538
preferredFocus=WindowToken(pid: 16913, windowId: 42538)
confirmedFocus=WindowToken(pid: 35186, windowId: 47324)
```

The gesture events explicitly reported `focusSelection=suppressedNonManagedFocus`.
That distinction matters: viewport selection moved, but macOS/managed confirmed
focus remained on window `47324`.

At this point `47324` was classified as:

```text
visibilityClass=hidden
bucket=offscreen
hiddenSide=right
currentFrame={{2055.0,7.0},{1926.5,1251.0}}
viewport={{8.0,7.0},{2040.0,1251.0}}
```

### 3. Window churn was followed by an offscreen selection restore

At 11:41:07 the focus session entered a native-app-switch/non-managed state
while preserving confirmed token `47324`:

```text
event=focus_lease_changed
owner=native_app_switch
focused=WindowToken(pid: 35186, windowId: 47324)
non_managed=true
```

A transient Helium surface, window `48208`, was then admitted and removed while
PID reevaluation processed the app's windows. Immediately before that churn,
the viewport still selected `42538`. Immediately afterward, the viewport
geometry was unchanged but selection had changed:

```text
before:
activeColumnIndex=3 currentViewStart=2536.5 selected=w42538
preferredFocus=WindowToken(pid: 16913, windowId: 42538)
confirmedFocus=WindowToken(pid: 35186, windowId: 47324)

after:
activeColumnIndex=3 currentViewStart=2536.5 selected=w47324
preferredFocus=WindowToken(pid: 82494, windowId: 47320)
confirmedFocus=WindowToken(pid: 35186, windowId: 47324)
```

The removed transient was not the confirmed window:

```text
removedToken=WindowToken(pid: 16913, windowId: 48208)
confirmedBeforeRemoval=WindowToken(pid: 35186, windowId: 47324)
matchesConfirmed=false
shouldRecoverFocus=false
```

This is the important inconsistent state: column 3 remained the viewport anchor,
but column 5's window became the selected node.

### 4. Commands 3 and 4 followed the offscreen selection

At 11:43:06, immediately before the problematic resize, the split was still
present:

```text
activeColumnIndex=3
currentViewStart=2536.5
targetViewStart=2536.5
selected=w47324 (column 5)
preferredFocus=WindowToken(pid: 82494, windowId: 47320)
confirmedFocus=WindowToken(pid: 35186, windowId: 47324)
```

Command 3 therefore resized column 5:

```text
cmd=3 kind=toggleColumnWidth(forward) columnIndex=5 window=47324
previous=1926.3 currentSpec=proportion(0.9500)
wrappedBoundary=true nextPreset=0 newSpec=proportion(0.3500)
targetPixels=705.9
```

The resize visibility policy then pulled that selected column back onscreen:

```text
activeColumnIndex: 3 -> 5
currentViewStart=2542.6
targetViewStart=4417.9
selected=w47324
```

After the animation settled at `currentViewStart=4417.9`, command 4 again
targeted the now-visible column 5:

```text
cmd=4 kind=toggleColumnWidth(forward) columnIndex=5 window=47324
previous=705.9 newSpec=proportion(0.5000) targetPixels=1011.0
```

## How resize targets are determined

### Dispatch

`CommandHandler` maps `cycleColumnWidthForward` directly to
`layoutCoordinator.cycleSize(forward: true)` and routes the other width/height
commands similarly (`Sources/Nehir/Core/Controller/CommandHandler.swift:145-168`).
No target is resolved at this layer.

### Workspace

`withNiriWorkspaceContext` chooses the interaction workspace, obtains that
workspace's stored `ViewportState`, and passes it to the operation
(`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:2548-2568`). This part
was correct: the command reached the intended workspace and monitor.

### Node and column

For `cycleColumnWidth*`, the handler:

1. reads `state.selectedNodeId`;
2. resolves it as a `NiriWindow`;
3. finds that window's containing column;
4. resizes that column.

That logic is explicit at
`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1836-1852`.

The same selected-node rule is used for `cycleWindowWidth`,
`cycleWindowHeight`, `setColumnWidth`, `setWindowWidth`, and `setWindowHeight`
(`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1858-1897` and
`:2017-2077`). Despite the “window width” name, horizontal width is implemented
through the containing column
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:524-542`).

### Preset and reveal

Once given the column, `toggleColumnWidth` chooses a representative target
window as `targetWindow ?? column.activeWindow ?? column.windowNodes.first`,
then advances the column's preset
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:417-505`). The
`window=47324` field in the resize trace is therefore diagnostic context for the
selected column; the width state belongs to the column.

After applying the width, the engine calls
`ensureSelectionVisibleForPendingWidth`. If the resized column is not fully
visible, it animates the viewport to the closest snap for that column
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:265-340`). Thus
the jump to column 5 was not a second targeting error; it was the expected
consequence of having already chosen offscreen column 5.

## Why selection and viewport could disagree

Nehir stores several related but non-identical concepts:

- `selectedNodeId`: the authoritative Niri layout-command target;
- `activeColumnIndex`: the viewport's active/anchor column;
- `preferredWorkspaceFocusToken`: pending/remembered/confirmed focus candidate;
- `confirmedManagedFocusToken`: the last confirmed managed AX focus.

The trace formatter obtains these independently
(`Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift:316-345`).
There is no invariant in the resize handler requiring the selected node to be in
the active column or visible.

The source also contains a path that explains the exact shape of the observed
split:

1. ordinary scheduled relayouts run with `recoverFocus=true`
   (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:934-951`);
2. eligible relayouts request focus validation for the interaction workspace
   (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1192-1200`);
3. `ensureFocusedTokenValid` prefers `confirmedManagedFocusToken` and commits
   that node as workspace selection
   (`Sources/Nehir/Core/Controller/WMController.swift:3843-3887`);
4. `commitWorkspaceSelection` changes `selectedNodeId` and remembered focus, but
   does not update `activeColumnIndex` or viewport offset
   (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1729-1754`).

That write pattern is exactly `activeColumnIndex=3` plus
`selectedNodeId=w47324` in column 5. Non-managed focus alone does not suppress
this recovery: `shouldSuppressManagedFocusRecovery` requires both non-managed
focus and a frontmost Nehir-owned window
(`Sources/Nehir/Core/Controller/WMController.swift:4041-4043`).

The capture is standard verbosity and does not record the selection mutation's
caller, so it cannot prove which particular relayout/focus-validation call
performed the write. It does prove that the write occurred during the transient
window/PID-reevaluation interval, and the focus-validation path above is the
source path whose semantics match the resulting state exactly.

## Runtime state inventory

“Focused”, “selected”, “active”, and “visible” are separate runtime domains.
They should not be expected to agree globally.

### Spatial and workspace state

| State | Owner and role | Legitimate divergence |
|---|---|---|
| `visibleWorkspaceId` / `previousVisibleWorkspaceId` | Current and historical visible workspace per monitor (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:147-151`). | Every monitor has its own active workspace; previous is deliberately historical. |
| `interactionMonitorId` / `previousInteractionMonitorId` | Current and historical command-routing monitor (`WorkspaceManager.swift:179-180`). `monitorForInteraction()` falls back to confirmed-focus monitor, then first monitor (`Sources/Nehir/Core/Controller/WMController.swift:1138-1152`). | May differ from confirmed-focus or pointer monitor. |
| `interactionWorkspace()` | Derived active workspace on the interaction monitor (`WMController.swift:1171-1174`). | May differ from the workspace containing a token returned by another resolver. |
| `ViewportState.selectedNodeId` | Persistent per-workspace Niri layout selection and direct target of most Niri layout commands (`Sources/Nehir/Core/Layout/Niri/ViewportState.swift:182-194`; `NiriLayoutHandler.swift:1836-2065`). | May differ from OS focus, confirmed focus, or visible column. |
| `activeColumnIndex` | Coordinate anchor for viewport placement, not generally a command target. View start is `columnX(activeColumnIndex) + viewOffsetPixels` (`Sources/Nehir/Core/Layout/Niri/ViewportState+Animation.swift:10-19`). | May differ from the selected node's column under free scroll, preserved focus, or inconsistent recovery. |
| `viewOffsetPixels` | Current/target gesture, spring, or static offset; with `activeColumnIndex`, determines what is visible (`ViewportState.swift:55-158`, `:182-190`). | Current and target differ during animation; visibility is independent of selection. |
| `selectionProgress` | Accumulator for discrete column selection (`ViewportState.swift:186`; `Sources/Nehir/Core/Layout/Niri/ViewportState+ColumnTransitions.swift:137-157`). | Can be nonzero between discrete selection steps. |
| `isScrollLocked` | Suppresses automatic/background reveal, but not explicit navigation (`ViewportState.swift:192`; `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:72-143`). | Selection/focus can remain parked away from the viewport. |
| `preservesUnsnappedGestureOffset` | Records intentional free-scroll state after bypassing snap (`ViewportState.swift:194`; `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift:196-255`). | The viewport may intentionally leave selection behind. |
| FFM pending/recent tokens | Timestamped attribution/debounce hints (`ViewportState.swift:198-201`). | They are neither confirmed focus nor command targets. |
| `selectionRevision` | Version protecting `selectedNodeId`, `activeColumnIndex`, and `selectionProgress` from stale session patches (`WorkspaceManager.swift:153-161`, `:3579-3663`). | Metadata, not another target. |
| `NiriContainer.activeTileIdx` | Per-column remembered active tile; `activeWindow` derives from it (`Sources/Nehir/Core/Layout/Niri/NiriNode.swift:386-389`, `:641-655`). | Every column retains one, so it need not equal workspace selection. |

### Keyboard, AX, and remembered focus state

| State | Owner and role | Legitimate divergence |
|---|---|---|
| Live frontmost PID / AX focused window | External observation read when resolving a target (`WMController.swift:1881-1889`, `:1914-1918`). | May lead or lag every Nehir projection during event delivery. |
| `ObservedWindowState.isFocused` | Per-window reconcile observation (`Sources/Nehir/Core/Reconcile/ReconcileSnapshot.swift:19-46`). | Evidence, not command authority; may be transiently stale. |
| Focus bridge active/pending/deferred request | Operational fronting request, retries, and queue (`Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:29-75`, `:194-229`). | Expected to differ from confirmed focus until AX acknowledgement. |
| `FocusSession.pendingManagedFocus` | Session projection of requested token, workspace, and monitor (`WorkspaceManager.swift:163-171`, `:1145-1158`). | May differ from focus bridge operational state and confirmed focus. |
| `focusedToken` / `confirmedManagedFocusToken` | Last managed token accepted by focus reconciliation (`WorkspaceManager.swift:170-176`, `:1137-1142`). | Can differ from selection and live OS focus, especially during non-managed focus. |
| Last tiled/floating focus by workspace | Separate remembered histories used on workspace return and recovery (`WorkspaceManager.swift:172-173`, `:1821-1888`). | Inactive workspaces intentionally remember tokens other than global focus. |
| `isNonManagedFocusActive` / `isAppFullscreenActive` | Mode flags preserving managed history while actual focus is outside the managed model (`WorkspaceManager.swift:175-176`, `:1922-1960`). | Intentionally permit live focus and confirmed managed focus to disagree. |
| Focus lease | Temporary policy gate suppressing FFM/non-authoritative activation (`Sources/Nehir/Core/Reconcile/FocusPolicyEngine.swift:9-83`). | Not a target identity. |

Pending managed focus is represented twice: the focus bridge owns operational
retries, while `WorkspaceManager` owns the reconcile/session projection.
`focusWindow` starts both (`WMController.swift:4085-4112`), and AX confirmation
updates them through separate calls (`Sources/Nehir/Core/Controller/AXEventHandler.swift:4338-4380`).

### Presentation-local state

| State | Role |
|---|---|
| `FocusBorderController.visualFocusTarget` | Retained managed or non-managed keyboard target for border rendering (`Sources/Nehir/Core/Border/FocusBorderController.swift:27-62`, `:243-245`). It is presentation state, not layout selection. |
| Overview selected handle, interaction monitor, and close target | Separate interaction authority while Overview is open (`Sources/Nehir/Core/Overview/OverviewController.swift:78-90`, `:151-160`, `:810-845`; `Sources/Nehir/Core/Overview/OverviewState.swift:8-15`). |
| Workspace-bar `isFocused` / `isSelected` | Independent derived labels from focused and selected tokens (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:350-444`). The UI explicitly exposes their disagreement. |

### Shared derived resolvers

| Resolver | Precedence and purpose |
|---|---|
| `preferredWorkspaceFocusToken` | Pending tiled → remembered tiled → confirmed tiled → first tiled (`WorkspaceManager.swift:1829-1858`). |
| `resolveWorkspaceFocusToken` | Remembered tiled → the preferred chain above → remembered floating → confirmed floating → first floating (`WorkspaceManager.swift:1861-1888`). Its outer remembered check means pending focus does not always win. |
| `layoutSelectionCommandTarget` | Validated selected node in the interaction workspace (`WMController.swift:1897-1912`). |
| `managedCommandTarget` | Command-time arbitration across non-managed guards, confirmed/frontmost floating, layout selection, same-PID floating, confirmed managed, and frontmost managed targets (`WMController.swift:1914-2130`). Returns a sourced `WMCommandTarget` (`Sources/Nehir/Core/Controller/WMCommandTarget.swift:8-18`). |
| `managedLayoutCommandTargetToken` | Layout selection first, otherwise `managedCommandTargetToken` (`WMController.swift:2261-2267`). |
| `focusedManagedTokenForCommand` | Alias for `managedCommandTargetToken`, despite the distinct name (`WMController.swift:2269-2270`). |
| Automation target | Usually confirmed managed focus first; optionally frontmost AX first during non-managed focus (`WMController.swift:1878-1889`). |
| `activeTileTokensNearestViewport` | Spatial close/recovery fallback ranked by viewport proximity (`NiriLayoutEngine+ViewportCommands.swift:158-190`; `AXEventHandler.swift:2544-2642`). |
| Summon-right anchor | Destination workspace first, then confirmed focus only if it belongs there, otherwise workspace preference (`Sources/Nehir/Core/Controller/SummonRightAnchor.swift:15-50`). |

These outputs are ephemeral, not additional stored focus states. Different
precedence can be domain-correct, but they are not interchangeable meanings of
“focused”.

## Valid non-visible `selectedNodeId` cases

A selected node is not required to be visible globally:

1. **Inactive workspaces:** selection is retained per workspace while another
   workspace is shown (`WorkspaceManager.swift:153-161`).
2. **Unsnapped/free viewport motion:** bypass-snap completion intentionally does
   not synchronize selection to `activeColumnIndex`
   (`Sources/Nehir/Core/Controller/MouseEventHandler.swift:2165-2179`).
3. **Scroll lock or parking:** automatic reveal may be denied while logical
   selection/focus remains unchanged (`NiriLayoutEngine+ViewportCommands.swift:72-143`).
4. **Gesture or spring preservation:** AX confirmation can update focus and
   selection while preserving the current visual viewport so an active
   interaction is not interrupted (`AXEventHandler.swift:4440-4530`).
5. **Already-confirmed focus and close recovery:** confirmation paths explicitly
   preserve the viewport to avoid snapping back to a column the user scrolled
   away from (`AXEventHandler.swift:4338-4350`, `:4471-4530`).
6. **Focus-follows-mouse:** pointer focus activates the concrete node with
   `ensureVisible: false` and `preserveViewportAnchor: true`
   (`MouseEventHandler.swift:1480-1501`).
7. **Reveal animation:** selection can be committed before the spring reaches
   its target (`Sources/Nehir/Core/Controller/WindowActionHandler.swift:487-529`).

The useful diagnostic invariant is narrower: on an **active, stable, snapped,
unlocked workspace with no gesture/spring or focus transition**, a persistent
split between selected-node column and viewport-active/visible column is
suspicious. It is especially dangerous when a command consumes selection and
then reveals its column. The captured resize sequence meets that narrower
condition: column 3 was stably visible, selected window 47324 was in column 5,
and resizing selection deliberately revealed column 5.

## Target-resolution entry points

| Entry/action family | Target authority |
|---|---|
| Global hotkeys | `handleHotkeyCommand` → `performCommand` (`Sources/Nehir/Core/Controller/CommandHandler.swift:23-31`, `:47-245`). Directional hotkeys are intercepted for Overview first. |
| Command palette | `handleCommand` → `performCommand`, without the hotkey Overview interception (`Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift:1022`; `CommandHandler.swift:34-36`). |
| Generic IPC commands | Usually map to `HotkeyCommand` and call `performCommand` (`Sources/Nehir/IPC/IPCCommandRouter.swift:21-221`). |
| Explicit window UI/IPC actions | Carry an explicit token/handle and route through `navigateToWindowInternal`; they do not re-resolve “focused” (`Sources/Nehir/Core/Controller/WindowActionHandler.swift:148-151`, `:472-529`; `IPCCommandRouter.swift:240-257`). |
| Niri focus navigation | Direct interaction-workspace `selectedNodeId`, then remembered/first tiled fallback (`NiriLayoutHandler.swift:1458-1512`, `:1774-1800`). |
| Niri fullscreen and sizing | Direct `selectedNodeId` (`NiriLayoutHandler.swift:1821-1964`, `:2017-2065`). |
| Niri consume/expel/move-column operations | `NiriOperationContext`, which captures interaction workspace and direct `selectedNodeId` (`NiriLayoutHandler.swift:2329-2519`, `:2652-2660`). |
| Viewport scrolling | Viewport/`activeColumnIndex`, with selection changed or synchronized according to snap mode (`NiriLayoutHandler.swift:1972-1999`; `MouseEventHandler.swift:2050-2179`). |
| Mouse click/drag/interactive resize | Pointer hit-test plus interaction workspace locked for the gesture lifetime (`MouseEventHandler.swift:648-655`, `:949-1236`). |
| Focus-follows-mouse | Pointer workspace plus hit-tested Niri node; selects without requiring reveal (`MouseEventHandler.swift:1369-1400`, `:1480-1501`). |
| AX focus confirmation | Concrete observed token/node, optionally preserving viewport anchor and suppressing reveal (`AXEventHandler.swift:4338-4606`). |
| Scheduled focus validation | Pending → confirmed → workspace fallback; commits only workspace selection/history (`WMController.swift:3843-3911`; `WorkspaceManager.swift:1729-1754`). |
| Move focused window between workspaces | `managedCommandTargetToken` (`Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:693-704`, `:868-884`, `:1020-1044`). |
| Move column between workspaces | `managedLayoutCommandTargetToken`, sometimes followed by a second direct selection lookup (`WorkspaceNavigationHandler.swift:730-817`). |
| Overview activation | Overview's explicit selected handle (`WindowActionHandler.swift:82-151`). |
| Workspace-bar Shift-click | Means “move focused window”; uses the managed command resolver rather than the clicked workspace's selected node (`WMController.swift:788-795`; `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:657-664`). |
| Summon-right | Explicit target plus destination-specific anchor resolver and workspace consistency checks (`WindowActionHandler.swift:393-461`; `SummonRightAnchor.swift:15-50`). |
| Focus border | Not a command target. Managed border updates require confirmed managed focus and no non-managed focus (`WMController.swift:4204-4225`). |

Workspace-level actions such as balance-widths and viewport lock intentionally
need no window target (`NiriLayoutHandler.swift:2003-2014`, `:2078-2093`).

## Repeated resolution logic and mismatch risks

There is no single invariant declaring whether a Niri command means AX/user
focus, persistent layout selection, or visible viewport column. The three
intentional authorities are combined ad hoc. The highest-risk repetitions are:

1. **Direct layout selection versus managed arbitration.** Most Niri handlers
   repeatedly read `selectedNodeId`, while other “focused window” commands use
   `managedCommandTarget`, and `managedLayoutCommandTargetToken` implements a
   third selection-first fallback. The resize mismatch is one consequence.
2. **Selection-only focus recovery.** Scheduled validation resolves pending,
   confirmed, or fallback focus, then `commitWorkspaceSelection` writes
   `selectedNodeId` and remembered focus without synchronizing
   `activeColumnIndex` or viewport offset (`WMController.swift:3843-3911`;
   `WorkspaceManager.swift:1729-1754`). This is the source-level write pattern
   matching the stable offscreen selection in the capture.
3. **Adjacent versus indexed column moves.** Adjacent move uses the token from
   `managedLayoutCommandTargetToken`; indexed move obtains that token but then
   ignores it and re-reads `sourceState.selectedNodeId`
   (`WorkspaceNavigationHandler.swift:730-817`). A fallback token can therefore
   work in one path and no-op in the other.
4. **Target workspace versus interaction workspace.** Adjacent window move
   resolves a token with `managedCommandTargetToken` but computes destination
   relative to `interactionWorkspace` (`WorkspaceNavigationHandler.swift:693-704`).
   The resolver can fall back to a window in another workspace. Indexed move
   instead derives source workspace from the resolved token (`:868-884`).
   The monitor-specific path similarly combines the token's source workspace
   with the interaction monitor (`:1020-1044`).
5. **Mouse-wheel hybrid.** Wheel destination comes from `activeColumnIndex`,
   but the starting node prefers `selectedNodeId`, even when it is in another
   column (`MouseEventHandler.swift:1978-1984`, `:2343-2360`). Snapped gesture
   completion instead explicitly synchronizes selection (`:2165-2179`).
6. **Two pending-focus owners.** Focus bridge operational state and workspace
   session projection require paired start/confirm/cancel calls. Missing one
   side creates contradictory “pending focus” answers.
7. **Workspace-focus precedence is duplicated.** `preferredWorkspaceFocusToken`
   gives pending focus first, but `resolveWorkspaceFocusToken` checks remembered
   tiled focus before calling it (`WorkspaceManager.swift:1829-1888`). Callers
   using the two helpers can disagree while a request is pending.
8. **IPC result does not always reflect target resolution.** Generic IPC routes
   through void handlers and `performCommand` reports `.executed` after
   dispatch even when a downstream `guard` found no target
   (`CommandHandler.swift:47-245`). Some workspace IPC wrappers separately
   pre-resolve and compare state, producing different success semantics
   (`IPCCommandRouter.swift:343-348`, `:435-456`).
9. **Same command, different Overview behavior.** Directional hotkeys navigate
   Overview before dispatch, while palette/IPC enter `performCommand` and are
   rejected by its Overview guard (`CommandHandler.swift:23-51`, `:248-255`).
   This may be intended input-surface policy, but it is not identical action
   semantics.
10. **Explicit Overview target with separately supplied workspace.** Activation
    verifies the handle still exists but trusts Overview's workspace id.
    `navigateToWindowInternal` can focus the token while selection/reveal updates
    no-op if that workspace snapshot is stale (`WindowActionHandler.swift:148-151`,
    `:472-529`).

Border and Overview disagreement with layout selection is **not** resolver
repetition to eliminate: those are presentation-specific authorities. Likewise,
per-column `activeTileIdx` is structural memory, not another global focus.

A future central resolver should return a typed context—not just a token—with
at least token, workspace, monitor, node, column, source authority, and whether
selection is parked/transient/offscreen. Different command families can then
declare which authority they accept without recomputing half of the context
from another state domain.

## Proposed verbose reproduction and capture runbook

### Important limitation of current verbose tracing

Verbose mode is still worth capturing, but it cannot by itself attribute a
selection-only write. `ViewportMutationSnapshot` contains only active column,
current/target offset, and offset kind; it does not contain `selectedNodeId`
(`Sources/Nehir/Core/Layout/Niri/ViewportState.swift:167-181`, `:216-223`). The
audit records provenance only when that snapshot changes (`:233-254`), and the
commit observer emits only when the viewport target offset moves by more than
half a pixel (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3532-3548`,
`:3630-3642`).

Consequently, a write that changes `selectedNodeId` from column 3 to column 5
while leaving `activeColumnIndex=3` and both offsets unchanged appears in the
next viewport record, but `lastViewportMutationCaller` may still describe an
older offset mutation or be nil. A verbose capture can correlate the flip with
focus/reconcile events and prove the command target, but definitive setter
attribution requires an additional selection-write event at the workspace
commit chokepoint.

### Capture preparation

1. In **Settings → Diagnostics**, enable **Developer Mode** and set
   **Viewport Trace Verbosity** to **Verbose**. Verbose enables layout dumps,
   per-frame gesture records, and viewport mutation provenance
   (`Sources/Nehir/Core/Config/ViewportTraceVerbosity.swift:9-42`).
2. Close Settings before reproducing. Do not open Command Palette, Terminal, or
   another Nehir-owned/debug window during the attempt; those surfaces alter
   frontmost/non-managed focus.
3. Prefer the default trace hotkey, `Control+Option+Command+T`, both to start and
   stop. Start immediately before the setup transition and stop immediately
   after the first wrong resize. Each trace category retains only its newest
   400 records, so a long verbose gesture sequence can evict the decisive
   beginning (`Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift:281-300`).
4. Use one short attempt per capture. Record a screen capture or screenshot as a
   separate visual aid, especially the workspace bar's distinct focused and
   selected indicators.

### Root-cause-oriented attempt

1. On one active Niri workspace, arrange at least six columns. Use easily
   identifiable windows in columns 3, 4, and 5.
2. Focus/select the column-5 window and wait for layout/focus animation to
   settle. Optionally cycle its width once; this creates a clear resize identity
   record before the divergence.
3. Start verbose capture.
4. Trackpad-scroll left until column 3 is the stable viewport/selection. The
   desired intermediate evidence is `activeColumnIndex=3`, selection in column
   3, and confirmed managed focus still on the column-5 token. The original
   sequence reported `focusSelection=suppressedNonManagedFocus`.
5. **Do not try to manufacture Helium popovers or transient windows.** The
   original capture contained a transient Helium window, but it does not show
   what user action created it and does not establish it as the trigger. A later
   non-reproduction created and removed several Helium transient surfaces while
   selection, confirmed focus, and the resize target all remained correctly on
   visible column 2. Treat this as incidental correlation, not a repro step.
6. Instead, perform only the normal action sequence that originally preceded the
   bad resize—if the bug had a familiar real-world precursor—and do not click a
   tiled window after the leftward gesture. If there is no known precursor,
   simply wait for the viewport spring to settle, then invoke **Cycle Column
   Width Forward** once using its normal hotkey. Do not use `nehirctl` from a
   newly focused Terminal for this step; bringing Terminal frontmost changes the
   state being investigated.
7. If a far/offscreen column resizes and is revealed while another column was
   visibly current, stop capture immediately. Otherwise, the attempt is a useful
   negative result: it confirms selection and the resize target stayed aligned.

The only productive timing variants are ordinary user actions that have actually
preceded the bug for the reporter (for example, the same app switch or closing
an app window if either was present). Capture one variant per trace; do not
invent a popover/churn step from the trace's internal window labels.

### Deterministic semantic reproduction

This does not prove the erroneous focus-recovery arm, but it tests the command's
behavior with an intentionally parked selection:

1. Focus/select a far-right column.
2. Hold the configured **Manual Override** modifier while trackpad-scrolling far
   enough left to bypass snap, or enable per-workspace Viewport Scroll Lock and
   produce a background focus confirmation for the far-right token.
3. Without selecting a visible window, run **Cycle Column Width Forward**.
4. Capture whether sizing follows the parked selected node and explicitly
   reveals it.

Label this capture as an intentional parked-selection control, not as the
root-cause reproduction.

### Negative control

Repeat the topology and leftward navigation, but explicitly click/focus the
visible column-3 window immediately before resizing. The command should resize
column 3 without a far-right reveal. A failing capture plus this control
separates target-state divergence from general resize geometry problems.

### Evidence checklist

A useful capture should contain, in order:

- a viewport record after gesture completion showing selected node, confirmed
  focus, `activeColumnIndex`, current/target view start, gesture/animation state,
  scroll lock, and unsnapped state;
- focus/reconcile records for the app switch and transient window admission or
  removal;
- the first record where selection has changed back to the far-right token while
  active column and viewport position remain unchanged;
- the resize record's window token and column index;
- the following viewport reveal/animation target;
- start/end runtime snapshots and the interaction-monitor write section.

`command_target.resolve.*` may be absent for this resize because the sizing hot
path bypasses `managedCommandTarget`; the Niri resize and viewport sections are
the authoritative command evidence.

For definitive attribution in a diagnostic build, add a behavior-neutral
`viewport_selection_write` event in `updateNiriViewportState` carrying workspace,
before/after selected node, before/after active column, selection revision, and
caller/reason. Also add a sizing-command-start event carrying interaction
monitor/workspace, selected token/node/column, active column, visibility class,
confirmed/pending/preferred focus, scroll-lock/gesture/animation flags, and the
resolved command target. Do not change targeting behavior while collecting this
evidence.

## Why the user's expectation differed

The visible UI suggested “resize the current viewport column” because column 3
was the active anchor and columns 2–4 were visible. The implementation instead
uses “resize the stored selected layout node.” Those usually coincide after
normal navigation, so the distinction is easy to miss. Here they separated when
confirmed-focus recovery rewrote only selection.

The labels also encourage the focus-based expectation: IPC descriptions call
these operations changes to the “focused Niri column/window,” while the hot path
does not resolve the live frontmost/focused target and does not choose a visible
column. `WMController.managedCommandTarget()` has richer target arbitration,
but these Niri sizing handlers bypass it and read `selectedNodeId` directly.

## Conclusions

### Confirmed

- All four captured resize operations targeted window `47324` in column 5.
- Commands 1–2 did so while column 5 was selected and visible.
- Before command 3, the viewport was on active column 3 while
  `selectedNodeId` pointed to offscreen column 5; command 3 then revealed it,
  so command 4 targeted the same column after it was visible again.
- Resize commands use `selectedNodeId`, not viewport visibility,
  `activeColumnIndex`, or `preferredWorkspaceFocusToken`.
- The sizing engine intentionally reveals a resized offscreen column.
- A focus-validation path can rewrite selection from confirmed focus without
  synchronizing active column or viewport, producing the observed split.

### Not established by this capture

- Whether resize commands should always follow selection, or should prefer the
  visible active column when selection is parked, is a product decision.
- The standard trace cannot identify the exact caller that changed selection at
  11:41:08. A future repro should use verbose viewport mutation audit and emit a
  command-start record containing selected token, selected column, active
  column, visibility class, preferred focus, confirmed focus, and resolved
  target.

## Candidate fix boundary (not implemented)

The narrowest behavioral decision point is
`NiriLayoutHandler.cycleSize` and the sibling sizing handlers. A fix should first
define one invariant:

- either **selection is authoritative**, in which case focus validation must not
  leave an offscreen selection paired with an unrelated active column; or
- **visible active column is authoritative for resize**, in which case sizing
  handlers must resolve a window from `activeColumnIndex` when selected-node
  visibility disagrees.

Adding only a visibility fallback without deciding this invariant risks changing
intentional parked-selection behavior during animations or explicit navigation.
No runtime code or tests were changed as part of this discovery.
