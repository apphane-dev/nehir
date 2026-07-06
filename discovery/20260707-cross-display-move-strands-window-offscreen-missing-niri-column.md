# Moving a window to an inactive cross-display workspace can strand it off-screen with no niri column — Discovery

Discovery (2026-07-07). **STATUS: open, actionable.** Moving the focused window
to an **inactive** workspace that lives on **another display**, then switching to
that workspace, can leave the workspace visibly **empty**: the window is still
tracked as a normal tiled window but is physically parked off-screen and has **no
column in the niri layout engine**, so nothing ever repositions it on-screen.

This survives the 2026-07-06 same-app follow-focus reveal fix (completed
`20260706-same-app-focus-switch-reveals-inactive-workspace-window.md`): that
reveal path **does fire** here (`follow_focus_to_parked_window decision=switch`)
but cannot help, because a window with no niri column gets no layout frame.

All source references were verified against the main Nehir source tree at
`4f9e5682` ("Re-center lone survivor after manual-resize move to another
workspace") — the exact build the capture ran on (`nehir v4f9e56` in the trace
header). Line numbers drift; function names are included so the code stays
findable. No trace-log filenames are referenced; every runtime value is inlined.

---

## TL;DR

- **Symptom.** Move focused window → workspace N (inactive, on a second display),
  switch to N → N appears empty; the window is nowhere on screen.
- **Observed divergence (the smoking gun).** At rest, `WorkspaceManager`/WindowModel
  reports the window `phase=tiled hidden=nil` on the now-visible target workspace,
  while the niri engine reports that workspace as **`no-columns`**. The two models
  disagree about whether the window is in the layout.
- **Consequence.** A managed tiling window absent from the niri column tree is never
  assigned a layout frame, so it keeps whatever frame was last written to it — here,
  the **workspace-inactive parking frame** off the left edge of the second display.
  It stays invisible.
- **Confirmed gating gap.** A window destroy removes the token from WindowModel
  **synchronously** but only **defers** the niri-column removal (seeded by the
  node id captured at destroy time). The **focused-admission** re-admit path
  re-adds the same window id to WindowModel (and requests a fresh niri insert) with
  **no cancellation or reconciliation** of that in-flight niri removal. Nothing
  ties the two refresh requests together.
- **Verdict.** Actionable. Root-cause *shape* is source-confirmed; one interleaving
  detail (below) is worth pinning with a targeted assertion before/inside the fix.

---

## Topology and initial state (to reproduce)

Two displays, arranged so the second sits **below-left** of the built-in:

- **Display 1** (built-in Retina, main): frame `(0, 0, 2056, 1329)`. Hosts the
  origin workspace.
- **Display 2** (DELL P2423D): frame `(-1171, 1329, 2560, 1440)`. Hosts the target
  workspace. Note its x-range is `[-1171, 1389]`.

Windows/actors:

- Target window: `com.microsoft.teams2`, pid `72005`, AX window id `7619`. It had
  been **manually resized** on the origin workspace (niri column
  `override=1632`, live frame `212,7,1632,1251` on display 1). Teams is an
  Electron app that churns AX window identity.
- Origin workspace: `BB56CE6D…` ("ws2"), visible on display 1, `7619` focused there.
- Target workspace: `C0F8AF80…` ("ws7"), **inactive**, belongs to display 2.

Action: move focused window to ws7, then switch to ws7.

---

## What the runtime did (evidence, inlined)

**1. Move to ws7 parks the window off-screen (ws7 is inactive at this moment).**

```
event=workspace_assigned token=(pid 72005, windowId 7619)
      from=BB56CE6D… to=C0F8AF80…
hideOrigin.resolve reason=workspaceInactive side=left result=(-2802,1329) frame=(212,7 1632x1251)
hidePlan.apply    id=7619 requestedOrigin=(-2802,1329) frameSize=1632x1251
hidePlan.final    id=7619 requested=(-2802,1329 1632x1251) observed=(-2802,1329 1632x1251) verified=true
```

The parking frame `(-2802, 1329)` sits entirely left of display 2 (which starts at
x `-1171`; `-1171 − 1632 = −2803 ≈ −2802`). This is the **last AX frame ever
written to this window**. At this point ws7's niri layout *did* contain the column
(one column, selected node `D0F44592…`, window target `-654,1336,1526,1371` on
display 2).

