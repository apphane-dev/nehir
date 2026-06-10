---
"nehir": none

---

Phase 4: centralize settings side effects. Replace direct refreshStatusBar() in applyPersistedSettings with requestSettingsProjectionRefresh() so external config reload uses the same projection pipeline as UI-initiated settings changes. Both paths now produce the same subsystem updates for status bar content.
