# Swiping away from a native-fullscreen video lands on the wrong workspace — Discovery

> Scope: root-cause a reported runtime bug. Source-backed; **does not propose a
> fix.** Line references verified against main-repo HEAD `8a2e6db4`.
> **Re-verify before implementing; line numbers drift** — at capture time the
> working tree had uncommitted edits in `AXEventHandler.swift`, so cite by symbol
> name, not just line.

## Symptom (as reported)

Two monitors, both hosting stacked Nehir workspaces on the same display. A video
plays in macOS **native fullscreen** (green-button, own Space) on one workspace.
The user exits fullscreen and, in the same motion, does a 3-finger trackpad
swipe to scroll. Instead of scrolling the workspace the video was on, the swipe
scrolls a **different** workspace — the user "lands on the wrong workspace."

---

## TL;DR

- The video window and the window the user lands on **belong to the same app**
  (one browser process, two windows on two different workspaces of the same
  display).
- When the native-fullscreen Space tears down, macOS hands keyboard focus to the
  app's **other** window, which lives on the **inactive** workspace. This arrives
  as an external `AXFocusedWindowChanged` for that app.
- Nehir already had a **pending managed focus request** to keep focus on the
  video window (on the correct workspace). The external focus change *conflicts*
  with that pending request.
- `shouldHonorObservedFocusOverPendingRequest` treats any external
  `focusedWindowChanged` as authoritative and **discards Nehir's pending
  request**, then activates the observed window — switching the active workspace
  to the wrong one. The subsequent swipe scrolls that now-active wrong workspace.
- The existing pre-close deferral guard that was built for exactly this "activate
  an inactive-workspace window during teardown" shape only covers
  `workspaceDidActivateApplication`, **not** `focusedWindowChanged`, so it does
  not catch this path.

---

## Topology at capture

Single display (`display 1`) hosts two stacked Nehir workspaces; the interaction
monitor stayed `display 1` for the whole sequence (`previous` interaction monitor
= `display 2`, never promoted). Relevant windows all belong to one browser
process, **pid 16913**:

- Workspace **`2390AEFE-…9529B7`** ("ws2") — the video. Managed tiling window
  `windowId 47748` was in native fullscreen (its live frame spans the whole
  screen: `live=0,0,2056,1290`). Also a floating child `50859` and transient
  fullscreen chrome windows (`50860`, `50895`).
- Workspace **`0301EC1A-…06D9F… A4C17`** ("ws1") — a two-column layout. Column 0 =
  `windowId 24203` (pid 51532); column 1 = `windowId 47139` (pid 16913, **same
  app as the video**), which is `activeColumnIndex=1`, `selectedNode`
  `E9FDB9B2-…291293C`.

Before the exit, ws2 was the active workspace on display 1 (all teardown events
below carry ws2's id and ws2's selected node; Nehir's pending focus request
targets ws2 — see step 4).

---

## Trace evidence (inlined; self-contained)

Times are `2026-07-13T18:16:__Z`. Workspace ids abbreviated.

**1. Native-fullscreen Space destroyed (user exits fullscreen).** `18:16:19` —
the video's dedicated CGS Space is destroyed:

```
workspace=ws2 reason=close_recovery_destroy_liveness_decision
  windowId=47748 token=(pid 16913, windowId 47748)
  origin=cgs_space_destroyed outcome=handled reason=native_fullscreen_destroy
  layout={w47748:selected{cur=212,7,1632,1251 ... live=0,0,2056,1290 ...}}
```

**2. Fullscreen chrome tears down; close-recovery expires.** `18:16:19`–`18:16:20`
— a cascade of liveness decisions for child windows `50860`/`50895`, ending with:

```
workspace=ws2 reason=close_recovery_expired expiredAgoMs=3789
  currentTarget=(pid 16913, windowId 47748) currentTargetManaged=true confirmedFocus=nil
workspace=ws2 reason=scroll_animation_stop  (ws2 settled, activeColumnIndex=0, viewStart=-204.0)
```

