# Move-Mouse-to-Focused Warps Cursor Across Monitors on Quick-Terminal Close — Discovery

Groom 2026-07-07: resolved — the center-warp is now suppressed while a windowCloseFocusRecovery context is active (AXEventHandler.swift warp gate checks activeWindowCloseFocusRecoveryWorkspaceId() == nil) (verified against main 7a025b78).

Reported issue: **closing the Ghostty "quick terminal" makes the cursor jump to
the 2nd monitor, where another Ghostty window lives.** The user correctly
identifies the `moveMouseToFocusedWindow` ("Move Mouse to Focused") feature as
the proximate cause. This is the multi-monitor sibling of the single-monitor
quick-terminal-close problem that was already fixed
(`completed/20260615-quick-terminal-close-switches-workspace.md`):
that fix's recovery guards are all built around *inactive-workspace* activations,
which is a single-monitor mental model, so a same-app re-focus that lands on the
**other monitor's already-active** workspace slips through and the center-warp
fires.

All evidence is inlined below; this document does not depend on any trace file
surviving. All file/line references should be re-verified before implementing —
line numbers drift.

---

## TL;DR

- **Setup (two monitors):** built-in Retina = `display 1` (main, frame
  `(0,0,2056,1329)`); external DELL = `display 3`
  `(-282,1329,2560,1440)`. `focusFollowsMouse=false`,
  `moveMouseToFocusedWindow=true`, `mouseWarpPolicyEnabled=true`.
- **One Ghostty process (`pid 895`, `com.mitchellh.ghostty`) owns two windows:**
  a persistent tiling window `895:307` on **workspace 7 (`DF42D837…`), display 3**,
  and a transient non-managed **quick-terminal** window (AX `window=185`) that
  drops down on display 1.
- **Sequence:** user dismisses the quick terminal. macOS's window-close focus
  recovery re-focuses another window of the *same app* (`pid 895`). The only
  other `pid 895` window is `895:307` on the 2nd monitor, so focus lands there.
  Nehir confirms managed focus on `895:307` and `moveMouseToFocusedWindow` warps
  the cursor from display 1 to display 3 — the visible jump.
