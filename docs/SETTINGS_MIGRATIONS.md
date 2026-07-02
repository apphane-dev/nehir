---
title: Settings Migrations
---

# Settings Migrations

Nehir prefers stable, human-readable config files, but config formats can still improve when an existing shape becomes awkward. Format changes use a gradual policy so dotfiles are not silently rewritten during normal decode.

## Goals

- Keep configs hand-editable and friendly to dotfiles managers.
- Decode old and new formats during the compatibility window.
- Never rewrite a config file just because it was decoded.
- Make pending changes visible in Settings → Diagnostics.
- Let users migrate explicitly.
- Let users postpone warning/badge state only while a migration is newly introduced.
- Reactivate postponed warnings on the next release.
- Publish each migration's phase and enforcement plan.

## Scope: migrations vs unknown keys

Soft migrations (this document) are about **config format changes** — an old shape the schema once accepted being replaced by a new canonical shape (`[[workspace]]` → keyed tables). They are user-visible format upgrades with an introduced/deprecated/enforced lifecycle.

**Unknown keys are a different concern.** A key the current schema simply doesn't model (from a newer Nehir version, a typo, or a hand edit) is *not* a migration: there is no old→new format change to perform. Unknown keys are valid TOML, are preserved on save (see [Configuration Principles](CONFIGURATION.md)), and surface as a non-blocking Diagnostics warning with **Copy AI Prompt**, **Postpone Warning**, and **Remove Unknown Keys**. They share the postpone state store and the Diagnostics/sidebar/menu/What's-New surfacing, but they have no registry entry and no lifecycle.

## Soft migration lifecycle

Use this lifecycle for user-owned config format changes where the old format can still be decoded safely.

### 1. New format introduced

The first release that introduces a replacement format must:

1. Add a decoder that accepts both the old and new formats.
2. Keep encoding/writing new configs in the new canonical format only.
3. Detect the old format without mutating files.
4. Show a Diagnostics warning/badge when old-format config is present and not postponed for the current release.
5. Keep the Diagnostics migration entry visible whenever the old format is present.
6. Offer:
   - **Migrate** — back up the old file and rewrite it to the new canonical format.
   - **Postpone Warning** — remove warning/badge state for the current app release only.

Postponing must not hide the migration entry or remove the **Migrate** control. It only downgrades the entry from warning to informational for the current release.

### 2. Old format deprecated

After at least one release in the introduced phase, a migration may move to deprecated. In this phase:

1. The decoder may still accept both old and new formats.
2. Diagnostics still shows the migration entry whenever the old format is present.
3. Diagnostics offers **Migrate** only.
4. **Postpone Warning** is not available.
5. Warning/badge state remains active until the file is migrated.

Use this phase when users have had a release window to postpone, but the project wants stale configs to stay visible until fixed.

### 3. Enforced migration / unsupported old format

A later release may remove the old decoder and migration action after the registry entry has announced that plan. In this phase:

1. The old format is no longer part of the supported config schema.
2. The dedicated migration code and Diagnostics migration entry are removed.
3. If stale config is detected or parsing fails, Nehir stops applying that stale file and shows the blocking **Couldn't load settings.toml** recovery window (the category-4 startup recovery screen). It offers a **Copy AI Prompt** and continues from defaults for the session — it never rewrites the file automatically.
4. The prompt (built by the shared `ConfigAssistancePrompt` helper) includes the app version, affected file, relevant stale entries or parse error, release/changelog links, and backup path when a backup exists.

This is the enforcement point: Nehir no longer promises to decode the old format in-app. The user gets explicit assistance instead of silent fallback or lossy automatic rewrite.

## Postpone state

