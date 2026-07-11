# OmniWM PR BarutSRB/OmniWM#364 — "Fix windows overlapping across monitors" (→BarutSRB/OmniWM#349) — Discovery

Source PR: https://github.com/BarutSRB/OmniWM/pull/364
Author: @biswadip-paul (co-authored by "Claude Opus 4.6"); two commits, +23 −0, single file.
Targets issue: https://github.com/BarutSRB/OmniWM/issues/349 (discovered in parallel →
`noop/20260616-omniwm-349-hidden-window-bleeds-multi-monitor.md`).
Scope of this doc: assess whether the PR's *concept* (post-layout clamp of a window's
rendered frame to its containing monitor's bounds to prevent cross-monitor overflow) is
applicable to nehir; judge the diff's quality (coverage + idioms); and decide whether to
adapt the fix.

All file/line references were verified against the Nehir source tree at
`7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace"). Re-verify
before implementing; line numbers drift.

---

> **Filed under `discovery/noop/`** — the verdict is 🟢 **Fixed / don't port**: nehir already
> prevents cross-monitor bleed at a stricter, earlier layer than PR BarutSRB/OmniWM#364's post-layout clamp
> (an overflowing tiled column is classified `.hidden` *before* any visible frame is emitted,
> and hidden windows are parked offscreen by an overlap-minimising resolver), and the PR is
> closed-without-merge upstream. Porting the diff as written would **regress** (clamps to the
> wrong basis `monitor.frame` vs nehir's `monitor.visibleFrame`, and drops windows on null
> intersection instead of parking them). This doc contributes no new root cause and owns no
> repo action: if a BarutSRB/OmniWM#349-like bleed ever reproduces, it belongs to the **stale-live-frame**
> family, not an unclamped visible frame. It is the **deduped survivor of a concurrent worker
> race**: two near-complete siblings reached the identical verdict and were removed —
> `20260616-omniwm-364-clamp-visible-frames-post-layout-noop.md` (an independent re-verification
> pass) and `20260616-omniwm-364-clamp-visible-frames-to-monitor-bounds.md`. This doc subsumes
> their content.

---

## Merge state (correcting the triage note)

The triage flagged this PR as **open**. The upstream state today is **closed, not merged**
(GitHub API: `state=closed`, `merged=false`; the `pull/364.diff` endpoint serves the two
commits as an unmerged patch, and the parallel BarutSRB/OmniWM#349 discovery independently recorded
"Closed without merge"). So BarutSRB/OmniWM#364 was **rejected upstream** — it never landed in OmniWM. That
makes the verdict here about whether to *adapt* the concept into nehir, not whether to
back-merge a real fix.

## TL;DR

- **nehir already prevents cross-monitor bleed at a stricter, earlier layer than this PR's
  clamp: a tiled column whose rendered rect overflows into a neighbouring monitor's frame
  is reclassified `.hidden` *before* any frame is committed, and hidden windows are parked
  offscreen by an overlap-minimising resolver. The PR's post-layout clamp of *visible*
  frames is therefore a no-op where nehir is strong, and useless where BarutSRB/OmniWM#349's symptom
  actually lives (hidden windows — which the PR explicitly excludes).**
- **The diff is technically fine in one detail** (commit 2's deferred-mutation arrays are
  the correct Swift fix for the concurrent-dictionary-mutation crash commit 1 introduced),
  **but conceptually wrong for nehir**: it clamps to `monitor.frame` (full screen incl.
  menu bar) while nehir's layout basis is `monitor.visibleFrame` (working area), and on a
  null intersection it *removes* the window from `framePool` without routing it to
  `hiddenHandles`, which downstream `layoutDiff` would then **silently skip** — a drop,
  not a fix.
- **Verdict:** 🟢 **Fixed / don't port.** nehir's `overflowEdgeIntersectingNeighboringMonitor`
  guard (`NiriLayout.swift:378`, def `:406`) — present since the `9a46877` "Initial Nehir
  import" baseline — supersedes the concept. Porting the clamp as written would be a
  regression. The triage `evaluate` flag resolves to "no."

## Provenance: is this nehir's code?

Yes. The exact function the PR patches exists in nehir under the renamed module path:

- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Animation.swift:228` —
  `calculateCombinedLayoutUsingPools`, returning `(frames: framePool, hiddenHandles:
  hiddenPool)`. This is 1:1 with OmniWM's
  `Sources/OmniWM/Core/Layout/Niri/NiriLayoutEngine+Animation.swift` that BarutSRB/OmniWM#364 edits.

