---
"nehir": patch

---

Internal refactor: introduce a central projection invalidation pipeline. State owners (WorkspaceManager) now emit structured invalidations (workspace, focus, settings projections) through callbacks routed to workspace bar, status bar, and IPC events via coalesced scheduling. Reduces risk of missed refreshes from scattered manual calls.
