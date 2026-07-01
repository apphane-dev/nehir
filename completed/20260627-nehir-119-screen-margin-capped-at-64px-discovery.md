# Screen margins (outer gaps) are hard-capped at 64 px in both the UI and the layout resolver — Discovery

**Status:** completed/resolved — implementation shipped on `main` in `8c15f374` ("Raise screen margin ceiling to 256px (#119)") on 2026-07-01. See the completed implementation record at [`20260627-nehir-119-screen-margin-capped-at-64px.md`](20260627-nehir-119-screen-margin-capped-at-64px.md).

Discovery (2026-06-27). GitHub issue **apphane-dev/nehir#119** "[Question]
More Margin": a user wants screen margins larger than 64 px (their custom dock
does not reserve space at the screen edge, so they want Nehir's margin to stand
in for it). The Settings slider tops out at 64 px, and hand-editing the value
above 64 in `settings.toml` has **no effect** — the margin stays at 64. This doc
locates, from source, exactly where that 64 px ceiling is enforced and why the
TOML workaround silently fails.

All code citations were verified against the main Nehir source tree at
`9ef0ae82` on 2026-06-27 (`git log -1 --format='%h %s'` → `9ef0ae82 Add sticky
PiP defaults and ignore app rules`). Line numbers will drift.

The completed implementation record is in
[`20260627-nehir-119-screen-margin-capped-at-64px.md`](20260627-nehir-119-screen-margin-capped-at-64px.md).

---

## TL;DR

- **Resolved on `main`.** The shipped fix splits the old single magic number into
  `GapLimits.range = 0 ... 256` for resolver/code/TOML values and
  `GapLimits.sliderRange = 0 ... 64` for all Settings gap sliders. Values above
  the 64 px slider cap are still preserved and displayed at their true value;
  the slider thumb simply pins at 64.
- The original 64 px ceiling was enforced at **two independent layers**; both had
  to change to raise it.
  1. **UI** — all eight screen-margin sliders (4 global + 4 per-monitor) in
     `LayoutSettingsTab` use `range: 0 ... 64`.
  2. **Runtime resolver** — `SettingsStore.resolvedGapSettings(for:)` clamps
     every resolved gap to `0 ... 64` via `.clamped(to: 0 ... 64)`.
- The layout reads margins **only** through that resolver
  (`WMController.insetWorkingFrame → outerGaps(for:) → resolvedGapSettings(for:)`),
  so a TOML value such as `bottom = 120` is stored verbatim but silently
  collapsed to `64` before it reaches the working-area inset. This is precisely
  why the `.toml` edit "caps at 64 regardless".
- The TOML load/store path does **not** clamp: `[gaps.outer] left/right/top/bottom`
  decode straight into an unclamped stored property. The cap is therefore a
  resolver + UI policy, **not** a persistence/format limit.
- `64` is a magic literal duplicated across ~13 call sites (5 fields in one
  resolver + 8 slider ranges) with no named constant. The inner-gap slider tops
  out at `0 ... 32` while the resolver allows `gapSize` up to `0 ... 64` — a
  pre-existing minor inconsistency surfaced by the same code path.

---

## How Nehir spells "screen margin"

"Screen margins" in the UI are the **outer gaps** — the empty band between the
monitor edge and the tiled working area, per edge. The relevant types and the
default values:

- `SettingsExport` fields `outerGapLeft/Right/Top/Bottom: Double`, defaults all
  `0` (and `gapSize: 16`)
  (`Sources/Nehir/Core/Config/SettingsExport.swift:123`).
- Per-monitor overrides live in `MonitorGapSettings.outerGapLeft/Right/Top/Bottom`
  as `Double?` (`Sources/Nehir/Core/Config/MonitorGapSettings.swift:30`).
- The resolver folds override-or-global into `ResolvedGapSettings`, whose
  `outerGaps: LayoutGaps.OuterGaps` view
  (`Sources/Nehir/Core/Config/MonitorGapSettings.swift:56`) is what the layout
  consumes.

The TOML shape is a nested table (encode/decode in
`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`):

```toml
[gaps]
size = 16          # inner gap (gapSize)

[gaps.outer]       # screen margins (outer gaps)
left = 0
right = 0
top = 0
bottom = 0
```

