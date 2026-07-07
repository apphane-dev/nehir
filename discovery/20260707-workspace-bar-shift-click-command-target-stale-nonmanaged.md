# Discovery: workspace-bar Shift-click uses the generic command target, so it can move the wrong window or no-op under non-managed focus

Status: confirmed — runtime evidence and source mechanism both verified against
`nehir vd953d4` (main at `d953d4d3`).

Workspace-bar Shift-click is documented as "move the focused window here", but
it does not carry an explicit window token from the bar/focus state into the move
operation. The bar only converts Shift into a generic "move focused window"
command. The command then re-resolves a `managedCommandTarget()` at click time.
That generic resolver can be stale (moving an older layout/command target) or can
return `nil` while non-managed focus is active, even when the bar/runtime state
still knows which managed window is selected.

## User-visible failures captured

### A. Telegram was the intended focused window, but a Codex window moved

The captured end state after the bad Shift-click has Telegram as Nehir's focused
managed window on the visible workspace:

```text
interactionWorkspace=04A28B7E-E0AF-419F-AC36-137BFEA1FE14
wmCommandTarget=WindowToken(pid: 55316, windowId: 351)
wmCommandTargetSource=layoutSelection
layoutSelection=WindowToken(pid: 55316, windowId: 351)
observedManagedFocus=WindowToken(pid: 55316, windowId: 351)
nonManaged=false
focus focused=55316:351
```

Telegram is visible and tiled in workspace 1:

```text
WindowToken(pid: 55316, windowId: 351)
workspace=04A28B7E-E0AF-419F-AC36-137BFEA1FE14
mode=tiling phase=tiled hidden=nil
liveAXFrame={{14.0, 7.0}, {1011.0, 1251.0}}
bundleId=ru.keepcoder.Telegram
```

But the workspace-transition side effect moved Codex window `20053`, not
Telegram. The transition affected workspace 1 and workspace 7, and the final
layout places the Codex token on workspace 7 while Telegram remains on workspace
1:

```text
lastAffectedWorkspaceIdsByReason=[... workspaceTransition: Set([
  04A28B7E-E0AF-419F-AC36-137BFEA1FE14,
  7C3199AC-1A27-4A48-BCBE-A7A7C9899735
])]

WindowToken(pid: 11877, windowId: 20053)
workspace=7C3199AC-1A27-4A48-BCBE-A7A7C9899735
mode=tiling phase=hidden hidden=workspaceInactive
bundleId=com.openai.codex

workspace=7 id=7C3199AC-1A27-4A48-BCBE-A7A7C9899735 ...
  {w20053:selected{cur=212,7,1632,1251,target=212,7,1632,1251,
   live=2055,7,1011,1251,replacement=1031,7,1011,1251,hidden:nil}}
```

The same capture shows why a stale Codex target was plausible before the click:
Nehir's initial admission/layout insertion used Codex as the focused reference
while building workspace 1, even though Telegram was also admitted into that
workspace:

```text
workspace=04A28B7E-E0AF-419F-AC36-137BFEA1FE14
token=WindowToken(pid: 11877, windowId: 20053)
beforeColumns=11 selectedNodeBefore=nil selectedTokenBefore=nil
focusedTokenBefore=WindowToken(pid: 11877, windowId: 20053)
reference=focused_token referenceColumn=6 landedColumn=6

workspace=04A28B7E-E0AF-419F-AC36-137BFEA1FE14
token=WindowToken(pid: 55316, windowId: 351)
beforeColumns=11 selectedNodeBefore=nil selectedTokenBefore=nil
focusedTokenBefore=WindowToken(pid: 11877, windowId: 20053)
reference=focused_token referenceColumn=6 landedColumn=5
```

So the bad move is consistent with the bar invoking a generic target resolver
instead of passing "the Telegram token that the user sees/has focused" into the
move request.

### B. Telegram accepted typing, but Shift-click did nothing

Two later captures start and end in the same precondition: Telegram is the
selected/observed managed window, but Nehir still marks non-managed focus active
and `managedCommandTarget()` is nil:

```text
interactionWorkspace=04A28B7E-E0AF-419F-AC36-137BFEA1FE14
wmCommandTarget=nil
wmCommandTargetSource=nil
layoutSelection=WindowToken(pid: 55316, windowId: 351)
observedManagedFocus=WindowToken(pid: 55316, windowId: 351)
focusRequest=nil borderTarget=nil
interactionMonitor=ID(displayId: 1)
nonManaged=true
focus focused=55316:351
```

Telegram is still visible and selected by the layout:

```text
workspace=1 id=04A28B7E-E0AF-419F-AC36-137BFEA1FE14 visible=true
activeColumnIndex=5 selectedNode=NodeId(uuid: 9A552B1D-A8AB-4770-86EF-C465CC6BFA42)
preferredFocus=WindowToken(pid: 55316, windowId: 351)

WindowToken(pid: 55316, windowId: 351)
workspace=04A28B7E-E0AF-419F-AC36-137BFEA1FE14
mode=tiling phase=tiled hidden=nil
liveAXFrame={{14.0, 7.0}, {1011.0, 1251.0}}
bundleId=ru.keepcoder.Telegram
```

No workspace-transition or layout-command counters change during the click
attempt in this state; the captured summaries remain at the previous values:

```text
requestedByReason=[... workspaceTransition: 6, layoutCommand: 18, ...]
executedByReason=[... workspaceTransition: 3, layoutCommand: 17, ...]
lastAffectedWorkspaceIdsByReason=[... workspaceTransition: Set([
  04A28B7E-E0AF-419F-AC36-137BFEA1FE14,
  7C3199AC-1A27-4A48-BCBE-A7A7C9899735
])]
```

This matches the observed "Shift-click in the workspace bar does nothing".

