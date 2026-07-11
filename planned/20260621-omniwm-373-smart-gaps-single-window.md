# BarutSRB/OmniWM#373 — Smart gaps (drop outer gaps for a lone window)

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned
**Source discovery:** `discovery/20260617-omniwm-373-smart-gaps-single-window.md`
**Upstream reference:** <https://github.com/BarutSRB/OmniWM/issues/373> (feature request; Hyprland `gaps_when_only`, i3 `smart_gaps`)

All source references were re-verified against the main Nehir source tree on
2026-06-21. Re-verify before editing; line numbers drift.

## TL;DR

Nehir has no "smart gaps": a lone tiled window is placed inside the
outer-gap-insetted working frame, so configured screen margins still surround it.
Inner gaps are already correct (one window has no neighbors). The only missing
piece is dropping the **outer** gaps when a workspace has exactly one normal tiled
window, and restoring them when a second appears.

Add a global boolean toggle `removeOuterGapsOnSingleWindow` (default `false`)
through `SettingsExport` / `SettingsStore` / `CanonicalTOMLConfig` and expose it
in `LayoutSettingsTab`. Reuse the engine's existing per-workspace
`singleWindowLayoutContext(in:)` predicate as the gate. When the toggle is on and
the predicate matches, build the layout snapshot's `workingFrame` with
`outerGaps: .zero` (keeping the workspace-bar / menu-bar top strut) and feed
`LayoutGaps(outer: .zero)` into the pass — so the lone window goes edge-to-edge.
Adding a second window flips the predicate to `nil` and the normal gapped path
resumes automatically; no restore logic is needed.

The change is localized to the layout snapshot/plan path. It deliberately does
**not** touch `insetWorkingFrame(for:)` as seen by mouse hit-testing, so
edge-click behavior is unchanged.

## Discovery corrections / decisions

The discovery's product verdict and scope are correct. These corrections are
needed while implementing:

1. **Line-number drift everywhere.** Every citation in the discovery has moved;
   corrected line numbers are used throughout this plan (verified against `main`
   `7a025b78` on 2026-07-07). Notable: `singleWindowLayoutContext` is at
   `NiriLayoutEngine.swift:270` (not 258); `insetWorkingFrame(for:)` is at
   `WMController.swift:820` (not 747); `insetWorkingFrame(from:...)` is at
   `WMController.swift:842` (not 761).
2. **The working frame has a single layout-only chokepoint, which the discovery
   underused.** The snapshot's `workingFrame` is produced in exactly one place —
   `LayoutRefreshController.buildMonitorSnapshot(for:orientation:)`
   (`LayoutRefreshController.swift:607`, with the `workingFrame:` line at `:616`)
   — and is then consumed by **both** layout-plan builders:
   - `NiriLayoutHandler.buildOnDemandLayoutPlan` (`NiriLayoutHandler.swift:296`)
     reads `snapshot.monitor.workingFrame` at `:309`, and builds
     `LayoutGaps(outer: snapshot.outerGaps)` at `:302`.
   - `NiriLayoutHandler.computeLayoutPlan` (`NiriLayoutHandler.swift:831`) reads
     `pass.insetFrame` at `:847` (which is `snapshot.monitor.workingFrame`, set in
     `buildRelayoutPlan` at `NiriLayoutHandler.swift:353`) and builds
     `LayoutGaps(outer: snapshot.outerGaps)` at `:840`.

   The discovery recommended hooking only `buildOnDemandLayoutPlan`. That would
   leave the relayout hot path (`computeLayoutPlan`) still gapped. Instead,
   centralize the override in `buildMonitorSnapshot` so a single change covers
   both builders **and** the constraint-relaxation path that reads the same
   snapshot (`LayoutRefreshController.swift:591`).
3. **Do not gate `insetWorkingFrame(for:)` itself.** The discovery listed that as
   option (b). It is also called directly by `MouseEventHandler` (7 sites:
   `MouseEventHandler.swift:930,1107,1137,1171,1760,1826,1895`) and
   `AXEventHandler.swift:2415` for edge hit-testing, which must keep real outer
   gaps. Gating inside `buildMonitorSnapshot` (layout-only) avoids that risk
   entirely; this plan therefore adds an `outerGapsOverride:` parameter to
   `insetWorkingFrame(for:)` rather than changing its default behavior.
4. **Symbol name fix.** The discovery cites "`MonitorGapSettings.outerGaps`"; the
   actual accessor is `ResolvedGapSettings.outerGaps`
   (`Sources/Nehir/Core/Config/MonitorGapSettings.swift:56`). No behavior change,
   just the precise symbol.
