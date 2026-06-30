# Fix persisted monitor override identity and show inactive overrides

## Status

Planned.

## Problem

Persisted monitor override matching currently treats `displayId` as a durable identity. That is unsafe: display IDs are runtime handles and can be reused by a different physical display after reconnects or topology changes. A stale override for a disconnected display can therefore be rebound to, and applied on, an unrelated connected display.

The settings UI has the opposite visibility problem: it only scopes configuration to currently connected monitors, so a saved override for a disconnected display is effectively invisible even though it may still exist on disk and may still influence matching if rebinding goes wrong.

## Repro evidence to preserve

A runtime capture showed this concrete mismatch:

- Connected topology had one monitor: `displayId=1`, name `Built-in Retina Display`, frame `2056x1329`.
- Global Niri settings requested centered lone windows at `0.9` width.
- A saved, disconnected monitor override existed for `name="DELL P2423D"`, `displayId=1`, anchor `(0,1329)`, with `loneWindowPolicy="centered"` and `loneWindowMaxWidth=0.6`.
- After moving all but one window off workspace 1, the lone remaining window was laid out at `x=416`, `width=1224`, `height=1226` on the built-in display.
- With outer gaps `left=8`, `right=8`, the working width is `2040`; `2040 * 0.6 = 1224`, so the disconnected Dell override was applied. The expected 90% width would have been about `1836`.

This document intentionally inlines the values above; it must not depend on reopening any machine-local capture.

## Source-backed findings

### 1. Active override lookup trusts `displayId` first

`Sources/Nehir/Core/Config/MonitorSettingsType.swift:19-30` resolves a monitor setting by returning the first entry whose `monitorDisplayId == monitor.displayId`, before considering the monitor name. That is the direct path that lets a stale `displayId=1` override match a different currently connected `displayId=1` monitor.

The same file also uses `displayId` as the first update/remove key:

- `Sources/Nehir/Core/Config/MonitorSettingsType.swift:37-60` replaces an existing setting by display ID.
- `Sources/Nehir/Core/Config/MonitorSettingsType.swift:63-69` removes by display ID.

### 2. Load-time rebinding mutates persisted override identity

`Sources/Nehir/Core/Config/SettingsStore.swift:723-743` calls `reboundMonitor(...)` for monitor settings when `ignoreMonitorIdentity` is false, then `applyResolvedMonitor(...)` mutates the setting.

`Sources/Nehir/Core/Config/SettingsStore.swift:825-843` implements `reboundMonitor(...)` with the same unsafe precedence: `displayId` match first, then optional position, then name.

`Sources/Nehir/Core/Config/SettingsStore.swift:801-808` writes the resolved monitor's `displayId` and anchor back into the settings object. This means loading config can silently rewrite a disconnected override toward the currently connected display. The next save can persist that accidental rebinding.

The position-based mode also starts with display ID: `Sources/Nehir/Core/Config/SettingsStore.swift:754-760` binds any override with a matching display ID before considering anchors at `Sources/Nehir/Core/Config/SettingsStore.swift:762-783`.

### 3. Monitor override files persist display IDs, anchors, and settings sections together

`Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift:92-99` writes `[match]` with `name`, optional `displayId`, and optional `anchorX` / `anchorY`.

`Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift:170-203` reads those fields back into each concrete monitor settings record. Since `displayId` is optional in the schema, the fix can keep backwards compatibility while downgrading `displayId` from identity to advisory metadata.

### 4. The Niri settings UI only shows connected monitors

`Sources/Nehir/UI/SettingsView.swift:240-248` stores `connectedMonitors = Monitor.current()` and passes only those monitors into `MonitorScopeSection`.

`Sources/Nehir/UI/SettingsView.swift:255-268` can only render `MonitorNiriSettingsSection` when the selected monitor ID exists in `connectedMonitors`; otherwise it falls back to global defaults.

`Sources/Nehir/UI/SettingsView.swift:271-273` refreshes the UI list from `Monitor.current()` on appear.

`Sources/Nehir/UI/OverridableControls.swift:210-224` renders picker entries only from the `monitors` array passed in. There is no row or status for saved overrides whose monitor is disconnected or otherwise inactive.

### 5. Existing tests encode the old, unsafe behavior

`Tests/NehirTests/SettingsStoreTests.swift:232-240` explicitly expects monitor lookup to prefer display ID over name fallback.

