# Nehir #119 — Raise the 64 px screen-margin (outer-gap) ceiling

**Status:** planned (blocked on a product decision — see "Open decision")
**Source discovery:** `discovery/20260627-nehir-119-screen-margin-capped-at-64px.md`
**Upstream reference:** <https://github.com/apphane-dev/nehir/issues/119> ("[Question] More Margin")

All source references were verified against the main Nehir source tree at
`9ef0ae82` on 2026-06-27. Re-verify before editing; line numbers drift.

## TL;DR

Screen margins (outer gaps) are hard-capped at 64 px in two places — the eight
Settings sliders (`range: 0 ... 64` in `LayoutSettingsTab.swift`) **and** the
layout resolver (`SettingsStore.resolvedGapSettings(for:)` clamps to
`0 ... 64`). The layout reads margins only through that resolver, so editing
`[gaps.outer]` above 64 in `settings.toml` is stored verbatim but silently
collapsed to 64 before the working-area inset — which is exactly the workaround
failure the reporter hit.

Fix: introduce one named bound and apply it at both layers. No schema change,
no persistence change, no layout-math change — only the ceiling moves. The
literal `64` is currently a magic number with no constant.

## Open decision (blocks implementation)

**Pick the new maximum.** Guria asked the reporter for a reasonable value. The
reporter's use case (a custom dock that does not reserve edge space) implies a
dock-tall margin, plausibly ~80–120 px. Recommendations, in order of preference:

1. **`256`** — comfortably covers any realistic dock/menu-bar/overscan reserve,
   keeps a sane slider, and is well within `Double`/layout headroom. Default
   recommendation.
2. **`128`** — minimal bump that clearly fixes the reported case with less risk
   of users shrink­-to-nothing on small displays.
3. **Unbounded-ish (`1024` or similar)** — defer entirely to the user; only if
   we also add the minimum-working-area guard below.

Lower bound stays `0` (no negative margins requested).

## Changes

### 1. Named bound (new)

Add a single source of truth for the gap range, e.g. in the Config module
alongside `MonitorGapSettings` / `SettingsStore`:

```swift
enum GapLimits {
    /// Inclusive range enforced for inner and outer gaps, in points.
    static let range: ClosedRange<Double> = 0 ... 256
}
```

(Exact name/types to match house style — the point is one constant consumed by
both the resolver and the UI.)

### 2. Resolver — `Sources/Nehir/Core/Config/SettingsStore.swift:907`

`resolvedGapSettings(for:)` currently hard-codes `0 ... 64` on five lines
(`:910`–`:914`). Replace each literal with `GapLimits.range`:

```swift
gapSize:        (override?.gapSize        ?? gapSize       ).clamped(to: GapLimits.range),
outerGapLeft:   (override?.outerGapLeft   ?? outerGapLeft  ).clamped(to: GapLimits.range),
outerGapRight:  (override?.outerGapRight  ?? outerGapRight ).clamped(to: GapLimits.range),
outerGapTop:    (override?.outerGapTop    ?? outerGapTop   ).clamped(to: GapLimits.range),
outerGapBottom: (override?.outerGapBottom ?? outerGapBottom).clamped(to: GapLimits.range)
```

This is the authoritative fix: it is what makes TOML values > 64 take effect.

### 3. UI — `Sources/Nehir/UI/LayoutSettingsTab.swift`

Eight `range: 0 ... 64` literals must move to `GapLimits.range` (as a
`ClosedRange<Double>` for the `Double`-typed `SettingsSliderRow` /
`OverridableSlider`):

- Global "Screen Margins": Left `:118`, Right `:135`, Top `:152`, Bottom `:169`.
- "Monitor Screen Margins": Left `:258`, Right `:269`, Top `:280`, Bottom `:291`.

Changing only the resolver (step 2) without this step would re-create the
reporter's bug in the UI: the slider could not reach values the resolver now
allows.

### 4. (Optional, while-here) inner-gap alignment

The inner-gap slider is `range: 0 ... 32` (`LayoutSettingsTab.swift:96`) while
the resolver already allows `gapSize` up to `0 ... 64`
(`SettingsStore.swift:910`). Either align the slider to `GapLimits.range` or
leave as-is — but make it a conscious choice. Recommend aligning to the same
named range for consistency.

## Guard (conditional on the chosen max)

If the new maximum is large (≥ 256) or unbounded, verify the working area cannot
be shrunk below the Niri minimum column width. `WMController.insetWorkingFrame`
(`Sources/Nehir/Core/Controller/WMController.swift:939`) feeds the clamped gaps
as `Struts` into `computeWorkingArea(parentArea: monitor.visibleFrame, …)`.
Read the width-solver floors (around
`Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:636` and the
`resolveAndCacheWidth` callers) to confirm a too-large margin degrades gracefully
(e.g. clamps the working width to a minimum) rather than producing a negative or
zero-width frame. If there is no floor, add one before shipping an unbounded max.

## Tests

Add to the relevant test suites (verify current names in `Tests/NehirTests/`):

1. **Resolver honors the new bound.**
   `SettingsStore.resolvedGapSettings` clamps an `outerGapBottom = 400` (set
   directly on the store) down to the new max, and passes through a value at the
   new max unchanged. Also assert a value of `64` is **not** clamped (regression
   for the old ceiling). This is the direct test for the reporter's TOML
   workaround.
2. **Per-monitor override clamps too.** Set a monitor override `outerGapTop = 400`
   and assert the resolved value is the new max (covers the
   `override?.x ?? x` branch).
3. **Round-trip above 64 through TOML.** Encode an export with
   `outerGapBottom = 120`, decode it, and assert the decoded value is `120`
   (pins that the codec never clamped — the cap lives only in the resolver).
   Extend the existing golden/codec tests in `SettingsTOMLCodecTests`.
4. **(If the guard is added)** a display-sized frame with margins larger than the
   frame still yields a non-degenerate (≥ minimum-width) working frame.

## Risks

- **Wrong layer only.** Editing just the resolver or just the sliders recreates
  a "value silently ignored" UX. Both must move together (steps 2 and 3).
- **Slider ergonomics.** A `0 ... 256` slider with `step: 1` is 256 detents;
  fine for a precise picker, but consider whether a coarser step above 64 is
  desirable. Not required.
- **Stale `64` literals elsewhere.** A grep confirmed `clamped(to: 0 ... 64)`
  appears on gap fields **only** at `SettingsStore.swift:910`–`:914`; the eight
  slider literals are the only other gap-related `64`s. No other call sites to
  sweep.

## Relationship to other work

- Discovery: `discovery/20260627-nehir-119-screen-margin-capped-at-64px.md`.
- `planned/20260621-omniwm-373-smart-gaps-single-window.md` — orthogonal (controls
  *when* outer gaps apply, not *how large*). Re-check its zeroing path only if
  the new max is made very large.
- `discovery/20260621-limit-float-precision-config-values.md` — unrelated
  (serialization precision of the same `[gaps]` fields, not the value ceiling).
