# BarutSRB/OmniWM#326 — Allow a Niri column over 100% width

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned
**Source discovery:** `discovery/20260617-omniwm-326-niri-column-over-100-percent-width.md`
**Upstream reference:** <https://github.com/BarutSRB/OmniWM/issues/326>
**Related:** `planned/20260621-omniwm-295-niri-window-width-preservation.md` — its
"Follow-ups" note points here; the two compose (whatever `ProportionalSize` a column
already has is preserved on move, so a future >100% capability rides along).

Source references were refreshed against main `7a025b78` on 2026-07-07. Width validation still caps at `1.0` in `Sources/Nehir/Core/Config/SettingsStore.swift:1015-1026`, and lone-window geometry still clamps to the containing frame in `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:770-787`.

## TL;DR

Nehir hard-caps every user-reachable column-width input at 100%: the preset and
default-width validators clamp to ≤1.0 (`SettingsStore.validatedPresets` / `validatedDefaultColumnWidth`),
the Settings UI `PercentTextField` ranges top out at `5 ... 100`, and "full width"
resolves to exactly `ProportionalSize.proportion(1.0)`. The layout engine itself
does **not** forbid `p > 1.0`: `ProportionalSize.resolveProportionalSpan` and
`NiriContainer.resolveSpan` only clamp to window min/max-size constraints
(`NiriNode.swift:48` / `:534`), the gesture-resize path already admits proportions
up to `NiriSizeChange.maxProportion` (`10_000`, `NiriSizeChange.swift:16`), and the
manual-override lone-window render path returns `cachedWidth` uncapped
(`NiriLayout.swift:720`). So the blocker is the validation/UI ceiling — plus one
render-path width clamp that snaps a lone >100% window back to the visible-frame
width (a second blocker the discovery asked to *verify*; verification found it
real, see "Discovery corrections / decisions" #2).

Deliver the feature in two layers:

- **Layer A — validation + UI.** Introduce one shared ceiling constant
  `SettingsStore.maxColumnWidthProportion = 3.0` and relax
  `validatedPresets` / `validatedDefaultColumnWidth` to clamp to it instead of the
  hard-coded `1.0` (keep the `0.05` lower bound). Extend the Settings UI
  `PercentTextField` ranges for the default column width and each resize preset to
  `5 ... 300` (and drop the matching `min(100, …)` in the default-width setter).
  Defaults stay ≤1.0, so >100% is purely opt-in and existing configs are unchanged.
- **Layer B — lone-window geometry.** In
  `NiriLayout.singleWindowViewportGeometry`, stop clamping an
  intentionally-overwidth lone window's width to `containingFrame.width`. Gate the
  relaxation on "the width overflow is NOT caused by the window's own min-size" so
  the existing min-size leak-prevention clamp is preserved. The viewport's shared
  snap/scroll mechanism (already wired for lone windows via
  `SingleWindowViewportGeometry.effectiveViewOffset`) then reveals the overflow.

Multi-column workspaces need Layer A only: a >1.0 column already gets its full
`cachedWidth` and rides the existing horizontal overflow-scroll path. Only the
truly lone window (1 column, 1 normal window) hits the Layer-B clamp.

## Discovery corrections / decisions

1. **Line-number drift (cosmetic, re-verified against `7a025b78`).** The discovery
   was verified against an older commit; current locations:
   - `validatedPresets(_:)` → `Sources/Nehir/Core/Config/SettingsStore.swift:975`
     (discovery said `:852`); the `min(1.0, max(0.05, $0))` map is at `:976`.
   - `validatedDefaultColumnWidth(_:)` → `SettingsStore.swift:983` (discovery said
     `:862`); clamp at `:985`.
   - `validatedLoneWindowMaxWidth(_:)` → `SettingsStore.swift:988` (discovery said
     `:866`); **not in scope** (centered lone-window feature; see Non-goals).
   - `niriColumnWidthPresets` storage → `SettingsStore.swift:53` (discovery said
     `:44`); load/merge site → `SettingsStore.swift:494` (discovery said `:478`).
   - `isFullWidth ? ProportionalSize.proportion(1) : column.width` →
     `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:72` (snapshot),
     `:490` (preset cycle), `:563` (resize compute) — discovery said `:66` / `:494`.
   - `resolveSpan` → `Sources/Nehir/Core/Layout/Niri/NiriNode.swift:534`
     (discovery said `:526`); `resolveProportionalSpan` → `NiriNode.swift:48`
     (discovery said `:42`); the min/max clamps are at `NiriNode.swift:551-552`
     (discovery said `:541`/`:543`).
   - Settings UI: the default-column-width `PercentTextField` is at
     `Sources/Nehir/UI/SettingsView.swift:431` (`range: 5 ... 100` at `:434`) and
     its binding setter clamp `Double(min(100, max(5, newPercent))) / 100.0` is at
     `SettingsView.swift:387`; the per-preset `PercentTextField` is at
     `SettingsView.swift:476` (`range: 5 ... 100` at `:479`). Discovery said
     `:357`/`:426`.
   - `singleWindowLayoutContext` →
     `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:270` (discovery said
     `:258`).
   - `hasManualSingleWindowWidthOverride` write sites →
     `NiriLayoutEngine+Sizing.swift:238` (`applyColumnWidth`), `:651`/`:662`
     (`toggleFullWidth`); discovery said `:655`/`:661`.

2. **New blocker found during verification — Layer B is required, not just a
   check.** The discovery said to *verify* that the lone-window path does not snap
   an overwidth single column back to 100%. It does:
   `NiriLayout.singleWindowViewportGeometry`
   (`Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:745`) constructs
   ```swift
   // NiriLayout.swift:770-776
   let yClampedRect = clampRect(
       CGRect(
           x: containingFrame.minX,
           y: unclampedYRect.minY,
           width: min(size.width, containingFrame.width),   // ← clamps >100% down to 100%
           height: size.height
       ),
       to: containingFrame
   )
   // NiriLayout.swift:782-792
   let overConstrained = size.width > workingFrame.width || size.height > workingFrame.height
   if overConstrained {
       rect = yClampedRect.roundedToPhysicalPixels(scale: scale)   // ← overwidth takes this branch
   } else { … }
   ```
   So a lone window set to >100% renders at exactly the containing-frame width;
   the overflow reveal the issue asks for never happens for the single-window
   case. Relaxing Layer A alone ships the feature for multi-column workspaces but
   not for the issue's primary use case (one app, wider than the screen). Layer B
   is therefore part of this plan, not a follow-up.

3. **Gate Layer B on min-size, not solely on `hasManualSingleWindowWidthOverride`.**
   The discovery suggests the manual-override flag "should gate the override."
   Taken literally that is unsafe: `applyColumnWidth`
   (`NiriLayoutEngine+Sizing.swift:238`) sets the flag for *any* manual resize, so
   a window whose own `minSize.width` exceeds the screen that the user also
   drag-resized would lose the legacy leak-prevention clamp and render offscreen.
   The correct gate is "the width overflow is **not** caused by the window's own
   min-size": `context.window.constraints.normalized().minSize.width <=
   workingFrame.width + tolerance`. This preserves the clamp exactly for min-size
   overflow while releasing it for intentional proportional >100% widths.

4. **The ceiling is a shared constant, not a new user setting.** The discovery
   floated a configurable `maxColumnWidthProportion` setting (default 1.0, up to
   3.0). That adds a TOML key, a migration, a UI control, and round-trip tests for
   a knob the issue never asks for — the request is simply "allow >100%." This
   plan uses a single `SettingsStore.maxColumnWidthProportion = 3.0` constant
   shared by both validators and the UI ranges. Nothing the user can set today can
   exceed 1.0 (the UI caps at 100%), so existing configs are all ≤1.0 and
   unaffected; a hand-edited TOML value of, say, `1.2` that currently silently
   clamps to `1.0` will now load as `1.2` (the intended new behavior). Making the
   ceiling a user-facing knob is deferred to Follow-ups.

5. **Defaults stay ≤1.0.** `BuiltInSettingsDefaults.niriColumnWidthPresets`
   (`Sources/Nehir/Core/Config/BuiltInSettingsDefaults.swift:10`, currently
   `[0.35, 0.50, 0.65, 0.95]`) is unchanged. >100% is opt-in: the user explicitly
   adds a >100% preset or drag-resizes past 100%. This keeps the default
   experience unchanged and avoids surprising existing users with an overwidth
   preset.

## Scope

### Files to add/change

1. `Sources/Nehir/Core/Config/SettingsStore.swift`
   - Add `nonisolated static let maxColumnWidthProportion: Double = 3.0` next to
     `defaultColumnWidthPresets` (`:973`), plus a convenience
     `nonisolated static var maxColumnWidthPercent: Int { Int(maxColumnWidthProportion * 100) }`
     for the UI ranges.
   - In `validatedPresets(_:)` (`:975`), replace the literal `1.0` ceiling with
     `maxColumnWidthProportion`:
     ```swift
     let result = presets.map { min(maxColumnWidthProportion, max(0.05, $0)) }
     ```
   - In `validatedDefaultColumnWidth(_:)` (`:983`), same replacement:
     ```swift
     return min(maxColumnWidthProportion, max(0.05, width))
     ```
   - Leave `validatedLoneWindowMaxWidth(_:)` (`:988`) untouched (Non-goal).

2. `Sources/Nehir/UI/SettingsView.swift`
   - In the `defaultColumnWidthPercent` binding setter (`:387`), replace
     `min(100, max(5, newPercent))` with
     `min(SettingsStore.maxColumnWidthPercent, max(5, newPercent))`.
   - Change the "Width" `PercentTextField` range (`:434`) from `5 ... 100` to
     `5 ... SettingsStore.maxColumnWidthPercent`.
   - Change each "Preset N" `PercentTextField` range (`:479`) from `5 ... 100` to
     `5 ... SettingsStore.maxColumnWidthPercent`. The preset setter
     (`current[index] = Double(newPercent) / 100.0` at `:482`) needs no clamp
     change — it relies on the field range, and `niriColumnWidthPresets` is a plain
     `var` (no auto-revalidation on assignment), consistent with today.
   - Leave the "Centered Width" field (`range: 10 ... 100` at `:461`) and its
     `loneWindowMaxWidthPercent` setter (`:485`) untouched (Non-goal).

3. `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift`
   - Add a tolerance constant on `NiriLayoutEngine` (the enclosing extension at
     `:88` owns `singleWindowViewportGeometry`): `private static let
     singleWindowOverflowTolerance: CGFloat = 0.5` (matches the feasibility
     tolerance in `LayoutRefreshController.swift:596`).
   - In `singleWindowViewportGeometry(for:in:containingFrame:scale:gaps:)`
     (`:745`), split the `overConstrained` branch so an intentional >100% width
     is preserved. Replace the block currently at `:764-792` with:
     ```swift
     let overConstrainedWidth = size.width > workingFrame.width
     let overConstrainedHeight = size.height > workingFrame.height
     // BarutSRB/OmniWM#326: a lone window wider than the working frame because the user
     // set a >100% proportional width is intentional overflow the viewport scrolls
     // to reveal — not a min-size leak to suppress. Only the window's own min-width
     // forcing the overflow keeps the legacy containing-frame clamp.
     let minWidthForcesOverflow =
         context.window.constraints.normalized().minSize.width
             > workingFrame.width + Self.singleWindowOverflowTolerance

     let unclampedYRect = CGRect(
         x: workingFrame.minX,
         y: workingFrame.minY,
         width: size.width,
         height: size.height
     )
     let yClampedRect = clampRect(
         CGRect(
             x: containingFrame.minX,
             y: unclampedYRect.minY,
             width: min(size.width, containingFrame.width),
             height: size.height
         ),
         to: containingFrame
     )
     let rect: CGRect
     if overConstrainedWidth && !minWidthForcesOverflow {
         // Intentional >100% width: keep the full width, anchor at the working-frame
         // origin, reuse the vertical clamp. The shared snap/scroll mechanism reveals
         // the overflow; centerOffset centers it initially.
         rect = CGRect(
             x: workingFrame.minX,
             y: yClampedRect.minY,
             width: size.width,
             height: yClampedRect.height
         ).roundedToPhysicalPixels(scale: scale)
     } else if overConstrainedWidth || overConstrainedHeight {
         // Min-size overflow (or height-only overflow): legacy clamp so an
         // over-constrained window does not leak offscreen.
         rect = yClampedRect.roundedToPhysicalPixels(scale: scale)
     } else {
         rect = CGRect(
             x: workingFrame.minX,
             y: yClampedRect.minY,
             width: size.width,
             height: size.height
         ).roundedToPhysicalPixels(scale: scale)
     }
     ```
   - `resolvedSingleWindowWidth` (`:707`) is unchanged: it already returns
     `max(0, context.container.cachedWidth)` for manual overrides (`:720`), which
     is what lets a >100% `cachedWidth` reach this geometry function. The non-manual
     branch (`workingFrame.width * maxWidthFraction.clamped(to: 0...1)` at `:717`)
     stays capped at 100% — correct, because a non-manual lone window follows the
     fill/centered policy, not a user >100% choice.

4. `Tests/NehirTests/SettingsStoreTests.swift` — update the two tests that encode
   the old ≤1.0 cap (see `## Tests`).
5. `Tests/NehirTests/NiriLayoutEngineTests.swift` — add the Layer-A regression
   guard and the Layer-B geometry tests (see `## Tests`).

### Non-goals

- Do **not** raise the centered lone-window ceiling. `validatedLoneWindowMaxWidth`
  (`SettingsStore.swift:988`) and the "Centered Width" UI (`SettingsView.swift:461`/`:485`)
  stay capped at 100%. Centering a window wider than the screen is a different
  feature; the issue is about *columns*.
- Do **not** change "full width." `toggleFullWidth`
  (`NiriLayoutEngine+Sizing.swift:626`) still resolves to `proportion(1.0)`; >100%
  is reached via presets or drag-resize, not the full-width toggle.
- Do **not** change `BuiltInSettingsDefaults.niriColumnWidthPresets`. Defaults
  stay ≤1.0; >100% is opt-in.
- Do **not** add a user-facing "max column width" setting/TOML key/migration. The
  ceiling is a compile-time constant (see "Discovery corrections" #4).
- Do **not** alter the engine's proportional math (`resolveProportionalSpan`,
  `resolveSpan`) or the gesture-resize clamp (`NiriSizeChange.maxProportion`); they
  already permit >1.0.
- Do **not** change window min/max-size constraint handling. An app declaring
  `maxSize.width < requested` still clamps down via `resolvedSingleWindowSize →
  constraints.clampWidth` (`NiriLayout.swift:725-731`) and `resolveSpan`
  (`NiriNode.swift:551-552`); an app whose `minSize.width > screen` still hits the
  legacy leak-prevention clamp. Both are expected.
- Do **not** build a new scroll mechanism. The viewport snap/scroll path is
  already shared with regular columns (`SingleWindowViewportGeometry.effectiveViewOffset`,
  `NiriLayout.swift:65-74`); Layer B only stops suppressing the width.

## Exact implementation plan

### Phase 1 — Raise the validation ceiling (Layer A, config)

1. Open `Sources/Nehir/Core/Config/SettingsStore.swift`. Immediately after
   `defaultColumnWidthPresets` (`:973`), add `maxColumnWidthProportion` (`3.0`)
   and the `maxColumnWidthPercent` computed helper.
2. In `validatedPresets(_:)` (`:975`), swap the `1.0` literal for
   `maxColumnWidthProportion`.
3. In `validatedDefaultColumnWidth(_:)` (`:983`), same swap.
4. Build: `swift build`.

### Phase 2 — Extend the Settings UI (Layer A, UI)

1. Open `Sources/Nehir/UI/SettingsView.swift`.
2. In the `defaultColumnWidthPercent` setter (`:387`), replace `100` with
   `SettingsStore.maxColumnWidthPercent`.
3. Change the two `PercentTextField` ranges (`:434` default width, `:479` presets)
   from `5 ... 100` to `5 ... SettingsStore.maxColumnWidthPercent`.
4. Build: `swift build`. Launch Settings → Niri → confirm the "Width" and "Resize
   Presets" fields now accept values up to 300.

### Phase 3 — Preserve an overwidth lone window's width (Layer B, geometry)

1. Open `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift`. Add
   `singleWindowOverflowTolerance = 0.5` to the `NiriLayoutEngine` extension.
2. In `singleWindowViewportGeometry` (`:745`), replace the `:764-792` block with
   the three-branch version in `Scope` above.
3. Build: `swift build`.

### Phase 4 — Tests

Add/Update tests per `## Tests`, then run the `## Validation` commands.

### Phase 5 — Manual end-to-end check

On a single monitor: add a resize preset of 150%, cycle a lone managed window to
it, confirm the window renders ~1.5× the working width with horizontal scroll
revealing the rightward overflow; confirm a second window in another column at
≤100% is unchanged; confirm a min-size-heavy app still clamps (no offscreen leak).

## Tests

### `Tests/NehirTests/SettingsStoreTests.swift` (update existing — they encode the old cap)

1. **`validatedPresetsPreserveOrderAndDuplicatesWhileClamping`** (`:349`).
   Currently asserts
   `validatedPresets([0.85, 0.02, 0.85, 1.2]) == [0.85, 0.05, 0.85, 1.0]`.
   After Layer A the `1.2` is below the 3.0 ceiling and no longer clamps. Update
   the expectation to `[0.85, 0.05, 0.85, 1.2]`, and add a clamp-at-ceiling case:
   `validatedPresets([0.3, 1.0, 1.5, 3.0, 5.0])` → `[0.3, 1.0, 1.5, 3.0, 3.0]`
   (lower bound preserved, upper bound clamped to 3.0). Locks in: the new ceiling
   and the unchanged lower bound.
2. **`validatedDefaultColumnWidthClampsAndSupportsAuto`** (`:371`).
   Currently asserts `validatedDefaultColumnWidth(1.2) == 1.0`. Update to
   `== 1.2`, keep `validatedDefaultColumnWidth(0.02) == 0.05`, and add
   `validatedDefaultColumnWidth(3.5) == 3.0` (ceiling clamp) plus
   `validatedDefaultColumnWidth(nil) == nil`. Locks in: auto stays `nil`, the
   lower bound is unchanged, the new ceiling clamps.
3. `settingsStoreRoundTripsOrderedDuplicatePresets` (`:359`) and
   `settingsStoreRoundTripsOptionalDefaultColumnWidth` (`:376`) stay green without
   edits (they use ≤1.0 values). Add one round-trip case asserting a >1.0 preset
   survives a save/reload cycle (e.g. `[0.5, 1.5]`) to lock in that the TOML path
   does not re-impose a ≤1.0 clamp elsewhere.

### `Tests/NehirTests/NiriLayoutEngineTests.swift` (add)

Use the same fixtures as the nearby single-window tests (`NiriLayoutEngine(balancedColumnCount: 3)`,
`makeTestHandle()`, one window in one workspace, the `settledLayoutState(from:column:settleTime:)`
helper used at `:1316`).

1. **`validatedPresetsOver100RenderLoneWindowWiderThanWorkingFrame`**
   - Build a single-window workspace. Set
     `column.width = .proportion(1.5)`, `column.hasManualSingleWindowWidthOverride = true`,
     then `column.resolveAndCacheWidth(workingAreaWidth: monitor.visibleFrame.width, gaps: gap)`.
   - Compute the settled layout and read the window frame.
   - Expect `frame.width` ≈ `1.5 * monitor.visibleFrame.width` (minus gap
     accounting, within `~2px`), i.e. **wider** than the working frame, not clamped
     to it. Locks in: Layer B — a >100% lone window renders at its full width.
2. **`loneWindowOver100RevealsOverflowViaViewportOffset`**
   - Same setup as (1). Seed the viewport from
     `engine.prepareAndSeedSingleWindowViewport(...)` (the existing seam at
     `NiriLayout.swift:856`) so `viewOffset = centerOffset`.
   - Set `state.viewOffsetPixels` to a gesture offset that scrolls right by
     `frame.width - monitor.visibleFrame.width + gap` and recompute the rendered
     rect via `singleWindowViewportGeometry(...).renderedRect(viewOffset:…)`.
   - Expect the rendered rect's right edge is now within the visible frame (the
     overflow is reachable by scroll). Locks in: the shared viewport offset is
     applied to an overwidth lone window, so scroll reveals the overflow.