`Tests/NehirTests/SettingsStoreTests.swift:710-721` expects applying settings to clear a stale display ID when a named monitor cannot be resolved.

`Tests/NehirTests/SettingsStoreTests.swift:724-759` expects rebinding to connected display IDs when `ignoreMonitorIdentity` is true. The position intent is still useful, but the test shape should be changed so display ID does not win over position/name.

### 6. Adjacent persisted display matching has the same smell

`Sources/Nehir/Core/Monitor/OutputId.swift:32-48` resolves persisted display assignments by display ID before name or position. This may be a separate implementation pass, but the plan should audit it so monitor override matching and workspace assignment matching do not keep diverging.

## Target behavior

1. `displayId` is treated as a runtime handle, not a durable override identity.
2. A disconnected display override remains stored and visible in Settings, but it is marked inactive and is not applied to unrelated connected displays.
3. Connected monitor override matching is deterministic and conservative:
   - identity mode (`ignoreMonitorIdentity=false`): match by monitor name/model first; use display ID only as an advisory tie-breaker among multiple connected monitors with the same name, never as a cross-name match.
   - position mode (`ignoreMonitorIdentity=true`): match by saved anchor/layout position with one-to-one assignment; display ID can break exact ties only after position scoring.
   - ambiguous matches should resolve to no active override rather than applying the wrong override.
4. Loading settings must not rewrite disconnected overrides to currently connected monitors.
5. Updating a connected monitor override may refresh advisory runtime metadata for that override, but only after the active resolver has identified that override as belonging to the connected monitor.
6. The settings UI must show both:
   - active connected monitor scopes, with their effective override status; and
   - saved inactive display overrides, with an explicit `Inactive` / `Disconnected` state and reset/delete affordance.

## Implementation plan

### Phase 1 — Introduce explicit active override resolution

Add a central resolver for `MonitorSettingsType` records, for example near `MonitorSettingsStore`:

- `activeSetting(for monitor: Monitor, in settings: [T], connectedMonitors: [Monitor], ignoreIdentity: Bool) -> T?`
- `activeAssignments(settings: [T], connectedMonitors: [Monitor], ignoreIdentity: Bool) -> [T.ID: Monitor.ID]`
- `inactiveSettings(settings: [T], connectedMonitors: [Monitor], ignoreIdentity: Bool) -> [T]`

Rules:

- In identity mode, candidate set is entries whose `monitorName` case-insensitively equals `monitor.name`.
- If there is one candidate, it is active for that monitor.
- If there are multiple same-name candidates, prefer one whose advisory `monitorDisplayId` equals the current runtime ID, then one whose anchor is closest to `monitor.workspaceAnchorPoint`; if still tied, return no active match and mark all ambiguous candidates inactive/ambiguous.
- In position mode, perform a one-to-one assignment by anchor distance across all saved entries with anchors. Do not pre-assign by display ID. Fall back to unique name only for entries with no anchor.
- Keep this resolver pure: it must not mutate `monitorDisplayId` or anchors.

Replace `MonitorSettingsStore.get(for monitor:in:)` callers with the resolver where active matching matters. Keep simple name-based lookup for editing by saved display name if needed, but do not use it to decide active application.

### Phase 2 — Stop load-time identity mutation

Change `SettingsStore.applyExport(...)` and `reboundMonitorSettings(...)` so loading a config preserves saved override identity metadata.

Concrete changes:

- Remove or sharply limit `SettingsStore.reboundMonitorSettings(...)` for monitor override arrays.
- Do not call `applyResolvedMonitor(...)` as part of ordinary settings load.
- Preserve `monitorName`, `monitorDisplayId`, and `monitorAnchorPoint` exactly as read from `monitors.d/*.toml` unless running an explicit migration.
- When `ignoreMonitorIdentity` changes, recompute active resolver results at use time rather than rewriting all persisted records.

This is the main fix preventing a disconnected Dell override from becoming an active built-in override just because both used `displayId=1`.

### Phase 3 — Make updates target records by resolver result, not by display ID alone

Update `MonitorSettingsStore.update(...)` semantics for connected monitor editing:

- If editing an active connected monitor with an existing active override, update that override by stable record ID (`MonitorNiriSettings.id`, etc.) or by the resolver's selected record.
- If no active override exists, create a new override using current monitor name, current anchor, and optional advisory display ID.
- For same-name duplicate monitors, avoid blindly replacing the first matching name-only entry unless the resolver says that entry is active for the selected connected monitor.
- `remove(for monitor:)` should remove only the active override for that monitor, not every record that happens to share the runtime display ID.