The PR's *fix* (`clampVisibleFramesToMonitorBounds`) is **not present in nehir**: `ffgrep`
for the symbol returns only matches inside the discovery docs themselves, nothing under
`Sources/`. So the question is purely "should we adapt it" — and the answer depends on
whether anything earlier in nehir already achieves the clamp's goal. It does (below).

## The upstream change (verbatim, from the API `/pulls/364/files` patch)

Both commits touch only `NiriLayoutEngine+Animation.swift`. Commit 1 inserted the clamp
with an in-loop mutation (crashed); commit 2 rewrote it with deferred mutation. The final
merged-as-patch form is:

```swift
// OmniWM: NiriLayoutEngine+Animation.swift — inserted just before `return (framePool, hiddenPool)`
+        clampVisibleFramesToMonitorBounds(monitor.frame)
+
         return (framePool, hiddenPool)
// ...
+    private func clampVisibleFramesToMonitorBounds(_ monitorBounds: CGRect) {
+        var toRemove: [WindowToken] = []
+        var toUpdate: [(WindowToken, CGRect)] = []
+
+        for (token, frame) in framePool where hiddenPool[token] == nil {   // visible windows only
+            let clamped = frame.intersection(monitorBounds)
+            if clamped.isNull {
+                toRemove.append(token)
+            } else if clamped != frame {
+                toUpdate.append((token, clamped))
+            }
+        }
+
+        for token in toRemove {
+            framePool.removeValue(forKey: token)                            // drop, not park
+        }
+        for (token, rect) in toUpdate {
+            framePool[token] = rect
+        }
+    }
```

The PR's own summary states the goal precisely: *"intersects each visible window's frame
with `monitor.frame`, removing frames that fall entirely outside the monitor bounds,"* and
*"Hidden windows … are excluded … since their positioning is handled separately."*

## What BarutSRB/OmniWM#349 reports (the bug this PR claims to fix)

> *"When i am using two monitors … windows not hiding fully. part of the hided window, that
> should be out of the visible monitor, are shown over shown window."*

The reporter's symptom is a **hidden** window's strip bleeding onto the adjacent monitor.
The PR re-frames it as *"tiled window frames bleeding"* and then **explicitly excludes the
hidden windows that are the actual symptom**. That mismatch is the heart of why this fix
was rejected upstream and why it is irrelevant to nehir.

## Why it doesn't apply (and the concept is already handled better in nehir)

### 1. nehir prevents the overhang at classification time — before any visible frame exists

Every container is classified by `containerVisibilityState` (`NiriLayout.swift:356`, the
verdict computed at `:378`), and only `.visible` columns emit unclamped frames. The verdict
already rejects any column whose overflow touches a neighbour:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:378-387  (inside containerVisibilityState)
        if let overflowEdge = overflowEdgeIntersectingNeighboringMonitor(
            renderedRect,
            viewportFrame: viewportFrame,
            orientation: orientation,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        ) {
            return .hidden(overflowEdge)   // :385  overflow lands on a neighbour → hide the WHOLE column
        }
        return .visible                     // :387  reachable ONLY when no neighbour-overflow
```

`overflowEdgeIntersectingNeighboringMonitor` (def `NiriLayout.swift:406`) computes the slice
of the column that sticks out past the viewport (`containerOverflowRegions`) and, for each
**non-owning** monitor, tests whether it intersects that monitor's frame:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:420-430
        for overflowRegion in overflowRegions {
            for otherMonitor in hiddenPlacementMonitors where !ownsViewport(   // :421  exclude the owning monitor
                otherMonitor,
                hiddenPlacementMonitor: hiddenPlacementMonitor,
                viewportFrame: viewportFrame
            ) {
                if overflowRegion.rect.intersects(otherMonitor.frame) {         // :426  neighbour-touch test
                    return overflowRegion.edge
                }
            }
        }
        return nil
```

