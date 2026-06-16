# Unified config diagnostics/migration implementation context

Source plan: `docs/plans/20260616-unified-config-diagnostics-and-migration-policy.md`.
Discovery: `docs/plans/discovery/20260616-hiro-410-settings-toml-unknown-keys-roundtrip-loss.md`.
Policy doc: `docs/SETTINGS_MIGRATIONS.md`.

## File map / high-value code paths

### `settings.toml` codec and persistence

- `Sources/Nehir/Core/Config/SettingsTOMLCodec.swift:4-16`
  - Only first-party file importing `TOML`; current boundary is intentionally small.
  - `encode(_ export:)` builds `CanonicalTOMLConfig(export:)`, configures `TOMLEncoder.outputFormatting = [.sortedKeys, .prettyPrinted]`, then encodes.
  - `decode(_:)` decodes `CanonicalTOMLConfig` and immediately returns `canonical.toSettingsExport()`.
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:15-144`
  - Static schema tables: `general`, `focus`, `mouseWarp`, `gaps`, `niri`, `borders`, `workspaceBar`, `gestures`, `statusBar`, `appearance`, plus nested color/outer tables.
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:146-224`
  - `init(export:)` constructs only modeled fields; no overflow/unknown storage.
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:226-290`
  - `toSettingsExport()` maps canonical schema back to `SettingsExport`; split config state is reset to defaults/empty values here (`workspaceConfigurations`, `hotkeyBindings`, app rules, monitor overrides, etc.).
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:293-450`
  - Hand-edit tolerant decoding: missing known keys use `decodeWithDefault`; wrong present types still throw.
  - Every `init(from:)` opens a `CodingKeys` container and decodes only known keys; unknown keys are ignored.
- `Sources/Nehir/Core/Config/SettingsExport.swift:13-86`
  - In-memory shape currently has no place to carry `settings.toml` unknown-key overflow. This is a key implementation constraint: adding overflow only to `CanonicalTOMLConfig` is not enough if public codec API remains `decode -> SettingsExport` and `encode(SettingsExport)`.
- `Sources/Nehir/Core/Config/SettingsFilePersistence.swift:131-168`
  - `saveImmediately` writes a full atomic replacement for `settings.toml` via `SettingsTOMLCodec.encode(export)` at lines 142-143; auxiliary files are rewritten too.
  - Same-export fast path skips rewrite only when current fingerprint equals `lastObservedFingerprint` and `export == lastPersistedExport` (134-140).
- `Sources/Nehir/Core/Config/SettingsFilePersistence.swift:426-469`
  - `readSnapshot()` decodes `settings.toml` first (`SettingsTOMLCodec.decode(data)` at 441), then overlays auxiliary config from `hotkeys.toml`, `workspaces.toml`, app rules, and monitor overrides.
- `Sources/Nehir/Core/Config/SettingsStore.swift:321-337,348-365`
  - Store initialization applies `persistence.load()` and registers external reload handler.
  - `ensureConfigFilesAvailable()` seeds missing files only; does not rewrite existing `settings.toml`.

### Mismatch detector / unknown-key detector starting point

- `Sources/Nehir/Core/Config/ConfigMismatchDetector.swift:4-15`
  - Current comments explicitly define unknown detection as schema round-trip loss: decode drops unknown `CodingKeys`, re-encode, diff raw vs output.
- `Sources/Nehir/Core/Config/ConfigMismatchDetector.swift:22-39`
  - Collects raw key paths, then collects key paths after `TOMLDecoder().decode(CanonicalTOMLConfig.self, from:)` + `SettingsTOMLCodec.encode(canonical.toSettingsExport())`.
  - Returns raw paths missing from schema output. Parse/unreadable file returns `[]`.
- `Sources/Nehir/Core/Config/ConfigMismatchDetector.swift:42-99`
  - Reusable pattern: recursive dynamic `AnyTOML: Decodable`, `container.allKeys`, `AnyTOMLKey: CodingKey`, and `collectKeyPaths` preserving original key case while de-duping lowercased paths.
  - Currently discards values; for round-trip preservation a value-carrying equivalent is needed.

### App launch strip / blocking UI

- `Sources/Nehir/App/AppDelegate.swift:50-76`
  - Before `SettingsStore`/`WMController`/status bar/hotkeys are created, `finishBootstrap` runs `detectConfigMismatches` on live `settings.toml`.
  - If unknowns exist, it creates a timestamped backup, calls `cleanSettingsFile`, shows migration UI, and only continues bootstrap on close.
- `Sources/Nehir/App/AppDelegate.swift:177-220`
  - Backup helper copies `settings.toml` to `settings-YYYYMMDD-HHMMSS.toml.backup` (with suffix collision handling).
  - `cleanSettingsFile` is decode -> encode -> atomic overwrite; this is the proactive unknown-key strip.
- `Sources/Nehir/UI/Onboarding/OnboardingWindowController.swift:118-137`
  - `showMigration(...)` presents `MigrationView` in `migrationWindow`; on window close invokes continuation passed by `AppDelegate`.
