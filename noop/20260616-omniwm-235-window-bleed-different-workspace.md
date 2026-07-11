# BarutSRB/OmniWM#235 — "Window bleeds into different workspace" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/235>
Scope of this doc: determine whether BarutSRB/OmniWM#235 applies to nehir, and specifically
whether its root cause overlaps nehir's existing stale-live-frame discoveries on
hidden columns / inactive workspaces — or whether it is a distinct bug. It is the
**cross-workspace** face of the window-bleed family; the **cross-monitor** face is
BarutSRB/OmniWM#349 (`noop/20260616-omniwm-349-hidden-window-bleeds-multi-monitor.md`).

All file/line references were verified against the Nehir source tree
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace").
Re-verify before implementing; line numbers drift.

---

> **Filed under `discovery/noop/`** — not because the bug is absent (the verdict
> below is 🔴 Open / Applies, and it is confirmed live in nehir), but because
> **BarutSRB/OmniWM#235 is a *duplicate* of the existing nehir discovery
> `20260616-workspace-inactive-stale-live-frame.md`**. It contributes no new root
> cause and owns no new repo action: its own recommendation is "implement the
> workspace-inactive discovery's recommendations, which close BarutSRB/OmniWM#235 directly."
> The fix work therefore lives under that sibling doc; BarutSRB/OmniWM#235 is kept here only for
> the upstream-symptom record and the cross-workspace / BarutSRB/OmniWM#349 cross-reference. It
> is the deduped survivor of a concurrent worker race (the strict-subset draft
> `…-omniwm-235-window-bleeds-into-workspace.md` was removed).

## TL;DR

- **BarutSRB/OmniWM#235 is the upstream description of nehir's stale-live-frame-on-inactive-workspace
  bug, not a distinct issue.** A window that belongs to a non-visible workspace keeps a
  **live AX frame that intersects the active workspace**, so a sliver of it is drawn on a
  workspace it does not belong to. nehir already caught this exact failure in the wild:
  `20260616-workspace-inactive-stale-live-frame.md` documents Telegram
  (`WindowToken(pid:15939, windowId:159)`) assigned to workspace 6 being live-visible at
  `liveAXFrame={{1050.0,0.0},{1006.0,1280.0}}` (x-range `1050..2056`) on the right side of
  active workspace 1, while nehir's own state said `hidden=workspaceInactive`,
  `observedVisible=false`.
- **Confirmed live in nehir, not merely latent.** The capture above is a real nehir
  runtime capture, and its symptom is BarutSRB/OmniWM#235 verbatim: *"around 100px … always the last
  selected window … at the right side of the screen."*
- **Upstream closed it `not_planned` while it still reproduced.** BarutSRB closed BarutSRB/OmniWM#235 on
  2026-05-05 as a "v0.4.8+ issue cleanup" because the conversation "predates the v0.4.8
  release on 2026-04-21." Guria replied the same day that **v0.4.8.1 still bleeds**: Zoom
  on workspace 1 is partly visible on every other workspace, and *"it disappears after
  some horizontal scroll applied on Workspace 1. But eventually reappears again."* The
  closure was a stale-sweep, not a fix.
- **Verdict:** 🔴 **Open / Applies.** nehir has since added drift **detection**
  instrumentation (`traceWorkspaceInactiveVisibleDriftIfNeeded`,
  `workspaceInactiveVisibleDriftDebugDump`, `workspaceInactiveVisibleDriftLine`) but it
  **only logs** — it never re-parks, the `hideWorkspace` skip branch still `continue`s, and
  the live-AX reconciliation is still `reason == .layoutTransient`-only. The user-visible
  bleed is not corrected. This upgrades the catalog's `validate` flag (Med / High) to
  **confirmed-live, same root cause**.

## Provenance: is this nehir's code?

Yes. Every symbol BarutSRB/OmniWM#235's symptom
depends on exists in nehir at the current HEAD, and they are the same symbols the
workspace-inactive discovery pinned:

- Workspace-inactive hide pass: `hideWorkspace` —
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2142`.
- The "skip already-hidden windows" short-circuit that lets a stale strip persist:
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2156-2167`.
- The physical-screen-edge park used for `.workspaceInactive` (and `.scratchpad`):
  `liveFrameHideOrigin` `.workspaceInactive, .scratchpad` switch case at
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2530-2541` →
  `HiddenWindowPlacementResolver.physicalScreenEdgeOrigin` at
  `Sources/Nehir/Core/Layout/SideHiding.swift:72`.
- The transition-only `.hide` that gates the layout-transient reconciliation:
  `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:909-915`.
- The `layoutTransient`-only live-AX re-read inside `resolveHideOperation`:
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2392-2404`.

