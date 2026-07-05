---
title: Viewport Navigation Spec
---

# Viewport Navigation Spec

Behavior specification for viewport navigation, snap behavior, and focus reveal policy.

---

## Layout Notation

A compact notation for describing viewport state in use cases.

```text
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

```text
[*30 30 .40].20 50
```
Four columns of width 30, 30, 60, 50. Viewport shows col1 (full), col2 (full), col3 ([clipped](glossary.md#clipped-column): 40 visible, 20 outside right). Col4 fully outside right (may be [parked](glossary.md#parked-window)). Col1 is focused.

```text
20 30 .30[.20 *40 40] 55
```
Six columns. Col1 (20) and col2 (30) fully outside left ([parked](glossary.md#parked-window)). Col3 (50) clipped at left edge: 30 outside left, 20 visible. Col4 (40) focused and fully visible. Col5 (40) fully visible. Col6 (55) fully outside right (parked).

```text
30 .10[.20 *60 .20].30
```
Four columns: 30, 30, 60, 50. Col1 fully outside left (parked). Col2 clipped left: 10 outside, 20 visible. Col3 (60) focused and fully visible. Col4 clipped right: 20 visible, 30 outside right.

### Effective snap point annotation

Use `|` to annotate the **currently effective** [snap point](glossary.md#snap-point) — the position the viewport is snapped to or targeting:

```text
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

## Settings

| Setting | Type | Default | Behavior |
|---|---|---|---|
| Reveal Style | `.auto` / `.closest` / `.center` | `.auto` | Controls where automatic reveals place clipped or parked targets. It never decides whether a reveal happens. |
| Manual Override Modifier | Key binding | User setting | Hold during a scroll gesture to bypass snap for that gesture. |
| Lone Window | `Fill` / `Centered(width)` with per-monitor `Use Global` / `Fill` / `Centered(width)` | `Fill` | Controls the default viewport geometry for a one-window workspace. |

---

## Proportional Size and Gap Accounting

Percentage column sizes are resolved with Niri-compatible gap accounting in a single rule:

```text
resolvedColumnWidth = (viewportWidth - gap) * proportion - gap
```

Consequences:

- A contiguous group whose proportions sum to `1.0` spans approximately `viewportWidth - 2 * gap` after its internal gaps are included.
- `50% + 50%` is therefore considered a viewport-fitting group without users compensating for gaps.
- `25% + 35% + 40%` follows the same rule and is also considered a viewport-fitting group.
- Users should not adjust percentages to account for gaps; gaps are part of the layout model.

Reveal Style `.auto` uses this same rule indirectly: a closest snap is treated as viewport-fitting only when the candidate viewport contains a contiguous group of fully visible columns whose combined span is within `2 * gap` of the viewport width. This rejects oversized combinations such as `65% + 50%` while accepting intended `100%` groups.

Implementation contract: route proportional pixel conversion through `ProportionalSize.resolveProportionalSpan(...)`; do not duplicate the formula at call sites. Do not change this primary-axis formula to adjust secondary-axis edge padding; stacked/tiled secondary-axis spacing is owned by `NiriAxisSolver` and related layout helpers, where inner gaps mean only gaps between adjacent tiles.

## Gap Semantics

Nehir has two distinct gap concepts:

- **Inner gap** — spacing between adjacent layout items. On the secondary axis for stacked/tiled windows, this means `count - 1` gaps and no implicit top/bottom edge padding.
- **Outer gap** — monitor-edge padding around the working area, represented by `LayoutGaps.OuterGaps`.

Monitor-specific gap values are resolved centrally by `SettingsStore.resolvedGapSettings(for:)` and exposed to runtime code by `WMController.gapSize(for:)` and `WMController.outerGaps(for:)`. Viewport/layout callers should use those monitor-aware helpers when a monitor is known, rather than reading global fallback gap values directly.

## Snap Grid

Snap points are computed per column. The viewport always snaps to the nearest snap point on gesture release (unless the Manual Override modifier is held).

### Snap point rules

For each column:
- **Left-edge snap** — viewport left aligns to show the column's left edge
- **Right-edge snap** — viewport right aligns to show the column's right edge
- **Center snap** — column is centered in the viewport. Only added when `column.effectiveViewportWidth > 0.30 * viewportWidth`

