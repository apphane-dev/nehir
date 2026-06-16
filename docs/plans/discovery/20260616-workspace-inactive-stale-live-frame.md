# Workspace-inactive window can remain visible on the active workspace — Discovery

Discovery (2026-06-16). Telegram was assigned to workspace 6, but its live AX frame was
visible on workspace 1 while Nehir believed the window was hidden because its workspace was
inactive. This is the same **wrong-parked / stale-live-frame family** as
`20260616-stale-live-frame-on-stably-hidden-column.md`, but it is **not the same failure
mode**: the earlier Helium case is a `layoutTransient` hide for a Niri column that is
stably offscreen; this Telegram case is a `workspaceInactive` hide for a window whose
workspace is not visible.

This is also the bug reported upstream as **Hiro issue #235** ("Window bleeds into
different workspace") — see `noop/20260616-hiro-235-window-bleed-different-workspace.md`
for the user-facing symptom record: multiple reporter reports (flschulz, Guria,
yougotwill), screenshots, the "~100px at the right side of the screen" signature,
and the "disappears after some horizontal scroll" self-repair that matches the
stably-hidden-column sibling. That capture here (Telegram live at `x=1050..2056`
on active workspace 1 while `hidden=workspaceInactive`) is #235's symptom verbatim.
#235 is filed as a **duplicate of this discovery** — it adds no new root cause and
owns no separate repo action; the fix work lives in the Recommendations below.
Upstream closed #235 `not_planned` as a v0.4.8+ stale-issue sweep while it still
reproduced in v0.4.8.1, so its resolution state is not evidence of a fix.

All runtime evidence below is inlined from the capture that exposed this. Trace files are
machine-local and ephemeral; this document copies the concrete timestamps, tokens, frames,
workspace ids, and state transitions needed to reason about the bug without reopening any
captured log. Code citations were checked at commit `75f34c7` and may drift.

---

## TL;DR

- **Symptom.** `WindowToken(pid: 15939, windowId: 159)`, `bundleId=ru.keepcoder.Telegram`,
  belongs to workspace 6 (`09013ABF-6A04-402C-8C6D-62260FC2622F`), while the active /
  interaction workspace is workspace 1 (`BCF1DDB0-08C4-4E9E-BCC9-3470A22693D3`). At capture
  start (`09:43:25Z`), Telegram was marked `hidden=workspaceInactive` and
  `inactiveWorkspace=true`, but its live AX frame was `{{1050.0, 0.0}, {1006.0, 1280.0}}`.
  On the only monitor, `frame=(0,0,2056,1329)`, so `x=1050..2056` is visible on the right
  half of workspace 1.
- **Internal contradiction.** The layout engine for workspace 6 describes Telegram as a
  normal visible tiled window in c0: `cur=10,0,2036,1280`, `target=10,0,2036,1280`,
  `hidden:nil`. The managed-window layer separately says `hidden=workspaceInactive`, and
  AX state says `lastApplied=nil`, `inactiveWorkspace=true`. The layout engine is not the
  source of this hide; the workspace-inactive hide path is.
- **Not the same as the Helium discovery.** The Helium bug was a stably-hidden Niri column:
  `layoutTransient(left)`, layout target already at an offscreen park slot, no transition
  so `resolveHideOperation` was not revisited. Telegram is different: its layout target is
  the normal tiled frame `(10,0,2036,1280)` because workspace 6 itself is hidden, and the
  hide reason is `workspaceInactive`.
- **New mechanism found.** `hideWorkspace` marks inactive windows and then skips moving any
  window that already has *any* hidden state (`LayoutRefreshController.swift:2153-2158`).
  If that hidden-state bit is stale or was set without a successful park write, every later
  inactive-workspace hide pass treats the window as already parked and never re-checks the
  live AX frame.
- **Second mechanism found.** Focusing Telegram via app switch cleared `hidden=workspaceInactive`
  at `09:43:58Z`, but the trace immediately records `ax_focus_confirm_skip_relayout` with
  `isWorkspaceActive=false`. That gives a path where an inactive-workspace reveal can clear
  hidden state without activating the workspace and without requesting a layout refresh for
  the target workspace.