- **Why the existing close-recovery guards miss it:** every guard keys on the
  target workspace being **inactive** (`shouldDeferInactiveNativeActivationBeforeCloseRecovery`
  requires `!isWorkspaceActive`; `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
  early-returns `guard !isWorkspaceActive else { return false }`).
  Workspace 7 is the *active* workspace on display 3, so for the cross-monitor
  re-focus `isWorkspaceActive == true` and **no guard suppresses or defers**.
  The single-monitor model assumes "the workspace we protect is on the same
  screen; a bad activation would hit an inactive workspace on that screen." With
  one active workspace per monitor, a same-app re-focus hits the *other* monitor's
  *active* workspace and is indistinguishable from a legitimate activation to the
  guards.
- **Why the warp itself is unguarded:** the center-warp gate at the AX
  focus-confirm path only checks the pointer-initiated suppression
  (`shouldSuppressMouseMoveToFocusedWindow(for:)`, set exclusively by
  Focus-Follows-Mouse / pointer activation). A system-initiated re-focus after a
  window close is **not** pointer-initiated, so the suppression is unset and the
  warp proceeds — including across monitors. Nothing ties the warp to the
  `windowCloseFocusRecovery` context.
- **Root cause (two layers):**
  1. *(P1, deeper)* Nehir has no guard for a **cross-monitor, active-workspace,
     same-app** re-focus driven by macOS on window close — the recovery guards are
     inactive-workspace-keyed and thus single-monitor-scoped.
  2. *(P2, the visible symptom)* `moveMouseToFocusedWindow` performs a
     **cross-monitor center-warp for a focus change that was system-initiated
     (close recovery), not user-initiated.** There is no link between the
     `windowCloseFocusRecovery` context and the warp gate, and `moveMouseToWindow`
     has no "don't warp across monitors for a non-user focus change" guard.
- **Recommended fix:** suppress the center-warp while a `windowCloseFocusRecovery`
  context is active (cheapest, directly matches the report), and additionally
  extend the recovery guards to recognize the cross-monitor same-app shape (same
  `pid`, different monitor, target on an *active* workspace) so the re-focus is
  deferred/suppressed before focus ever lands on the other monitor. See
  **Fix direction**.

---

## Topology & window mapping

Two monitors (each has its own active workspace):

```
ID(displayId: 1) isMain=true hasNotch=true  frame=(0.0, 0.0, 2056.0, 1329.0)
    visibleFrame=(0.0, 0.0, 2056.0, 1290.0) name=Built-in Retina Display
ID(displayId: 3) hasNotch=false            frame=(-282.0, 1329.0, 2560.0, 1440.0)
    visibleFrame=(-282.0, 1329.0, 2560.0, 1410.0) name=DELL P2423D
```

- **workspace 1** = `FF8BCBEC-23F9-415E-AC26-D7557408BA5A` — visible on
  **display 1**. Holds Slack `9464:227`, DBeaver `16851:351`, Helium
  `9523:314`, and VSCode `19484:398`.
- **workspace 7** = `DF42D837-5171-4590-A37A-2A08A561E33A` — visible on
  **display 3**. Holds **Ghostty `895:307`** (the "another instance of ghostty"
  the user refers to), tiling, frame `(178,1329 1640×1402)`.

Relevant settings: `focusFollowsMouse=false`,
`moveMouseToFocusedWindow=true`, `mouseWarpPolicyEnabled=true`.

`pid 895` (`com.mitchellh.ghostty`) is special here: it owns **both** the managed
tiling window `895:307` on display 3 **and** the non-managed quick-terminal
window (AX `window=185`) that drops down on display 1. The quick terminal is not
in the managed-window table; it shows up only as a transient, repeatedly
`create_seen`/`create_retry_scheduled` AX element and a non-managed focus
fallback.

## Inlined evidence (self-contained)

> Captured binary: nehir, build reported as `v57356b*`, capture window
> `2026-06-17T09:50:39Z` → `2026-06-17T09:50:48Z` (~8.7 s). All values below are
> copied from that capture; none depend on re-opening any log file.

### Start state

```
focused=WindowToken(pid: 9523, windowId: 314)            ← Helium, workspace 1, display 1
interaction current=ID(displayId: 1) previous=ID(displayId: 3) nonManaged=false
moveMouseToFocusedWindow=true  focusFollowsMouse=false  mouseWarpPolicyEnabled=true
```

### The quick terminal takes focus as a non-managed window

```
event=non_managed_focus_changed active=true fullscreen=false preserve=false
  interaction=ID(displayId: 1)/prev=ID(displayId: 3)
  plan=focus=focused=nil,pending=nil,non_managed=true
ax=AXFocusedWindowChanged pid=895 window=nil
```

`non_managed_fallback_entered pid=895 source=focusedWindowChanged` recurs
throughout — i.e. the `pid 895` focus changes are the quick-terminal (non-managed)
window, not the managed `895:307`.

### The close + cross-monitor re-focus + warp (the bug)

At capture-end second `09:50:45`, the focus lease clears and macOS re-focuses a
`pid 895` window. The only other `pid 895` window is `895:307` on display 3, so
managed focus is confirmed there:

```
event=focus_lease_changed owner=nil  plan=…,pending=nil  focus_lease=cleared
event=managed_focus_confirmed token=WindowToken(pid: 895, windowId: 307)
  workspace=DF42D837-5171-4590-A37A-2A08A561E33A monitor=Optional(ID(displayId: 3))
  interaction=ID(displayId: 3)/prev=ID(displayId: 1)
  plan=focus=focused=WindowToken(pid: 895, windowId: 307),pending=nil
event=focus_lease_changed owner=window_close_focus_recovery reason=window_close_focus_recovery
  interaction=ID(displayId: 3)/prev=ID(displayId: 1)
  plan=…,lease=window_close_focus_recovery
```

Note the ordering: **`managed_focus_confirmed` for `895:307` lands *before* the
`window_close_focus_recovery` lease is armed** — the close signal (auxiliary AX
destroy of `window=185`) arrives after focus has already moved:

```
ax=AXFocusedWindowChanged pid=895 window=nil
ax=AXUIElementDestroyed      pid=895 window=185      ← the quick terminal, non-managed
```

The center-warp then fires on the focus-confirm, jumping the cursor from
**display 1** to **display 3**:

```
moveMouseToFocused.request source=axFocusConfirmed token=WindowToken(pid: 895, windowId: 307)
  frame=(178.0,1329.0 1640.0x1402.0) frameSource=preferred
  current=(1028.0,641.0)  dest=(998.0,2030.0)  pressedButtons=0 centerOnScreen=true
moveMouseToFocused.perform source=axFocusConfirmed token=WindowToken(pid: 895, windowId: 307)
  dest=(998.0,2030.0) windowServerDest=(998.0,-701.0) pressedButtons=0
```

Decoded: `current=(1028.0,641.0)` is on display 1 (NSScreen Y range `0…1329`);
`dest=(998.0,2030.0)` is the center of `895:307` on display 3 (Y range
`1329…2769`). `centerOnScreen=true`, `pressedButtons=0` → both warp guards pass
and the cursor is warped across monitors. The interaction monitor then flips to
match the new focus:

```
interaction=ID(displayId: 1)→ID(displayId: 3) reason=updateInteractionMonitor
```

The aftermath (same second) shows the cursor now on display 3 and the mouse-warp
policy observing it at the display-3 edge:

```
mouseMove.replay staleQueued queued=(990.8,2049.9) current=(996.1,2036.2)   …(cursor on display 3)
warp.outside loc=(927.3,2769.0) axis=horizontal last=DELL P2423D#3
  frame=(-282,1329 2560x1440) order=["DELL P2423D","Built-in Retina Display"] attempted=false
```

### End state

```
focused=WindowToken(pid: 895, windowId: 307)            ← Ghostty, workspace 7, display 3
interaction current=ID(displayId: 3) previous=ID(displayId: 1)
focus-lease=window_close_focus_recovery
```

So the user, who was on display 1, ends with both focus and cursor on display 3
after dismissing the quick terminal.

---

## Why the existing close-recovery guards do not catch this

The single-monitor fix
(`completed/20260615-quick-terminal-close-switches-workspace.md`)
added a `windowCloseFocusRecovery` lease plus several suppression/deferral
checks. Every one of them is gated on the **target workspace being inactive**:

- `shouldDeferInactiveNativeActivationBeforeCloseRecovery`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1342`) requires
  `!isWorkspaceActive`.
