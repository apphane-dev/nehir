# Internal-display new-window placement still lacks a durable user-intent affinity

**Status:** actionable policy/observability gap; the reported visible failure is **not reproduced in the available post-WIP capture**. The rejected WIP is proven inert for the recorded admissions and must not be revived as-is. No fix is claimed working or validated.

Verified against `main` at `3056bee8` on 2026-07-14. Companion plan: [`../planned/20260714-internal-display-new-window-placement.md`](../planned/20260714-internal-display-new-window-placement.md).

## Verdict

Commit `3056bee8` fixed the external-display case by adding a cursor-derived monitor as a late create-placement signal. The inverse report remains: after explicitly activating an internal-display workspace, with the Ghostty quick terminal and pointer reportedly on that display, a new ordinary window can still appear on the external display.

The durable source gap is that create placement snapshots values (`focusedWorkspaceId`, `interactionMonitorId`, `cursorMonitorId`) but not the **provenance and recency of an explicit workspace activation**. Consequently the resolver cannot distinguish:

- “the user explicitly selected this workspace/display immediately before creating a window”, from
- stale managed focus, a recent same-pid admission, an ordinary cursor position, or macOS's initial frame.

The latest captured sequence does not itself show the reported external landing. It instead proves that the rejected WIP did not participate and reveals a contradiction that the next implementation must make observable: the user's stated pointer location was the internal display, while every relevant placement context resolved `cursor_monitor=display 2` (the HP external display).

## Observed facts

### Topology and initial state

```text
display 1: Built-in Retina Display, isMain=true
  frame=(0,0 1728x1117), visibleFrame=(0,0 1728x1084)
display 2: HP Z27k G3
  frame=(-134,1117 1920x1080), visibleFrame=(-134,1117 1920x1050)
```

At capture start:

```text
interactionWorkspace=6C7E0B39-88A5-49A9-B63A-9ECC8C3E6690
interactionMonitor=display 1
nonManaged=true
focused=nil
workspace 2 id=6C7E0B39-88A5-49A9-B63A-9ECC8C3E6690 visible=true columns=0
workspace 6 id=A45EA252-C3E0-40E4-A559-4730E9991204 visible=true columns=0
```

Thus Nehir's stored interaction state and the active empty workspace both identify the internal display. The pointer resolver, however, later identifies display 2.

### Quick-terminal and ordinary-window sequence

Ghostty pid `82494` first exposed quick-terminal window `5915`:

```text
window_decision token=82494:5915 context=focused_admission
  disposition=unmanaged source=builtInRule(ghosttyQuickTerminalOverlay)
  axSubrole=AXFloatingWindow level=101 frame=(0,-726 1728x759)
prepare_create_rejected window=5915 reason=untracked_decision
  create_context_source=ax_focused_admission_synthesized
```

The ordinary Ghostty window `82494:58371` was then admitted before its CGS create event:

```text
window_decision token=82494:58371 context=focused_admission
  disposition=managed axSubrole=AXStandardWindow frame=(179,65 847x1045)
create_placement_resolved token=82494:58371
  workspace=6C7E0B39-88A5-49A9-B63A-9ECC8C3E6690
  pending_workspace=nil pending_monitor=nil
  focused_workspace=6C7E0B39-88A5-49A9-B63A-9ECC8C3E6690
  focused_monitor=display 1 focused_workspace_source=recent_pid
  native_monitor=nil frame_monitor=display 1
  interaction_monitor=display 1 cursor_monitor=display 2
  context_source=ax_focused_admission_synthesized
candidate_tracked token=82494:58371 workspace=6C7E0B39-...
window_admitted token=82494:58371 workspace=6C7E0B39-... monitor=display 1
focus_confirmed token=82494:58371 workspace=6C7E0B39-...
create_seen window=58371
```

The resolved workspace and monitor are internal display 1. At capture end the window remained assigned there (`workspace=6C7E0B39-...`, desired monitor `display 1`); its offscreen `x=1727` frame was Niri's horizontal parking state, not display-2 geometry (display 2 is vertically below at `y>=1117`).

Two Finder admissions show the same signal conflict:

```text
token=60520:58367 source=confirmed_focus frame_monitor=display 1
  interaction_monitor=display 1 cursor_monitor=display 2
  resolved workspace=6C7E0B39-... (display 1)

token=60520:58374 source=confirmed_focus frame_monitor=display 1
  interaction_monitor=display 1 cursor_monitor=display 2
  resolved workspace=6C7E0B39-... (display 1)
```

Therefore this capture is useful negative evidence, not runtime confirmation of the user's visible symptom. The unresolved possibilities are: the pointer-to-screen observation disagreed with physical reality at admission; the reported external landing occurred outside the retained create-focus events; or the visible symptom is a later frame/layout move rather than initial workspace resolution.

### Contrast: the external-display case

An earlier capture from the now-shipped external-display flow had active/focused placement on display 2 while the cursor was on display 1. Ordinary Ghostty window `82494:56658` resolved to display 2:

```text
focused_workspace=D782E0EE-D9D7-482A-874D-A802EA72D9D8
focused_monitor=display 2 interaction_monitor=display 2
cursor_monitor=display 1 frame_monitor=display 1 native_monitor=nil
resolved workspace=D782E0EE-... (display 2)
```

