---
"nehir": minor
---

Added an `openSettings` command for opening the Nehir settings window.

The new command is surfaced everywhere other commands live:

- **Command Palette** — searchable under the Commands tab (try "settings" or "preferences")
- **Hotkeys** — assignable in Settings → Hotkeys (unassigned by default; persisted as `ui.settings` in the config)
- **CLI / IPC** — `nehirctl command open-settings` (IPC name `open-settings`)

It behaves like the other "open surface" commands (`open-command-palette`, `open-menu-anywhere`): it activates the Settings window via the shared `SettingsWindowController`, and is reachable through the same hotkey, command palette, and IPC paths. The status bar menu's existing Settings item is unchanged.
