---
"nehir": patch
contributors: [dagrlx]
---

Reset the Niri viewport when closing back to a single fill-width window.

- Closing the right column of a proportional pair could leave the surviving lone window with the old two-column viewport target (for example `targetViewStart=-516` after a `50% + 50%` pair collapsed to one full-width Ghostty window). A later focus/click relayout then applied that stale viewport and shifted the window hundreds of pixels off its fill position.
- Lone-window viewport preparation now runs on window-removal relayouts even when the removal created an in-flight scroll/column animation, so the surviving fill-width window settles back to the fill viewport immediately.

Fixes #56.
