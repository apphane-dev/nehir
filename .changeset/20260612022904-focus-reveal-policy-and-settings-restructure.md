---
"nehir": minor
---

Redesigned Niri viewport navigation around snap points instead of explicit centering and legacy reveal controls.

**Breaking changes**:

- Removed the old `scroll-reveal`, `center-focused-column`, and `always-center-single-column` settings.
- Removed explicit center commands from hotkeys, IPC, command handling, and the action catalog. Centering is now produced by the snap grid when a center snap point is the selected target.
- Removed per-monitor overrides for the removed viewport navigation settings.

Added **Reveal Partial** in Gestures & Focus → Navigation. It controls what happens when focus moves to a partially visible column:

- `Default`: choose the closest snap when the resulting viewport is a natural fit; otherwise center the target column.
- `Off`: do not reveal partially visible columns.
- `Snap Closest`: snap to the nearest target-column edge or center candidate.
- `Snap Center`: center the target column.

Improved default reveal behavior for proportional columns. Column groups such as `50% + 50%` and `25% + 35% + 40%` are treated as viewport-fitting without users having to compensate for gaps. Oversized combinations such as `65% + 50%` are not treated as a fit.

Added viewport movement commands for snapping left and right through the snap grid.

Renamed the resize modifier setting to **Mouse Modifier**. The same modifier is used for right-mouse resize and for temporarily bypassing trackpad snap during scroll gestures.

Fixed focus-follows-mouse so FFM focus changes do not reveal, relayout, or scroll the viewport, including duplicate AX focus confirmations for the same FFM target.

Fixed trackpad and keyboard/AX reveal paths to use the same snap-grid geometry, reducing divergence between gesture release, command navigation, and focus reveal.