Because the `.visible` branch (`renderedContainerRect = visibilityRect`, layout split site
`NiriLayout.swift:275`) is **only reachable when that guard returns `nil`**, every frame a
visible column produces is already inside the owning monitor — there is no overhang left for
a post-pass clamp to trim. Windows are sized inside their container (`layoutContainer`,
`NiriLayout.swift:291`), so a bounded column ⇒ bounded window frames. The clamp is a no-op
in the multi-monitor side-by-side case it targets. (`git log -S` shows this guard ships in
the `9a46877` "Initial Nehir import" — it is nehir's baseline design, not a recent backport.)

### 2. The hidden windows (the real BarutSRB/OmniWM#349 symptom) are parked by an overlap-minimising resolver

Columns that *do* overflow are `.hidden`, so their windows go to `hiddenHandles`
(`NiriLayout.swift:278`) and are **never in `framePool` at all**. They are parked offscreen
by `HiddenWindowPlacementResolver`, which picks the origin that minimises overlap with every
other monitor — trying both hide edges and multiple vertical parking lanes:

```swift
// Sources/Nehir/Core/Layout/SideHiding.swift:71  enum HiddenWindowPlacementResolver
// :72  static func physicalScreenEdgeOrigin(...)
// :103-104  (comment + call) "…otherwise preserving that source-display Y can leave a
//            large strip visible on an adjacent monitor."  → verticalParkingCandidates(...)
// :121 / :194 / :209 / :260  overlapArea(...) minimised across lanes and edges
```

The `:103` comment describes BarutSRB/OmniWM#349's exact failure mode and is nehir's deliberate guard. The
PR's clamp does nothing for these windows by its own admission (`where hiddenPool[token] ==
nil`), so even in OmniWM the patch cannot address the reporter's literal symptom.

### 3. nehir already clamps — but on the paths where it is correct, and to `visibleFrame`

nehir is not "anti-clamp"; it applies bounds-clamping on the paths where a window can
legitimately stray and where classify-and-hide does not apply, and crucially it clamps to
the **working area** (`monitor.visibleFrame`), not the full screen:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:1475        floating frames
        return clampedFloatingFrame(offsetFrame, in: monitor.visibleFrame)
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:3037 / :3062   restore origins
        let restoredOrigin = clampedOrigin(forTopLeft: topLeft, windowSize: frame.size, in: restoreFrame)
```

The tiled layout path is the one exception — and there, classification-and-parking is the
stricter choice. So nehir's clamp posture is intentional and consistent, not an oversight.

### 4. Why porting the diff as-is would regress (three concrete hazards)

- **Wrong basis.** The PR clamps to `monitor.frame` (full screen, including the menu-bar /
  past the dock). nehir sizes and positions tiled layouts against `monitor.visibleFrame`
  (the working area) — `monitorFrame: monitor.visibleFrame` at
  `NiriLayoutEngine+Animation.swift:254`, `screenFrame: monitor.frame` at `:255`. Clamping
  visible frames to `monitor.frame` would permit frames into the menu-bar strip,
  contradicting the layout's own sizing basis (and is inconsistent with the `visibleFrame`
  basis nehir uses for floating clamps above).
- **Drops windows instead of parking them.** `framePool.removeValue(forKey: token)` on a
  null intersection removes the window from the frame pool but does **not** add it to
  `hiddenHandles`. Downstream, `layoutDiff` does
  `guard let frame = frames[token] else { continue }` (`NiriLayoutHandler.swift:931`) — a
  window absent from both `frames` and `hiddenHandles` is skipped entirely: no `.hide`, no
  `.show`, no frame change. It would be left at a stale frame, which *is* the bug, not the
  fix. nehir's correct invariant is classify-and-park, never drop.
- **Single-monitor clamp cannot reason about neighbours.** `frame.intersection(monitorBounds)`
  only knows the owning monitor, but bleed is a *neighbour*-monitor phenomenon. nehir's
  classifier inspects neighbour frames directly (`:421`/`:426`), which is exact; the clamp
  is heuristic and would clip a legitimately-visible-in-own-monitor frame that merely
  *looks* like it overhangs the owning frame's edge with no neighbour there (single-monitor
  edge case).

### Diff-quality assessment (as the triage asked)

- **Good:** commit 2's two-pass deferred mutation (`toRemove`/`toUpdate` then apply) is the
  correct, idiomatic fix for the Swift "mutate-during-`for-in`" crash that commit 1 had. As
  a standalone Swift pattern it is sound.
- **Coverage gaps:** the clamp covers exactly **one** site (the visible `framePool` return).
  It does **not** cover hidden windows (the actual symptom), floating windows (separate
  path — nehir already clamps these), or the stale-live-frame family (separately documented
  in `20260616-stale-live-frame-on-stably-hidden-column.md` /
  `20260616-workspace-inactive-stale-live-frame.md`).
- **Semantics:** "clamp-and-drop" conflicts with nehir's "hide-and-park" policy (§4 above).
  It is a different UX outcome (clip a partially-visible column vs. vanish the whole column
  the instant any edge crosses into a neighbour), smuggled in as a hardening.