Postpone decisions are runtime state, not config. Store them outside `~/.config/nehir`, for example under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/nehir/settings-migration-state.json
```

The same store backs both soft-migration warnings and unknown-key warnings, keyed by a stable id (`{migrationID}` for migrations, `unknown-settings-keys:{file path}` for unknown keys). This avoids id collisions while keeping one release-scoped postpone mechanism.

Suggested shape:

```json
{
  "postponed": {
    "workspaces-array-to-keyed-tables": {
      "appVersion": "0.12.0",
      "postponedAt": "2026-06-16T12:00:00Z"
    }
  }
}
```

A postponed warning is suppressed only when the current app version exactly matches the stored `appVersion`. On the next release, the same still-applicable migration warning becomes visible again. Postponing does not hide the migration entry itself; Diagnostics still shows the stale format information and a manual **Migrate** action.

Do not store postpone decisions in `settings.toml`, `workspaces.toml`, or other user config files.

## Migration registry requirements

Every supported config migration must have a registry entry containing:

| Field | Meaning |
|-------|---------|
| `id` | Stable machine-readable migration id. Used for postpone state. |
| `file` | Config file or directory affected. |
| `phase` | `introduced`, `deprecated`, or `enforced`. |
| `introduced` | First release containing the new format and compatibility decoder. |
| `deprecated` | First release where postpone is no longer available, if known. |
| `enforced` | First release where old-format support is removed, if known. |
| `detects` | How Nehir identifies stale config. |
| `old format` | Minimal example of the old format. |
| `new format` | Minimal example of the canonical format. |
| `user action` | What Diagnostics offers in the current phase. |
| `enforcement plan` | When/how the old format stops being decoded. |

## Current registry

### `reveal-partial-to-reveal-style`

| Field | Value |
|-------|-------|
| `id` | `reveal-partial-to-reveal-style` |
| `file` | `~/.config/nehir/settings.toml` |
| `phase` | `introduced` |
| `introduced` | TBD: first release that ships Reveal Style and Viewport Scroll Lock |
| `deprecated` | TBD: earliest release where **Postpone Warning** is removed |
| `enforced` | TBD: release where `revealPartial` migration support is removed |
| `detects` | The `[niri]` table contains a `revealPartial` key. |
| `user action` | Diagnostics offers **Migrate** and **Postpone Warning**. After postponing, warning/badge state is suppressed for the current release, but the entry and **Migrate** action remain available. |
| `enforcement plan` | Keep detecting `revealPartial` during the introduced phase. Move to deprecated before enforcement. In the enforced phase, remove dedicated migration support and report the stale key through standard settings recovery/unknown-key assistance. |

Old format:

```toml
[niri]
revealPartial = "snapClosest"
```

New canonical format:

```toml
[niri]
revealStyle = "closest"
```

Mapping:

| Old `revealPartial` | New `revealStyle` |
|---|---|
| `default` | `auto` |
| `snapClosest` | `closest` |
| `snapCenter` | `center` |
| `off` | `auto` |

Notes:

- The old `off` value has no persisted global equivalent. The replacement is the runtime per-workspace **Viewport Scroll Lock** toggle; migration writes `revealStyle = "auto"` and removes `revealPartial`.
- If both `revealPartial` and `revealStyle` are present, migration preserves the existing `revealStyle` value and removes only `revealPartial`.
- Fresh saves emit only `revealStyle`.

### `workspaces-array-to-keyed-tables`

| Field | Value |
|-------|-------|
| `id` | `workspaces-array-to-keyed-tables` |
| `file` | `~/.config/nehir/workspaces.toml` |
| `phase` | `introduced` |
| `introduced` | TBD: first release that ships the keyed-table decoder |
| `deprecated` | TBD: earliest release where **Postpone Warning** is removed |
| `enforced` | TBD: release where `[[workspace]]` decoding/migration support is removed |
| `detects` | The file contains one or more `[[workspace]]` array-of-table entries. |
| `user action` | Diagnostics offers **Migrate** and **Postpone Warning**. After postponing, warning/badge state is suppressed for the current release, but the entry and **Migrate** action remain available. |
| `enforcement plan` | Keep decoding `[[workspace]]` during the introduced phase. Move to deprecated before enforcement. In the enforced phase, remove dedicated migration support and show migration-assistance prompt if a stale file is still present. |

Old format:

```toml
[[workspace]]
name = "1"
monitor = "main"

[[workspace]]
name = "6"
displayName = "❤️"
monitor = "secondary"
```

New canonical format:

```toml
[1]
monitor = "main"

[6]
displayName = "❤️"
monitor = "secondary"
```

Notes:

- This migration intentionally stays close to the current workspace model: workspace names remain positive numeric IDs.
- No per-monitor slot model is introduced by this migration.
- `displayName` remains the compatibility name for the custom visible label unless a separate migration renames it later.
- The decoder accepts old and new formats in the introduced phase, but loading the file does not rewrite it.
- Fresh saves emit only the new keyed-table format.

## Diagnostics copy guidance

### Reveal Partial introduced phase

Suggested title:

```text
Update reveal setting
```

Suggested body:

```text
settings.toml uses the old revealPartial key. Nehir now uses revealStyle for where reveals land, and Viewport Scroll Lock for suppressing background automatic reveals. You can migrate now, or hide this reminder until the next Nehir update. A future Nehir update may require the new key.
```

Actions:

- **Migrate** — back up and rewrite `settings.toml` with `revealStyle`, removing `revealPartial`.
- **Postpone Warning** — record the migration id and current app version in the migration state file. This suppresses warning/badge state for the current release only, while keeping the migration entry and **Migrate** action visible.

### Workspaces introduced phase

Suggested title:

```text
Update workspace config
```

Suggested body:

```text
workspaces.toml uses the old [[workspace]] style. Nehir can still read it, but the new format is shorter: [1], [2], [6], etc. You can migrate now, or hide this reminder until the next Nehir update. A future Nehir update may require the new format.
```

Actions:

- **Migrate** — back up and rewrite `workspaces.toml` to keyed tables.
- **Postpone Warning** — record the migration id and current app version in the migration state file. This suppresses warning/badge state for the current release only, while keeping the migration entry and **Migrate** action visible.

### Workspaces deprecated phase

Suggested body:

```text
workspaces.toml uses the old [[workspace]] style. Please migrate to the new [1], [2], [6] format. A future Nehir update may require the new format.
```

Actions:

- **Migrate** — back up and rewrite `workspaces.toml` to keyed tables.

No postpone action is available in the deprecated phase.
