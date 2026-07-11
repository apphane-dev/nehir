# BarutSRB/OmniWM#240 — "Focus previous window command doesn't work across workspaces" — Discovery

Groom 2026-07-07: resolved — Focus Previous now crosses workspaces and monitors (30faf8f3, "Focus Previous Window crosses workspaces and monitors").

Source issue: https://github.com/BarutSRB/OmniWM/issues/240
Scope of this doc: determine whether nehir's "Focus Previous Window" command
reaches the last-focused window when it lives on a *different* workspace, or —
like upstream OmniWM — silently falls back to a window in the current workspace.

All file/line references were verified against the Nehir source tree
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace").
**Re-verify before implementing; line numbers drift.** Verdict is by code
inspection (no runtime trace). Upstream quotes were fetched live from the GitHub
issue page.

---

## TL;DR

- **nehir reproduces the bug: "Focus Previous Window" is hardcoded to search only
  the *current* workspace (`limitToWorkspace: true`), so it can never switch back
  to the last-focused window when that window is on another workspace — exactly the
  behavior reported upstream.** The engine already contains the cross-workspace
  search machinery, but it is unused, and the caller then re-activates the result
  in the *current* workspace id, so flipping the flag alone is not a complete fix.
- **Verdict:** 🔴 **Open / Applies** — latent nehir bug, not fixed, owns a new
  action distinct from sibling BarutSRB/OmniWM#317 (which is a focus *revert race*, a different
  root cause).

## Provenance: is this nehir's code?

Yes. The command path is entirely nehir-local niri-style layout code:

- Hotkey `focus previous` → `HotkeyCommand.focusPrevious`
  (`Sources/Nehir/Core/Config/HotkeyConfigMapping.swift:44`).
- Dispatch → `CommandHandler.focusPreviousInNiri()`
  (`Sources/Nehir/Core/Controller/CommandHandler.swift:51-52` → `:237`).
- Selection logic → `NiriLayoutEngine.focusPrevious(...)`
  (`Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:626`).
- MRU lookup → `findMostRecentlyFocusedWindow(...)`
  (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:703`).

The action's display name is **"Focus Previous Window"** with search keywords
`["last focused", "recent window"]` and a default **Option-Tab** binding
(`Sources/Nehir/Core/Input/ActionCatalog.swift:213-217`, display name at `:863`).
Those keywords are decisive: the feature is *intended* as a global
most-recently-used window switcher (Alt-Tab-like), not a per-workspace column
navigation — which is precisely the expectation the upstream reporter had.

## The code in question

The single entry point (`CommandHandler.swift`):

```swift
// Sources/Nehir/Core/Controller/CommandHandler.swift:237
private func focusPreviousInNiri() {
    guard let controller else { return }
    controller.niriLayoutHandler.withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps in
        if let currentId = state.selectedNodeId { engine.updateFocusTimestamp(for: currentId) }
        if let currentId = state.selectedNodeId { engine.activateWindow(currentId) }

        // Sources/Nehir/Core/Controller/CommandHandler.swift:248-256
        guard let previousWindow = engine.focusPrevious(
            currentNodeId: state.selectedNodeId,
            in: wsId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            limitToWorkspace: true          // ← confines search to the current workspace
        ) else { return }

        // Sources/Nehir/Core/Controller/CommandHandler.swift:260-261
        controller.niriLayoutHandler.activateNode(
            previousWindow, in: wsId, state: &state,          // ← wsId is STILL the current workspace
            options: .init(ensureVisible: false, updateTimestamp: false, startAnimation: false)
        )
        ...
    }
}
```

The engine helper that does the search (`NiriNavigation.swift`):

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:626-641
func focusPrevious(currentNodeId: NodeId?, in workspaceId: WorkspaceDescriptor.ID,
                   motion: MotionSnapshot, state: inout ViewportState,
                   workingFrame: CGRect, gaps: CGFloat,
                   limitToWorkspace: Bool = true) -> NiriWindow? {
    let searchWorkspaceId = limitToWorkspace ? workspaceId : nil   // :635
    guard let previousWindow = findMostRecentlyFocusedWindow(
        excluding: currentNodeId, in: searchWorkspaceId            // :636-639
    ) else { return nil }
    ...
}
```

