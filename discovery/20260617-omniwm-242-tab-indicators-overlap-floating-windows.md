# BarutSRB/OmniWM#242 — "Tab indicators overlap floating windows" — Discovery

Groom 2026-07-07: still applicable — partial; TabbedColumnOverlayManager.shouldShowOverlay still checks viewport intersection only (no floating-occlusion filter in tabbedColumnOverlayInfos) (verified against main 7a025b78).

Source issue: <https://github.com/BarutSRB/OmniWM/issues/242>
Scope of this doc: determine whether the symptom reproduces in nehir — the
tabbed-column indicator rail drawing on top of a floating window that occupies
the same screen region — and whether any fix is needed.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

---

## TL;DR

- **nehir's tab overlay is not occlusion-aware:** `shouldShowOverlay` checks only
  viewport intersection, and the overlay-info collector never inspects floating
  windows. So when z-ordering places the overlay above a floating window, the
  rail draws over it — the BarutSRB/OmniWM#242 symptom can occur.
- **But nehir partly mitigates it:** the overlay is `level = .normal` and
  z-ordered relative to the active *tiled* window (`orderWindow(relativeTo:
  activeWindowId)`), not unconditionally above floating windows — so a focused
  floating window usually covers the overlay rather than the reverse.
- **Verdict:** 🟡 **Partial — owns a small action.** Make the tab overlay
  floating-occlusion-aware (suppress or lower it when a floating window covers
  its rail region). Low priority / cosmetic (the reporter calls it "not a huge
  dealbreaker").

## Issue context

- **State:** closed `not_planned`; no merged fix, no diff to port.
- **Symptom (verbatim):** "I noticed that the indicators of tabbed columns
  overlap the floating windows." (Screenshot shows the tab rail drawn over a
  floating window.) "Not a huge dealbreaker, but thought it was worth to
  mention."

## Provenance: is this nehir's code?

Yes — same overlay subsystem as BarutSRB/OmniWM#218 (`TabbedColumnOverlayManager`,
`TabbedColumnOverlayWindow`, `NiriLayoutHandler.updateTabbedColumnOverlays`).
The rail is drawn just **left** of a tabbed column:

```swift
// Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:547  (overlayFrame)
let x = visibleColumnFrame.minX - (width - TabbedOverlayMetrics.totalWidth)   // just LEFT of the column
let y = visibleColumnFrame.minY + (visibleColumnFrame.height - height) / 2
```

## The code in question

**The visibility gate is viewport-only — no floating-occlusion check:**

```swift
// Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:419
static func shouldShowOverlay(columnFrame: CGRect, visibleFrame: CGRect) -> Bool {
    let intersection = columnFrame.intersection(visibleFrame)
    return intersection.width >= TabbedOverlayMetrics.minVisibleIntersection &&
        intersection.height >= TabbedOverlayMetrics.minVisibleIntersection
}
```

**The info collector only walks tabbed columns; it never consults floating
entries:**

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1043  (tabbedColumnOverlayInfos)
for column in engine.columns(in: workspaceId) where column.isEffectivelyTabbed {
    guard let frame = column.renderedFrame ?? column.frame else { continue }
    let visibleColumnFrame = frame.intersection(monitor.visibleFrame)
    guard TabbedColumnOverlayManager.shouldShowOverlay(columnFrame: frame, visibleFrame: monitor.visibleFrame) else { continue }
    ...   // ← no check against floating window frames
}
```

**The overlay is `.normal` level, z-ordered relative to the active tiled window
(the partial mitigation):**

```swift
// Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:462  (init)
level = .normal
...
// Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:530  (update, ordering)
if let targetWid = info.activeWindowId, forceOrdering || lastActiveWindowId != targetWid || !wasVisible {
    SkyLight.shared.orderWindow(wid, relativeTo: UInt32(targetWid))   // targetWid == active tiled window
}
```

## Why this is Partial (applies, but partly guarded)

1. **The overlap can still occur.** Because the overlay rail sits at
   `visibleColumnFrame.minX − …` (just left of the column) and is only gated on
   viewport visibility, a floating window that covers that left-edge region does
   not suppress the rail. When z-ordering puts the overlay above that floating
   window (e.g. the tabbed column is the active/focused surface, so
   `forceOrdering` re-orders the rail up, and the floating window is not
   subsequently ordered above it), the rail draws over the floating window —
   exactly the reported symptom.

2. **nehir mitigates more than OmniWM appears to.** The overlay is `level =
   .normal` (`TabbedColumnOverlay.swift:462`) and ordered relative to the active
   *tiled* window, not placed at a high floating/status window level. A
   frontmost/focused floating window therefore usually renders above the rail and
   covers it, so the overlap is less frequent than an always-on-top
   implementation would produce. This is why the verdict is Partial, not fully
   Open.

3. **The upstream issue is `not_planned`** (declined, likely pending the rewrite)
   with no fix to port; nehir's residual is the missing occlusion check, not a
   wholesale design flaw.

## Recommendation

**Own a small, low-priority action: make the tab overlay floating-occlusion-aware.**
Two viable shapes (pick one):

- **Suppress:** in `tabbedColumnOverlayInfos` (`NiriLayoutHandler.swift:1032`),
  compute the candidate rail frame (`overlayFrame(for: visibleColumnFrame,
  tabCount:)`) and skip emitting the info when a floating window's rendered frame
  in the same workspace/monitor covers the rail region beyond a small tolerance.
  Floating frames are already available through the workspace manager / floating
  state (`floatingState.lastFrame`, used elsewhere in placement).
- **Lower:** alternatively, when occluded, drop the overlay's z-order below the
  occluding floating window (order relative to the floating window instead of
  the active tiled window) so the floating window covers it rather than the
  reverse. This keeps the rail visible when the floating window moves away
  without a full re-emit.

Suppressing is simpler and matches how nehir already hides overlays for
off-viewport columns. Either way the change is localized to the overlay-info
collection path; the per-pass refresh wiring (BarutSRB/OmniWM#218) already re-evaluates it on
every layout pass and floating move.

## Suggested tests

- A tabbed column plus a floating window whose frame covers the column's left
  rail region: assert `tabbedColumnOverlayInfos` emits no info for that column
  (or emits one flagged to be lowered) while the floating window occludes it.
- Move the floating window away from the rail region: assert the overlay info is
  re-emitted on the next pass and the rail reappears (no restart / manual
  action).
- Floating window covering only the *body* of the column but not the rail region:
  assert the overlay still shows (occlusion is rail-region-specific, not
  whole-column).
