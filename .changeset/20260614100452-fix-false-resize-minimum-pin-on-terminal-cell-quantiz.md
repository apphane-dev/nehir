---
"nehir": patch
---

Fixed false resize-minimum pin on terminal windows that snap to cell rows.

- Terminal/grid apps such as Ghostty round window geometry to whole cell rows. When a requested fill height fell between grid lines, the app snapped the window *up* by a few pixels and Nehir misread that small overshoot as a hard app-enforced minimum.
- Nehir then permanently recorded an inferred resize minimum on just that window, over-constrained the Niri solver against its siblings, and pinned the window to the snapped (taller) height. This is why one Ghostty window on a multi-column workspace could end up taller than the others.
- Small `verificationMismatch` overshoots (within ~one cell) are now treated as bidirectional cell quantization rather than a one-sided minimum: the observed snapped frame is accepted and confirmed, but no inferred minimum is recorded and the solver is no longer force-pinned. Genuine app minimums are unaffected because they are reported via `AXMinSize` and respected independently.
