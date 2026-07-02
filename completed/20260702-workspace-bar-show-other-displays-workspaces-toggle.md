# Workspace bar: per-display toggle to show other displays' workspaces as pills

**Status:** completed — shipped in commit `8286c192` on `main` (2026-07-02,
"Show other displays in the workspace bar"). Moved from `planned/` to
`completed/`. The implementation shipped with a `minor` changeset because this is
a new opt-in user-facing feature.
**Source:** design discussion 2026-07-02. No Nehir ticket was filed at the time
of writing; add one if a tracking issue is desired.

Source paths below refer to the main Nehir source tree. Source line numbers are
intentionally omitted because they drift quickly; use the shipped commit above for
exact provenance.

## TL;DR

Nehir now has an opt-in workspace-bar setting that shows workspaces from other
displays in the current display's bar. The setting is off by default, configurable
globally, and overridable per monitor. Foreign workspaces are appended after the
local workspaces behind a divider and grouped under a display icon so the bar
remains compact.

The interaction intentionally reuses the existing workspace-pill wiring:

- Plain-click a foreign workspace pill → switch that workspace on its home
display. The existing bar focus path resolves the workspace's home monitor and
suppresses mouse warp from bar clicks.
- Shift-click a foreign workspace pill → move the focused window to that
workspace through the existing focused-window move path.

## Shipped behavior

- Default is off: existing single-display/default workspace-bar behavior is
  unchanged unless the new toggle is enabled.
- Global setting:
  `workspaceBarShowWorkspacesFromOtherDisplays`.
- Per-monitor override:
  `MonitorBarSettings.showWorkspacesFromOtherDisplays`.
- Resolved setting:
  `ResolvedBarSettings.showWorkspacesFromOtherDisplays`.
- Projection option:
  `WorkspaceBarProjectionOptions.showWorkspacesFromOtherDisplays`.
- Foreign workspace projection:
  - uses realized workspaces from `workspaceManager.monitors` → `workspaces(on:)`;
  - excludes the current monitor's local workspaces;
  - dedupes by workspace id;
  - respects `hideEmptyWorkspaces` using real workspace occupancy;
  - excludes sticky windows from occupancy, matching local workspace projection;
  - leaves scratchpad and sticky top-level pills unchanged.
- Foreign workspace rendering:
  - local workspaces still render as the full workspace pills with window icons;
  - foreign workspaces are compact navigation pills without duplicated window
    icons;
  - foreign groups are separated by a divider and marked once with a display
    icon, avoiding repeated or ellipsized display names in each pill;
  - a small dot marks a foreign workspace that is active on its home display;
  - full monitor names are still available through help/accessibility text.
- Settings/onboarding:
  - Settings → Workspace Bar includes the global toggle;
  - connected monitor overrides include the overridable toggle;
  - saved inactive overrides show the saved value;
  - the workspace-bar preview and onboarding preview both reflect the toggle;
  - onboarding includes the toggle and uses a fit-to-width preview so all sample
    workspace/floating-window content remains visible.

## Main source changes

- `Sources/Nehir/Core/Config/MonitorBarSettings.swift`
  - Added monitor override storage and resolved default plumbing.
- `Sources/Nehir/Core/Config/SettingsExport.swift`
  - Added the global exported setting with default `false`.
- `Sources/Nehir/Core/Config/SettingsStore.swift`
  - Added live setting storage, export/import handling, and per-monitor
    resolution.
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
  - Added the new `[workspaceBar]` TOML key.
- `Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift`
  - Added read/write support in `monitors.d/*.toml` `[bar]` sections.
- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarProjectionOptions.swift`
  - Threaded the resolved setting into workspace-bar projection options.
- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift`
  - Split local workspace projection from foreign workspace projection.
  - Added foreign realized-workspace projection gated by the toggle.
- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
  - Extended `WorkspaceBarItem` with foreign/home-display state.
  - Added grouped foreign workspace rendering under one display icon per foreign
    display.
  - Kept click and context-menu actions on the existing focus/move closures.
- `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift`
  - Added global/per-monitor UI controls and wired the preview configuration.
- `Sources/Nehir/UI/Onboarding/Animations/WorkspaceBarAnimation.swift`
  - Added live preview support for foreign workspace groups.
  - Kept floating-window preview content and added fit-to-width scaling.
- `Sources/Nehir/UI/Onboarding/OnboardingStepControls.swift`
  - Added the onboarding toggle row.