### Residual edge cases (honestly stated)

- If a hidden window is so large that **no** parking lane yields zero overlap,
  `HiddenWindowPlacementResolver` returns the minimum-overlap origin, so a sliver could
  remain in an extreme case. The PR does **not** help here either (hidden windows are
  excluded), so this is a pre-existing nehir characteristic, not a gap the PR fills.
- nehir's classifier admits a `niriViewportPreParkMargin` for visibility gating; that margin
  sits *inside* the owning viewport and cannot by itself reach a neighbour monitor, so it is
  not a bleed vector for the reported symptom.

## Distinction from nehir's stale-live-frame discoveries

If a BarutSRB/OmniWM#349-like symptom (a "hidden" window's pixels on another monitor) ever appears in
nehir, it is **not** this PR's mechanism. It is the *stale-live-frame* family: a window nehir
believes hidden whose live AX frame never advanced to the park slot (state/cache desync +
park-write failure), documented in the two stale-live-frame briefs. The table from the
parallel BarutSRB/OmniWM#349 discovery holds:

| | BarutSRB/OmniWM#349 / PR BarutSRB/OmniWM#364 | nehir stale-live-frame discoveries |
|---|---|---|
| Window's logical state at layout | **Visible** (tiled column) | **Hidden** (`layoutTransient` / workspace-inactive) |
| What is wrong | Computed **visible frame** overhangs the monitor edge | **Live AX frame** stale / never reached the park slot |
| Layer | Layout geometry (no monitor clamp) | State/cache desync + park-write failure |
| Does the other's fix help? | Clamp skips `hiddenPool` ⇒ useless for stale frames | Reconciliation only runs on transitions ⇒ useless for an unclamped visible frame |

## Recommendation

**Do not port/adapt PR BarutSRB/OmniWM#364.** Concretely:

1. Do **not** add `clampVisibleFramesToMonitorBounds` (in any form) to
   `NiriLayoutEngine+Animation.swift`. nehir's classification-and-parking pipeline
   (`NiriLayout.swift:378`/`:406` + `SideHiding.swift:71`) supersedes it, and the helper's
   semantics (clamp to `monitor.frame`, drop on null) conflict with nehir's basis
   (`monitor.visibleFrame`, park-don't-drop). It is also closed-without-merge upstream.
2. The concept "clamp a rendered frame to monitor bounds" is **already** present in nehir on
   the paths that need it — floating (`WMController.swift:1475`) and restore
   (`LayoutRefreshController.swift:3037`) — both correctly to `visibleFrame`. No additional
   clamp site is warranted on the tiled path.
3. Commit 2's deferred-dictionary-mutation idiom is correct Swift but moot here, since the
   helper it fixes should not exist in nehir.
4. If a real multi-monitor bleed is reproduced in nehir, route it to the **stale-live-frame**
   work (capture the offending window's `hidden` reason, `lastApplied`, and live AX frame),
   not to an unclamped visible frame.

## Suggested tests

These lock in the behaviour nehir already has, so a future port attempt can't silently
regress it:

1. **Neighbour-overflow column is hidden, not clipped.** Two fake monitors with touching
   frames (e.g. M1 `frame=(0,0,2000,1000)`, M2 `frame=(2000,0,2000,1000)`), a workspace on
   M1 with one 1000-wide column. Scroll so the column's rendered rect is `x=1500..2500`
   (overhangs M2). Assert the column's windows are in `hiddenPool` (`hiddenHandles`),
   **absent** from `framePool`, and `framePool` contains no frame intersecting M2's frame.
2. **In-monitor partial column stays visible and bounded.** Same two monitors; scroll so the
   column is `x=500..1500` (fully inside M1). Assert the window is in `framePool` and its
   frame lies entirely within M1's `visibleFrame`.
3. **No window is dropped from the diff.** For a window whose frame ends up outside
   `monitor.frame`, assert `layoutDiff` (`NiriLayoutHandler.swift:931` call site) still
   emits either a `.hide` directive or a frame change — never silence. This is the exact
   regression the PR's `removeValue`-on-null would introduce.
4. **Hidden windows park with zero neighbour overlap when geometry allows.** Same two-monitor
   fixture, small windows. Assert every hidden window's placed frame
   (`HiddenWindowPlacementResolver.physicalScreenEdgeOrigin`) has `overlapArea(...) == 0`
   against all other monitors.
