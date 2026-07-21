---
"nehir": patch
---

Fix two wake glitches on scaled-resolution displays: a phantom right-edge Dock shield that appeared after opening the lid from sleep (a Dock inset learned from a stale display-mode reading), and a runaway internal relayout loop that could execute millions of times during the wake settle.
