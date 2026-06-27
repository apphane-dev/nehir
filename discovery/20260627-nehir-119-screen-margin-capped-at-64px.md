# Screen margins (outer gaps) are hard-capped at 64 px in both the UI and the layout resolver — Discovery

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

The companion implementation plan is in
[`../planned/20260627-nehir-119-screen-margin-capped-at-64px.md`](../planned/20260627-nehir-119-screen-margin-capped-at-64px.md).

---

## TL;DR

- The 64 px ceiling is enforced at **two independent layers**; both must change
  to raise it.
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

Introduce a single named bound, e.g. `gapValueRange` / `maxOuterGap`, and apply
it at both layers. Concretely:

1. **Resolver** — `SettingsStore.resolvedGapSettings(for:)`
   (`SettingsStore.swift:907`): replace the literal `0 ... 64` with the named
   range. Decide the new upper bound (see open questions).
2. **UI** — the eight `range: 0 ... 64` literals in `LayoutSettingsTab.swift`
   (`:118`, `:135`, `:152`, `:169`, `:258`, `:269`, `:280`, `:291`) must use the
   same named range.
3. **(Optional) alignment** — the inner-gap slider is `0 ... 32` (`:96`) while
   the resolver allows `gapSize` up to `0 ... 64` (`SettingsStore.swift:910`).
   Decide whether to align inner-gap slider max with the resolver while here.

The slider `step` is already `1`, so a large upper bound is usable from the UI
without changing stepping. A per-edge bound is possible but unnecessary for the
reported use case.

---

## Risks and unknowns

- **New upper bound is a product decision.** Guria asked the reporter for "what
  value seems reasonable". 64 is comfortably under typical dock heights; the
  reporter's dock case likely wants ~80–120 px. Candidates: 128, 256, or simply a
  generous fixed value. Picking too low re-triggers the issue; too high is
  harmless because the user drives it explicitly.
- **Minimum working area.** A very large margin on a small/low-resolution
  display could shrink `workingFrame` below the layout's minimum column width or
  trigger degenerate tiling. `computeWorkingArea`/the Niri width solvers should
  be checked for a floor before unconditionally allowing, say, 512 px on a
  1280-wide display. Not verified here.
- **Lower bound.** Currently `0` (no negative margins). The reporter only wants
  *more*, so the lower bound can stay `0`; negative outer gaps are out of scope.
- **Smart-gaps interaction.** `planned/20260621-omniwm-373-smart-gaps-single-window.md`
  zeroes outer gaps for lone windows. That path is independent of the clamp but
  should be re-checked if the bound becomes very large.

---

## What is still unknown

- Whether `computeWorkingArea` / Niri minimum-width logic guards against an
  over-shrunk working frame once the cap is raised (a capture or a read of the
  solver floors would settle it).
- Whether anything downstream assumes outer gaps ≤ 64 (e.g. pre-park margins,
  `niriViewportPreParkMargin` at `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:402`,
  is independent and unrelated, but worth a glance).
- The maintainer's chosen new maximum (blocks picking the literal).

---

## Relationship to other work

- Companion plan:
  [`../planned/20260627-nehir-119-screen-margin-capped-at-64px.md`](../planned/20260627-nehir-119-screen-margin-capped-at-64px.md).
- `discovery/20260621-limit-float-precision-config-values.md` — adjacent
  config concern about the *serialization precision* of these same `[gaps]`
  fields. It explicitly lists `gaps.outer.*` as non-offenders (integer-slider
  driven) and does **not** touch the value ceiling. No overlap.
- `planned/20260621-omniwm-373-smart-gaps-single-window.md` — smart gaps; touches
  *when* outer gaps are applied (zeroed for single windows), orthogonal to *how
  large* they may be.
- Upstream issue: <https://github.com/apphane-dev/nehir/issues/119>.