3. **`loneWindowManualWidthAtOrUnder100StaysCentered`** (regression guard)
   - Single window, `column.width = .proportion(0.5)`,
     `hasManualSingleWindowWidthOverride = true`.
   - Expect the rendered frame width ≈ `cachedWidth` and
     `frame.midX ≈ monitor.visibleFrame.midX` (mirrors the existing assertion at
     `NiriLayoutEngineTests.swift:1331-1334`). Locks in: Layer B does not alter the
     ≤100% manual-override path (the `else` branch).
4. **`minSizeOverflowLoneWindowStillClampedToContainingFrame`** (regression guard)
   - Single window whose `constraints.minSize.width > monitor.visibleFrame.width`
     (e.g. min 2500 on a 2000-wide frame). Set a manual override so the
     `minWidthForcesOverflow` predicate is the deciding factor.
   - Expect the rendered frame width ≤ `monitor.visibleFrame.width` (the legacy
     clamp still fires). Locks in: Layer B's min-size gate preserves the leak
     prevention.
5. **`multiColumnWorkspaceRendersOverwidthColumnWithoutClamp`** (Layer A suffices
   for multi-column)
   - Two columns; set one to `.proportion(1.5)` with a manual override, the other
     to `.proportion(0.5)`. Resolve and compute the multi-column layout.
   - Expect the 1.5 column's frame width ≈ its `cachedWidth` (uncapped), the 0.5
     column unchanged, and the two frames' combined width to exceed the working
     frame (overflow that the existing multi-column scroll reveals). Locks in:
     multi-column >100% works via Layer A alone.

