# Workspace bar reactive lens over viewport selection

**Status:** implemented — on branch `refactor-workspace-bar-reactive-viewport-lens`,
pending user validation before merge (not yet on `main`)
**Source discovery:** [`discovery/20260622-workspace-bar-freezes-on-gesture-with-non-managed-focus.md`](../discovery/20260622-workspace-bar-freezes-on-gesture-with-non-managed-focus.md)
**Provenance:** Nehir-original architectural refactor; no upstream OmniWM counterpart.

## The architectural change in one line

The workspace bar is now a reactive lens over viewport selection: it recomputes
whenever the viewport's parked column changes, regardless of which code path
moved it, because the refresh is emitted at the single chokepoint that **all**
live viewport selection writes already funnel through.

This replaces the prior "scattered manual invalidation" model, where each mutation
path had to remember to call `requestWorkspaceProjectionRefresh()` and a missed
call-site left the bar frozen. The reported bug (3-finger gesture freeze under
non-managed focus) was exactly such a miss — and the whole failure class is now
eliminated for viewport-driven UI.

## What landed

All source references are repo-relative; re-verify before editing, line numbers
drift. Captured against branch `refactor-workspace-bar-reactive-viewport-lens`.

### The chokepoint publisher (the architectural fix)

`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3257`, inside
`updateNiriViewportState`. When a LIVE selection field
(`selectedNodeId` / `activeColumnIndex` / `selectionProgress`) changes and
`selectionRevision` bumps, it now emits
`invalidateWorkspaceProjection(reason: "viewportSelectionChanged")`.

Why this is the right chokepoint: the inline comment in
`updateNiriViewportState` documents that `withNiriViewportState`,
`applySessionPatch`, and direct callers all funnel through this method, and that
planning copies (`buildRelayoutPlan` / `computeLayoutPlan`) never do — they are
local `inout ViewportState` values embedded in a `WorkspaceSessionPatch`, arriving
here only via `applySessionPatch`, by which point the stale-selection guard has
reconciled them. So emitting here fires exactly once per real live selection
change, never for a planning write, and never per-pixel during a gesture
(`updateGesture` only touches the gesture-tracker offset, never the selection
fields — the revision bumps only when a discrete column lands at gesture end).

The invalidation routes via the existing
`onProjectionInvalidated` → `WMController.requestProjectionRefresh` channel and
the existing coalescing scheduler (`requestWorkspaceProjectionRefreshScheduling`,
two-yield generation-gated flush), so no new scheduling path was introduced.

### Option C content model (parked-column highlight)

`Sources/Nehir/Core/Controller/WMController.swift:734` adds
`viewportSelectedToken(for:)`, which resolves the window the viewport is parked
on for a monitor's active workspace from
`niriViewportState(for:).selectedNodeId` via the niri engine. It is threaded
through `workspaceBarItems` (`:708`) and `workspaceBarProjection` (`:724`).

`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift` takes a new
`viewportSelectedToken` parameter (`:26` and all helpers) and marks each
window/app `isSelected` (`entry.handle.id == viewportSelectedToken`) distinct
from `isFocused` (`entry.handle.id == focusedToken`). `focusedToken` still
sourced solely from `confirmedManagedFocusToken`.

`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift` adds `isSelected` to
`WorkspaceBarWindowItem` (`:35`), `WorkspaceBarWindowInfo` (`:56`), and the
`WindowIconView` call sites. `WindowIconView` renders a distinct, weaker
"selected" state — full opacity + soft accent glow (`glowRadius` 3,
`glowOpacity` 0.22 at `:640`/`:646`) — versus the strong "focused" state (scale
1.1, glow radius 4 / opacity 0.5). Two concepts, two inputs, two visual weights.

### Option B (sibling click / focus-follows-mouse path)

