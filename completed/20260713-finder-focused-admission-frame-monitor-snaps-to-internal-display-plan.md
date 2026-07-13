# Plan: focused-admission placement must honor the interaction monitor when the window frame is off-screen

> **✅ SHIPPED — landed on `main` in `3056bee8`, 2026-07-13.** Both the primary
> failure-mode-B fix (cursor-monitor signal) from the "Corrected fix direction"
> section and the secondary failure-mode-A hardening (interaction-monitor
> fallback) from the original Steps landed, plus a third defect found during
> implementation (failure mode C — focus bounce). See the discovery's
> "Resolution" section for the shipped summary. History below is retained as
> provenance; the "NEEDS REWORK" call it originally carried was resolved by
> re-planning around the cursor-monitor signal.
>
> What actually shipped vs. this plan:
> - Cursor-monitor branch (B) requires only the WindowServer frame off-screen
>   (not also the live AX frame — the AX frame is macOS default noise for a fresh
>   window); it is ordered *before* the interaction-monitor branch.
> - The interaction-monitor branch (A) requires *both* WindowServer and live AX
>   frames off-screen.
> - The new test file shipped as
>   `Tests/NehirTests/PlacementCursorInteractionMonitorFallbackTests.swift`
>   (not the `PlacementInteractionMonitorFallbackTests.swift` name proposed in
>   Step 3), and tests were written *after* the user confirmed the fix in the
>   real repro, per the `AGENTS.md` Tests rule.

**Source discovery:**
[`20260713-finder-focused-admission-frame-monitor-snaps-to-internal-display.md`](20260713-finder-focused-admission-frame-monitor-snaps-to-internal-display.md)
(source-backed root cause, verified against `main`; **read the Correction
section — the reported repro is failure mode B**).

**Original one-line goal (failure mode A only):** when a new window is admitted
via the synthesized focused-admission path with **no focused/native context** but
a known **interaction monitor**, and the window's placement frame is
**off-screen** (contained by no monitor, e.g. a display-2 negative-y park-zone
frame), place it on the **interaction monitor**, not on whatever monitor
`monitorApproximation` snapped the off-screen frame to.

Re-verify every line number below against `main` before editing — the discovery
was written against the current tree but line numbers drift.

---

## Corrected fix direction (failure mode B — the reported bug)

The reported repro carries **no signal at all** pointing at the display the user
clicked: `focused_*`/`native_*` are nil, the off-screen frame snaps to display 1,
and `interaction_monitor` is a **stale display 1** because it is written only by
Nehir-managed actions (managed focus, workspace activation/navigation,
scratchpad, mouse warp — enumerated in the discovery) and a non-managed
desktop click on a display without managed windows updates none of them.

The missing signal is the **cursor location** at admission time. Recommended
(targeted) approach, to be turned into concrete steps after a runtime spike
confirms the cursor is on the expected display at admission:

1. Add a strict-containment cursor→monitor lookup (reuse the `monitorContaining`
   helper this plan already adds in Step 1) applied to `NSEvent.mouseLocation`
   (bridged into the CoreGraphics/global space Nehir uses; `mouseLocation` is
   AppKit bottom-left origin, so convert — see `ScreenCoordinateSpace`). A cursor
   on no monitor yields `nil`.
2. Carry the resolved cursor monitor into `WindowCreatePlacementContext` (new
   optional field), populated in `makeCreatePlacementContext`
   (`AXEventHandler.swift:6978` region). Do **not** overwrite the existing
   `interactionMonitorId`; add a *separate* signal so the stale-interaction
   behaviour elsewhere is untouched.
3. In the no-focused/native-context focused-admission tail of
   `createPlacementTarget`, prefer the cursor monitor when it is present and the
   placement frame is contained by no monitor (off-screen). Order it so genuine
   authoritative signals (pending/native/confirmed focus) still win.
4. Consider whether the interaction monitor itself should follow the cursor on
   non-managed activation (broad root-cause fix) — deferred; higher blast radius
   (border/reveal/focus all read it). Decide in the re-plan.

Open validation question to resolve first: at the moment the synthesized
focused-admission fires for Finder ⌘N, is `NSEvent.mouseLocation` still on
display 2? Confirm with a runtime spike before committing to steps.

Tests for B must follow the same discipline as everything here: **no test edits
until the fix is confirmed in the real repro** (see `AGENTS.md` → Tests).

---

## Below: original failure-mode-A steps (secondary hardening — NOT the reported-bug fix)

## Root cause recap (two compounding defects)

