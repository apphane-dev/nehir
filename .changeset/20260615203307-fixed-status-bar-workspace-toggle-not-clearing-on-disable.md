---
"nehir": patch
---

Fixed the Status Bar "Show Workspace" toggle not clearing the workspace text when disabled — the title persisted until the app was restarted. Settings-projection refreshes now reach the status bar even when the feature is being turned off, so it clears its title immediately.