At this point close-recovery for ws2 has **expired** — there is no active
`windowCloseFocusRecovery` context to suppress a stray activation.

**3. ~3 s gap**, then macOS re-homes focus to the app's other window. `18:16:23`
— an **external `focusedWindowChanged`** arrives for pid 16913, but the AX
"focused window" is now `47139`, which lives on **ws1** (the inactive
workspace):

```
workspace=ws1 reason=close_recovery_activation_gate
  token=(pid 16913, windowId 47139)
  isWorkspaceActive=false
  source=focusedWindowChanged  origin=external
  requestDisposition=conflictsWithPendingRequest(
      ManagedFocusRequest(requestId: 110,
                          token: (pid 16913, windowId 47748),
                          workspaceId: ws2,
                          status: pending))
  currentTarget=(pid 16913, windowId 47748) currentTargetManaged=true currentTargetSamePid=true
  decision=evaluate
  columns=2 activeColumnIndex=1 currentViewStart=502.5 targetViewStart=502.5
```

Read this carefully: **Nehir wanted to keep focus on the video window `47748` on
ws2** (pending request `#110`), but macOS's external focus change points at
`47139` on ws1, and the gate's verdict is `decision=evaluate` (not suppress /
not defer).

**4. Nehir honors the external change and activates ws1.** `18:16:23` — focus is
confirmed on `47139` and ws1 becomes the active/interaction workspace:

```
workspace=ws1 reason=ax_focus_confirm_before_activate  token=(pid 16913, windowId 47139)
  confirmedFocus=(pid 16913, windowId 47139)
workspace=ws1 reason=ax_focus_confirm_after_activate   token=(pid 16913, windowId 47139)
```

**5. The swipe arms on ws1 (the wrong workspace).** `18:16:23` — same second:

```
workspace=ws1 reason=touch_scroll_gesture_armed
  input=trackpadTouches requiredFingers=3 activeTouches=3 inputPhaseName=began
  columns=2 activeColumnIndex=1 selectedNode=E9FDB9B2-…291293C
  preferredFocus=(pid 16913, windowId 47139) confirmedFocus=(pid 16913, windowId 47139)
```

