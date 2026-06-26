---
title: Configuration Principles
---

# Configuration Principles

Nehir's config layout is designed around three priorities: **human readability**, **dotfiles-manager friendliness**, and **explicit migration**.

## Directory Structure

```
~/.config/nehir/
├── settings.toml          # core behavior: gaps, borders, gestures
├── hotkeys.toml           # physical keybindings
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

Missing keys are filled from built-in defaults as hand-edit tolerance. Nehir avoids silent config rewrites during normal decode.

**Unknown keys are preserved.** If `settings.toml` contains keys the current schema doesn't model (for example from a newer Nehir version or a typo), they survive a load → edit → save cycle instead of being dropped. They are valid TOML, so Nehir keeps them and surfaces them as a non-blocking warning in **Settings → Diagnostics** (with a **Copy AI Prompt**, **Postpone Warning**, and **Remove Unknown Keys** action). They never block startup and the file is never rewritten automatically.

Startup blocks only when the file genuinely cannot be loaded (TOML parse failure, a known key with the wrong type, or an enforced legacy format). In that case Nehir shows a **Couldn't load settings.toml** recovery window with a **Copy AI Prompt** and starts from defaults for the session — it does not rewrite your file.

When a format must change, it follows the gradual policy in [Settings Migrations](SETTINGS_MIGRATIONS.md): decode both formats during a compatibility window, warn in Diagnostics, and let users migrate explicitly or postpone for the current release.

Inactive sample files use `.toml.sample` extension so they aren't parsed. Rename to `.toml` to activate.

### 4. Human-readable values everywhere

Hotkey bindings use names, not key codes:

```toml
# hotkeys.toml
[workspace]
switch = "Option+Command+{N}"
moveTo = "Option+Shift+Command+{N}"

[focus]
left = "Option+Command+Left Arrow"
right = "Option+Command+Right Arrow"

[move]
windowToWorkspaceUp = "Hyper+Up Arrow"
windowToWorkspaceDown = "Hyper+Down Arrow"
```

## Default Shortcut Model

Default hotkeys are stored and shown as physical key chords.

The model is organized by action weight:

```text
Option+Command              navigate / focus / open UI
Option+Shift+Command        move the focused window
Control+Option+Command      larger-scope navigation
Hyper                       structural movement
```

Where:

```text
Hyper = Control+Option+Shift+Command
```

### Why Option+Command is the base

Nehir avoids simpler bases because they collide with common macOS behavior:

- **Control** conflicts with Mission Control, Spaces, terminal/readline shortcuts, and editor commands.
- **Control+Option** conflicts with VoiceOver, because macOS uses it as the VoiceOver modifier.
- **Option** alone conflicts with text editing, including word movement, word selection, and delete-word commands.

`Option+Command` is the least-bad built-in base for public defaults. It still has some app/menu conflicts, but fewer critical system-level conflicts than Control-based defaults.

If you prefer a single-key entry point for this base layer, the [Karabiner double-Command recipe](recipes/karabiner-double-command-sticky-command-option.json) makes double-tap-hold send `Command+Option` and double-tap-release enable sticky `Command+Option`.

Examples:

```text
Option+Command+Arrow   focus
Option+Command+Number  switch workspace
Option+Command+Space   command palette
```

### Why Shift means "move"

Shift is the "move the current thing" layer:

```text
Option+Command+Arrow          focus window
Option+Shift+Command+Arrow    move window

Option+Command+{N}            switch workspace
Option+Shift+Command+{N}      move window to workspace
```

This keeps related actions paired:

```text
without Shift = go there
with Shift    = move current window there
```

### Why Control adds larger scope

Control is not used as the base. It is added when the action operates at a broader scope than a single focused window:

```text
Control+Option+Command+Tab          switch to last workspace
Control+Option+Command+Left/Right   previous/next workspace
Control+Option+Command+{N}          focus column {N}
```

### Why Hyper is reserved for structural moves

Hyper is visually and physically distinct, so it is used for heavier actions that reshape layout or move things across boundaries:

```text
Hyper+Up/Down      move window to workspace up/down
Hyper+Left/Right   move column left/right
```

`Hyper+...` always means the physical four-modifier chord.

### Why column-to-workspace is unassigned

Column-to-workspace up/down is intentionally unassigned. Defaults like `Hyper+PageUp` and `Hyper+PageDown` are visually noisy in the UI, and moving an entire column to another workspace is advanced enough to keep out of the default model.

### Current default matrix

```text
Focus window                  Option+Command+Arrow
Last focused window           Option+Command+Tab
Move window                   Option+Shift+Command+Arrow