- **Unknown origin.** The capture starts after Telegram is already wrong. `lastApplied=nil`
  and there are no recorded `hidePlan.*`, `hideOrigin.resolve`, enqueue, or confirmation
  entries for `id=159` anywhere in the captured frame-apply trace. The first failed / skipped
  park was therefore not captured, or it was not recorded by `AXManager` at all.

---

## Topology and initial state

Single-monitor topology:

```
ID(displayId: 1) frame=(0.0, 0.0, 2056.0, 1329.0)
visibleFrame=(0.0, 0.0, 2056.0, 1290.0)
name=Built-in Retina Display
```

At capture start (`09:43:25Z`):

```
interactionWorkspace=BCF1DDB0-08C4-4E9E-BCC9-3470A22693D3
interactionMonitor=ID(displayId: 1)
visibleWorkspaces=1
windows total=3 tiled=3 floating=0 hidden=1
inactiveWorkspaceWindowIds=1
```

Workspace visibility:

```
workspace=1 id=BCF1DDB0-08C4-4E9E-BCC9-3470A22693D3 visible=true  columns=2
workspace=6 id=09013ABF-6A04-402C-8C6D-62260FC2622F visible=false columns=1
```

Telegram's managed state is already contradictory:

```
WindowToken(pid: 15939, windowId: 159)
workspace=09013ABF-6A04-402C-8C6D-62260FC2622F
mode=tiling phase=tiled hidden=workspaceInactive layout=standard
liveAXFrame={{1050.0, 0.0}, {1006.0, 1280.0}}
observedVisible=false observedFocused=false
replacementFrame={{155.0, 0.0}, {1006.0, 1280.0}}
bundleId=ru.keepcoder.Telegram
```

The same start-state AX dump says Nehir has no recorded apply for this window:

```
windowId=159 lastApplied=nil pending=nil failure=nil retryBudget=nil
forceApply=false observerRequest=nil inactiveWorkspace=true
```

But the Niri layout decision for workspace 6 is not hidden at all:

```
workspace=6 id=09013ABF-6A04-402C-8C6D-62260FC2622F
c0[x=0.0,cached=2036.0,...]{
  w159:selected{
    cur=10,0,2036,1280,
    target=10,0,2036,1280,
    last=nil,
    live=1050,0,1006,1280,
    replacement=155,0,1006,1280,
    observed=nil,
    hidden:nil
  }
}
```

So the bug is not that Niri decided Telegram's column is offscreen. Niri says workspace 6's
only column is visible *within workspace 6*. The separate workspace-inactive path is
responsible for keeping the window off workspace 1.

---

## What happened during the capture

### 1. Telegram starts visibly wrong on workspace 1

The start frame `liveAXFrame={{1050.0, 0.0}, {1006.0, 1280.0}}` covers
`x=1050..2056` on a display whose x range is `0..2056`. This exactly matches the user
report: the window is assigned to workspace 6, but visible on workspace 1.

At the same time Nehir's own state says:

```
hidden=workspaceInactive
observedVisible=false
windowId=159 lastApplied=nil inactiveWorkspace=true
```

That is the stale-live-frame fingerprint: managed state believes the window is hidden,
but live AX geometry is on-screen.

### 2. App-switch focus to Telegram clears hidden state without workspace activation

At `09:43:58Z`, native app switching confirmed focus to Telegram:

```
event=managed_focus_confirmed token=WindowToken(pid: 15939, windowId: 159)
workspace=09013ABF-6A04-402C-8C6D-62260FC2622F
plan=focus=focused=WindowToken(pid: 15939, windowId: 159),pending=nil,lease=native_app_switch
```

Immediately after that, hidden state is cleared:

```
event=hidden_state_changed token=WindowToken(pid: 15939, windowId: 159)
workspace=09013ABF-6A04-402C-8C6D-62260FC2622F hidden=false plan=phase=tiled
```

The viewport trace for the same timestamp shows that workspace 6 did **not** become the
active workspace from Nehir's point of view, and no relayout was requested for it:

