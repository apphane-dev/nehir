---
"nehir": patch
---

Moved Developer Mode from Settings → General into Settings → Diagnostics and expanded Diagnostics into a developer troubleshooting surface while Developer Mode is on.

- Runtime State section lists each debug command (Dump Runtime State, Trace Capture, Reset Runtime State, Restart Clearing State) with its currently assigned shortcut and a button to run it directly, replacing a separate read-only hotkey list.
- Restart Clearing State reuses the same confirmation dialog with an Enable Tracing checkbox as the status bar menu.
- Recent Traces section lists the last ten exported trace captures with Copy Path (plain path string) and Copy File (Finder-style file pasteboard object) actions, plus Reveal Traces Folder.
- Added a Show Trace Capture Button toggle (duplicated from Workspace Bar settings) for one-place configuration.
- Assign in Hotkeys deep-links into the Hotkeys tab and filters it to the debug commands.
