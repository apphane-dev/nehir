# OmniWM PR BarutSRB/OmniWM#384 — "Respect window min-size constraints in Niri column width" — Discovery

Source PR: https://github.com/BarutSRB/OmniWM/pull/384
Author: @biswadip-paul (co-authored by "Claude Opus 4.6"); one source commit + tests, single file.
Fixes issue: https://github.com/BarutSRB/OmniWM/issues/383 (related to #268/BarutSRB/OmniWM#283).
Merge state: **closed without merge** upstream — so judge the *concept*, never the diff.
Scope of this doc: determine whether nehir's Niri column-width layout already respects
per-window min-size constraints (the LAYOUT side of the min-size problem), and whether
the PR's concept is safe/needed to port.

All file/line references were verified against the Nehir source tree at
`7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace"). Line
numbers drift — re-verify before implementing.

---

> **Filed under `discovery/noop/`** — the verdict is 🟢 **Fixed / don't port**: nehir already
> propagates window min-size into the Niri column-width engine and clamps column width **up**
> to it (`resolveSpan`), and the very relaxation the PR removes — an *unconditional*
> `relaxedForResizePlaceholder()` that drops `minWidth`/`minHeight` to 1 for every window —
> **does not exist in nehir**. nehir never adopted OmniWM's `resizePlaceholderState` subsystem;
> it relaxes constraints only via a strictly-scoped `relaxedForLayoutFeasibility()` that fires
> solely when a window's own minimum exceeds the monitor feasibility frame. Porting the PR's
> concept is therefore a no-op, and porting the diff verbatim is impossible (the gated symbol
> does not exist). Owns no new repo action. The paired AX side lives in the sibling discovery
> `20260616-omniwm-403-frame-write-race-min-size-suppression.md`; see the final section for why
> BarutSRB/OmniWM#384 does **not** close BarutSRB/OmniWM#403's loop and why a premise in BarutSRB/OmniWM#403's write-up needs revisiting.

---

## TL;DR

- **nehir's column-width layout already respects per-window min-size: `resolvedLayoutConstraints` preserves the full `minSize` in the normal case, `updateWindowConstraints` pushes it onto the layout node, and `resolveSpan`/`widthBounds` clamp the column width up to `minSize.width`. The OmniWM PR's specific bug — an unconditional `relaxedForResizePlaceholder()` collapsing every window's min to 1 — is absent in nehir; the method, the `ResizePlaceholderState` type, and the snapshot field it gated on do not exist here at all.**
- **Verdict:** 🟢 **Fixed / don't port.** Porting the concept is a no-op; the concept is already implemented and tested. The triage `evaluate` flag resolves to "no."

## The upstream change (concept, from the closed diff)

The PR touches only `Sources/OmniWM/Core/Controller/LayoutRefreshController.swift` (plus
tests). Its thesis, from the PR description:

> *Previously, `layoutConstraints` were unconditionally relaxed via
> `relaxedForResizePlaceholder()`, dropping `minWidth`/`minHeight` to 1 for all windows.
> This meant the layout engine couldn't clamp column widths to respect app minimum sizes,
> causing apps like WhatsApp to trigger resize placeholders (or get parked offscreen) when
> the column preset was narrower than the app's minimum width. Now, constraints are only
> relaxed for windows already in a resize-placeholder state. For all other windows, the full
> constraints propagate to the layout engine, allowing `resolveSpan()` to clamp column widths
> up to the app's minimum size.*

The diff is one branch:

```swift
// OmniWM LayoutRefreshController.swift (snapshot build loop)
-                    layoutConstraints: mergedConstraints.relaxedForResizePlaceholder(),
-                    ...
-                    resizePlaceholderState: controller.workspaceManager.resizePlaceholderState(for: entry.token)
+            let resizePlaceholderState = controller.workspaceManager.resizePlaceholderState(for: entry.token)
+            let layoutConstraints = resizePlaceholderState != nil
+                ? mergedConstraints.relaxedForResizePlaceholder()
+                : mergedConstraints                        // ← full minSize preserved for normal windows
```

Issue #383 is the user symptom: min-size-constrained apps (WhatsApp, Music) shown "too small"
or parked offscreen when a column preset is narrower than the app's enforced minimum, on
screens where the next-larger preset overflows the display.

## Provenance: is this nehir's code?

Partially — the *call site* exists under the renamed module, but the **bug does not**, because
the symbols the PR hinges on were never ported:

- nehir's snapshot-build loop is `buildWindowSnapshots` at
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:482` (1:1 role with OmniWM's site).
- `ffgrep relaxedForResizePlaceholder` → **no matches anywhere in nehir.** The method does not exist.
- `ffgrep resizePlaceholderState` → **no matches anywhere in nehir.** The
  `ResizePlaceholderState` type, the `workspaceManager.resizePlaceholderState(for:)` accessor,
  and the `layoutConstraints`/`resizePlaceholderState` snapshot fields it gated on do not exist.
- `LayoutWindowSnapshot` (`Sources/Nehir/Core/Layout/LayoutBoundary.swift:4`) carries
  `token`, `constraints`, `layoutConstraints`, `hiddenState`, `layoutReason`,
  `showsNativeFullscreenPlaceholder` — **no `resizePlaceholderState` field.** nehir has no
  "resize placeholder" subsystem at all.

So this is not "the same file, different code" — it is "the relaxation the PR removes was
never introduced." The relevant question becomes: does nehir's own relaxation already preserve
min-size in the normal case? It does (next section).

## The code in question (nehir's equivalent path, verbatim)

nehir computes `layoutConstraints` per window through a *gated* relaxation, not an unconditional
one:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:528  (inside buildWindowSnapshots)
let layoutConstraints = resolvedLayoutConstraints(
    for: mergedConstraints,         // full minSize (app cached + rule min + inferred resize min)
    layoutReason: layoutReason,
    hiddenState: hiddenState,
    workingFrame: workingFrame,     // monitor working area
    containingFrame: containingFrame
)
```

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:543
private func resolvedLayoutConstraints(...) -> WindowSizeConstraints {
    let effectiveConstraints = constraints.normalized()
    if effectiveConstraints.isFixed || layoutReason == .nativeFullscreen { return effectiveConstraints }

    guard layoutReason == .standard,
          hiddenState == nil,
          let workingFrame
    else { return effectiveConstraints.relaxedForLayoutFeasibility() }   // ← nehir's ONLY relaxation

    let tolerance: CGFloat = 0.5
    let feasibilityFrame = containingFrame ?? workingFrame
    if effectiveConstraints.minSize.width <= feasibilityFrame.width + tolerance,
       effectiveConstraints.minSize.height <= feasibilityFrame.height + tolerance
    {
        return effectiveConstraints               // ← NORMAL CASE: full minSize preserved
    }
    return effectiveConstraints.relaxedForLayoutFeasibility()  // ← only when min > whole monitor
}
```

The relaxation itself is named for its true scope:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:142
func relaxedForLayoutFeasibility() -> WindowSizeConstraints {
    guard !isFixed else { return normalized() }
    return WindowSizeConstraints(minSize: .init(width: 1, height: 1), maxSize: maxSize, isFixed: false)
}
```

The preserved min-size then flows to the engine and is honored by the clamping math:

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:370  (layout pass, per window)
engine.updateWindowConstraints(for: window.token, constraints: window.layoutConstraints)
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:84
func updateWindowConstraints(for token: WindowToken, constraints: WindowSizeConstraints) {
    guard let node = tokenToNode[token] else { return }
    let normalized = constraints.normalized()
    guard node.constraints != normalized else { return }
    node.constraints = normalized
    clampColumnWidthToBounds(for: node)          // :98 — re-clamp the column immediately
}
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:551
func widthBounds() -> (min: CGFloat, max: CGFloat?) {
    var minWidth: CGFloat = 1
    for window in windowNodes {
        let constraints = window.constraints.normalized()
        minWidth = max(minWidth, constraints.minSize.width)   // :554 — column min = max of window mins
        ...
    }
    return (minWidth, maxWidth.map { max($0, minWidth) })
}

// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:526
private func resolveSpan(..., minConstraint: CGFloat, maxConstraint: CGFloat?) -> CGFloat {
    ...
    if result < minConstraint { result = minConstraint }      // :548 — CLAMP UP to min width
    if let effectiveMaxConstraint, result > effectiveMaxConstraint { result = effectiveMaxConstraint }
    return result
}
```

(The single-window path is even more direct: `resolvedSingleWindowRect`/`resolvedSingleWindowSize`
read the un-relaxed `context.window.constraints` at `NiriLayout.swift:732`/`:754`, so a lone
min-size window always gets its minimum.)

## Why it doesn't apply (and porting would be a no-op or impossible)

### 1. The relaxation BarutSRB/OmniWM#384 removes does not exist in nehir

OmniWM's bug is `mergedConstraints.relaxedForResizePlaceholder()` applied to **every** window,
unconditionally. nehir has no `relaxedForResizePlaceholder` and no `resizePlaceholderState`
gating. Its sole relaxation, `relaxedForLayoutFeasibility()` (`NiriNode.swift:142`), is reached
**only** in the explicit edge cases in `resolvedLayoutConstraints` (`LayoutRefreshController.swift:543`):

- the window is **fixed-size** or in **native fullscreen** → returned as-is (no relaxation at all);
- `layoutReason != .standard`, the window is **hidden**, or there is **no working frame** → relaxed
  (correct: an offscreen window or a monitorless layout has nothing to be feasible against); or
- the window's **own** `minSize` exceeds the whole **feasibility frame** (`monitor.visibleFrame`) →
  relaxed (correct: the window physically cannot fit on the monitor; without relaxation the solver
  is infeasible).

In the exact scenario #383 reports — a visible, standard-layout, on-monitor app whose preset is
narrower than its enforced minimum — none of those branches fire, so `layoutConstraints` carries
the **full** `minSize`, exactly what PR BarutSRB/OmniWM#384 restores upstream.

### 2. nehir's column math already clamps up to min-width

Because the full `minSize` propagates (`NiriLayoutHandler.swift:370` →
`NiriLayoutEngine+Windows.swift:84`), `widthBounds()` (`NiriNode.swift:551`) derives the column's
`minWidth` from the windows' `minSize.width`, and `resolveSpan` (`NiriNode.swift:548`) clamps the
resolved column width **up** to that minimum. A WhatsApp at a 50%-preset-below-its-minimum does
**not** get a sub-minimum column in nehir; it gets `max(preset, minSize.width)`. The #383
"too-small / parked-offscreen" symptom has no production trigger here.

### 3. It is already tested

nehir locks this behaviour in directly — the PR's own test (`windowWithLargeMinSizeClampsColumnWidthInNiri`)
has nehir equivalents already on the books:

- `constraintApplicationRespectsBounds` (`Tests/NehirTests/NiriLayoutEngineTests.swift:1909`) —
  asserts `updateWindowConstraints` plants `window.constraints.minSize.width == 400` on the node.
- `constraintApplicationCancelsWidthAnimationWhenRuntimeMinimumExceedsTarget`
  (`NiriLayoutEngineTests.swift:1933`) — asserts a runtime minimum larger than the animated target
  cancels/clamps the column animation (the clamp-up behaviour).
- `NiriLayoutEngineTests.swift:537` — two windows each with `minSize.width == 700` drive the column
  into overflow **tabbed mode** (a usable, on-screen fallback), not an offscreen placeholder — the
  min-size is honoured as the feasibility constraint.

### Why porting the diff verbatim is impossible, and the concept is a no-op

- The diff edits `mergedConstraints.relaxedForResizePlaceholder()` and reads
  `controller.workspaceManager.resizePlaceholderState(for:)`. **Neither symbol exists in nehir.**
  Applying the patch would not compile. Adapting the concept means "don't unconditionally relax min-
  size" — which nehir already does not do.

## Distinction from the sibling BarutSRB/OmniWM#403 discovery (and a correction to its premise)

The triage note pairs this PR with `20260616-omniwm-403-frame-write-race-min-size-suppression.md`
(the AX frame-write race side). BarutSRB/OmniWM#403 is valid and stands: its loop (failed write → unsuppressed
app snap-back → identical re-write) reproduces in nehir and its one-clause suppression fix ports
cleanly. **But one premise in BarutSRB/OmniWM#403's write-up needs revisiting in light of this doc:**