This is nehir's code, in nehir's files.

## Upstream issue summary

Filed 2026-04-13 on OmniWM/OmniWM **0.4.7.4** by `flschulz` (ultrawide monitor):

> "a window that I have on a different workspace is bleeding into my currently
> selected workspace. E.g. if I have XCode on Workspace 2, I can see like 100px of
> it on workspace 1. If I switch to workspace 2 I can see the last selected window
> of workspace 1 (again around 100 px). So it is always the **last selected
> window** that I see there **at the right side of the screen**."

Corroborating reports, all the same per-**workspace** right-edge signature:

- `yougotwill` (2026-04-13): related to upstream BarutSRB/OmniWM#151; **only reproduces when windows
  are set to full column width**; no bleed at normal width.
- `Guria` (2026-04-13): single screen; **a Zoom call window bleeds into every workspace
  except the one currently displaying it**; also *"when I overscroll farmost right first
  column window piece bleeds behind last column."* Zoom *"bleeds from the right of other
  workspaces no matter if it is part of [the] layout or it was put in Scratchpad. Only
  moving to fullscreen helps to get rid of that bleed."*
- `flschulz` (2026-04-13): worked flawlessly in **0.4.5**, broken in **0.4.7.4**;
  animations also smoother in 0.4.5.

**Closure (2026-05-05, `BarutSRB`):** closed as part of a "v0.4.8+ issue cleanup" because
the last conversation "predates the v0.4.8 release on 2026-04-21," inviting a reopen if it
still reproduces.

**Still reproduces after closure (2026-05-05, `Guria`, v0.4.8.1):**

> "Zoom is placed on Workspace 1. Here I switched to other empty workspaces (all except
> 1st) and I see part of Zoom window on the right side. **it disappears after some
> horizontal scroll applied on Workspace 1. But eventually reappears again.**"

So BarutSRB/OmniWM#235's resolution state is **not "fixed"** — it is a stale-sweep close over a bug the
reporter confirmed live one release later. Guria's two 2026-05-05 screenshots show a
partial Zoom window on the right edge of otherwise-empty workspaces.

## The code in question

### 1. Inactive-workspace windows are parked at a screen edge, not truly hidden

`hideWorkspace` parks each inactive-workspace window via the `.workspaceInactive` reason,
which resolves to a **physical-screen-edge origin**, not a compositor-level hide:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2142-2170
private func hideWorkspace(
    _ entries: [WindowModel.Entry], monitor: Monitor,
    preferredSide: HideSide, hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
) {
    guard let controller else { return }
    for entry in entries {
        guard controller.workspaceManager.layoutReason(for: entry.token) != .nativeFullscreen else { continue }
        controller.axManager.markWindowInactive(entry.windowId)
        // Skip moving windows already hidden offscreen by the layout engine.
        // They're already parked — no need to shuffle them to the other side.
        if let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) {  // :2156
            traceWorkspaceInactiveVisibleDriftIfNeeded(entry, monitor: monitor,            // detection only
                preferredSide: preferredSide, hiddenState: hiddenState,
                hiddenPlacementMonitors: hiddenPlacementMonitors,
                trigger: "hideWorkspace.skipAlreadyHidden")
            continue                                                                        // ← no park plan
        }
        hideWindow(entry, monitor: monitor, side: preferredSide,
                   reason: .workspaceInactive, hiddenPlacementMonitors: hiddenPlacementMonitors)
    }
}
```

The park origin for `.workspaceInactive` / `.scratchpad` is the screen edge:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2530-2541  (inside liveFrameHideOrigin)
switch reason {
case .workspaceInactive, .scratchpad:
    let wsResult = HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(
        for: frame.size, requestedSide: side, targetY: frame.origin.y,
        baseReveal: baseReveal, scale: scale,
        monitor: hiddenPlacementMonitor, monitors: resolvedHiddenPlacementMonitors)
    ...
    return wsResult
```

```swift
// Sources/Nehir/Core/Layout/SideHiding.swift:72-91  (physicalScreenEdgeOrigin)
static let hiddenWindowEdgeRevealEpsilon: CGFloat = 1.0    // LayoutRefreshController.swift:102
...
let reveal = baseReveal / max(1.0, scale)                  // ~0.5pt at 2x, ~1pt at 1x
func origin(for side: HideSide, y: CGFloat) -> CGPoint {
    switch side {
    case .left:  CGPoint(x: monitor.frame.minX - size.width + reveal, y: y)
    case .right: CGPoint(x: monitor.frame.maxX - reveal, y: y)   // ← right-edge park
    }
}
```