## Validation

```bash
swift build

# Layer A: validators + round-trip
swift test --filter SettingsStoreTests/validatedPresetsPreserveOrderAndDuplicatesWhileClamping
swift test --filter SettingsStoreTests/validatedDefaultColumnWidthClampsAndSupportsAuto
swift test --filter SettingsStoreTests/settingsStoreRoundTrips
swift test --filter SettingsTOMLCodecTests

# Layer B + multi-column regression
swift test --filter NiriLayoutEngineTests/validatedPresetsOver100RenderLoneWindowWiderThanWorkingFrame
swift test --filter NiriLayoutEngineTests/loneWindowOver100RevealsOverflowViaViewportOffset
swift test --filter NiriLayoutEngineTests/loneWindowManualWidthAtOrUnder100StaysCentered
swift test --filter NiriLayoutEngineTests/minSizeOverflowLoneWindowStillClampedToContainingFrame
swift test --filter NiriLayoutEngineTests/multiColumnWorkspaceRendersOverwidthColumnWithoutClamp

# Whole-engine Niri suite (catches accidental regressions in sizing/viewport paths)
swift test --filter NiriLayoutEngineTests
```

Manual validation (default lone-window `.fill` policy):

1. Settings → Niri → Resize Presets → set one preset to **150%** (confirm the field
   accepts it; the "Width" default field should also accept up to 300%).
