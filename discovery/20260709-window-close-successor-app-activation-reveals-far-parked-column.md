# Closing a window lets macOS successor-app activation reveal a far parked column

**Status:** discovery / source-backed root cause. Verified against `main`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift`); re-verify line numbers
before implementing.

**Symptom:** closing a managed window on the right of the viewport scrolls the
viewport all the way to a *different* app's window parked in the first column,
instead of keeping the viewport where it was / selecting the surviving window
nearest the closed one.

Reported: "closed Zoom on the right side of the viewport, but it scrolled to
Ghostty placed in the 1st column."

This is **related to but distinct from** the quick-terminal-close cluster
([`../completed/20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md`](../completed/20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md),
CR-1, **landed** in `d3ef41ee`). There the disruptor is a same-app unmanaged
**overlay** close. Here it is a plain managed window close where macOS activates
a **different application** as the successor, and Nehir follows that activation
with a reveal. The landed CR-1 fix does not touch this path (it only recognizes
overlay-capable pids and same-app close/overlay evidence), so this finding is
still open.

All evidence inlined; no dependency on any trace file.

---

## Evidence

Workspace `F80F782F…` ("workspace 4"), single display, **5 columns**,
`activeColumnIndex=3`, viewport scrolled right (`currentViewStart≈3248`). Layout
at the moment of the close:

```text
c0  x=0.0     w32187  com.mitchellh.ghostty   65% width, parked/selected-left
...
c3  x=4271.4  w32376  us.zoom.xos (pid 11980)  the window being closed (on-screen, right)
```

Close sequence (`13:49:43`):

```text
ax=AXUIElementDestroyed pid=11980 window=32376              // Zoom window closes

# 1. the closing Zoom window's own focus-confirm — correctly a no-op
close_recovery_activation_gate token=11980:32376 isWorkspaceActive=true source=focusedWindowChanged
ax_focus_confirm_reveal_candidate token=11980:32376 columnIndex=3 visibility=fullyVisible
ax_focus_confirm_reveal_result   token=11980:32376 didReveal=false      // good, no move

# 2. macOS then activates a DIFFERENT app (Ghostty) as the successor
activation_source_observed pid=82494 source=workspaceDidActivateApplication
focus_confirmed token=82494:32187 source=workspaceDidActivateApplication
close_recovery_activation_gate token=82494:32187 isWorkspaceActive=true source=workspaceDidActivateApplication

ax_focus_confirm_after_activate  token=82494:32187 preserveActiveViewport=false preserveActiveViewportReason=none
ax_focus_confirm_reveal_candidate token=82494:32187 columnIndex=0 visibility=parked(...) revealStyle=auto
ax_focus_confirm_reveal_result   token=82494:32187 columnIndex=0 didReveal=true      // THE BAD REVEAL

relayout.viewportOffsetChanged activeColumnIndex=0
  currentViewStart=3246.2 → targetViewStart=-361.9                    // scrolls all the way left
