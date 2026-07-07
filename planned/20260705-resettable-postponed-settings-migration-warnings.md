# Make postponed settings-migration warnings resettable from Diagnostics — Plan

Re-verified against main 7a025b78 on 2026-07-07.

Small UX change to the Diagnostics settings tab: once a settings-migration /
unknown-keys warning has been **postponed**, there is currently no way to bring
it back short of editing state on disk. The postponed state shows a disabled
`Postponed` button and stays hidden for the current app version. This change
lets the user un-postpone individual warnings and reset all postponed settings
warnings at once.

Status: **valid, not shipped on `main`** — the full change was prototyped as
commit `ff69764e` ("Make postponed migration warnings resettable"), but that
commit is not an ancestor of `main` 7a025b78. Current `main` still has no
`Show Warning Again`, `Reset Postponed Settings Warnings`, or
`postponedSettingsIssueIds` symbols under `Sources/Nehir`, so this remains a
planned change. If the side commit is unavailable, re-apply from the diff shape
below.

---

## What it does

- **Un-postpone a single warning.** In `SettingsMigrationWarningView` and
  `UnknownSettingsKeysWarningView`, replace the disabled `Postponed` button with
  an active **"Show Warning Again"** button that calls a new `onResetPostpone`
  closure, clearing that warning's postpone record.
- **Reset all postponed settings warnings.** Add a **"Reset Postponed Settings
  Warnings"** bordered button to the Diagnostics tab, shown only when
  `postponedSettingsIssueIds` is non-empty, which clears every postponed record
  matching a currently-applicable issue for the current app version.
- Both paths clear via `migrationStateStore.clearPostpone(migrationID:)`, refresh
  the issue list, and post `.settingsMigrationStateDidChange` so the UI updates.

## Files touched

- `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift`:
  - New `@State private var postponedSettingsIssueIds: Set<String>`.
  - `refreshSettingsIssues()` now also computes `postponedSettingsIssueIds` from
    `migrationStateStore.load().postponed`, filtered to records whose
    `appVersion == appVersion` and whose id is in the current applicable-issue
    postpone-id set.
  - New `resetPostpone(migrationID:)` and `resetPostponedSettingsWarnings()`.
  - `SettingsMigrationWarningView` / `UnknownSettingsKeysWarningView` gain an
    `onResetPostpone: () -> Void` and swap the disabled `Postponed` button for an
    active "Show Warning Again".
- `.changeset/…-make-postponed-settings-migration-warnings-reset.md` — `patch`,
  "Make postponed settings migration warnings resettable from Diagnostics".

## How to land

The side implementation was reported to pass `mise run format:check && mise run
lint && mise run build`, but it has not shipped. Land it independently from a
fresh branch off `main`; if `ff69764e` is unavailable, re-apply from the diff
described above — it is self-contained and touches only
`DisplayDiagnosticsSettingsTab.swift` plus its changeset.

## Follow-ups / tests

- No tests shipped with the original commit. Consider a view-model-level test
  that: postpones an issue, asserts it appears in `postponedSettingsIssueIds`,
  calls `resetPostpone`, and asserts the record is cleared and the issue
  re-surfaces. `migrationStateStore` should be injectable in the test harness.
- Confirm `clearPostpone(migrationID:)` exists on the store used here and is the
  correct inverse of the postpone path for both migration and unknown-keys
  issues (they share the id space via `SettingsDiagnosticsDetector.postponeID`).
