# OmniWM issue #326 — "Allow Niri layout column to be more than 100%" — Discovery

Groom 2026-07-07: in flight — a plan exists (planned/20260621-omniwm-326-niri-column-over-100-percent-width.md); column width is still hard-capped at 100% (verified against main 7a025b78).

Source issue: <https://github.com/BarutSRB/OmniWM/issues/326>
Scope of this doc: determine whether nehir already allows a Niri column to be
wider than 100% of the working area (overflow, revealed by horizontal scroll),
and if not, scope the action nehir would own to implement it.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

---

## TL;DR

- **nehir hard-caps column width at 100%.** Every user-reachable width input is
  clamped to ≤1.0 — `validatedPresets` (`min(1.0, max(0.05, _))`),
  `validatedDefaultColumnWidth` (≤1.0), and `isFullWidth` resolves to
  `proportion(1.0)`. There is no way to set a column wider than the working area.
- **But the engine does not forbid it:** `resolveProportionalSpan` and
  `resolveSpan` only clamp to window min/max-size constraints, not to ≤1.0 — so a
  proportion >1 would render if it could be set. The blocker is purely the
  validation/UI cap.
- **Verdict:** 🔴 **Open — owns a new action.** Raise the width clamps above 1.0
  (e.g. allow presets up to a configurable max), and ensure the existing
  horizontal overflow-scroll viewport reveals a single column that is wider than
  the working area.

## Issue context

- **State:** open (feature request, triaged Med).
- **Request (verbatim):** "Allow Niri layout column to be more than 100%. … It
  can be really useful for apps that has own vertical splits or to test wider
  responsive layout."
- **Use case:** an app with its own internal vertical splits, or responsive-width
  testing, wants a tiled column wider than the screen, with horizontal scroll to
  reveal the overflow (niri-style).

## Provenance: is this nehir's code?

Yes. Column sizing, presets, and validation all exist:

- `NiriNode.resolveSpan(spec:isFull:availableSpace:gaps:minConstraint:maxConstraint:)`
  (`Sources/Nehir/Core/Layout/Niri/NiriNode.swift:526`) — resolves a
  `.proportion(p)` or `.fixed(f)`; clamps only to window min/max constraints.
- `ProportionalSize.resolveProportionalSpan(_:availableSpace:gaps:)`
  (`NiriNode.swift:42`) — `(availableSpace - gaps) * proportion - gaps`; **no**
  ≤1.0 clamp in the math.
- `isFullWidth` → `ProportionalSize.proportion(1.0)` (the 100% maximum) at
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:66` and `:494`.
- Preset validation: `SettingsStore.validatedPresets(_:)`
  (`Sources/Nehir/Core/Config/SettingsStore.swift:852`),
  `validatedDefaultColumnWidth(_:)` (`:862`),
  `validatedLoneWindowMaxWidth(_:)` (`:866`).
- Preset storage/cycling: `niriColumnWidthPresets`
  (`SettingsStore.swift:44`/`:478`), `presetWidthIdx`
  (`NiriLayoutEngine+Sizing.swift:446`), and the UI in
  `Sources/Nehir/UI/SettingsView.swift:357`/`:426`.
- Overflow-scroll viewport: nehir already scrolls the viewport horizontally to
  reveal columns beyond the working frame (multi-column overflow) — the same
  mechanism would reveal a single >100% column.

## The code in question

**The hard cap (the blocker) — every preset is clamped to ≤1.0:**

```swift
// Sources/Nehir/Core/Config/SettingsStore.swift:852
static func validatedPresets(_ presets: [Double]) -> [Double] {
    let result = presets.map { min(1.0, max(0.05, $0)) }   // ← ≤ 100%
    if result.count < 2 { return defaultColumnWidthPresets }
    return result
}

// Sources/Nehir/Core/Config/SettingsStore.swift:862
static func validatedDefaultColumnWidth(_ width: Double?) -> Double? {
    guard let width else { return nil }
    return min(1.0, max(0.05, width))                      // ← ≤ 100%
}
```

**"Full width" is defined as exactly 100%:**

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:66 / :494
let currentSpec = column.isFullWidth ? ProportionalSize.proportion(1) : column.width
```

