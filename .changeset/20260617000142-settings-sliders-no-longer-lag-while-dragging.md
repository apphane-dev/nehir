---
"nehir": patch

---

Settings sliders no longer lag while dragging.

- Dragging the Scroll Sensitivity slider (and other settings sliders such as Border Width, Workspace Bar Height/Opacity, and global gaps) used to trigger a synchronous settings save plus controller side-effects on every drag tick. The save's debounce was a single task yield, so it effectively fired once per frame, blocking the main actor with a TOML encode and disk write on each pixel of motion.
- `SettingsSliderRow` now buffers the value in a local draft while dragging and commits it exactly once when the drag ends, so the `didSet` save and any `.onChange` controller work run a single time at release. The numeric value next to the slider still updates live while dragging.