2. In a workspace with a single managed window, cycle column width (the
   `toggleColumnWidth` hotkey/gesture) until the 150% preset is active.
3. Confirm the window renders ~1.5× the monitor's working width, anchored left,
   with its right portion initially beyond the visible edge.
4. Scroll the viewport horizontally (gesture/trackpad) and confirm the rightward
   overflow is revealed and re-snaps.
5. Add a second window so the workspace has two columns; set one to 150% and the
   other to 50%. Confirm the 150% column overflows and scrolls, the 50% column is
   unchanged, and cycling/presets behave normally.
6. Open an app with a large declared `maxSize.width` and assign it a 150% preset:
   confirm it clamps down to the app's max (expected). Open an app whose
   `minSize.width` exceeds the screen: confirm it still clamps to the visible frame
   (no offscreen leak — Layer B regression guard).
7. Confirm `validatedDefaultColumnWidth(nil)` still yields the balanced/auto
   default (no behavior change for users who never touch the width).

Changeset (minor): "Allow Niri columns wider than 100% of the working area, with
horizontal scroll reveal (BarutSRB/OmniWM#326)."

## Risks and mitigations

- **Snap-grid range for a single overwidth column.** The viewport's snap points
  come from column boundaries; a single >100% column has few snap points, so the
  scrollable range may be tight. Mitigation: `effectiveViewOffset`
  (`NiriLayout.swift:65-74`) and `seedSingleWindowCenterOffsetIfNeeded`
  (`:840`) already seed `viewOffset = centerOffset` from a zero state, centering
  the overwidth window initially so overflow is reachable on both sides. If manual
  testing shows the snap range too tight, extend `viewportStartBounds`/snap-point
  generation for the single-column case as a follow-up — **not** in this plan.
- **Min-size gate false negatives.** If an app reports a `minSize.width` just
  under the screen but a `maxSize.width` that clamps the requested >100% width
  down, the window will render at the app's max, not the requested width.
  Expected (matches discovery and the issue's use case: apps with their own splits
  generally do not over-constrain max width). Document in the release note; no
  mitigation needed.
- **Existing tests encode the old ≤1.0 cap.** `validatedPresetsPreserveOrderAndDuplicatesWhileClamping`
  and `validatedDefaultColumnWidthClampsAndSupportsAuto` explicitly assert `1.2 → 1.0`.
  They are updated (not deleted) to assert the new ceiling; the lower-bound and
  fallback assertions are preserved so the clamp shape stays covered.
- **Centering assertion regression.** The existing single-window manual-override
  test (`NiriLayoutEngineTests.swift:~1290-1335`) asserts `frame.midX ==
  visibleFrame.midX` for a ≤100% width. Layer B's `else` branch leaves that path
  untouched, so the assertion holds. Add the explicit
  `loneWindowManualWidthAtOrUnder100StaysCentered` guard to lock it in.
- **Offscreen leak via the wrong branch.** If the `minWidthForcesOverflow`
  predicate is inverted, a min-size-heavy lone window would render offscreen.
  Mitigation: the `minSizeOverflowLoneWindowStillClampedToContainingFrame` test
  pins the legacy clamp for the min-size case.
- **`niriColumnWidthPresets` is a plain `var`.** Assignment does not re-validate,
  so a >1.0 value typed in the UI flows straight to the engine. This is the
  intended path; the `PercentTextField` range is the UI clamp. If a future change
  auto-validates on assignment, re-confirm the ceiling is consulted there.
- **Backward compatibility for hand-edited configs.** A TOML value between 1.0 and
  3.0 that previously clamped silently to 1.0 now loads as-is. This is the feature
  behaving as requested; note it in the changelog so it is not reported as a bug.

## Follow-ups (out of scope)

- A user-facing "max column width" setting/TOML key (the discovery's configurable
  knob) if field feedback wants a per-user ceiling different from 3.0.
- Allowing the **centered** lone-window policy to exceed 100% (would need
  `validatedLoneWindowMaxWidth` and the "Centered Width" UI raised, plus geometry
  work for a centered-but-overwidth window). Separate feature; the issue is about
  columns.
- Tuning the snap/scroll range for a single overwidth column if manual testing
  finds the reachable scroll range too tight (see Risks).
- Per-app initial column width (BarutSRB/OmniWM#283,
  `discovery/20260617-omniwm-283-per-app-initial-column-width.md`) composes with
  this at column *creation*; it stays a separate task.
