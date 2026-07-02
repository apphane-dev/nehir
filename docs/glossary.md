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

## default column width

`DefaultColumnWidth` is the width assigned to a new or newly claimed column before manual resizing. It has two modes:

- **balanced** — fit `N` columns across the working area, so each column starts at `1/N` width
- **custom** — use an explicit working-area width fraction

Canonical column-width resolution (highest wins):

1. Manual/fixed/full-width column state
2. `DefaultColumnWidth.custom(fraction)`
3. `DefaultColumnWidth.balanced(columns)` → `1/N`

`LoneWindowPolicy.fill` / `.centered` does not replace canonical column width. It supplies a transient lone-window viewport/render width while the lone-window predicate holds.

---

## far overscroll boundary

A snap point at the scrollable start or end of the whole column strip, produced from `viewportStartBounds(...)`. It is not a per-column edge snap: it represents the farthest legal viewport position for the current layout, including the small overscroll/reveal allowance used by Niri-style scrolling.

See also: [snap grid](#snap-grid), [viewport offset](#viewport-offset).

---

## focused window

The macOS window currently receiving keyboard input, as reported by the Accessibility API. Nehir tracks this via `AXEventHandler`.

See also: [active column](#active-column).

---

## managed window

A window admitted into Nehir's tracked model. Managed windows have a `WindowModel.Entry`, appear in IPC window queries, and have a `TrackedWindowMode` of either `.tiling` or `.floating`.

Sticky, scratchpad, rule effects, hidden state, and focus metadata are overlays on top of managed windows; they are not extra tracked modes.

See also: [unmanaged window](#unmanaged-window), [sticky window](#sticky-window).

---

## inner gap

The spacing between adjacent tiled surfaces inside the layout. In stacked/tiled columns, inner gap applies only between neighboring tiles on the secondary axis (`count - 1` gaps). It is not monitor-edge padding.

Primary-axis proportional column widths intentionally keep Niri-compatible gap accounting through `ProportionalSize.resolveProportionalSpan(...)`; do not reinterpret that formula when changing secondary-axis gap behavior.

See also: [outer gap](#outer-gap), [proportional span](#proportional-span).

---

## focus follows mouse (FFM)

A mode where keyboard focus moves to whichever tiled window is under the cursor as the cursor moves. When FFM triggers a focus change, the viewport does **not** scroll — the cursor is already in the visible portion of the target column. FFM can only activate fully visible or [clipped](glossary.md#clipped-column) columns; [parked](glossary.md#parked-window) windows are offscreen and unreachable by the cursor. See [Reveal on Focus](viewport-navigation-spec.md#reveal-on-focus).

---

## lone-window policy

`LoneWindowPolicy` controls a normal, non-tabbed workspace with exactly one column and exactly one window.

- **fill** — make the lone window fill the working area
- **centered** — cap the lone window to a max working-area width fraction and keep it horizontally centered

The policy defines only the default lone-window render/viewport rect. It is transient: the column keeps its canonical width for later multi-column layout. After a manual resize, the window keeps the requested width (still centered) and is not capped by the policy max width.

Per-monitor lone-window overrides are tri-state through `MonitorNiriSettings.loneWindowPolicy`:

- `nil` — inherit the global policy
- `.fill` — explicitly use fill on that monitor
- `.centered(maxWidthFraction:)` — explicitly use centered on that monitor

Do not infer this override state from a nullable centered width; `SettingsStore.resolvedNiriSettings(for:)` is the source of truth.

See also: [single-window viewport geometry](#single-window-viewport-geometry).

---

## monitor gap settings

Per-monitor gap overrides stored as `MonitorGapSettings` and resolved to `ResolvedGapSettings`. `SettingsStore.resolvedGapSettings(for:)` merges global defaults with per-monitor overrides; runtime code should consume this through `WMController.gapSize(for:)` and `WMController.outerGaps(for:)` when a monitor is known.

---

## outer gap

Monitor-edge padding around the working area. Outer gaps are represented as `LayoutGaps.OuterGaps` and are applied when computing monitor working frames/insets.

Outer gap is distinct from [inner gap](#inner-gap): top/bottom edge padding must come from outer gaps, not from secondary-axis tile spacing.

---

## parked window

A window Nehir has moved to an offscreen or edge resting position because it should not currently be visible. Due to macOS WindowServer limitations, this is not a true hide for external app windows: Nehir can usually reduce the visible remnant to a tiny edge/corner strip, but the system may clamp the requested position.

For Niri viewport scrolling, represented internally as `ContainerVisibilityState.hidden(AxisHideEdge)` with a `layoutTransient` hidden reason. The edge (`.left` / `.right`) records which side the window is parked on. Workspace-inactive and scratchpad hiding use the same hidden-state model with different hidden reasons (`workspaceInactive`, `scratchpad`) and may use physical-edge parking rather than a viewport side.

In the [layout notation](viewport-navigation-spec.md#layout-notation), columns that are fully outside the viewport and have been parked appear as plain numbers outside `[]`, e.g. `30 [...]` — the `30` is a parked column on the left. A [clipped column](#clipped-column) (partially visible) is distinct and uses the split notation.

See also: [sticky window](#sticky-window), [single-window viewport geometry](#single-window-viewport-geometry).

---

## picture-in-picture default sticky

A built-in window-rule effect for PiP-like media surfaces. Nehir classifies common Picture-in-Picture windows from AX and WindowServer facts and marks them sticky by default so they remain visible across workspace switches.

This is an automatic sticky **source**, not a special PiP mode. The window is still tracked as either `.floating` or `.tiling`. Users can manually unstick it; the automatic source remains recorded so commands can target/toggle the same surface, but the effective sticky state becomes false until sticky is re-enabled.

PiP classification is conservative. Some PiP windows expose reliable AX facts only after the PiP receives focus or a click, so Nehir may begin tracking them after that first interaction. Browser PiP implementations that expose only parented popup-level WindowServer children or generic dialog surfaces may remain unmanaged/native-sticky because the same facts are also used by context menus and ordinary dialogs. Use explicit app rules for stable app-specific surfaces.

See also: [sticky window](#sticky-window), [managed window](#managed-window).

---

## proportional span

A proportional column/window span resolved by `ProportionalSize.resolveProportionalSpan(...)` using Niri-compatible gap accounting:

```text
resolvedSpan = (availableSpace - gap) * proportion - gap
```

This rule is intentionally centralized. Reveal Style `.auto` relies on the same `2 * gap` fit tolerance so groups such as 50% + 50% remain viewport-fitting.

---

## reveal

Automatic viewport scrolling to bring a newly focused column into view. Whether a reveal occurs is fixed:

- **FFM** — never reveals.
- **Fully visible target** — never reveals.
- **Viewport Scroll Lock enabled for a background/automatic trigger** — never reveals.
- **Explicit user navigation to a clipped or parked target** — reveals using `revealStyle` (`.auto`, `.closest`, `.center`).

See [Reveal on Focus](viewport-navigation-spec.md#reveal-on-focus).

---

## viewport scroll lock

A per-workspace runtime toggle that suppresses background automatic reveal scrolling. It does not block explicit user navigation such as workspace-bar window clicks and focus commands, and it does not block explicit viewport manipulation such as viewport scroll commands, trackpad gestures, or interactive drags.

See [Reveal on Focus](viewport-navigation-spec.md#viewport-scroll-lock).

---

## single-window viewport geometry

The centralized geometry model for a workspace containing exactly one normal non-tabbed window. `SingleWindowViewportGeometry` owns:

- the resolved lone-window viewport rect
- the center offset for initial/resting placement
- rendered-frame offsetting relative to the current viewport offset

Callers should use `singleWindowViewportGeometry(...)`, `resolvedSingleWindowViewportRect(...)`, `prepareSingleWindowViewport(...)`, or `prepareAndSeedSingleWindowViewport(...)` instead of re-deriving centered width, center offset, or frame offset rules in controllers. Viewport positions, bounds, and snap widths should use `NiriContainer.effectiveViewportWidth`, which selects the transient lone-window render width when present and falls back to canonical `cachedWidth` otherwise.

Lone-window rendering follows the raw viewport offset so gestures are visibly responsive. The shared [snap grid](#snap-grid), not a render-time clamp, decides where the window settles. A single tiled window still participates in the same far-overscroll boundary math as multi-column layouts, so a sufficiently strong swipe can settle at a boundary with only a sliver of the lone column visible. `cachedWidth` remains canonical; the lone-window render width must not leak into multi-column layout state.

---

## snap grid

The ordered set of [snap points](#snap-point) for the current column layout. Computed from column positions and effective viewport widths by `computeSnapGrid(...)` / `ViewportSnapContext`. The viewport targets the nearest snap point on gesture release.

Columns that approximately fill the viewport (within pixel tolerance) intentionally omit synthetic `±gap` edge snaps; those points would only shift a full-width column by one gap and lose working-area margins. Over-wide columns (wider than the viewport) keep their edge snaps so clipped leading/trailing content can still be reached. Center and [far overscroll boundary](#far-overscroll-boundary) snaps remain in both cases. Lone-window snap math uses the transient lone-window render width via `effectiveViewportWidth`, not raw canonical `cachedWidth`.

See [Snap Grid](viewport-navigation-spec.md#snap-grid).

---

## snap point

A viewport offset value the snap grid can target. For each column, up to three snap points exist:

- **left-edge snap** — column's left edge aligns with the viewport's left edge
- **right-edge snap** — column's right edge aligns with the viewport's right edge
- **center snap** — column is centered in the viewport (only for columns whose effective width exceeds 30% of the viewport width)

In the [layout notation](viewport-navigation-spec.md#effective-snap-point-annotation), the effective snap point is annotated with `|`: `[|N` (left-edge), `N|]` (right-edge), `|H.H|` (center — column split at its midpoint, both halves must be equal).

---

## sticky window

A managed window whose effective visibility spans workspaces on the same monitor. Sticky windows are projected separately in the workspace bar and are not hidden merely because their assigned workspace is inactive.

Sticky state is an effect/source overlay, not a third `TrackedWindowMode`. Sources include native global sticky detection, built-in Picture-in-Picture classification, app rules (`sticky = true`), and the manual sticky toggle. A manual unsticky override wins over automatic sources; such a window remains command-addressable as having a sticky source, but `isStickyWindow` is false until sticky is toggled back on.

See also: [picture-in-picture default sticky](#picture-in-picture-default-sticky), [managed window](#managed-window), [parked window](#parked-window).

---

## unmanaged window

A window Nehir deliberately does not track or lay out. Built-in rules ignore system UI and panels, and user app rules can request this with `manage = "ignore"`.

Unmanaged windows do not get a `WindowModel.Entry`, do not appear in managed-window IPC queries, and are not moved by layout refresh. Focus on unmanaged windows is represented as non-managed focus so Nehir does not accidentally mutate a stale managed command target.

See also: [managed window](#managed-window).

---

## viewport

The current scroll position of the viewport, stored as `ViewportState.viewOffsetPixels`. A `ViewOffset` enum with three states: `.static` (settled), `.gesture` (in motion), `.spring` (animating to target).

---

## viewport scroll command

`scrollViewport(.left)` / `scrollViewport(.right)` — commands that scroll the viewport to the previous or next [snap point](#snap-point) without immediately changing the [active column](#active-column). Focus transfers to the nearest visible column only when the active column becomes [parked](#parked-window).

Default bindings: `Cmd+Option+[` and `Cmd+Option+]`.

See [Viewport Scroll Commands](viewport-navigation-spec.md#viewport-scroll-commands).