1. **D1 — interaction monitor discarded.** In `createPlacementTarget`
   (`Sources/Nehir/Core/Controller/WMController.swift:1465-1594`), every branch
   that would honor `createPlacementContext.interactionMonitorId` is gated behind
   a non-nil focused workspace/monitor (`:1499` needs `focusedMonitorId`; `:1525`
   needs `focusedWorkspaceId`). For a plain app activation of an app with no
   tracked/recent window (Finder), those are all nil, so the interaction monitor
   is never consulted and control falls through to the frame-monitor fallback at
   `:1576`.
2. **D2 — off-screen frame snaps to the wrong monitor.**
   `monitorForPlacementFrame` (`WMController.swift:1721`) uses
   `CGPoint.monitorApproximation` (`Sources/Nehir/Core/Monitor/Monitor.swift:486`),
   which returns the **nearest** monitor when the point is inside none. A
   display-2 park-zone frame `(719, -1369, 1011, 1251)` (center `(1224.5,
   -743.5)`, inside neither monitor) snaps to the internal display (~744px away
   vs ~2073px to the external), and the fallback at `:1576` trusts it.

The fix targets the seam where these meet: the fallback tail must prefer the
interaction monitor over a *merely approximated* (off-screen) frame monitor,
while still honoring a frame monitor that genuinely **contains** the frame (a
window the user dragged onto a specific display before admission).

---

## Files to touch

- `Sources/Nehir/Core/Monitor/Monitor.swift` — add a strict-containment
  companion to `monitorApproximation`.
- `Sources/Nehir/Core/Controller/WMController.swift` — add a containment-only
  frame→monitor helper and an interaction-monitor fallback branch.
- `Tests/NehirTests/PlacementInteractionMonitorFallbackTests.swift` — **new**
  per-behavior test file (see `docs/TESTING.md`; do **not** append to the frozen
  `AXEventHandlerTests.swift` monolith).
- Changeset fragment via `mise run changeset patch "…"`.

**Do-not-touch fences** (other parallel work owns these):
- Do not modify `monitorApproximation` itself or any other caller of it — add a
  *new* helper alongside it. Other placement/layout code depends on its
  nearest-snap behavior.
- Do not touch the focused-context branches (`WMController.swift:1499-1544`) or
  `makeCreatePlacementContext` (`AXEventHandler.swift:7074`). The fix is
  additive in the fallback tail only; changing the focused branches risks
  regressing confirmed-focus placement.
- Do not touch any file under `Tests/NehirTests/AXEventHandlerTests.swift`
  (frozen monolith).

---

## Step 1 — strict-containment monitor helper (`Monitor.swift`)

`monitorApproximation` lives as a `CGPoint` extension near
`Sources/Nehir/Core/Monitor/Monitor.swift:486`:

```swift
func monitorApproximation(in monitors: [Monitor]) -> Monitor? {
    if let containing = monitors.first(where: { $0.frame.contains(self) }) {
        return containing
    }
    return monitors.min(by: { $0.frame.distanceSquared(to: self) < $1.frame.distanceSquared(to: self) })
}
```

Add a sibling that returns `nil` when the point is on no monitor (no
nearest-snap):

```swift
func monitorContaining(in monitors: [Monitor]) -> Monitor? {
    monitors.first(where: { $0.frame.contains(self) })
}
```

Fast gate after this step: `mise run test:compile`.

## Step 2 — containment-only frame helper + interaction fallback (`WMController.swift`)

Near `monitorForPlacementFrame` (`WMController.swift:1721`), add:

```swift
private func monitorContainingPlacementFrame(_ frame: CGRect?) -> Monitor? {
    guard let frame, !frame.isNull, !frame.isEmpty else { return nil }
    return frame.center.monitorContaining(in: workspaceManager.monitors)
}
```

In the fallback tail of `createPlacementTarget`, **after** the native-space
branch (ends `WMController.swift:1574`) and **before** the frame-monitor
fallback (`:1576`), insert:

```swift
// A synthesized focused-admission with no focused/native context still knows the
// interaction monitor. If the placement frame is off-screen (contained by no
// monitor — e.g. a parked negative-y frame that monitorApproximation would snap
// to the wrong display), trust the interaction monitor over the approximated
// frame monitor. An on-screen frame (contained by a real monitor) still falls
// through to the frame-monitor fallback below.
if let interactionMonitorId = createPlacementContext?.interactionMonitorId,
   monitorContainingPlacementFrame(windowFrame) == nil,
   monitorContainingPlacementFrame(AXWindowService.framePreferFast(axRef)) == nil,
   let workspace = workspaceManager.activeWorkspaceOrFirst(on: interactionMonitorId)
{
    return WorkspacePlacementTarget(
        workspaceId: workspace.id,
        monitorId: interactionMonitorId,
        isAuthoritative: true
    )
}
```

Rationale for ordering and guards:
- After native-space: a real native-space monitor (`:1566`) is authoritative
  (the window truly exists on that space) and must still win over interaction.
