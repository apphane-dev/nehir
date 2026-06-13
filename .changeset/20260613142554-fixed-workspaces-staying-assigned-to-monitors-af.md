---
"nehir": patch

---

Fixed workspaces staying assigned to monitors after they are disconnected, which could cause stale workspace bar positioning or window reveal issues following an external display detach. Workspace-to-monitor assignments are now revalidated against the current monitor set whenever displays change.
