# Move Workspace / Column to Next Monitor (i3/Aerospace-style, wrap-around)

GitHub issue: **#62 — Move Workspace to next monitor** (no labels).

## TL;DR

The requested capability **does not exist today**. Nehir has a *two-way*
`swapWorkspaceWithMonitor(.left/.right/.up/.down)` command and a cyclic
*focus*-to-next-monitor command (`focusMonitorNext`, which wraps), but there is
**no one-way "move the current workspace to the next monitor (with
wrap-around)"** command and **no "move the focused column to the next monitor"
command**. The reporter's i3/Aerospace mental model (`Cmd+P` = move workspace to
next monitor, wrap; `Cmd+Shift+P` = move column to next monitor, wrap) cannot be
expressed with the current command set, and the existing "swap workspace with
monitor" hotkeys do nothing for the user out of the box (see "Why swap is a
no-op for this user" below).

Verdict: **actionable** — investigation concludes a genuine capability gap; proposes two new commands (see "Proposed plan" below). Lives in `discovery/` pending maintainer confirmation of the source-monitor backfill policy.
(`moveWorkspaceToMonitor(.next/.previous)` and
`moveColumnToMonitor(.next/.previous)`), both cyclically wrapped, on top of
existing workspace-assignment primitives. No engine rework required.

All file references below were re-verified on the main worktree
(`/Users/Aleksei_Gurianov/ghq/github.com/guria/nehir`) on 2026-06-19; line
numbers drift over time.

---

## Issue (inlined, self-contained)

Reporter @stefanpinterBE finds the monitor hotkeys confusing and non-functional:

> i do not understand how the monitor hotkeys work. Swap Workspace with
> Left/Right/Up/Down Monitor? They even do nothing for me. A lot of hotkeys like
> 'move window to workspace N on Down Monitor'... that does sound like a lot of
> hotkeys needing to be defined?
>
> I am used to (Aerospace/Sway/i3/hyprland): Command+P = Move Workspace to NEXT
> monitor; Command+Shift+P = Move Windows/Column to NEXT monitor. When the last
> (right-most) monitor is active and I press the hotkey again, it should just
> wrap around and start again at the left-most. i am unsure why i'd want to
> SWAP anything.

Owner @Guria: "We still have some commands and hotkeys inherited from the
upstream project, and I haven't reviewed all of them yet… I'm particularly
interested in understanding whether you're missing a specific workflow (like
'move workspace to next monitor' with wrap-around)."

Reporter: not urgent; currently ignores extra monitors; prefers the simple
wrap-around next/prev workflow with few hotkeys.

---

## Current command surface (verified in source)

`Sources/Nehir/Core/Input/HotkeyCommand.swift` — monitor-related cases:

- `case focusMonitorPrevious` (`:16`), `case focusMonitorNext` (`:17`),
  `case focusMonitorLast` (`:18`) — change *which monitor receives input*;
  **do not move anything**.
- `case swapWorkspaceWithMonitor(Direction)` (`:62`) — two-way workspace
  exchange with an *adjacent* (spatially directional) monitor.
- `case moveWindowToWorkspaceOnMonitor(workspaceIndex:monitorDirection:)`
  (`:68`) — move a single focused window to a numbered workspace on an
  *adjacent* monitor (directional, no wrap).

There is **no** `moveWorkspaceToMonitor`, `moveColumnToMonitor`, or any
cyclic "move workspace/column to the next monitor" case.

### Focus-to-next-monitor already wraps cyclically

`WorkspaceNavigationHandler.focusMonitorCyclic(previous:)`
(`Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:164`) calls
`WorkspaceManager.nextMonitor(from:)` / `previousMonitor(from:)`, which **wrap
around** a position-sorted monitor list:

- `WorkspaceManager.nextMonitor(from:)`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3266`):
  `let nextIdx = (currentIdx + 1) % sorted.count`.
- `WorkspaceManager.previousMonitor(from:)`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3256`):
  `let prevIdx = currentIdx > 0 ? currentIdx - 1 : sorted.count - 1`.