```

No `close_recovery_begin` is armed for the Zoom close on this workspace (the only
close-recovery event in the window is `close_recovery_inactive_activation_deferred`
for an unrelated pid on another workspace). So nothing pins the viewport, and the
successor **app** activation is treated as an ordinary managed activation that
reveals its (parked, far-left) column.

---

## Root cause

When a managed window closes, macOS frequently activates the **next application**
in z-order (here Ghostty), delivered as `source=workspaceDidActivateApplication`
resolving to a managed window of that other app. Nehir's close-recovery /
stable-viewport machinery is built around **same-app** successor churn (the app
whose window closed re-focusing one of *its own* windows) and around the
quick-terminal overlay case. A **cross-app** successor activation triggered by a
close does not arm close-recovery for the closed window's workspace, so:

- the viewport is not pinned (`preserveActiveViewport=false … reason=none`), and
- the successor app's window is revealed by the normal reveal path
  (`ax_focus_confirm_reveal_*`), even though it is a parked column far from where
  the user was working.

The user's expectation — "choose the surviving window nearest the closed one" —
is the close-recovery stable-target intent (`stableRecoveryFocusTarget` /
`activeTileTokenNearestViewport`, `AXEventHandler.swift:2390-2452`). That path is
never reached here because close-recovery does not engage for a close whose
successor is a different application.

### Verified successor-selection locus

When the closed window's tiled focus is no longer eligible, workspace focus
resolution falls back to the **first tile**, not the tile nearest the removed
one: `preferredWorkspaceFocusToken` ends with

```swift
// WorkspaceManager.swift:1856
return tiledEntries(in: workspaceId).first {
    isFocusResolutionEligible($0, in: workspaceId, mode: .tiling)
}?.token
```

`tiledEntries(...).first` is column 0 — here the parked Ghostty window `32187`.
So the successor focus chosen after Zoom's removal is column 0 regardless of where
Zoom was, and confirming/revealing that token is what scrolls the viewport left.
This resolver is reached via `resolveWorkspaceFocusToken`
(`WorkspaceManager.swift:1861`) →
`ensureFocusedTokenValid` (`WMController.swift:3824`, called from
`LayoutRefreshController.swift:494`). The observable `workspaceDidActivateApplication`
for Ghostty in the trace is consistent with this internal selection driving the
app activation.

### Why this is not the QT bug

- The disruptor is `workspaceDidActivateApplication` for a **different pid**, not a
  same-app `focusedWindowChanged` redirect, and not an unmanaged overlay destroy.
- There is no overlay evidence (`recentNonManaged` / `overlayVisible`) and no
  same-app-close evidence for the successor app, so the CR-1 guards
  (`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`, the
  overlay stable redirect) are structurally inapplicable — they key on the
  successor being the *same* app as the closed window.

---

## Prerequisites for reproduction

1. A workspace with several columns; the viewport scrolled so a window on the
   right (e.g. column 3) is active/on-screen.
2. A managed window of a **different** app parked in the first column (here a
   65%-width Ghostty window at column 0).
3. Ghostty (or whichever app owns the far column) is the app macOS will activate
   as the successor when the right-hand window closes — i.e. it is next in
   application z-order. (As with the QT bug, which app macOS activates on close is
   the uncontrolled lever; it must be the far-column app for this to bite.)
4. Close the right-hand window (here Zoom at column 3).

Result: the viewport scrolls left to reveal the successor app's parked first
column instead of staying near the closed window.

---

## Candidate fix directions (for the plan stage — not prescribed)

1. **Treat a close-induced cross-app successor activation as close-recovery.**
   When a `workspaceDidActivateApplication`/`focusedWindowChanged` activation for a
   *different* pid arrives immediately after a managed window on the active
   workspace was destroyed, arm the same viewport-pin / nearest-surviving-window
   selection used for same-app close recovery, instead of running a full reveal of
   the successor's parked column. Recency of the destroy (a short TTL keyed on the
   closed window's workspace, not pid) is the trigger.
2. **Prefer the spatially-nearest surviving column over the successor app's
   window.** After a close, if the successor activation would reveal a column far
   from the closed window's column, redirect focus to the nearest surviving
   managed column to the closed one and keep the viewport put — the explicit
   "nearest to just-closed" rule the user expects.
3. **At minimum, pin the viewport (no reveal) for a successor activation that
   lands on a parked column right after a close**, leaving focus selection to
   normal rules but not scrolling.

Compatibility: a genuine user app-switch (Cmd-Tab / Dock) to the far app must
still reveal its window. The distinguishing signal is temporal correlation with a
just-closed managed window on the active workspace, not app identity.

## Cluster

Adjacent to **CR-1** (close-recovery / same-app overlay focus churn) and **VR-1**
(automatic viewport movement) in
[`20260708-cross-discovery-relevance-clusters.md`](20260708-cross-discovery-relevance-clusters.md),
but a separate root: cross-app successor activation on close, not same-app/overlay
churn — none of CR-1's guards key on it, since they all require same-pid
evidence (recent same-app window close, or overlay-capable pid). Do not fold this
into CR-1's reopen criterion; it needs its own plan.

Related documents:

- [`../completed/20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md`](../completed/20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md)
  — sibling finding from the same investigation session, **landed** in
  `d3ef41ee`. Same surface symptom class (an unwanted post-close reveal/scroll to
  a parked column) but a same-app/overlay root, not cross-app; its fix explicitly
  does not cover this document's failure mode.
- [`../completed/20260706-stable-viewport-on-window-close-recovery.md`](../completed/20260706-stable-viewport-on-window-close-recovery.md)
  — parent that introduced the viewport-pin / stable-target-redirect / nearest-tile
  machinery (`stableRecoveryFocusTarget`, `activeTileTokenNearestViewport`,
  `AXEventHandler.swift:2390-2452`) this document's fix directions would extend to
  the cross-app case.
- [`../completed/20260707-close-last-app-window-stay-on-current-workspace.md`](../completed/20260707-close-last-app-window-stay-on-current-workspace.md)
  — established that a close should keep focus/viewport local to the current
  workspace even when the closed app's own workspace loses its survivor; this
  document is the cross-app analogue of that same "stay local on close" intent.
- [`../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md`](../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md)
  — compatibility boundary any fix here must preserve: a genuine user-driven
  app switch (Cmd-Tab / Dock) to a window on another workspace must still
  reveal/follow it. The distinguishing signal for this document's fix is temporal
  correlation with a just-closed managed window on the active workspace, not app
  identity — mirroring how that document's guard distinguishes real switches from
  close-successor churn.