Switch workspace              Option+Command+Number
Move window to workspace      Option+Shift+Command+Number

Previous/next workspace       Control+Option+Command+Left/Right
Last workspace                Control+Option+Command+Tab

Focus column number           Control+Option+Command+Number
Focus first/last column        Option+Command+Home/End
Move column first/last         Control+Option+Command+Home/End

Move window workspace up/down Hyper+Up/Down
Move column left/right        Hyper+Left/Right

Toggle fullscreen             Option+Command+Return
Toggle native fullscreen      Option+Shift+Command+Return
Toggle focused window sticky  Unassigned
Toggle column tabbed          Option+Shift+Command+T
Toggle column full width      Option+Shift+Command+F
Balance sizes                 Option+Shift+Command+B
Raise all floating windows    Option+Shift+Command+R

Cycle column width            Option+Command+Comma/Period
Resize column                 Option+Command+-/=
Resize window height          Option+Shift+Command+-/=

Command palette               Option+Command+Space
Menu anywhere                 Option+Command+M
Overview                      Option+Command+O
```

Monitor focus is deliberately separate from the workspace/window model and uses `Control+Command+Tab` and `Control+Command+Grave`.

`Toggle column tabbed` normally switches the focused column between stacked and tabbed. If Nehir temporarily forced a column into overflow-tabbed mode because the stacked windows cannot fit at their minimum heights, the same command splits the windows into separate columns only while that overflow still exists. If the stack now fits, the command just clears the transient forced-tab state and preserves the column.

### Display and Dock recommendations

For the best Niri scrolling experience:

- Use an **auto-hide Dock**. A fixed Dock on the same physical edge used for parking hidden windows is a known degraded configuration: macOS may adjust parked external app windows to the Dock boundary and leave a Dock-width visible strip.
- Arrange displays **vertically** in macOS System Settings (`Displays > Arrange`) instead of side-by-side horizontally. Nehir parks transient offscreen tiled windows near the horizontal screen edge. With side-by-side monitors, those parked windows can bleed into the neighboring display because macOS does not allow fully hiding external app windows by position alone. A vertical monitor arrangement keeps the horizontal parking edges away from adjacent displays and avoids the most visible bleed artifacts.

The design goal is:

```text
small number of modifier patterns
easy to infer related commands
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

Rule effects are explicit and composable:

```toml
# Leave a helper overlay alone entirely.
[match]
bundleId = "com.example.Helper"
titleSubstring = "Overlay"

[effect]
manage = "ignore"

# Keep a media-style window visible across workspace switches.
[match]
bundleId = "org.mozilla.firefox"
titleSubstring = "Picture-in-Picture"

[effect]
layout = "float"
sticky = true
```

Supported effect values:

- `manage = "auto" | "ignore"` — `ignore` makes matching windows unmanaged. It wins over layout, sticky, sizing, and workspace effects.
- `layout = "auto" | "tile" | "float"` — chooses the tracked layout mode for managed matches.
- `sticky = true | false` — sets the sticky visibility effect for managed matches. `true` pins the window across workspaces; `false` opts matching windows out of sticky defaults such as Picture-in-Picture classification.
- `assignToWorkspace = "<raw workspace name>"`, `minWidth`, `minHeight` — existing placement and size effects.

Picture-in-Picture-like media windows are sticky by default when Nehir can classify them from AX/WindowServer facts. This is not a special window mode: PiP surfaces are still normal managed floating/tiling windows with an automatic sticky source, and the manual sticky toggle can unstick/restick them.

Classification is intentionally conservative. Some Chromium/Helium-style PiP windows expose reliable AX facts only after the PiP receives focus or a click, so Nehir may start tracking them after that first interaction rather than at the instant the surface appears.