The gesture then drives ws1's viewport (`currentViewStart` marches `502.5 →
1011.0` over ~18 update frames) and later scrolls back. Every gesture event
carries ws1's id. The video's workspace (ws2) is never touched again.

---

## Root cause (confirmed in source)

The observable event that flips the active workspace is the external
`focusedWindowChanged` for the app's *other* window being honored over Nehir's
own pending focus request.

### The observed focus change enters `handleAppActivation`

`AppAXContext.onFocusedWindowChanged` dispatches into
`handleAppActivation(pid:source:)` with `source: .focusedWindowChanged`
(`ServiceLifecycleManager.swift:99–104`). Inside `handleAppActivation`
(`AXEventHandler.swift:3579`), the focused AX window is resolved to `47139`, its
entry is found, and its workspace `wsId` = ws1. `isWorkspaceActive` is computed
as `false` (ws1 is not the active workspace of display 1). The disposition is
`conflictsWithPendingRequest(#110 → 47748 / ws2)`.

### The pre-close deferral guard does not cover this source

`shouldDeferInactiveNativeActivationBeforeCloseRecovery`
(`AXEventHandler.swift:3081`) exists precisely to defer "macOS activates an
inactive-workspace window during a close/teardown before recovery has armed."
Its own doc-comment describes this jump. But it is gated on
`source == .workspaceDidActivateApplication` — so a `focusedWindowChanged`
carrying the same ambiguous shape **falls straight through**. It also requires an
already-active recovery workspace / active focused workspace, and here
close-recovery for ws2 had already *expired* (step 2).

The `close_recovery_activation_gate` trace at `AXEventHandler.swift:3717`
(`decision: "evaluate"`) records that none of the same-app suppress/defer guards
fired, and execution reaches the disposition switch.

### The conflict is resolved in favor of the external change

At the `conflictsWithPendingRequest` arm (`AXEventHandler.swift:3817–3830`):

```swift
case let .conflictsWithPendingRequest(request):
    if shouldHonorObservedFocusOverPendingRequest(
        source: source,
        origin: origin
    ) {
        clearManagedFocusState(
            matching: request.token,          // 47748 on ws2 — the video
            workspaceId: request.workspaceId
        )
        break                                 // fall through to activate observed entry
    }
    continueManagedFocusRequest(request, …)   // (would keep chasing ws2) — NOT taken
    return
```

`shouldHonorObservedFocusOverPendingRequest` (`AXEventHandler.swift:7225–7230`)
is:

```swift
private func shouldHonorObservedFocusOverPendingRequest(
    source: ActivationEventSource,
    origin: ActivationCallOrigin
) -> Bool {
    source.isAuthoritative && origin == .external
}
```

and `ActivationEventSource.isAuthoritative` is `true` exactly for
`.focusedWindowChanged` (`ServiceLifecycleManager.swift:15–17`). The event's
`origin` is `.external`. So the predicate returns **true**: Nehir **clears its
own pending request to restore the video** (`#110 → 47748 / ws2`) and proceeds to
`handleManagedAppActivation` for the observed entry `47139`, which activates ws1.

`shouldHandleObservedManagedActivationWithoutPendingRequest`
(`AXEventHandler.swift:7209`) shows the same authoritative-focus bias applies to
the no-request path (`case .focusedWindowChanged: return true` even when
`!isWorkspaceActive`), so once the pending request is cleared there is nothing
left to stop the inactive-workspace activation.

### Why the swipe then hits the wrong workspace

By the time `touch_scroll_gesture_armed` fires (same second), ws1 is the active
interaction workspace and its column 1 (`47139`) is the selected node. The
gesture pipeline operates on the active workspace, so the scroll drives ws1.

---

## Causal chain (one line)

native-fullscreen Space destroyed on ws2 → close-recovery for ws2 expires →
macOS emits external `AXFocusedWindowChanged` for the same app, but its focused
window `47139` lives on the inactive ws1 → the pre-close deferral guard ignores
it (only covers `workspaceDidActivateApplication`) →
`shouldHonorObservedFocusOverPendingRequest` treats the authoritative external
focus change as winning and **discards Nehir's pending request to restore the
video on ws2** → ws1 activated → 3-finger swipe scrolls ws1 = wrong workspace.

---

## Open questions for the fix stage (not decided here)

1. **Should an authoritative external `focusedWindowChanged` be allowed to switch
   the *active workspace* to an inactive one while a managed focus request for the
   currently-active workspace is still pending?** The honor-observed-focus rule
   was written to respect real user focus intent, but here the "focus change" is
   macOS's automatic re-homing after a Space teardown, not user intent.
2. **Should the inactive-native-activation deferral
   (`shouldDeferInactiveNativeActivationBeforeCloseRecovery`) also cover
   `source == .focusedWindowChanged`,** at least within a grace window after a
   `native_fullscreen_destroy` for the same pid on a different workspace?
3. **Does the pending request `#110` targeting the video (ws2) represent the
   correct post-exit intent?** If so, honoring it (rather than clearing it) would
   keep the user on ws2. Confirm where `#110` originates (native-fullscreen
   restore path) before relying on it.
4. **Same-pid, cross-workspace disambiguation:** the losing and winning windows
   share a pid; `currentTargetSamePid=true`. Any guard must distinguish "app's
   other window on another workspace" from a genuine user re-focus.

## Reproduction (topology-level, no log needed)

1. On one display, stack two Nehir workspaces (A and B) both containing windows
   of the **same** app (e.g. a browser with a window on each).
2. Make workspace A active; put one of A's windows into **native** fullscreen
   (green button / `toggleNativeFullscreen`).
3. Exit native fullscreen. As macOS tears the fullscreen Space down it re-homes
   focus to the app's window on workspace B.
4. Immediately 3-finger swipe to scroll. Observe the scroll applies to workspace
   B, not A. Expected: stay on / scroll workspace A.
