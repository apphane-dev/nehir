# Click on partially visible sibling never observed: no reveal, resize hits stale target

Date: 2026-07-18

## Symptoms (both from one 21-second capture)

1. Clicking into a partially visible sibling tiled window (same app as the
   focused window) did not trigger a viewport reveal — the clicked window
   stayed mostly offscreen.
2. Immediately afterwards, the resize-column command (`toggleColumnWidth`)
   resized the *previously* focused window, not the window the user had just
   clicked.

Both symptoms have a single root cause: **Nehir never observed any focus
change after the click** — no reveal ran, and the layout selection (which the
resize command trusts) stayed on the old window.

## Topology and initial state

Single built-in display, `frame=(0,0,2056,1329)`, one active workspace
(`2E03BE57…`) with 5 tiled columns (3× Ghostty herdr panes hidden left, 2×
Helium browser windows) plus one sticky floating Helium window:

- Focused/selected: Helium window `34788:188`, column 4 (last), on screen at
  `{{370,7},{1316,1251}}` (later resized narrower).
- Sibling: Helium window `34788:1721`, column 3, live frame
  `{{-1563,7},{1926,1251}}` — visible strip is `x ∈ [0, 363]` only.
- Floating sticky: Helium `34788:771`, frame `{{0,0},{772,608}}`
  (`barFloating=accepted(sticky)`).
- Focus targets: `wmCommandTarget=34788:188 wmCommandTargetSource=layoutSelection
  layoutSelection=34788:188 observedManagedFocus=34788:188`.
- AXManager runtime state showed `pendingObservers=2 recentFailures=1`.
- `focusFollowsMouse=false`.

## Trace evidence

Mouse trace (locations in the mouse trace's screen space; window frames above
are in the same space):

```
21:08:17 mouseDown loc=(795.3,483.2) button=left    ← inside 188 (x 370..1381)
21:08:17 mouseUp   loc=(795.3,483.1)
21:08:18 mouseDown loc=(336.8,509.6) button=left    ← inside 1721's visible strip (x < 363)
21:08:18 mouseUp   loc=(336.7,509.6)
```

Niri resize trace — every resize command in the capture, including `cmd=43`
issued **4 seconds after the sibling click**, targets column 4 / window 188:

```
21:08:14 cmd=42 apply kind=toggleColumnWidth(backward) ... columnIndex=4 ... window=188
21:08:22 cmd=43 apply kind=toggleColumnWidth(backward) ... columnIndex=4 ... window=188
```

Create-focus trace (ordered ring; the relevant tail):

```
border_reapplied token=34788:188 phase=animationSettled   (×7, resize settle)
pending_focus_started request=1150 token=34788:188 reason=mouseScrollSelection
activation_source_observed pid=34788 source=focusedWindowChanged
reveal_decision token=34788:188 ... is_ws_active=true should_activate=false source=focusedWindowChanged
focus_confirmed token=34788:188 source=focusedWindowChanged
focus_reality token=34788:188 ... app_focused_window=188
```

Key negative findings:

- There is **no** `reveal_decision`, `focus_confirmed`, or any activation
  event for token `34788:1721` anywhere in the capture.
- There is exactly **one** `source=focusedWindowChanged` activation for
  pid 34788 in the whole 21 s — and it confirms 188, with the app itself
  reporting `app_focused_window=188` at query time.
- Between the sibling click (21:08:18) and `cmd=43` (21:08:22) the tracing
  log records nothing at all for pid 34788.
- End-of-capture focus targets are unchanged:
  `layoutSelection=34788:188 observedManagedFocus=34788:188`.

By contrast, pid 936 (a system dialog surface) produced three genuine
`source=focusedWindowChanged` activations earlier in the same capture — the
notification pipeline as such was alive.

## Source-backed causal chain

### Why no reveal (symptom 1)

The reveal decision lives exclusively in the AX-activation path:
`handleManagedAppActivation` records `reveal_decision` and drives
confirm/reveal (`Sources/Nehir/Core/Controller/AXEventHandler.swift:4460-4497`).
It is reached from `AppAXContext.onFocusedWindowChanged`
(`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:99-104`), whose
only upstream is the per-app `kAXFocusedWindowChangedNotification` observer
(`Sources/Nehir/Core/Ax/AppAXContext.swift:222-233,967-984`). With
`focusFollowsMouse=false`, Nehir has **no mouse-side click-to-focus path**: a
plain left click is not interpreted by `MouseEventHandler` at all (the capture
shows only raw `mouseDown`/`mouseUp` with no follow-up), so the AX
notification is the *sole* signal that a click moved focus. No notification ⇒
no `reveal_decision` ⇒ no reveal.

### Why resize hit the old window (symptom 2)

`cycleSize` resolves its target purely from the Niri viewport selection:

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1863-1877
guard let currentId = state.selectedNodeId,
      let windowNode = engine.findNode(by: currentId) as? NiriWindow,
      let column = engine.findColumn(containing: windowNode, in: wsId)
