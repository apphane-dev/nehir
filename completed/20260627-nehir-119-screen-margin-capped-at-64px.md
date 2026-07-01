# Nehir #119 — Raise the 64 px screen-margin / gap ceiling

**Status:** completed — shipped on `main` in `8c15f374` ("Raise screen margin ceiling to 256px (#119)") on 2026-07-01. Moved from `planned/` to `completed/` on 2026-07-01.
**Source discovery:** `20260627-nehir-119-screen-margin-capped-at-64px-discovery.md`
**Upstream reference:** <https://github.com/apphane-dev/nehir/issues/119> ("[Question] More Margin")

All source references below were re-verified against `main` at `8c15f374` on
2026-07-01. Line numbers will drift.

## TL;DR

The original bug was the reporter's TOML workaround failing: `[gaps.outer]`
values above 64 were stored, but `SettingsStore.resolvedGapSettings(for:)`
clamped them back to 64 before the working-area inset.

What shipped:

- `GapLimits.range = 0 ... 256` in `Sources/Nehir/Core/Config/MonitorGapSettings.swift:10`.
  This is the resolver/code/TOML ceiling for both inner gaps and outer screen
  margins.
- `SettingsStore.resolvedGapSettings(for:connectedMonitors:)` clamps all five
  resolved fields (`gapSize`, left/right/top/bottom outer gaps) to
  `GapLimits.range` (`Sources/Nehir/Core/Config/SettingsStore.swift:861`).
  This is the authoritative fix: TOML / monitor-override values up to 256 now
  reach layout instead of silently collapsing to 64.
- `GapLimits.sliderRange = 0 ... 64` in
  `Sources/Nehir/Core/Config/MonitorGapSettings.swift:20`. This is deliberately
  narrower than the resolver range so Settings sliders stay ergonomic.
- All ten gap sliders in `Sources/Nehir/UI/LayoutSettingsTab.swift` use
  `GapLimits.sliderRange`:
  - global Inner Gap at `:183`, global Screen Margins at `:205`, `:222`, `:239`,
    `:256`;
  - per-monitor Inner Gap at `:483`, per-monitor Screen Margins at `:498`,
    `:509`, `:520`, `:531`.
- Values above the 64 px slider cap are preserved and shown at their true value
  in the UI. `SettingsSliderRow` / `OverridableSlider` format their unclamped
  `effectiveValue`; the SwiftUI slider thumb pins at 64, but the value label can
  still show e.g. `120 px`. Only an actual drag writes a new value in the
  0...64 interactive range.

No schema, persistence, or layout-math change shipped.

## Product decision that unblocked implementation

The chosen resolver maximum is **256 px**. It comfortably covers the reported
custom-dock case while staying bounded.

The Settings UI intentionally does **not** expose a 0...256 slider. The final
split is:

```swift
enum GapLimits {
    static let range: ClosedRange<Double> = 0 ... 256       // resolver / config
    static let sliderRange: ClosedRange<Double> = 0 ... 64  // Settings UI
}
```

This means advanced users can keep larger values in `settings.toml` or monitor
overrides, while the UI remains precise for common values.

## Runtime validation

The fix was validated in two app runs, with evidence inlined here so the record
does not depend on local trace files.

1. **Clean launch with 256 px side margins already configured.** Layout stayed
   healthy with three tiled columns and non-degenerate frames:

   ```text
   c0[x=0.0,cached=668.0]
   c1[x=700.0,cached=684.0]
   c2[x=1416.0,cached=684.0]
   window height = 1020
   reasons included touch_scroll_gesture_*, ax_focus_confirm_*, scroll_animation_*
   ```

   No NaN, fatal/assert, negative/degenerate-frame, or clamp/error pathology was
   observed.

2. **Live Settings update to 256.** The layout reflowed while the app was
   running; observed column cached widths included `560`, `644`, `668`, `684`,
   and `727` during the transition, with window height remaining `1020`. Frame
   verification reported zero positional/size error for the settled writes, e.g.
   `sizeError=0 positionError=0`.

Together these cover the two important paths: persisted config on launch and
live UI/settings mutation.

## Guard outcome

The original plan asked for an additional guard check if the max became 256 or
larger. Static source review and runtime validation were sufficient for the
chosen bound:

- `computeWorkingArea(parentArea:scale:struts:)` clamps working-area width and
  height with `max(0, ...)` before physical-pixel rounding, so oversized struts
  cannot produce negative dimensions.
- The 256 px runtime validation above produced normal non-degenerate Niri
  columns and successful frame verification.

No extra minimum-working-area guard shipped.

## Tests that landed

- `Tests/NehirTests/SettingsStoreTests.swift:272`
  `resolvedGapSettingsHonorNamedRange` — an `outerGapBottom = 400` value clamps
  to `GapLimits.range.upperBound`, a value at the new max passes through, and
  `64` is no longer treated as the ceiling.
- `Tests/NehirTests/SettingsStoreTests.swift:289`
  `resolvedGapSettingsClampMonitorOverrides` — per-monitor outer-gap overrides
  clamp to the same resolver range.
- `Tests/NehirTests/SettingsStoreTests.swift:304`
  `sliderRangeIsNarrowerThanResolverRange` — documents that the UI slider cap is
  intentionally narrower than the resolver/config ceiling.
- `Tests/NehirTests/SettingsTOMLCodecTests.swift:165`
  `roundTripsOuterGaps` now round-trips `outerGapBottom = 120`, pinning that the
  codec/persistence layer does not clamp the value.

Focused validation run during implementation:

```text
swift test --filter 'GapSettingsResolutionTests|SettingsTOMLCodecTests'
→ 14 tests in 2 suites passed
mise run format:check
→ 0 files require formatting
mise run changeset:check
→ Changeset present
```

## Changeset / attribution

A patch changeset shipped with the implementation:

```text
.changeset/20260630093955-raise-screen-margin-limit-to-256px.md
contributors: [charmbyte]
```

The issue reporter `@charmbyte` is attributed as a contributor.

## Relationship to other work

- Discovery: `20260627-nehir-119-screen-margin-capped-at-64px-discovery.md`.
- `../planned/20260621-omniwm-373-smart-gaps-single-window.md` remains
  orthogonal: it controls *when* outer gaps apply, not *how large* they may be.
- `../planned/20260621-limit-float-precision-config-values.md` remains
  unrelated: it concerns serialization precision of config values, not the value
  ceiling.
