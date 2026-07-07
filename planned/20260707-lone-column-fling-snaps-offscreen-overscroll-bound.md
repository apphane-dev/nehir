# Stop fling-scrolling from snapping a lone/narrow column off the display

**Status:** planned.
**Symptom:** On a workspace whose only column (or whose columns together) are
**narrower than the viewport**, a fast three-finger horizontal fling can park
that sole window ~90%+ off the display edge — it "disappears off the side" even
though it fits entirely on-screen with room to spare and there is nothing beyond
the edge to reveal.
**Desired behavior:** when the strip does not fill the viewport, every snap
(resting) position keeps the columns fully on-screen. A fling settles on a
fully-visible snap (left-aligned, right-aligned, or centered), never on an
off-content overscroll bound.

Root cause and full evidence: see
`discovery/20260707-lone-column-fling-snaps-to-offscreen-overscroll-bound.md`.

Source references verified against the main Nehir source tree at HEAD
`7a025b78` ("Verify window liveness before honoring a spurious AX destroy on
cold start") on 2026-07-07. **Re-verify line numbers before editing; they
drift.**

## Root cause (inline recap)

`computeSnapGrid` in
`Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift` unconditionally
appends the two `viewportStartBounds` endpoints as first-class snap *targets*:

```swift
// ViewportState+Geometry.swift (~:715-717)
let bounds = viewportStartBounds(columns: columns, gap: gap, viewportWidth: viewportWidth)
points.append(SnapPoint(offset: bounds.lowerBound, columnIndex: 0, kind: .rightEdge))
points.append(SnapPoint(offset: bounds.upperBound, columnIndex: columns.count - 1, kind: .leftEdge))
```

`viewportStartBounds` (~:600-618) grants an intentional 5% edge overscroll
(`upper = total - lastWidth*0.05 - gap`, `lower = firstWidth*0.05 + gap -
viewportWidth`). That idiom is correct only when there is content beyond the
edge to reveal — i.e. when the strip **fills** the viewport (`total >
viewportWidth`). When the strip is narrower than the viewport, both endpoints
land far outside the range where the columns are on-screen, yet they are live
snap targets. A fling projection then selects one and the gesture-end spring
(`ViewportState+Gestures.swift`, `endGesture` → `context.closest(to:)` →
`endGesture.spring`) rests the window off-display.

Concrete failing case (from the capture): one column `width=1480`, `gap=6`,
`viewportWidth=2466`. Snap grid = `{-2386, -980, -493, -6, 1400}`. The two
bound endpoints `1400` (upper) and `-2386` (lower) push the sole column ~90%+
off-screen; only `-980`/`-493`/`-6` keep it fully visible. A leftward fling
(`projectedViewStart≈1147`) snaps to `1400` → window at screen x=664, off
display 2.

## Fix (approach A — localize to snap targets; leave clamp/bounds untouched)

Only append the two `viewportStartBounds` endpoints as snap points **when the
strip actually fills the viewport**. When `total <= viewportWidth` there is
nothing to overscroll toward, and the per-column leftEdge/rightEdge/center snaps
already cover every fully-visible resting position.

Rationale for this site (not `viewportStartBounds` itself):
`boundedViewportStart` (the clamp built on `viewportStartBounds`) is called from
several paths (`ViewportState+Geometry.swift:627`, `:715`, and
`ViewportState+Gestures.swift:285`). Narrowing the *clamp* would change
transient-overscroll and relayout-clamp semantics broadly. The reported defect
is that off-content positions are **resting snap targets**; fixing
`computeSnapGrid` removes those rest positions with minimal blast radius while
leaving the overscroll clamp (transient spring overshoot) intact.

### Step 1 — gate the bound-snaps in `computeSnapGrid`

File: `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift`, function
`computeSnapGrid(columns:gap:viewportWidth:pixelTolerance:)`.

Replace the unconditional append of the two bound endpoints with a
strip-fills-viewport gate. Compute the strip total with the existing helper and
only append the bound-snaps when the strip is genuinely wider than the viewport:

```swift
let bounds = viewportStartBounds(columns: columns, gap: gap, viewportWidth: viewportWidth)
let stripTotal = totalWidth(columns: columns, gap: gap)
// The ±bound overscroll snaps park the edge column with only a 5% sliver
// visible — the niri "peek the neighbor" idiom. That only makes sense when
// there is content beyond the edge, i.e. the strip is wider than the viewport.
// For a strip narrower than the viewport these endpoints rest a column off the
// display; the per-column edge/center snaps already cover every on-screen rest
// position, so omit the bound-snaps in that case.
if stripTotal > viewportWidth + pixelTolerance {
    points.append(SnapPoint(offset: bounds.lowerBound, columnIndex: 0, kind: .rightEdge))
    points.append(SnapPoint(offset: bounds.upperBound, columnIndex: columns.count - 1, kind: .leftEdge))
}
```

Notes for the implementer:
- `totalWidth(columns:gap:)` already exists in the same file (~:317, forwards to
  `totalSpan`). Use it; do not reimplement.
- Keep `points.sortedAndDeduped(pixelTolerance: pixelTolerance)` at the end
  unchanged.
- Do **not** change the per-column edge/center snap logic (~:682-713) or the
  `columnApproximatelyFillsViewport` guard — those are orthogonal and already
  correct.
- Match surrounding style (the file already uses inline `bounded(...)` and
  descriptive comments in this idiom).

### Step 2 — regression tests

File: `Tests/NehirTests/ViewportSnapContextTests.swift` (extend the existing
`computeSnapGrid` and/or `ViewportStartBoundsTests` areas; reuse the existing
`makeColumns(widths:)` helper).

Add, at minimum:

1. **Lone narrow column omits the off-screen bound-snaps.**
   `columns = makeColumns(widths: [1480])`, `gap = 6`, `viewportWidth = 2466`.
   Assert the grid contains no snap that leaves the column off-screen: every
   snap `offset` must satisfy `-986 - tol <= offset <= 0 + tol` (the range where
   the 1480-wide column stays fully within the 2466 viewport). Equivalently
   assert the off-content endpoints `1400` and `-2386` are **absent**, and the
   fully-visible snaps (`≈ -980`, `≈ -493`, `≈ -6`) are present.
2. **Fling projection settles fully-visible.** With the same fixture, build a
   `snapContext` and assert `context.closest(to: 1147)?.offset` is the
   left-edge snap (`≈ -6`), **not** `1400`. This directly encodes the reported
   bug.
3. **Filled strip still overscrolls (no regression).** Keep/mirror the existing
   `boundsAllowEdgeOverscroll` fixture (`widths: [400,400,400]`, `gap: 8`,
   `viewportWidth: 500`, `total = 1216 > 500`) and assert the grid **still
   contains** the bound-snaps (`≈ 1188` upper, `≈ -472` lower). This proves the
   gate did not remove legitimate overscroll for filled strips.

Use the same `pixelTolerance` conventions already in the suite; prefer explicit
comments showing the arithmetic (the file already documents `total`/`lower`/
`upper` computations inline).

## Do-not-touch fences

- Do **not** modify `viewportStartBounds`, `boundedViewportStart`,
  `boundedViewOffset`, or any clamp behavior — the overscroll clamp is
  deliberately preserved (transient spring overshoot is fine).
- Do **not** modify `ViewportState+Gestures.swift` (`endGesture`, momentum
  projection, snap selection) — the fix is entirely in the snap *grid*.
- Do **not** touch the per-column edge/center snap generation or the
  `columnApproximatelyFillsViewport` guard.
- Do **not** touch any other file under `Sources/Nehir/Core/Layout/Niri/` or
  elsewhere. This change is two files plus a changeset.

## Gate

- **Between steps (fast):** `mise run build` (the change is a pure function;
  compilation is the fast signal). Optionally `mise run format:check` +
  `mise run lint`.
- **Once at the end (full):** `mise run check` (format + lint + build + test).
  The new tests must pass and the existing `ViewportSnapContextTests` /
  `ParkedViewportRelayoutTests` must stay green.

## Changeset (required — user-visible bug fix)

```bash
mise run changeset patch "Keep a lone or narrow column fully on-screen when fling-scrolling; stop snapping the viewport to an off-display overscroll bound when the strip is narrower than the viewport"
```

## Commit message shape

Plain-English subject, no Conventional-Commits prefix, e.g.:

```
Keep a narrow column on-screen when fling-scrolling

A fast horizontal fling could snap the viewport to an overscroll bound that
parked a lone/narrow column ~90% off the display, even though it fit entirely
on-screen with nothing to reveal beyond the edge. Only expose the ±bound
overscroll snaps when the strip is wider than the viewport; otherwise the
per-column edge/center snaps already cover every fully-visible rest position.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

(Reference a nehir issue number only if one exists for this — none is known at
plan time. Do not cite upstream tickets.)

## Completion token

On success, after the full gate is green, print exactly:

`PLAN_DONE_lone_column_offscreen_snap_fixed`