**2. The window token churns: destroyed, then re-admitted.**

```
#8  event=window_removed  token=(pid 72005, windowId 7619) workspace=C0F8AF80… phase=destroyed
...
#12 event=window_admitted token=(pid 72005, windowId 7619) workspace=C0F8AF80…
      context=focused_admission interaction=display 2 / prev=display 1 phase=tiled
```

The re-admission comes through the **focused-admission** path because Teams becomes
frontmost as ws7 is switched to:

```
window_decision token=(pid 72005, windowId 7619) context=focused_admission
      disposition=managed outcome=trackedTiling  wsFrame=(-2802.0,-1251.0,1632.0,1251.0)
create_placement_resolved token=(…7619) workspace=C0F8AF80…
      focused_workspace=BB56CE6D… focused_workspace_source=recent_pid
      context_source=ax_focused_admission_synthesized interaction_monitor=display 2
candidate_tracked token=(…7619) workspace=C0F8AF80…
```

Note `wsFrame=(-2802,-1251,1632,1251)` — the WindowServer still has the window at
the parked (off-screen) location.

**3. Switch-to-ws7 reveal fires but cannot place a column-less window.**

```
reveal_decision token=(…7619) target_ws=C0F8AF80… is_ws_active=true should_activate=false target_ws_visible=true
focus_reality  token=(…7619) observed_focused=false observed_visible=true on_screen=false ws_visible=true app_frontmost=true
follow_focus_to_parked_window token=(…7619) workspace=C0F8AF80… decision=switch
relayout_activated_window     token=(…7619) workspace=C0F8AF80…
ax_focus_confirm_reveal_skipped token=(…7619) preserveActiveViewport=true
```

`follow_focus_to_parked_window decision=switch` is the 2026-07-06 reveal fix doing
its job — it detected the window is `on_screen=false` and switched/relayouted. But
the relayout has no column to place.

**4. End state — the divergence.**

WindowModel / `WorkspaceManager`:

```
WindowToken(pid 72005, windowId 7619) workspace=C0F8AF80… mode=tiling phase=tiled
   hidden=nil  observedVisible=true
   liveAXFrame={{-2802.0, 1329.0}, {1632.0, 1251.0}}
   replacementFrame={{-2802.0, -1251.0}, {1632.0, 1251.0}}
focus focused=72005:7619   interaction current=display 2
```

niri engine, same workspace, same instant:

```
-- Niri Viewports --
workspace=7 id=C0F8AF80… visible=true columns=0 preferredFocus=(pid 72005, windowId 7619)
-- Niri Layout Decisions --
workspace=7 id=C0F8AF80… no-columns
LayoutRefreshController: windowRemoval=1  executedByReason=[… windowDestroyed: 1 …]
```

So: WindowModel says "tiled, not hidden, on the visible workspace, focused" while
the niri engine says the workspace has **zero columns**. The window's live AX frame
is exactly the parked frame from step 1 — it was never moved back on-screen.

---

## Root cause

Two independent models of "is this window in the layout" diverged, and the frame
writer is driven by the niri model while `hidden=nil` is set by the WindowModel.

### Confirmed: destroy defers a niri-only column removal that nothing cancels

`handleRemoved(token:)` (`Sources/Nehir/Core/Controller/AXEventHandler.swift`,
~:1569):

- **Synchronously** removes the token from WindowModel:
  `controller.workspaceManager.removeWindow(pid:windowId:)` (~:1617).
- Captures the **current** niri node id (`engine.findNode(for: token)?.id`, ~:1613)
  and **defers** the niri-engine column removal:
  `controller.layoutRefreshController.requestWindowRemoval(workspaceId:removedNodeId:niriOldFrames:shouldRecoverFocus:)`
  (~:1622).

`requestWindowRemoval` (`LayoutRefreshController.swift` ~:826) enqueues a
`WindowRemovalPayload` carrying that node id. It is applied later by
`buildWindowRemovalExecutionPlan` (~:1162), which collects `removalSeeds` keyed on
the destroy-time `removedNodeId` (~:1171) and calls
`niriHandler.layoutWithNiriEngine(activeWorkspaces:useScrollAnimationPath:removalSeeds:)`
(~:1192). This step mutates **only** the niri engine; it never re-checks WindowModel.

