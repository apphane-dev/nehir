---
"nehir": patch
---

Tile a window you deliberately switch to (Dock, Cmd-Tab, or launcher) even while non-managed focus is active. Previously, activating an app whose window had never been tracked — such as one revealed after being hidden across a restart — left it floating unmanaged and stuck, because its own focus kept re-arming the guard that dropped it.
