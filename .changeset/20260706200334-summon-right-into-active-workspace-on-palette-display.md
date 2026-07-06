---
"nehir": minor
---

Summon Right (Shift-Enter in the Windows palette) now works when the active workspace has no managed anchor window, targets the display the palette opened on, and reliably admits cross-monitor summons.

- Previously Shift-Enter was disabled whenever the active workspace had no managed
  anchor window (empty workspace, or focus on an unmanaged/foreign window). Summon
  Right now stays available in that case and summons the selected window into the
  palette's active workspace as the new rightmost column.
- Summon targeting now follows the palette's display (where the mouse was when the
  palette opened), not the keyboard-interaction monitor. This is a semantics shift
  for multi-monitor keyboard-driven use, and matches where the palette is already
  drawn.
- A cross-workspace Summon Right no longer leaves the window resting on its
  original monitor until you manually manipulate it: it is framed and admitted to
  the destination workspace in one motion.
