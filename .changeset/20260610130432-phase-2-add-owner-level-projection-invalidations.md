---
"nehir": none

---

Phase 2: add owner-level projection invalidations to WorkspaceManager mutators (window add/rekey/remove/setWorkspace/setHiddenState/setLayoutReason, focus/scratchpad/interaction changes, active workspace/topology/monitor assignment) and remove redundant manual requestWorkspaceProjectionRefresh() calls from WMController, LayoutRefreshController, and AXEventHandler that are now covered by owner invalidations
