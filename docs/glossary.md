---
title: Glossary
---

# Glossary

Shared terminology used across Nehir's internal documentation and specs.

---

## active column

The column tracked by `ViewportState.activeColumnIndex`. Updated on focus change, gesture snap, and viewport scroll commands.

See also: [focused window](#focused-window).

---

## clipped column

A column that straddles the viewport boundary — part of its width is inside the viewport, part is outside. The window is rendered at its real position; the visible portion is whatever the viewport frame exposes. **Not the same as [parked](#parked-window).**

In the [layout notation](viewport-navigation-spec.md#layout-notation), clipped columns are written with a split: `.N[.M` (clipped at left edge) or `.N].M` (clipped at right edge).

---

## focused window

The macOS window currently receiving keyboard input, as reported by the Accessibility API. Nehir tracks this via `AXEventHandler`.

See also: [active column](#active-column).

---

## focus follows mouse (FFM)

A mode where keyboard focus moves to whichever tiled window is under the cursor as the cursor moves. When FFM triggers a focus change, the viewport does **not** scroll — the cursor is already in the visible portion of the target column. FFM can only activate fully visible or [clipped](glossary.md#clipped-column) columns; [parked](glossary.md#parked-window) windows are offscreen and unreachable by the cursor. See [Reveal on Focus](viewport-navigation-spec.md#reveal-on-focus).

---

## parked window

A window the layout engine has moved to an offscreen resting position. Parked windows are not visible to the user. Due to a macOS limitation, exactly 1px of the window remains on-screen to prevent the system from reclaiming its display connection.

Represented internally as `ContainerVisibilityState.hidden(AxisHideEdge)` with a `layoutTransient` hidden reason. The edge (`.left` / `.right`) records which side the window is parked on.

In the [layout notation](viewport-navigation-spec.md#layout-notation), columns that are fully outside the viewport and have been parked appear as plain numbers outside `[]`, e.g. `30 [...]` — the `30` is a parked column on the left. A [clipped column](#clipped-column) (partially visible) is distinct and uses the split notation.

---

## reveal

Scrolling the viewport to bring a newly focused column into view. Whether a reveal occurs depends on the column's **visibility state** at the time focus changes:

- **Fully visible** — no reveal (any source)
- **[Parked](glossary.md#parked-window)** — always reveals to the closest snap (any source)
- **[Clipped](glossary.md#clipped-column) + FFM** — no reveal; cursor is already in the visible portion
- **[Clipped](glossary.md#clipped-column) + other source** — after visibility/source gates allow reveal, the `revealPartial` setting (`.default`, `.off`, `.snapClosest`, `.snapCenter`) chooses how the column is revealed

See [Reveal on Focus](viewport-navigation-spec.md#reveal-on-focus).

---

## snap grid

The ordered set of [snap points](#snap-point) for the current column layout. Computed from column positions and widths. The viewport targets the nearest snap point on gesture release.

See [Snap Grid](viewport-navigation-spec.md#snap-grid).

---

## snap point

A viewport offset value the snap grid can target. For each column, up to three snap points exist:

- **left-edge snap** — column's left edge aligns with the viewport's left edge
- **right-edge snap** — column's right edge aligns with the viewport's right edge
- **center snap** — column is centered in the viewport (only for columns whose effective width exceeds 30% of the viewport width)

In the [layout notation](viewport-navigation-spec.md#effective-snap-point-annotation), the effective snap point is annotated with `|`: `[|N` (left-edge), `N|]` (right-edge), `|H.H|` (center — column split at its midpoint, both halves must be equal).

---

## viewport

The visible portion of the column strip on a given monitor. Its horizontal position is described by `ViewportState.viewOffsetPixels`. The viewport does not resize; it scrolls over the column strip.

---

## viewport offset

The current scroll position of the viewport, stored as `ViewportState.viewOffsetPixels`. A `ViewOffset` enum with three states: `.static` (settled), `.gesture` (in motion), `.spring` (animating to target).

---

## viewport scroll command

`scrollViewport(.left)` / `scrollViewport(.right)` — commands that scroll the viewport to the previous or next [snap point](#snap-point) without immediately changing the [active column](#active-column). Focus transfers to the nearest visible column only when the active column becomes [parked](#parked-window).

Default bindings: `Cmd+Option+[` and `Cmd+Option+]`.

See [Viewport Scroll Commands](viewport-navigation-spec.md#viewport-scroll-commands).