```
reason=ax_focus_confirm_before_activate token=WindowToken(pid: 15939, windowId: 159)
currentViewStart=0.0 targetViewStart=0.0 live=1050,0,1006,1280

reason=ax_focus_confirm_reveal_candidate token=WindowToken(pid: 15939, windowId: 159)
columnIndex=0 visibility=fullyVisible viewStart=0.0

reason=ax_focus_confirm_reveal_result token=WindowToken(pid: 15939, windowId: 159)
columnIndex=0 isFFM=false didReveal=false

reason=ax_focus_confirm_skip_relayout token=WindowToken(pid: 15939, windowId: 159)
isWorkspaceActive=false isFFM=false isAnimating=false
```

The key fields are `hidden=false`, `didReveal=false`, and `isWorkspaceActive=false`. The
window was treated as a reveal / focus target inside workspace 6, but workspace 6 remained
inactive, so the code path skipped the relayout that would normally place the tiled frame.

### 3. Switching away re-hides Telegram, but no frame apply is recorded

At `09:44:02Z`, focus moved back to Slack on workspace 1. The event log records Telegram
being hidden again:

```
event=hidden_state_changed token=WindowToken(pid: 15939, windowId: 159)
workspace=09013ABF-6A04-402C-8C6D-62260FC2622F hidden=true plan=phase=hidden
```

By capture end (`09:44:06Z`), Telegram's live frame is parked at the physical right edge:

```
WindowToken(pid: 15939, windowId: 159)
mode=tiling phase=hidden hidden=workspaceInactive
liveAXFrame={{2055.0, 0.0}, {2036.0, 1280.0}}
replacementFrame={{10.0, 0.0}, {2036.0, 1280.0}}
```

`x=2055` is the expected 1pt reveal on a 2056pt-wide display, so by the end the user-visible
bleed is likely gone. However, `lastApplied` is still nil:

```
windowId=159 lastApplied=nil pending=nil failure=nil retryBudget=nil
forceApply=false observerRequest=nil inactiveWorkspace=true
```

And the Niri layout decision still says the workspace-6 target is the normal tiled frame,
not the park slot:

```
w159:selected{cur=10,0,2036,1280,target=10,0,2036,1280,last=nil,
              live=2055,0,2036,1280,replacement=10,0,2036,1280,
              observed=nil,hidden:nil}
```

No captured frame-apply entry names `id=159`: no `hidePlan.apply`, no `hidePlan.verify`,
no `hideOrigin.resolve`, no `enqueue`, no `confirmed`, and no `skip-dedup`. The trace
therefore does **not** prove that Nehir moved Telegram to `2055`; it only proves the live
AX frame changed to a park-like coordinate without `AXManager` recording a last-applied
frame.

---

## Mechanism — why workspace-inactive drift can stick

### 1. `hideWorkspace` skips any window that already has hidden state

`LayoutRefreshController.hideWorkspace` marks each inactive-workspace window inactive, then
returns early if the window already has hidden state:

```swift
// LayoutRefreshController.swift:2153-2158
controller.axManager.markWindowInactive(entry.windowId)
// Skip moving windows already hidden offscreen by the layout engine.
// They're already parked — no need to shuffle them to the other side.
if controller.workspaceManager.hiddenState(for: entry.token) != nil {
    continue
}
```

Only windows that pass this guard call `hideWindow(... reason: .workspaceInactive)`
(`LayoutRefreshController.swift:2159-2164`). That means a window with
`hidden=workspaceInactive` but a visible live AX frame is considered already handled. The
park write is skipped precisely when the stale hidden metadata needs to be verified.

This is analogous to the Helium discovery's stably-hidden gap, but it is on a different
path. In the Helium case, `.hide` visibility changes are transition-gated. Here,
`hideWorkspace` itself transition-gates by hidden-state existence.

### 2. The existing stale-live reconciliation is layout-transient only

`hideWindow` would route through `resolveHideOperation` (`LayoutRefreshController.swift:2353-2378`).
That function already contains a live-AX re-read for stale cached hidden state:

