---
"nehir": patch
contributors: [Alan-TheGentleman]
---

Keep the workspace bar and managed windows below an auto-hidden menu bar by anchoring to an explicit menu-bar inset instead of the auto-hide-sensitive visible frame (#68). On multi-monitor setups the explicit inset now applies on secondary displays too, keeping them clear of the reveal region even when no menu bar is drawn there.
