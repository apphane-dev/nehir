---
"nehir": none

---

Share pure Niri layout decisions between the onboarding move demo and runtime layout engine. This extracts a platform-free `PureLayout` reducer, drives the interactive demo through it, routes production Niri focus and focused-window move decisions through the same reducer, and adds bridge assertions so runtime tree mutations stay aligned with the pure model.
