# Workspace assignment visibility + lone-window width cache leak — Discovery

**Status:** completed — implemented in the main Nehir source tree on 2026-06-19.
Resolution and implementation learning are captured in the completed plan
[`completed/20260619-workspace-assignment-lone-window-width-and-reveal.md`](20260619-workspace-assignment-lone-window-width-and-reveal.md).
This document is kept as the self-contained runtime-evidence record.

Scope: document the failed lone-window-width fix and the runtime evidence from the
workspace-assignment repros. The goal is to preserve the concrete evidence and
separate the real model change from shortcut fixes that only reset `cachedWidth`.

All source references below were checked against the main Nehir source tree on
2026-06-19. Line numbers drift — they describe the pre-implementation code shape.

---

## TL;DR

- **Two defects are visible in the repros:**
  1. A window assigned to an inactive workspace can later be modeled as tiled,
     unhidden, selected, and focused while its live frame remains parked at the
     right edge of the display. The model says “visible workspace / tiled
     window”; the physical frame is effectively offscreen.
  2. The lone-window `.fill` width leaks into column sizing. After a workspace
     has one filled lone window, moving/adding a second column can leave the
     first column at full working-area width (`2040`) while the new column is the
     normal balanced half width (`1008`).
- **The failed override attempt was directionally right but incomplete.** Its
  debug output showed `override=nil` after a second column was added, but the
  first column still had `cached=2040.0`. That proves the single-window render
  width had already polluted the canonical column cache.
- **Verdict:** ✅ Resolved (implemented 2026-06-19). The width bug was fixed as a
  model split: canonical column `cachedWidth` is now separate from the transient
  lone-window render/layout override (`loneWindowLayoutWidthOverride`), and
  viewport/snap geometry resolves through a single `effectiveViewportWidth` entry
  point so the split does not desync render width from scroll/snap math. The fix
  did **not** clear `cachedWidth` opportunistically. Separately, the
  workspace-inactive reveal path now verifies onscreen placement before clearing
  hidden state. See the completed plan for the second-stage viewport-width
  learning that the storage split alone was insufficient.

---

## User-visible repros captured

### Repro A — assign last window to workspace 3, then observe workspace 3

The window was assigned from workspace 1 to workspace 3 while workspace 3 was not
active:

```text
event=workspace_assigned token=WindowToken(pid: 48530, windowId: 1851)
from=77947EF9-E740-4DA8-AB61-B1523B22C7B0
to=4162EFCB-6B56-4010-A903-FAE561280BBE
plan=desired=workspace=4162EFCB-6B56-4010-A903-FAE561280BBE,mode=tiling

event=hidden_state_changed token=WindowToken(pid: 48530, windowId: 1851)
workspace=4162EFCB-6B56-4010-A903-FAE561280BBE hidden=true plan=phase=hidden
```

When workspace 3 was activated, Nehir cleared hidden state and focused the same
token:

```text
event=hidden_state_changed token=WindowToken(pid: 48530, windowId: 1851)
workspace=4162EFCB-6B56-4010-A903-FAE561280BBE hidden=false plan=phase=tiled

event=managed_focus_confirmed token=WindowToken(pid: 48530, windowId: 1851)
workspace=4162EFCB-6B56-4010-A903-FAE561280BBE
plan=focus=focused=WindowToken(pid: 48530, windowId: 1851),pending=nil
```

At the end of the run, the model still said workspace 3 was visible and selected
that token:

```text
interactionWorkspace=4162EFCB-6B56-4010-A903-FAE561280BBE
layoutSelection=WindowToken(pid: 48530, windowId: 1851)
observedManagedFocus=WindowToken(pid: 48530, windowId: 1851)

workspace=3 id=4162EFCB-6B56-4010-A903-FAE561280BBE visible=true columns=1
selectedNode=NodeId(uuid: BA6F472A-547F-4D39-9E2B-EFEF73C3B32F)
preferredFocus=WindowToken(pid: 48530, windowId: 1851)
```

