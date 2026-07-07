# OmniWM issue #390 — "OmniWM can lose workspace state (restore miss + stale Niri selection)" — Discovery

Groom 2026-07-07: partially resolved — Bug 2 (stale session patch overwrites newer selection) shipped via M6 (42ac731f); Bug 1 (persisted-restore metadata fallback for metadata-less windows) unverified against current source — re-confirm (verified against main 7a025b78).

Source issue: <https://github.com/BarutSRB/OmniWM/issues/390>
Suggested fix (reference fork): <https://github.com/leojplin/OmniWM/commit/bd7dba61471f2e4a79d134ecdca7c38636fa4f00>
Scope of this doc: determine whether the issue applies to nehir, and whether
the suggested fix is safe to port.

**Verdict:** **Relevant.** Every symbol named in the bug report exists verbatim in
nehir, and both bugs reproduce against the current `main`.

---

## TL;DR

| Bug | In Nehir? | Root-cause location | Status |
| --- | --- | --- | --- |
| **1. Persisted restore misses windows without `managedReplacementMetadata`** | Yes | `WorkspaceManager.persistedWindowRestoreCatalogBuildSnapshot()` (snapshot filter) **and** `plannedPersistedHydrationMutation()` (guard on `metadata`) | **Unfixed.** No fallback when metadata is absent. |
| **2. Stale session patch overwrites newer selection** | Yes | `NiriLayoutHandler.buildRelayoutPlan()` writes `viewportState` into `WorkspaceSessionPatch`; applied later in `LayoutRefreshController.executeLayoutPlan()` after `await` | **Partially fixed.** Guarded **only** for the gesture path (`viewOffsetPixels.isGesture`). No revision guard for selection. |

The reference fix (commit `bd7dba6`) proposes two changes, neither of which exists in Nehir:

1. Synthesize persisted-restore metadata from the current window entry (bundle id + workspace id +
   mode + known frame) when `managedReplacementMetadata` is missing.
2. Add a **selection revision counter** that `WorkspaceSessionPatch` carries; drop older patches
   when a newer selection exists.

---

## Provenance: is this nehir's code?

The issue references these nehir symbols, all confirmed present:

| Issue term | Nehir symbol | Definition site |
| --- | --- | --- |
| `managedReplacementMetadata` | `ManagedReplacementMetadata` | `Sources/Nehir/Core/Workspace/WindowModel.swift` |
| `ViewportState` | `struct ViewportState` | `Sources/Nehir/Core/Layout/Niri/ViewportState.swift` |
| `selectedNodeId` | `ViewportState.selectedNodeId` | `Sources/Nehir/Core/Layout/Niri/ViewportState.swift` |
| Niri session patch | `WorkspaceSessionPatch` | `Sources/Nehir/Core/Layout/LayoutBoundary.swift` |
| persisted restore catalog | `PersistedWindowRestoreCatalog` + builder | `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` |
| hydration planning | `RestorePlanner.planPersistedHydration` | `Sources/Nehir/Core/Reconcile/RestorePlanner.swift` |

There is no divergence that would insulate nehir from these bugs.

---

## Bug 1 — Persisted workspace restore misses current app windows

### What the issue claims

The restore catalog and boot hydration depend on `managedReplacementMetadata`. Some normal,
currently-existing app windows never acquire that metadata. When that happens, the window is
either (a) never written to the persisted restore catalog, and/or (b) skipped during boot
hydration — so on restart it lands in whatever workspace it is discovered in, not the workspace
it was previously assigned to.

### Confirmation in Nehir — two independent gates, both key on `metadata`

