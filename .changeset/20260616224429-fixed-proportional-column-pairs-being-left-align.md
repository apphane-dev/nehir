---
"nehir": patch

---

Fixed proportional column pairs being left-aligned with the slack gap on one side.

- Multi-column Niri layouts like a `50% + 50%` pair were sized correctly but misplaced: the column group was anchored to the left edge, leaving the entire proportional slack gap on the right side instead of splitting it evenly. A `50/50` pair now centers its slack — on a 2056px display it sits at `16 / 1036` instead of `0 / 1020`.
- Applies consistently across the second-window insertion, startup/restore, and native-fullscreen restore paths so the viewport settles to the same position regardless of how it was reached.
- Column widths, heights, column order, and window identity are preserved; only the horizontal origin of the filling group shifts by at most the viewport-fill tolerance.
