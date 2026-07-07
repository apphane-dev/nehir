# OmniWM PR #169 — "settings.json full canonical export" — Discovery

Source PR: https://github.com/BarutSRB/OmniWM/pull/169
Merge state: **closed without merge** upstream; judge the idea, not the branch.
Scope of this doc: determine whether the closed JSON-export/config-workflow PR
applies to nehir, whether its settings round-trip concern is already owned by
#410, and whether any distinct nehir action remains.

All file/line references were verified against the Nehir source tree
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace").
Re-verify before implementing; line numbers drift.

---

> **Filed under `discovery/noop/`** — #169 owns no new repo action. The PR's
> direct target is upstream's old monolithic `settings.json` export API
> (`exportData(incrementalOnly:)` / `exportSettings(incrementalOnly:)`), and those
> symbols are absent in nehir. nehir's editable-config workflow already creates
> and opens/reveals the live TOML config files. The remaining real loss mode —
> unknown TOML keys dropped on decode→encode — is already the sibling root issue
> `discovery/20260616-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md`.

## TL;DR

- **The upstream PR is a JSON-export workflow patch, while nehir no longer has a
  settings JSON export path.** `ffgrep exportData`, `ffgrep exportSettings`, and
  `ffgrep SettingsExportMode` in `Sources/Nehir` find no matching upstream API;
  nehir persists modeled settings through `SettingsTOMLCodec` plus auxiliary
  TOML/directories (`Sources/Nehir/Core/Config/SettingsTOMLCodec.swift:6`,
  `Sources/Nehir/Core/Config/SettingsFilePersistence.swift:142-158`).
- **Verdict:** ⚪ **Won't port / Not applicable.** The only overlapping bug class
  is the known unknown-key round-trip loss, and #410 already owns that fix
  (`discovery/20260616-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md:9-11`).

## Upstream PR: proposed fix and diff shape

PR #169 was closed without merge. The patch series begins with
"Make settings.json export full config by default": it changes upstream
`SettingsExport.exportData(incrementalOnly:)` and `SettingsStore.exportSettings`
defaults from `true` to `false`, then adds a regression test asserting default
export includes canonical hotkey bindings. The next settings commit replaces the
boolean with `SettingsExportMode { full, compact }`, wires settings UI buttons
for "Export Editable Config" / "Export Compact Backup", and adds reveal/open
settings-file actions and README copy for `~/.config/omniwm/settings.json`.

Representative upstream diff snippets:

```diff
-    func exportData(incrementalOnly: Bool = true, ...)
+    func exportData(incrementalOnly: Bool = false, ...)

-enum / boolean incrementalOnly
+enum SettingsExportMode { case full; case compact }
+Button("Export Editable Config") { try settings.exportSettings(mode: .full) }
+Button("Export Compact Backup") { try settings.exportSettings(mode: .compact) }
```

The branch later accreted many unrelated commits (AX/title-cache/performance,
app-rule, README, Ghostty, border changes), so the portable concept for this doc
is only the settings-file workflow and full-vs-compact export behavior.

## Provenance: is this nehir's code?

Partially applicable, but not in API shape. The current nehir config model is
not the old monolithic JSON export:

- `SettingsExport` exists as the in-memory modeled settings value
  (`Sources/Nehir/Core/Config/SettingsExport.swift:13`), and it includes hotkeys,
  workspace, app-rule, and monitor override fields
  (`Sources/Nehir/Core/Config/SettingsExport.swift:43`,
  `Sources/Nehir/Core/Config/SettingsExport.swift:62-67`).
- The upstream JSON export symbols are **not found** in nehir: no
  `exportData`, no `exportSettings`, no `SettingsExportMode`, and no settings
  `JSONEncoder` path under `Sources/Nehir/Core/Config`.
- The live persistence path is TOML: `SettingsTOMLCodec.encode(_:)` maps the
  export into `CanonicalTOMLConfig` (`Sources/Nehir/Core/Config/SettingsTOMLCodec.swift:6-10`),
  while `SettingsFilePersistence.saveImmediately(_:)` writes `settings.toml`,
  `hotkeys.toml`, `workspaces.toml`, `apprules.d`, and `monitors.d`
  (`Sources/Nehir/Core/Config/SettingsFilePersistence.swift:142-158`).