Columns narrower than 30% of the viewport only get edge snaps. This keeps the snap grid sparse for multi-column layouts with small panels.

Columns whose effective width approximately fills the viewport (within pixel tolerance) do **not** get the synthetic `columnX - gap` / `columnX + width + gap - viewportWidth` edge snaps. For a full-width column those points are meaningless `±gap` shifts: they reveal no neighboring column and lose working-area margins. Over-wide columns (wider than the viewport) keep their edge snaps so clipped content can be reached. The column can still have a center snap and the snap grid still includes far overscroll boundary points.

For a lone-window workspace, effective viewport width is the transient lone-window render width (`loneWindowLayoutWidthOverride`) when present, not the canonical column `cachedWidth`. This lets fill/centered lone windows scroll and snap against the real rendered span while preserving the canonical width used when a second column appears.

A single tiled column uses the same far overscroll boundary points as a multi-column strip. A trackpad gesture can therefore settle at a far boundary when the projected release position is closer to that boundary than to the center/resting snap, leaving only the configured edge sliver of the lone column visible.

### Gesture release

On gesture release, the viewport snaps to the nearest snap point. The focused column updates to the column at the target snap position.

Hold the **Manual Override** modifier during a gesture to bypass snapping — the viewport settles at the decelerated natural position.

Implementation contract: `computeSnapGrid(...)`, `viewportStartBounds(...)`, and `ViewportSnapContext` in `ViewportState+Geometry.swift` are the source of truth for snap points and bounds. Gesture release, viewport scroll commands, Reveal Style, resize adjustment, column transitions, and lone-window scroll/snap handling must consume this shared geometry instead of constructing local snap/edge formulas.

---

## Lone-Window Viewport Behavior

A lone window is a normal, non-tabbed workspace with exactly one column and one window. Its default rect is controlled by `LoneWindowPolicy`:

- **fill** — fill the working area
- **centered** — cap width to the policy's max working-area fraction and center it

Per-monitor overrides are tri-state through `MonitorNiriSettings.loneWindowPolicy`:

- `nil` — inherit global policy
- `.fill` — explicit Fill on that monitor
- `.centered(maxWidthFraction:)` — explicit Centered on that monitor

`SingleWindowViewportGeometry` is the source of truth for the resolved lone-window rect, center offset, and render offset. `NiriContainer.effectiveViewportWidth` is the source of truth for viewport positions, bounds, and snap width when that rect is wider or narrower than the canonical column width. Controllers and gesture handlers should call `singleWindowViewportGeometry(...)`, `resolvedSingleWindowViewportRect(...)`, `prepareSingleWindowViewport(...)`, or `prepareAndSeedSingleWindowViewport(...)` rather than re-deriving the math.

Lone-window rendering follows the raw viewport offset so scroll gestures are visible. The snap grid decides where the viewport settles. This keeps fill windows responsive during a gesture while preserving the same far-overscroll affordance available in multi-column layouts. `cachedWidth` remains the canonical column width for later multi-column layout; the fill/centered render span is transient and must not leak back into canonical width state.

### Single-window snap bounds

A single tiled window is the selected column and participates in far overscroll. `viewportStartBounds(...)` applies the same edge-visible-fraction rule used for the first and last columns of a multi-column strip. Gesture release chooses the closest projected snap, with far-boundary snaps available even when there is only one column.

---

## Reveal on Focus

"Reveal" means an automatic viewport scroll that brings a focused column into view. Reveal has fixed whether-rules and one style setting for placement.

| Condition | Automatic scroll? |
|---|---|
| Focus follows mouse (FFM) focus change | Never |
| Target already fully visible | Never |
| Viewport Scroll Lock enabled on the workspace and the trigger is background/automatic | Never |
| Explicit user navigation with a clipped or parked target | Yes, using Reveal Style |
| Any other non-FFM trigger with a clipped or parked target | Yes, using Reveal Style |

The same rules apply to keyboard commands, click activation, external raises, and layout commands that keep the selection visible.

### Reveal Style

`revealStyle: .auto | .closest | .center`