On a 2056pt-wide display the right-edge park lands at `x ≈ 2055.5` with a 1px sliver
intentionally left visible. A parked window is therefore **not actually hidden by the
compositor** — it is nudged mostly off-screen. If that park write is ever skipped,
clamped, or undone, the window's left edge stays where the tiled frame put it and a strip
remains on the active workspace. That strip is exactly the "~100px at the right side"
flschulz and Guria describe.

### 2. The detection instrumentation nehir added — and why it does not fix the bleed

Responding to the workspace-inactive discovery, nehir wired in **observability**, not a
repair. The drift line is computed but only emitted as a trace string:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2240-2277  (workspaceInactiveVisibleDriftLine)
private func workspaceInactiveVisibleDriftLine(...) -> String? {
    ...
    guard let liveFrame = AXWindowService.framePreferFast(entry.axRef)
        ?? (try? AXWindowService.frame(entry.axRef)) else { return nil }
    ...
    guard liveFrame.intersects(activeMonitor.frame) else { return nil }       // :2260  only when on-screen
    let expectedOrigin = HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(...)  // :2265
    let dx = abs(liveFrame.origin.x - expectedOrigin.x)
    let dy = abs(liveFrame.origin.y - expectedOrigin.y)
    let parkTolerance: CGFloat = 2.0                                         // :2276
    guard dx > parkTolerance || dy > parkTolerance else { return nil }       // :2277
    ...
    return [...]   // a String — no park plan, no state change
}
```

`traceWorkspaceInactiveVisibleDriftIfNeeded` (`LayoutRefreshController.swift:2177`) just
records that line when trace capture is active; `workspaceInactiveVisibleDriftDebugDump`
(`:2203`) returns the same scan on demand. None of them issue a `WindowPositionPlan`, and
the `hideWorkspace` skip branch still `continue`s (`:2166`) right after logging. So a
window whose metadata says `workspaceInactive` but whose live AX frame is on-screen is
*observed* under capture and otherwise **left exactly where it is**. The bleed still
happens; nehir simply knows it is happening when tracing.

### 3. The stale-live-frame trap that lets the strip persist

Two gaps make the strip sticky; both are unchanged since the workspace-inactive discovery:

**(a) `hideWorkspace` skips already-hidden windows without re-verifying the live frame**
(`LayoutRefreshController.swift:2156-2167`, quoted above). If `hiddenState != nil`, it
`continue`s — issuing no park plan. So the very windows whose metadata is stale are the
ones never re-driven to the edge origin.

**(b) The live-AX reconciliation is `layoutTransient`-only.** The correct medicine exists
in `resolveHideOperation` — when the cached frame already matches the park origin, it
re-reads live AX and re-applies if it has drifted — but the gate excludes the
workspace-inactive reason:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2386-2404  (inside resolveHideOperation)
let moveEpsilon: CGFloat = 0.01
if abs(frame.origin.x - origin.x) < moveEpsilon,
   abs(frame.origin.y - origin.y) < moveEpsilon
{
    if reason == .layoutTransient,                          // ← excludes .workspaceInactive
       let liveFrame = try? AXWindowService.frame(entry.axRef)
    {
        let liveDx = abs(liveFrame.origin.x - origin.x)
        let liveDy = abs(liveFrame.origin.y - origin.y)
        if liveDx > moveEpsilon || liveDy > moveEpsilon {
            controller.axManager.recordFrameApplyTrace("hidePlan.staleCachedAlreadyHidden id=\(entry.windowId) ...")
            return .movable(WindowPositionPlan(entry: entry, origin: origin,
                frameSize: liveFrame.size, displayId: monitor.displayId), hiddenState: hiddenState)
        }
    }
    return .alreadyHidden(hiddenState: hiddenState)
}
```

Even if `resolveHideOperation` were reached for a workspace-inactive window, the
`reason == .layoutTransient` test would skip the live re-read and return `.alreadyHidden`,
preserving the stale strip. And it is rarely reached for these windows at all: `hideWorkspace`
short-circuits them in (a), and the `.hide` transition into the layout-transient path is
itself transition-only (`NiriLayoutHandler.swift:909-915`), so a stably-hidden window never
emits the `.hide` that would route it through `resolveHideOperation` via the diff.

## Why this applies to nehir

