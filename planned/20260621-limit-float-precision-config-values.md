# Limit float precision in config values

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned
**Source discovery:** `discovery/20260621-limit-float-precision-config-values.md`
**Prerequisite:** none live — the sibling unknown-key round-trip work it leans on is
already merged (`SettingsTOMLUnknownValue` / per-table `unknownFields`).

All source references were re-verified against the main Nehir source tree on
2026-06-22. Re-verify before editing; line numbers drift.

## TL;DR

Nehir serializes every config `Double` at shortest IEEE-754 round-trip precision,
so the shipped golden fixture already pins `red = 0.08458520228437894` and
`blue = 0.979300037944676` (15–17 significant digits), and any color picked in the
workspace-bar UI injects 16-digit floats (`178/255 = 0.6980392156862745`). This is
a serialization-only cosmetic problem: the file is hard to read, noisy in diffs,
and intimidating to hand-edit.

Fix it **round-on-write at the codec boundary**, leaving the in-memory
`SettingsExport` / `SettingsColor` precision (and therefore all runtime layout,
geometry, and color rendering) untouched. Add one small `Double` formatting helper
in the Config module, route the normalized 0..1 leaves (borders + workspace-bar
RGBA, `backgroundOpacity`, `columnWidthPresets`) and the monitor anchor
coordinates through it, regenerate the golden fixture, and add targeted regression
tests. No schema change, no runtime-precision change.

