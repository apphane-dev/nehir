# OmniWM issue #147 — "Mouse-to-focused + FFM → jumping cursor" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/147>
Scope of this doc: determine whether the bug applies to nehir (with both
"Mouse to Focused" center-warp **and** "Focus Follows Mouse" enabled, moving the
mouse between windows should not snap the cursor to the center of the newly
focused window), and whether any fix is needed.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

> **Filed under `discovery/noop/`** — nehir already prevents exactly this cursor
> snap via a **token-keyed warp suppression** set on the Focus-Follows-Mouse
> activation path and gated on every center-warp call site. The bug does not
> reproduce in nehir; there is no upstream fix diff to port (the issue was
> closed `not_planned` with no merged fix). No new repo action is owned here.

---

## TL;DR

- **When FFM mouse-activates a window, nehir records that token as
  "pointer-initiated" for a 1 s window, and every "move mouse to focused
> window" center-warp call site checks that flag and bails.** So a focus change
  caused by moving the cursor does **not** recenter the cursor; only
  keyboard/hotkey or new-window focus (which never sets the suppression) warps.
- **Verdict:** 🟢 **Fixed.** This is precisely the behavior #147 asks for
  ("focus changes when moving the cursor manually, but the cursor does not jump
  to the center").

## Issue context

- **State:** closed `not_planned`; no merged fix, no diff to port.
- **Reproduce:** enable both "Mouse to Focused" (center the cursor in the newly
  focused window) and "Focus Follows Mouse" (focus the window under the cursor);
  move the mouse between two windows.
- **Symptom (verbatim):** "After entering the new window, the cursor immediately
  jumps to the center of that window. This creates an unexpected mouse movement
  because the cursor jumps instead of following a smooth path."
- **Expected:** "The focus changes when moving the cursor manually, but the
  cursor does not jump to the center of the newly focused window. The cursor
  should jump to the center only when a new window is selected via hotkey or when
  a new window pops up." (OmniWM v0.4.2.1, macOS Tahoe.)

## Provenance: is this nehir's code?

Yes. Both features exist in nehir and are independently toggleable:

- `focusFollowsMouse` — `Sources/Nehir/Core/Controller/WMController.swift:91`
  (`focusFollowsMouseEnabled`), defaulted off
  (`Sources/Nehir/Core/Config/SettingsExport.swift:99`).
- `moveMouseToFocusedWindow` ("Mouse to Focused") —
  `Sources/Nehir/Core/Controller/WMController.swift:92`
  (`moveMouseToFocusedWindowEnabled`), defaulted off
  (`Sources/Nehir/Core/Config/SettingsExport.swift:100`), set via
  `setMoveMouseToFocusedWindow(_:)` (`WMController.swift:696`).
- The center-warp itself is `WMController.moveMouseToWindow(_:preferredFrame:reason:)`
  (`WMController.swift:3555`), which calls `warpMouseCursorPosition(...)` to the
  frame center (`WMController.swift:3588`).

## The code in question

**The suppression record + gate (the core of the fix):**

```swift
// Sources/Nehir/Core/Controller/WMController.swift:93-96
private var pointerFocusWarpSuppression: (token: WindowToken, timestamp: Date)?
// Backstop for paths that don't go through focus confirmation (FFM, gesture snap).
// 1s covers typical AX async confirmation latency with margin.
private let pointerFocusWarpSuppressionInterval: TimeInterval = 1.0

// Sources/Nehir/Core/Controller/WMController.swift:700-710
func suppressMouseMoveToFocusedWindow(for token: WindowToken) {
    pointerFocusWarpSuppression = (token, Date())
}

func shouldSuppressMouseMoveToFocusedWindow(for token: WindowToken) -> Bool {
    guard let suppression = pointerFocusWarpSuppression else { return false }
    guard Date().timeIntervalSince(suppression.timestamp) <= pointerFocusWarpSuppressionInterval else {
        return false
    }
    return suppression.token == token
}
```

**FFM activation records the suppression as its first action — this is what
marks a focus change as pointer-initiated:**

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift:1374-1382
private func activateFocusFollowsMouseTarget(_ target: FocusFollowsMouseTarget) {
    guard let controller else { return }

    switch target {
    case let .niri(workspaceId, window):
        controller.suppressMouseMoveToFocusedWindow(for: window.token)   // ← mark pointer-initiated
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { vstate in
            vstate.pendingFFMFocusToken = window.token
            vstate.pendingFFMFocusTimestamp = Date()
            controller.niriLayoutHandler.activateNode(...)
```

(The same record is also set for floating targets at
`MouseEventHandler.swift:1345` and for the generic pointer target at
`MouseEventHandler.swift:1371`.)

**Center-warp call site #1 — the AX focus-confirm path (this is the path that
would snap after FFM hands focus over):**

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:2101-2109
if shouldConfirmRequest,
   controller.moveMouseToFocusedWindowEnabled,
   controller.workspaceManager.confirmedManagedFocusToken == entry.token,
   !controller.workspaceManager.isNonManagedFocusActive,
   !controller.shouldSuppressMouseMoveToFocusedWindow(for: entry.token)   // ← gate
{
    controller.moveMouseToWindow(entry.token, preferredFrame: preferredMouseFrame, reason: "axFocusConfirmed")
}
```

**Center-warp call site #2 — the Niri animation-settled path:**

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:183-186
if controller.moveMouseToFocusedWindowEnabled,
   controller.workspaceManager.activeFocusRequestToken == nil,
   let token = controller.workspaceManager.confirmedManagedFocusToken,
   !controller.shouldSuppressMouseMoveToFocusedWindow(for: token)   // ← gate
{
    controller.moveMouseToWindow(token, preferredFrame: controller.preferredKeyboardFocusFrame(for: token), reason: "niriAnimationSettled")
}
```

## Why the bug does not apply (nehir already prevents it)

1. **Mouse-initiated focus is tagged.** `handleFocusFollowsMouse(at:)`
   (`MouseEventHandler.swift:1189`) resolves the window under the pointer and,
   on activation, calls `activateFocusFollowsMouseTarget(_:)`, which calls
   `controller.suppressMouseMoveToFocusedWindow(for: window.token)` as its very
   first statement (`MouseEventHandler.swift:1381`). That records
   `(token, now)` into `pointerFocusWarpSuppression`.

2. **Both center-warp sites check the tag and skip.** The AX focus-confirm site
   (`AXEventHandler.swift:2108`) and the Niri animation-settled site
   (`NiriLayoutHandler.swift:186`) both require
   `!shouldSuppressMouseMoveToFocusedWindow(for: token)`. For an FFM-initiated
   focus the gate returns `true` (matching token within the 1 s window), so
   `moveMouseToWindow(...)` is **not** called → the cursor is not warped to the
   center. This is the exact expected behavior from #147.

3. **Keyboard/hotkey and new-window focus are unaffected.** Those paths set
   focus through `focusWindow`/`setKeyboardFocusTarget` and never call
   `suppressMouseMoveToFocusedWindow(for:)`, so the gate returns `false` and the
   center-warp proceeds — again matching #147's expectation ("jump to the center
   only when … selected via hotkey or when a new window pops up").

4. **The 1 s backstop is sized for the async gap.** The comment at
   `WMController.swift:94-95` ("Backstop for paths that don't go through focus
   confirmation (FFM, gesture snap). 1s covers typical AX async confirmation
   latency with margin.") documents that the window is deliberately tuned to
   cover the delay between FFM requesting focus and AX confirming it — the exact
   interval in which the unwanted snap would otherwise occur.

## Recommendation

**Do nothing.** nehir already implements the precise behavior #147 requests, at
the idiomatic layer (suppress at the pointer-focus source, gate at every warp
site). There is no upstream diff to port (issue closed `not_planned`, no fix).
If a future report shows a residual snap on pointer-initiated focus, the
investigation target is the 1 s `pointerFocusWarpSuppressionInterval` vs. the
observed AX confirmation latency on that hardware — not a missing guard.

## Suggested tests

 Nehir's guard is behavioral and worth a regression that does not currently
appear to be asserted by name:

- With both `focusFollowsMouse` and `moveMouseToFocusedWindow` enabled, simulate
  a pointer-driven FFM activation of window B while A is focused; assert that
  `shouldSuppressMouseMoveToFocusedWindow(for: B.token)` is `true` immediately
  after, and that the subsequent focus-confirm does **not** invoke
  `moveMouseToWindow` for B (inject a warping spy and assert it is not called).
- Contrast case: a keyboard `focusNext` to B; assert the warp spy **is** called
  for B (no suppression recorded). This locks in the source distinction #147
  depends on.