Finder `60520:56661` and Ghostty `82494:56663` followed the same display-2 focused/interaction affinity despite cursor/frame disagreement. This is an important regression fence: cursor must not always win for ordinary keyboard-created windows.

## Source-confirmed mechanism

### What the placement context knows

`WindowCreatePlacementContext` stores native space, active focus request, focused workspace/monitor, interaction monitor, cursor monitor, source, and recent-pid workspace (`Sources/Nehir/Core/Controller/AXEventHandler.swift:317-333`). It has no explicit-workspace-activation id, source, generation, or age.

AX-first admission synthesizes the context in `ensureCreatePlacementContextForFocusedAdmission` (`AXEventHandler.swift:7018-7037`). `makeCreatePlacementContext` prefers confirmed managed focus, then a recent same-pid workspace (`:7047-7055`), and snapshots interaction and cursor monitors independently (`:7056-7069`). The pointer monitor comes from strict `NSScreen` containment (`:7073-7095`). Thus `focused_workspace_source=recent_pid` and `cursor_monitor=display 2` in the observed Ghostty event are exactly source-supported outputs, not inferred trace semantics.

### Existing authority order

`resolveWorkspacePlacement` preserves, in order, an existing entry, an explicit move target, structural replacement, and tracked-parent inheritance before it asks generic create placement (`Sources/Nehir/Core/Controller/WMController.swift:1230-1262`). Configured workspace rules are handled later (`:1277-1284`).

For a new tiled window, `createPlacementTarget` checks:

1. explicit move (`WMController.swift:1473-1475`);
2. active managed focus request (`:1477-1483`);
3. native Space (`:1485-1493`);
4. focused/frame/interaction arbitration and confirmed/recent-pid focus (`:1495-1544`);
5. cursor fallback only after those stronger branches (`:1547-1572`);
6. interaction/native/frame fallbacks (`:1593-1689`).

This ordering explains the captured internal result: `focused_workspace=6C7E0B39-...` and `focused_monitor=display 1` reach `managedFocusPlacementTarget` at `:1539-1544` before the cursor fallback. It also explains the successful external case: display-2 managed focus beats a display-1 cursor.

### Explicit workspace activation is real intent but loses provenance

User-facing workspace activation calls `WorkspaceManager.setActiveWorkspace` (`Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:503` in `activateWorkspace`; other navigation paths use the same manager API). The public manager method defaults `updateInteractionMonitor=true` (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3506-3517`). `setActiveWorkspaceInternal` updates the visible workspace and then writes only the interaction monitor id (`:4336-4358`). No durable record says that this value came from an explicit user workspace activation, which workspace was selected, how recently, or whether later focus events superseded it.

That missing provenance is the actionable root cause at the policy boundary: placement cannot give explicit workspace selection a narrowly scoped affinity distinct from generic interaction/cursor state.

## Why rejected WIP `ccb50dc4` did not solve the sequence

The WIP added `hasNonManagedFocusContext` and `staleManagedFocusCursorPlacementTarget`. Its predicate required all of:

```text
non-managed focus context = true
focused_workspace_source = confirmed_focus
cursor monitor != focused monitor
WindowServer frame center contained by no monitor
nearest approximated frame monitor == cursor monitor
```

It was called both before returning a structural replacement and inside the focused-monitor branch.

It could not fire for `82494:58371` because two required facts were false:

- `focused_workspace_source=recent_pid`, not `confirmed_focus`;
- frame `(179,65 847x1045)` is genuinely on display 1, while `cursor_monitor=display 2`; it is neither offscreen nor approximated to the cursor monitor.

It could not fire for Finder `60520:58367` or `60520:58374` either: although their source was `confirmed_focus`, their on-screen display-1 frames did not satisfy the offscreen/approximated-to-cursor conditions.

More importantly, the WIP attempted to bypass `structuralReplacementWorkspaceId` when its cursor predicate matched. Current source returns structural replacement before generic placement (`WMController.swift:1241-1246`). Without evidence that a structural match is provisional rather than a real destroy/create replacement, bypassing it risks splitting a replacement from its preserved workspace. Fence this approach out: do not override structural replacement merely because non-managed focus and cursor evidence disagree with managed focus.

## Root-cause confidence and uncertainty

### Proven

1. Explicit workspace activation updates an interaction monitor value but records no placement-intent provenance.
2. AX-first create contexts independently snapshot focused/recent-pid, interaction, frame, native-space, and cursor signals.
3. The rejected WIP predicate is false for every relevant admission in the available post-WIP capture.
4. The post-WIP capture resolves the new Ghostty and Finder windows to internal display 1, not external display 2.
5. The cursor signal in that capture says display 2, contradicting the reported physical pointer location.

### Not proven

1. Which event produces the user-visible external landing in the still-failing repro.
2. Whether initial workspace resolution is wrong in that run, or a later layout/frame operation moves a correctly resolved window.
3. Whether AppKit cursor-to-screen resolution is wrong, the pointer moved before admission, or the report and capture delimit different moments.
4. The safe lifetime/consumption rule for a new explicit-workspace placement affinity.

These uncertainties require instrumentation and user confirmation before any success claim.
