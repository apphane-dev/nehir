# Hiro issue #410 — "Settings save drops unknown TOML keys (round-trip data loss)" — Discovery

Source issue: <https://github.com/BarutSRB/Hiro/issues/410>
Filed against: `BarutSRB/Hiro` (upstream of nehir — see `NOTICE.md`;
nehir is a fork of `BarutSRB/OmniWM`, which was renamed to Hiro).
Reporter tested upstream commit `fce3a2c5` ("Fix cursor warp for focus follows mouse").
Scope of this doc: determine whether nehir's settings persistence round-trips
(preserves) unknown/unmapped TOML keys or drops them on re-write, and locate the
exact code paths. This is treated as the **root issue** of the round-trip /
config-recovery cluster that also includes closed #322 and closed-without-merge
PR #169 / #346.

Every symbol/line reference below was independently verified against
`worktree-calm-meadow-6229` at `98f2429` ("Add more issue discoveries") on
2026-06-16. Re-verify before implementing; line numbers drift.

---

## TL;DR

- **Applies: nehir's TOML codec drops every key it does not statically model.**
  `SettingsTOMLCodec.encode(_:)` rebuilds a fresh `CanonicalTOMLConfig` from the
  in-memory `SettingsExport` (`Sources/Nehir/Core/Config/SettingsTOMLCodec.swift:6-11`);
  the hand-written `init(from:)` only ever reads its own `CodingKeys`
  (`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:296-306`), so unknown keys
  are gone the instant `decode` returns. The exact load→mutate→save repro in #410
  reproduces silently in nehir.
- **nehir is in one respect *worse* than upstream Hiro:** it additionally runs a
  **proactive launch-time strip**. `AppDelegate.finishBootstrap` calls
  `detectConfigMismatches` (`Sources/Nehir/App/AppDelegate.swift:59`); if any
  unknown key is found it backs up the file and calls `cleanSettingsFile`
  (`:62` → `:210-215`), which decode→encode→overwrites, deleting unknown keys
  before the UI even appears. This is nehir's own instance of the #322
  "settings.toml gets reset" symptom.
- **That launch gate is a partial guard, not a fix.** It reduces the
  *silent*-loss severity on a version skew (there is a timestamped backup +
  a migration window), but it still **destroys** the unknown keys from the live
  config and does nothing for the in-session save path. A real #410 fix (preserving
  unknown keys) would also make this gate stop firing — a design interaction the
  implementer must resolve.
- **Verdict:** 🔴 Open / Applies. The round-trip data loss is real and unfixed;
  the dropping is even codified by an existing test,
  `unknownNiriKeysAreIgnoredAndNotReencoded`
  (`Tests/NehirTests/SettingsTOMLCodecTests.swift:89-104`).

## Provenance: is this nehir's code?

Yes. Every symbol named upstream exists in nehir and matches the structure
described in the report:

- `Sources/Nehir/Core/Config/SettingsTOMLCodec.swift` — `encode`/`decode` static
  funcs (`:6`, `:13`). The only file importing `TOML`; the codec boundary the
  issue is about.
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift` — the `Codable` shape:
  struct + nested tables (`:15-145`), `init(export:)` (`:147`),
  `toSettingsExport()` (`:226`), hand-written `init(from decoder:)` decoders
  (`:296-306` top-level, per-table overrides `:313-445`).
- `Sources/Nehir/Core/Config/SettingsExport.swift` — the in-memory value type
  (`:13`).
- `Sources/Nehir/Core/Config/SettingsFilePersistence.swift` — on-disk
  read/write/watch for `settings.toml` and the auxiliary codec files.

This is a lineal fork, not coincidentally similar code.

## The code in question

### Encode — the drop happens here

```swift
// Sources/Nehir/Core/Config/SettingsTOMLCodec.swift:6-11
static func encode(_ export: SettingsExport) throws -> Data {
    let canonical = CanonicalTOMLConfig(export: export)
    let encoder = TOMLEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(canonical)
}
```

`CanonicalTOMLConfig(export:)` (`:147`) constructs a struct holding **only** the
statically-modelled tables (general/focus/mouseWarp/gaps/niri/borders/
workspaceBar/gestures/statusBar/appearance — `:15-145`). There is no
`extraKeys`/`unknownKeys` dictionary, no `superDecoder`, no `[String: Any]`
spillover. Anything not in the struct cannot be re-emitted.

### Decode — tolerant of *missing* keys, silently discards *unknown* keys

```swift
// Sources/Nehir/Core/Config/SettingsTOMLCodec.swift:13-16
static func decode(_ data: Data) throws -> SettingsExport {
    let canonical = try TOMLDecoder().decode(CanonicalTOMLConfig.self, from: data)
    return canonical.toSettingsExport()
}
```

The main `init(from decoder:)` (`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:296-306`)
opens a container keyed by `CodingKeys` and `decodeWithDefault`s each modeled table;
the per-table `init(from:)` overrides (`:313-445`) do the same for leaf keys.
Unknown keys are present in the decoded container but are never read, so they are
lost the instant `decode` returns. (Nehir relies on this for *graceful* missing-key
tolerance — `mainSettingsUsesDefaultsForMissingKeys`,
`Tests/NehirTests/SettingsTOMLCodecTests.swift:39` — but the same container
semantics make *extra* keys vanish.)

### Write path — atomic full overwrite, never merged with on-disk content

```swift
// Sources/Nehir/Core/Config/SettingsFilePersistence.swift:131,142-143
func saveImmediately(_ export: SettingsExport) throws {
    ...
    let data = try SettingsTOMLCodec.encode(export)
    try data.write(to: fileURL, options: .atomic)
```

`readSnapshot()` feeds back through `SettingsTOMLCodec.decode`
(`Sources/Nehir/Core/Config/SettingsFilePersistence.swift:428`), so a
load→mutate→save cycle on a file containing unknown keys drops them. The
short-circuit at `:133-140` (equality test `export == lastPersistedExport` at
`:136`) only skips the write when the in-memory export is **identical** to
`lastPersistedExport`; any real setting change writes the whole file and erases
unknown keys. (`SettingsStore.ensureConfigFilesAvailable`,
`Sources/Nehir/Core/Config/SettingsStore.swift:348`, also encodes+writes — the
encode call sits at `:354` — but only when the file is *absent*, so it is a
seeder, not a lossy-overwrite path.)

### nehir-specific: proactive launch-time strip (the #322 instance, in code)

```swift
// Sources/Nehir/App/AppDelegate.swift:50-66  (finishBootstrap, "Phase 0: config drift")
let settingsURL = storagePaths.configDirectory.appendingPathComponent("settings.toml", isDirectory: false)
let unknown = detectConfigMismatches(in: settingsURL)                    // :59
if !unknown.isEmpty {
    let backup = createTimestampedSettingsBackup(settingsURL: settingsURL)
    let cleanupError = backup.url == nil ? nil : cleanSettingsFile(settingsURL: settingsURL)  // :62
    OnboardingWindowController.shared.showMigration(
        unknownKeys: unknown, backupURL: backup.url, ...
    )
    return
}
```

```swift
// Sources/Nehir/App/AppDelegate.swift:210-215
private func cleanSettingsFile(settingsURL: URL) -> String? {
    do {
        let original = try Data(contentsOf: settingsURL)
        let export = try SettingsTOMLCodec.decode(original)      // :213
        let clean = try SettingsTOMLCodec.encode(export)         // :214
        try clean.write(to: settingsURL, options: .atomic)       // :215
        return nil
    } catch { return error.localizedDescription }
}
```

So at every launch, nehir (a) detects unknown keys, (b) makes a timestamped
backup, (c) **strips them** via the same lossy decode→encode, then (d) shows a
migration window. nehir's own detection code documents the mechanism — the header
of `detectConfigMismatches` states the schema round-trip works *because*
"Codable silently drops keys not in `CodingKeys`"
(`Sources/Nehir/Core/Config/ConfigMismatchDetector.swift:8-10`). The detector
itself proves the keys are dropped by re-encoding and diffing key paths
(`Sources/Nehir/Core/Config/ConfigMismatchDetector.swift:29-34`).

### Existing test codifies the (buggy) dropping behavior

```swift
// Tests/NehirTests/SettingsTOMLCodecTests.swift:89-104
@Test func unknownNiriKeysAreIgnoredAndNotReencoded() throws {
    var export = SettingsExport.defaults()
    export.niriBalancedColumnCount = 4

    let output = try #require(String(data: SettingsTOMLCodec.encode(export), encoding: .utf8))
    let unknownKey = "maxWindows" + "PerColumn"
    let edited = output.replacingOccurrences(
        of: "balancedColumnCount = 4",
        with: "balancedColumnCount = 4\n\(unknownKey) = 7")

    let decoded = try SettingsTOMLCodec.decode(Data(edited.utf8))
    #expect(decoded == export)

    let reencoded = try #require(String(data: SettingsTOMLCodec.encode(decoded), encoding: .utf8))
    #expect(reencoded.contains(unknownKey) == false)   // :104 — asserts unknown keys are ERASED
}
```

The final assertion (`:104`) is the smoking gun: the suite requires unknown keys
to be **absent** after re-encode. The reporter's proposed XCTest is this test with
the assertion inverted.

## Why it applies

1. **No round-trip container exists on the codec path.** A search of
   `Sources/Nehir/Core/Config/` for `extraKeys`/`unknownKeys`/`superDecoder`/
   `userInfo` on the codec returns nothing. The only `KeyedDecodingContainer`
   `allKeys` enumeration lives in a *separate, read-only* validator,
   `ConfigMismatchDetector` (`Sources/Nehir/Core/Config/ConfigMismatchDetector.swift:52`),
   backed by a dynamic `AnyTOMLKey: CodingKey` (`:94`). It only *detects/reports*
   mismatches — it does not feed captured keys back into the codec. So the
   infrastructure to enumerate unknown keys already exists in nehir; it is just
   used to warn+strip instead of preserve.
2. **The write is a full atomic overwrite**, not a merge (`SettingsFilePersistence.swift:143`).
3. **The dropping is intended-in-tests** (`SettingsTOMLCodecTests.swift:104`) and
   *intended-in-product* (the launch gate at `AppDelegate.swift:59-66` deliberately
   strips detected unknown keys).
4. **The in-session repro (#410's literal ask) reproduces silently.** With the
   codec as-is, injecting `futureSetting = "keep-me"` under `[general]` and
   `futureNiriSetting = true` under `[niri]`, then bumping a known setting and
   encoding, yields exactly the two failing assertions the reporter shows — there
   is no migration window on that path because `detectConfigMismatches` runs only
   at bootstrap.

### Partial mitigation (the 🟡 qualifier) — and why it doesn't close the issue

For the *cross-version/upgrade* sub-scenario (the #322 cluster), nehir has built a
guard: the bootstrap `detectConfigMismatches` → timestamped backup → migration
window path (`AppDelegate.swift:59-66`). So a downgrade/upgrade that leaves
unknown keys is **not silent** — the user gets a backup and a notice. But:

- The unknown keys are still **removed** from the live `settings.toml` by
  `cleanSettingsFile` (`:213-215`). The user's effective config loses them; recovery
  requires manually re-merging from the backup. The issue's "Expected" (keys
  *survive* the save) is not met.
- The guard does **not** cover the in-session save path at all — #410's exact
  repro is still silent.
- **Design interaction:** if the codec were fixed to preserve unknown keys,
  `detectConfigMismatches` would no longer see them (they survive the round-trip
  diff at `ConfigMismatchDetector.swift:29-34`), so the migration window would stop
  firing. The fix must therefore decide explicitly whether unknown keys should
  (a) silently coexist and be preserved, or (b) still be surfaced to the user while
  preserved. This is a product decision, not a mechanical port.

## Relationship to #322, #169 and #346 (cross-references)

- **Hiro issue #322 — "[Bug] v0.4.9 resets the settings.toml again" (closed).**
  Per the triage notes, this is the user-facing instance of the same cluster: a
  version upgrade reset users' `settings.toml`. nehir's `cleanSettingsFile`
  (`AppDelegate.swift:210-215`) is nehir's own active implementation of exactly
  that behavior — it deliberately rewrites the file minus unknown keys. #322 is the
  same root cause as #410; a #410 fix that preserves unknown keys would also
  neutralize the reset-on-upgrade symptom. (#322's upstream specifics were not
  independently fetched for this doc; conclusion rests on nehir code + triage
  metadata.)
- **Hiro PR #169 — "settings.json full canonical export" (closed, NOT merged).**
  Adjacent but **not the same fix, and not applicable to nehir.** nehir has **no
  settings.json path**: the only JSON usage app-wide is
  `Sources/Nehir/Core/Config/RuntimeStateStore.swift` (an unrelated runtime-state
  file) and `Sources/Nehir/Core/Input/HotkeyBinding.swift`; every user-facing
  config codec in `Sources/Nehir/Core/Config/` is TOML (`SettingsTOMLCodec`,
  `HotkeysTOMLCodec`, `WorkspacesTOMLCodec`). PR #169 expands *known* JSON output;
  #410 preserves *unknown* TOML input. Porting #169 would not close #410. (PR #169's
  diff was not fetched; the "not applicable" conclusion is grounded in the absence
  of a settings.json codec in nehir.)
- **Hiro PR #346 (closed-without-merge).** A second attack on the settings
  round-trip root. Not fetched individually for this doc; flagged here only as
  part of the same cluster — review its diff before implementing a fix to avoid
  duplicating a previously-rejected approach.

## Recommendation

Fix #410 in nehir by making the TOML codec **round-trip unknown keys** rather than
discard them, then reconcile the two deliberate-stripping sites. Concretely:

1. **Capture unknown keys at decode time.** Open the keyed containers against a
   dynamic `CodingKey` (the `AnyTOMLKey` pattern already exists at
   `Sources/Nehir/Core/Config/ConfigMismatchDetector.swift:94`), enumerate
   `container.allKeys` (`:52`), and stash any key not in the model into a
   per-table overflow (e.g. `[String: TOMLValue]` / raw fragments).
2. **Re-emit at encode time.** Have `CanonicalTOMLConfig` write modeled keys
   first, then append each captured unknown key under its original table; reuse
   the existing `.sortedKeys`/`.prettyPrinted` formatting
   (`SettingsTOMLCodec.swift:9`).
3. **Decide the policy, then update the two strippers:**
   - `Tests/NehirTests/SettingsTOMLCodecTests.swift:104` — flip the expectation
     from erasure to preservation (rename `unknownNiriKeysAreIgnoredAndNotReencoded`
     → e.g. `unknownNiriKeysRoundTripThroughReencode`).
   - `AppDelegate.cleanSettingsFile` (`:210-215`) + the Phase-0 gate
     (`:59-66`) + `ConfigMismatchDetector` (`:8-10`) — decide whether the
     migration window should still fire. If unknown keys are now preserved, the
     detector's round-trip diff (`:29-34`) will report none; either retire the
     launch strip or redefine "mismatch" as something the user opted into.
4. **Scope the first cut to known tables** (the issue's "Expected" scopes it to
   `[general]`/`[niri]` etc.); top-level unknown tables can be a follow-up.
5. **Follow-up (out of scope for #410):** the sibling auxiliary codecs
   `HotkeysTOMLCodec`/`WorkspacesTOMLCodec` (written by the same
   `saveImmediately` path, `SettingsFilePersistence.swift:145,148`) likely share
   the lossy pattern, but #410 is specifically about `settings.toml`. Track
   separately.

## Suggested tests   (omit if N/A)

Add to `Tests/NehirTests/SettingsTOMLCodecTests.swift`:

1. **Unknown key inside a known table survives load→mutate→save** — the issue's
   repro: inject `futureSetting = "keep-me"` under `[general]` and
   `futureNiriSetting = true` under `[niri]`, set `gaps.size = 24`, encode, and
   assert both unknown keys are present alongside `size = 24.0`.
2. **Unknown top-level table behavior is explicitly pinned** (preserve or
   intentionally drop) so the chosen scope is documented and regression-proofed.
3. **Rewrite `unknownNiriKeysAreIgnoredAndNotReencoded`** so the final assertion
   reflects preservation rather than erasure, renamed accordingly.
4. **Type-mismatch in a known key still rejects** — ensure the existing
   `mainSettingsRejectInvalidPresentValues` guarantee
   (`SettingsTOMLCodecTests.swift:48`; a bad value for a *known* key still
   throws) survives the new capture mechanism.
5. **Launch-strip regression** (in `ConfigMismatchDetectorTests` /
   `AppDelegate`-level tests): after the codec preserves unknown keys,
   `detectConfigMismatches` no longer reports them for a round-tripped file
   (i.e. the migration gate does not spuriously fire on its own output).