- `Sources/Nehir/UI/Onboarding/OnboardingView.swift`,
  `Sources/Nehir/UI/Onboarding/OnboardingStepView.swift`, and
  `Sources/Nehir/UI/Onboarding/OnboardingSteps.swift`
  - Increased/centered the workspace-bar onboarding preview area so the expanded
    preview fits.

## Design decisions resolved

1. **Plain-click behavior on a foreign pill** — shipped as "switch the
   workspace's home display". This matches the existing workspace-bar focus path
   and keeps cursor warp suppressed for bar clicks.
2. **Foreign active visual** — shipped as a small dot on the active foreign
   workspace, distinct from the local display's focused-workspace accent ring.
3. **Foreign display labeling** — shipped as a single display icon per foreign
   display group, not repeated text per pill. The implementation initially used
   compact text tags, but that was revised before merge because repeated display
   labels were visually noisy and could still truncate.
4. **`hideEmptyWorkspaces` interaction** — shipped as consistent with local
   projection: foreign empty workspaces are hidden when the setting is on, and
   floating-only workspaces count as occupied only when floating windows are
   included in the bar projection.
5. **Foreign window icons** — not duplicated in foreign pills. The foreign pills
   are navigation/move targets; the home display's own bar remains the detailed
   view with window icons.

## Non-goals preserved

- Did not implement "Move Workspace to Monitor" (Nehir #62); foreign pills switch
  or move a window to a workspace, but do not relocate the workspace to this
  display.
- Did not change the right-click *Move to Workspace ▸* submenu added by the
  sibling plan; the submenu remains the explicit token-based move path.
- Did not change focus-follows or mouse-warp policy beyond reusing the existing
  bar paths.

## Tests added/updated

- `Tests/NehirTests/WorkspaceBarDataSourceTests.swift`
  - Foreign workspaces appear only when the toggle is enabled.
  - Foreign item metadata includes home monitor name, compact internal monitor
    label, active-on-home state, and no duplicated window icons.
  - Foreign empty workspaces respect `hideEmptyWorkspaces`.
- `Tests/NehirTests/SettingsStoreTests.swift`
  - Default is off.
  - Per-monitor override wins.
  - Export/apply round-trips the setting.
  - `MonitorOverrideFileStore` round-trips the per-monitor override.
- `Tests/NehirTests/SettingsTOMLCodecTests.swift` fixture update
  - Canonical TOML includes `showWorkspacesFromOtherDisplays = false`.
- Existing constructor call sites were updated in:
  - `Tests/NehirTests/IPCQueryRouterTests.swift`
  - `Tests/NehirTests/RefreshRoutingTests.swift`
  - `Tests/NehirTests/WorkspaceBarGeometryTests.swift`

## Validation before merge

Successful focused validation included:

```bash
mise run format:check
swift build
git diff --check
swift test --filter "WorkspaceBarDataSourceTests|WorkspaceBarManagerTests|WorkspaceBarSettingsResolutionTests|WorkspaceBarMonitorOverrideFileStoreTests|WorkspaceBarGeometryTests|SettingsTOMLCodecTests|IPCQueryRouterTests|RefreshRoutingTests"
```

The focused test run covered 161 tests across the workspace-bar/config/TOML/IPC
and refresh-routing areas.

A full `swift test` run was also attempted during implementation. The full suite
showed unrelated order-dependent failures that also reproduced on the clean base
without this feature; the focused validation above was used for this change.

## Manual validation performed during review

The implementation was iterated against multi-display screenshots before merge:

- Repeated full display names in every foreign workspace pill were replaced with
  a single display icon per group.
- The onboarding workspace-bar preview was updated so enabling the foreign
  workspace toggle no longer clips or hides floating-window samples.
- Preview/help text was updated to describe the actual display-icon grouping.

## Risks and mitigations

- **Cross-display focus surprise.** Plain-clicking a foreign pill switches the
  other display and may move keyboard focus there. Mitigation: the feature is
  opt-in and off by default; help text documents the behavior.
- **Visual ambiguity.** Foreign active workspaces could be mistaken for the local
  active workspace. Mitigation: foreign active state uses a small dot, while the
  local active workspace keeps the accent ring.
- **Density.** Many displays/workspaces can still crowd the bar. Mitigation:
  foreign workspaces are grouped behind a display icon, omit duplicated window
  icons, and respect `hideEmptyWorkspaces`.
- **Disconnected monitors.** Only realized monitor-assigned workspaces are
  projected, matching the sibling submenu implementation.

## Follow-ups

- Add richer tooltip/help wording if users find plain-click cross-display focus
  surprising.
- Revisit grouping/order if users with many displays want current-display-first
  or custom foreign-display ordering.
- Coordinate with Nehir #62 if workspace relocation becomes available later.