- Both frame checks must be non-containing: `windowFrame` is the WindowServer/
  window-info frame; `framePreferFast(axRef)` is the live AX fast frame. Only
  when **neither** places the window on a real monitor do we treat the frame as
  off-screen and defer to interaction.
- This branch is reachable in both `preferManagedFocusPlacement == true` and
  `false` paths because it lives in the shared tail, matching the buggy trace
  (which fell through the `preferManagedFocusPlacement` block).

Fast gate after this step: `mise run test:compile`.

## Step 3 — regression test (new per-behavior file)

Create `Tests/NehirTests/PlacementInteractionMonitorFallbackTests.swift` using
Swift Testing (`import Testing`). Use the **shared** support helpers
(`makeLayoutPlanPrimaryTestMonitor`, `makeLayoutPlanSecondaryTestMonitor`,
`makeLayoutPlanTestController` from `LayoutPlanTestSupport.swift`) — the
`makeAXEvent*` helpers are `private` to the frozen monolith and cannot be
reused; construct `WindowCreatePlacementContext` inline.

Topology: primary `(0,0,1920,1080)`, secondary `(1920,0,1920,1080)`.

**Test A — off-screen frame → interaction monitor wins (the bug).**
- Workspaces: `"1"` on `.main`, `"6"` on `.secondary`; set each active on its
  monitor; `setInteractionMonitor(secondary.id)`.
- `AXWindowService.fastFrameProviderForTests = { _ in nil }` (so the live-AX
  frame is nil), restored in `defer`.
- Call `controller.resolveWorkspaceForNewWindow` with:
  - `workspaceName: nil`
  - `axRef`: a throwaway `AXWindowRef`
  - `pid`: `getpid()`
  - `createPlacementContext`: `WindowCreatePlacementContext` with **only**
    `interactionMonitorId: secondary.id` set; `nativeSpaceMonitorId`,
    `activeFocusRequestWorkspaceId`, `activeFocusRequestMonitorId`,
    `focusedWorkspaceId`, `focusedMonitorId` all `nil`;
    `source: "ax_focused_admission_synthesized"`; `focusedWorkspaceSource: nil`;
    `recentPidWorkspaceId: nil`; `createdAt: Date()`.
  - `windowFrame: CGRect(x: 400, y: -1200, width: 800, height: 600)` — center
    `(800, -900)`, inside neither monitor, nearest = **primary** (the trap).
  - `fallbackWorkspaceId: primaryWorkspaceId`.
- `#expect(resolved == secondaryWorkspaceId)`. **Fails before the fix** (resolves
  to primary via the snapped frame monitor), passes after.

**Test B — on-screen frame still honored (regression guard for D2).**
- Same setup but `setInteractionMonitor(primary.id)` and
  `windowFrame: CGRect(x: 2000, y: 100, width: 400, height: 300)` — center
  `(2200, 250)`, **contained by secondary**.
- `#expect(resolved == secondaryWorkspaceId)` — the frame monitor (secondary)
  must still win over the interaction monitor (primary); the new branch is
  skipped because the frame is contained. This proves the fix does not steal
  legitimate frame-based placement.

Model the harness on the existing multi-monitor placement test at
`Tests/NehirTests/AXEventHandlerTests.swift:7175-7223`
(`fallbackWorkspaceDoesNotConstrainSameAppSiblingPlacement`) — it constructs two
monitors, sets active workspaces per monitor, and calls
`resolveWorkspaceForNewWindow` directly. Do not import from that file; replicate
only the shared-helper usage.

## Step 4 — changeset

```bash
mise run changeset patch "Open windows on the display you're using instead of the built-in display when macOS reports an off-screen initial position"
```

(No Nehir issue number was provided for this bug; do not invent one. If the user
supplies one, add `Fixes #NN` to the changeset summary and the commit body.)

## Step 5 — full gate

Run the full pipeline once at the end:

```bash
mise run check   # format + lint + build + test
```

All green required. Do not trust a partial run.

---

## Commit message shape

Plain English, no Conventional-Commits prefix (see `AGENTS.md`). Suggested:

```
Place focused-admission windows on the interaction monitor for off-screen frames

When macOS reports a new window's initial frame in an off-screen park zone,
monitorApproximation snapped it to the nearest (often internal) display and
placement trusted that over the known interaction monitor, so e.g. Finder
activated on the external display opened on the built-in one. Prefer the
interaction monitor when the placement frame is contained by no monitor;
on-screen frames still honor the frame monitor.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

## Acceptance

- New test file: Test A red before the WMController change, green after; Test B
  green throughout.
- `mise run check` fully green.
- Changeset fragment present.
- No edits outside the files listed under "Files to touch".
