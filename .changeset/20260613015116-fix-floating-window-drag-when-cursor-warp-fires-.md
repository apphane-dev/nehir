---
"nehir": patch

---

Fix floating window drag when cursor warp fires during mouse click. Skip moveMouseToFocusedWindow and moveMouseToMonitor while any mouse button is held. Add detailed tracing for mouse down/drag/up, cursor warp decisions, and focus-follows-mouse skip reasons.
