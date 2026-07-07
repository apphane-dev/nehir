# Tab indicators: consume gap space first, shrink window only as fallback — Discovery

Groom 2026-07-07: still applicable — deferred proposal (verdict: sound idea but the per-column position/scroll-dependent footprint change's maintenance burden outweighs the situational ≤12pt gain); not pursued, no `planned/` doc (verified against main 7a025b78).

Proposal under review (paraphrased): when placing a tabbed-column indicator
rail, first try to source its horizontal footprint from the adjacent gap (the
inter-column gap, or the outer gap when the column is flush to the screen
edge); only fall back to shrinking the window when the available gap is
insufficient.

All file/line references were verified against the main Nehir source tree on
2026-06-27. Re-verify before implementing; line numbers drift.

---

## TL;DR

- **The rail already does *not* paint over content.** The layout engine
  reserves a flat `tabIndicatorWidth = 12pt` strip on the left of every tabbed
  column and insets window content past it, so the rail draws in *reserved*
  space. There is no "rail covering the window" bug to fix. The proposal's real
  effect is to **reclaim up to 12pt of window content width** by sourcing that
  strip from the neighboring gap instead of from the column.
- **The benefit is real but small and situational.** With defaults
  (`gapSize = 16`, `outerGapLeft = 0`) the inner gap can hold the 12pt rail, so
  non-leftmost columns could reclaim the full 12pt. But any column scrolled to
  the left edge of the working area has only the outer gap (`0` by default) to
  its left, so the common leftmost-visible case falls straight to the
  shrink-window path and gains nothing.
- **The cost is a structural coupling change.** Today the rail's footprint is a
  single shared constant (`RenderStyle.tabIndicatorWidth`) applied uniformly by
  the layout engine; the overlay renderer independently places the rail in that
  strip. The proposal makes the footprint **per-column and
  position/scroll/neighbor-dependent**, which fights the engine's otherwise
  stateless `columnWidth ↔ windowWidth` mapping and forces two systems to agree
  on a per-frame computation.
- **Verdict:** 🟡 **Sound idea, but the maintenance burden outweighs the
  situational gain.** Defer the dynamic version. If pursued at all, do it as a
  *static* per-column choice made when the column settles, never tracked live
  during scroll.

---

## How the rail's space is reserved today (source-backed)

The footprint is a flat constant, set once and consumed in five places.

**The constant** — `barThickness(10) + spacing(2) = 12`:

```swift
// Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:10-13
static let barThickness: CGFloat = 10
static let spacing: CGFloat = 2
static let totalWidth: CGFloat = barThickness + spacing   // 12
static let hitWidth: CGFloat = 20
...
// Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:294
static let tabIndicatorWidth: CGFloat = TabbedOverlayMetrics.totalWidth
```

**Wired into the engine as one flat value** (no gap awareness anywhere):

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1853
engine.renderStyle.tabIndicatorWidth = TabbedColumnOverlayManager.tabIndicatorWidth
```

**Reserved from the column's own width** — column = window + 12, window = column − 12:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:116-126
private func tabOffset(for column: NiriContainer) -> CGFloat {
    column.isEffectivelyTabbed ? renderStyle.tabIndicatorWidth : 0
}
private func columnWidth(forWindowWidth windowWidth: CGFloat, in column: NiriContainer) -> CGFloat {
    windowWidth + tabOffset(for: column)
}
private func windowWidth(forColumnWidth columnWidth: CGFloat, in column: NiriContainer) -> CGFloat {
    max(0, columnWidth - tabOffset(for: column))
}
```

**Content is inset past the reserved strip** — so the rail never overlaps content:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:975-984
let tabOffset = isEffectivelyTabbed ? renderStyle.tabIndicatorWidth : 0
let contentRect = CGRect(
    x: canonicalContainerRect.origin.x + tabOffset,                 // content starts 12pt in
    y: canonicalContainerRect.origin.y,
    width: max(0, canonicalContainerRect.width - tabOffset),         // content is 12pt narrower
    height: canonicalContainerRect.height
)
```

The same constant also drives the animation fallback
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Animation.swift:343`) and the
tiles origin (`…+Animation.swift:466-469`, `xOffset = tabIndicatorWidth`), and
is declared on `RenderStyle` (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:129`).

**The renderer then places the rail in that strip, reading only the visible
frame** — it must land exactly where the engine reserved space:

```swift
// Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:557-565  (overlayFrame)
let width = max(TabbedOverlayMetrics.hitWidth, TabbedOverlayMetrics.totalWidth)   // 20
let x = visibleColumnFrame.minX - (width - TabbedOverlayMetrics.totalWidth)        // minX - 8
// visual bar then sits at [minX, minX+10]; gutter [minX+10, minX+12]; content starts at minX+12 → no overlap
```

The collector that feeds the renderer already has `column.frame` and
`monitor.visibleFrame` but **not** neighbor frames or resolved gaps
(`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1094-1130`,
`tabbedColumnOverlayInfos`).

**Key takeaway:** the engine and the renderer communicate the rail's footprint
through *one constant*. That is the contract the proposal would replace with a
per-column, per-frame value.

---

## Where the "gap" would come from, and the arithmetic

Gap model (defaults inline):

```swift
// Sources/Nehir/Core/Config/SettingsExport.swift:123-129  (SettingsExport.defaults)
gapSize: 16,
outerGapLeft: 0, outerGapRight: 0, outerGapTop: 0, outerGapBottom: 0,
```

```swift
// Sources/Nehir/Core/Layout/Niri/InteractiveResize.swift:111-141  (LayoutGaps)
init(horizontal: CGFloat = 8.0, vertical: CGFloat = 8.0, outer: OuterGaps = .zero)
```

```swift
// Sources/Nehir/Core/Config/SettingsStore.swift:908-916  (resolved, clamped 0...64)
gapSize: (override?.gapSize ?? gapSize).clamped(to: 0 ... 64)
```

Column X positions put exactly `gaps` between neighbors:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:358-362
func columnX(at index: Int, columns: [NiriContainer], gaps: CGFloat) -> CGFloat {
    var x: CGFloat = 0
    for i in 0 ..< index where i < columns.count { x += columns[i].cachedWidth + gaps }
    return x
}
```

So for a tabbed column the "available gap to the left" is:

| Topology of the column | Gap to its left (defaults) | vs. rail 12pt | Outcome of proposal |
|---|---|---|---|
| Has a neighbor to the left | inner `gapSize = 16` | 16 ≥ 12 | **reclaims full 12pt** of content |
| Leftmost / scrolled to the working-area left edge | `outerGapLeft = 0` | 0 < 12 | **falls back to shrinking** — no gain |
| Outer gap configured, e.g. `outerGapLeft ≥ 12` | that outer gap | may suffice | reclaims, but eats the user's outer margin |

In other words the optimization engages for *interior* columns and silently
no-ops for the column that is flush to the left edge — which is frequently the
focused/visible one. The gain is "up to 12pt of window width, sometimes."

---

## Challenges — issues and maintenance burden

These are the reasons to push back. They are not nitpicks; the first two are
architectural.

### 1. The rail footprint is a global constant precisely so the width math is stateless

`columnWidth(forWindowWidth:)` and `windowWidth(forColumnWidth:)`
(`NiriLayoutEngine+Sizing.swift:120-126`) assume a **stable, position-independent**
mapping between a stored column width and the window width. Width presets,
interactive resize, width-preservation across moves, and the "column width"
command all depend on it (the existing
`discovery/20260621-window-width-vs-column-width-semantics.md` already flags the
`tabOffset` term as a correctness wart at lines 314-343).

Making `tabOffset` depend on the available left gap means **the same stored
`columnWidth` resolves to different `windowWidth` values as the user scrolls**,
because the left gap changes when a neighbor scrolls off or the column reaches
the edge. That turns a pure function into stateful geometry and invalidates the
mapping every width-related feature leans on. This is the single biggest cost.

### 2. Two systems must now agree on a per-column, per-frame computation

Today the engine reserves 12pt; the renderer reads the visible frame and lands
in the reserved strip — they share only the constant. If the inset becomes
gap-dependent, the renderer's `overlayFrame`
(`TabbedColumnOverlay.swift:557`) must compute the *exact same* available-left-gap
as the engine's inset path, including neighbor topology, scroll offset, and
per-monitor outer gaps. Any drift → the rail either floats in the gap
misaligned or overlaps content it was supposed to avoid. The collector
(`NiriLayoutHandler.swift:1094-1130`) would have to be given neighbor frames and
resolved gaps it does not currently carry.

### 3. Reflow/jitter during horizontal scroll

As a column is scrolled, its left gap transitions from "inner gap (16)" to
"outer gap (0) / off-screen." If the inset tracks the available gap, the window
content width changes *during the gesture* — visible grow/shrink mid-scroll,
which reads as a regression. Mitigating it (e.g. pin the inset during
animation, or to the settled topology) largely negates the proposal's benefit
and adds animation-specific state.

### 4. The leftmost-visible column — a common case — gains nothing

With default `outerGapLeft = 0`, any column at the working-area left edge has
zero gap to its left and must shrink the window regardless. So the proposal
silently does nothing for the case users are most likely looking at, while
changing behavior for interior columns. That is a hard-to-explain
inconsistency (the rail "reclaims space" on some columns and not others,
seemingly at random as you scroll).

### 5. Edge cases in the shared inter-column gap

- For a 16pt gap and a 20pt **hit** width, the hit area of column B's rail
  reaches `B.minX − 20 = A.maxX − 4`, i.e. 4pt into neighbor A's content — a
  click-zone collision when both are tabbed.
- Drawing in an outer gap consumes the user's configured margin, which is
  surprising; if `outerGapLeft < 12` the rail still overflows off-screen and
  must fall back anyway.
- The `hitWidth(20) − totalWidth(12) = 8pt` of hit area already extends left
  into the gap today (`overlayFrame`, `x = minX − 8`), so *clickability* is
  already gap-aware; the proposal only moves the *visual* bar leftward.

### 6. Interaction with adjacent features

Smart gaps (single window — `discovery/20260617-omniwm-373-smart-gaps-single-window.md`),
fullscreen, lone-window-max-width, and column width bounds all flow through the
same `windowWidth(forColumnWidth:)` pipe. A variable inset is one more term
each of those paths must reason about, and each is a place a regression can
hide.

### 7. Test surface

The flat-12 assumption is pinned directly
(`Tests/NehirTests/OwnedWindowRegistryTests.swift:175`,
`#expect(TabbedColumnOverlayManager.tabIndicatorWidth == 12)`) and indirectly
through the visible-frame contract
(`Tests/NehirTests/NiriLayoutEngineTests.swift:3594`,
`visibleColumnFrame == renderedFrame.intersection(...)`). A gap-dependent inset
requires new per-topology cases across both the overlay tests and the engine
width tests.

---

## Recommendation

**Do not pursue the dynamic (scroll/neighbor-tracked) version.** Its gain is
"≤12pt of content width, only for interior columns, only with gap ≥ 12" and its
cost is turning a stateless width mapping into stateful geometry plus a
renderer/engine coupling that did not exist before. The cost dominates.

If the density reclaim is genuinely wanted, the only shape worth considering is
a **static, per-column inset chosen once when the column settles** (e.g. at
insert/resolve time), stored on the column, and used everywhere the constant is
today — so the `columnWidth ↔ windowWidth` mapping stays a pure function of
stored state and the renderer reads the same stored value. Even that variant:

- still no-ops for leftmost-visible columns (outer gap 0),
- still needs jitter handling when a column's *settled* topology changes
  (neighbor inserted/removed/reordered),
- still adds a per-column field and a new code path through every width call
  site listed above,

so it is a real feature with real cost, not a tidy fix. Treat it as such: scope
it, write the topology tests first, and decide explicitly whether ~12pt of
content width on interior tabbed columns is worth it. My read: **defer** until
someone asks for the density by name.