And the MRU lookup itself (`NiriLayoutEngine+Windows.swift`), which *does* know
how to span workspaces — but only when handed `workspaceId == nil`:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:703-717
func findMostRecentlyFocusedWindow(excluding excludingNodeId: NodeId?,
                                   in workspaceId: WorkspaceDescriptor.ID? = nil) -> NiriWindow? {
    let allWindows: [NiriWindow] = if let wsId = workspaceId, let root = root(for: wsId) {
        root.allWindows                              // ← current-workspace-only branch (used today)
    } else {
        Array(roots.values.flatMap(\.allWindows))    // ← cross-workspace branch EXISTS but is dead
    }
    let candidates = allWindows.filter { window in
        window.id != excludingNodeId && window.lastFocusedTime != nil
    }
    return candidates.max { ($0.lastFocusedTime ?? .distantPast) < ($1.lastFocusedTime ?? .distantPast) }
}
```

Timestamps are stamped for every focused window regardless of workspace
(`updateFocusTimestamp(for:)` at `NiriLayoutEngine+Windows.swift:693-701`), so the
MRU data for a window on a *different* workspace is recorded and retained — the
information needed for cross-workspace focus-previous exists; only the search is
artificially walled off.

## Why it applies

Upstream BarutSRB/OmniWM#240 (reporter @yougotwill): *"If I'm on `Workspace 1` and focus an
application on `Workspace 2` and then use the 'Focus previous window' command it
doesn't go back to the first application, instead it focuses another window in
`Workspace 2`."* The issue was closed as `not_planned` by the maintainer purely as
a v0.4.8+ triage cleanup ("closing … because the last conversation here predates
the v0.4.8 release"), **not** because it was fixed — there is no linked PR or
stated fix.

Tracing nehir step by step reproduces the identical behavior:

1. User is on WS 1 focusing window **A**, then switches to WS 2 and focuses
   window **B**. At this point `A.lastFocusedTime` (older) and `B.lastFocusedTime`
   (newer) are both set in the engine.
2. User presses Option-Tab ("Focus Previous Window") while still on WS 2.
3. `focusPreviousInNiri` runs inside `withNiriWorkspaceContext`, so `wsId == WS 2`,
   and calls `engine.focusPrevious(..., limitToWorkspace: true)`
   (`CommandHandler.swift:255`).
4. `focusPrevious` sets `searchWorkspaceId = WS 2` (`NiriNavigation.swift:635`)
   and calls `findMostRecentlyFocusedWindow(excluding: B, in: WS 2)`.
5. Because `workspaceId` is non-nil, the lookup uses `root(for: WS 2).allWindows`
   only (`NiriLayoutEngine+Windows.swift:707-708`) — window **A** on WS 1 is never
   a candidate.
6. The MRU max therefore selects the most-recently-focused window in WS 2 *other
   than* **B** (or returns `nil` if WS 2 has no other eligible window). It then
   re-activates that window **in `wsId == WS 2`** (`CommandHandler.swift:260-261`).
7. Net effect: focus moves to another window in the current workspace, never to
   **A** on WS 1 — exactly "focuses another window in Workspace 2."

So the bug reproduces by inspection. There is no guard anywhere in this path that
would switch the active workspace to the target window's workspace; even the
dead cross-workspace branch of `findMostRecentlyFocusedWindow` would, on its own,
only *return* the node — `activateNode(previousWindow, in: wsId, …)` is still
called with the *current* workspace id, so activating a node that lives in another
workspace would be incoherent. A real fix must both widen the search and perform a
workspace switch.

This is **not** owned by the sibling discovery `20260616-omniwm-317-…`. That doc
concerns rapid focus-next/prev *reverting to an intermediate window* due to a
stale macOS AX echo — a timing/race root cause. BarutSRB/OmniWM#240 is a static, structural
workspace-scoping limitation: the two share no code cause and no fix.

## Recommendation

Port the *intent* (not a specific upstream diff, since none exists). Implement
cross-workspace "Focus Previous Window":

1. Widen the search: have `focusPreviousInNiri` pass `limitToWorkspace: false`
   (or introduce a dedicated cross-workspace entry point), so
   `findMostRecentlyFocusedWindow`'s `roots.values.flatMap(\.allWindows)` branch
   is reached and the true global MRU window is selected.
2. Switch workspaces to the winner: when the selected `previousWindow`'s workspace
   differs from the current `wsId`, drive a workspace switch (the
   `WorkspaceNavigationHandler` / `rememberedTiledFocusToken` restore path at
   `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:230` is the
   existing pattern for activating a remembered window after a workspace change)
   *instead of* calling `activateNode(previousWindow, in: wsId, …)` with the wrong
   workspace id. Confirm the target node's workspace id is reachable from the
   engine root that owns it.
3. Decide policy for *same-monitor* vs *cross-monitor*: niri's `focus-previous`
   is workspace-local by design, so a global MRU is a nehir-specific enhancement.
   Confirm with the maintainer that global MRU is the desired semantics (the
   `"last focused"` / `"recent window"` keywords at `ActionCatalog.swift:217`
   argue yes) before committing.

Do **not** treat the closed `not_planned` status as "resolved": it was a triage
cleanup, and the reporter's described behavior is reproduced verbatim in nehir.

## Suggested tests

- **Cross-workspace MRU returns to the origin window.** Seed two workspaces; focus
  window A on WS 1, switch to WS 2 and focus window B, then invoke
  `focusPreviousInNiri()`. Assert the active workspace returns to WS 1 and the
  focused node is A (not a window in WS 2).
- **Same-workspace MRU unchanged.** With A and B both on the current workspace,
  focus B then Option-Tab; assert focus moves to A (guards the existing
  per-workspace behavior is preserved when the previous window is local).
- **Single-window target workspace.** Focus A on WS 1, switch to WS 2 whose only
  window is B, then Option-Tab; assert focus returns to A on WS 1 (the upstream
  "does nothing / stays in WS 2" case must now succeed).
- **Target on another monitor (policy test).** If global MRU is scoped to the
  current monitor by policy, assert Option-Tab never switches monitors; if
  global, assert it can. Pin whichever behavior is decided in step 3 above.
