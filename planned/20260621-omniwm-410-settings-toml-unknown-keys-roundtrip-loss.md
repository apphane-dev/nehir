# OmniWM #410 — Settings TOML unknown-keys round-trip loss

**Status:** completed — no new action. The discovery's recommendation already
shipped on `main` as commit `b7cfb91e` ("Preserve and surface unknown settings
keys instead of stripping them") and is recorded in
`completed/20260616-unified-config-diagnostics-and-migration-policy.md`. This
plan exists only to point a worker at the completed work.
**Source discovery:** `discovery/20260616-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md`
**Superseded by (shipped):** `completed/20260616-unified-config-diagnostics-and-migration-policy.md`
**Cluster:** `noop/20260616-omniwm-169-settings-json-full-export.md` (PR #169 —
closed-without-merge upstream, judged not applicable to nehir; same root cause
owned by this ticket).

All source references were re-verified against the main Nehir source tree at
`e7b246b6` on 2026-06-21. Re-verify before editing; line numbers drift.

## TL;DR

The discovery's verdict (🔴 applies; `SettingsTOMLCodec` drops every key it does
not statically model, and the launch-time strip destroys them before the UI
appears) was **correct, and the recommended fix has already landed** — with a
broader scope than the discovery's minimal #410 cut. As part of the unified
config-diagnostics policy, commit `b7cfb91e`:

1. made `CanonicalTOMLConfig` capture unknown keys per known table at decode and
   re-emit them at encode (round-trip), carrying the overflow through
   `SettingsExport` itself;
2. flipped the codified-loss test from erasure to preservation and added the
   issue's literal repro as a test;
3. introduced a preservation-aware `detectUnknownKeys(in:)` and a non-blocking
   `SettingsDiagnosticsIssue.unknownKeys` Diagnostics row (Copy AI Prompt +
   Postpone Warning), with no file rewrite;
4. **removed** the `AppDelegate.finishBootstrap` unknown-key strip
   (`detectConfigMismatches → backup → cleanSettingsFile → showMigration`) and
   renamed `MigrationView` → `ConfigRecoveryView`, which now fires only for
   genuine load failures (parse / wrong-type / enforced migration).

There is nothing further to implement for #410 as scoped. A worker arriving here
should **stop** and treat #410 as closed by `b7cfb91e`.

## What shipped (verified in `main` at `e7b246b6`)

Mapping the discovery's five recommendation items to the as-built source:

1. **Capture unknown keys at decode.** Each known-table decoder opens its
   container and calls
   `SettingsTOMLUnknownValue.decodeUnknownFields(from:excluding:)`, stashing
   non-modeled keys into a per-table `unknownFields: [String: SettingsTOMLUnknownValue]`
   (`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:43` and the per-table
   `init(from:)` overrides, e.g. `:497`, `:526`, `:546`). The dynamic-key pattern
   the discovery pointed at (`ConfigMismatchDetector`'s `AnyTOMLKey`) is
   reused via the new `Sources/Nehir/Core/Config/SettingsTOMLUnknownValue.swift`.
2. **Re-emit at encode.** Each table's `encode(to:)` uses a dynamic
   `SettingsTOMLDynamicKey` container and writes modeled keys then captured
   unknown keys, preserving the existing `.sortedKeys`/`.prettyPrinted`
   formatting. The overflow is carried across the `decode → SettingsExport →
   encode` boundary by
   `Sources/Nehir/Core/Config/SettingsExport.swift:100-103`
   (`settingsTOMLUnknownFields`), so the in-session save path no longer drops
   unknown keys.
3. **Policy decided and strippers reconciled.**
   - `Sources/Nehir/Core/Config/ConfigMismatchDetector.swift:19`
     (`detectUnknownKeys(in:)`) is preservation-aware: it compares the raw TOML
     tree to schema key paths derived from `CanonicalTOMLConfig.CodingKeys`, so
     captured-but-unmodeled keys are still reported as Diagnostics without being
     destroyed. `detectConfigMismatches(in:)` (`:40`) survives as a thin
     deprecated alias.
   - The launch strip is gone. `AppDelegate.finishBootstrap`
     (`Sources/Nehir/App/AppDelegate.swift:57-76`) now only calls
     `settingsLoadFailureDetails(settingsURL:)` (`:64`) and, on a genuine load
     failure, `OnboardingWindowController.shared.showConfigRecovery(...)`
     (`:65`). There is no `cleanSettingsFile`, no
     `createTimestampedSettingsBackup`, and no `showMigration` on the unknown-key
     path. Unknown keys surface as a non-blocking Diagnostics row via
     `Sources/Nehir/Core/Config/SettingsDiagnosticsIssue.swift`
     (`.unknownKeys(UnknownSettingsKeysIssue)`) and the shared
     `Sources/Nehir/Core/Config/ConfigAssistancePrompt.swift`.
   - `Sources/Nehir/UI/Onboarding/MigrationView.swift` was renamed to
     `Sources/Nehir/UI/Onboarding/ConfigRecoveryView.swift` and fires only for
     invalid/unsupported config; it does not auto-strip.
4. **First cut scoped to known tables** — see "Discovery corrections / decisions"
   below for the resolution of the top-level-table ambiguity.
5. **Test rewrite.**
   `unknownNiriKeysAreIgnoredAndNotReencoded` is now
   `unknownNiriKeysRoundTripThroughReencode`
   (`Tests/NehirTests/SettingsTOMLCodecTests.swift:95`) with the final assertion
   flipped to `#expect(reencoded.contains(unknownKey))`. The issue's literal
   repro is codified as `unknownKeysSurviveLoadMutateSaveAcrossTables`
   (`:116`): seeds `futureSetting = "keep-me"` under `[general]` and
   `futureNiriSetting = true` under `[niri]`, mutates `gaps.size` to `23`, and
   asserts both unknown keys survive alongside `size = 23`.

## Discovery corrections / decisions

The discovery was accurate; no symbol or location it cited required correction.
Two decisions worth pinning for anyone re-reading the discovery against the
as-built:

- **The fix landed with a broader scope than the discovery's minimal #410 cut.**
  The discovery recommended a codec-only round-trip plus reconciling the two
  strippers. The shipped work folded both into a unified four-category
  config-diagnostics policy (see the completed doc's "Goal" table). This is a
  superset of the recommendation, not a deviation from it; the codec round-trip
  is Phase 1 of that policy.
- **Top-level unknown tables are still dropped (the discovery's open decision
  point #4 was resolved as "drop").** The top-level
  `CanonicalTOMLConfig.init(from:)` (`:442-460`) opens a container keyed only by
  its `CodingKeys` and does **not** call `decodeUnknownFields`, and its
  `encode(to:)` (`:462-474`) writes only modeled tables. So unknown keys *inside*
  known tables (`[general]`, `[niri]`, …) round-trip, but an unknown
  **top-level table** (e.g. `[someFutureFeature]`) is silently lost on save.
  This matches the discovery's explicit first-cut scope ("scope the first cut to
  known tables") and the completed plan's Non-goals, but it is a real residual
  data-loss variant — track it as a follow-up, do not assume it is covered.

## Validation

No new code to validate. To confirm the fix is already green on `main`:

```bash
swift build
swift test --filter SettingsTOMLCodecTests
swift test --filter ConfigMismatchDetector   # detectUnknownKeys coverage
swift test --filter SettingsDiagnostics      # non-blocking unknown-key row
# Regression: launching with an unknown key does not block or rewrite settings.toml
```

The shipped tests that lock the behavior in are
`unknownNiriKeysRoundTripThroughReencode` and
`unknownKeysSurviveLoadMutateSaveAcrossTables`
(`Tests/NehirTests/SettingsTOMLCodecTests.swift:95,116`).

## Follow-ups (out of scope for #410)

These are the only pieces of the discovery's recommendation not yet done. Both
are **separate tickets**, not part of #410:

- **Sibling auxiliary codecs.** `Sources/Nehir/Core/Config/HotkeysTOMLCodec.swift`
  and `Sources/Nehir/Core/Config/WorkspacesTOMLCodec.swift` are manual TOML
  codecs that still drop unknown keys (no `SettingsTOMLUnknownValue` usage). The
  discovery explicitly scoped #410 to `settings.toml` and flagged the siblings as
  a follow-up; the completed plan reiterates this under Non-goals. Track
  separately.
- **Unknown top-level tables.** As noted above, an unknown top-level table is
  still silently dropped. If preserving unknown top-level tables is wanted later,
  the top-level `CanonicalTOMLConfig` decoder/encoder (`:442-474`) would need the
  same `decodeUnknownFields`/dynamic-key-encode treatment the per-table decoders
  already use. File as its own ticket; do not expand #410 to cover it.