But the physical frame was still at the right edge of a `2056`-wide display:

```text
WindowToken(pid: 48530, windowId: 1851)
workspace=4162EFCB-6B56-4010-A903-FAE561280BBE mode=tiling phase=tiled hidden=nil
liveAXFrame={{2055.0, 0.0}, {2040.0, 1267.0}}
replacementFrame={{2055.0, 0.0}, {2040.0, 1267.0}}

AX state for windowId=1851:
lastApplied={{8.0, 0.0}, {2040.0, 1267.0}}
failure=verificationMismatch
```

The layout target wanted the window at `x=8`, but verification saw it at `x=2055`
(or with a slightly rejected width):

```text
failed id=1851 target={{8.0, 0.0}, {2040.0, 1267.0}}
observed={{2055.0, 0.0}, {1955.0, 1267.0}}
reason=verificationMismatch

failed id=1851 target={{8.0, 0.0}, {2040.0, 1267.0}}
observed={{8.0, 0.0}, {2038.0, 1267.0}}
reason=verificationMismatch
```

**Finding:** the workspace/session model can advance to `phase=tiled hidden=nil`
while the window remains at the offscreen parking edge or in a failed frame-write
state. The UI symptom matches “workspace 3 has no visible assigned window” even
though the model has an assigned/focused tiled entry.

### Repro B — assign two windows to workspace 4, then observe workspace 4

Workspace 4 began empty. The first moved window entered it alone, so the
lone-window policy rendered it at full working-area width:

```text
event=workspace_assigned token=WindowToken(pid: 15217, windowId: 7040)
from=9F48D86C-35E8-4DD3-8E93-BBC23CE22635
to=38142F08-0D3D-4C39-A31F-C77CD5613CB0

workspace=4 id=38142F08-0D3D-4C39-A31F-C77CD5613CB0 columns=1
layout=c0[x=0.0,cached=2040.0,override=2040.0,spec=prop:0.5000]
{w7040:selected{cur=8,0,2040,1267,target=8,0,2040,1267}}
```

A second window was then assigned to the same workspace:

```text
event=workspace_assigned token=WindowToken(pid: 9464, windowId: 227)
from=9F48D86C-35E8-4DD3-8E93-BBC23CE22635
to=38142F08-0D3D-4C39-A31F-C77CD5613CB0
```

Once workspace 4 had two columns, the failed override attempt did clear the
single-window override (`override=nil`), but the first column's cache was already
full width:

```text
workspace=4 id=38142F08-0D3D-4C39-A31F-C77CD5613CB0 columns=2
activeColumnIndex=1 currentViewStart=666.2 targetViewStart=1532.0
layout=
c0[x=0.0,cached=2040.0,override=nil,spec=prop:0.5000]
  {w7040{cur=-658,0,2040,1267,target=-1524,0,2040,1267}}
|c1[x=2048.0,cached=1008.0,override=nil,spec=prop:0.5000]
  {w227:selected{cur=1390,0,1008,1267,target=524,0,1008,1267}}
```

At the end of the run, workspace 4 was still visible with the same imbalanced
column widths:

```text
workspace=4 id=38142F08-0D3D-4C39-A31F-C77CD5613CB0 visible=true columns=2
activeColumnIndex=0 currentViewStart=0.0 targetViewStart=0.0

c0[x=0.0,cached=2040.0,override=nil,spec=prop:0.5000]
  {w7040:selected{cur=8,0,2040,1267,target=8,0,2040,1267}}
|c1[x=2048.0,cached=1008.0,override=nil,spec=prop:0.5000]
  {w227{cur=2056,0,1008,1267,target=2056,0,1008,1267}}
```

Expected with `spec=prop:0.5000` and normal gaps on this monitor is approximately
`1008` per balanced column. The `2040` first column is the lone-window `.fill`
render width leaking into normal multi-column layout.