**Gate A — catalog build (write path).** `WorkspaceManager.persistedWindowRestoreCatalogBuildSnapshot()`
constructs the snapshot that feeds `PersistedWindowRestoreCatalogBuilder.build`. Any entry without
`managedReplacementMetadata` is **skipped entirely** and therefore never persisted:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift
private func persistedWindowRestoreCatalogBuildSnapshot() -> PersistedWindowRestoreCatalogBuildSnapshot {
    let context = monitorResolutionContext()
    let topologyProfile = context.topologyProfile
    var snapshotEntries: [PersistedWindowRestoreCatalogBuildEntry] = []

    for entry in windows.allEntries() {
        guard let metadata = entry.managedReplacementMetadata,   // ← GATE A: skipped if nil
              let restoreIntent = entry.restoreIntent,
              let workspaceName = descriptor(for: entry.workspaceId)?.name
        else {
            continue
        }
        ...
        snapshotEntries.append(
            PersistedWindowRestoreCatalogBuildEntry(
                token: entry.token,
                metadata: metadata,
                ...
            )
        )
    }
    return PersistedWindowRestoreCatalogBuildSnapshot(entries: snapshotEntries)
}
```

`PersistedWindowRestoreCatalogBuildEntry.metadata` is non-optional, and
`PersistedWindowRestoreKey(metadata:)` returns nil when metadata is nil, so the builder's own
`guard let key = PersistedWindowRestoreKey(metadata:) else { continue }` is a second, redundant
gate that also drops the entry.

**Gate B — boot hydration (restore path).** `WorkspaceManager.plannedPersistedHydrationMutation`
returns `nil` for any token lacking metadata, so no hydration plan is ever produced for it:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:745
private func plannedPersistedHydrationMutation(for token: WindowToken) -> PersistedHydrationMutation? {
    guard let metadata = windows.managedReplacementMetadata(for: token),   // ← GATE B
          let hydrationPlan = restorePlanner.planPersistedHydration(
              .init(token: token, metadata: metadata, ...)                  // metadata is non-optional in the input
          )
    else {
        return nil
    }
    ...
}
```

This is called from the window-admission reconcile path (`WorkspaceManager.swift:484`):

```swift
let persistedHydration = event.token.flatMap { plannedPersistedHydrationMutation(for: $0) }
```

A nil `persistedHydration` means `mergePersistedHydration` is never invoked, so the window keeps
whatever `workspaceId` it was first observed with.

### Why a window can lack `managedReplacementMetadata`

