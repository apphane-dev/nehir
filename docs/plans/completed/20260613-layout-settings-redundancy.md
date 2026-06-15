# Layout Settings: Redundancy & Maintainability

Exploration (2026-06-13) of the layout-settings surface. Started as a
redundancy/maintainability audit of *plumbing*; pivoted to a deeper conceptual
collision in the column-width model that was causing genuine comprehension
failure. Both threads are captured here — the plumbing duplication and the
semantic redesign — because the duplication exists *because* there is no single
model of a layout dimension.

All file references should be re-verified before implementing; line numbers drift.

---

## Part 1 — The Plumbing Tax (one knob, ~10 touchpoints)

### Observation

Adding a single layout setting today means editing roughly ten locations. Traced
end-to-end for `maxVisibleColumns`:

1. `SettingsStore` `var` + `didSet { scheduleSave() }`
   — `Sources/Nehir/Core/Config/SettingsStore.swift`
2. `SettingsExport` field
3. `BuiltInSettingsDefaults` / `SettingsExport.defaults()`
4. `CanonicalTOMLConfig.Niri` struct
   — `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
5. `CanonicalTOMLConfig.init(export:)` map
6. `CanonicalTOMLConfig.toSettingsExport()` map
7. Per-field hand-edit-tolerant `init(from decoder:)`
8. `SettingsStore.toExport()`
9. `SettingsStore.applyExport(_:monitors:)`
10. UI tab — `Sources/Nehir/UI/LayoutSettingsTab.swift` (+ per-monitor section)

No single place declares the set of layout dimensions or which of them are
overridable. The layout dimension set is implicit, scattered across these files.

### Inconsistency: "what is a layout setting" is ad hoc

- **Gaps** (`size` + outer L/R/T/B): global-only, **not** per-monitor-overridable.
- **Niri knobs are split three ways:**
  - `maxVisibleColumns` + `singleWindowAspectRatio` → per-monitor-overridable
    (via `MonitorNiriSettings`, resolved into `ResolvedNiriSettings`).
  - `infiniteLoop` → sits *inside* `ResolvedNiriSettings` but is **not**
    overridable (always sourced from the global setting).
  - `revealPartial`, `columnWidthPresets`, `defaultColumnWidth` → global-only,
    not present in `MonitorNiriSettings` at all.

So the override surface is irregular and the "resolved settings" struct contains
fields that can't actually be overridden — a leaky abstraction.

### Scope fork (plumbing)

- **A — Internal plumbing only.** Collapse the ~10-touchpoint duplication so
  adding a layout knob is a 1–2 place edit. TOML shape, UI, override coverage
  identical. Pure refactor, zero user-visible change.
- **B — The semantic set.** Redefine which settings count as "layout" and make
  override coverage consistent (gaps overridable; `infiniteLoop` moved out of
  the resolved struct or made overridable).
- **C — Both.** Redesign the set (B) and dedupe the plumbing (A) together.

**Lean: C.** The duplication exists because there is no single model of a layout
dimension; fixing one without the other leaves the root cause. But this is the
biggest scope.

> ⚠️ **Pivot:** before committing to any plumbing refactor, the user flagged a
> more pressing problem — four column-related knobs that overlap conceptually
> and are hard to reason about. Part 2 supersedes Part 1 in priority.

---

## Part 2 — The Real Problem: Four Column-Width Knobs in Collision

User-reported symptom: *presets, default new-column width, visible columns, and
single-column width look very conflicting — mentally struggling to comprehend
consequences.*

### How column width actually resolves (precedence wins top-down)

Established by reading `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift`,
`NiriLayoutEngine+ColumnOps.swift`, `NiriLayoutEngine+Sizing.swift`,
`NiriLayout.swift`:

```
1. singleWindowAspectRatio   ← wins IF: exactly 1 column + 1 window + not tabbed + normal sizing
      (width is DERIVED from window height × ratio; ignores everything below)
      Sources/Nehir/Core/Layout/Niri/NiriLayout.swift: aspectFittedSingleWindowRect()

2. defaultColumnWidth        ← wins IF it's set (not "Auto")
      (explicit fraction, e.g. 0.5)
      NiriLayoutEngine.swift:144  var defaultColumnWidth: CGFloat? = 0.5
      NiriLayoutEngine.swift:191  resolvedColumnResetWidth()

3. 1 / maxVisibleColumns     ← the "Auto" fallback when #2 is nil
      NiriLayoutEngine.swift:197  return (1.0 / CGFloat(effectiveMaxVisibleColumns(...)), nil)

   ─── orthogonal to all three ───
4. columnWidthPresets        ← ONLY the palette for the "cycle width" hotkey
      defaultColumnWidth tries to snap onto the nearest preset so the cycle
      starts aligned, but it's a loose heuristic (within a tolerance), not a rule
      NiriLayoutEngine.swift:214  matchingPresetIndex()
