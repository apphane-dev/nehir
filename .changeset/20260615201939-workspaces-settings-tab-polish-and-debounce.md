---
"nehir": patch
---

Polished the Workspaces settings tab. Editing the display name now coalesces config syncs instead of re-applying workspace settings and refreshing the layout on every keystroke. Workspaces with an empty-string display name now show "Workspace \<id\>" in the sidebar instead of a blank label, and the context-menu Delete item is disabled (rather than prompting a confirmation that then silently does nothing) for workspaces that can't be deleted.