5. **`singleWindowViewportGeometry` location.** The definition is at
   `NiriLayout.swift:745`; the discovery's `:871` was the call site inside
   `layoutSingleWindowWorkspace` (now `NiriLayout.swift:889`; the enclosing
   function is at `:875`).

## Scope

### Files to add/change

1. `Sources/Nehir/Core/Config/SettingsExport.swift`
   - Add `var removeOuterGapsOnSingleWindow: Bool` next to the outer-gap fields
     (`:32`); default `false` in the defaults block (`:123`).
2. `Sources/Nehir/Core/Config/SettingsStore.swift`
   - Add `var removeOuterGapsOnSingleWindow = SettingsStore.defaultExport.removeOuterGapsOnSingleWindow`
     next to `outerGapBottom` (`:92`).
   - Wire `toExport()` (`:415`) and `apply(export:)` (`:486`).
3. `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
   - Add `var smartGapsSingleWindow: Bool = false` to `Gaps`
     (`struct Gaps` at `:74`) plus a `case smartGapsSingleWindow` in its
     `CodingKeys`; default `false` so old configs round-trip unchanged.
   - Wire `from(export:)` (`:278`) and the `toExport` path (`:383`).
4. `Sources/Nehir/Core/Controller/WMController.swift`
   - Add an `outerGapsOverride: LayoutGaps.OuterGaps? = nil` parameter to
     `insetWorkingFrame(for:)` (`:820`); inside, pass
     `outerGaps: outerGapsOverride ?? outerGaps(for: monitor)` to
     `insetWorkingFrame(from:...)` (`:842`). All existing callers are unaffected
     (default `nil`).
   - Add a `@MainActor` helper, e.g.:
     ```swift
     func shouldRemoveOuterGapsForSingleWindow(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
         settings.removeOuterGapsOnSingleWindow
             && niriEngine?.singleWindowLayoutContext(in: workspaceId) != nil
     }
     ```
     (`niriEngine` is `WMController.swift:125`; `singleWindowLayoutContext(in:)`
     is `NiriLayoutEngine.swift:270`.)
5. `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`
   - Add a `workspaceId: WorkspaceDescriptor.ID? = nil` parameter to
     `buildMonitorSnapshot(for:orientation:)` (`:607`); update the sole caller
     `buildRefreshInput` (`:631`) to pass `workspaceId`.
   - At the `workingFrame:` line (`:616`), when
     `workspaceId.flatMap { controller?.shouldRemoveOuterGapsForSingleWindow(in: $0) } == true`,
     call `controller?.insetWorkingFrame(for: monitor, outerGapsOverride: .zero)`
     instead of the unparameterized form. `.zero` is
     `LayoutGaps.OuterGaps.zero` (`InteractiveResize.swift:117`). Keep the
     `?? monitor.visibleFrame` fallback.
6. `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift`
   - In `makeWorkspaceSnapshot` (`:252`), set the snapshot's `outerGaps:` (the
     argument near `controller.outerGaps(for: monitor)`) to `.zero` when
     `controller.shouldRemoveOuterGapsForSingleWindow(in: wsId)` is true,
     otherwise unchanged. This makes the `LayoutGaps(outer:)` constructed at
     `:302` (`buildOnDemandLayoutPlan`) and `:840` (`computeLayoutPlan`) both
     carry zero outer for the lone-window case.
   - No edit to `buildOnDemandLayoutPlan` / `computeLayoutPlan` bodies is
     required — they already derive from the snapshot.
7. `Sources/Nehir/UI/LayoutSettingsTab.swift`
   - In the `"Screen Margins"` Section (`:109`), add a
     `Toggle("Remove screen margins for a lone window", isOn: …)` bound to
     `settings.removeOuterGapsOnSingleWindow`, with a `SettingsCaption` explaining
     the behavior (restored when a second window appears). Use direct binding (a
     boolean toggle does not need the draft/commit pattern the sliders use).
8. Settings-change → relayout wiring (pick one, verify during impl):
   - `setGaps(to:)` / `setOuterGaps(...)` (`WorkspaceManager.swift:2401`/`:2408`)
     fire `onGapsChanged` → `ServiceLifecycleManager.handleGapsChanged()`
     (`:213`) → `requestRefresh(reason: .gapsChanged)`, but only when gap
     **values** change. A pure boolean toggle does not trip them. Ensure flipping
     `removeOuterGapsOnSingleWindow` requests a relayout — either by routing the
     toggle through the same gaps-changed notification, or by including the field
     in the settings-change observer that already requests
     `.workspaceConfigChanged` (see `WMController.updateWorkspaceConfig()`,
     `WMController.swift:860` region). The add/remove-second-window transition
     needs no extra wiring (predicate flips → normal relayout).

### Non-goals

- Do **not** change `insetWorkingFrame(for:)` behavior for mouse / AX edge
  hit-testing (the `MouseEventHandler` / `AXEventHandler` callers).
- Do **not** change inner-gap behavior — already correct with one window.
- Do **not** hide the focus border for a lone smart-gaps window (follow-up;
  `FocusBorderController`).
- Do **not** animate the gapped↔gapless transition (follow-up).
- Do **not** add per-monitor (`MonitorGapSettings`/`ResolvedGapSettings`) or
  per-workspace layering yet — global toggle first, as the discovery scopes.
- Do **not** alter `LoneWindowPolicy` (`.fill` / `.centered(...)`) semantics;
  smart gaps composes with both and must not collide with `.centered`.
- Do **not** change `singleWindowLayoutContext(in:)`'s predicate (tabbed columns,
  non-`.normal` sizing modes intentionally excluded).

## Exact implementation plan

### Phase 1 — Settings plumbing (global toggle, default `false`)

1. `SettingsExport.swift`: add `removeOuterGapsOnSingleWindow: Bool`; default
   `false`.
2. `SettingsStore.swift`: add the stored property, `toExport()`, `apply(export:)`.
3. `CanonicalTOMLConfig.swift`: add `Gaps.smartGapsSingleWindow` + CodingKey;
   wire `from(export:)` and `toExport`. Confirm an old TOML without the key
   decodes to `false` (Codable default).
4. `LayoutSettingsTab.swift`: add the `Toggle` in the `"Screen Margins"` Section.

### Phase 2 — Engine predicate accessor

`singleWindowLayoutContext(in:)` (`NiriLayoutEngine.swift:270`) already returns a
non-`nil` context iff the workspace has exactly one non-tabbed column with
exactly one `.normal`-sized window — the exact BarutSRB/OmniWM#373 predicate. Add
`WMController.shouldRemoveOuterGapsForSingleWindow(in:)` (see Scope item 4). No
new engine code.

### Phase 3 — Working-frame override at the single chokepoint

1. Add `outerGapsOverride:` to `WMController.insetWorkingFrame(for:)` (`:820`).
2. Add `workspaceId:` to `LayoutRefreshController.buildMonitorSnapshot(for:orientation:)`
   (`:607`); thread from `buildRefreshInput` (`:631`).
3. At the `workingFrame:` line (`:616`), substitute
   `insetWorkingFrame(for: monitor, outerGapsOverride: smartGaps ? .zero : nil)`
   where `smartGaps = workspaceId.map { controller?.shouldRemoveOuterGapsForSingleWindow(in: $0) ?? false } ?? false`.

This single change makes the lone window edge-to-edge in both
`buildOnDemandLayoutPlan` and `computeLayoutPlan`, and gives the constraint
relaxation path (`LayoutRefreshController.swift:591`) the expanded frame (so an
over-constrained lone window is not needlessly shrunk).

### Phase 4 — Pass-level outer gaps

In `makeWorkspaceSnapshot` (`NiriLayoutHandler.swift:252`), pass
`outerGaps: smartGaps ? .zero : controller.outerGaps(for: monitor)` (with the
same `smartGaps` check) so `LayoutGaps(outer: snapshot.outerGaps)` at `:302` and
`:840` is consistent with the expanded working frame.

### Phase 5 — Relayout on toggle

Wire the boolean toggle to a refresh request (Scope item 8). Verify manually that
toggling mid-session with one window re-lays-out on the next pass without a
restart.

### Phase 6 — Tests + validation (see below)

## Tests

### `Tests/NehirTests/NiriLayoutEngineTests.swift` (extend)

Existing single-window / `loneWindowPolicy` coverage lives here (e.g.
`:1087`, `:1129`, `:3897`). Add:

1. `smartGapsLoneWindowFillsWorkingFrameEdgeToEdge` — one `.normal` window,
   `removeOuterGapsOnSingleWindow = true`, non-zero outer gaps configured: assert
   the lone window's frame equals the monitor working area inset by **only** the
   bar top strut (outer gaps `0` on left/right/bottom).
2. `smartGapsRestoredWhenSecondWindowAppears` — same workspace, add a second
   window: assert both windows are laid out with configured outer **and** inner
   gaps restored (predicate `nil` → normal path).
3. `smartGapsToggleOffReappliesOuterGaps` — toggle off with one window: assert
   outer gaps reappear on the next relayout (no restart).
4. `smartGapsComposesWithCenteredLoneWindowPolicy` —
   `loneWindowPolicy = .centered(maxWidthFraction: 0.8)` + smart gaps on: assert
   centering is preserved **and** outer gaps removed (compose, not collide).

Use the existing harness in this file (`engine.loneWindowPolicy = ...` setup at
`:1087`/`:1129`; outer-gaps wiring at `:270`/`:4298`) to keep the assertions
consistent with how current lone-window tests build frames.

### `Tests/NehirTests/SettingsStoreTests.swift` / `SettingsTOMLCodecTests.swift` (extend)

5. Default `removeOuterGapsOnSingleWindow == false` (mirror the
   `gapSize`/`outerGap*` defaults assertions at `SettingsStoreTests.swift:317-321`).
6. TOML round-trip: set `smartGapsSingleWindow = true`, encode/decode, assert
   preserved; and a TOML omitting the key decodes to `false` (backward compat) —
   mirror `roundTripsOuterGaps` (`SettingsTOMLCodecTests.swift:165`).

### `Tests/NehirTests/LayoutRefreshControllerTests.swift` (extend, if a controller-level seam exists)

7. `buildMonitorSnapshot` produces an expanded `workingFrame` (outer gaps removed,
   bar top strut retained) when `shouldRemoveOuterGapsForSingleWindow(in:)` is
   true for the given workspace, and the normal gapped frame otherwise. If the
   controller-level harness cannot synthesize a single-window workspace cheaply,
   cover this via the engine-level tests (1–4) instead and skip this case.

## Validation

```bash
swift build
swift test --filter NiriLayoutEngineTests
swift test --filter SettingsStoreTests
swift test --filter SettingsTOMLCodecTests
swift test --filter LayoutRefreshControllerTests
mise run check        # format + lint + build + test
```

Manual validation:

1. One tiled window on a workspace, non-zero outer gaps configured, toggle on:
   the window spans edge-to-edge horizontally and to the bottom; the top still
   respects the workspace bar.
2. Add a second window: both windows reflow with configured outer + inner gaps.
3. Toggle off with one window: outer gaps reappear on the next relayout.
4. With `loneWindowPolicy = .centered(...)`: the lone window stays centered in
   width while outer gaps are removed.
5. Toggle the setting, then click near the screen edge over the (now edge-to-edge)
   lone window: confirm mouse hit-testing / focus behavior is unchanged (the
   `insetWorkingFrame(for:)` change must not affect `MouseEventHandler` paths).

Changeset (minor; confirm release policy): "Add optional smart gaps: remove
outer screen margins for a lone tiled window (BarutSRB/OmniWM#373)."

## Risks and mitigations

- **Hit-testing regression.** `insetWorkingFrame(for:)` is shared with mouse/AX
  edge hit-testing. Mitigation: add a parameter with `nil` default instead of
  changing the default; only `buildMonitorSnapshot` passes `.zero`. Add the manual
  edge-click check (#5 above).
- **Toggle doesn't relayout.** The boolean does not trip the value-based
  `setGaps`/`setOuterGaps` path. Mitigation: explicitly wire the toggle to a
  `.gapsChanged` (or `.workspaceConfigChanged`) refresh; add test #3.
- **Predicate disagreement between snapshot and pass.** The working frame
  (Phase 3) and `LayoutGaps.outer` (Phase 4) must both flip for the same
  workspace/pass. Mitigation: gate both from the single
  `shouldRemoveOuterGapsForSingleWindow(in:)` helper, computed off the same
  predicate and the same settings field.
- **`.centered` lone window + smart gaps.** Removing outer gaps must not break
  centering. Mitigation: explicit composition test (#4).
- **Constraint relaxation sees a larger frame.** Expanding `workingFrame` relaxes
  min-size feasibility for the lone window — desirable, not a risk, but note it.
- **Per-monitor gap overrides ignored for the lone window.** With the global
  toggle on, a per-monitor outer-gap override is intentionally ignored for the
  lone window (it is forced to `.zero`). This matches BarutSRB/OmniWM#373's "remove outer gaps"
  intent; per-monitor smart-gaps layering is a follow-up.

## Follow-ups (out of scope)

- Per-monitor and/or per-workspace smart-gaps layering in `MonitorGapSettings` /
  `ResolvedGapSettings`.
- Hide the focus border for a lone smart-gaps window (`FocusBorderController`).
- Animate the gapped↔gapless transition using the existing viewport-offset
  animation infra.
- Optional inner-gap removal knob (no-op today since one window has no
  neighbors); only relevant if tabbed/multi-window single-column cases are later
  included in the predicate.
