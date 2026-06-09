<h1 align="center">
  <img src="Resources/Logo.png" alt="Nehir" width="600" />
</h1>

<img src="Resources/AppIcon.png" align="right" width="128" />

A scrolling tiling window manager for macOS, built on the Niri column layout paradigm.

> **Nehir** (Turkish for "river") — windows flow in columns, scrolling horizontally across your screen.

## Features

- **Niri scrolling column layout** — windows arranged in columns that scroll horizontally, with automatic overflow tabbing when stacked windows cannot fit at their minimum heights
- **Workspace management** — multiple workspaces with hotkey switching
- **Window borders** — configurable colored borders on the focused window
- **Workspace bar** — per-monitor status bar showing workspace names and app icons
- **Focus follows mouse** — optional hover focus
- **Multi-monitor support** — seamless window management across displays. For the best Niri scrolling experience, use an auto-hide Dock and arrange displays vertically in macOS System Settings to avoid parked offscreen windows bleeding onto neighboring monitors.
- **Overview mode** — bird's-eye view of all windows
- **Command palette** — fuzzy search for commands
- **App rules** — per-application layout overrides
- **IPC** — Unix socket for external control via `nehirctl`
- **TOML configuration** — split config under `~/.config/nehir/`

## Install

### Homebrew

After the first release is published, Nehir can be distributed from the `guria/tap` Homebrew tap:

```bash
brew tap guria/tap
brew install --cask nehir
```

Nehir requires Accessibility permissions after installation:

```text
System Settings > Privacy & Security > Accessibility
```

### From source

```bash
# Package the app bundle
mise run package:release

# User-local install (no sudo)
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$HOME/Applications/Nehir.app"
cp -R dist/Nehir.app "$HOME/Applications/Nehir.app"
install -m 755 .build/apple/Products/Release/nehirctl "$HOME/.local/bin/nehirctl"
```

Or use mise:

```bash
# User-local install
mise run install

# System-wide install
mise run install:system
```

## Usage

```bash
# Run
Nehir

# CLI control (requires IPC enabled)
nehirctl command focus left
nehirctl command switch-workspace 2
nehirctl --help
```

## Debugging & Tracing

Nehir includes runtime debugging and trace-capture commands. They are exposed consistently through IPC/CLI, the command palette, and hotkey handling, and appear in the **Debugging & Tracing** category:

- **Debug: Dump Runtime State** — copies the current runtime debug dump to the clipboard and writes it to the unified log
- **Debug: Reset Runtime State** — clears runtime debugging state and reboots tracking from a startup-style rescan
- **Debug: Restart Clearing Runtime State** — clears runtime debugging state and relaunches the app
- **Debug: Toggle Trace Capture** — default hotkey: `Ctrl+Option+Cmd+T`
  - IPC/CLI accepts an optional `desiredState` argument (`active` or `inactive`) for idempotent scripting: `nehirctl command debug trace toggle active`

Stopping a trace capture writes a log bundle to:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/nehir/traces/
```

and copies the dumped file path to the clipboard.

For feedback/debug reports: toggle tracing on, reproduce the issue, toggle tracing off, then share the copied trace-bundle path or file. An optional **Show Trace Capture Button** workspace-bar setting provides the same toggle in the bar for advanced users and developers.

For IPC/CLI usage, see [docs/IPC-CLI.md](docs/IPC-CLI.md).

## Configuration

Nehir uses a split-file config layout under `~/.config/nehir/`:

```
~/.config/nehir/
├── settings.toml      # core app behavior
├── hotkeys.toml       # physical keybindings
├── workspaces.toml    # workspace definitions
├── apprules.d/        # one file per app rule
│   ├── com-google-chrome.toml
│   └── pip-floating.toml.sample   # inactive sample
└── monitors.d/        # per-monitor overrides
    └── studio-display.toml
```

All files are watched for changes — edits are applied live without restarting.

See [Configuration Principles](docs/CONFIGURATION.md) for the design rationale.

### Default Shortcut Model

Nehir defaults are stored and shown as physical key chords.

- **Option+Command** — navigate, focus, and open UI
- **Option+Shift+Command** — move the focused window
- **Control+Option+Command** — larger-scope navigation such as workspace history and column indexes
- **Hyper** — physical Control+Option+Shift+Command, reserved for structural moves

For a lighter way to enter the base layer, see the [Karabiner double-Command recipe](docs/recipes/karabiner-double-command-sticky-command-option.json).

The goal is a small set of predictable modifier patterns:

```text
without Shift = go there
with Shift    = move current window there
Hyper         = reshape or move structure
```

## Development

```bash
# Build (debug)
mise run build

# Build and run
mise run dev

# Release build
mise run build:release

# Run tests (requires Xcode)
mise run test

# Clean
mise run clean
```

## Origin

Nehir is a highly opinionated fork of [Hiro](https://github.com/BarutSRB/Hiro) (formerly OmniWM), rebuilt around a single layout engine — Niri scrolling columns — with stripped-down controls and no backward-compatibility baggage.

The original project tried to accommodate a wide range of user requests; Nehir deliberately narrows the scope to do one thing well. We're deeply grateful to the original author for the foundation this builds on.

### Notable changes from Hiro/OmniWM

- **Single layout model.** Nehir is rebuilt around Niri-style scrolling columns instead of keeping multiple layout/control models.
- **No legacy compatibility layer.** Configuration, defaults, hotkeys, and behavior are allowed to change to fit Nehir's narrower workflow.
- **Required motion stays enabled.** Unlike Hiro/OmniWM's user-toggleable animation preference, Nehir treats layout motion as part of the interaction model: disabling it makes Niri-style scrolling, resizing, and transition state hard to follow, so there is no `animationsEnabled` setting.
- **Split TOML configuration.** Runtime config is organized under `~/.config/nehir/` with separate files for settings, hotkeys, workspaces, app rules, and monitor overrides.
- **Close/collapse focus stays local.** When macOS reports another same-app window as focused after closing or collapsing the current one, Nehir treats that as native fallback focus rather than user navigation. Same-app fallback to inactive workspaces is ignored, and unmanaged quick-terminal fallback is also ignored on the current workspace so the viewport does not scroll to that app's managed column. Explicit Nehir focus commands still take precedence.
- **Configurable gesture scroll snap.** Trackpad swipe gestures can snap to column boundaries or stop freely mid-scroll. Controlled by `gestures.scrollSnap` in `settings.toml` (default `true`).
- **Built-in runtime debugging tools.** Nehir now ships command-palette and IPC/CLI actions to dump runtime state, reset/rebootstrap runtime state, restart while clearing runtime state, and capture runtime trace bundles under `${XDG_STATE_HOME:-$HOME/.local/state}/nehir/traces/`.

## License

GPL-2.0-only