else { return }
engine.toggleColumnWidth(column, ...)
```

`selectedNodeId` only moves when a focus change is confirmed through the
activation path above. Since the click's focus change was never observed,
`selectedNodeId` (and `wmCommandTarget`, sourced from `layoutSelection`)
stayed on 188's node, and `cmd=43` resized column 4/window 188 while macOS
keyboard focus was — per the user's observation — on the clicked sibling.
This is the same "resize trusts `selectedNodeId`" surface documented in
[20260713-resize-command-target-offscreen-selection](20260713-resize-command-target-offscreen-selection.md),
armed here by a different precondition (lost focus observation instead of
focus-validation restoring an offscreen selection).

### Why the one observed `focusedWindowChanged` is not the click

Two source facts explain the single 188-confirming activation:

1. `WMController.focusWindow` (`Sources/Nehir/Core/Controller/WMController.swift:4151-4198`)
   fronts the window via `performWindowFronting` and then calls
   `probeFocusedWindowAfterFronting`, which re-enters
   `handleAppActivation(pid:source:.focusedWindowChanged, origin:.probe)`
   (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1296-1314`). A probe
   is therefore indistinguishable from a real notification in the
   `activation_source_observed` trace line (origin is not recorded).
2. The trace shows `pending_focus_started request=1150 token=34788:188
   reason=mouseScrollSelection` immediately before that activation.
   `.mouseScrollSelection` has exactly one call site: the committed-trackpad-
   gesture finalize path, which re-issues `focusWindow` for the active
   column's window on every gesture end — even when the snap did not change
   columns (`Sources/Nehir/Core/Controller/MouseEventHandler.swift:2179-2196`,
   finalize entry at `:2024`).

So the observed activation is Nehir's own echo: a viewport swipe finalized
(shortly before the capture's mouse ring begins at 21:08:17), re-fronted the
already-focused 188, and the fronting probe confirmed 188. The click on the
sibling produced **no** notification of its own.

## Root-cause hypotheses (ranked)

### H1 (primary): Helium's focus observer was not delivering

`AppAXContext.createContext` creates the focus observer once, on the app's
dedicated AX thread, with **no error handling and no retry**: the results of
`AXObserverCreate` and `AXObserverAddNotification` for
`kAXFocusedWindowChangedNotification` are ignored
(`Sources/Nehir/Core/Ax/AppAXContext.swift:222-233`). If registration failed
(or the observer later died), that app emits no focus notifications for the
lifetime of its context, silently. Supporting signals:

- Zero genuine focus notifications from pid 34788 across 21 s of active
  clicking, while pid 936's notifications flowed normally.
- Runtime state `pendingObservers=2 recentFailures=1` shows observer
  installation is not universally healthy.
- Existing work on observer loss (branch reinstalling app launch/termination
  observers after restart) shows this class of failure recurs.

### H2 (alternate): the click never focused a window at all

The click point `(336.7,509.6)` also lies inside the sticky floating Helium
window 771 (`{{0,0},{772,608}}`) if 771 is z-above 1721 at that point, and
could in principle have been swallowed by an overlay surface. This would also
produce "no notification". It does not, however, explain the user observing
keyboard focus on the sibling before invoking resize, so it is second-ranked.
(If 771 had been focused by the click, a genuine notification confirming 771
would be expected — none arrived, which weakly argues against this branch
too, and further supports H1.)

## Secondary robustness gaps worth fixing regardless

1. **The notification callback discards the window.** The AX callback passes
   only the pid (`Sources/Nehir/Core/Ax/AppAXContext.swift:967-984`);
   `handleAppActivation` re-queries the app's *current* focused window at
   processing time. Any short-lived focus state (or a race with Nehir's own
   `performWindowFronting`) is masked — the handler can only ever see the
   final winner, never the transition the user made.
2. **Gesture-end refocus is unconditional.** The finalize path re-issues
   `focusWindow(…, .mouseScrollSelection)` even when the snapped column is
   unchanged (`Sources/Nehir/Core/Controller/MouseEventHandler.swift:2179-2196`).
   Each such call fronts a window and can race a user click that happened in
   the same instant. A no-op guard (previous active column == ended column
   and token already confirmed) would remove this stomp risk.
3. **Probes are indistinguishable from real notifications in traces.**
   `probeFocusedWindowAfterFronting` reuses `source=.focusedWindowChanged`
   and `activation_source_observed` does not record `origin`
   (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1296-1314`). The "AX
   notification trace" section of the runtime capture was empty even though
   activations occurred, so raw notification arrival per pid is currently
   unobservable.

## Suggested next steps

1. Instrument to disambiguate H1 vs H2 (small, additive):
   - record `origin` in `activation_source_observed`;
   - record every raw `kAXFocusedWindowChangedNotification` arrival (pid +
     reported focused window id) into the existing, currently empty AX
     notification trace;
   - log failures of `AXObserverCreate`/`AXObserverAddNotification` in
     `AppAXContext.createContext` with the pid/bundle id.
2. Fix H1 structurally: check registration results and retry/reinstall the
   focus observer (aligns with the existing observer-reinstall work).
3. Independently harden the symptom-2 surface: commands that act on
   `selectedNodeId` could cross-check the app-reported focused window for the
   frontmost managed app, or at least the confirmed managed focus, before
   resizing (see the 2026-07-13 resize-target discovery for the same
   conclusion from a different arming path).
4. Consider the gesture-end no-op refocus guard (gap 2 above).