`Sources/Nehir/Core/Controller/WMController.swift:547-554` routes
`.focusProjection` to **both** the status bar (`requestFocusProjectionRefreshScheduling`)
and the workspace bar (`requestWorkspaceProjectionRefreshScheduling`). This is
the fix recommended by the sibling discovery
[`discovery/20260615-workspace-bar-focus-projection-routing.md`](../discovery/20260615-workspace-bar-focus-projection-routing.md)
for the click/FFM family; it is orthogonal to the gesture bug (the suppressed
gesture emits no `.focusProjection`).

### Changeset

`.changeset/20260624011050-fix-the-workspace-bar-freezing-during-trackpad-c.md`
(patch) — user-facing, framed as: the bar's selected-column indicator now
follows the swipe even when an unmanaged app is on top.

## How this differs from the discovery's scoped recommendation (intentional escalation)

The source discovery's pragmatic recommendation (its final section) was:

> land Option B (fixes the click/FFM family) **and** a scoped version of Option C
> that adds viewport-column as a bar input and emits a workspace-projection
> refresh at the gesture-end call-site.

That is a **point fix for the gesture path**: one more manual invalidation call
added to the scattered set. It fixes the reported symptom but leaves the failure
class intact — any *other* code path that mutates `ViewportState` selection
without remembering to invalidate would still freeze the bar.

This implementation goes further, per the handoff directive that escalated the
work to the full Option C / "reactive lens" goal: it moves invalidation off the
call-sites entirely and to the chokepoint. The manual gesture-end refresh the
discovery recommended was never added and never will be — `MouseEventHandler.finalizeOrCancelCommittedGesture`
(`Sources/Nehir/Core/Controller/MouseEventHandler.swift:1883`) contains **no**
`requestWorkspaceProjectionRefresh` call. The bar tracks the gesture purely
through the chokepoint publisher.

Net: the discovery's recommended scoped-Option-C block (capture
`selectionRevision` before/after the gesture, refresh on delta) is absent, and
replaced by one centralized emission that covers the gesture path *and* every
future viewport mutation.

## Anchor policy preserved (hard constraint)

Under non-managed focus, the gesture end still does **not** call
`setManagedFocus` or advance `confirmedManagedFocusToken`. The guard at
`Sources/Nehir/Core/Controller/MouseEventHandler.swift:1993`
(`!controller.workspaceManager.isNonManagedFocusActive`) stands unchanged.

The chokepoint emits a `.workspaceProjection` invalidation, **not** a focus
change. It re-projects the bar's `isSelected` (parked-column) highlight without
touching the managed-focus anchor. So `isFocused` (focus dot / scale) stays on
`confirmedManagedFocusToken`; only `isSelected` (column glow) moves with the
viewport. The two concepts remain cleanly separated in the data model and the
view.

## Follow-ups still open (out of scope here)

- **Test invariant inversion (do after user confirmation).** `Tests/NehirTests/RefreshRoutingTests.swift:1132`,
  `focusOnlyChangesRefreshStatusBarWithoutWorkspaceBarQueue`, asserts
  `workspaceBarRefreshDebugState.requestCount == 0` after a focus-only change.
  Option B intentionally inverts this (a focus change now also refreshes the
  workspace bar), so the assertion now sees `requestCount == 1`. Per AGENTS.md,
  tests are not touched until the fix is confirmed in the user's real repro;
  once confirmed, update this assertion to the new expectation and add the
  regression tests in the discovery's "Test coverage gaps" section (gesture end
  under non-managed focus still moves the bar; anchor policy preserved).
- **Merge.** This is uncommitted work on branch
  `refactor-workspace-bar-reactive-viewport-lens`, validated only against the
  build, lint/format, and the directly-affected suites (115/116 pass; the lone
  failure is the Option-B invariant above). It is **not** on `main`.
- **Re-validate the status-bar freeze under the same gesture.** The discovery's
  "Open questions" notes the status bar is likely frozen for the same reason on
  the same gesture (no `.focusProjection` emitted). The chokepoint publisher
  should now also refresh the status bar on viewport change (the flush calls
  `refreshStatusBar()`), but this was not separately traced — worth confirming
  in the same follow-up repro.
