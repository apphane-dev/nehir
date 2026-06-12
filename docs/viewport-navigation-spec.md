---
title: Viewport Navigation Spec
---

# Viewport Navigation Spec

Design specification for viewport navigation, snap behavior, and focus reveal policy.
This document captures the intended design; implementation may differ during transition.

---

## Layout Notation

A compact notation for describing viewport state in use cases.

```
20 30 .30[.20 *40 40] 55
```

- Space-separated column entries, left to right
- `[` / `]` mark the [viewport](glossary.md#viewport) edges
- Entries **outside** `[]` are outside the viewport — fully outside columns may be [parked](glossary.md#parked-window); columns straddling the edge are [clipped](glossary.md#clipped-column)
- Entries **inside** `[]` are visible in the viewport
- A plain number is the column width in viewport-width units (viewport = 100 units)
- `.N[.M` — [clipped](glossary.md#clipped-column) at the **left** viewport edge: `N` is the portion outside the viewport on the left, `M` is the visible portion (total column width = N+M)
- `.N].M` — [clipped](glossary.md#clipped-column) at the **right** viewport edge: `N` is the visible portion, `M` is the portion outside the viewport on the right (total column width = N+M)
- `*` prefix on an entry marks the [focused column](glossary.md#focused-window)

### Examples

```
[*30 30 .40].20 50
```
Four columns of width 30, 30, 60, 50. Viewport shows col1 (full), col2 (full), col3 ([clipped](glossary.md#clipped-column): 40 visible, 20 outside right). Col4 fully outside right (may be [parked](glossary.md#parked-window)). Col1 is focused.

```
20 30 .30[.20 *40 40] 55
```
Six columns. Col1 (20) and col2 (30) fully outside left ([parked](glossary.md#parked-window)). Col3 (50) clipped at left edge: 30 outside left, 20 visible. Col4 (40) focused and fully visible. Col5 (40) fully visible. Col6 (55) fully outside right (parked).

```
30 .10[.20 *60 .20].30
```
Four columns: 30, 30, 60, 50. Col1 fully outside left (parked). Col2 clipped left: 10 outside, 20 visible. Col3 (60) focused and fully visible. Col4 clipped right: 20 visible, 30 outside right.

### Effective snap point annotation

Use `|` to annotate the **currently effective** [snap point](glossary.md#snap-point) — the position the viewport is snapped to or targeting:

```
[|30 30 40] 50              left-edge snap on col1: | touches [
[30 40 30|] 50              right-edge snap on col3: | touches ]
.20[.25 |25.25| 25] 30      center snap on col3: column split at its midpoint
```

Rules:
- `[|N` — left-edge snap: `|` between `[` and the column; the column's left edge is flush with the viewport left
- `N|]` — right-edge snap: `|` between the column and `]`; the column's right edge is flush with the viewport right
- `|H.H|` — center snap: the column is split at its midpoint using `.`; total column width = H + H. Two validity conditions must both hold:
  1. **Equal halves** — the two `H` values must be equal (the `.` is at the column's midpoint)
  2. **Viewport symmetry** — the sum of all visible content from `[` to `.` must equal the sum from `.` to `]` (both = 50 when viewport = 100)

  Example: `.20[.25 |25.25| 25] 30` — left of `.`: 25+25=50 ✓, right of `.`: 25+25=50 ✓. Both conditions satisfied.

---

## Settings (redesigned)

### Removed

| Setting | Reason |
|---|---|
| Center Focused Column (picker: never / onOverflow / always) | Snap grid produces centering automatically — this picker has no distinct behavior left to control |
| Always Center Single Column (toggle) | A single visible column always gets a center snap point — this toggle has no independent effect |
| Scroll Reveal (picker: always / keyboard-and-commands / never) | Replaced by visibility-based reveal policy |

### Retained / renamed

| Setting | Notes |
|---|---|
| Mouse Modifier | Renamed from "Right Mouse Resize Modifier". Hold during a scroll gesture to bypass snap for that gesture. `none` = no way to bypass snap. |

### New

| Setting | Type | Default | Notes |
|---|---|---|---|
| Reveal Partial | `.off` / `.snapClosest` / `.snapCenter` | TBD | What happens when focus moves to a [clipped](glossary.md#clipped-column) column from any non-FFM source |

---

## Snap Grid

Snap points are computed per column. The viewport always snaps to the nearest snap point on gesture release (unless the mouse modifier is held).

### Snap point rules

For each column:
- **Left-edge snap** — viewport left aligns to show the column's left edge
- **Right-edge snap** — viewport right aligns to show the column's right edge
- **Center snap** — column is centered in the viewport. Only added when `column.effectiveWidth > 0.30 * viewportWidth`

Columns narrower than 30% of the viewport only get edge snaps. This keeps the snap grid sparse for multi-column layouts with small panels.

### Gesture release

On gesture release, the viewport snaps to the nearest snap point. The focused column updates to the column at the target snap position.

Hold the **Mouse Modifier** key during a gesture to bypass snapping — the viewport settles at the decelerated natural position.

---

## Reveal on Focus

"Reveal" means the viewport scrolls to bring a newly focused column into view. The decision is based on the column's **visibility state before focus changes**, not on what triggered the focus.

| Target visibility | Source | Behavior |
|---|---|---|
| Fully visible | Any | No scroll |
| [Parked](glossary.md#parked-window) | Any | Scroll to closest snap that reveals the column |
| [Clipped](glossary.md#clipped-column) | FFM | No scroll — cursor is already in the visible portion |
| [Clipped](glossary.md#clipped-column) | Keyboard / click / external | Controlled by **Reveal Partial** setting |

### Reveal Partial

`revealPartial: .off | .snapClosest | .snapCenter`

Applies when focus moves to a [clipped](glossary.md#clipped-column) column from any non-FFM source:

- **`.off`** — no scroll; the column is already partially visible and the user can reposition the viewport manually with `scrollViewport` commands
- **`.snapClosest`** — scroll to the snap point of the target column nearest to the current viewport position (minimal scroll)
- **`.snapCenter`** — scroll to center the target column

### Parked columns

When the target is [parked](glossary.md#parked-window), the viewport always scrolls to the **closest snap** that brings the column into view — the edge snap nearest to the current viewport position. No configuration.

If the target column is already at a valid snap position (within pixel tolerance), no scroll occurs.

---

## Viewport Scroll Commands

Two new commands — `scrollViewport(.left)` and `scrollViewport(.right)` — scroll the viewport through [snap points](glossary.md#snap-point) without immediately changing focus.

Default bindings: `Cmd+Option+[` (left) and `Cmd+Option+]` (right).

The [active column](glossary.md#active-column) does not change while it remains visible. When a scroll step causes the active column to become [parked](glossary.md#parked-window) (`ContainerVisibilityState.hidden(edge)`), focus transfers to the **nearest visible column** — no threshold, the existing binary parked state determines this.

---

## Use Cases

### Focus change: target fully visible

```
[|*30 30 40] 50
```
Any fully visible column is focused. Viewport is at rest at a snap position.

| Source | Result (focus col2) | Result (focus col3) |
|---|---|---|
| Any | `[|30 *30 40] 50` | `[|30 30 *40] 50` |

Target is fully visible — no reveal triggered. Snap point is not re-evaluated; viewport remains at rest.

### Focus change: target clipped (right side), non-FFM

```
[|*30 30 .40].20 50    col3 is 60 wide, 40 visible
```
User focuses col3 with keyboard or click.

`revealPartial = .off`:
```
[|30 30 *.40].20 50
```
No scroll — col3 is already partially visible.

`revealPartial = .snapClosest`:
```
.20[.10 30 *60|] 50
```
Minimal scroll: col3's right-edge aligns with viewport right.

`revealPartial = .snapCenter`:
```
30 .10[.20 *|30.30| .20].30
```
Viewport scrolls to center col3. Left of `.`: 20+30=50 ✓; right of `.`: 30+20=50 ✓.

### Focus change: target clipped (right side), FFM

```
[|*30 30 .40].20 50
```
Cursor moves over col3 (the visible portion). FFM activates col3.

```
[|30 30 *.40].20 50
```
Focus transfers to col3, viewport does not scroll.

### Focus change: target parked

```
[|*30 30 .40].20 50    col4 (50) is parked right
```
User navigates to col4 with any source (keyboard, click, external).

Parked target always scrolls to the closest snap — the edge snap nearest to the current viewport position. Col4 is parked right; closest snap is its right-edge snap:

```
30 30 .10[.50 *50|]
```
Col3 (60 wide) clipped left: 10 outside, 50 visible. Col4 (50) fully visible at right-edge snap.

### Viewport scroll command: `scrollViewport(.right)`

```
[|*30 30 .40].10 45
```
User presses `scrollViewport(.right)`. Next snap: col2 left-edge. Col1 scrolls fully outside — immediately [parked](glossary.md#parked-window) — focus transfers to col2.

```
30 [|*30 50 .20].25
```
Press again. Next snap: col3 center. Col2 slightly [clipped](glossary.md#clipped-column) but not [parked](glossary.md#parked-window) — focus stays on col2.

```
30 *.5[.25 |25.25| .25].20
```
Press again. Col2 fully outside — [parked](glossary.md#parked-window) — focus transfers to nearest visible column.

```
30 30 [|*50 .20].15
```

---

## Open Questions

- **`revealPartial` default**: `.snapClosest` feels less disruptive; `.snapCenter` feels more predictable. Needs user testing.
- **Center snap threshold (30%)**: exact value TBD. Determines whether a column gets a center snap point.