- Order is `Monitor.sortedByPosition(_:)`
  (`Sources/Nehir/Core/Monitor/Monitor.swift:88`) via the cached
  `sortedMonitors()` (`WorkspaceManager.swift:2164`).

So the **wrap-around, position-sorted monitor ring the user wants already
exists** for *focus* — the same ring is exactly what the new move commands
should reuse. Only the *move* operation is missing.

### Swap is a two-way exchange, not a one-way move

`WorkspaceNavigationHandler.swapCurrentWorkspaceWithMonitor(direction:)`
(`WorkspaceNavigationHandler.swift:215`) resolves the target with
`WorkspaceManager.adjacentMonitor(from:direction:)` (note: **no wrap**) and
then calls the two-way
`WorkspaceManager.swapWorkspaces(_:on:with:on:)`
(`WorkspaceManager.swift:3117`). That function writes each workspace onto the
*other* monitor's session (`visibleWorkspaceId`) and rewrites both
`assignedMonitorPoint`s — a true A↔B exchange. This is why the command family
is named "swap": the workspace you had on monitor 1 and the workspace that was
on monitor 2 trade places. That is **not** the i3/Aerospace one-way "send *my*
workspace to the next monitor" semantic.

### Why swap is a no-op for this user

Three compounding reasons, all visible in the code:

1. **The swap hotkeys are unassigned by default.** In
   `Sources/Nehir/Core/Input/ActionCatalog.swift`, the four
   `swapWorkspaceWithMonitor.{left,right,up,down}` actions are registered with
   `binding: .unassigned` (the `for direction in [Direction.left, .right, .up,
   .down]` loop, `:335`–`:341`). The reporter never bound them, so pressing
   nothing produces nothing. (By contrast `focusMonitorNext` *is* bound by
   default — `Cmd+Tab` analog `kVK_Tab` + `controlKey|cmdKey`, `:445`–`:449` —
   which is why "focus next monitor" works but "swap" does not.)

2. **Swap is directional, not cyclic, and silently no-ops when there is no
   neighbour in that exact direction.** `adjacentMonitor(from:direction:wrapAround:)`
   (`WorkspaceManager.swift:3233`) filters candidate monitors by the sign of
   `monitorDelta(dx,dy)` (`:3239`–`:3247`). If the monitor topology has no
   monitor strictly left/right/up/down of the current one (e.g. a diagonal or
   vertically-stacked arrangement like the one this project itself recommends
   for Nehir), the directional filter is empty, `wrapAround` defaults to
   `false`, and the function returns `nil` — and `swapCurrentWorkspaceWithMonitor`
   early-returns (`:222` guard) with no user feedback. The same directional,
   non-wrapping `adjacentMonitor` is used by
   `moveWindowToWorkspaceOnMonitor` (`WorkspaceNavigationHandler.swift:907`),
   so those per-monitor hotkeys have the same blind spots.

3. **Even when swap fires, it exchanges two workspaces** rather than sending
   the user's current workspace to the next monitor and leaving the source
   monitor on its previous/next workspace — which is the mental model the
   reporter describes.

### One-way window move exists (for reference)

`WorkspaceNavigationHandler.moveWindowToWorkspaceOnMonitor(rawWorkspaceID:monitorDirection:)`
(`WorkspaceNavigationHandler.swift:891`) is the only existing *one-way*,
*cross-monitor* transfer. It is the pattern to imitate for a one-way move: it
transfers a window via `transferWindowFromSourceEngine(...)`, calls
`controller.reassignManagedWindow(token, to:)`, optionally follows focus
(`focusFollowsWindowToMonitor`), and commits via
`layoutRefreshController.commitWorkspaceTransition(...)`. It is,
however, (a) per-window not per-workspace/per-column, (b) keyed by a numbered
destination workspace, and (c) directional without wrap.

### Workspace-assignment primitives a move can compose from

A one-way "move workspace to monitor" needs only existing plumbing:

- `WorkspaceManager.setActiveWorkspace(_:on:)` (`WorkspaceManager.swift:3153`)
  makes a workspace the visible one on a monitor.