Applies uniformly to [clipped](glossary.md#clipped-column) and [parked](glossary.md#parked-window) targets after the whether-rules allow a reveal:

- **`.auto`** — use the closest target-column snap only when that candidate viewport contains a contiguous group of fully visible columns whose proportional span fits the viewport under Nehir's gap accounting; otherwise use `.center`. This treats groups such as `50% + 50%` and `25% + 35% + 40%` as fitting while rejecting oversized groups such as `65% + 50%`.
- **`.closest`** — scroll to the target column's snap point nearest to the current viewport position (minimal scroll).
- **`.center`** — scroll to the target column's center snap; falls back to `.closest` when no center snap exists.

If the target column is already at the selected target offset (within pixel tolerance), no scroll occurs.

### Viewport Scroll Lock

Viewport Scroll Lock is a per-workspace runtime toggle. When enabled, it suppresses background automatic reveals only. Explicit user navigation (workspace-bar window clicks and focus commands) and explicit viewport manipulation — `scrollViewport(.left/.right)`, trackpad scroll gestures, and interactive drags — keep working and do not unlock the workspace.

---

## Viewport Scroll Commands

`scrollViewport(.left)` and `scrollViewport(.right)` scroll the viewport through [snap points](glossary.md#snap-point) without immediately changing focus.

Default bindings: `Cmd+Option+[` (left) and `Cmd+Option+]` (right).

The [active column](glossary.md#active-column) does not change while it remains visible. When a scroll step causes the active column to become [parked](glossary.md#parked-window) (`ContainerVisibilityState.hidden(edge)`), focus transfers to the **nearest visible column** — no threshold, the existing binary parked state determines this.

---

## Use Cases

### Focus change: target fully visible

```text
[|*30 30 40] 50
```
Any fully visible column is focused. Viewport is at rest at a snap position.

| Source | Result (focus col2) | Result (focus col3) |
|---|---|---|
| Any | `[\|30 *30 40] 50` | `[\|30 30 *40] 50` |

Target is fully visible — no reveal triggered. Snap point is not re-evaluated; viewport remains at rest.

### Focus change: target clipped (right side), non-FFM

```text
[|*30 30 .40].20 50    col3 is 60 wide, 40 visible
```
User focuses col3 with keyboard or click.

`revealStyle = .auto` chooses the same closest snap here because the resulting viewport is filled:
```text
.20[.10 30 *60|] 50
```

`revealStyle = .closest`:
```text
.20[.10 30 *60|] 50
```
Minimal scroll: col3's right-edge aligns with viewport right.

`revealStyle = .center`:
```text
30 .10[.20 *|30.30| .20].30
```
Viewport scrolls to center col3. Left of `.`: 20+30=50 ✓; right of `.`: 30+20=50 ✓.

### Focus change: target clipped (right side), FFM

```text
[|*30 30 .40].20 50
```
Cursor moves over col3 (the visible portion). FFM activates col3.

```text
[|30 30 *.40].20 50
```
Focus transfers to col3, viewport does not scroll.

### Focus change: target parked

```text
[|*30 30 .40].20 50    col4 (50) is parked right
```
User navigates to col4 with any non-FFM source.

The target is parked, so the viewport reveals it using the configured Reveal Style. With `.closest`, col4's nearest edge snap is selected:

```text
30 30 .10[.50 *50|]
```
Col3 (60 wide) clipped left: 10 outside, 50 visible. Col4 (50) fully visible at right-edge snap.

### Viewport scroll command: `scrollViewport(.right)`

```text
[|*30 30 .40].10 45
```
User presses `scrollViewport(.right)`. Next snap: col2 left-edge. Col1 scrolls fully outside — immediately [parked](glossary.md#parked-window) — focus transfers to col2.

```text
30 [|*30 50 .20].25
```
Press again. Next snap: col3 center. Col2 slightly [clipped](glossary.md#clipped-column) but not [parked](glossary.md#parked-window) — focus stays on col2.

```text
30 *.5[.25 |25.25| .25].20
```
Press again. Col2 fully outside — [parked](glossary.md#parked-window) — focus transfers to nearest visible column.

```text
30 30 [|*50 .20].15
```