```

### Three genuine conflicts (the source of the comprehension failure)

**1. `maxVisibleColumns` is mis-named and overloaded.**
It is *not* a capacity limit anywhere. Verified by grepping every read of
`effectiveMaxVisibleColumns` / `maxVisibleColumns` across the layout engine,
constraint solver, sizing, column ops, and viewport files: it is consumed in
exactly **two** spots, both as the "default width = 1/N" denominator:

- `NiriLayoutEngine+ColumnOps.swift:394` — animation heuristic for a moved column's width.
- `NiriLayoutEngine.swift:197` — the Auto fallback width.

You can freely have 5 visible columns with `maxVisibleColumns = 2`; nothing
enforces a cap. The presets default to 1/3 and 2/3 because three columns fit.
So the name promises a hard cap that doesn't exist, and it silently competes
with `defaultColumnWidth` to describe **the same quantity** (default new-column
width) in two vocabularies — with `defaultColumnWidth` shadowing it whenever set.

**2. Three independent models of "column width" with no declared precedence.**
Auto (`1/N`), explicit (`defaultColumnWidth`), and geometry-derived
(`singleWindowAspectRatio`). Nothing in the names or UI tells you which wins or
*when*. This is the core mental-model collision the user is feeling.

**3. Presets ↔ default width coupling is a loose heuristic.**
Set `defaultColumnWidth = 0.4` (not near any preset) and you get a 40% column
that isn't on the cycle palette, so the cycle starts in a surprising place.
`matchingPresetIndex()` snaps within a tolerance, not a guarantee.

### Scope fork (semantic)

- **Option A — Preserve expressiveness, make it honest (recommended).** Keep all
  four, but:
  - (a) Rename `maxVisibleColumns` to reflect that it is the auto-split / default
    width source — *or* remove its width job entirely and make `defaultColumnWidth`
    the single source (with `Auto` meaning `1/N` derived from a real capacity knob).
  - (b) Document the precedence visibly in the UI.
  - (c) Tighten preset↔default coupling so it's a guarantee, not a heuristic.
  No behavior lost, confusion removed.
- **Option B — Collapse.** Merge `maxVisibleColumns` and `defaultColumnWidth`
  into one "column width" concept (fraction, with an Auto meaning `1/N`). Fewer
  knobs, but lose the ability to set a real capacity cap independently of default
  width — if that independence ever mattered.

**Lean: A.** The four do different things (auto-split, explicit default,
single-window geometry, cycle palette); the pain is that their relationships are
implicit.

### Open question raised

*Is the single-window aspect ratio a feature you actually use, or dead weight?*
Answer determines whether A stays a 3-knob cleanup or drops to 2.

---

## Part 3 — Single-Window Aspect Ratio Deep Dive

User: *single window indeed worth special treatment, but the way it is done now
is really questionable. Originally introduced by the OmniWM author; reasoning
unknown, only that he mentioned wide-monitor cases.*

### What it does today

A runtime predicate — *exactly 1 column + 1 window + not tabbed + normal sizing*
(see `singleWindowLayoutContext()` in `NiriLayoutEngine.swift:235`) — flips the
whole layout into **aspect-fit mode**. Given the monitor's working frame and a
chosen ratio (e.g. 16:9 = 1.78), `aspectFittedSingleWindowRect()` fits the
largest centered rect with that ratio *inside* the frame:

- On a normal monitor (ratio < target): keeps full height, shrinks width.
- On a wide monitor (ratio > target): the lone window renders at a readable
  16:9, centered — **this is the wide-monitor case** the OmniWM author meant.

The moment a second column/window appears, the predicate fails and the constraint
silently vanishes.

### Why it's genuinely questionable

1. **Modeled as a *column-width setting*, but it's actually a *layout mode*.**
   It wins by fully bypassing the width machinery — proportions, presets, and
   default width are all ignored when the predicate holds. This is the root of
   the Part-2 collision: it's a different concept wearing a width setting's
   clothes.

2. **All-or-nothing vanishing act.** On a lone window you get a centered 16:9
   box; open one more app and the first window snaps to full-height/half-width
   with no rationale the user can see. The constraint exists or doesn't, with
   nothing in between.

3. **Aspect ratio is an *indirect proxy* for the actual intent.** "Wide monitors"
   → "don't let a lone window stretch across 3440px." An aspect ratio is one way
   to derive a width, but the real goal is **cap how wide a lone window gets**
   (and center it). A direct max-width / max-span expresses that intent honestly
   and generalizes: once a 2nd column arrives, normal splitting takes over
   naturally instead of a mode flip.

4. **Bonus hidden sub-mode.** A manual resize of the lone window flips
   `hasManualSingleWindowWidthOverride`, switching from aspect-fit to
   "full height + custom centered width" (see `resolvedSingleWindowRect()` in
   `NiriLayout.swift:634` and `centeredSingleWindowRect()`). So there are
   secretly **two** single-window behaviors, picked by a hidden flag with no UI.

### Scope fork (single-window treatment)

- **Option A — "Lone-window max width + centering" (recommended; matches the
  wide-monitor intent).** Drop the aspect-ratio enum. Express it directly: a
  lone window is capped to a max width (px or % of working area) and centered;
  when a 2nd column appears, normal column logic takes over seamlessly. One
  concept, no mode collision, generalizes to any monitor shape.
  Trade-off: lose precise "make this window exactly 4:3" shaping.

- **Option B — "Real lone-window aspect shaping," but modeled honestly.** Keep
  ratio-shaping, but:
  - (a) Lift it out of the width-setting namespace into its own explicit
    single-window layout mode.
  - (b) Decide and document what happens at 2 windows (2nd joins a shared area?
    aspect-mode just ends?).
  - (c) Kill the hidden manual-override sub-mode or promote it to a visible
    choice.

**Lean: A.** The OmniWM reasoning points at width-capping, and a max-width +
center policy removes the collision with the column-width model entirely rather
than patching it. Aspect shaping of a single window, if anyone ever wants it,
is better as a per-window property (Niri already has per-window sizing) than a
global layout knob.

### Files of record (single-window)

- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:235` —
  `singleWindowLayoutContext()` predicate
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:634` —
  `resolvedSingleWindowRect()` (mode switch)
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift` —
  `aspectFittedSingleWindowRect()`, `centeredSingleWindowRect()`
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:148`,
  `NiriLayoutEngine+Animation.swift:286`,
  `NiriLayoutEngine+Sizing.swift:103,453` — all consumers of the predicate
- `NiriNode.swift` — `hasManualSingleWindowWidthOverride` (hidden sub-mode flag)

---

## Decisions Pending

1. **Plumbing scope** — A (internal only), B (semantic set), or C (both). Lean: C.
2. **Column-width semantics** — A (honest, preserve expressiveness) or B (collapse). Lean: A.
3. **Single-window treatment** — A (lone-window max width + centering) or B (honest
   aspect shaping). Lean: A.

Decisions 2 and 3 are coupled: if single-window becomes "max width + centering"
(Part 3, Option A), it stops being a column-width concept entirely and the
Part 2 three-way collision collapses to a two-way one (Auto vs explicit default),
which makes Part 2 Option A cheaper. Recommended sequencing: decide Part 3
first, then Part 2, then Part 1 plumbing.

---

## Additional Opinion Pass

A second pass agrees with the core diagnosis, but would be more aggressive about
semantic cleanup and less eager to bundle that cleanup with the plumbing refactor.

The central issue is not duplication first; it is that the exposed concepts are
not honest. `maxVisibleColumns` is the clearest example. In the current engine it
is not a visible-column cap. It is only used as the denominator for the automatic
default width (`1 / N`) and as a fallback width in a column-move animation
heuristic. Because `niriDefaultColumnWidth` defaults to `0.5`, the "Visible
Columns" setting often has no effect unless the default width is set to Auto.
That makes the setting feel broken, not merely confusing.

This pass would not introduce a real capacity cap now. A hard cap on visible
columns sounds like a separate feature and may fight the scrolling/overflow
model. Instead, the current `maxVisibleColumns` concept should be reframed as
part of default-width selection:

```text
Default New Column Width
  Mode: Balanced / Custom

  if Balanced:
    Fit columns: 1...5       # width = 1 / N

  if Custom:
    Width: 5...100%