`CanonicalTOMLConfig.Gaps` (`:80`) and `Gaps.Outer` (`:89`) are plain `Double`
leaves; encode is at `:283`, decode is at `:390`. Neither side clamps.

---

## Enforcement point 1 — the Settings UI sliders

`Sources/Nehir/UI/LayoutSettingsTab.swift`. Every screen-margin slider passes a
hard-coded `range: 0 ... 64`:

- Global section `Section("Screen Margins")` (`:109`): Left `:118`, Right `:135`,
  Top `:152`, Bottom `:169`.
- Per-monitor section `Section("Monitor Screen Margins")` (`:253`): Left `:258`,
  Right `:269`, Top `:280`, Bottom `:291` (these use `OverridableSlider`, same
  `range: 0 ... 64`).

Each slider's `get` reads the **raw stored value** (`effectiveOuterGap*` →
`settings.outerGap*`, `Sources/Nehir/UI/LayoutSettingsTab.swift:24`), so a value
loaded from TOML above 64 reaches the slider — but a SwiftUI `Slider` bounded to
`0 ... 64` pins the thumb and clamps any drag to 64, so the UI cannot express or
commit anything larger. (The inner-gap slider uses `range: 0 ... 32` at `:96`,
which is why the issue is specific to outer margins.)

## Enforcement point 2 — the runtime resolver (this is what defeats the TOML edit)

`Sources/Nehir/Core/Config/SettingsStore.swift:907`:

```swift
func resolvedGapSettings(for monitor: Monitor) -> ResolvedGapSettings {
    let override = gapSettings(for: monitor)
    return ResolvedGapSettings(
        gapSize: (override?.gapSize ?? gapSize).clamped(to: 0 ... 64),
        outerGapLeft: (override?.outerGapLeft ?? outerGapLeft).clamped(to: 0 ... 64),
        outerGapRight: (override?.outerGapRight ?? outerGapRight).clamped(to: 0 ... 64),
        outerGapTop: (override?.outerGapTop ?? outerGapTop).clamped(to: 0 ... 64),
        outerGapBottom: (override?.outerGapBottom ?? outerGapBottom).clamped(to: 0 ... 64)
    )
}
```

`clamped(to:)` is `Swift.min(Swift.max(self, range.lowerBound), range.upperBound)`
(`Sources/Nehir/Core/Layout/Niri/NiriNode.swift:946`), so `120.clamped(to: 0 ... 64)`
evaluates to `64`. This clamps **both** the global value and any per-monitor
override (the `override?.x ?? x` fallback is itself clamped).

## Why the TOML workaround silently fails (the effect path)

The layout never reads the stored `outerGap*` properties directly; it goes
through the resolver, which clamps. Full chain:

1. `NiriLayoutHandler` builds the working area via
   `controller.insetWorkingFrame(for: monitor)`
   (e.g. `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1200`).
2. `WMController.insetWorkingFrame(for:)` (`Sources/Nehir/Core/Controller/WMController.swift:933`)
   calls `outerGaps(for:)` (`:501`), which is
   `resolvedGapSettings(for: monitor).outerGaps` (`:492`).
3. That resolves through `settings.resolvedGapSettings(for:)` → **clamp to 64**
   (enforcement point 2).
4. `insetWorkingFrame` turns the (already clamped) gaps into
   `Struts(left:right:top:bottom:)` (`WMController.swift:949`) and hands them to
   `computeWorkingArea(parentArea: monitor.visibleFrame, …)`, producing the
   inset `workingFrame` that Niri tiles into.

So `[gaps.outer] bottom = 120` is loaded as `120`, stored as `120`, shown to the
slider as `120` — but rendered as `64`, because step 3 collapses it before the
inset. No persistence error, no warning; the value is simply ignored past 64.

## What does NOT clamp (confirming the cap is policy, not format)

- **Stored properties.** `SettingsStore.outerGapLeft/Right/Top/Bottom`
  (`Sources/Nehir/Core/Config/SettingsStore.swift:80`) and `gapSize` (`:76`) only
  do `didSet { scheduleSave() }`; they accept and persist any `Double`.