Under normal operation `LayoutRefreshController` synthesizes metadata from AX facts with
fallbacks (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1314`, `WMController.swift:3009`).
But metadata is populated **after** a layout refresh, not at the moment a window is admitted. The
admission path (which calls `plannedPersistedHydrationMutation`) runs **before** the first
refresh completes, so at boot a freshly-discovered window can momentarily have `nil` metadata and
be silently dropped from both the persisted catalog (Gate A, if a catalog save fires in that
window) and from hydration (Gate B). The issue's repro ("let the app windows be discovered again
without `managedReplacementMetadata`") is exactly this race.

### `ManagedReplacementMetadata` fields (for the fallback)

```swift
// Sources/Nehir/Core/Workspace/WindowModel.swift
struct ManagedReplacementMetadata: Equatable, Sendable {
    var bundleId: String?
    var workspaceId: WorkspaceDescriptor.ID
    var mode: TrackedWindowMode
    var role: String?
    var subrole: String?
    var title: String?
    var windowLevel: Int32?
    var parentWindowId: UInt32?
    var frame: CGRect?
    var transientWindowServerEvidence = false
    var degradedWindowServerChildEvidence = false
    ...
}
```

Every one of these (except the two booleans) is derivable from the window entry itself at
admission time — `bundleId`/`mode` from observed state, `frame` from the observed window frame,
`workspaceId` from the entry. That is precisely what the reference fix's "fall back to the
running app bundle identifier, workspace id, mode, and known frame" relies on.

---

## Bug 2 — Stale Niri session patch overwrites newer selection

### What the issue claims

Layout plans are built asynchronously. A plan may capture an older `ViewportState` snapshot. If
the user changes the selected window before that old patch applies, the stale patch overwrites
the newer `selectedNodeId`, `activeColumnIndex`, or `selectionProgress`.

### Confirmation in Nehir — the async gap is real

**Capture point.** `NiriLayoutHandler.buildRelayoutPlan` copies the snapshot's viewport state
into a local, runs the layout pass on it, then embeds it in the session patch:

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift (buildRelayoutPlan)
var state = snapshot.viewportState            // ← snapshot captured earlier
...
let currentSelection = state.selectedNodeId
...
return WorkspaceLayoutPlan(
    workspaceId: pass.wsId,
    monitor: snapshot.monitor,
    sessionPatch: WorkspaceSessionPatch(
        workspaceId: pass.wsId,
        viewportState: state,                  // ← carries selectedNodeId, activeColumnIndex, selectionProgress
        rememberedFocusToken: rememberedFocusToken
    ),
    diff: diff,
    animationDirectives: directives
)
```

`ViewportState` (definition) confirms what the patch carries:

```swift
// Sources/Nehir/Core/Layout/Niri/ViewportState.swift
struct ViewportState {
    var activeColumnIndex: Int = 0
    var viewOffsetPixels: ViewOffset = .static(0.0)
    var selectionProgress: CGFloat = 0.0
    var selectedNodeId: NodeId?
    ...
}
```

**Async apply point.** `LayoutRefreshController.executeRelayout` builds the plan, crosses
`await`/`Task.checkCancellation` boundaries, and only then applies it:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift (executeRelayout)
do {
    var plan = try await buildRelayoutExecutionPlan(...)   // ← snapshot + plan built here
    applyRefreshMetadata(refresh, to: &plan)
    try Task.checkCancellation()                            // ← GAP: user can change selection now
    await executeRefreshExecutionPlan(plan)                 // ← patch applied here
} catch { return false }
```

`executeRefreshExecutionPlan` → `executeLayoutPlans` → `executeLayoutPlan`:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift
func executeLayoutPlan(_ plan: WorkspaceLayoutPlan) {
    applySessionPatch(plan.sessionPatch)     // ← stale viewportState reaches WorkspaceManager here
    diffExecutor.execute(plan)
    applyAnimationDirectives(plan.animationDirectives)
}
```

And `WorkspaceManager.applySessionPatch` unconditionally writes the stale `viewportState`
(overwriting `selectedNodeId` / `activeColumnIndex` / `selectionProgress`):

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1649
func applySessionPatch(_ patch: WorkspaceSessionPatch) -> Bool {
    var changed = false
    var rememberedFocusToken = patch.rememberedFocusToken

    if var viewportState = patch.viewportState {
        ...
        updateNiriViewportState(viewportState, for: patch.workspaceId)   // ← overwrites newer selection
        changed = true
    }
    ...
}
```

### Existing mitigation — gesture path only

`applySessionPatch` already contains a **partial** guard, but it is scoped exclusively to the
trackpad-gesture case, and the comment on it explicitly names the `selectedNodeId` hazard that
Bug 2 describes:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1654
// Gesture viewport changes are owned by MouseEventHandler and are applied to the
// workspace state before a relayout is requested. A relayout plan may be built from
// one of those gesture snapshots and arrive later, after more gesture updates or after
// endGesture() has already selected a snap target. Feeding that stale snapshot back
// into session state can regress the offset/active column and, more subtly, restore a
// stale selectedNodeId whose rememberedFocusToken pulls the viewport back later.
if viewportState.viewOffsetPixels.isGesture {
    viewportState = niriViewportState(for: patch.workspaceId)
    rememberedFocusToken = nil
}
```

So the team **already understands** this class of bug, but mitigated only the gesture
(`viewOffsetPixels.isGesture`) branch. The non-gesture path — e.g. the user pressing a focus
hotkey or clicking another window between snapshot capture and patch application — is **not**
guarded, and a stale `selectedNodeId` from an in-flight patch will overwrite the newer selection.

### What Nehir is missing

There is **no** selection-revision / generation counter tied to `selectedNodeId`. Nehir does
maintain generation/revision counters, but none of them gate selection:

- `AppAXContext.LockedWindowGenerationMap` — frame-write generations (`Sources/Nehir/Core/Ax/AppAXContext.swift`)
- `WMController.workspaceBarRefreshGeneration` / `pendingWorkspaceBarRefreshGeneration` —
  workspace-bar refresh coalescing (`Sources/Nehir/Core/Controller/WMController.swift`)
- `WMController.statusBarRefreshGeneration` — status-bar refresh coalescing
- `WorkspaceManager.persistedWindowRestoreCatalogRevision` — persisted-catalog build freshness

The reference fix's "Niri selection revision counter" that `WorkspaceSessionPatch` declares and
that `applySessionPatch` checks against a newer current selection has no analogue here.

---

## Reproduction recipes (Nehir)

**Bug 1 — restore miss.**
1. Configure two workspaces (e.g. `1`, `2`).
2. Launch an app and open **two** windows of it.
3. Move one window to workspace `1`, the other to workspace `2`.
4. Quit and relaunch Nehir so persisted restore state is rebuilt/hydrated at boot.
5. Ensure the windows are re-discovered before a layout refresh has populated
   `managedReplacementMetadata` for them (e.g. fast relaunch, or an app whose AX facts are slow
   to arrive).
6. **Expected:** each window restores to its previous workspace.
   **Actual:** one or both windows remain in the workspace they were discovered in.

**Bug 2 — stale selection.**
1. Use Niri column layout with ≥ 2 windows in a workspace.
2. Trigger a relayout (resize, add/remove a window, monitor change) that captures the current
   `selectedNodeId` into a `WorkspaceSessionPatch`.
3. Before `executeRefreshExecutionPlan` applies that patch, select a different window (focus
   hotkey / click).
4. Let the in-flight patch apply.
5. **Expected:** the newly selected window stays selected.
   **Actual:** selection snaps back to the window that was selected at snapshot time.

---

## Suggested fix surface (porting the reference commit)

The changes map onto Nehir as follows. **No implementation is done in this discovery pass** —
this is the proposed surface for review.

**For Bug 1** — synthesize metadata at both gates so a window without
`managedReplacementMetadata` is still persistable and hydratable.

- In `persistedWindowRestoreCatalogBuildSnapshot()`: when `entry.managedReplacementMetadata` is
  nil, build a fallback `ManagedReplacementMetadata` from the entry itself —
  `bundleId` from observed bundle id, `workspaceId` from `entry.workspaceId`, `mode` from the
  entry's disposition, `frame` from the observed frame — instead of `continue`-ing.
- In `plannedPersistedHydrationMutation(for:)`: use the same fallback so the hydration guard
  does not return nil. Because `PersistedHydrationInput.metadata` is non-optional, the fallback
  must be constructed before calling `planPersistedHydration`, not inside it.
- `RestorePlanner.persistedHydrationMatches` already tolerates metadata-only matches
  (`entry.key.matches(metadata)` fallback branch), so no planner change should be required
  beyond feeding it non-nil metadata.

**For Bug 2** — add a selection revision counter and drop stale patches.

- Add a per-workspace monotonic counter (e.g. `selectionRevision` in session state).
- Bump it wherever selection is mutated directly — `CommandHandler`,
  `MouseEventHandler`, `WindowActionHandler`, `WorkspaceNavigationHandler`, and the
  `selectedNodeId =` assignment sites in `NiriLayoutHandler`.
- Add `selectionRevision: UInt64?` (or similar) to `WorkspaceSessionPatch` in
  `Sources/Nehir/Core/Layout/LayoutBoundary.swift`, stamped at snapshot capture in
  `buildRelayoutPlan`.
- In `WorkspaceManager.applySessionPatch`, when a patch carries a `viewportState` and its
  revision is older than the current `selectionRevision`, drop the
  `selectedNodeId` / `activeColumnIndex` / `selectionProgress` fields (or drop the whole
  viewport state) instead of writing them. Mirror the existing `isGesture` guard's shape.

---

## Test coverage today

Relevant suites exist but **neither regression is covered**:

- `Tests/NehirTests/RestorePlannerTests.swift` — exercises `planPersistedHydration`, but only with
  non-nil `metadata`; no case for an entry lacking `managedReplacementMetadata`.
- `Tests/NehirTests/WorkspaceManagerTests.swift` — covers catalog build/consume plumbing; no case
  asserting a metadata-less window is still persisted/hydrated.
- `Tests/NehirTests/LayoutRefreshControllerTests.swift` / `MouseEventHandlerTests.swift` — cover
  the gesture stale-snapshot mitigation; no test for a non-gesture stale patch racing a newer
  selection.
- `Tests/NehirTests/NiriLayoutEngineTests.swift:1832` sets a `staleSelection`, but that asserts
  `validateSelection` retention — not the stale-`WorkspaceSessionPatch` race.

Two regression tests should accompany the fix:

1. **Restore hydration without metadata** — a window entry with `nil`
   `managedReplacementMetadata` is persisted and later hydrated to its prior workspace.
2. **Stale selection patch dropped** — a `WorkspaceSessionPatch` carrying an older
   `selectedNodeId` is dropped (or its selection fields ignored) when a newer selection exists.

---

## Open questions for the maintainer

1. Is `managedReplacementMetadata` *intended* to be eventually populated for every tracked window?
   If yes, Bug 1's fix could alternatively be "ensure metadata is populated at admission" rather
   than "tolerate its absence" — but the reference commit chooses tolerance, which is more robust
   against the admission-before-refresh race.
2. Should the selection revision guard preserve `viewOffsetPixels` while dropping only
   `selectedNodeId`/`activeColumnIndex`/`selectionProgress`, or drop the whole `viewportState`?
   The gesture guard replaces the entire state; a narrower fix may be less disruptive but needs a
   decision on what "selection revision" protects.
3. Should the revision counter live in `ViewportState` itself (so snapshots naturally carry it) or
   in session state looked up per-workspace in `applySessionPatch`? The latter matches the
   `persistedWindowRestoreCatalogRevision` precedent.
