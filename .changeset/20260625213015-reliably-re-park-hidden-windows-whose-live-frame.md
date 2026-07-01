---
"nehir": patch

---

Improve hidden-window recovery so windows that unexpectedly reappear while Nehir still considers them hidden are re-parked more reliably, including offscreen scrolling columns that have been hidden for a while. This does not remove macOS's offscreen parking limitations, so a thin parked-window strip may still be visible in some configurations.