- `WorkspaceManager.assignWorkspaceToMonitor(_:monitorId:)`
  (`WorkspaceManager.swift:3167`) reassigns a workspace's anchor point and
  validates the assignment.
- `WorkspaceManager.nextMonitor(from:)` / `previousMonitor(from:)` (above)
  give the cyclic target.
- `WMController.syncMonitorsToNiriEngine()` + `commitWorkspaceTransition(...)`
  is the same commit pair `swapCurrentWorkspaceWithMonitor` uses
  (`WorkspaceNavigationHandler.swift:247`–`:266`).

So a one-way move is **a strict subset of what swap already does**, minus the
reverse-direction write.

---

## Proposed design

Add two new hotkey commands. Both are one-way and **cyclically wrapped** by
reusing the existing `nextMonitor`/`previousMonitor` ring.

### New commands

```swift
// Sources/Nehir/Core/Input/HotkeyCommand.swift
case moveWorkspaceToMonitor(MonitorCyclicDirection)   // move the *whole active workspace* to the next/prev monitor
case moveColumnToMonitor(MonitorCyclicDirection)      // move the *focused column* to the next/prev monitor
```

```swift
// new small enum, or reuse Direction with a dedicated .next/.previous variant
enum MonitorCyclicDirection: String, Codable {
    case next
    case previous
}
```

Reusing a dedicated `next`/`previous` (rather than `.left/.right/.up/.down`) is
intentional and is the core of the request: the user wants a **single**
wrap-around ring independent of physical arrangement, exactly mirroring
`focusMonitorNext`/`focusMonitorPrevious` and i3's `move workspace to output
right`-with-wrap.

### Semantics

**`moveWorkspaceToMonitor(.next)`** — the i3 `move workspace to output` behaviour:

1. Resolve `currentMonitorId` via `interactionMonitorId(for:)` and
   `currentWsId` via `controller.interactionWorkspace()?.id` (same as swap,
   `WorkspaceNavigationHandler.swift:218`–`:219`).
2. `target = workspaceManager.nextMonitor(from: currentMonitorId)`
   (cyclic) — **not** `adjacentMonitor(..., wrapAround:)`.
3. Save the current viewport state (`saveNiriViewportState(for: currentWsId)`,
   as swap does at `:238`).
4. Move the workspace one-way: assign the current workspace to the target
   monitor via `assignWorkspaceToMonitor(currentWsId, monitorId: target.id)`
   and make it the visible workspace there via
   `setActiveWorkspace(currentWsId, on: target.id)`. On the *source* monitor,
   activate its next/previous workspace (or its last-used workspace via
   `previousVisibleWorkspaceId` in the monitor session, as `swapWorkspaces`
   already tracks at `WorkspaceManager.swift:3131`) so the source monitor is
   not left blank.
5. Set the interaction monitor to the target (`setInteractionMonitor(target.id)`)
   so focus follows the workspace the user just moved — matching
   `focusFollowsWindowToMonitor` ergonomics and the i3 expectation that the
   workspace you moved is the one you're now on.
6. Commit: `controller.syncMonitorsToNiriEngine()` +
   `commitWorkspaceTransition(affectedWorkspaces:[...], reason:.workspaceTransition)`
   and restore focus via `resolveAndSetWorkspaceFocusToken(for: currentWsId)`
   (same commit shape as `swapCurrentWorkspaceWithMonitor`,
   `WorkspaceNavigationHandler.swift:247`–`:266`).

Wrap-around is automatic because `nextMonitor(from:)` returns
`sorted[(currentIdx + 1) % count]`; pressing it again from the right-most
monitor lands on the left-most — verbatim what the reporter asked for.

**`moveColumnToMonitor(.next)`** — the Aerospace `Cmd+Shift+P` behaviour:

1. Resolve the focused column's anchor token via
   `controller.managedCommandTargetToken()` and the current workspace/monitor
   (same preamble as `moveWindowToWorkspaceOnMonitor`,
   `WorkspaceNavigationHandler.swift:892`–`:896`).
2. `target = workspaceManager.nextMonitor(from: currentMonitorId)` (cyclic).
3. Transfer the whole focused column (not a single window) to the target
   monitor's active workspace, reusing
   `transferWindowFromSourceEngine(...)` per-window for each token in the
   focused column, then `controller.reassignManagedWindow(token, to:)`.
   (Column-aware transfer may need a small helper that enumerates the focused
   column's nodes from the niri engine; if a column-level transfer primitive
   is missing, fall back to moving each window token in the focused column
   individually — the same engine `moveColumnToWorkspace(Int)` path already
   moves a column, so the per-token loop is proven.)
4. Follow focus to the target monitor when `focusFollowsWindowToMonitor` is on
   (mirror `moveWindowToWorkspaceOnMonitor`'s `shouldFollowFocus` block,
   `WorkspaceNavigationHandler.swift:944`–`:976`).
5. Commit via `commitWorkspaceTransition(...)`.

> Note: the column variant is larger than the workspace variant because it
> touches the niri engine's column model. The **workspace** variant is
> independently shippable and delivers the primary user request; the **column**
> variant can land as a follow-up. Recommend sequencing them as two tasks.

### Suggested default hotkeys

Bind by default (the absence of defaults is itself the bug the reporter hit —
swap is unassigned, so the feature is invisible). Proposed defaults, chosen to
avoid colliding with the existing `focusMonitorNext` = `Ctrl+Cmd+Tab` and
`focusMonitorLast` = `Ctrl+Cmd+\``:

