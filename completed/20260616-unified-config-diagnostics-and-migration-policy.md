# Unified Config Diagnostics & Migration Policy

Status: **completed** — shipped 2026-06-16 in `b7cfb91e` ("Preserve and surface unknown settings keys instead of stripping them"). All four phases landed:

- **Phase 1 (codec round-trip):** per-table unknown-key overflow via the new `SettingsTOMLUnknownValue` + `CanonicalTOMLConfig` capture/re-emit; the codified-loss test `unknownNiriKeysAreIgnoredAndNotReencoded` was flipped to require preservation.
- **Phase 2 (Diagnostics):** `ConfigAssistancePrompt` (extracted prompt helper), the `SettingsDiagnosticsIssue` enum, and the preservation-aware `detectUnknownKeys(in:)` (category 2) now surface unknown keys as a non-blocking Diagnostics row with Copy AI Prompt + Postpone Warning, with no file rewrite.
- **Phase 3 (strip removal):** the `AppDelegate.finishBootstrap` unknown-key strip (`detectConfigMismatches → backup → cleanSettingsFile → showMigration`) is gone; `detectConfigMismatches` survives only as a thin alias delegating to `detectUnknownKeys`.
- **Phase 4 (recovery window):** `MigrationView` was renamed `ConfigRecoveryView` and now fires only for genuine load failures (parse/type error, enforced migration); it uses the shared prompt helper and does not auto-strip.

The implementation reference at the end of this doc is preserved from the
implementation-context notes that accompanied the commit.

## Overview

Nehir currently has **two unrelated, overlapping mechanisms** for "settings the running
version doesn't fully understand":

1. **Soft migrations** (just built): a registry + Diagnostics UI that handles a known
   old format → new format change for a user-owned file (`workspaces.toml`
   `[[workspace]]` → keyed tables). Non-blocking, explicit Migrate / Postpone Warning,
   release-scoped warning suppression. See `docs/SETTINGS_MIGRATIONS.md` and
   `Sources/Nehir/Core/Config/SettingsMigrationRegistry.swift`.
2. **Launch-time unknown-key strip**: a *blocking* bootstrap gate that, whenever
   `settings.toml` has any key the schema doesn't statically model, backs up the file,
   rewrites it (dropping the unknown keys), and shows `MigrationView` with a "Copy AI
   Prompt" action. See `Sources/Nehir/App/AppDelegate.swift:48-66` and the discovery
   doc `discovery/20260616-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md`.

These two were designed in isolation and now collide: the launch strip treats *any*
schema drift as fatal-and-rewriting, while the migration policy is built on the premise
that the app keeps running and lets the user decide. This plan unifies them into one
policy with a clear, non-overlapping split between **non-blocking Diagnostics issues**
and **blocking startup recovery**.

The key product decision, carried out here, is: **unknown keys are valid config, must
survive round-trip, and are surfaced (not rewritten) in Diagnostics.** The launch strip
for unknown keys goes away.

## Context

### Discovery: unknown-key round-trip data loss

