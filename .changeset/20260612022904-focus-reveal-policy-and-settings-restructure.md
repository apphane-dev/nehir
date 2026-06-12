---
"nehir": minor

---

**Breaking change**: Per-monitor overrides for `center-focused-column`, `always-center-single-column`, and `infinite-loop` have been removed from TOML monitor settings. These settings are now global-only and have moved to Gestures & Focus → Navigation in the UI.

Added `scroll-reveal` setting (values: `always` | `keyboard-and-commands` | `never`, default `always`) to control whether focusing a window scrolls the viewport to reveal it. Set to `keyboard-and-commands` to keep the viewport still when clicking a partially visible window.

Fixed: focus-follows-mouse no longer scrolls the viewport on AX focus confirmation.

Fixed: Move Cursor to Focused Window no longer warps the cursor after a trackpad gesture snap-back animation completes.
