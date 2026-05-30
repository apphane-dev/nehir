---
title: Configuration Principles
---

# Configuration Principles

Nehir's config layout is designed around three priorities: **human readability**, **dotfiles-manager friendliness**, and **zero migration**.

## Directory Structure

```
~/.config/nehir/
├── settings.toml          # core behavior: gaps, borders, gestures
├── hotkeys.toml           # all keybindings + modifier trigger
├── workspaces.toml        # workspace list with monitor assignments
├── apprules.d/            # one file per app rule
│   ├── com-google-chrome.toml
│   ├── com-apple-safari.toml
│   ├── pip-floating.toml.sample       # inactive sample (rename to .toml to enable)
│   └── dialog-floating.toml.sample
└── monitors.d/            # per-monitor overrides (niri, bar, orientation)
    └── studio-display.toml
```

## Principles

### 1. One concern per file

`settings.toml` has no hotkeys, no app rules, no workspace definitions. Each file owns a single concern. You can `diff`, `grep`, or `git blame` a single file to understand one aspect of your setup.

### 2. Dotfiles-manager friendly

The split layout works naturally with stow, chezmoi, yadm, or bare git repos:

- **Selective sync**: commit `hotkeys.toml` and `apprules.d/` to your dotfiles; keep `settings.toml` machine-local.
- **No merge conflicts**: adding an app rule is a new file, not a new array entry in a monolithic config.
- **Machine-specific monitors**: `monitors.d/` overrides are per-display — different machines get different files.
- **Diffable**: small, focused files produce readable diffs.

### 3. Missing keys use defaults

When a new setting is added, existing config files continue to work — missing keys are filled from built-in defaults.

Inactive sample files use `.toml.sample` extension so they aren't parsed. Rename to `.toml` to activate.

### 4. Human-readable values everywhere

Hotkey bindings use names, not key codes:

```toml
# hotkeys.toml
modifierTrigger = "Option+Command"

[workspace]
switch = "Modifier+{N}"
moveTo = "Modifier+Shift+{N}"

[focus]
left = "Modifier+Left Arrow"
right = "Modifier+Right Arrow"
```

App rules use `[match]` / `[effect]` sections:

```toml
# apprules.d/com-google-chrome.toml
[match]
bundleId = "com.google.Chrome"

[effect]
minWidth = 500
minHeight = 375
```

Monitor overrides use `[match]` / `[niri]` / `[bar]` / `[orientation]` sections:

```toml
# monitors.d/ultrawide.toml
[match]
name = "LG HDR 5K"

[niri]
maxVisibleColumns = 3
```

### 5. Live reload

All config files and directories are watched with `DispatchSource` file system observers. Edits take effect immediately — no restart, no manual reload command.

### 6. Deterministic workspace identity

Workspace IDs are derived from workspace names via a stable hash, not random UUIDs. This means `workspaces.toml` can be shared across machines and workspace references in app rules (`assignToWorkspace = "3"`) are stable.

### 7. Ordered app rules

App rules in `apprules.d/` carry an `order` field to preserve specificity ordering. More specific rules (with title/role matchers) should come after generic rules. The order field is written automatically during save.

### 8. No runtime state in config

Runtime state (window restore catalog, command palette last mode) is stored separately in `~/.local/state/nehir/runtime-state.json` — never in the config directory. Your config stays clean and diffable.

## File Reference

| File | Required | Description |
|------|----------|-------------|
| `settings.toml` | Yes | Core behavior: general, focus, gaps, niri, borders, workspace bar, gestures, status bar, appearance |
| `hotkeys.toml` | No | Keybindings and modifier trigger. Defaults used if missing. |
| `workspaces.toml` | No | Workspace list. Built-in defaults used if missing. |
| `apprules.d/*.toml` | No | Per-app window rules. Empty directory = no rules. |
| `monitors.d/*.toml` | No | Per-monitor overrides. Empty directory = global settings only. |

## Inactive Samples

The `apprules.d/` directory includes `.toml.sample` files demonstrating advanced matchers:

- `pip-floating.toml.sample` — float browser Picture-in-Picture windows
- `dialog-floating.toml.sample` — float dialogs with workspace assignment
- `title-regex-workspace.toml.sample` — regex title matching with workspace routing

Rename any sample to `.toml` and edit values to activate.