The re-admit path — `admitFocusedWindowBeforeNonManagedFallback` →
`trackPreparedCreate` (`AXEventHandler.swift` ~:2835 / ~:1291) — re-adds the same
window id to WindowModel and requests a **separate** `.axWindowCreated` refresh
(~:1319) to re-insert the column. There is **no `cancelWindowRemoval`** in
`LayoutRefreshController`, and the create path does not reconcile against or
invalidate an in-flight window-removal payload for the same window id / workspace.

Result: a destroy's deferred niri-column removal remains armed across a
same-window-id re-admission. When it executes after the re-admit, the niri engine
ends column-less for a window WindowModel still considers a live, non-hidden,
focused tiling window. The window keeps its last-written frame — the off-screen
parking frame — and there is no layout column to ever move it back.

### Why the reveal fix doesn't rescue it

The 2026-07-06 follow-focus reveal (`followFocusToParkedWindowWorkspaceIfNeeded`,
called from `handleManagedAppActivation` ~:2998) correctly detects
`on_screen=false` and issues `activateWorkspace(focusing:)` → relayout. But
relayout places windows from niri columns; with `no-columns` on ws7 the relayout
is a no-op for `7619`. The reveal fix assumed the parked window is present in the
layout and only the *viewport/active-workspace pointer* is wrong. Here the window
is missing from the layout entirely, which is a different failure.

### Contributing trigger: focused-admission on an Electron identity churn

The churn that destroys and re-admits `7619` mid-move is the same
focused-admission-vs-managed-replacement seam described in planned
`20260625-vscode-focused-admission-skips-managed-replacement-rekey.md` and completed
`20260630-visible-unmanaged-windows-admitted-late-as-columns.md`: an Electron app
(`com.microsoft.teams2`) re-surfaces its window through an AX **focus** event, and
the focused-admission route admits it as a fresh entry rather than reconciling with
the in-flight destroy. The cross-display + inactive-target move is what makes the
stranded frame land **off-screen** (parked) instead of merely mis-placed.

---

## Residual question to pin before/inside the fix

Source confirms the divergence is *possible* (deferred niri removal not cancelled
by same-id re-admit). The captured evidence shows the niri node id changed across
the churn (`D0F44592…` before destroy → `8039D2BF…` after re-admit), so it is worth
confirming **which** interleaving actually empties ws7:

- (a) the deferred removal (seeded with the **old** node id) is applied *after*
  re-insert and still drops the workspace's only column; or
- (b) the re-insert never persists because the removal refresh and the create
  refresh coalesce and the removal wins.

Confirm by adding a transient invariant check at the end of each layout refresh:
for every WindowModel tiling entry whose workspace is active, assert the niri engine
has a node for its token (or trace the mismatch with the removal-seed node id vs the
live node id). This turns the "shape" into an exact, test-backed trigger.

---

## Recommended direction (for a follow-up `planned/` doc)

Do **not** patch the reveal path further — the layout model is the source of truth
and it is the one that is wrong. Candidate fixes, cheapest first:

1. **Cancel/reconcile the pending niri removal on same-id re-admit.** When
   `trackPreparedCreate` (or the shared admission entry) admits a window id that has
   an in-flight `WindowRemovalPayload` for the same workspace, drop/replace that
   payload (add a `cancelWindowRemoval(windowId:workspaceId:)` to
   `LayoutRefreshController`). Most targeted; addresses the confirmed gating gap.
2. **Seed removals by token, and skip the removal if WindowModel still tracks the
   window** at execution time in `buildWindowRemovalExecutionPlan`. Defensive: makes
   the deferred niri removal idempotent against a live re-admit regardless of node-id
   churn.
3. **Post-refresh invariant repair.** After a layout refresh, for any active-workspace
   WindowModel tiling entry missing a niri node, re-insert it (and re-run placement).
   Broadest safety net; also covers other paths that could desync the two models.

Prefer (1) + the invariant assertion from the residual-question section as a
regression guard; consider (2) as belt-and-suspenders.

**Do-not-touch note for whoever plans/implements:** this is adjacent to but distinct
from the in-flight focused-admission-rekey work
(`planned/20260625-vscode-focused-admission-skips-managed-replacement-rekey.md`,
which folds identity churn onto the existing entry). If that lands first it may
change the churn shape here — re-verify this repro against `main` before writing the
plan.
