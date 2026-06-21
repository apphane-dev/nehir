# Discovery — Limit float precision in config values

Source: backlog item **#10** "Limit float precision in config values"
(`planned/20260621-backlog-brainstorm.md`, "Config / rules / automation" section).

Scope of this doc: determine what "limit float precision" means for Nehir's
config files, whether the problem is real in the current source tree, exactly
which fields and codecs produce ugly high-precision floats, and whether/where it
should be fixed.

All source references verified against the main Nehir source tree on
2026-06-21. Re-verify before implementing; line numbers drift. The external
`swift-toml` library is pinned at version `2.0.0`, revision `827506c` (per
`Package.resolved`); references to its encoder use that pin.

---

## TL;DR

- **The problem is real and already visible in the shipped defaults.** Nehir's
  `settings.toml` golden fixture pins color channels as
  `red = 0.08458520228437894` and `blue = 0.979300037944676` (17 and 15
  significant digits). These come straight from `SettingsExport.defaults()`
  (`borderColorRed = 0.084585202284378935`, `borderColorBlue = 0.97930003794467602`).
- **Root cause:** the `swift-toml` encoder serializes every `Double` with
  `String(f)` (shortest IEEE-754 round-trip). There is no precision policy on
  Nehir's side. Nehir's own `formatNumber` helper (used by the three hand-written
  per-file codecs) only strips the `.0` suffix from whole numbers; it leaves
  genuine fractional floats at full precision.
- **Most fields are fine** because they are pixel sizes driven by `step: 1`
  sliders (`gaps.size`, `workspaceBar.height`, `borderWidth`, …) or stepped
  ratios (`scrollSensitivity` step `0.5`). The offenders cluster into two
  groups: **normalized 0..1 channels/opacity** (color RGBA, `backgroundOpacity`)
  and **geometric coordinates** (`monitorAnchorX/Y`).