### Phase 4 — Preserve but demote `displayId` in monitor override files

Keep `displayId` in `[match]` for backwards compatibility and diagnostics, but document and enforce that it is advisory:

- `MonitorOverrideFileStore.encode(...)` can still write `displayId` and anchor.
- `MonitorOverrideFileStore.decode(...)` should continue reading old files.
- New code should not rely on `displayId` alone when resolving an active override.
- Consider adding a schema/comment note in generated files later, but avoid noisy rewrites as part of this bug fix unless required.

### Phase 5 — UI: show inactive saved overrides

Refactor `MonitorScopeSection` so it accepts a display-scope model rather than only `[Monitor]`, for example:

```swift
enum MonitorSettingsScope: Hashable {
    case global
    case connected(Monitor.ID)
    case inactiveOverride(UUID)
}

struct MonitorSettingsScopeRow: Identifiable {
    let id: MonitorSettingsScope
    let title: String
    let subtitle: String?
    let state: State // active custom, active global, inactive/disconnected, ambiguous
}
```

For the Niri tab:

- Build connected rows from `Monitor.current()`.
- Build inactive rows from `settings.monitorNiriSettings` records that the active resolver did not assign to any connected monitor.
- Show inactive rows under a separate picker/menu group such as `Saved Display Overrides`.
- Label them clearly, for example: `DELL P2423D — Inactive (not connected)`.
- Selecting an inactive row should not fall back to global defaults. It should render a saved override detail view.

Add a `SavedMonitorNiriOverrideSection` or generalized saved-override view that can show:

- saved display name;
- saved anchor if present;
- advisory display ID if present, labelled as runtime/advisory;
- saved Niri override values (`balancedColumnCount`, `loneWindowPolicy`, width);
- `Delete Override` / `Reset Saved Override` action.

First implementation can make inactive overrides read-only except for delete/reset. Editing inactive values can be a follow-up if needed.

Apply the same pattern later to workspace bar, gap, and orientation tabs so inactive per-monitor settings are not hidden in other settings pages.

### Phase 6 — Revisit workspace/display assignment matching separately

Audit `OutputId.resolveMonitor(...)` and restore assignment matching after the override fix lands. The immediate lone-window bug is in monitor overrides, but workspace assignment code should also avoid display ID as durable identity where possible.

Do not bundle a broad workspace restore semantic change into the first monitor override fix unless tests prove the same active bug path.

## Tests to add or update after runtime confirmation

Per repository workflow, add tests after the runtime fix is confirmed in the real repro.

Suggested coverage:

1. Active resolver ignores cross-name display ID collision:
   - saved override: `name="DELL P2423D"`, `displayId=1`, width `0.6`;
   - connected monitor: `name="Built-in Retina Display"`, `displayId=1`;
   - result: no active override; global lone-window width applies.

2. Disconnected override remains persisted:
   - apply settings with a saved Dell override and only built-in connected;
   - assert the Dell override record still has name/anchor/advisory metadata and remains in `monitorNiriSettings`;
   - assert `settings.niriSettings(for: builtIn)` returns nil / no active override.

3. UI model includes inactive override:
   - given connected built-in monitor plus saved Dell override;
   - Niri settings scope rows include `Global`, built-in connected row, and inactive Dell saved override row.

4. Position mode does not let display ID beat anchor:
   - two saved overrides with stale display IDs and anchors;
   - connected monitors with reused display IDs but different positions;
   - assert active assignment follows position.

5. Same-name duplicate monitors are deterministic:
   - two connected monitors with the same name;
   - two saved overrides with anchors;
   - assert one-to-one active assignment by anchor, not first display ID match.

6. Update/remove only active selected override:
   - same-name duplicates or stale disconnected override plus connected monitor;
   - resetting connected monitor does not delete inactive saved override.

## Acceptance criteria

- Reproducing the runtime scenario above yields a lone-window width derived from global `0.9`, not the disconnected Dell `0.6` override.
- The disconnected Dell override is still visible in Settings as inactive/not connected.
- Saving Settings does not silently rewrite the Dell override to `Built-in Retina Display` or delete it.
- Connected monitor overrides still work when the matching display is present.
- `mise run format:check` and the focused settings/UI tests pass.