```

In other words, `maxVisibleColumns = 3` should mean "new columns default to
one-third width in Balanced mode," not "only three columns can be visible."
The UI should stop presenting it as an independent top-level "Visible Columns"
knob.

The recommended mental model is three honest concepts:

1. **Default new-column width.** One policy: either balanced for `N` columns or a
   custom percentage. Internally this eventually wants an explicit enum such as
   `.balanced(columns: Int)` / `.custom(fraction: CGFloat)`, while preserving old
   TOML keys for migration.
2. **Resize/cycle presets.** Keep these separate from default width. Presets are
   the command palette for resize actions, not the source of the initial column
   width. Either document the current nearest/next-preset behavior clearly or
   make the coupling explicit, but do not leave it as a hidden heuristic.
3. **Lone-window behavior.** Replace the aspect-ratio-flavored column-width knob
   with a direct lone-window policy, e.g. `Fill` vs `Centered with max width`.
   The apparent user intent is "on wide monitors, do not let one window become
   absurdly wide," which is a max-width policy, not an aspect-ratio policy.

Suggested UI shape:

```text
Column Defaults
  Default new-column width:
    - Balanced for N columns
    - Custom %

Resize Behavior
  Width cycle presets:
    - 33%
    - 50%
    - 67%
    ...

Lone Window
  - Fill
  - Centered, max width: X% or X px
```

This differs from the earlier "preserve all four knobs, make them honest" lean:
it preserves the useful capabilities, but collapses the user-facing mental model
to three concepts. `maxVisibleColumns` becomes an implementation/migration name
for balanced default width, and `singleWindowAspectRatio` becomes a legacy form
of a lone-window width policy.

Sequencing recommendation from this pass: do **semantic redesign first**, then
perform the plumbing dedupe once the new model stabilizes. A generic layout
settings abstraction created before the concepts are settled risks abstracting
the wrong thing. The plumbing tax is real, but the more urgent problem is that
the current UI exposes fake and overlapping concepts.