> *BarutSRB/OmniWM#403, §"Why it applies" step 1: "nehir's column-width math does **not** yet respect that minimum
> (that is the separate BarutSRB/OmniWM#384 layout-side pairing) … so it computes a target smaller than the app's
> enforced minimum."*

That conflates two distinct axes. nehir's column math **does** respect a known min-size (this doc,
§2). The "sub-minimum target" that fuels BarutSRB/OmniWM#403's loop does not come from the *propagation* gap BarutSRB/OmniWM#384
fixes (unconditional relaxation) — nehir has no such gap. It comes from a different axis: **constraint
discovery**. On a window's early layouts, before the app's min-size has been cached/inferred,
`cachedConstraints(for:)` returns `nil` → `mergedConstraints` is `.unconstrained` (`minSize = 1`)
(`LayoutRefreshController.swift:500`–`:504`) → `resolveSpan` has `minConstraint = 1` → a sub-minimum
target is computed and written, the app clamps it back, and BarutSRB/OmniWM#403's race engages. That transient is
closed by the **resize-minimum learner / `inferredResizeMinimumSize`** path
(`LayoutRefreshController.swift:512`–`:516`), which BarutSRB/OmniWM#403 itself cites — not by BarutSRB/OmniWM#384.

Consequences for the orchestrator:

- **Porting BarutSRB/OmniWM#384 would NOT close BarutSRB/OmniWM#403's loop.** nehir already propagates min-size; there is nothing
  for BarutSRB/OmniWM#384 to add. BarutSRB/OmniWM#403's "pair this fix with a BarutSRB/OmniWM#384 port" caveat should be read as "pair it with
  the *constraint-learning* path" — which nehir already has — not with an BarutSRB/OmniWM#384 port.
- BarutSRB/OmniWM#403's own verdict (🔴 Applies, port the suppression clause) is unaffected; only its
  *root-cause framing* of the bad target (attributed to missing column-width min-size respect)
  should be corrected to "uncached/undiscovered min-size on early layouts." The fix (suppress the
  snap-back while a recent failure is recorded) is correct regardless, because it bounds the loop
  during exactly the pre-learning window.

## Recommendation

**Do not port/adapt PR BarutSRB/OmniWM#384.** Concretely:

1. Do **not** introduce a `resizePlaceholderState`-gated relaxation in nehir — there is no
   `resizePlaceholderState` subsystem to gate on, and no unconditional relaxation to gate.
2. nehir's `resolvedLayoutConstraints` (`LayoutRefreshController.swift:543`) is already the
   correct, stricter, earlier-layer version of what BarutSRB/OmniWM#384 restores upstream. Leave it.
3. The min-size respect that #383 asks for is already provided by
   `resolveSpan`/`widthBounds` (`NiriNode.swift:526`/`:551`) + the inference path
   (`LayoutRefreshController.swift:512`). No additional clamp site is warranted.
4. (Cross-doc) Update BarutSRB/OmniWM#403's root-cause note when it is actioned: the bad target is a
   constraint-**discovery** transient, not a constraint-**propagation** gap — BarutSRB/OmniWM#384 is not the
   structural pair for it.

## Suggested tests

nehir already has the regression coverage (§3). One optional addition would lock the
*normal-case* propagation explicitly against a future bad port, mirroring the PR's test:

1. **Large-min window in a narrow-preset column clamps up, stays on screen.** A single window with
   `minSize.width = 2500` on a `visibleFrame.width = 3000` monitor, column preset that would
   otherwise resolve to ~1500. Assert the emitted `frameChange.frame.width >= 2500`
   (`resolveSpan` clamp at `NiriNode.swift:548`) and that no hide/placeholder is produced. This is
   the direct nehir analogue of the PR's `windowWithLargeMinSizeClampsColumnWidthInNiri` and
   guards the `resolvedLayoutConstraints` normal-case branch (`LayoutRefreshController.swift:567`).