**The engine itself does NOT clamp the proportion to ≤1 — only to window
min/max constraints:**

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:526  (resolveSpan)
let effectiveSpec = isFull ? ProportionalSize.proportion(1.0) : spec
switch effectiveSpec {
case let .proportion(p):
    result = ProportionalSize.resolveProportionalSpan(p, availableSpace: availableSpace, gaps: gaps)
case let .fixed(f):
    result = f
}
let effectiveMaxConstraint = maxConstraint.map { max($0, minConstraint) }
if result < minConstraint { result = minConstraint }
if let effectiveMaxConstraint, result > effectiveMaxConstraint { result = effectiveMaxConstraint }   // window max-size only
return result

// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:42  (resolveProportionalSpan)
(availableSpace - gaps) * proportion - gaps   // no ≤1.0 clamp
```

## Why this is Open (and the action is well-scoped)

1. **The feature is genuinely absent at the validation layer.** Every path that
   sets a column width — presets, default width, full-width toggle — is capped at
   1.0 (`SettingsStore.swift:852`/`:862`; `isFullWidth` → `proportion(1)`). A user
   cannot make any column wider than the working area today.

2. **The rendering engine is already capable.** `resolveProportionalSpan` and
   `resolveSpan` do not forbid `p > 1`; they only clamp to the windows'
   declared min/max-size constraints (`NiriNode.swift:541`/`:543`). So a
   proportion of, say, 1.5 would compute a column 1.5× the working width minus
   gaps — the work is in *allowing* it to be set and *scrolling* to reveal it,
   not in teaching the layout to render it.

3. **The reveal mechanism already exists.** nehir's viewport already scrolls
   horizontally to reveal columns that overflow the working frame (multi-column
   overflow). A single column wider than the viewport should reuse that same
   overflow-scroll path; the main correctness check is that the
   `singleWindowLayoutContext` / `loneWindowPolicy` path (which today caps width
   at `maxWidthFraction` ≤1.0, `NiriLayoutEngine.swift:259`) and the
   fills-viewport tolerance do not clamp or re-center a deliberately-overwidth
   single column.

## Recommendation

**Implement ">100% column width" as a new, owned action.** Suggested shape:

- **Raise the validation ceiling.** Introduce a configurable maximum proportion
  (e.g. a `maxColumnWidthProportion` setting, default 1.0 for backward
  compatibility, allowed up to some sane bound like 3.0) and relax
  `validatedPresets`/`validatedDefaultColumnWidth` (`SettingsStore.swift:852`/
  `:862`) to clamp to that maximum instead of the hard-coded `1.0`. Keep the 0.05
  lower bound.
- **Allow >1.0 presets in the UI** (`SettingsView.swift:357`/`:426`) and through
  `cycleColumnWidth` / `toggleColumnFullWidth`. "Full width" can stay at 1.0; the
  new >1.0 presets are an additional range the user opts into.
- **Verify the overflow reveal for a single overwidth column.** Confirm the
  horizontal viewport scroll exposes the rightward overflow when one column
  exceeds the working width, and that `singleWindowLayoutContext`
  (`NiriLayoutEngine.swift:258`) and the fills-viewport tolerance
  (`resolveProportionalSpan` 2×gap slack comment, `NiriNode.swift:43-50`) do not
  snap an overwidth lone column back to 100%. The `hasManualSingleWindowWidthOverride`
  flag (`NiriLayoutEngine+Sizing.swift:655`/`:661`) is the existing escape hatch
  for "user deliberately set this width" and should gate the override.
- **Window max-size constraints still apply** (`NiriNode.swift:543`): an app that
  declares a `maxSize.width` smaller than the requested width will still clamp —
  document this as expected (it matches the use case: apps with their own splits
  generally do not over-constrain max width).

## Suggested tests

- Set a preset of 1.5 (after raising the cap): assert a single-column workspace
  resolves the column to `(workingArea - gaps) * 1.5 - gaps` pixels (wider than
  the working frame), and that scrolling the viewport right reveals the overflow.
- Two columns, one at 1.0 and one at 0.5: assert today's behavior is unchanged
  (regression guard — the cap change must not alter ≤1.0 layouts).
- `validatedPresets([0.3, 1.0, 1.5, 3.0, 5.0])` with a max of 3.0: assert it
  yields `[0.3, 1.0, 1.5, 3.0, 3.0]` (clamped to the new ceiling, lower bound
  preserved).
- An app declaring `maxSize.width < workingArea*1.5`: assert the overwidth
  request clamps to that app's max (existing constraint behavior respected).
