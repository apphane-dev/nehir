---
"nehir": none

---

Internal: emit a focus_reality trace record next to every focus_confirmed carrying the macOS-observed truth (observed_focused, observed_visible, on_screen, ws_visible, app_frontmost, app_focused_window). Runtime focus traces previously logged only Nehir's intended focus model, which could read as success while the window server never made the window key or its workspace visible; the new record makes that model/reality divergence visible in the trace. No behavior change.
