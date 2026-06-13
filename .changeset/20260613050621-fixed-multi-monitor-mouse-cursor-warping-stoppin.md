---
"nehir": patch
contributors: [flschulz, dagrlx]
---

Fixed multi-monitor mouse cursor warping stopping whenever Nehir was not the active app (for example with the Settings window closed). Warp now shares the main mouse event tap, which keeps receiving events while the app is in the background.
