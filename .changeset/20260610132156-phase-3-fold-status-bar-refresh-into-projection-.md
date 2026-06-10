---
"nehir": none

---

Phase 3: fold status bar refresh into projection invalidation pipeline. Route .focusProjection and .settingsProjection to coalesced status bar refresh. Remove direct refreshStatusBar() from handleSessionStateChanged() and SettingsView.swift, replacing with projection-based scheduling. Add waitForStatusBarRefreshForTests() for async test support.