## The code in question

### nehir's main settings encoder is already canonical, not compact JSON

```swift
// Sources/Nehir/Core/Config/SettingsTOMLCodec.swift:6-10
static func encode(_ export: SettingsExport) throws -> Data {
    let canonical = CanonicalTOMLConfig(export: export)
    let encoder = TOMLEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(canonical)
}
```

`CanonicalTOMLConfig` is an explicit TOML schema with modeled tables only
(`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:15-26`), populated from the
full in-memory export (`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:147-223`).
There is no compact/diff mode equivalent to upstream PR #169.

### nehir splits the full editable config across files

```swift
// Sources/Nehir/Core/Config/SettingsFilePersistence.swift:142-158
let data = try SettingsTOMLCodec.encode(export)
try data.write(to: fileURL, options: .atomic)

let hotkeysData = HotkeysTOMLCodec.encode(export.hotkeyBindings)
try hotkeysData.write(to: hotkeysFileURL, options: .atomic)

let workspacesData = WorkspacesTOMLCodec.encode(export.workspaceConfigurations)
try workspacesData.write(to: workspacesFileURL, options: .atomic)

try AppRuleFileStore.write(export.appRules, to: appRulesDirectoryURL)
try MonitorOverrideFileStore.write(..., to: monitorsDirectoryURL)
```

This is the nehir analogue of "full canonical export," but as a live TOML config
folder rather than a single `settings.json` backup/export file.

### nehir already has create/reveal/open workflow for the live config

```swift
// Sources/Nehir/UI/ConfigurationFilesSection.swift:11-33
Section("Configuration") {
    LabeledContent("Config Folder") { ... Button("Reveal in Finder") { ... } }
    LabeledContent("Settings File") { ... Button("Edit") { ... } }
}
```

```swift
// Sources/Nehir/UI/SettingsFileWorkflow.swift:17-27
try settings.ensureConfigFilesAvailable()
switch action {
case .revealConfigFolder:
    revealFile([settings.configDirectoryURL])
case .openMainSettingsFile:
    guard openFile(settings.settingsFileURL) else { throw CocoaError(.fileNoSuchFile) }
}
```

`ensureConfigFilesAvailable()` seeds every missing config file/directory, not
just `settings.toml` (`Sources/Nehir/Core/Config/SettingsStore.swift:348-375`).
The settings UI calls this workflow from the General tab
(`Sources/Nehir/UI/SettingsView.swift:107-108`,
`Sources/Nehir/UI/SettingsView.swift:138-143`).

## Why this does not apply as a distinct port

1. **The broken upstream default is absent.** PR #169 changes a default argument
   from compact/incremental to full. nehir has no `incrementalOnly` or
   `SettingsExportMode`, so there is no default to flip and no JSON export button
   to relabel.
2. **The editable-config workflow is already stricter in nehir.** Instead of
   exporting a separate editable `settings.json`, nehir edits the live config:
   `ConfigurationFilesSection` exposes the config folder and main settings file
   (`Sources/Nehir/UI/ConfigurationFilesSection.swift:11-33`), and the workflow
   creates missing files first (`Sources/Nehir/UI/SettingsFileWorkflow.swift:17`).
3. **The actual remaining round-trip data loss is already #410.** nehir still
   drops unknown TOML keys because `decode` reads only `CanonicalTOMLConfig` and
   `encode` rebuilds only modeled tables (`Sources/Nehir/Core/Config/SettingsTOMLCodec.swift:13-15`,
   `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:296-308`). The sibling
   discovery explicitly names closed-without-merge PR #169 as part of that cluster
   and owns the preservation action
   (`discovery/20260616-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md:9-11`).

## Recommendation

Do **not** port PR #169. Keep #410 as the actionable settings round-trip ticket:
its fix should preserve unknown TOML keys across `SettingsTOMLCodec.decode` →
`encode` and reconcile that with nehir's launch-time mismatch cleanup. If a UX
follow-up is desired later, evaluate it as a nehir-native config-folder workflow,
not as a resurrection of upstream's closed `settings.json` export mode.
