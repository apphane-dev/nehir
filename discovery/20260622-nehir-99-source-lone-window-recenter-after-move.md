# Nehir issue #99 — Center window doesn't work reliable when changing windows in workspace — Discovery

**Status:** discovery
**Source issue:** https://github.com/apphane-dev/nehir/issues/99 (OPEN, label `bug`)
**Reporter env:** nehir 0.6.0-rc.9, macOS 26.5.1

Verified against the main Nehir source tree at `4ae5fc96` on 2026-06-22.
`git log -1 --format='%ci %s'` returned `2026-06-22 05:27:00 +0300 Exempt managed windows on inactive native Spaces from full-rescan eviction`.
Line numbers below were checked against that source tree; they will drift.

## TL;DR

- This is the reverse half of the 2026-06-19 lone-window work: the transient lone-window override exists, but the **source-side 2→1 transition** after a move/close does not re-enter the lone-window seed path.
- `moveWindowToWorkspace` / `moveColumnToWorkspace` already clear the **target** workspace's transient override when it becomes multi-column, but the **source** side only cleans up empty columns and selection. It never re-seeds the surviving lone window.
- The controller already routes `workspaceTransition` to an immediate relayout and passes the affected workspace set through the planner, so this is not a missing refresh request; it is a missing source-side state repair.
- Closing a window has the same hole: if one window remains, the close path does not explicitly restore the lone-window viewport/override state.
- Fix scope: after any move/close that leaves exactly one normal tiled window, explicitly re-run the lone-window seed path for that workspace instead of relying on a later incidental relayout.

## Code in question

### The current model already splits canonical width from lone-window viewport state

`NiriContainer` already carries the transient override and the effective-width helper:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:600-605
var effectiveViewportWidth: CGFloat {
    loneWindowLayoutWidthOverride ?? cachedWidth
}

func clearLoneWindowLayoutWidthOverride() {
    loneWindowLayoutWidthOverride = nil
}
```

That split is the key prior-art context from the 2026-06-19 fix.

### The lone-window seed path exists, but only on the admission path

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:733-749
        if snapshot.hasCompletedInitialRefresh,
           let newToken = newTokens.last,
           let newNode = pass.engine.findNode(for: newToken),
           snapshot.isActiveWorkspace
        {
            state.selectedNodeId = newNode.id

            if wasEmpty {
                if pass.engine.singleWindowLayoutContext(in: pass.wsId) != nil {
                    let geometry = pass.engine.prepareSingleWindowViewport(
                        in: pass.wsId,
                        workingFrame: pass.insetFrame,
                        containingFrame: pass.monitor.frame,
                        scale: pass.engine.displayScale(in: pass.wsId),
                        gaps: pass.gap
                    )
                    resetViewportForCenteredLoneWindow(geometry: geometry, state: &state)
                } else {
```

This is the only obvious place where a workspace gets its lone-window centering freshly seeded during window admission.

### The lone-window layout helper writes the transient override

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:817-836
    func prepareSingleWindowViewport(
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        containingFrame: CGRect? = nil,
        scale: CGFloat = 2.0,
        gaps: CGFloat
    ) -> SingleWindowViewportGeometry? {
        guard let context = singleWindowLayoutContext(in: workspaceId) else { return nil }
        let geometry = singleWindowViewportGeometry(
            for: context,
            in: workingFrame,
            containingFrame: containingFrame,
            scale: scale,
            gaps: gaps
        )
        if context.container.hasManualSingleWindowWidthOverride {
            context.container.clearLoneWindowLayoutWidthOverride()
        } else {
            context.container.loneWindowLayoutWidthOverride = geometry.rect.width
        }
        return geometry
    }
```

This is the code the source-side move/close path would need to re-enter for the surviving lone window.

### Workspace moves clear the target, then only clean up the source

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:40-60
        let targetColumn: NiriContainer
        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: targetRoot) {
            initializeNewColumnWidth(existingColumn, in: targetWorkspaceId)
            targetColumn = existingColumn
        } else {
            let newColumn = NiriContainer()
            initializeNewColumnWidth(newColumn, in: targetWorkspaceId)
            targetRoot.appendChild(newColumn)
            targetColumn = newColumn
        }
        targetColumn.appendChild(window)
        if targetRoot.allWindows.count != 1 {
            for column in targetRoot.columns where !column.hasManualSingleWindowWidthOverride {
                column.clearLoneWindowLayoutWidthOverride()
            }
        }

        cleanupEmptyColumn(sourceColumn, in: sourceWorkspaceId, state: &sourceState)

        sourceState.selectedNodeId = fallbackSelection
```