```swift
// LayoutRefreshController.swift:2258-2268
let moveEpsilon: CGFloat = 0.01
if abs(frame.origin.x - origin.x) < moveEpsilon,
   abs(frame.origin.y - origin.y) < moveEpsilon
{
    if reason == .layoutTransient,
       let liveFrame = try? AXWindowService.frame(entry.axRef)
    {
        let liveDx = abs(liveFrame.origin.x - origin.x)
        let liveDy = abs(liveFrame.origin.y - origin.y)
        if liveDx > moveEpsilon || liveDy > moveEpsilon {
            controller.axManager.recordFrameApplyTrace("hidePlan.staleCachedAlreadyHidden ...")
            return .movable(...)
        }
    }
    return .alreadyHidden(hiddenState: hiddenState)
}
```

Two important limitations matter for Telegram:

1. `hideWorkspace` does not call `hideWindow` at all if `hiddenState != nil`, so
   `resolveHideOperation` is often not reached for already-hidden inactive-workspace
   windows.
2. Even if reached, the stale-cached live-AX re-read is gated by
   `reason == .layoutTransient`, so the workspace-inactive reason would not get the same
   reconciliation behavior without code changes.

The workspace-inactive park origin is computed by the same resolver family:

```swift
// LayoutRefreshController.swift:2398-2412
case .workspaceInactive, .scratchpad:
    let wsResult = HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(...)
    controller.axManager.recordFrameApplyTrace(
        "hideOrigin.resolve reason=workspaceInactive ... result=... frame=..."
    )
    return wsResult
```

For Telegram's end frame, that physical-edge policy corresponds to `x=2055`: a 1pt reveal
at the right edge of a `2056`-wide monitor.

### 3. Inactive-workspace focus reveal can clear state without moving the window

`unhideWindow` only handles `workspaceInactive` hidden state and delegates to
`executeHiddenReveal` (`LayoutRefreshController.swift:2472-2484`). In
`executeHiddenReveal`, if `restoreWindowFromHiddenState` returns `.none`, the
workspace-inactive branch simply clears hidden state and unsuppresses writes:

```swift
// LayoutRefreshController.swift:2809-2815
switch restoreWindowFromHiddenState(entry, monitor: monitor, hiddenState: hiddenState) {
case .none:
    if hiddenState.workspaceInactive {
        controller.workspaceManager.setHiddenState(nil, for: entry.token)
        controller.axManager.unsuppressFrameWrites(frameEntry)
        onSuccess?()
        return true
    }
```

The trace's `hidden=false` + `didReveal=false` + `ax_focus_confirm_skip_relayout` sequence
is consistent with this no-position-plan reveal path: hidden metadata is removed, but no
frame is written and no relayout is requested because the workspace is not active.

The focus-confirm code only requests relayout when `isWorkspaceActive` is true; otherwise
it records `ax_focus_confirm_skip_relayout` (`AXEventHandler.swift:2068-2085`). Telegram
hit the skip branch with `isWorkspaceActive=false`.

---

## Relationship to the stale scrolled-column discovery

| Aspect | Stably-hidden Helium column | Workspace-inactive Telegram |
|---|---|---|
| User symptom | Hidden/parked in state, live AX visible | Hidden/parked in state, live AX visible |
| Hide reason | `layoutTransient(left)` | `workspaceInactive` |
| Layout target | Offscreen park slot (`x=-1006`) | Normal tiled workspace-6 target (`x=10`) |
| Hidden state source | Niri offscreen-column visibility | WM inactive-workspace hide path |
| Transition gate | `.hide` emitted only when offscreen side changes | `hideWorkspace` skips if any hidden state exists |
| Existing reconciliation | `hidePlan.staleCachedAlreadyHidden`, but transition-gated | Not reached, and currently `layoutTransient`-only |
| Fix trigger observed | Scroll workspace until column re-enters apply band | App switch away eventually produced park-like live frame |

So the answer is: **same family, different bug**. The shared invariant violation is
`hidden != nil` + `observedVisible=false` + live AX on-screen / not at the park origin. The
new discovery is that the workspace-inactive code path has its own stale-hidden metadata
trap and is not covered by the layout-transient reconciliation described in the earlier
file.

---

## Confidence and open questions

### Proven by this capture