Chosen policy (resolves discovery open questions #1–#3, see below): **round all
0..1 floats to 6 decimal places, coordinates to 3 decimal places, no `1/255`
quantization in v1.**

## Discovery corrections / decisions

The discovery recommendation is right; these items pin down what it left open or
slightly mis-stated, verified against `main` on 2026-06-22:

1. **Precision policy decided (open Q1 & Q2).** Round 0..1 normalized floats to
   **6 dp** (`1e-6` is far below the 8-bit-sRGB step of ~`3.9e-3` and below any
   perceptual or Display P3 wide-gamut threshold). Round monitor anchor
   coordinates to **3 dp** (sub-pixel). **Do not** quantize to `1/255` in v1 — it
   is lossy for wide-gamut colors and is a product decision tracked as a
   follow-up.
2. **Anchor matcher is tolerance-based, not exact (open Q3 — resolved, de-risks
   the anchor path).** `SettingsStore.reboundMonitor`
   (`Sources/Nehir/Core/Config/SettingsStore.swift:792-796`) selects the monitor
   via `monitors.min { $0.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
   < $1.workspaceAnchorPoint.distanceSquared(to: anchorPoint) }` — a nearest-match
   comparison, not `CGPoint == CGPoint`. A sub-pixel (3 dp) perturbation cannot
   reorder the distances, so rounding anchors to 3 dp is safe. No follow-up work
   is needed on the matcher.
3. **`AppRuleFileStore` has no fractional offenders.** Its only numeric leaves
   are `AppRule.minWidth` / `minHeight` (`Sources/Nehir/Core/Config/AppRule.swift:67-68`,
   `Double?`, pixel sizes). The discovery's "extend `formatNumber` in
   `AppRuleFileStore`" therefore needs **no behavioral change** there; the shared
   helper can replace its duplicated `formatNumber` for hygiene, but `minWidth` /
   `minHeight` stay on the whole-number (precision 0) path. The only hand-written
   codec with a live fractional offender is `MonitorOverrideFileStore`
   (`backgroundOpacity`, plus the two anchor coordinates); `WorkspacesTOMLCodec`
   has the unsanitized anchor interpolation.
4. **`scrollSensitivity` step lives at `BehaviorSettingsTab.swift:70`, not `:68`.**
   Line 68 is the `value:` binding; `step: 0.5` is on line 70. Cosmetic; confirms
   `scrollSensitivity` is a non-offender (0.5 step yields short decimals).
5. **Persistence short-circuit confirmed safe.**
   `SettingsFilePersistence.saveImmediately`
   (`Sources/Nehir/Core/Config/SettingsFilePersistence.swift:135`) compares
   `export == lastPersistedExport` (`:140`) and stores the un-rounded in-memory
   export back into `lastPersistedExport` (`:169`). Because this plan rounds only
   on the *serialized* side (inside `CanonicalTOMLConfig.init(export:)` and the
   hand-written formatters), `SettingsExport` equality is never affected and the
   short-circuit keeps firing. No change to `SettingsFilePersistence` is required.

## Scope

### Files to add/change

1. **`Sources/Nehir/Core/Config/ConfigFloatFormatting.swift`** (new) — shared
   `Double` formatting helpers, used by both the canonical codec and the
   hand-written per-file codecs:
   - `func nehirRounded(precision decimalPlaces: Int) -> Double` —
     `(self * scale).rounded() / scale` where `scale = pow(10, decimalPlaces)`.
     Reuses the *shape* of the existing `CGFloat.roundedToPhysicalPixel(scale:)`
     helper at `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:12` (layout
     domain — do not import that file; copy the shape).
   - `func nehirFormatted(precision decimalPlaces: Int = 0) -> String` — returns
     `String(Int(self))` when `self == self.rounded()` (preserves the existing
     whole-number collapse used by the hand-written codecs, e.g. `16.0` → `16`),
     otherwise `String(self.nehirRounded(precision: decimalPlaces))`. With
     `precision: 0` this reproduces today's `formatNumber` behavior for
     fractional values; callers pass `6` for 0..1 fields and `3` for coordinates.
2. **`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`** — apply shape (A)
   from the discovery: round the normalized 0..1 leaves **in `init(export:)`**
   so the stored canonical value is already short when the per-table
   `encode(to:)` hands it to `swift-toml`. Concrete leaf assignments to wrap:
   - `borders.color`: `red: export.borderColorRed.nehirRounded(precision: 6)`,
     and the same for `green` / `blue` / `alpha` (in the `Borders.Color(...)`
     initializer inside `init(export:)`).
   - `workspaceBar.backgroundOpacity` → `export.workspaceBarBackgroundOpacity.nehirRounded(precision: 6)`.
   - `workspaceBar.accentColor` / `workspaceBar.textColor`: in the
     `.map { color in ... }` blocks, round `color.red/green/blue/alpha` to 6 dp
     when constructing `WorkspaceBar.Color`.
   - `niri.columnWidthPresets` →
     `export.niriColumnWidthPresets?.map { $0.nehirRounded(precision: 6) }`
     (cheap sanitize so hand-edited or future-version presets stay clean;
     discovery open Q5 — recommended yes).
   - Do **not** round px fields (`gaps.size`, `borders.width`,
     `workspaceBar.height/xOffset/yOffset/labelFontSize`, etc.) — they are
     integer-stepped and already clean; leaving them untouched keeps the diff
     minimal and the short-circuit semantics obvious.
   - *Equivalent alternative the worker may choose:* round inside each per-table
     `encode(to:)` (e.g. `Borders.Color.encode` emits
     `try container.encode(red.nehirRounded(precision: 6), forKey: "red")`).
     Same serialized output, no stored-value mutation. Pick `init(export:)` for a
     single concentrated seam; switch only if a snag appears.
3. **`Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift`** — replace the
   private `formatNumber(_:​)` (`:254`) with a thin delegate to
   `Double.nehirFormatted(precision:)`, and route the fractional leaves through
   higher precision:
   - `anchorX` / `anchorY` (`:98-99`) → `formatNumber(anchor.x)` becomes
     `anchor.x.nehirFormatted(precision: 3)` (coordinate).
   - `backgroundOpacity` (`:140`) → `v.nehirFormatted(precision: 6)` (0..1).
   - `height`, `xOffset`, `yOffset`, `gapSize`, `outerGap*`, `loneWindowMaxWidth`
     stay on `nehirFormatted()` (precision 0 / whole-collapse) — they are px or
     already-clean ratios.
4. **`Sources/Nehir/Core/Config/AppRuleFileStore.swift`** — replace the private
   `formatNumber(_:​)` (`:266`) with `Double.nehirFormatted()` for hygiene
   (removes the duplicated helper). **No behavioral change**: `minWidth` /
   `minHeight` (`:62-63`) are px integers and stay on the whole-number path.
5. **`Sources/Nehir/Core/Config/WorkspacesTOMLCodec.swift`** — the anchor
   interpolation (`:43-44`) currently uses raw `\(anchor.x)` / `\(anchor.y)`
   string interpolation (shortest round-trip). Route both through
   `anchor.x.nehirFormatted(precision: 3)` / `anchor.y.nehirFormatted(precision: 3)`.
   `parseAnchorPoint(x:y:)` (`:220`) already parses arbitrary precision, so
   load→save stability holds.
6. **`Tests/NehirTests/Fixtures/canonical-settings.toml`** — regenerate to match
   the new short forms. After this plan the `[borders.color]` block becomes:
   ```toml
   [borders.color]
   alpha = 1.0
   blue = 0.9793
   green = 1.0
   red = 0.084585
   ```
   (`String(0.084585202284378935.nehirRounded(precision: 6))` → `"0.084585"`;
   `String(0.97930003794467602.nehirRounded(precision: 6))` → `"0.9793"`.) All
   other tables are byte-identical. The existing
   `canonicalDefaultsMatchGoldenFixture` test re-pins the cleaner file and
   already writes the actual output to a temp path on drift, so the update is
   mechanical.
7. **Tests under `Tests/NehirTests/`** — see §Tests.

### Non-goals

- Do **not** change runtime precision used by layout, color rendering, or
  geometry. Rounding happens only on the serialized side of the codec boundary.
- Do **not** quantize color channels to `1/255` in v1 (product decision; tracked
  as a follow-up).
- Do **not** change the config schema (no hex colors, no integer-percent
  opacity). That is a migration and is strictly out of scope.
- Do **not** touch `SettingsFilePersistence` equality/short-circuit logic.
- Do **not** apply rounding to the `SettingsTOMLUnknownValue.float` re-encode
  path in v1 (`Sources/Nehir/Core/Config/SettingsTOMLUnknownValue.swift`,
  `.float(let value)` case in `encode(to:)`). Track as a follow-up for output
  consistency.
- Do **not** round px/integer-stepped fields (`gaps`, `borders.width`,
  `workspaceBar.height/xOffset/yOffset/labelFontSize`, `scrollSensitivity`, …).

## Exact implementation plan

### Phase 1 — Shared helper

1. Create `Sources/Nehir/Core/Config/ConfigFloatFormatting.swift` with the
   `Double.nehirRounded(precision:)` and `Double.nehirFormatted(precision:)`
   extensions described above. `nehirFormatted` must preserve the whole-number
   collapse (`self == self.rounded()`) so the hand-written codecs keep their
   current integer styling (e.g. `size = 16`, not `size = 16.0`).
2. `swift build` to confirm it compiles in isolation.

### Phase 2 — Canonical codec (the main offender)

3. In `CanonicalTOMLConfig.init(export:)`, wrap the normalized 0..1 leaf
   assignments with `.nehirRounded(precision: 6)`: `borders.color` RGBA,
   `workspaceBar.backgroundOpacity`, `workspaceBar.accentColor?.{r,g,b,a}`,
   `workspaceBar.textColor?.{r,g,b,a}`, and `niri.columnWidthPresets`
   (`.map { $0.nehirRounded(precision: 6) }`). Leave px and coordinate-free
   fields untouched.
4. Regenerate `Tests/NehirTests/Fixtures/canonical-settings.toml` by encoding
   `SettingsExport.defaults()` and replacing the fixture (or letting the test
   write the actual to its temp path and copying it over). Verify only the
   `[borders.color]` `red`/`blue` lines change.
5. Run `swift test --filter SettingsTOMLCodecTests`. The existing
   `canonicalDefaultsMatchGoldenFixture`, `roundTripsMainSettingsDefaults`, and
   `roundTripsNestedColorQuartets` tests must stay green; note that
   `roundTripsMainSettingsDefaults` will now exercise save→load lossiness for the
   two default color channels — if it asserts exact equality on defaults, relax
   it to a tolerance (≤ `1e-6` per channel) or assert against the rounded
   defaults. (See §Risks.)

### Phase 3 — Hand-written codecs

6. In `MonitorOverrideFileStore`, replace the private `formatNumber` with
   `Double.nehirFormatted` and route `backgroundOpacity` through precision 6 and
   `anchorX`/`anchorY` through precision 3; leave px/outer-gap fields at
   precision 0.
7. In `AppRuleFileStore`, replace the private `formatNumber` with
   `Double.nehirFormatted()` (precision 0) — hygiene only, no behavior change.
8. In `WorkspacesTOMLCodec`, route the `monitorAnchorX` / `monitorAnchorY`
   interpolation (`:43-44`) through `.nehirFormatted(precision: 3)`.
9. `swift build`, then run the codec test filters in §Validation.

### Phase 4 — Tests

10. Add the regression tests in §Tests.

### Phase 5 — Full validation

11. Run the full config/codec test matrix (§Validation) and a clean `mise run test`.

## Tests

### `Tests/NehirTests/SettingsTOMLCodecTests.swift` (extend)

1. **`colorChannelsSpelledShortOnEncode`** — set
   `borderColorRed = 0.084585202284378935`, `borderColorBlue = 0.97930003794467602`,
   encode, assert the output contains `red = 0.084585` and `blue = 0.9793` (≤ 6
   fractional digits, never the 15–17-digit form).
2. **`nsColorDerivedChannelsRoundTripIdempotently`** — build a `SettingsColor`
   from a channel like `178/255`, set it as `workspaceBarAccentColor`, then
   encode → decode → re-encode and assert the two encoded forms are
   byte-identical (load→save stability for colors).
3. **`opacityArithmeticArtifactNotLeaked`** — set
   `workspaceBarBackgroundOpacity = 0.1 + 0.2`, encode, assert the output does
   **not** contain `30000000000000004` and is bounded to 6 fractional digits
   (e.g. `backgroundOpacity = 0.3`).
4. **`decodedColorWithinPrecisionBound`** — after a rounded encode, the decoded
   `SettingsColor` differs from the input by at most `1e-6` per channel (pins the
   chosen precision bound and documents the save→load lossiness).
5. **`canonicalDefaultsMatchGoldenFixture`** (existing) — stays green after the
   fixture regeneration in Phase 2.

### `Tests/NehirTests/WorkspacesTOMLCodecTests.swift` (extend)

6. **`fractionalAnchorSurvivesRoundTripWithBoundedPrecision`** — encode a
   workspace config with a fractional anchor (e.g. `x = 1440.5789`,
   `y = 900.3333`), assert the encoded text spells each coordinate with ≤ 3
   fractional digits, then decode → re-encode and assert byte-identical output.

### Monitor override round-trip (extend `Tests/NehirTests/SettingsStoreTests.swift`)

7. **`fractionalBackgroundOpacityOverrideIsBoundedAndRoundTrips`** — write a
   `MonitorBarSettings` with `backgroundOpacity = 0.1 + 0.2` and a fractional
   anchor, round-trip it through `MonitorOverrideFileStore.write` / read, assert
   the encoded file spells `backgroundOpacity` with ≤ 6 fractional digits (no
   `30000000000000004`) and the anchor coordinates with ≤ 3 fractional digits,
   and that the decoded values match within the precision bound.

Test hygiene: keep all assertions on the *serialized text* (regex/substring) for
the "spelled short" cases, and on `Double` tolerance for the round-trip cases.

## Validation

```bash
swift build
swift test --filter SettingsTOMLCodecTests
swift test --filter WorkspacesTOMLCodecTests
swift test --filter SettingsStoreTests
swift test --filter AppRuleDraftTests
# Full suite (Xcode required):
mise run test
```

Manual spot-check (optional): pick a non-trivial accent color in the workspace-bar
settings UI, save, open `settings.toml`, and confirm the `[workspaceBar.accentColor]`
channels are spelled at ≤ 6 fractional digits; toggle a per-monitor
`backgroundOpacity` override and confirm the monitor override file is likewise
clean.

Changeset (patch): "Round config floats to bounded precision on write for
diff-stable, hand-editable TOML."

## Risks and mitigations

- **save→load lossiness for colors (by design).** Rounding in
  `init(export:)` means `0.084585202284378935` is written as `0.084585` and reads
  back as `0.084585`. This is sub-perceptual (≤ `1e-6` per channel, far below the
  8-bit sRGB step) and load→save→load is stable, but the existing
  `roundTripsMainSettingsDefaults` test may assert exact default equality. If it
  fails, relax it to a per-channel `abs(decoded - input) <= 1e-6` tolerance (or
  compare against the rounded defaults). Document the lossiness in a code comment
  at the `init(export:)` seam.
- **Persistence short-circuit.** Confirmed safe (see Discovery corrections #5):
  `lastPersistedExport` holds the un-rounded `SettingsExport`, so
  `export == lastPersistedExport` is unaffected. Keep rounding strictly on the
  serialized side; do **not** write rounded values back into `SettingsExport` or
  `lastPersistedExport`.
- **Whole-number collapse regression in hand-written codecs.** `nehirFormatted`
  must keep `self == self.rounded() → String(Int(self))` so px fields continue to
  emit `size = 16` rather than `size = 16.0`. Add an `AppRuleDraftTests` /
  monitor-override assertion that a whole-number px field still collapses.
- **Coordinate rounding vs. anchor rebounding.** Resolved safe (Discovery
  corrections #2): the rebounder is nearest-match via `distanceSquared`, not
  exact equality, so 3 dp cannot flip the selected monitor. If the matcher ever
  moves to exact equality, revisit before tightening coordinate precision.
- **`columnWidthPresets` sanitize changing the fixture.** Built-in defaults
  (`0.35/0.5/0.65/0.95`) are already ≤ 2 dp, so `.nehirRounded(precision: 6)` is
  a no-op on them; the golden fixture's `[niri]` table stays byte-identical.
  Confirm via the regenerated fixture diff.
- **swift-toml pin.** The library is pinned at `2.0.0`, revision `827506c`
  (per `Package.resolved`); it serializes floats via `String(f)` (shortest
  round-trip) in `Sources/TOML/Encoder.swift` `serializeValue`. Feeding it a
  pre-rounded `Double` is the entire mechanism of this plan; do not attempt to
  change the library.

## Follow-ups (out of scope)

- Apply the same helper to `SettingsTOMLUnknownValue.float` re-encode
  (`Sources/Nehir/Core/Config/SettingsTOMLUnknownValue.swift`, `.float` case) so
  future-version floats re-emitted by an older build are also clean. Cosmetic;
  track separately.
- Product decision: quantize color channels to `1/255` so hand-edited values
  match 8-bit hex exactly. Lossy for wide-gamut (Display P3) colors; needs a
  product call before implementing.
- Schema-level alternatives (store opacity as integer percent, color as hex) —
  full schema migration, strictly separate.
- If field-specific precision ever needs to vary beyond the two-bucket rule
  (0..1 → 6 dp, coordinate → 3 dp), consider per-field metadata; not needed today.
