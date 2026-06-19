---
"nehir": patch

---

Use raw multitouch input for trackpad workspace gestures

Switch trackpad workspace gestures to the raw MultitouchSupport
contact-frame path so swipes are no longer eaten by the focused app,
and preserve the unsnapped viewport offset after a snap-bypassed
(modifier-held) gesture so subsequent gestures and layout refreshes
start from where the user left the viewport instead of snapping it
back to a visibility-corrected column edge.
