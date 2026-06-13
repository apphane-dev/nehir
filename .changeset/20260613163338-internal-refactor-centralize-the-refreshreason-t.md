---
"nehir": none

---

Internal refactor: centralize the RefreshReason to refresh-route mapping. A single RefreshReason routing table now drives route (fullRescan / relayout / immediateRelayout / visibilityRefresh / windowRemoval) and scheduling policy, exposed via a new reason-driven LayoutRefreshController.requestRefresh entry point. Adding a reason or changing refresh policy is now a one-place edit instead of scattered call sites; behavior is unchanged.