1. A workspace-inactive window can be live-visible on the active workspace:
   `hidden=workspaceInactive`, workspace 6 invisible, workspace 1 active, live x-range
   `1050..2056` on display 1.
2. The Niri layout engine does not know Telegram is hidden; its layout decision for
   workspace 6 has `hidden:nil` and normal target `10,0,2036,1280`.
3. `hideWorkspace` skips already-hidden windows before calling `hideWindow`, so stale
   `workspaceInactive` metadata can prevent any re-park attempt.
4. App-switch focus can clear workspace-inactive hidden state while `isWorkspaceActive=false`
   and while the focus-confirm path skips relayout.
5. The captured frame-apply trace records no `id=159` move, and `lastApplied` remains nil
   from start to end.

### Not proven yet

1. **Initial origin of the bad `1050` frame.** The capture starts with Telegram already
   wrong. It does not show whether the first park write was skipped, failed, clamped, or
   undone by Telegram / WindowServer.
2. **Who moved Telegram to `2055` by the end.** The end coordinate is park-like, but no
   `AXManager` last-applied state or frame-apply trace entry names `id=159`. It may have
   been a Nehir path that did not record in this trace, a WindowServer/app side effect of
   app switching, or an observation gap.
3. **Whether `.none` reveal is always involved.** The event sequence strongly suggests the
   no-position-plan branch, but the trace does not log `restoreWindowFromHiddenState`'s
   exact return case.

---

## Recommendations

1. **Add workspace-inactive stale-live reconciliation.** Hidden workspace-inactive windows
   should not be skipped solely because `hiddenState != nil`. Re-check their live AX frame
   against the expected physical-edge park origin on a bounded cadence or before returning
   from `hideWorkspace`'s already-hidden branch. If the live frame is not near the park
   origin, issue the same kind of park plan `hideWindow` would issue.
2. **Generalize the stale-cached live-AX guard.** The `hidePlan.staleCachedAlreadyHidden`
   live re-read is currently `layoutTransient`-only. The same invariant applies to
   `workspaceInactive`: if cached/metadata says parked but live AX is visible or not near
   the computed park origin, return `.movable`.
3. **Do not clear `workspaceInactive` hidden state without either activating the workspace
   or writing a restore frame.** In app-switch focus handling, if the focused window's
   workspace is still inactive, either activate / transition to that workspace, or leave
   it hidden and re-park it. The current `hidden=false` + `isWorkspaceActive=false` + no
   relayout combination is unsafe.
4. **Instrument the uncertain edges.** Add trace fields around:
   - `hideWorkspace` already-hidden skips: token, reason, hidden state, live frame, expected
     park origin, and whether drift was detected.
   - `executeHiddenReveal` return branch: `.none`, `.positionPlan`, or `.asyncFrame`.
   - Workspace-inactive `hideWindow` applications and verification, with `id=159`-style
     frame-apply entries that update or explain `lastApplied`.

A unit test can cover the controller invariant: an already-`workspaceInactive` window whose
live frame is inside the active monitor must be scheduled for a park write instead of being
skipped. A real runtime capture is still needed to prove the external WindowServer/app
behavior accepts the park and to identify the initial drift source.

---

## Reproduction / validation checklist

- Single display `(0,0,2056,1329)` or equivalent.
- Workspace 1 active and visible; workspace 6 invisible.
- Telegram tiled on workspace 6 with a normal workspace-6 target around `(10,0,2036,1280)`.
- Bad state to detect: `hidden=workspaceInactive`, `inactiveWorkspace=true`,
  `lastApplied=nil` or stale, but live AX frame intersects the active display (observed:
  `liveAXFrame={{1050.0, 0.0}, {1006.0, 1280.0}}`).
- App-switch to Telegram and observe whether hidden state clears while
  `isWorkspaceActive=false` and `ax_focus_confirm_skip_relayout` is recorded.
- Switch away and observe whether Telegram is re-parked to the physical-edge origin
  (`x≈display.maxX−1`, observed `x=2055`) and whether a frame-apply / last-applied record
  now exists for the window.
- After a fix, an already-hidden workspace-inactive Telegram with live frame on-screen
  should be re-driven to the park origin without requiring an app switch or workspace
  activation.