That is the asymmetry: target-side override cleanup exists; source-side lone-window reseed does not.

### Window close/removal has the same omission when one window remains

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:176-198
    func removeWindow(token: WindowToken) {
        guard let node = tokenToNode[token] else { return }
        closingTokens.remove(token)

        guard let column = node.parent as? NiriContainer else { return }

        column.adjustActiveTileIdxForRemoval(of: node)

        node.remove()
        tokenToNode.removeValue(forKey: token)

        if column.displayMode == .tabbed, !column.children.isEmpty {
            column.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: column)
        }

        if column.children.isEmpty {
            let root = column.parent as? NiriRoot
            column.remove()

            if let root {
                for col in root.columns {
                    col.cachedWidth = 0
                }
            }
        }
    }
```

If a close leaves one window behind, nothing here re-seeds the lone-window viewport state.

### The relayout planner already carries affected workspaces through

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1081-1094
        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let layoutWorkspaceIds = affectedWorkspaceIds.isEmpty ? activeWorkspaceIds : affectedWorkspaceIds
        let niriWorkspaces = layoutWorkspaceIds
        var workspacePlans: [WorkspaceLayoutPlan] = []
        workspacePlans.reserveCapacity(niriWorkspaces.count)

        var updateTabbedOverlays = false

        if !niriWorkspaces.isEmpty {
            try Task.checkCancellation()
            let plans = try await niriHandler.layoutWithNiriEngine(
                activeWorkspaces: niriWorkspaces,
                useScrollAnimationPath: useScrollAnimationPath
            )
```

So the bug is not "no relayout request"; it is that the source-side move/close path never makes the surviving lone workspace deterministic by itself.

## Root cause / analysis

By inspection, the lone-window behavior is split into two parts:

1. **Canonical column state** (`cachedWidth`) used by normal multi-column layout.
2. **Transient lone-window state** (`loneWindowLayoutWidthOverride` + viewport center seeding) used only while a workspace has exactly one normal tiled window.

The admission path knows how to seed that state for a freshly-empty workspace: when the first window arrives and the workspace is active, it calls `prepareSingleWindowViewport(...)` and `resetViewportForCenteredLoneWindow(...)`.

The reverse transition is missing. When `moveWindowToWorkspace` or `moveColumnToWorkspace` removes the last-but-one window from the source workspace, the engine does **not** call the lone-window seed helper for the survivor. It only clears the empty column and updates selection. That means the remaining window keeps depending on a later incidental layout/viewport pass to recenter itself.

That dependency is what makes the report flaky: sometimes a later interaction happens to revisit the workspace and restore the lone-window state; sometimes it does not. The reporter's "move the survivor to ws7 and back to ws6" workaround forces a fresh arrival path that re-seeds the lone-window state, so it recovers reliably.

The close path has the same shape: if one window remains, nothing here re-runs the lone-window seed. So `move*Workspace` and `removeWindow`/`removeWindows` need the same source-side helper.

## Suggested validation / tests

- `moveWindowToWorkspace` regression: start with 2 tiled windows on a workspace under `.centered(0.6)`, move one away, and assert the remaining source window gets lone-window state again (`loneWindowLayoutWidthOverride` set and centered viewport restored).
- `moveColumnToWorkspace` regression: same assertion, but move a column instead of a window.
- `removeWindow` regression: closing one of two windows leaves the survivor centered, not stuck in the old scroll position.
- Keep the target-side behavior covered separately: target override cleanup should still happen when a workspace leaves the single-window state.

## Sibling / related discoveries

- `completed/20260619-workspace-assignment-lone-window-width-cache-leak.md`
- `completed/20260619-workspace-assignment-lone-window-width-and-reveal.md`

Issue #99 is the reverse transition of that machinery. Reuse the split-state model; do not solve it by mutating canonical width back and forth.