| Command                          | Suggested default       | Rationale                                   |
|----------------------------------|-------------------------|---------------------------------------------|
| `moveWorkspaceToMonitor(.next)`  | `Ctrl+Cmd+Right Arrow`  | "workspace" + "next monitor", arrow = ring  |
| `moveWorkspaceToMonitor(.previous)` | `Ctrl+Cmd+Left Arrow` | symmetric                                    |
| `moveColumnToMonitor(.next)`     | `Ctrl+Cmd+Shift+Right Arrow` | shift = "column/window" modifier (Nehir already uses Shift for column moves, e.g. `moveColumnToWorkspaceUp/Down`) |
| `moveColumnToMonitor(.previous)` | `Ctrl+Cmd+Shift+Left Arrow` | symmetric                                |

These are proposals; the reporter's literal `Cmd+P` / `Cmd+Shift+P` are fine as
user overrides but `Cmd+P` is macOS Print and should not be a default.

### Code seam points (where to edit)

- **Command enum:** `Sources/Nehir/Core/Input/HotkeyCommand.swift` — add the
  two cases near the existing monitor cases (`:16`–`:18`, `:62`).
- **Action catalog (titles + defaults):**
  `Sources/Nehir/Core/Input/ActionCatalog.swift` — add title strings near the
  `focusMonitorNext`/`swapWorkspaceWithMonitor` titles (`:874`–`:876`, `:918`)
  and register default bindings near the `focusMonitorNext` block (`:443`–`:460`)
  and the `swapWorkspaceWithMonitor` loop (`:335`–`:341`).
- **Handler:** `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift`
  — add `moveWorkspaceToMonitor(direction:)` and
  `moveColumnToMonitor(direction:)` next to
  `swapCurrentWorkspaceWithMonitor` (`:215`) and
  `moveWindowToWorkspaceOnMonitor` (`:891`).
- **Command dispatch:** `Sources/Nehir/Core/Controller/CommandHandler.swift`
  — add cases near the existing `.focusMonitorNext` (`:91`) and
  `.swapWorkspaceWithMonitor` (`:161`) switches.
- **IPC:** `Sources/Nehir/IPC/IPCCommandRouter.swift` — add cases near the
  existing monitor moves (`:113`–`:129`) so the new commands are scriptable.
- **TOML config schema:** `Sources/Nehir/Core/Config/HotkeyConfigMapping.swift`
  — add `[focus]`- or `[move]`-section keys (e.g. `moveWorkspaceToMonitorNext`,
  `moveWorkspaceToMonitorPrevious`, `moveColumnToMonitorNext`,
  `moveColumnToMonitorPrevious`) next to the existing `monitorNext` /
  `monitorPrevious` (`:55`–`:56`) and `swapWithMonitor*` (`:35`–`:38`) mappings.
