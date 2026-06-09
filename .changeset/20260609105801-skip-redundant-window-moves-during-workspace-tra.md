---
"nehir": patch

---

Skip redundant window moves during workspace transitions. Windows already parked offscreen by the layout engine are no longer shuffled to the other side when their workspace becomes inactive. Removed ineffective animationsEnabled check from window movement animation path.
