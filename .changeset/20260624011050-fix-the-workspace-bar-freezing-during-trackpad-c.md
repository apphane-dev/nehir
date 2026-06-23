---
"nehir": patch

---

Fix the workspace bar's selected-column indicator freezing during trackpad column-switch gestures when an app that Nehir doesn't manage (a transient overlay, the app switcher, or any unmanaged foreground window) is on top. The bar now follows the swipe, showing which column you landed on, while the stronger focus highlight still tracks the window that's actually focused. The bar also updates whenever you switch columns by any means, so it no longer gets stuck if a particular action forgets to refresh it.
