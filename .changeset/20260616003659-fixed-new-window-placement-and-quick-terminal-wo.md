---
"nehir": patch
---

Fixed several cases where Nehir could jump to the wrong workspace or place new windows in the wrong location.

- New windows now open on the workspace/monitor you are actively using, even when macOS reports AX focus before the window-create event or when an older confirmed focus belongs to another workspace.
- Closing or hiding a quick-terminal/dropdown window no longer pulls you back to an older window or column on another workspace.
- Layout refreshes no longer auto-activate newly rediscovered windows on inactive workspaces.
- Workspace Bar clicks now target the exact workspace entry instead of resolving through the displayed label, so clicking later workspaces remains reliable.

Also improved runtime traces for diagnosing placement and focus recovery decisions.