- **Verdict:** 🟢 **Pursue — small and scoped.** Round-on-write at the codec
  boundary (do not touch runtime precision). The companion work it depends on
  (unknown-key round-tripping, OmniWM #410) is already merged
  (`SettingsTOMLUnknownValue` / `unknownFields`), so this is a clean cosmetic
  follow-up, not a schema change.

## Related prior work

- `planned/20260621-backlog-brainstorm.md` — the source list; item #10 is this
  idea.
- `discovery/20260616-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md` —
  the sibling config-codec investigation. Its recommendation (preserve unknown
  TOML keys) is **already implemented** in the current tree via
  `SettingsTOMLUnknownValue` (`Sources/Nehir/Core/Config/SettingsTOMLUnknownValue.swift`)
  and the per-table `unknownFields: [String: SettingsTOMLUnknownValue]` slots in
  `CanonicalTOMLConfig` (`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`).
  The test there was flipped from
  `unknownNiriKeysAreIgnoredAndNotReencoded` to
  `unknownNiriKeysRoundTripThroughReencode`
  (`Tests/NehirTests/SettingsTOMLCodecTests.swift`). That work is what makes the
  float-precision fix low-risk today: the codec boundary is already the place
  where serialization concerns are isolated, so adding a precision policy there
  is consistent with the established design.
- No prior discovery doc addresses float precision directly. A grep for
  `precision`, `rounded(` (excluding frame/corner usage), `quantiz`,
  `significantDigit` across `discovery/`/`planned/`/`completed/`/`noop/` finds
  only unrelated layout-quantization material (e.g.
  `discovery/20260618-upstream-port-minor-candidates.md` M2 "Learned per-window
  size quantum", which is about refused-frame learning, not config formatting).

## What the idea means for Nehir

Nehir persists its configuration to TOML files that users read, hand-edit, and
diff in version control. When a `Double` config value is serialized with full
IEEE-754 precision, the file fills with values like `0.08458520228437894` or
`0.6980392156862745` that are (a) hard to read, (b) noisy in diffs, and (c)
intimidating to hand-edit. "Limit float precision" means: when *writing* config,
emit only the decimal digits that matter for that field's semantics, so the file
is clean and diff-stable. It is a serialization/cosmetic concern — it must **not**
reduce runtime precision used by layout, color rendering, or geometry.

The concept is independent of (but adjacent to) the unknown-key round-trip work:
that preserves *which* keys survive a save; this controls *how* a float's value
is spelled.

## Current behavior (with evidence)

### The encoder formats every Double as shortest-round-trip

`settings.toml` is written by `SettingsTOMLCodec.encode`
(`Sources/Nehir/Core/Config/SettingsTOMLCodec.swift`), which builds a
`CanonicalTOMLConfig` and hands it to `TOMLEncoder` from the pinned `swift-toml`
2.0.0 library. That library serializes floats in its `serializeValue` switch as:

```swift
case .float(let f):
    if f.isNaN { return "nan" }
    else if f.isInfinite { return f > 0 ? "inf" : "-inf" }
    return String(f)
```

(`swift-toml` @ `827506c`, `Sources/TOML/Encoder.swift`, `serializeValue`.)

`String(Double)` in Swift yields the shortest decimal string that round-trips to
the same `Double`. That is the right call for *lossless* serialization, but it
emits 15–17 significant digits whenever the stored value is not a "nice"
decimal — which is the common case for color channels derived from hex/NSColor.

### The defaults already prove it

The shipped golden fixture `Tests/NehirTests/Fixtures/canonical-settings.toml`
(which the test `canonicalDefaultsMatchGoldenFixture` pins byte-for-byte,
`Tests/NehirTests/SettingsTOMLCodecTests.swift`) currently contains:

```toml
[borders.color]
alpha = 1.0
blue = 0.979300037944676
green = 1.0
red = 0.08458520228437894
```

These come from `SettingsExport.defaults()`
(`Sources/Nehir/Core/Config/SettingsExport.swift`):

- `borderColorRed: 0.084585202284378935`
- `borderColorBlue: 0.97930003794467602`

Encoding each default `Double` with `String(_:)` reproduces the fixture exactly
(verified on 2026-06-21):

- `String(0.084585202284378935)` → `"0.08458520228437894"`
- `String(0.97930003794467602)` → `"0.979300037944676"`

### User-driven values make it worse, not better

Colors picked in the workspace-bar settings UI flow through
`SettingsColor(nsColor:)` / `SettingsColor(color:)`
(`Sources/Nehir/UI/SettingsColor+SwiftUI.swift`):

```swift
guard let converted = nsColor.usingColorSpace(.deviceRGB) else { return nil }
self.init(
    red: Double(converted.redComponent),
    green: Double(converted.greenComponent),
    blue: Double(converted.blueComponent),
    alpha: preservesAlpha ? Double(converted.alphaComponent) : 1
)
```

`NSColor.redComponent` etc. are raw 0..1 doubles. An 8-bit-per-channel sRGB
value does not round-trip to a short decimal — e.g. the channel for 8-bit `178`
is `178/255 = 0.6980392156862745` (16 significant digits). So as soon as a user
picks any non-trivial accent/text color, the file gains 16-digit floats under
`[workspaceBar.accentColor]` / `[workspaceBar.textColor]`. Arithmetic artifacts
also leak through directly: a value computed as `0.1 + 0.2` serializes as
`0.30000000000000004`.

### Most other Double fields are already clean

Not every `Double` field is an offender. Inventory of `Double` leaf fields in
`CanonicalTOMLConfig` (`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`)
and their UI stepping:

| Field (table.key) | Semantics | UI step | Offender? |
|---|---|---|---|
| `gaps.size`, `gaps.outer.{left,right,top,bottom}` | px gaps | integer slider | no |
| `niri.loneWindowMaxWidth`, `niri.defaultColumnWidth` | px width | integer stepper | no |
| `niri.columnWidthPresets` | 0..1 ratios | defaults `0.35/0.5/0.65/0.95` | no (today) |
| `borders.width` | px | integer | no |
| `borders.color.{red,green,blue,alpha}` | 0..1 channel | color picker | **yes** |
| `workspaceBar.height`, `xOffset`, `yOffset`, `labelFontSize` | px / pt | integer | no |
| `workspaceBar.backgroundOpacity` | 0..1 | slider | **yes** (potentially) |
| `workspaceBar.accentColor.{r,g,b,a}`, `workspaceBar.textColor.{r,g,b,a}` | 0..1 channel | color picker | **yes** |
| `gestures.scrollSensitivity` | multiplier | `step: 0.5` (`BehaviorSettingsTab.swift:68`) | no |

So the live offenders are: **all four borders color channels, all eight
workspace-bar color channels, and `workspaceBar.backgroundOpacity`** — i.e. the
normalized 0..1 family. `columnWidthPresets` is clean today only because the
built-in defaults happen to be short decimals; a hand-edited or future-version
preset would not be sanitized.

### The hand-written codecs have the same issue, half-mitigated

Three per-file codecs bypass `TOMLEncoder` and write TOML by hand. They share a
helper:

```swift
// Sources/Nehir/Core/Config/AppRuleFileStore.swift:266
// Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift:254
private static func formatNumber(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}
```

This collapses `16.0` → `16` (nice) but still emits `String(value)` — full
shortest-round-trip — for any genuinely fractional value. `MonitorGapSettings`
and `MonitorBarSettings` (`Sources/Nehir/Core/Config/MonitorGapSettings.swift`,
`Sources/Nehir/Core/Config/MonitorBarSettings.swift`) carry `Double?` fields
(`gapSize`, `outerGap*`, `height`, `backgroundOpacity`, `xOffset`, `yOffset`)
that flow through this helper, so a fractional per-monitor `backgroundOpacity`
override emits full precision.

`WorkspacesTOMLCodec` does not use the helper at all for the anchor fields
(`Sources/Nehir/Core/Config/WorkspacesTOMLCodec.swift:42-45`):

```swift
if let anchor = output.anchorPoint {
    lines.append("monitorAnchorX = \(anchor.x)")
    lines.append("monitorAnchorY = \(anchor.y)")
}
```

Default Swift string interpolation of `CGFloat`/`Double` is again the shortest
round-trip form, so a monitor anchor point (display pixel coordinates, often
fractional on scaled/HiDPI layouts) lands in `workspaces/*.toml` at full
precision.

## Where / how it would be implemented

The clean design — consistent with the unknown-key work — is **round-on-write at
the codec boundary**, leaving the in-memory `SettingsExport` / `SettingsColor`
precision untouched. Concrete places:

1. **Normalized 0..1 fields in `CanonicalTOMLConfig`** — round at the point
   where the canonical serialization shape is built. The natural seam is each
   per-table `encode(to encoder: Encoder)` override, or the leaf assignments in
   `init(export:)` (`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`).
   Rounding the value fed into `container.encode(...)` means the `Double`
   reaching the library is already short, so `String(f)` emits a short decimal.
   Affected leaves: `Borders.Color.{red,green,blue,alpha}`,
   `WorkspaceBar.Color.{red,green,blue,alpha}` (both the `accentColor` and
   `textColor` nested tables), and `WorkspaceBar.backgroundOpacity`.
2. **A shared precision helper.** Add a small `Double` extension (e.g.
   `func nehirRounded(precision:)` / `func quantized(toStep:)`) in the Config
   module. There is already an in-repo precedent for the technique:
   `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:12`
   `(self * scale).rounded() / scale` (a `quantized(to:)`-style helper, layout
   domain). Reuse the *shape*, not the file.
3. **The three hand-written codecs.** Extend `formatNumber` (in
   `AppRuleFileStore` and `MonitorOverrideFileStore`) to accept a precision
   parameter, or add a sibling `formatRatio(_:)` for 0..1 fields, and route
   `MonitorBarSettings.backgroundOpacity` through it. Give
   `WorkspacesTOMLCodec`'s anchor interpolation the same treatment
   (`monitorAnchorX/Y`).
4. **The unknown-value float path.** `SettingsTOMLUnknownValue.float(Double)`
   (`Sources/Nehir/Core/Config/SettingsTOMLUnknownValue.swift`) re-emits a
   captured future-version float at full precision. For consistency the same
   helper can be applied in its `encode(to:)`. This is cosmetic and optional;
   flag it as a follow-up rather than a blocker.
5. **Golden fixture.** `Tests/NehirTests/Fixtures/canonical-settings.toml` must
   be regenerated to match the new output. The existing test
   `canonicalDefaultsMatchGoldenFixture` already writes the actual output to a
   temp file on drift, so the update is mechanical. Add targeted regression
   tests (see below).

Two implementation shapes are viable for the main codec; pick one:

- **(A) Round in `init(export:)`.** Mutate the canonical struct's stored values
  to the rounded forms. Simplest; the canonical struct is a serialization-only
  shape (the app reads via `toSettingsExport()`), so rounding there does not
  leak into runtime state. Risk: `toSettingsExport()` is also used on the decode
  path, so a decoded color would come back rounded — acceptable (sub-perceptual)
  but means load→save is idempotent while save→load is lossy by design.
- **(B) Custom wrapper `Encodable`.** Wrap the normalized fields in a
  `PreciseDouble` type whose `encode(to:)` emits the rounded value, leaving the
  stored `Double` exact. More invasive (changes field types) but keeps decode
  lossless. Overkill for a cosmetic fix; prefer (A).

Recommendation: **(A)**, scoped to the normalized 0..1 fields plus the anchor
interpolation.

## Risks and unknowns

- **Persistence short-circuit interaction.** `SettingsFilePersistence.saveImmediately`
  skips the write when `export == lastPersistedExport`
  (`Sources/Nehir/Core/Config/SettingsFilePersistence.swift`, the equality guard
  before `data.write(..., options: .atomic)`). If rounding is applied only to
  the *bytes* and `lastPersistedExport` stores the un-rounded in-memory export,
  the short-circuit keeps working (both sides compare un-rounded). If instead
  the rounded value is written back into `lastPersistedExport`, the next
  comparison would see `export != lastPersistedExport` on every save (no loop,
  but the short-circuit never fires). Confirm which object `lastPersistedExport`
  holds and keep rounding purely on the serialized side to preserve the
  optimization.
- **Color fidelity vs. perceptual thresholds.** Rounding a 0..1 channel to 6 dp
  is `1e-6` — far below any perceptual or 8-bit-sRGB threshold, and safe for
  Display P3 wide-gamut channels. Quantizing to `1/255` (~0.0039) matches 8-bit
  sRGB exactly and would make hand-editing match hex values, but it is lossy for
  wide-gamut colors. The safe default is **round to N dp (5–6)**; quantize-to-
  255 is a stronger policy choice that needs a product decision.
- **Decode lossiness under shape (A).** As noted, rounding in `init(export:)`
  makes save→load slightly lossy for colors. This is acceptable but should be
  documented and tested (load→save→load must be stable; save→load→save must be
  stable).
- **Anchor-point semantics.** `monitorAnchorX/Y` are real pixel coordinates used
  by monitor-identity-agnostic restore (see
  `discovery/20260618-monitor-identity-agnostic-restore.md` /
  `completed/20260618-monitor-identity-agnostic-restore.md`). Rounding to, say,
  2–3 dp is sub-point and safe; rounding to integers could shift a matched
  anchor by a fraction of a pixel and *might* affect matching if the matcher
  does exact equality. The matcher must be checked before applying integer
  rounding to anchors. (Unknown — not verified for this doc.)
- **Scope creep into schema.** "Store opacity as integer percent, color as hex"
  is a tempting adjacent change. It is a schema migration and strictly out of
  scope for this cosmetic fix; track separately.

## Open questions

1. **Precision policy.** Fixed N-decimal-places (e.g. 6 dp for 0..1, 2–3 dp for
   coordinates), or per-field metadata? A single global rule is simpler and
   probably sufficient.
2. **Color quantization.** Round-to-N-dp (recommended) vs. quantize-to-1/255
   (matches 8-bit sRGB and hex editing)? Decide before implementing so the
   golden fixture is regenerated once.
3. **Anchor matcher tolerance.** Does
   `Sources/Nehir/Core/Config/WorkspacesTOMLCodec.swift`'s
   `parseAnchorPoint`/consumer do exact `CGPoint` equality on restore, or a
   tolerance-based match? Determines whether anchors can be aggressively
   rounded.
4. **Unknown-float path.** Apply the helper to
   `SettingsTOMLUnknownValue.float` re-encode, or leave future-version floats
   untouched? (Recommend: apply, for output consistency, but as a follow-up.)
5. **`columnWidthPresets` hand-editing.** Should presets be sanitized on write
   too, even though defaults are clean today? (Recommend: yes, cheaply, under
   the same helper.)

## Suggested tests   (omit if N/A)

Add to `Tests/NehirTests/SettingsTOMLCodecTests.swift`:

1. **Color channels are spelled short on encode.** Set
   `borderColorRed = 0.084585202284378935`, encode, assert the output contains
   `red = 0.084585` (or whatever precision is chosen) — i.e. ≤ a fixed number of
   fractional digits, not 17.
2. **NSColor-derived channels round-trip idempotently.** Build a `SettingsColor`
   from a channel like `178/255`, encode → decode → re-encode, assert the two
   encoded forms are byte-identical (load→save stability for colors).
3. **Opacity rounding.** Set `workspaceBarBackgroundOpacity = 0.1 + 0.2`
   (arithmetic artifact), encode, assert the output does not contain
   `30000000000000004`.
4. **Runtime precision preserved.** After a rounded encode, the decoded
   `SettingsColor` differs from the input by at most `1e-6` per channel (pins
   the chosen precision bound).
5. **Golden fixture regenerated** to match the new short forms; the existing
   `canonicalDefaultsMatchGoldenFixture` test then re-pins the cleaner file.

For the hand-written codecs, add to the relevant test suites:

6. **`WorkspacesTOMLCodec`** — a fractional anchor (e.g. `x = 1440.5`) survives
   load→save and is spelled with bounded precision.
7. **`MonitorOverrideFileStore` / `AppRuleFileStore`** — a fractional
   `backgroundOpacity` override is spelled with bounded precision and round-trips.

## Recommendation

**Pursue — small and scoped.** The ugliness is real, already in the shipped
defaults, and gets worse the moment a user touches a color picker. The fix is a
serialization-only change at the codec boundary (do not alter runtime geometry or
color precision), the dependent unknown-key work is already merged, and the
existing golden-fixture test machinery makes verification mechanical.

Concrete plan, in order:

1. Add a `Double` precision helper in the Config module (round-to-N-dp; reuse
   the `(x * scale).rounded() / scale` shape already in
   `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift`).
2. Apply it on write to the normalized 0..1 leaves in `CanonicalTOMLConfig`
   (borders + workspace-bar RGBA, `backgroundOpacity`), via shape (A).
3. Extend `formatNumber` in `AppRuleFileStore`/`MonitorOverrideFileStore` and
   the `WorkspacesTOMLCodec` anchor interpolation.
4. Regenerate `Tests/NehirTests/Fixtures/canonical-settings.toml` and add the
   regression tests above.
5. Defer: unknown-float path, `columnWidthPresets` sanitization, any
   schema-level change (hex colors / integer-percent opacity), and the
   anchor-matcher tolerance question — track as follow-ups.

Decision needed before step 2: the precision/quantization policy (open question
#1 and #2). Default recommendation: **round all 0..1 floats to 6 decimal
places** and **coordinates to 3 decimal places**, no `1/255` quantization in the
first cut.
