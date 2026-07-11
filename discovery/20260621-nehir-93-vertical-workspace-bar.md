# nehir #93 / BarutSRB/OmniWM#255 — "Vertical workspace bar" — Discovery

Groom 2026-07-07: still applicable — open greenfield enhancement; `WorkspaceBarPosition` still has only the two top-edge cases (`overlappingMenuBar`/`belowMenuBar`) and no left/right-edge or orientation concept exists (verified against main 7a025b78).

Source issues:
- nehir (local tracker): <https://github.com/apphane-dev/nehir/issues/93>
- upstream origin: <https://github.com/BarutSRB/OmniWM/issues/255>

nehir #93 is the local tracker for this feature. Its entire body is a pointer to
upstream BarutSRB/OmniWM#255 ("Issue reported in OmniWM pre 0.4.8 release, closed as
cleanup without validation"), quoting the upstream reporter @yougotwill: *"Title
says it all. I might try and contribute a PR for this once the Zig port is
complete as I'm hoping it might be easier for me than in Swift."* The two issues
are the same feature request — there is no independent content in #93 — so this
single document covers both. nehir #93 is labeled `enhancement` and
`omniwm-cleanup`; upstream BarutSRB/OmniWM#255 is labeled `enhancement`.

Scope of this doc: determine whether nehir already has any vertical (left/right
screen-edge) workspace bar support; if not, map the architecture a vertical
orientation would touch, identify the clean seams, and scope the work. This is a
discovery / feasibility doc — no code is changed here.