The match between BarutSRB/OmniWM#235's reported symptoms and nehir's workspace-inactive mechanism is
one-to-one:

| BarutSRB/OmniWM#235 symptom (user report) | nehir mechanism (code + capture) |
|---|---|
| Window on workspace N bleeds onto a different workspace | `hideWorkspace` parks inactive-workspace windows by nudging them to a screen edge (`LayoutRefreshController.swift:2142`), not via a compositor hide. A failed/skipped/clamped park leaves the tiled frame on-screen. |
| "~100px … at the right side of the screen" | Right-edge park = `monitor.frame.maxX - reveal` (`SideHiding.swift:82-86`); the leftover strip is whatever the failed park left on-screen. nehir capture showed the window occupying `x=1050..2056` of a `0..2056` display — a full right-hand bleed. |
| "always the **last selected/focused** window" | The most-recently-focused window is the one whose park/reveal churn leaves its live frame at a tiled coordinate. The workspace-inactive discovery documents the exact failure: app-switch focus cleared `hidden=workspaceInactive` with `isWorkspaceActive=false` and `ax_focus_confirm_skip_relayout`, then re-hiding left the frame on-screen. |
| Only reproduces with **full column width** (`yougotwill`) | A full-width window's tiled frame spans the whole display, so any park shortfall lands a wide, visible strip. A narrow window parks cleanly because most of it is already off-screen. Same geometry, not a different code path. |
| "Zoom … bleeds regardless of layout or Scratchpad" (`Guria`) | nehir parks `.scratchpad` and `.workspaceInactive` in the **same** `physicalScreenEdgeOrigin` switch case (`LayoutRefreshController.swift:2530`), so both reasons exhibit the identical edge-bleed. |
| "**disappears after some horizontal scroll** … eventually reappears" (`Guria`, v0.4.8.1) | Scrolling until the column re-enters the apply band forces a `.show` transition (`NiriLayoutHandler.swift:917-919`), which re-applies a real frame and clears the drift — the exact "fixed by scrolling" mechanism proven in `20260616-stale-live-frame-on-stably-hidden-column.md`. "Eventually reappears" is the recurring drift that no background reconciliation catches. |
| Worked in 0.4.5, broken in 0.4.7.4 (`flschulz`) | Consistent with a change to the edge-park hide mechanism between those releases; nehir inherits the post-0.4.5 behavior. |

The decisive evidence is that nehir already caught this bug in the wild: the
workspace-inactive capture shows a window on an inactive workspace (6) live-visible on the
active workspace (1) while nehir's state says `hidden=workspaceInactive` +
`observedVisible=false`. That is the literal definition of BarutSRB/OmniWM#235.

### Two nehir mechanisms, one umbrella symptom

BarutSRB/OmniWM#235's reports actually span both of nehir's stale-live-frame mechanisms on a single
display — they are not a separate cause, they are the same invariant violation
(`hidden != nil` + `observedVisible=false` + live AX on-screen) on two hide reasons:

