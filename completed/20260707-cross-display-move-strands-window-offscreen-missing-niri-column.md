# Moving a window to an inactive cross-display workspace can strand it off-screen with no niri column — Completed

Discovery 2026-07-07. **STATUS: SHIPPED 2026-07-07** on `main` in commit
`7a025b78` ("Verify window liveness before honoring a spurious AX destroy on cold
start"). The fix removed the **trigger** (a spurious AX destroy) rather than
reconciling the downstream desync — see "Resolution (what actually shipped)"
below. This document is retained as the confirmed root-cause record; its
originally-proposed fix directions were **not** the ones taken.

Symptom (as captured): moving the focused window to an **inactive** workspace that
lives on **another display**, then switching to that workspace, left the workspace
visibly **empty** — the window was still tracked as a normal tiled window but was
physically parked off-screen with **no column in the niri layout engine**, so
nothing repositioned it on-screen. The captured cross-display move was one
manifestation of a broader spurious-AX-destroy problem that could also wipe
managed windows on a cold start (see the shipped changeset, "Stop wiping all
managed windows on a cold start when macOS fires spurious AX destroy
notifications").

This symptom survived the 2026-07-06 same-app follow-focus reveal fix (completed
`20260706-same-app-focus-switch-reveals-inactive-workspace-window.md`): that
reveal path **did fire** here (`follow_focus_to_parked_window decision=switch`)
but could not help, because a window with no niri column gets no layout frame.

The evidence and root-cause analysis below were verified against the main Nehir
source tree at `4f9e5682` ("Re-center lone survivor after manual-resize move to
another workspace") — the exact build the capture ran on (`nehir v4f9e56` in the
trace header). The resolution below is against `7a025b78`. Line numbers drift;
function names are included so the code stays findable. No trace-log filenames are
referenced; every runtime value is inlined.

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
- **Verdict.** SHIPPED. The desync described here was a **downstream symptom** of a
  spurious AX destroy. The fix (`7a025b78`) suppresses the spurious destroy at the
  source, so the destroy→re-admit churn — and therefore the desync — no longer
  happens. The reconcile-the-desync directions this doc originally proposed were not
  needed. See "Resolution (what actually shipped)".

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

## Resolution (what actually shipped)

Landed on `main` in commit `7a025b78` ("Verify window liveness before honoring a
spurious AX destroy on cold start"), together with the confirming tracing (below).
Changeset (patch): "Stop wiping all managed windows on a cold start when macOS
fires spurious AX destroy notifications."

**The trigger, not the desync, was fixed.** The `#8 window_removed phase=destroyed`
in the evidence above was a **spurious AX destroy** — macOS reported window `7619`
as destroyed while the WindowServer still had it alive. Every downstream problem
(re-admission via focused-admission, the WindowModel↔niri divergence, the stranded
off-screen frame) flowed from honoring that false destroy. Rather than reconcile the
divergence after the fact, the fix stops honoring the spurious destroy:

- `handleWindowDestroyed(windowId:pidHint:verifyWindowServerLiveness:)`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift`) gained a
  `verifyWindowServerLiveness` flag. **AX-observed** destroys
  (`handleRemoved(pid:winId:)`) pass `true`; **CGS `.created`/destroyed** events
  (the trusted source) pass `false`.
- When `verifyWindowServerLiveness` is `true` and the WindowServer **still reports
  the window** (`resolveWindowInfo(windowId)?.pid == token.pid`), the destroy is
  **not** honored immediately. Instead `scheduleDestroyLivenessVerification(for:)`
  waits `postCreateLifecycleVerificationDelay`, warms the AX context, and only calls
  `handleRemoved(token:)` if the WindowServer confirms the window is **actually
  gone** (`resolveWindowInfo(windowId) == nil`). A real close still removes the
  window after the short verification; a spurious destroy is dropped.
- Supporting refactor: `isEntryOnScreen` and the new liveness math now share
  `Monitor.isFrameOnScreen(_:across:minimumVisibleFraction:)` /
  `Monitor.visibleOverlapArea(of:across:)` (`Sources/Nehir/Core/Monitor/Monitor.swift`).

Because the window is never destroyed mid-move, the focused-admission re-admit and
the deferred-niri-removal-vs-re-admit race described under "Root cause" no longer
occur. The reconcile/cancel-pending-removal directions this doc originally proposed
were therefore **not implemented** and are not needed for this bug. The confirmed
gating gap (no `cancelWindowRemoval`; a deferred niri removal is not invalidated by
a same-id re-admit) still exists in the abstract, but with the spurious-destroy
trigger gone it is no longer reachable by this path. If a *genuine* same-id
destroy→re-admit race is ever observed again, reopen with those directions as the
starting point.

### Confirming tracing (also shipped in `7a025b78`)

The instrumentation used to pin this — added on branch
`trace/niri-windowmodel-desync` and folded into `7a025b78` — is now in `main`:

- `reason=windowmodel_niri_desync` — post-refresh membership invariant: an
  active-workspace WindowModel tiling entry with no niri node.
- `reason=window_removal_seed_check` — at removal execution: whether a removal seed
  node id is stale against a live re-admitted token.
- `reason=readmit_pending_removal` — at focused-admission re-add: whether an
  in-flight `WindowRemovalPayload` exists for the same workspace/token (via the new
  read-only `LayoutRefreshController.pendingWindowRemovalPayload(for:workspaceId:)`).

These remain useful regression instrumentation for any future WindowModel↔niri
divergence, independent of this specific fix.
