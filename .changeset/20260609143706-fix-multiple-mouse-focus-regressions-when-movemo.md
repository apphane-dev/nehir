---
"nehir": patch
contributors: [charmbyte]
---

Fix multiple mouse focus regressions when `moveMouseToFocusedWindow` is enabled:

- Suppress cursor warp on pointer-initiated focus, workspace bar clicks, tab clicks, and trackpad gestures.
- Prevent `focusFollowsMouse` from activating tiled columns while a floating window is active above the Niri layout, or behind unmanaged windows during hover, click, or drag interactions.
- Restore `focusFollowsMouse` after scroll animation and owned window close.
- When `focusFollowsMouse` is enabled, keep swipe gesture end from committing focus to the snapped column; final focus follows the pointer instead.
- Warp the cursor to the target monitor center when switching to an empty workspace.

Fixes #21.
