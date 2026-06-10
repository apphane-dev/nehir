---
"nehir": minor

---

Redesigned Settings sidebar and status bar menu.

Settings sidebar now has ten sections — General, Behavior, Layout, Monitors, Workspaces, Workspace Bar, Borders, App Rules, Hotkeys, and Diagnostics — replacing the previous flat structure.

- **General**: Theme, Status Bar display, Prevent Display Sleep, Developer Mode, and nehirctl CLI install
- **Behavior**: Focus Follows Mouse, Follow Window to Monitor, Move Cursor to Focused, Scroll Gestures, and Mouse Resize — all in one place
- **Layout**: Inner Gaps, Outer Margins, and Column Layout settings with per-monitor scope
- **Hotkeys**: search field at the top filters bindings live; Reset to Defaults moved to the bottom
- **App Rules**: inline add/edit panel replaces the modal sheet; +/− footer buttons; Escape to dismiss
- **Diagnostics**: Accessibility permission status added alongside display environment checks

Status bar menu is now minimal: three quick toggles (Focus Follows Mouse, Window Borders, Workspace Bar), Open Settings, Open App Rules, Config Files, and Quit. CLI install and IPC enable have moved to Settings → General.

Six new toggle commands added: `toggle-focus-follows-mouse`, `toggle-focus-follows-window-to-monitor`, `toggle-move-mouse-to-focused`, `toggle-borders`, `toggle-prevent-sleep`, `toggle-ipc`.

Debug commands (dump/reset/restart state, trace) are now hidden from the command palette and hotkey settings unless Developer Mode is on.