- `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
  (`AXEventHandler.swift:1380`) early-returns
  `guard !isWorkspaceActive else { return false }` (`:1399`). Its same-`pid`
  anchor branch likewise needs the *focused* token to sit on an active workspace
  *and* `focusedToken.pid == observedEntry.pid`; at the moment of the re-focus the
  confirmed managed focus was Helium/VSCode (not `pid 895`), so the anchor does
  not fire.
- `shouldSuppressObservedActivationDuringWindowCloseRecovery`
  (`AXEventHandler.swift:1303`) keys on `recoveryWorkspaceId != observedEntry.workspaceId`
  — but only **after** the lease is armed, and here focus already landed before
  arming (see ordering above).

For the cross-monitor re-focus, the target workspace 7 is **active on display 3**,
so `isWorkspaceActive == true` and all of these return "don't suppress / don't
defer." The activation proceeds through the normal `handleManagedAppActivation`
path, focus is confirmed on `895:307`, and the warp runs.

In other words: the recovery machinery protects *one monitor's* active workspace
from being switched away to an *inactive* workspace. It has no concept of "the
bad re-focus is onto a **different monitor's active** workspace" — which is the
only shape a same-app re-focus can take when the app's only other window is on
another screen.

## Why the warp is unguarded

The center-warp gate at the AX focus-confirm path
(`AXEventHandler.swift:2104-2111`):

```swift
if shouldConfirmRequest,
   controller.moveMouseToFocusedWindowEnabled,
   controller.workspaceManager.confirmedManagedFocusToken == entry.token,
   !controller.workspaceManager.isNonManagedFocusActive,
   !controller.shouldSuppressMouseMoveToFocusedWindow(for: entry.token)
{
    controller.moveMouseToWindow(entry.token, preferredFrame: preferredMouseFrame, reason: "axFocusConfirmed")
}
```

`shouldSuppressMouseMoveToFocusedWindow(for:)` returns `true` only for a
**pointer-initiated** focus within the 1 s window
(`pointerFocusWarpSuppression`, set by Focus-Follows-Mouse / pointer activation —
see `noop/20260617-omniwm-147-ffm-warps-cursor-to-center.md`).
A macOS-driven re-focus after a window close is not pointer-initiated, so the
suppression is unset and the gate passes. Nothing in the gate consults the
`windowCloseFocusRecovery` context.

`WMController.moveMouseToWindow(_:preferredFrame:reason:)`
(`Sources/Nehir/Core/Controller/WMController.swift:3557`) then only checks
`centerOnScreen` (dest on *some* screen — yes, display 3) and `pressedButtons == 0`
(both pass). There is **no** "don't warp if the dest monitor differs from the
current cursor / interaction monitor unless the focus change was user-initiated"
guard, so the warp crosses monitors unconditionally.

---

## Root cause

Two layers, both required to produce the visible jump:

1. **(P1 — deeper)** The `windowCloseFocusRecovery` guards are inactive-workspace
   keyed and therefore single-monitor-scoped. A same-app, window-close-driven
   re-focus onto another monitor's *active* workspace is not recognized as a
   close-recovery shape, so it is neither deferred nor suppressed, and focus
   settles on the other monitor.
2. **(P2 — the visible symptom)** `moveMouseToFocusedWindow` warps the cursor for
   a focus change without distinguishing user-initiated (keyboard/command-nav)
   from system-initiated (macOS close recovery). There is no link between the
   `windowCloseFocusRecovery` context and the warp gate, and no cross-monitor
   guard, so the cursor jumps to whichever monitor macOS re-focused.

The single-monitor sibling bug (workspace *switch* on close) was fixed at P1.
This multi-monitor variant additionally needs either a P1 extension for the
cross-monitor active-workspace shape or a P2 guard that suppresses the warp
during recovery.

---

## Fix direction

### Primary (P2): suppress the center-warp while close recovery is active

Cheapest and directly matching the report. At the warp gate
(`AXEventHandler.swift:2104-2111`), add a clause that bails when a
`windowCloseFocusRecovery` context is active, mirroring the existing
`activeWindowCloseFocusRecoveryWorkspaceId()` check used by the suppression
guards:

```swift
if shouldConfirmRequest,
   controller.moveMouseToFocusedWindowEnabled,
   controller.workspaceManager.confirmedManagedFocusToken == entry.token,
   !controller.workspaceManager.isNonManagedFocusActive,
   !controller.shouldSuppressMouseMoveToFocusedWindow(for: entry.token),
   activeWindowCloseFocusRecoveryWorkspaceId() == nil   // ← new
{
    controller.moveMouseToWindow(entry.token, preferredFrame: preferredMouseFrame, reason: "axFocusConfirmed")
}
```

(The same clause should be considered at the second warp site,
`NiriLayoutHandler.swift:183-186`'s `niriAnimationSettled` path.)

**Caveat — the arming race:** in this capture the warp fired *before* the lease
armed (`managed_focus_confirmed` at #32 precedes `focus_lease_changed owner=window_close_focus_recovery`
at #33, because the auxiliary AX destroy of `window=185` lands after the
re-focus). A pure "suppress while recovery active" check would miss this instance.
To make P2 reliable it must be combined with one of:

- **Arm earlier.** Today the auxiliary-destroy arming
  (`handleWindowDestroyed` → `armWindowCloseFocusRecoveryForFocusedAppEvent`,
  `AXEventHandler.swift:2782`) fires only once the `window=185` destroy is
  observed. Arm the recovery context from the **first** `pid 895`
  `focusedWindowChanged`/`non_managed_fallback_entered` that follows the quick
  terminal losing focus, so the context exists before the successor focus is
  confirmed. (The single-monitor fix already considered focus-out-driven arming
  as option A; the multi-monitor case makes it necessary.)
- **Defer the successor confirmation.** Extend
  `shouldDeferInactiveNativeActivationBeforeCloseRecovery`'s deferral shape to
  also cover a same-`pid`, **cross-monitor**, active-workspace observed
  activation when no recovery is armed yet, then retry — giving the close signal
  time to arm recovery (same 120 ms retry pattern already used for the inactive
  case at `AXEventHandler.swift:1366-1378`).

### Secondary (P1): recognize the cross-monitor same-app shape

Generalize the recovery suppression beyond "inactive workspace." A same-app
(`observedEntry.pid == focusedToken.pid` *or* `== the just-closed app's pid`)
observed activation whose target is on a **different monitor** than the current
interaction monitor should be treated as a close-recovery candidate even when
the target workspace is active on its own monitor. Concretely, in
`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
(`AXEventHandler.swift:1380`), before the `guard !isWorkspaceActive else { return false }`
early-return, add: if the observed entry's monitor differs from the interaction
monitor and the activation is an `unrelatedNoRequest`/`focusedWindowChanged`
app-internal re-focus, suppress (or defer-and-retry) so focus does not leave the
user's monitor. This is the multi-monitor analogue of the inactive-workspace
suppression and is what actually keeps focus on display 1.

### Tertiary: an explicit cross-monitor warp guard (broader, riskier)

Add to `moveMouseToWindow` (`WMController.swift:3557`) a guard: do not warp when
the destination monitor differs from the current cursor/interaction monitor
**unless** the focus change is known to be user-initiated (a pending managed
request / command-nav origin). This would also catch future system-initiated
cross-monitor warps, but it risks regressing legitimate command navigation that
*intentionally* warps across monitors (see `docs/ARCHITECTURE.md` "Cursor warp
suppression" / empty-workspace monitor-switch exception). Prefer P1+P2; treat
this as a backstop if P1 proves unreliable.

---

## Suggested tests

Add to `Tests/NehirTests/AXEventHandlerTests.swift` (near the existing
`windowCloseFocusRecovery` coverage):

1. **Cross-monitor same-app re-focus after close is suppressed/deferred.** Two
   monitors, each with an active workspace. `pid A` has a managed window on
   display 3 and a non-managed quick-terminal on display 1; display 1's active
   workspace has a different app focused. Destroy the quick terminal. Assert the
   subsequent `pid A` `focusedWindowChanged`/`workspaceDidActivateApplication`
   for the display-3 window does **not** move confirmed focus off display 1 and
   does **not** flip the interaction monitor to display 3. (Would fail today.)
2. **No center-warp during recovery.** With `moveMouseToFocusedWindow=true` and a
   `windowCloseFocusRecovery` context active, an `axFocusConfirmed` for a window
   on another monitor must **not** call `moveMouseToWindow` (inject a warping
   spy, assert it is not called). Contrast: with no recovery context, the warp
   spy **is** called for the same confirmation.
3. **Arming race.** Assert that the recovery context is armed from the first
   post-close `focusedWindowChanged` for the owning `pid` (before the auxiliary
   destroy), so the suppression in (1)/(2) is in place before the successor
   confirmation.

---

## Open questions

- Is the quick terminal reliably non-managed across Ghostty versions? In this
  capture `window=185` is never in the managed table (`non_managed_fallback_entered`),
  so `shouldRecoverFocus` in `handleRemoved(token:)` never applies to it; only the
  auxiliary-destroy arming (`AXEventHandler.swift:2782`) does. If a future
  Ghostty admits the quick terminal as managed, the destroy path changes — the
  P1 cross-monitor guard should be origin- and monitor-based, not destroy-path-
  specific, to stay robust.
- Does the same jump reproduce with a *different* app owning windows on both
  monitors (not just Ghostty)? The mechanism is generic (any same-app re-focus on
  close), so it should; a second-app repro would confirm P1 generality.