## Source-backed mechanism

The workspace bar wires all workspace-pill clicks through
`WorkspaceBarManager.handleWorkspacePillClick`:

- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:227-233` passes
  workspace focus clicks to `handleWorkspacePillClick`; the explicit context-menu
  move path also calls `moveFocusedWindowFromBar`.
- `WorkspaceBarManager.swift:654-662` polls global modifier flags and dispatches
  Shift to `controller.moveFocusedWindowFromBar(toWorkspaceId:)`.
- `WorkspaceBarManager.swift:760-766` defines the whole intent resolver:
  `.shift` means `.moveWindow`; otherwise focus.

`moveFocusedWindowFromBar` is only a workspace-id adapter:

- `Sources/Nehir/Core/Controller/WMController.swift:793-795` converts the target
  workspace id to a raw name and calls
  `workspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID:)`.

The actual moved token is then resolved generically, not supplied by the bar:

- `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:868-880`
  starts `moveFocusedWindow(toRawWorkspaceID:)` with
  `guard let token = controller.managedCommandTargetToken() else { return }`,
  then transfers and reassigns that token.
- `Sources/Nehir/Core/Controller/WMController.swift:2052-2054` defines
  `managedCommandTargetToken()` as `managedCommandTarget()?.token`.

That resolver has two important gates that explain the captures:

1. Under active non-managed focus, it returns `nil` before consulting the
   selected layout token when the frontmost token is the preserved managed focus
   or when probing does not find a different managed target
   (`WMController.swift:1916-1937`). That is exactly the no-op state above:
   `nonManaged=true`, `layoutSelection=Telegram`, `observedManagedFocus=Telegram`,
   but `wmCommandTarget=nil`.
2. Outside non-managed focus, `managedCommandTarget()` can use layout selection
   as the command target (`WMController.swift:1879-1894`, selected node lookup;
   `WMController.swift:1988-1990`, selection returned before the later confirmed
   managed-focus fallback). If layout selection/confirmed focus is stale relative
   to what the user considers focused, Shift-click moves that stale target.

Therefore the root cause is not a missing Shift modifier check in the bar. The
Shift check exists. The bug is that the Shift-click path delegates to the same
ambiguous command-target resolver used by keyboard commands, while the bar UX
promises to move the currently focused/selected managed window visible to the
user.

## Reproduction/validation steps

### Repro 1: stale target moves the wrong window

Goal: create a state where the user has moved attention to Telegram, but Nehir's
command target still points at an older managed Codex selection.

1. Use one display with the workspace bar enabled below the menu bar.
2. Have at least these managed windows available:
   - Telegram (`ru.keepcoder.Telegram`) on the visible workspace.
   - Two Codex windows (`com.openai.codex`), with at least one Codex window in a
     non-active workspace or recently used as the layout/focus reference.
3. Restart/reload Nehir or otherwise force a fresh admission cycle while a Codex
   window is the last/frontmost managed window, then switch interaction to the
   workspace containing Telegram.
4. Click/focus Telegram so it accepts typing.
5. Hold Shift and click a different workspace pill in the workspace bar.

Expected: Telegram's token moves to the clicked workspace.

Bug: a Codex token moves instead. Validate by dumping runtime state after the
click: Telegram remains in its original workspace, while a Codex token appears
in the clicked workspace and `lastAffectedWorkspaceIdsByReason` records a
workspace transition involving the source workspace and clicked workspace.

The captured bad result had Telegram token `55316:351` still in workspace
`04A28B7E-E0AF-419F-AC36-137BFEA1FE14`, while Codex token `11877:20053` ended in
workspace `7C3199AC-1A27-4A48-BCBE-A7A7C9899735`.

### Repro 2: non-managed-focus state makes Shift-click no-op

Goal: create the exact no-op precondition: Telegram is the selected/observed
managed window, but non-managed focus is still active.

1. Use the same one-display workspace-bar setup.
2. Focus Telegram and verify it accepts typing.
3. Trigger a non-managed or ignored overlay/app focus transition, then return
   keyboard input to Telegram without clearing Nehir's non-managed-focus flag.
   In the capture this involved an ignored Ghostty quick-terminal overlay: its
   focused admission was rejected as a built-in unmanaged rule, followed by
   `non_managed_fallback_entered pid=82494 source=focusedWindowChanged`.
4. Before clicking, validate this Focus Targets state in diagnostics/runtime
   dump:

   ```text
   wmCommandTarget=nil
   layoutSelection=WindowToken(pid: <Telegram pid>, windowId: <Telegram window>)
   observedManagedFocus=WindowToken(pid: <Telegram pid>, windowId: <Telegram window>)
   nonManaged=true
   ```

5. Hold Shift and click a different workspace pill.

Expected: Telegram moves to the clicked workspace, because it is the selected
managed window and accepts typing.

Bug: nothing moves. Validate that no new workspace transition is recorded and
that the clicked workspace did not receive Telegram.

## Fix direction

The bar Shift-click path should not ask `managedCommandTarget()` to rediscover a
window in states where the bar already has a better managed target. Candidate
approaches:

- Add a token-explicit workspace-bar move entry point, e.g.
  `moveWindowFromBar(token:toWorkspaceId:)`, and have Shift-click choose the
  visible selected/focused token from the bar snapshot/active workspace instead
  of `managedCommandTargetToken()`.
- Or add a bar-specific resolver that, under non-managed focus, is allowed to use
  `layoutSelectionCommandTarget()` / confirmed managed focus for the active
  interaction workspace before returning `nil`.

Whichever path is chosen, validation must cover both captured states: a stale
Codex command target must not move when Telegram is selected, and a
`nonManaged=true` state with `layoutSelection=Telegram` must still move Telegram
instead of no-oping.