Some browsers expose PiP as native macOS helper UI rather than a normal addressable media window. Safari, Dia, Arc, and Atlas/ChatGPT can create parented popup-level WindowServer children or generic `AXDialog` surfaces whose AX/WindowServer facts are indistinguishable from context menus or ordinary dialogs. Nehir intentionally does not auto-manage those surfaces as sticky PiP because doing so can pin context menus. When such an app provides stable AX facts, use an explicit app rule (for example matching bundle ID plus `axSubrole = "AXDialog"` or a title pattern) to opt that surface into `layout = "float"` and `sticky = true`.

Monitor overrides use `[match]` / `[niri]` / `[bar]` / `[orientation]` sections:

```toml
# monitors.d/ultrawide.toml
[match]
name = "LG HDR 5K"

[niri]
balancedColumnCount = 3
```

### 5. Live reload

All config files and directories are watched with `DispatchSource` file system observers. Edits take effect immediately — no restart, no manual reload command.

### 6. Deterministic workspace identity

Workspace IDs are derived from workspace names via a stable hash, not random UUIDs. This means `workspaces.toml` can be shared across machines and workspace references in app rules (`assignToWorkspace = "3"`) are stable.

### 7. Ordered app rules

App rules in `apprules.d/` carry an `order` field to preserve specificity ordering. More specific rules (with title/role matchers) should come after generic rules. The order field is written automatically during save.

### 8. No runtime state in config

Runtime state (window restore catalog, command palette last mode) is stored separately under `~/.local/state/nehir/` — never in the config directory. Migration postpone decisions also live in state, not config. Your config stays clean and diffable.

### 9. Monitor-independent restore

By default Nehir reattaches saved monitor bindings (workspace→display assignments, per-monitor overrides, and per-window restore) by **monitor identity** — the macOS display id plus the display name (e.g. `HP E27m G4`). This is safest for existing setups because per-monitor gaps, orientation, bar, and niri overrides often describe the physical display itself.

When you move the same Mac between different monitor sets — for example a dual-monitor desk at home and a different dual-monitor desk at the office — both the display id and the name change, so identity matching may no longer find the intended display and apps can land on the wrong monitor. Enable **Settings → Monitors → "Keep apps on the same screen position"** (`[general] ignoreMonitorIdentity = true`) to match displays by **layout position** instead of model/name. Apps, workspaces, and per-monitor settings then return to the same monitor slot — Main or Secondary — regardless of which physical display now occupies that position.

```toml
# settings.toml
[general]
ignoreMonitorIdentity = true
```

Use this mode when you want Nehir state to follow monitor slots across similar layouts, such as home ↔ office dual-monitor desks or swapped monitor models.

Leave it off when settings should follow a specific physical monitor, when you often rearrange display positions, or when temporary displays/projectors should not inherit external-monitor overrides.

App rules do not store monitor identity directly. If an app rule assigns a window to a workspace, this setting can still affect the result indirectly through that workspace's monitor assignment.

Position matching uses each saved monitor's top-left anchor point, which Nehir records alongside the identity. `workspaces.toml` gains optional `monitorAnchorX` / `monitorAnchorY` keys for `specific` assignments, and `monitors.d/*.toml` `[match]` sections gain optional `anchorX` / `anchorY`. These are written automatically while the monitor is connected; configs without them keep the previous identity-only behavior, so the change is fully backward compatible. An exact display-id match always wins first, so reconnecting the *same* monitor behaves as before.

## File Reference

| File | Required | Description |
|------|----------|-------------|
| `settings.toml` | Yes | Core behavior: general, focus, gaps, niri, borders, workspace bar, gestures, status bar, appearance |
| `hotkeys.toml` | No | Physical keybindings. Defaults used if missing. |
| `workspaces.toml` | No | Workspace list. Built-in defaults used if missing. |
| `apprules.d/*.toml` | No | Per-app window rules. Empty directory = no rules. |
| `monitors.d/*.toml` | No | Per-monitor overrides. Empty directory = global settings only. |

## Inactive Samples

The `apprules.d/` directory includes `.toml.sample` files demonstrating advanced matchers:

- `pip-floating.toml.sample` — float browser Picture-in-Picture windows
- `dialog-floating.toml.sample` — float dialogs with workspace assignment
- `title-regex-workspace.toml.sample` — regex title matching with workspace routing

Rename any sample to `.toml` and edit values to activate.