- **Apply-from-export.** `SettingsStore.applyExport` assigns the decoded values
  verbatim (`Sources/Nehir/Core/Config/SettingsStore.swift:509`).
- **TOML codec.** `CanonicalTOMLConfig` encodes/decodes `[gaps]` / `[gaps.outer]`
  as plain `Double` with no range check (`:80`, `:283`, `:390`).

The only places `64` is enforced are enforcement points 1 and 2 above.

---

## Root cause surface

The 64 px ceiling is a magic literal, not a derived constraint. There is no
named constant; `64` is repeated as:

- 5 fields in `resolvedGapSettings` (`SettingsStore.swift:910`–`:914`),
- 8 slider `range:` literals in `LayoutSettingsTab.swift`.

Because the layout's only read path is the resolver, the resolver clamp is the
**authoritative** cap. The UI ranges are a secondary input cap that prevents the
user from even requesting more. A correct fix must touch both, otherwise:

- raise only the resolver → TOML edits above 64 start working, but the slider
  still cannot reach them (confusing: slider max < effective max);
- raise only the sliders → the resolver still collapses anything above 64, so
  dragging the slider higher has no visible effect (the exact bug the user
  already hit with the TOML workaround).

A grep across `Sources/Nehir/Core/` confirms `0 ... 64` / `clamped(to: 0 ... 64)`
appears on gap fields **only** at `SettingsStore.swift:910`–`:914`; every other
`clamped(to: 0 ... 64)`-shaped call is on unrelated indices/fractions. So there
is exactly one runtime clamp to edit.

---

## Fix surface (what a change touches)

The shipped fix uses two named bounds rather than one UI+resolver bound:

1. **Resolver / config ceiling** — `SettingsStore.resolvedGapSettings(for:)`
   now clamps `gapSize` and all four outer gaps to `GapLimits.range`, whose upper
   bound is 256. This is what makes TOML / monitor-override values above 64 take
   effect.
2. **Settings slider ceiling** — all ten gap sliders (global + per-monitor,
   inner + outer) now use `GapLimits.sliderRange`, whose upper bound is 64. This
   keeps the interactive sliders ergonomic while still rendering larger config
   values at their true value.
3. **Persistence remains unclamped** — TOML encode/decode still stores plain
   `Double` values, and the added codec regression round-trips
   `outerGapBottom = 120`.

---

## Risks and unknowns

- **New upper bound decision resolved.** The implementation chose 256 for the
  resolver/config ceiling and 64 for the Settings slider ceiling.
- **Minimum working area checked for the chosen bound.** Static review confirmed
  `computeWorkingArea` clamps working-area width/height with `max(0, ...)`, and
  runtime validation with 256 px side margins produced healthy non-degenerate
  Niri columns plus frame verification with `sizeError=0 positionError=0`.
- **Lower bound.** Currently `0` (no negative margins). The reporter only wants
  *more*, so the lower bound can stay `0`; negative outer gaps are out of scope.
- **Smart-gaps interaction.** `planned/20260621-omniwm-373-smart-gaps-single-window.md`
  zeroes outer gaps for lone windows. That path is independent of the clamp but
  should be re-checked if the bound becomes very large.

---

## What is still unknown

No blocker remains for #119. Future work could still explore a richer numeric
input for values above the 64 px slider cap, but the shipped slider labels already
render larger config values truthfully and the resolver honors them up to 256.

---

## Relationship to other work

- Completed implementation record:
  [`20260627-nehir-119-screen-margin-capped-at-64px.md`](20260627-nehir-119-screen-margin-capped-at-64px.md).
- `discovery/20260621-limit-float-precision-config-values.md` — adjacent
  config concern about the *serialization precision* of these same `[gaps]`
  fields. It explicitly lists `gaps.outer.*` as non-offenders (integer-slider
  driven) and does **not** touch the value ceiling. No overlap.
- `planned/20260621-omniwm-373-smart-gaps-single-window.md` — smart gaps; touches
  *when* outer gaps are applied (zeroed for single windows), orthogonal to *how
  large* they may be.
- Upstream issue: <https://github.com/apphane-dev/nehir/issues/119>.