---

## Current code shape

### `cachedWidth` is both canonical state and single-window render result

`NiriContainer` has a single mutable cache field:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:379-382
var width: ProportionalSize = .default
var cachedWidth: CGFloat = 0
```

Multi-column layout treats that cache as the actual column span:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:200-226
if container.cachedWidth <= 0 {
    container.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: primaryGap)
}
let containerSpans = containers.map { $0.cachedWidth }
```

The lone-window path computes the fill/centered width without a manual override,
but then writes the resulting lone-window rect width back into the same cache:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:700-712
private func resolvedSingleWindowWidth(...) -> CGFloat {
    guard context.container.hasManualSingleWindowWidthOverride else {
        return workingFrame.width * CGFloat(context.maxWidthFraction.clamped(to: 0.0 ... 1.0))
    }
    ...
    return max(0, context.container.cachedWidth)
}
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:817-825
let geometry = singleWindowViewportGeometry(...)
context.container.cachedWidth = geometry.rect.width
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:879-885
let geometry = singleWindowViewportGeometry(...)
let canonicalRect = geometry.rect
context.container.cachedWidth = canonicalRect.width
```

So a default lone `.fill` render on a `2040` working area mutates the column's
only cached width to `2040`, even when `column.width` still says
`.proportion(0.5)`.

### Admission resets one path; workspace moves do not fix the model

New-window admission has a one-off reset when adding a second window to a root
that currently has one window:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:146-149
if root.allWindows.count == 1 {
    for column in root.columns where !column.hasManualSingleWindowWidthOverride {
        column.cachedWidth = 0
    }
}
```

That reset is already the wrong abstraction for this bug: it relies on clearing
state after it has been polluted. It also does not cover the workspace-move path
that created the workspace-4 repro:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:34-40
if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: targetRoot) {
    initializeNewColumnWidth(existingColumn, in: targetWorkspaceId)
    targetColumn = existingColumn
} else {
    let newColumn = NiriContainer()
    initializeNewColumnWidth(newColumn, in: targetWorkspaceId)
    targetRoot.appendChild(newColumn)
    targetColumn = newColumn
}
```

The move path initializes the newly created target column, but it does not
separate or sanitize the existing lone column's full-width render cache before
that existing column becomes part of a two-column layout.

### Hidden reveal clears state before proving onscreen placement

`applyPositionPlans` logs a SkyLight verification and AX fallback, but it does
not return success/failure to the caller:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2382-2417
applyPositionsViaSkyLight(...)
...
recordFrameApplyTrace("hidePlan.verify ... fallback=YES")
if dx > verifyEpsilon || dy > verifyEpsilon {
    let axResult = AXWindowService.setFrame(...)
    recordFrameApplyTrace("hidePlan.axFallback ...")
}
```

The reveal path clears hidden state immediately after applying a position plan:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:3017-3021
case let .positionPlan(plan):
    applyPositionPlans([plan])
    controller.workspaceManager.setHiddenState(nil, for: entry.token)
    controller.axManager.unsuppressFrameWrites(frameEntry)
    onSuccess?()
    return true