- `Sources/Nehir/UI/Onboarding/MigrationView.swift:4-8,21-29,111-128,131-178`
  - Current copy is explicitly about unrecognized keys and automatic cleanup.
  - `Copy AI Prompt` is disabled when `backupURL == nil`.
  - `buildPrompt(backupURL:)` is private UI code; includes app version, release URL, unknown keys, cleanup outcome, and backup path.

### Soft migration machinery and Diagnostics UI

- `docs/SETTINGS_MIGRATIONS.md`
  - Core invariants: do not silently rewrite just because decoded; Diagnostics warning/badge; explicit Migrate; Postpone only current release; state outside config.
- `Sources/Nehir/Core/Config/SettingsMigrationRegistry.swift:3-63`
  - Notification name: `.settingsMigrationStateDidChange`.
  - Registry has one descriptor: `workspaces-array-to-keyed-tables`.
  - `applicableMigrations` detects stale `workspaces.toml`; `pendingMigrations` filters postponed current-version entries.
- `Sources/Nehir/Core/Config/SettingsMigrationRegistry.swift:65-123`
  - `WorkspacesConfigMigration.needsMigration` detects legacy `[[workspace]]`.
  - `migrate(fileURL:)` backs up then rewrites `workspaces.toml` to canonical keyed tables.
- `Sources/Nehir/Core/Config/SettingsMigrationStateStore.swift:13-60`
  - State file: `settings-migration-state.json` under state dir.
  - API is migration-id keyed: `isPostponed(migrationID:currentAppVersion:)`, `postpone`, `clearPostpone`.
  - Writes private state (`0700` dir, `0600` file temp) with sorted, pretty JSON.
- `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift:4-24,52-76,139-188`
  - Keeps `applicableMigrations` in state and shows `Section("Settings Migrations")` when migrations/confirmation/errors exist.
  - Uses `applicableMigrations`, not `pendingMigrations`, so postponed migration entries remain visible but informational.
- `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift:191-253`
  - `SettingsMigrationWarningView` already has the desired Migrate/Postpone Warning pattern and visual downgrade when postponed.
- `Sources/Nehir/UI/SettingsSidebar.swift:58-63`
  - Badge count = display issues + accessibility issue + `SettingsMigrationDetector.pendingMigrations().count`. Unknown-key warnings will need to feed this count.

### Auxiliary codecs (explicit non-goal for this plan)

- `Sources/Nehir/Core/Config/HotkeysTOMLCodec.swift` and `Sources/Nehir/Core/Config/WorkspacesTOMLCodec.swift` are manual TOML-ish codecs and not in scope for unknown-key preservation.
- `Sources/Nehir/Core/Config/WorkspacesTOMLCodec.swift:16-18,72-80` supports legacy `[[workspace]]` detection for the current soft migration.

### Dependency notes

- `Package.swift:22-24,33-47,76-85`: dependency is `swift-toml` from `2.0.0`; project uses Swift language mode 6 and macOS 15.
- Local checkout evidence:
  - `.build/checkouts/swift-toml/Sources/TOML/Value.swift:12-43` exposes public `TOMLValue` cases, but it does **not** conform to `Codable` in the dependency.
  - Encoder internals serialize private `TOMLValue` trees and sort keys when requested (`Encoder.swift:183-230`); keyed encoding boxes primitive values into `TOMLValue` (`Encoder.swift:545-612`).
  - Practical implication: if preserving arbitrary unknown values, expect to implement a local `Codable` dynamic value wrapper or extend `TOMLValue` locally with `Codable`. Do not assume `TOMLValue` can be decoded/encoded directly today.

## Current behavior summary

1. Missing known values are tolerated. Example: `mainSettingsUsesDefaultsForMissingKeys` removes `ipcEnabled`, decode succeeds with default (`Tests/NehirTests/SettingsTOMLCodecTests.swift:39-46`).
2. Known keys with wrong present type throw. `mainSettingsRejectInvalidPresentValues` changes `hotkeysEnabled = true` to a string and expects an error (`Tests/NehirTests/SettingsTOMLCodecTests.swift:48-59`). This must remain category-4/recovery behavior.
3. Unknown keys are currently dropped by design. `unknownNiriKeysAreIgnoredAndNotReencoded` injects `maxWindowsPerColumn = 7` under `[niri]`, decode equals original export, and re-encode must not contain the unknown key (`Tests/NehirTests/SettingsTOMLCodecTests.swift:89-104`).
4. Any real save is a full rewrite, so load -> mutate -> save drops unknown keys unless no-op fast path applies.
5. Launch-time unknown key handling is blocking and destructive: `AppDelegate.finishBootstrap` backs up, `cleanSettingsFile` overwrites with recognized-only TOML, then shows `MigrationView`.
6. Soft migrations are non-blocking Diagnostics warnings: old `workspaces.toml` is detected without mutation; user can Migrate or Postpone Warning; badge suppression is release-scoped.
7. Invalid/corrupt settings currently do not use the migration window. `SettingsFilePersistence.load()` catches errors, moves `settings.toml` to `settings.toml.corrupt`, saves defaults, and continues (`SettingsFilePersistence.swift:101-120`; test at `SettingsStoreTests.swift` `corruptFileIsRenamedAsideAndReplacedWithDefaults`). This conflicts with the plan's future category-4 blocking recovery goal.