All file/line references were verified against `main` at `6ba6760f` ("Surface
attribution across About, nehirctl, and source headers") on 2026-06-21.
**Re-verify before implementing; line numbers drift.** Verdict is by code
inspection (no runtime trace).

---

## TL;DR

- **nehir does not implement a vertical workspace bar.** The workspace bar is
  horizontal and top-edge-only by construction: the position enum has exactly two
  cases, both top-edge (`overlappingMenuBar`, `belowMenuBar`); the bar view body
  is an `HStack`; the geometry hardcodes a horizontally-centered, top-anchored
  frame; and the only screen-edge layout coupling is a *top* inset. There is no
  latent/hidden vertical path to flip on.
- **Verdict:** 🟡 **Open enhancement / greenfield** — not a bug port (no upstream
  diff exists; BarutSRB/OmniWM#255 was "title says it all", closed as a pre-0.4.8 triage
  cleanup). Correctly labeled `enhancement`. The feature is feasible and
  well-scoped: the niri working-area model already has per-edge struts
  (`left`/`right`/`top`/`bottom`), so the layout-coupling change is *populating*
  the left/right struts, not inventing them.
- **Cleanest seam:** introduce an orientation concept at `WorkspaceBarPosition`
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:43`) and propagate it
  through four concentrated sites — (1) the view layout axis, (2) the frame
  geometry, (3) the reserved-inset → niri-strut coupling in `WMController`, and
  (4) the settings/persistence surface. The hardest correctness requirement is
  #3: tiles must not underlap a vertical bar when `reserveLayoutSpace` is on.

## Provenance: is this nehir's code?

Yes. The workspace bar is implemented entirely in-tree under
`Sources/Nehir/UI/WorkspaceBar/`, with settings in `Sources/Nehir/Core/Config/`
and the layout-space reservation in `Sources/Nehir/Core/Controller/WMController.swift`:

```
Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift         <- position enum, panel lifecycle, frame application
Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift        <- frame math, reserved-inset derivation
Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift            <- SwiftUI bar body (HStack), measurement view
Sources/Nehir/UI/WorkspaceBar/WorkspaceBarPanel.swift           <- NSPanel frame constraint
Sources/Nehir/UI/WorkspaceBar/WorkspaceBarProjectionOptions.swift
Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift
Sources/Nehir/UI/WorkspaceBarSettingsTab.swift                  <- settings UI (position picker)
Sources/Nehir/Core/Config/MonitorBarSettings.swift              <- ResolvedBarSettings + per-monitor Codable settings
Sources/Nehir/Core/Config/SettingsStore.swift                   <- global bar settings
Sources/Nehir/Core/Config/SettingsExport.swift                  <- export DTO + defaults
Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift             <- [workspaceBar] TOML round-trip
Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift        <- per-monitor override TOML
Sources/Nehir/Core/Controller/WMController.swift                <- reserved-inset → niri working-area struts
Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift           <- Struts + computeWorkingArea
Sources/Nehir/UI/Onboarding/Animations/WorkspaceBarAnimation.swift  <- onboarding animation (cosmetic)
```

There is no second bar implementation; this is the only workspace bar path.

## The code in question

### 1. Position enum — two top-edge cases, no left/right

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:43-57
enum WorkspaceBarPosition: String, CaseIterable, Identifiable {
    case overlappingMenuBar
    case belowMenuBar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overlappingMenuBar: "Overlapping Menu Bar"
        case .belowMenuBar: "Below Menu Bar"
        }
    }
}
```

Both cases are top-edge slots. There is no concept of a screen *edge* (left/right)
or an *axis* (horizontal/vertical). This enum is the natural place to introduce
the vertical orientation (see Open decision A).

### 2. Geometry — top-anchored, horizontally centered, width fit-to-content

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:31-44
func frame(
    fittingWidth: CGFloat,
    monitor: Monitor,
    resolved: ResolvedBarSettings
) -> CGRect {
    let width = max(fittingWidth, 300)                       // long axis = horizontal; min 300
    var x = monitor.frame.midX - width / 2                   // horizontally CENTERED
    var y = effectivePosition == .belowMenuBar
        ? monitor.visibleFrame.maxY - barHeight              // top edge, below menu bar
        : monitor.visibleFrame.maxY                          // top edge, overlapping

    x += CGFloat(resolved.xOffset)
    y += CGFloat(resolved.yOffset)

    return CGRect(x: x, y: y, width: width, height: barHeight)
}
```

`barHeight` (the bar's short-axis / vertical thickness, from `resolved.height`,
default `24.0`) is the only dimension plumbed through as a setting. The long-axis
extent (`width`) is measured from content (`fittingWidth`) with a `max(…, 300)`
floor. A vertical bar inverts both: the short axis becomes horizontal thickness,
the long axis becomes measured height, and the anchor moves from
`visibleFrame.maxY` to `visibleFrame.minX` (left edge) or `maxX - thickness`
(right edge).

The notch-aware override is also top-edge-specific:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:48-56
static func effectivePosition(for monitor: Monitor, resolved: ResolvedBarSettings) -> WorkspaceBarPosition {
    if monitor.hasNotch, resolved.notchAware, resolved.position == .overlappingMenuBar {
        return .belowMenuBar
    }
    return resolved.position
}
```

This logic ("overlap → drop below when there is a notch") has no meaningful
analogue for a left/right edge and must be given its own policy for vertical bars
on notched screens (see Open decision B).

### 3. Reserved-space coupling — top strut only (the correctness crux)

The bar can optionally reserve layout space so tiles do not underlap it. Today
this is modeled as a single *top* inset:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:13, :24, :28-30
struct WorkspaceBarGeometry: Equatable {
    let effectivePosition: WorkspaceBarPosition
    let menuBarHeight: CGFloat
    let barHeight: CGFloat
    let reservedTopInset: CGFloat
    ...
    let reservedTopInset = isVisible && resolved.reserveLayoutSpace ? barHeight : 0
```

`WMController.insetWorkingFrame` consumes that inset and turns it into the niri
tiling working area:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:789-826
func insetWorkingFrame(for monitor: Monitor) -> CGRect {
    ...
    let reservedTopInset = WorkspaceBarGeometry.resolve(
        monitor: monitor, resolved: resolved,
        isVisible: isWorkspaceBarVisible(on: monitor, resolved: resolved)
    ).reservedTopInset
    return insetWorkingFrame(from: monitor.visibleFrame, scale: scale,
                             reservedTopInset: reservedTopInset, outerGaps: outerGaps(for: monitor))
}

func insetWorkingFrame(from frame: CGRect, scale: CGFloat = 2.0,
                       reservedTopInset: CGFloat = 0, outerGaps: LayoutGaps.OuterGaps? = nil) -> CGRect {
    let outer = outerGaps ?? workspaceManager.outerGaps
    let struts = Struts(
        left: outer.left,
        right: outer.right,
        top: outer.top + reservedTopInset,     // <- only `top` receives the bar reservation
        bottom: outer.bottom)
    return computeWorkingArea(parentArea: frame, scale: scale, struts: struts)
}
```

**Favorable finding:** the underlying niri strut model is already per-edge —
`Struts(left:right:top:bottom:)` at `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:92-98`,
applied by `computeWorkingArea(parentArea:scale:struts:)` at `:101`, which
subtracts each edge independently. So the fix here is to derive a
`reservedLeadingInset`/`reservedTrailingInset` from the geometry and route them
into `struts.left` / `struts.right` for a vertical bar — no new strut machinery
is required. This is the single most important correctness change: without it, a
left/right-edge bar with `reserveLayoutSpace = true` would reserve space at the
*top* (wrong edge) and tiles would underlap the vertical bar.

### 4. View — `HStack` body, width is the measured dimension

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:190-249
var body: some View {
    HStack(spacing: workspaceSpacing) {            // <- horizontal row of workspace pills
        ForEach(snapshot.items, id: \.id) { item in WorkspaceItemView(...) }
        ...                                        // scratchpad, trace button, diagnostics, command palette
    }
    .padding(.horizontal, 4)
    .frame(height: itemHeight + 4)                 // <- fixed short-axis (height), variable long axis
    .background { ... }                            // barShape = RoundedRectangle(cornerRadius: 8)
}
```

The measurement counterpart drives the `fittingWidth` used by the geometry:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:420-424
func measuredWidth(for snapshot: ..., using measurementView: NSHostingView<WorkspaceBarMeasurementView>) -> CGFloat {
    measurementView.rootView = WorkspaceBarMeasurementView(snapshot: snapshot)
    measurementView.layoutSubtreeIfNeeded()
    return measurementView.fittingSize.width       // <- measures the LONG (horizontal) axis
}
```

A vertical bar needs the body axis flipped to `VStack` for the vertical case and
the measurement to report `fittingSize.height` instead of `.width`. The
`WorkspaceBarMeasurementView` at `WorkspaceBarView.swift:122` is a parallel
layout used only for sizing, so both views must flip together. `cornerRadius: 8`
on the pill/background is orientation-agnostic.

### 5. Settings surface (the wiring to add)

The position setting is read from a Codable enum string and flows through five
layers. Any new orientation value must be added at every layer or it will not
round-trip:

| Layer | File:line | Role |
|---|---|---|
| Global store | `Sources/Nehir/Core/Config/SettingsStore.swift:189-190` | `workspaceBarPosition` typed property |
| Export DTO + defaults | `Sources/Nehir/Core/Config/SettingsExport.swift:57`, `:143` | `workspaceBarPosition: String`, default `"overlappingMenuBar"` |
| Canonical TOML (read) | `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:310` | `position: export.workspaceBarPosition` |
| Canonical TOML (write) | `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:403` | `workspaceBarPosition: workspaceBar.position` |
| Per-monitor override | `Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift:222` | `bar["position"].flatMap { WorkspaceBarPosition(rawValue:) }` |
| Per-monitor model | `Sources/Nehir/Core/Config/MonitorBarSettings.swift:24`, `:93`, `:134` | `position: WorkspaceBarPosition?` + resolved default |
| Settings UI | `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift:103-110`, `:344-352` | global Picker + `OverridablePicker` iterating `WorkspaceBarPosition.allCases` |

Because the settings-tab pickers iterate `WorkspaceBarPosition.allCases`, **adding
new enum cases auto-populates both the global and per-monitor pickers for free**
— but only if orientation is modeled as new cases on this enum (Open decision A).
A separate `orientation` enum would need its own picker and DTO field.

The existing tunables that interact with a vertical bar: `height` (short-axis
thickness; see Open decision D), `xOffset`/`yOffset` (applied in `frame(...)`
after anchoring — meaningful for both axes), `notchAware` (top-edge-specific
policy today; see Open decision B), `reserveLayoutSpace` (gates the inset in
section 3), `backgroundOpacity`, accent/text color (orientation-agnostic).

## Why it does not apply yet (and is not a bug)

Upstream BarutSRB/OmniWM#255 carries no diff and no reproduction — it is a one-line feature
request ("Title says it all") closed as part of a pre-0.4.8 triage cleanup, not
because it was built. nehir #93 mirrors it verbatim. There is therefore nothing
to *port*; this is net-new feature work. Nothing in nehir's current bar path is
"wrong for vertical" — it simply has no vertical path. The `omniwm-cleanup` label
on #93 should not be read as "resolved": like the other `omniwm-cleanup`-tagged
issues ported into nehir planning (e.g. the BarutSRB/OmniWM#240 focus-previous study), it marks
an upstream item dropped during triage that nehir may pick up on its own merits.

## What a vertical bar requires (implementation map)

Ranked by how concentrated / mechanical vs. decision-heavy the change is.

1. **Orientation model (decision A).** Either add `.leftEdge` / `.rightEdge` to
   `WorkspaceBarPosition` (`WorkspaceBarManager.swift:43`) and derive the axis
   from the case, or introduce a separate `WorkspaceBarOrientation` enum plumbed
   through the settings surface in section 5. The former is less wiring (pickers
   auto-populate); the latter keeps "which top-edge slot" and "which edge" cleanly
   orthogonal.

2. **View axis flip.** Make `WorkspaceBarView.body` (`:191`) and
   `WorkspaceBarMeasurementView` (`:122`) choose `HStack` vs `VStack` (and
   `.frame(height:)` vs `.frame(width:)` for the short axis) based on the
   resolved orientation. Report `fittingSize.width` or `.height` from
   `measuredWidth` (`WorkspaceBarManager.swift:424`) accordingly. Consider
   renaming to `measuredLength` to stay axis-neutral.

3. **Geometry rewrite.** Generalize `WorkspaceBarGeometry.frame(...)`
   (`:31-44`): for a vertical orientation, anchor `x` to
   `monitor.visibleFrame.minX` (left) or `maxX - thickness` (right), set the
   short axis to `barHeight` (thickness), and make the long axis the
   content-measured dimension with the existing `max(…, 300)` floor applied along
   that axis. Decide long-axis anchoring (centered vs. top-aligned — see decision
   C). Generalize `effectivePosition`/notch handling (decision B).

4. **Reserved-inset coupling (correctness-critical).** Replace the single
   `reservedTopInset` with per-edge reservation, and have
   `WMController.insetWorkingFrame` (`:814-825`) populate `struts.left` or
   `struts.right` (not `top`) when the bar is vertical and `reserveLayoutSpace`
   is on. `Struts` (`NiriLayoutEngine.swift:92`) already supports all four edges,
   so this is routing, not new modeling. This is what prevents tiles from
   underlapping the vertical bar.

5. **Settings + persistence.** Add the new value(s) through every row of the
   table in section 5 so the choice survives export/import, TOML round-trip, and
   per-monitor override. Update `ResolvedBarSettings.defaults`
   (`MonitorBarSettings.swift`) and `SettingsExport` defaults (`:143`).

6. **Panel / window level.** `WorkspaceBarPanel.constrainFrameRect`
   (`WorkspaceBarPanel.swift`) already clamps the frame to the screen for both
   axes, so no change is strictly required there, but re-test that a tall
   vertical bar clamps correctly on short displays.

7. **Onboarding animation (cosmetic).** `WorkspaceBarAnimation.swift` renders the
   bar as an `HStack` (`:84`, `:109`, `:168`). This is onboarding-only eye candy
   and not a blocker, but should be flipped for consistency once the real bar
   supports vertical.

## Open decisions for the maintainer

- **A. Axis model.** New `WorkspaceBarPosition` cases (`.leftEdge`/`.rightEdge`)
  vs. a separate `WorkspaceBarOrientation`. Recommend new position cases for
  minimal settings wiring and because "position" already means "where on the
  screen edge".
- **B. Notch policy for vertical.** `effectivePosition` today only handles the
  top-edge notch overlap. For a vertical bar on a notched MacBook, decide:
  ignore the notch entirely (bar sits at the screen corner), or shorten the bar's
  long axis to avoid the notch height region. Recommend ignore-the-notch as the
  v1 (simplest), revisit if it looks bad.
- **C. Long-axis anchor.** Horizontally the bar is centered
  (`monitor.frame.midX - width/2`). For vertical: vertically centered, or
  top-aligned (below any future top bar / menu bar), or bottom-aligned? Recommend
  top-aligned by default with `yOffset` already available for adjustment.
- **D. `height` semantics.** Today `height` (default `24.0`) is the bar's
  short-axis thickness and is consumed as the reserve-inset magnitude (section
  3). For a vertical bar the short axis is horizontal width. Recommend keeping
  `height` as the *short-axis thickness* in both orientations (so
  `reserveLayoutSpace` continues to use it directly as the strut magnitude), and
  letting the long axis be content-measured — do **not** repurpose `height` to
  mean long-axis length.

## Suggested tests

- **Geometry: left/right-edge frame.** For a vertical orientation, assert
  `WorkspaceBarGeometry.frame(...)` anchors `x` to `visibleFrame.minX` (left) or
  `maxX - thickness` (right), short axis == `height`, long axis ==
  `max(fittingLength, 300)`. Mirror the existing horizontal-centering assertion.
- **Reserved inset routes to the correct edge.** With a vertical bar and
  `reserveLayoutSpace = true`, assert `WMController.insetWorkingFrame(for:)`
  shrinks the niri working area on the *matching* side (left/right), not on top.
  With a horizontal bar, assert the top inset is unchanged (regression guard).
- **Round-trip persistence.** Assert the new orientation value survives
  `SettingsExport` → `CanonicalTOMLConfig` encode/decode and the per-monitor
  override store (`MonitorOverrideFileStore`), including the unknown-key
  round-trip guarantees studied in `discovery/20260616-omniwm-410-…`.
- **Per-monitor override independence.** A vertical bar on monitor A must not
  force monitor B vertical (the per-monitor `position` override path at
  `MonitorBarSettings.swift:24` / `MonitorOverrideFileStore.swift:222`).
- **View axis.** A snapshot test (or `WorkspaceBarMeasurementView` sizing test)
  that a vertical bar's measured long dimension is height, not width.

## Reproduction / verification commands

Re-verify the architecture before implementing:

```bash
# Position enum — confirm only two top-edge cases
rg -n 'enum WorkspaceBarPosition|case overlappingMenuBar|case belowMenuBar' \
   Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift

# Geometry — top-anchored, centered, width fit-to-content
rg -n 'func frame\(|midX - width|max\(fittingWidth|visibleFrame\.maxY' \
   Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift

# Reserved-inset → niri strut coupling (the correctness crux)
rg -n 'reservedTopInset|Struts\(|top: outer\.top \+|left: outer\.left|right: outer\.right' \
   Sources/Nehir/Core/Controller/WMController.swift Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift

# View axis + measurement
rg -n 'HStack\(spacing: workspaceSpacing\)|\.frame\(height: itemHeight|fittingSize\.width' \
   Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift

# Full settings-wiring surface for `position`
rg -n 'workspaceBarPosition|WorkspaceBarPosition\.allCases|bar\["position"\]' \
   Sources/Nehir/Core/Config/ Sources/Nehir/UI/WorkspaceBarSettingsTab.swift
```

The defining evidence is that `WorkspaceBarPosition` has no left/right case,
`WorkspaceBarGeometry.frame(...)` anchors only to the top edge and centers only
horizontally, and `WMController.insetWorkingFrame` feeds the bar reservation
exclusively into `Struts.top` — while `Struts` itself already supports all four
edges, so the layout-coupling fix is routing, not new modeling.