- **Settings UI:** `Sources/Nehir/UI/HotkeySettingsView.swift` — surface the
  new bindings in the monitor/focus category (the `moveColumnTo` branch at
  `:555` shows the pattern for grouped entries).

### Relationship to existing swap (do not conflate)

Keep `swapWorkspaceWithMonitor(.left/.right/.up/.down)` as-is — it is a
legitimate (if confusingly named and unassigned) feature for users who want a
two-way exchange along a spatial axis. The new commands are *additive* and
*cyclic*, addressing the one-way ring workflow the reporter (and i3/Aerospace
users generally) expects. Consider, as a separate documentation/UX task,
renaming the in-app label from "Swap Workspace with … Monitor" to something
that signals the two-way exchange (e.g. "Exchange Workspace with Adjacent
Monitor") so the new "Move Workspace to Next/Previous Monitor" reads as the
clearly one-way default.

---

## Implementation steps (sequenced)

1. **Enum + catalog + defaults (workspace variant only first).** Add
   `moveWorkspaceToMonitor(MonitorCyclicDirection)` to `HotkeyCommand`,
   `MonitorCyclicDirection` enum, titles + default bindings in
   `ActionCatalog`. Compile.
2. **Handler.** Implement `WorkspaceNavigationHandler.moveWorkspaceToMonitor(direction:)`
   using `nextMonitor`/`previousMonitor` + `assignWorkspaceToMonitor` +
   `setActiveWorkspace` + the swap-style commit. Wire dispatch in
   `CommandHandler` and `IPCCommandRouter`. Compile.
3. **TOML schema.** Add config keys in `HotkeyConfigMapping`. Verify round-trip
   (load → export reproduces the keys).
4. **Manual verification (workspace variant):** on a 2- and 3-monitor setup,
   confirm (a) pressing `.next` from the right-most monitor wraps to the
   left-most, (b) the moved workspace becomes the visible workspace on the
   target and focus follows it, (c) the source monitor shows its previous
   workspace rather than going blank, (d) the niri layout/viewport state of the
   moved workspace is preserved (columns, scroll offset).
5. **Column variant.** Repeat steps 1–4 for `moveColumnToMonitor`, adding the
   column-enumeration + per-token transfer helper.
6. **Settings UI + docs.** Surface bindings; update in-app labels to
   distinguish one-way "Move" from two-way "Exchange".

### Verification matrix (acceptance)

- `moveWorkspaceToMonitor(.next)` on a 2-monitor ring: ws A (monitor 1) →
  appears on monitor 2, focus follows, monitor 1 shows its other workspace.
- `.next` from the last monitor wraps to the first monitor (no dead-end, no
  no-op) — this is the bug the reporter hit with directional swap.
- `.previous` wraps the other way.
- `moveColumnToMonitor(.next)` moves the focused column to the next monitor's
  active workspace and (when `focusFollowsWindowToMonitor`) follows focus.
- No regressions in `swapWorkspaceWithMonitor` or `focusMonitorNext`.

---

## Open questions

- **Source-monitor backfill policy.** When a workspace moves off its monitor,
   what becomes visible on the now-empty source: the monitor's
   `previousVisibleWorkspaceId`, its next-in-order workspace, or workspace 1?
   `swapWorkspaces` already tracks `previousVisibleWorkspaceId`
   (`WorkspaceManager.swift:3131`); reusing it is the lowest-surprise choice.
   Confirm with the maintainer's preference.
- **Should the column variant require `focusFollowsWindowToMonitor`, or always
   follow focus?** i3/Aerospace always follow; Nehir's existing
   `moveWindowToWorkspaceOnMonitor` gates on the setting. Recommend gating for
   consistency, but the maintainer may prefer always-follow for the column
   case.
- **Interaction vs. assignment semantics for a workspace already assigned to a
   monitor.** `assignWorkspaceToMonitor` validates via `isValidAssignment`;
   confirm a workspace can be reassigned away from its current monitor without
   being rejected (swap already relies on this at `WorkspaceManager.swift:3121`).
