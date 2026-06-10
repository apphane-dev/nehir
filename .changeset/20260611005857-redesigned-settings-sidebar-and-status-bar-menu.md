---
"nehir": minor

---

Redesigned Settings, status bar menu, and toggle commands.

**Settings sidebar** now has ten sections organized into four groups — General, Behavior, Layout, Monitors, Workspaces, Workspace Bar, Borders, App Rules, Hotkeys, and Diagnostics.

- **General**: Theme, Status Bar display, Prevent Display Sleep, Developer Mode, and nehirctl CLI install
- **Behavior**: Focus Follows Mouse, Follow Window to Monitor, Move Cursor to Focused, Scroll Gestures, and Mouse Resize — all in one place
- **Layout**: Inner Gaps, Outer Margins, and Column Layout settings with per-monitor scope
- **Hotkeys**: search field at the top filters bindings live; Reset to Defaults moved to the bottom
- **App Rules**: inline add/edit panel replaces the modal sheet; +/− footer buttons; Escape to dismiss
- **Diagnostics**: Accessibility permission status added alongside display environment checks

**Settings placement** was reorganized across sections so related options land together — focus behavior, scroll gestures, and mouse resize now share the Behavior tab; gap and column layout controls live in Layout. Captions and inline descriptions were added to clarify what each setting does. Controls use consistent styling (grouped form sections, uniform slider rows, caption text) instead of the previous mixed layouts.

**Status bar menu** is now minimal: three quick toggles (Focus Follows Mouse, Window Borders, Workspace Bar), Open Settings, Config Files, and Quit. CLI install and IPC enable have moved to Settings → General.

Six new toggle commands: `toggle-focus-follows-mouse`, `toggle-focus-follows-window-to-monitor`, `toggle-move-mouse-to-focused`, `toggle-borders`, `toggle-prevent-sleep`, `toggle-ipc`.

Debug commands (dump/reset/restart state, trace) are hidden from the command palette and hotkey settings unless Developer Mode is on. The Hotkeys section shows a "Dev" badge next to the debugging group when developer mode is active; experimental features show an "Experimental" badge inline.