```

This explains how a workspace-inactive window can become `hidden=nil` even when
the frame application has just logged a verification mismatch. Later layout frame
writes may still recover it, but the trace shows at least one run where they did
not recover before the user observed the workspace.

---

## Root cause model

The width bug is not “cached width sometimes needs to be reset.” It is that
`cachedWidth` carries two different concepts:

1. **Canonical column width** — the width that should participate in normal
   multi-column layout, resizing, snapping, and persistence-like session state.
2. **Lone-window render/layout width** — a policy overlay used only while the
   workspace has exactly one normal tiled window, e.g. `.fill` or centered
   max-width.

Those concepts have different lifetimes. The lone-window overlay should appear
and disappear with the render/layout condition. It should not rewrite canonical
column state. The failed override attempt proved this: after the override was
cleared for a two-column workspace, `cached=2040.0` remained, so normal layout
still used the stale full-width value.

The visibility bug is adjacent but distinct: workspace assignment to an inactive
workspace intentionally hides the moved token, then activation reveals it. The
current reveal path updates model hidden state before physical placement is
verified, so a failed or rejected frame write can leave the model ahead of the
window server.

---

## Recommendation

### 1. Make lone-window width a render/layout override, not cached state

Use a structural split, not a reset workaround:

- Keep the canonical column cache as the value used by multi-column layout.
- Add a transient lone-window layout/render override (name suggestion:
  `singleWindowLayoutWidthOverride` or `loneWindowRenderWidth`).
- Single-window layout should compute the fill/centered width and store/use only
  that override. It must not assign the fill/centered width into canonical
  `cachedWidth`.
- Normal multi-column layout should ignore and clear the lone-window override.
- Manual single-window width changes are different: those should still commit a
  real canonical width and mark the existing manual override semantics.

Expected diagnostics after the fix:

```text
# Lone workspace with default fill:
cached=1008.0 override=2040.0 spec=prop:0.5000 manual=false

# Same workspace after a second column is added/moved in:
c0 cached=1008.0 override=nil spec=prop:0.5000
c1 cached=1008.0 override=nil spec=prop:0.5000
```

This preserves the user's expected model: the single-window default overlays the
internal width; it does not change window/column state.

### 2. Cover workspace moves explicitly

Once the model is split, the workspace-move path only needs to clear the
transient lone-window override when the target leaves the single-window state. It
should not clear canonical width. Review at least:

- `NiriLayoutEngine.moveWindowToWorkspace` in
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift`.
- `NiriLayoutEngine.addWindow` in
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift`.
- Any path that claims an empty column or appends a second column to an existing
  lone workspace.

### 3. Make workspace-inactive reveal state follow verified placement

For the “assigned but no visible window” symptom, make the hidden reveal path
observable and fail-safe:

- Have `applyPositionPlans` return per-window verification status, or otherwise
  expose whether SkyLight/AX fallback actually placed the window near the target.
- Do not clear `workspaceInactive` hidden state for a tiled reveal until either:
  - the position plan verifies onscreen, or
  - a subsequent forced layout frame write verifies onscreen.
- If keeping hidden state until verification is too invasive, at minimum add a
  delayed verification/retry for tiled workspace-inactive reveals, analogous to
  the existing pending reveal transaction machinery for floating/scratchpad
  cases.
- Trace the distinction between “model hidden state cleared” and “onscreen frame
  verified” so future captures cannot collapse these into one event.

---

## Suggested tests / validation

Per repository debugging rules, add regression tests after the real repro is
confirmed fixed. Useful coverage once the implementation is accepted:

1. **Lone fill then second moved window balances columns.** Move a window into an
   empty target workspace under `.fill`, run layout, then move a second window
   into that workspace. Assert the first column's canonical width remains the
   balanced/default width and any lone override is nil in the two-column state.
2. **Manual single-window override still persists.** Manually resize/toggle width
   in a lone workspace, then add a second column. Assert the manual width is the
   intended canonical width and is not lost by the transient override cleanup.
3. **Hidden reveal mismatch does not clear state silently.** With a fake frame
   writer that reports a verification mismatch, reveal a workspace-inactive tiled
   window and assert Nehir either keeps hidden state or schedules a verified
   forced retry before reporting the window as normally tiled/visible.
4. **Runtime validation.** In the exact repro, a lone workspace should dump like
   `cached=1008.0 override=2040.0`; after adding/moving a second column, the same
   workspace should dump `override=nil` and balanced `cached=1008.0` widths. For
   workspace assignment, the selected/focused token should end with an onscreen
   frame near `x=8`, not at the parking edge `x=2055`.