`discovery/20260616-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md`
establishes (upstream BarutSRB/OmniWM#410, applies verbatim to nehir):

- `SettingsTOMLCodec.encode(_:)` rebuilds a fresh `CanonicalTOMLConfig` from the
  in-memory `SettingsExport` (`Sources/Nehir/Core/Config/SettingsTOMLCodec.swift:6-11`).
  The hand-written `init(from:)` only reads its own `CodingKeys`
  (`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:296-306`), so **every unknown key
  is gone the instant `decode` returns.**
- The write path is a full atomic overwrite, never merged with on-disk content
  (`SettingsFilePersistence.swift:131,142-143`). A load→mutate→save cycle on a file with
  unknown keys drops them silently.
- nehir additionally runs a **proactive launch-time strip**: `AppDelegate.finishBootstrap`
  calls `detectConfigMismatches` → `createTimestampedSettingsBackup` →
  `cleanSettingsFile` (decode→encode→overwrite) → `showMigration`. This is nehir's own
  instance of the "BarutSRB/OmniWM#322 settings.toml gets reset on upgrade" symptom.
- The dropping behavior is **codified by a test**:
  `unknownNiriKeysAreIgnoredAndNotReencoded`
  (`Tests/NehirTests/SettingsTOMLCodecTests.swift:89-104`), whose final assertion requires
  the unknown key to be absent after re-encode.
- The infrastructure to enumerate unknown keys already exists:
  `ConfigMismatchDetector` + its dynamic `AnyTOMLKey: CodingKey` and `AnyTOML` recursive
  wrapper (`Sources/Nehir/Core/Config/ConfigMismatchDetector.swift`). It is used to
  *detect-and-strip*, not to preserve.
- Design interaction the implementer must resolve: if the codec preserves unknown keys,
  `detectConfigMismatches`'s round-trip diff stops reporting them, so the launch gate
  stops firing on its own output. This plan makes that resolution explicit.

### Current soft-migration machinery (already shipped)

- `Sources/Nehir/Core/Config/SettingsMigrationRegistry.swift` —
  `SettingsMigrationDescriptor`, `SettingsMigrationDetector`
  (`applicableMigrations` vs release-scoped `pendingMigrations`),
  `WorkspacesConfigMigration.migrate(fileURL:)` (timestamped backup + rewrite).
- `Sources/Nehir/Core/Config/SettingsMigrationStateStore.swift` —
  `settings-migration-state.json` under the state dir; postpone is keyed by
  `{migrationID: appVersion}`.
- `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift` — Diagnostics renders a
  `SettingsMigrationWarningView` per applicable migration with Migrate / Postpone Warning.
- `Sources/Nehir/UI/SettingsSidebar.swift` — badge count includes pending migrations.
- `docs/SETTINGS_MIGRATIONS.md` — lifecycle: `introduced` → `deprecated` → `enforced`.

### Current recovery UI (to be repurposed)

- `Sources/Nehir/UI/Onboarding/MigrationView.swift` — a blocking window titled
  "Config Update Required", lists unknown keys as "ignored", offers "Copy AI Prompt" +
  "Dismiss". Its prompt builder (`buildPrompt(backupURL:)`) is otherwise reusable.
- `OnboardingWindowController.showMigration(...)` presents it
  (`Sources/Nehir/UI/Onboarding/OnboardingWindowController.swift:118`).

## Goal

One policy, four non-overlapping categories, with a clean blocking/non-blocking line:

```text
Diagnostics (non-blocking)          Startup recovery (blocking)
─────────────────────────           ──────────────────────────
1. missing known values             4. invalid / unsupported config
2. truly unrecognized keys             - TOML parse failure
3. known soft migrations               - known key with wrong type
   (introduced/deprecated/enforced)    - enforced-migration old format
                                       - codec can't produce a usable config
```

1. **Missing known values** — no warning. Decode with defaults; file untouched unless the
   user changes a setting.
2. **Truly unrecognized keys** (valid TOML, unknown to schema) — non-blocking Diagnostics
   issue. App starts normally. **Unknown keys are preserved on save.** Diagnostics shows
   the key/file, says "Nehir ignores this setting", offers **Copy AI Prompt** and
   **Postpone Warning**. Postpone hides warning/badge for the current release only.
3. **Known soft migrations** — the existing registry/Diagnostics flow.
4. **Invalid / unsupported config** — the **only** remaining blocking path. App may not be
   able to apply the config safely, so a pre-bootstrap recovery window is justified. It
   offers **Copy AI Prompt** (and, where a backup exists, the backup path). It must **not**
   rewrite/strip by default.

## Non-goals

- **Do not** preserve unknown keys for the sibling codecs (`HotkeysTOMLCodec`,
  `WorkspacesTOMLCodec`) in this plan. Unknown-key round-trip is scoped to
  `settings.toml` (`CanonicalTOMLConfig`), matching the discovery doc's scope. Track the
  siblings as a follow-up.
- **Do not** preserve unknown *top-level tables* in the first cut. The discovery doc scopes
  the fix to unknown keys inside known tables (`[general]`, `[niri]`, …). Top-level unknown
  tables get an explicit, pinned behavior (see Phase 2 decision point).
- **Do not** build a generic schema/manifest. The valid key set stays derived from the
  Codable schema; unknown keys are captured by overflow containers, not by a maintained
  allow-list.
- **Do not** auto-migrate anything. No silent rewrites anywhere in the unified policy.

## Proposed model

### Codec: capture + re-emit unknown keys (round-trip)

`CanonicalTOMLConfig` gains a per-table overflow that survives decode and is re-emitted by
encode. Approach per the discovery doc's recommendation:

- Each known-table `init(from:)` opens a keyed container against a dynamic `CodingKey`
  (the `AnyTOMLKey` pattern already in `ConfigMismatchDetector.swift:94`), enumerates
  `container.allKeys`, decodes modeled keys as today, and stashes any non-modeled key into
  a `TOMLValue`/raw-fragment overflow (e.g. `[String: TOMLValue]`).
- `encode(to:)` writes modeled keys first (preserving existing `.sortedKeys`/
  `.prettyPrinted` formatting), then appends each captured unknown key under its original
  table.
- Missing known values keep using `decodeWithDefault` — unchanged behavior.

This is the **dependency for everything else**: until unknown keys survive round-trip,
Diagnostics cannot truthfully say "kept in the file", and removing the launch strip would
re-introduce silent loss on the in-session save path.

### Detector split

Split the current `detectConfigMismatches` (which conflates "unknown key" with "mismatch")
into two distinct, composable operations:

- `detectUnknownKeys(...)` — returns key paths present in the raw file but absent from the
  re-encoded schema output. **Preservation-aware**: once the codec round-trips, this still
  reports them (they're unknown to the *schema*, just no longer destroyed). Used by
  Diagnostics category 2.
- A *parse/type-failure* path (today: `decode` throws, or `SettingsStore` falls into its
  corrupt-file branch) feeds category 4. This is not a "mismatch list"; it's a "the file
  could not be applied" error with the raw parse/decode error string.

### Diagnostics entry types

Generalize the existing `SettingsMigrationWarningView` / `PendingSettingsMigration` pattern
to a small set of Diagnostics issue kinds, all non-blocking:

```swift
enum SettingsDiagnosticsIssue: Identifiable {
    case softMigration(PendingSettingsMigration)     // category 3
    case unknownKeys(UnknownKeysIssue)               // category 2

    var id: String { ... }   // stable per issue
}
```

`UnknownKeysIssue` carries: file URL, list of unknown key paths, and a
"Copy AI Prompt" action built by the extracted prompt helper (below). Postpone is keyed by
`{file + appVersion}` in the same migration state file (reuses
`SettingsMigrationStateStore`), so unknown-key warnings also reactivate on the next release.

### Shared "Copy AI Prompt" helper

Extract `MigrationView.buildPrompt(backupURL:)` into a non-UI helper, e.g.
`Sources/Nehir/Core/Config/ConfigAssistancePrompt.swift`:

```swift
enum ConfigAssistancePrompt {
    /// Builds a prompt for an AI assistant to consult release notes and migrate
    /// equivalent values. Used by Diagnostics (unknown keys, enforced migrations)
    /// and by the blocking recovery window (parse/type failures).
    static func prompt(
        kind: AssistanceKind,
        appVersion: String,
        affectedFile: URL,
        details: [String],          // unknown key paths, or stale entries / error text
        backupURL: URL?
    ) -> String
}
```

Both Diagnostics and the repurposed blocking window consume it. `MigrationView` is renamed
to something accurate (e.g. `ConfigRecoveryView`) and its copy text is updated to reflect
that it is shown only for invalid/unsupported config, not for ordinary unknown keys.

## Phase 1 — Unknown-key round-trip in the codec (foundation)

No UI change. Pure correctness fix; unblocks the rest.

- Add per-table unknown-key overflow to `CanonicalTOMLConfig` and its nested tables (scope:
  known tables; see Non-goals).
- `encode` re-emits captured unknown keys under their original tables.
- Pin top-level unknown-table behavior explicitly (preserve vs drop) with a test — do not
  leave it implicit.

Validation:

- `swift build` clean, `swift test` green.
- Rewrite `unknownNiriKeysAreIgnoredAndNotReencoded`
  (`SettingsTOMLCodecTests.swift:89-104`) → `unknownNiriKeysRoundTripThroughReencode`:
  the final assertion flips from erasure to preservation.
- Add the issue's literal repro as a test: inject `futureSetting = "keep-me"` under
  `[general]` and `futureNiriSetting = true` under `[niri]`, mutate `gaps.size`, encode,
  assert both unknown keys survive alongside the new value.
- Add: bad value for a *known* key still throws (guard that the capture mechanism didn't
  weaken `mainSettingsRejectInvalidPresentValues`).

**Do not** remove the launch strip in this phase. After Phase 1 the strip's
`cleanSettingsFile` decode→encode stops *dropping* unknown keys (they now round-trip), so
the strip becomes a no-op rewrite — harmless but pointless. Removal is Phase 3.

## Phase 2 — Unknown-key Diagnostics (non-blocking)

Surface category 2 in Diagnostics, using the preserved keys.

- Extract `ConfigAssistancePrompt` from `MigrationView.buildPrompt`.
- Add `detectUnknownKeys(...)` (preservation-aware; see Proposed model).
- Add `SettingsDiagnosticsIssue.unknownKeys` and a Diagnostics view row offering **Copy AI
  Prompt** + **Postpone Warning** (release-scoped, via `SettingsMigrationStateStore`).
- Unknown-key warnings count toward the Diagnostics badge in `SettingsSidebar`.
- No file rewrite anywhere on this path.

Validation:

- `swift test` green.
- New test: a `settings.toml` with an unknown key under a known table produces an
  `unknownKeys` Diagnostics issue and **the file is byte-for-byte preserved** across a
  load→mutate→save cycle (assert the unknown key remains).
- New test: Postpone suppresses the warning/badge only for the current app version;
  next-version detection re-shows it (mirror `SettingsMigrationStateStoreTests`).

## Phase 3 — Remove the launch-time unknown-key strip

Now that unknown keys are preserved (Phase 1) and surfaced non-blockingly (Phase 2), the
launch gate for unknown keys is obsolete.

- In `AppDelegate.finishBootstrap` (`Sources/Nehir/App/AppDelegate.swift:48-66`), **remove**
  the `detectConfigMismatches → backup → cleanSettingsFile → showMigration` path for
  unknown keys.
- Bootstrap proceeds directly to `continueBootstrap`; unknown keys (if any) appear in
  Diagnostics after launch.
- Update the header comment on `ConfigMismatchDetector` / the "Phase 0" comment block —
  they currently describe the strip as the design.
- `ConfigMismatchDetectorTests`: the "detects unknown key" cases move to the
  `detectUnknownKeys` test target; the parse-failure-returns-empty case stays with the
  failure path.

Validation:

- `swift build` clean, `swift test` green.
- Grep proves no remaining caller of the unknown-key strip; `cleanSettingsFile` is gone or
  repurposed.
- Regression: launching with an unknown key does **not** create a backup and does **not**
  block startup (a launch-level test or an AppDelegate-level test).

**Decision point (do not decide for the implementer):** whether to keep
`detectConfigMismatches` as a thin alias delegating to `detectUnknownKeys` during a
transition, or delete it outright. Prefer deletion unless an external caller exists.

## Phase 4 — Repurpose the blocking recovery window for category 4 only

The window stays, but its meaning narrows to "config cannot be safely applied".

- Rename `MigrationView` → `ConfigRecoveryView`; update title/copy from "Config Update
  Required / ignored entries" to something like "Couldn't load settings.toml" with the
  specific parse/decode error.
- It is shown only when: TOML parse fails, a known key has a wrong type, an
  enforced-migration old format is present, or the codec otherwise can't produce a usable
  `SettingsExport`.
- It uses `ConfigAssistancePrompt` (Phase 2). Where a backup is created for an enforced
  migration, the backup path is included in the prompt.
- It **does not** rewrite by default. Rewriting (backup + clean rewrite) is, if kept at
  all, an explicit user action on this screen, not an automatic pre-step.

Validation:

- `swift test` green.
- The recovery window is reachable only from a genuine load failure, not from mere unknown
  keys (covered by Phase 3 regression).
- Copy text reviewed against the "are you seriously showing this to an end user" bar.

## Rollout strategy

Small, independently-shippable PRs, ordered by dependency:

1. **Phase 1** (codec round-trip) — ship first; it's the correctness foundation and makes
   the later phases safe. Includes flipping the codified-loss test.
2. **Phase 2** (unknown-key Diagnostics) — depends on Phase 1 (must not claim "kept" while
   the save path still drops).
3. **Phase 3** (remove launch strip) — depends on Phases 1+2 (otherwise removing the strip
   re-exposes the silent in-session loss from BarutSRB/OmniWM#410).
4. **Phase 4** (recovery window narrowing) — can follow Phase 3; mostly copy + trigger
   conditions.

Phases 1→2→3 are dependency-ordered and must not be reordered. Phase 4 is independent of
Phase 3's mechanics but should land after, so the blocking window's only remaining triggers
are real failures.

## Risks

- **Premature removal of the strip (Phase 3 before Phase 1).** If the launch strip is
  removed before the codec round-trips, the in-session save path silently drops unknown
  keys — reintroducing BarutSRB/OmniWM#410's literal repro with no guard at all. Mitigation: hard
  ordering Phase 1 → Phase 3; the Phase 1 test flip is the gate.
- **Round-trip fidelity drift.** Capturing unknown keys as `TOMLValue` and re-emitting them
  must preserve value shape (ints stay ints, arrays/dates/datetimes survive, comments are
  *not* expected to survive — see discovery doc's "prefer a correct canonical file over a
  lossy partial rewrite" note, generalized here to "keys preserved; formatting/comments
  may normalize"). Mitigation: the repro test asserts key *presence and value*, not byte
  equality.
- **Top-level unknown-table ambiguity.** If the first cut drops unknown top-level tables,
  that is a *new* silent loss at the table level. Mitigation: pin the behavior explicitly
  in Phase 1 with a test, and file a follow-up if "drop" is chosen temporarily.
- **Conflation of "unknown key" and "wrong type".** A known key with a wrong type already
  throws today (`mainSettingsRejectInvalidPresentValues`); it must keep throwing and route
  to category 4, not become a "preserved unknown key". Mitigation: the Phase 1 type-mismatch
  test is mandatory.
- **Postpone-state namespace collision.** Unknown-key warnings and soft migrations share
  `SettingsMigrationStateStore`. Keying unknown-key postpone by `file + appVersion` (not by
  a migration id) avoids collisions; confirm in Phase 2 tests.

## Success criteria

- Unknown keys inside known `settings.toml` tables survive load→mutate→save (Phase 1); the
  codified-loss test is inverted.
- Unknown keys appear as a non-blocking Diagnostics issue with Copy AI Prompt + Postpone
  Warning, and the file is not rewritten (Phase 2).
- The launch-time unknown-key strip is gone; startup is not blocked by mere unknown keys
  (Phase 3).
- The blocking window fires only for invalid/unsupported config (parse/type failure,
  enforced migration), uses the shared prompt helper, and does not auto-strip (Phase 4).
- The four-category split in "Goal" is the single source of truth: Diagnostics owns
  categories 1–3, startup recovery owns category 4, with no overlap.

## Related

- Discovery: `discovery/20260616-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md`
- Policy doc: `docs/SETTINGS_MIGRATIONS.md`
- Soft-migration registry (shipped): `Sources/Nehir/Core/Config/SettingsMigrationRegistry.swift`,
  `SettingsMigrationStateStore.swift`

## Implementation reference (as-built)

Merged from the implementation-context notes that accompanied `b7cfb91e`. Line
numbers are from that commit and drift over time — re-locate by symbol.

### `settings.toml` codec and persistence

- `Sources/Nehir/Core/Config/SettingsTOMLCodec.swift:4-16` — only first-party file
  importing `TOML`; `encode(_ export:)` builds `CanonicalTOMLConfig(export:)`, configures
  `TOMLEncoder.outputFormatting = [.sortedKeys, .prettyPrinted]`, then encodes; `decode(_:)`
  decodes `CanonicalTOMLConfig` and immediately returns `canonical.toSettingsExport()`.
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift` — static schema tables
  (`general`, `focus`, `mouseWarp`, `gaps`, `niri`, `borders`, `workspaceBar`, `gestures`,
  `statusBar`, `appearance`, …); `init(export:)` constructs only modeled fields;
  `toSettingsExport()` maps canonical schema back to `SettingsExport` (split config state
  is reset to defaults/empty here); every `init(from:)` opens a `CodingKeys` container,
  decodes known keys, and stashes unknowns into per-table overflow.
- `Sources/Nehir/Core/Config/SettingsExport.swift` — the in-memory shape; carries the
  unknown-key overflow needed to survive the `decode → SettingsExport → encode` boundary.
- `Sources/Nehir/Core/Config/SettingsTOMLUnknownValue.swift` — the `Codable` dynamic
  value wrapper for captured unknown values (see dependency notes below).
- `Sources/Nehir/Core/Config/SettingsFilePersistence.swift` — `saveImmediately` writes a
  full atomic replacement for `settings.toml` via `SettingsTOMLCodec.encode(export)`;
  same-export fast path skips rewrite only when current fingerprint equals
  `lastObservedFingerprint` and `export == lastPersistedExport`. `readSnapshot()` decodes
  `settings.toml` first, then overlays auxiliary config (`hotkeys.toml`, `workspaces.toml`,
  app rules, monitor overrides).
- `Sources/Nehir/Core/Config/SettingsStore.swift:321-337,348-365` — store init applies
  `persistence.load()` and registers the external reload handler; `ensureConfigFilesAvailable()`
  seeds missing files only.

### Unknown-key detector

- `Sources/Nehir/Core/Config/ConfigMismatchDetector.swift` — `detectUnknownKeys(in:)`
  is the preservation-aware detector used by Diagnostics category 2 (compares raw key
  paths against modeled schema key paths, not against lossy re-encoded output).
  `detectConfigMismatches(in:)` is now a thin alias delegating to it. The reusable
  pattern is a recursive dynamic `AnyTOML: Decodable`, `AnyTOMLKey: CodingKey`, and
  `collectKeyPaths` preserving original key case while de-duping lowercased paths.

### Diagnostics UI / shared prompt

- `Sources/Nehir/Core/Config/SettingsDiagnosticsIssue.swift` — the issue enum
  (`.softMigration`, `.unknownKeys`) used by Diagnostics rows.
- `Sources/Nehir/Core/Config/ConfigAssistancePrompt.swift` — the shared non-UI
  `prompt(kind:appVersion:affectedFile:details:backupURL:)` helper consumed by both
  Diagnostics and the blocking recovery window.
- `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift` — renders an issue row per
  applicable migration / unknown-key set with Migrate or Copy AI Prompt + Postpone
  Warning; `SettingsMigrationWarningView` is the Warning-pattern row.
- `Sources/Nehir/UI/SettingsSidebar.swift:58-63` — badge count = display issues +
  accessibility issue + `pendingMigrations().count` (unknown-key warnings feed this count).

### Blocking recovery window (category 4 only)

- `Sources/Nehir/UI/Onboarding/ConfigRecoveryView.swift` (formerly `MigrationView`) —
  shown only for invalid/unsupported config (TOML parse failure, known key with wrong
  type, enforced-migration old format, codec can't produce a usable config). Uses
  `ConfigAssistancePrompt`; does not rewrite/strip by default.
- `Sources/Nehir/UI/Onboarding/OnboardingWindowController.swift` — presents the
  recovery window on a genuine load failure.
- `Sources/Nehir/App/AppDelegate.swift` — `finishBootstrap` no longer runs the
  unknown-key strip; bootstrap proceeds directly and unknown keys (if any) surface in
  Diagnostics after launch.

### Soft migration machinery

- `docs/SETTINGS_MIGRATIONS.md` — invariants: do not silently rewrite just because
  decoded; Diagnostics warning/badge; explicit Migrate; Postpone only current release;
  state outside config.
- `Sources/Nehir/Core/Config/SettingsMigrationRegistry.swift` — `SettingsMigrationDescriptor`,
  `applicableMigrations` vs release-scoped `pendingMigrations`; one descriptor
  (`workspaces-array-to-keyed-tables`); `WorkspacesConfigMigration.migrate(fileURL:)`
  backs up then rewrites `workspaces.toml`.
- `Sources/Nehir/Core/Config/SettingsMigrationStateStore.swift` —
  `settings-migration-state.json` under the state dir; API is keyed
  `{migrationID: appVersion}` (`isPostponed`, `postpone`, `clearPostpone`); private state
  writes (`0700` dir, `0600` file temp, sorted pretty JSON). Unknown-key postponement
  reuses this store under a namespaced stable key (issue kind + file path).

### Dependency notes

- `Package.swift`: dependency is `swift-toml` from `2.0.0`; Swift language mode 6, macOS 15.
- The dependency's `TOMLValue` does **not** conform to `Codable` upstream
  (`.build/checkouts/swift-toml/.../Value.swift`), so arbitrary unknown values are carried
  through the local `Codable` wrapper `SettingsTOMLUnknownValue` rather than via `TOMLValue`
  directly. Do not assume `TOMLValue` can be decoded/encoded directly.

### Auxiliary codecs (explicit non-goal)

- `Sources/Nehir/Core/Config/HotkeysTOMLCodec.swift` and `WorkspacesTOMLCodec.swift` are
  manual TOML-ish codecs and were **not** in scope for unknown-key preservation in this
  plan — track the siblings as a follow-up. `WorkspacesTOMLCodec.swift` supports legacy
  `[[workspace]]` detection for the current soft migration.

### As-built design traps

- **API-boundary loss:** unknowns captured in `CanonicalTOMLConfig` would be discarded
  when converting to `SettingsExport` unless the overflow is carried through `SettingsExport`
  itself (both `decode → SettingsExport` and `encode(SettingsExport)`). The codec API now
  carries it.
- **Equatable interaction:** carrying preservation metadata on `SettingsExport` can
  perturb the same-export no-rewrite fast path and equality-based tests. Equality must
  ignore overflow so semantically equal settings stay equal.
- **Detector redesign:** once the codec round-trips, the old lossy round-trip-diff
  detector stops reporting unknown keys; `detectUnknownKeys` compares raw key paths
  against modeled schema key paths instead. Verify known paths are derived from a
  defaults/canonical schema encode.
- **Wrong-type conflation:** a known key with invalid type must continue throwing / route
  to category 4, never be preserved as unknown.
- **Diagnostics path is read-only:** the unknown-key Diagnostics path must not back up,
  clean, or write the file.
- **Postpone namespace:** unknown-key postponement reuses `SettingsMigrationStateStore`
  under a namespaced key (issue kind + file path), not a migration id, to avoid collisions.
- **Nested tables:** the raw collector emits both table and leaf paths (e.g.
  `workspaceBar.width`); verify actual table context in test data before relying on string
  append.
- **Top-level unknown tables:** behavior (preserve vs drop) is pinned by test; dropping
  them would be a silent data-loss variant.
