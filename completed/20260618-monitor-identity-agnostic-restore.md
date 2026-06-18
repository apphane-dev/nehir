# Monitor-identity-agnostic restore (issue #65)

## Context

Nehir ties every per-monitor binding to a monitor's **identity** — its `displayId` and
`localizedName` (e.g. `"HP E27m G4"`). When the same laptop moves between different physical
monitor sets (home dual-monitor ↔ office dual-monitor), *both* the `displayId` and `name`
differ, so on reconnect Nehir cannot recognise "the same monitor" and:

- **windows/apps land on the wrong monitor** — the runtime restore matchers rank candidate
  monitors by **name match first**, so when no name matches the result is effectively
  arbitrary instead of position-stable;
- workspaces pinned to a specific display fall back to the main monitor;
- per-monitor bar/gap/orientation/niri overrides are lost.

**Primary goal (user requirement):** after a monitor disconnect → reconnect, *every app stays
on the same monitor it was on before* — whether that monitor is now Main or Secondary —
matched by **layout position (topology)** rather than monitor model/name.

GitHub issue #65 asks for the same thing as a setting. Add a global toggle
`ignoreMonitorIdentity` (default `false`). When enabled, all monitor-resolution paths ignore
the monitor name/model and resolve by **position / anchor-point geometry** (which already
encodes Main vs Secondary). (Note: App Rules in `AppRule.swift` don't bind to monitors, so the
issue title's "App rules" is moot.)

## Resolution paths to change

These all currently let monitor **name** dominate. Position (anchorPoint, frameSize, `isMain`)
already distinguishes Main vs Secondary; the fix is to stop letting name override it.

**Runtime restore (the user's core requirement — windows/workspaces returning to position).
These already persist geometry, so they need ONLY toggle-gating, no schema change:**

1. **`MonitorRestoreAssignments.restoreMatchScore`** —
   `Sources/Nehir/Core/Monitor/MonitorRestoreAssignments.swift:163` (via
   `resolveWorkspaceRestoreAssignments:30`). Visible-workspace → monitor restore on topology
   change. `namePenalty` is currently the first tiebreaker after `assignedCount`.
2. **`RestorePlanner.persistedMonitorMatchScore` + `resolvePersistedPreferredMonitor`** —
   `Sources/Nehir/Core/Reconcile/RestorePlanner.swift:351,391`. Per-window preferred-monitor
   restore (`PersistedRestoreIntent.preferredMonitor`, a `DisplayFingerprint` that already
   carries `anchorPoint` + `frameSize`, `ReconcileSnapshot.swift:78`). `namePenalty` ranks
   first. **This is the path that decides which monitor each app's window returns to.**
   - Workspace home/`effectiveMonitor` fallback (`WorkspaceManager.swift:3803`) is already
     anchor-distance based; `.main`/`.secondary` descriptors (`MonitorDescription.swift`)
     already resolve positionally — no change needed, just confirm they're in the path.

**Persisted config (breaks across machines; needs an anchor persisted because the on-disk
types store only name + displayId):**

3. **`OutputId.resolveMonitor(in:)`** — `Sources/Nehir/Core/Monitor/OutputId.swift:19`.
   Workspace→display pins (`.specificDisplay`). Today: exact `displayId`, else unique `name`.
4. **`MonitorSettingsStore.get(for:in:)`** — `Sources/Nehir/Core/Config/MonitorSettingsType.swift:10`.
   Per-monitor bar/gap/orientation/niri overrides. Today: `displayId`, else `name`.

## Matching strategy

When `ignoreMonitorIdentity` is on:
- Keep the exact `displayId` short-circuit (correct + harmless when the *same* physical
  monitor reconnects with a stable id).
- **Drop the name penalty** so ranking falls to anchor-point distance + frame-size delta
  (= position = Main/Secondary). Reuse the existing squared-distance helpers
  (`MonitorRestoreAssignments.swift:183`, `RestorePlanner.swift:493`).
- For paths #3/#4, the on-disk types lack geometry, so persist a **top-left anchor point**
  (`Monitor.workspaceAnchorPoint`, `Monitor.swift:78`) and pick the nearest-anchor monitor;
  fall back to today's name logic when the anchor is absent (old configs) or the toggle is
  off — fully backward compatible.

## Implementation

### A. Thread the flag

`SettingsStore` owns the new flag. Carry it into the planners and resolvers:
- Add `ignoreMonitorIdentity: Bool` to `RestorePlanner.TopologyInput` (`:18`) and
  `PersistedHydrationInput` (`:42`); populate from `settings.ignoreMonitorIdentity` at the
  build sites in `WorkspaceManager` (`:529` topology, `:757` hydration).
- Add an `ignoreIdentity` parameter to `resolveWorkspaceRestoreAssignments` /
  `restoreMatchScore`, to `OutputId.resolveMonitor`, and to `MonitorSettingsStore.get`.
- `SettingsStore` resolver methods (`barSettings(for:)` etc. `:682`+, and
  `normalizedWorkspaceConfigurations` `:622`) read `self.ignoreMonitorIdentity` directly.

### B. Gate name penalty in runtime matchers (paths #1, #2)

- `restoreMatchScore`: `let namePenalty = ignoreIdentity ? 0 : (…existing…)`.
- `persistedMonitorMatchScore`: same. In `resolvePersistedPreferredMonitor`, when
  `ignoreIdentity` keep the exact-displayId short-circuit but skip the exact-fingerprint
  short-circuit (it embeds the name) and rely on the name-free `min` ranking.
- Confirm `planMonitorConfigurationChange` (`:152`,`:202`-`224`) and `planEvent` propagate the
  flag where they call into these.

### C. Persist anchor for on-disk references (paths #3, #4)

- **`OutputId.swift`**: add `let anchorPoint: CGPoint?` (`Codable`/`Hashable`); populate in
  `init(from monitor:)` with `monitor.workspaceAnchorPoint`.
- **`WorkspacesTOMLCodec.swift`** (`encode:32`, `decode:55`): write/read `monitorAnchorX` /
  `monitorAnchorY` for `.specificDisplay`; missing → `nil`.
- **`MonitorSettingsType` protocol** (`:4`): add `var monitorAnchorPoint: CGPoint? { get set }`
  (store as flat optional `anchorX`/`anchorY`). Add the property, init param, and `Codable`
  keys (`decodeIfPresent`/`encodeIfPresent`, mirroring `monitorDisplayId`) to the 4 conformers:
  `MonitorBarSettings`, `MonitorGapSettings`, `MonitorOrientationSettings`, `MonitorNiriSettings`.
- **`MonitorOverrideFileStore.swift`**: write/read `anchorX`/`anchorY` in the `[match]`
  section (`encode:82`, `decode:154`).
- Populate the anchor on save by extending `SettingsStore.reboundMonitorSettings` /
  `normalizedWorkspaceConfigurations` (`SettingsStore.swift:651,622`), which already rebind
  `displayId` against current monitors.

### D. Anchor-proximity resolution (paths #3, #4)

- `OutputId.resolveMonitor(in:ignoreIdentity:)`: exact `displayId` first; then if
  `ignoreIdentity` and `anchorPoint != nil`, return the monitor with nearest
  `workspaceAnchorPoint`; else the current unique-name fallback.
- `MonitorSettingsStore.get(for:in:ignoreIdentity:)`: `displayId`/name matches first; when
  `ignoreIdentity`, among entries with an anchor pick the nearest to
  `monitor.workspaceAnchorPoint`.
- *Refinement:* prefer matching the built-in display to the built-in (via `Monitor.isMain`
  / notch) before anchor proximity, so laptop-internal settings don't migrate onto an external.

### E. Settings pipeline (mirror `developerModeEnabled` end-to-end)

- **`SettingsExport.swift`**: add `var ignoreMonitorIdentity: Bool` + `false` in `defaults()`.
- **`CanonicalTOMLConfig.swift`** `General` struct: add field + `CodingKeys`; `decodeWithDefault`
  (~`:451`) and `encode` (~`:460`); `init(export:)` mapping (~`:227`) and reverse mapping into
  `SettingsExport` (~`:393`).
- **`SettingsStore.swift`**: published
  `var ignoreMonitorIdentity = SettingsStore.defaultExport.ignoreMonitorIdentity { didSet { scheduleSave() } }`
  (near `:258`); include in the export builder (~`:438`) and `apply(export:)` (~`:523`).

### F. UI toggle — Monitor Settings tab

In `MonitorSettingsTab.swift`, add a `Section` ("Display Matching") with:
```swift
Toggle("Keep apps on the same monitor across reconnects", isOn: $settings.ignoreMonitorIdentity)
    .onChange(of: settings.ignoreMonitorIdentity) { _, _ in controller.refreshLayout() }
SettingsCaption("Match saved windows, workspaces, and per-monitor settings by screen position instead of monitor model — so apps return to the same monitor (Main or Secondary) when moving between different monitor sets (e.g. home and office).")
```
Use existing helpers (`SettingsPage`, `SettingsCaption`); confirm the exact refresh entry
point on `WMController` (the tab already holds `controller`).

### G. Docs

- `docs/CONFIGURATION.md`: document `[general] ignoreMonitorIdentity` and the new optional
  `monitorAnchorX/Y` fields in `workspaces.toml` and `monitors.d/*.toml`.
- `docs/SETTINGS_MIGRATIONS.md`: note the additive, backward-compatible fields (no migration —
  all new keys optional).

## Critical files

- `Sources/Nehir/Core/Reconcile/RestorePlanner.swift` (per-window + topology restore)
- `Sources/Nehir/Core/Monitor/MonitorRestoreAssignments.swift`
- `Sources/Nehir/Core/Monitor/OutputId.swift`, `Sources/Nehir/Core/Monitor/MonitorDescription.swift`
- `Sources/Nehir/Core/Config/MonitorSettingsType.swift`
- `Sources/Nehir/Core/Config/{MonitorBarSettings,MonitorGapSettings,MonitorOrientationSettings,MonitorNiriSettings}.swift`
- `Sources/Nehir/Core/Config/{WorkspacesTOMLCodec,MonitorOverrideFileStore}.swift`
- `Sources/Nehir/Core/Config/{SettingsExport,CanonicalTOMLConfig,SettingsStore}.swift`
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` (planner build sites `:529`,`:757`)
- `Sources/Nehir/UI/MonitorSettingsTab.swift`
- `docs/CONFIGURATION.md`, `docs/SETTINGS_MIGRATIONS.md`

## Verification

1. **Unit tests** (extend existing suites):
   - `Tests/NehirTests/RestorePlannerTests.swift` — per-window restore: with `ignoreIdentity:true`
     and differing names/displayIds but matching position, windows resolve to the same Main /
     Secondary monitor; with the flag off, legacy name-first behavior is unchanged.
   - `Tests/NehirTests/MonitorRestoreAssignmentsTests.swift` — workspace restore ignores name
     when flagged.
   - New `OutputId.resolveMonitor` / `MonitorSettingsStore.get` cases (different name + displayId,
     same anchor → match when flagged; no match when off / anchor absent).
   - `Tests/NehirTests/SettingsStoreTests.swift` — round-trip the `ignoreMonitorIdentity` flag and
     the persisted anchor fields (TOML encode/decode, backward compat when keys absent).
   - Run: `swift test` (or `mise run test` if defined).
2. **Build**: `swift build` / `mise run package:release`.
3. **Manual (the real scenario):** with the toggle on, place apps across Main + Secondary,
   disconnect a monitor, reconnect a *different model* in the same position, and confirm every
   app returns to its original Main/Secondary monitor and per-monitor overrides reattach.
   Repeat with the toggle off to confirm legacy identity-only behavior is unchanged.
