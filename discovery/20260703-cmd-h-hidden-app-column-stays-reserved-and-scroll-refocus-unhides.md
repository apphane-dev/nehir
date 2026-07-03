# Discovery: Cmd-H hidden app keeps its column reserved, and scroll snap refocuses (unhides) it

Status: discovery — runtime evidence and source mechanism both fully
confirmed; behavior follows directly from the code. Found while reproducing
the admission-suppression trap in
`discovery/20260703-user-activated-slack-suppressed-as-stale-under-nonmanaged-focus.md`
(this is a separate defect with a different mechanism).

Validated against the main Nehir source tree on 2026-07-03 at commit
`8286c192` ("Show other displays in the workspace bar"), the build that
produced the capture.

## Summary

Hiding a managed app with Cmd-H does not remove its window from the niri
layout: the column stays in the scroll strip as a reserved empty slot. Worse,
a trackpad scroll whose snap lands on that column **focuses the hidden
window**, which makes macOS unhide the app — the window pops back on screen
2 seconds after the user hid it. From the user's point of view: "hiding with
Cmd-H is broken — tile stays reserved, window reappears on scroll."

## Evidence (capture 2026-07-03, 11:52:25Z–11:52:33Z)

Single built-in display, workspace `C6E4E9A2-43B0-4475-9BBB-DA9DAB331ED8`
with five managed tiled windows: VS Code (24553), Slack (pid 33189,
windowId 25368), agterm (25239), Telegram (22998), Helium (23176).

1. `11:52:28Z` — user hides Slack with Cmd-H. Background events:
   `focus_lease_changed owner=native_app_switch
   reason=workspaceDidActivateApplication` followed by
   `managed_focus_confirmed` on VS Code (macOS hands focus to the next app).
   The refresh statistics record exactly one `appHidden` refresh requested and
   executed — with `lastAffectedWorkspaceIds … appHidden: Set([])` (empty).
   **No `hidden_state_changed` record is ever emitted for the Slack token**,
   and no window-removal or layout-change event follows: the layout still has
   5 columns with Slack's column untouched.
2. `11:52:29–30Z` — user performs a three-finger scroll. The gesture-end
   viewport record shows the snap landing on the hidden window's column and
   requesting focus on it:

```text
reason=touch_scroll_gesture_end … snap=true focusSelection=requested
  endedActiveColumnIndex=1 columns=5
  preferredFocus=WindowToken(pid: 33189, windowId: 25368)
  confirmedFocus=WindowToken(pid: 26735, windowId: 24553)
  layout=…|c1[…]{w25368:selected{cur=550,7,1011,1251,…,hidden:nil}}|…
```

   Column c1 is Slack, still occupying its full 1011-pt slot (`hidden:nil` —
   the geometry-hide machinery never touched it).
3. Immediately after: `managed_focus_requested` → two
   `managed_focus_confirmed` events for the Slack token, one `appUnhidden`
   refresh requested and executed. macOS unhides an app whose window is
   focused, so the window reappears.
4. Capture end state: Slack `mode=tiling phase=tiled hidden=nil
   layout=standard observedVisible=true`, `focus focused=33189:25368` — fully
   back as if Cmd-H had never happened.

## Source mechanism (all cites against `8286c192`)

1. **Hide keeps the entry and the column.** `handleAppHidden`
   (`Sources/Nehir/Core/Controller/AXEventHandler.swift:2971`) inserts the pid
   into `hiddenAppPIDs`, tags each entry with
   `setLayoutReason(.macosHiddenApp, …)`, and requests an `.appHidden`
   refresh. Nothing removes the window from the niri engine's column strip, so
   the layout keeps reserving the slot (the capture's `appHidden` refresh
   affected zero workspaces). The tag's consumers are focus/border validity
   (`isManagedWindowDisplayable`,
   `Sources/Nehir/Core/Controller/WMController.swift:603`) and full-rescan
   preservation (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1524`
   keeps hidden-app entries from being pruned while the app is invisible) —
   not column layout.
2. **Unhide restores placement.** `handleAppUnhidden`
   (`AXEventHandler.swift:3018`) calls `restoreFromNativeState` for entries
   tagged `.macosHiddenApp`. So the design intent is "keep the entry, restore
   in place on unhide" — the reserved column is a consequence of that intent,
   not an oversight in a single spot.
3. **Scroll snap focuses hidden windows.** The trackpad gesture-end path
   (`Sources/Nehir/Core/Controller/MouseEventHandler.swift:2160-2180`) takes
   the snapped column's selected window and calls
   `controller.focusWindow(selectedWindow.token)` guarded only by
   `focusFollowsMouseEnabled` and `isNonManagedFocusActive`. It never checks
   `isManagedWindowDisplayable` (which is false for hidden-app windows via
   `hiddenAppPIDs` / `.macosHiddenApp`), so the snap requests focus on the
   hidden window and macOS unhides the app. This is the concrete "reappears
   on scroll" trigger; any other path that focuses by column index without a
   displayable check would do the same.

## Relationship to the admission-suppression discovery

Separate defects, related workflow. This one is about a *managed* window
whose app gets Cmd-H hidden mid-session (entry kept, column reserved,
accidental unhide). The suppression discovery is about a window with *no
entry* (hidden across a Nehir restart, so the startup rescan never admitted
it) being permanently rejected while non-managed focus is active. Fixing this
discovery changes what Cmd-H means for the layout; fixing that one changes
admission. Both were reproduced with the same Slack window on the same day.

## Fix options

**A. Treat Cmd-H like removal-with-restore (recommended).**
On `.appHidden`, remove the app's windows from the niri columns (the strip
compacts, like a close) while keeping the entry/restore metadata —
`restoreFromNativeState` plus the existing window-restore machinery already
handle re-placement on unhide. This matches user expectation (a hidden app
occupies no screen space) and eliminates the accidental-unhide vector
entirely, since the column no longer exists to snap onto. Cost: unhide no
longer restores the exact column index unless the restore path re-inserts at
the recorded position (the `niriPlacement` restore intent already records
column/tile indices).

**B. Minimal: exclude non-displayable windows from focus selection.**
In the gesture-end selection (and any column-snap focus path), skip windows
where `isManagedWindowDisplayable` is false — snap to the column but don't
focus, or select the nearest displayable column instead. Fixes "reappears on
scroll" but leaves the reserved empty tile, which is likely still perceived
as broken.

**Recommendation:** A for the product behavior; add B's displayable guard to
the gesture-end focus request regardless, as defense in depth for other
non-displayable states (`.nativeFullscreen`, corner-hidden).

## Validation sketch

1. Five tiled windows; Cmd-H one of the apps.
2. Expected after fix A: the strip compacts to four columns (trace shows a
   window-removal/relayout for the hidden token; `appHidden` refresh affects
   the workspace); scrolling across the strip never unhides the app.
3. Unhide the app (Dock click / Cmd-Tab): window is re-admitted at its
   recorded placement (`window_admitted` or restore event; column count back
   to five).
4. Regression: Cmd-H then immediately Cmd-Tab back must restore focus and
   placement; hide across a Nehir restart still behaves per the companion
   discovery's fix.
