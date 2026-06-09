---
"nehir": minor

---

BREAKING: Remove the Enable Animations setting and always keep Nehir-authored motion enabled. Niri-style scrolling, resizing, and transition motion are part of the interaction model rather than decorative effects; disabling them made the app difficult to use. Also skip redundant workspace-transition moves for windows already parked offscreen.
