# Restore managed focus after explicit viewport navigation

Status: landed on `main` in commit `8a2e6db4` (2026-07-13).

## Source discovery

- `discovery/20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md`
- `discovery/20260713-resize-command-target-offscreen-selection.md`
- NF-1 in `discovery/20260708-cross-discovery-relevance-clusters.md`

## Landed result

`MouseEventHandler` now requests `.mouseScrollSelection` focus for a selected
managed window even while non-managed focus is active, while preserving the
focus-follows-mouse guard and existing focus-request ordering. The gesture-end
diagnostic records `nonManagedFocusAtSelection`; the obsolete
`suppressedNonManagedFocus` disposition is no longer emitted for this explicit
navigation path. A patch changeset was added in
`.changeset/20260713170109-restore-managed-focus-after-explicit-viewport-na.md`.

The implementation changed only `Sources/Nehir/Core/Controller/MouseEventHandler.swift`
and added the changeset. Tests were intentionally not edited pending real-user
runtime confirmation, per project policy.

## Problem

A committed, snapped three-finger viewport gesture updates Niri's selected node
and the preferred focus token, but `MouseEventHandler` currently refuses to
request managed focus whenever `isNonManagedFocusActive` is true. That leaves
confirmed managed focus and generic command targeting on an earlier window (or
with no target) even though the user explicitly navigated to a different managed
column.

This is observable with Ghostty Quick Terminal. Once the Quick Terminal is the
non-managed focused surface, a subsequent snapped gesture can select a managed
Ghostty window while retaining the prior confirmed managed token. The trace
records `focusSelection=suppressedNonManagedFocus`; commands which resolve
through `managedCommandTarget()` can then decline a target.

## Decision and invariant

A **committed snapped viewport gesture** is explicit user navigation. When it
selects a managed tiled window and focus-follows-mouse is disabled, it must
request managed focus even if an unmanaged overlay or Quick Terminal currently
owns macOS focus.

This intentionally lets an explicit gesture dismiss the overlay's focus claim
in favor of the selected tiled window. It does **not** weaken the non-managed
focus protections for passive AX activation, mouse movement, focus-follows-mouse,
close recovery, or generic command resolution before an explicit selection.

After the normal AX confirmation, selection, preferred focus, confirmed managed
focus, and command targeting must converge on the gesture-selected window.

## Scope

### Change

`Sources/Nehir/Core/Controller/MouseEventHandler.swift`

In the committed trackpad-gesture finalization path around
`finalizeOrCancelCommittedGesture`:

1. Keep the existing selection behavior: after `endGesture`, synchronize the
   viewport selection to its snapped active column unless the locked gesture
   context bypasses snapping.
2. Keep the existing `focusFollowsMouseEnabled` guard and managed-keyboard-target
   lookup.
3. Remove only the `!isNonManagedFocusActive` prerequisite from the managed
   focus request for a selected window. A selected managed window must call
   `controller.focusWindow(_:reason: .mouseScrollSelection)` regardless of the
   current non-managed-focus flag.
4. Capture whether non-managed focus was active for the existing
   `touch_scroll_gesture_end` diagnostic. Preserve the existing
   `focusSelection=requested` value for a successful request; add a separate
   boolean detail such as `nonManagedFocusAtSelection=true` so a future capture
   can distinguish the explicit override from ordinary scroll focus without
   creating a second trace vocabulary.
5. Leave the existing animation and mouse-warp suppression ordering intact:
   selection/focus request is issued before the snap animation is started, and
   the existing confirmed-token suppression remains the fallback when no focus
   request was possible.

`.changeset/<generated>.md`

Create a patch changeset using:

```bash
mise run changeset patch "Restore managed focus after explicit viewport navigation"
```

## Do not touch

- `Sources/Nehir/Core/Controller/AXEventHandler.swift`: do not alter
  non-managed activation, Quick Terminal classification, overlay-close churn,
  or close-recovery policy in this slice.
- `Sources/Nehir/Core/Controller/WMController.swift`: do not change the
  non-managed command-target resolver. It should become usable through normal
  managed-focus confirmation rather than acquire a competing selection fallback.
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` and
  `Sources/Nehir/Core/Layout/Niri/*`: do not globally synchronize selection,
  confirmed focus, and viewport anchor. Those domains deliberately diverge in
  inactive, locked, unsnapped, gesture, and recovery states.
- `Tests/`: do not add, edit, move, or delete tests until the user confirms the
  runtime fix in the real Quick Terminal reproduction. This is a hard project
  policy, even though the validation commands below still run the existing suite.

## Implementation steps

1. Re-read the current committed-gesture finalization code in
   `MouseEventHandler.swift`; confirm the selected-window path still has the
   same sequence: snap → synchronize selection → choose managed target → request
   focus → trace disposition → start animation.
2. Make the narrow focus-gate change and add the diagnostic boolean. Do not
   introduce a test-only conditional or a new focus-policy abstraction.
3. Run the fast gate:

   ```bash
   mise run test:compile
   ```

4. Create the patch changeset.
5. Run the full existing suite once:

   ```bash
   mise run test
   ```

6. Review the diff for the do-not-touch fences and commit with the plain-English
   subject:

   ```text
   Restore focus after explicit viewport navigation
   ```

## Manual acceptance

The user validates this before any test work:

1. Arrange several managed tiled Ghostty windows and focus one.
2. Open Ghostty Quick Terminal, leaving it as the unmanaged focused surface.
3. Use a committed three-finger snapped gesture to navigate to another visible
   managed Ghostty column; do not click that tiled window.
4. Confirm the selected window becomes managed focus after AX confirmation and
   that a focused-window command targets it rather than silently declining or
   targeting the pre-gesture window.
5. Confirm a Quick Terminal open/close without a viewport gesture still retains
   the existing overlay and close-recovery behavior.
6. Capture diagnostics if needed. The gesture-end record should show
   `focusSelection=requested` and `nonManagedFocusAtSelection=true`; the later
   focus confirmation should identify the selected token.

## Risks and mitigations

- **Overlay focus can be intentionally displaced.** This is the requested
  behavior only for a committed snapped gesture, the strongest available local
  signal of user intent. Passive activation and all other non-managed guards
  remain unchanged.
- **Focus request can fail at the macOS boundary.** The existing confirmation
  and command-target safeguards remain authoritative; the change requests focus
  but does not synthesize confirmation or command authority.
- **Regression in gesture animation/warp behavior.** The implementation must
  retain the current ordering and reuse the existing `.mouseScrollSelection`
  reason, animation start, and suppression code.
- **Broader stale-focus bugs exist.** This plan fixes the explicit viewport
  navigation escape hatch only. It is not a replacement for separate NF-1 work
  on passive activation or command paths with an explicit token.