- The **dominant** report ("window on workspace 2 bleeds into workspace 1", "Zoom bleeds
  into every workspace except the one displaying it") is the **workspace-inactive** trap
  (`.workspaceInactive`, screen-edge park) — `20260616-workspace-inactive-stale-live-frame.md`.
- The **overscroll** sub-symptom ("when I overscroll farmost right first column window
  piece bleeds behind last column") and the "**disappears after some horizontal scroll**"
  self-repair are the **stably-hidden column** trap (`.layoutTransient(left)`, offscreen
  column slot) — `20260616-stale-live-frame-on-stably-hidden-column.md`.

Both share the same reconciliation gap: the live-AX re-check runs only on a `.show`/`.hide`
*transition*, so a window that is already hidden when its live frame drifts is never
re-parked. BarutSRB/OmniWM#235 is the cross-workspace umbrella; BarutSRB/OmniWM#349 is the same family seen across
monitors.

## Relationship to the sibling discoveries

| Aspect | BarutSRB/OmniWM#235 (this doc, upstream) | `workspace-inactive-stale-live-frame` (nehir) | `stale-live-frame-on-stably-hidden-column` (nehir) | BarutSRB/OmniWM#349 (cross-monitor) |
|---|---|---|---|---|
| Framing | window bleeds into a different **workspace** | window on inactive workspace visible on active workspace | hidden column's window stays on-screen after scroll | hidden window bleeds onto a different **monitor** |
| Hide reason | `.workspaceInactive` (dominant) + `.layoutTransient` (overscroll) | `.workspaceInactive` | `.layoutTransient(left)` | screen-edge park misses adjacent monitor |
| Shared invariant | `hidden != nil` + `observedVisible=false` + live AX on-screen | same | same | same |
| Park target | screen edge (`physicalScreenEdgeOrigin`) | screen edge (`x≈2055`) | offscreen column slot (`x=-1006`) | screen edge |
| Why it sticks | park skipped/clamped; already-hidden skip; no re-check | same | transition-only reconciliation never re-runs | same edge-park geometry |
| Fixed by (user) | horizontal scroll | (app switch parked it by end) | scroll until column re-enters apply band | — |
| nehir code state | **unfixed** (detection-only) | discovery filed; reconciliation still `layoutTransient`-only | discovery filed; reconciliation transition-gated | discovery filed |

BarutSRB/OmniWM#235 is the upstream-facing description of the **workspace-inactive** column of this family
(with an overscroll/layout-transient footnote), and nehir already has the matching,
capture-proven discovery for it. The code that produces it is unchanged except for the
detection-only logging noted above.

## Recommendation

Do not treat BarutSRB/OmniWM#235 as a new investigation. It is the same root cause as
`20260616-workspace-inactive-stale-live-frame.md`; implement that discovery's
recommendations, which close BarutSRB/OmniWM#235 directly:

1. **Stop skipping already-hidden workspace-inactive windows blindly.** In `hideWorkspace`
   (`LayoutRefreshController.swift:2156-2167`), when `hiddenState != nil`, compare the live
   AX frame to the expected edge origin (the comparison `workspaceInactiveVisibleDriftLine`
   already computes at `LayoutRefreshController.swift:2265-2277`) and, if it has drifted past
   `parkTolerance`, issue the same park plan `hideWindow(reason:.workspaceInactive)` would —
   instead of `continue`-ing. The drift computation already exists; the missing piece is the
   `.movable` return on detection.
2. **Generalize the stale-cached live-AX reconciliation beyond `layoutTransient`.** In
   `resolveHideOperation` (`LayoutRefreshController.swift:2392-2404`), drop the
   `reason == .layoutTransient` gate (or add `.workspaceInactive`/`.scratchpad`) so the
   `hidePlan.staleCachedAlreadyHidden` re-apply runs for the workspace-inactive reason too.
3. **Do not clear `workspaceInactive` hidden state without writing a frame or activating the
   workspace** (the workspace-inactive discovery's `executeHiddenReveal` `.none` path), as
   that is how hidden state is cleared while `isWorkspaceActive=false` with no relayout.

These are the same fixes the workspace-inactive discovery already specifies; BarutSRB/OmniWM#235 adds no
new root cause, only confirms the symptom is reported upstream and is still live in the
latest upstream release the reporter tested. Any repair must also be validated against the
`docs/window-parking-and-offscreen-clamp.md` pitfalls: a unit test can prove a park *plan is issued*, but
whether WindowServer finally accepts the offscreen park and the external window renders
hidden is the separate, still-open clamp problem — the reconciliation here only guarantees
the live frame is *re-driven* toward the park slot.

## Suggested tests

Mirror the workspace-inactive discovery's recommended test, framed for BarutSRB/OmniWM#235:

1. **Inactive-workspace drift is re-parked, not skipped.** Build a controller state with one
   monitor `M` (`frame=(0,0,2056,1329)`), workspace 1 active and visible, workspace 6
   invisible, and a window assigned to workspace 6 whose metadata is
   `hidden=workspaceInactive` but whose live AX frame intersects `M`
   (e.g. `live={{1050,0},{1006,1280}}`). After `hideWorkspace` runs, assert a park plan
   toward the right-edge origin (`x≈2055`) is issued for that window rather than skipped.
   (Asserting WindowServer *renders* it hidden is out of scope for a unit test — see
   `docs/window-parking-and-offscreen-clamp.md` — but the plan being issued is the gateable invariant.)
2. **Full-width window reproduces the wide bleed; narrow window parks cleanly.** Parametrize
   (1) over window width and assert that the visible-strip width on the active monitor
   shrinks to ≤ the reveal epsilon after the fix, capturing the "full column width" condition
   `yougotwill` reported.
3. **Reveal does not drop hidden state without a frame.** With workspace 6 still inactive,
   simulate an app-switch focus confirm to the workspace-6 window
   (`isWorkspaceActive=false`). Assert that hidden state is either preserved or cleared only
   alongside a restore frame / workspace activation — not cleared with no relayout (the
   `ax_focus_confirm_skip_relayout` path).