## Implementation constraints / design traps

- Unknown-key preservation must survive through `SettingsExport` or through a persistence-side companion object. Current `SettingsTOMLCodec.decode` returns only `SettingsExport`, and `SettingsTOMLCodec.encode` receives only `SettingsExport`; `CanonicalTOMLConfig` overflow alone would be lost at the API boundary.
- If adding unknown overflow to `SettingsExport`, account for `Equatable`: preservation metadata could affect the same-export no-rewrite fast path and tests comparing exports. A custom equality ignoring overflow may be needed if metadata should not make semantically equal settings unequal.
- Preservation is scoped to unknown keys inside known `settings.toml` tables for first cut. Top-level unknown table behavior must be pinned by test; current detector reports top-level unknown keys/tables.
- `detectConfigMismatches` will stop working if it remains based on lossy round-trip after preservation. New `detectUnknownKeys` should compare raw key paths against modeled schema key paths, not against preserved re-encoded output. One robust approach: derive known paths from a defaults/canonical schema encode and compare to raw paths while treating known table paths carefully.
- Be careful with dotted/nested tables: raw collector emits both table and leaf paths. Existing tests expect `workspaceBar.width` when appending `width = 7` after the last `[workspaceBar...]` section. Verify actual table context in test data before relying on string append.
- Shared postpone state currently has only `migrationID` terminology. Unknown-key postponement can reuse the store but should use a namespaced stable key (for example based on issue kind + file path), to avoid collisions with real migration IDs.
- `DisplayDiagnosticsSettingsTab` currently uses `applicableMigrations` for visible rows and `isPostponed` only for visual state. Unknown-key rows need the same distinction: visible if applicable, warning/badge only if not postponed for current version.
- `MigrationView.buildPrompt` is private and backup-only today. The shared helper should support Diagnostics unknown-key prompts without a backup path and recovery prompts with parse/decode error details.
- Phase ordering matters: remove launch strip only after unknown keys are preserved on save and surfaced non-blockingly, otherwise in-session save silently loses user config.

## Tests to update/add

Existing tests to change or preserve:

- `Tests/NehirTests/SettingsTOMLCodecTests.swift`
  - Flip/rename `unknownNiriKeysAreIgnoredAndNotReencoded` to require preservation.
  - Keep `mainSettingsRejectInvalidPresentValues` passing.
  - Add literal repro: unknown under `[general]` and `[niri]`, mutate a known value (e.g. `gaps.size`), save/encode, assert unknowns and mutated value survive.
  - Add top-level unknown table/key behavior pin.
  - Golden fixture `canonicalDefaultsMatchGoldenFixture` should remain unchanged for default output unless overflow changes default encoding.
- `Tests/NehirTests/ConfigMismatchDetectorTests.swift`
  - Current unknown-key tests are for `detectConfigMismatches`; move/rename to `detectUnknownKeys` as policy changes.
  - Preserve parse-failure behavior only if the function remains documented to return empty on parse failure; category-4 recovery may need a separate parse/decode error path test.
- `Tests/NehirTests/SettingsMigrationStateStoreTests.swift`
  - Existing release-scoped postpone tests are a model for unknown-key warning postpone; add a namespaced unknown issue key/current-version/next-version test.
- `Tests/NehirTests/SettingsStoreTests.swift`
  - Add persistence-level load -> mutate -> `saveImmediately`/`flushNow` test with unknown `settings.toml` key surviving.
  - Existing corrupt-file behavior may need updates in Phase 4 if startup recovery replaces move-aside/default behavior.
- App/bootstrap tests:
  - There is no direct existing test of `finishBootstrap` unknown-key strip; `AppDelegateIPCTests` only covers termination/IPC helpers. Removing strip may require an AppDelegate-level test seam or lower-level test proving no caller remains.

Suggested commands:

```sh
swift test --filter SettingsTOMLCodecTests
swift test --filter ConfigMismatchDetectorTests
swift test --filter SettingsMigrationStateStoreTests
swift test --filter SettingsFilePersistenceTests
swift test
swift build
rg "detectConfigMismatches|cleanSettingsFile|showMigration|MigrationView" Sources Tests
```

## Main risks

- **API-boundary loss:** unknowns captured in `CanonicalTOMLConfig` but discarded when converting to `SettingsExport`.
- **Detector false negatives:** preservation-aware encode makes old round-trip-diff detector useless for unknown-key Diagnostics unless redesigned.
- **Wrong-type conflation:** a known key with invalid type must continue throwing/recovery, not be preserved as unknown.
- **Unintended file rewrites:** Diagnostics unknown-key path must not back up, clean, or write the file.
- **Postpone collisions:** reuse of `SettingsMigrationStateStore` needs namespaced keys for unknown-key issues.
- **User-facing copy drift:** blocking window copy currently says Nehir removed unknown keys; must be rewritten before repurposing.
- **Top-level unknown tables:** dropping them without a pinned test would be a silent data-loss variant.
