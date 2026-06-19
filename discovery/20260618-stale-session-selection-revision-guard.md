# M6 — Cross-workspace stale focus/session revision guard — Discovery

Source upstream concept: `713280e` ("Clear stale pending managed focus on cross-workspace reassignment") + the WorldStore selection-sequence-mark idea.
Authoritative bug source: [`20260615-omniwm-390-workspace-restore-and-stale-selection.md`](20260615-omniwm-390-workspace-restore-and-stale-selection.md) (Bug 2 = stale session patch overwrites newer selection).
Related: [`20260616-omniwm-317-rapid-focus-revert-race.md`](20260616-omniwm-317-rapid-focus-revert-race.md), [`20260616-omniwm-240-focus-previous-cross-workspace.md`](20260616-omniwm-240-focus-previous-cross-workspace.md).

Scope: determine whether the stale session-patch overwrite and the stale cross-workspace pending-focus apply to nehir, and scope a nehir-shaped fix (do **not** port upstream WorldStore).

---

## TL;DR

- **Two defects apply:**
  1. **Stale session patch overwrites newer selection.** `NiriLayoutHandler.buildRelayoutPlan` writes `viewportState` (including `selectedNodeId`) into a `WorkspaceSessionPatch`, which is applied later in `LayoutRefreshController.executeLayoutPlan` **after an `await`**. If the user changes selection (focus hotkey, click) between plan-build and plan-apply, the stale patch clobbers the newer selection.
  2. **Stale pending managed focus on cross-workspace reassignment.** A `ManagedFocusRequest` issued against workspace A is not cleared when its token is reassigned to workspace B; confirming it pulls focus/selection to the wrong workspace.
- **Current guards:** the stale-patch overwrite is guarded **only** for the gesture path (`viewOffsetPixels.isGesture`, `WorkspaceManager.swift:1670-1677`). There is no selection-revision guard. The cross-workspace clear does not exist.
- **Verdict:** 🔴 Open / Applies. Implement a nehir-sized **selection/session revision counter** rather than upstream WorldStore. This is the larger of the minor items — high callsite-coverage risk — and warrants its own review loop.

## Provenance: is this nehir's code?

Yes. The patch type, the apply path, and the partial guard all exist:

```swift
// Sources/Nehir/Core/Layout/LayoutBoundary.swift:93
struct WorkspaceSessionPatch {
    ...
    var rememberedFocusToken: WindowToken?    // :96
    // (no revision field today)
}
```

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1659
func applySessionPatch(_ patch: WorkspaceSessionPatch) -> Bool {
    ...
    // :1670-1677 — gesture-only guard
    if viewportState.viewOffsetPixels.isGesture {
        ...
        rememberedFocusToken = nil
    }
```

`hiro-390` confirms both bugs reproduce against current nehir `main` and that the gesture-only guard leaves selection unguarded.

## The code in question

### Capture (planning copy, no revision)

`NiriLayoutHandler.buildRelayoutPlan` (snapshot→plan path, body `:336-407`) and `buildOnDemandLayoutPlan` (`:281-331`) copy `snapshot.viewportState` into a local, mutate it, and embed it in a `WorkspaceSessionPatch` (constructed around `computeLayoutPlan` `:445`, `:487`). The plan is built against a snapshot with **no revision stamp**.

### Apply (crosses an await)

`LayoutRefreshController.executeRelayout` crosses `await`/`Task.checkCancellation` between build and apply; `executeLayoutPlan` → `WorkspaceManager.applySessionPatch` (`:1659`). Between build and apply, a user focus hotkey or click can mutate the **live** session selection. The patch then overwrites it.

### The gesture-only guard

`WorkspaceManager.swift:1670-1677` drops the whole `viewportState` (and `rememberedFocusToken`) only when `viewOffsetPixels.isGesture`. Non-gesture patches apply unconditionally — including stale selection.

## Why it applies

The existing generation/revision counters in the codebase do not gate selection: `AppAXContext.LockedWindowGenerationMap`, `WMController.workspaceBarRefreshGeneration`, `WorkspaceManager.persistedWindowRestoreCatalogRevision`. None of them protect `selectedNodeId`/`activeColumnIndex`/`selectionProgress` against a stale async patch. The cross-workspace reassignment path (`WMController.reassignManagedWindow`, `:3630-3645`) does not cancel a pending managed request whose token it just moved.

## Recommendation

**Nehir-shaped revision guard.** Do not port upstream WorldStore.

1. **Add per-workspace selection revision** to session state: `selectionRevision: UInt64` on `WorkspaceSession` (`WorkspaceManager.swift:145-167`); accessors `selectionRevision(for:)` / `bumpSelectionRevision(for:)`.
2. **Bump at every live selection mutation site.** Wrap live-state writes (`selectedNodeId =`, `activeColumnIndex =`, `selectionProgress =`) in a helper `mutateSelection(for:_:)` that does `withNiriViewportState` + `bumpSelectionRevision` atomically. Confirmed live-mutation sites (from `grep "selectedNodeId =" Sources`): `WorkspaceManager.setSelection` (`:3215`) and `commitWorkspaceSelection` (`:1641`); `CommandHandler.navigateInNiri` family (`:441-487`); `MouseEventHandler` (`:1380`, `:1963`); `NiriLayoutHandler` (`:569`, `:580`, `:719`, `:1601`); `WindowActionHandler` (`:411`); `WorkspaceNavigationHandler` (`:521-535`, `:806`, `:940`); `AXEventHandler` (`:2194-2325`).
   - **Critical:** do **not** bump inside `buildRelayoutPlan`'s `var state = snapshot.viewportState` — that is a *planning copy*; bumping there would corrupt the guard (the plan would carry the new revision and always pass). Bump only on **live** `withNiriViewportState` mutations.
3. **Add `plannedSelectionRevision: UInt64? = nil`** to `WorkspaceSessionPatch` (`LayoutBoundary.swift:93`). Optional preserves back-compat for direct `applySessionPatch` callers that do not stamp it (they apply unconditionally, which is correct — their patches are synchronous and fresh).
4. **Stamp at capture:** set `plannedSelectionRevision` in `buildRelayoutPlan`/`computeLayoutPlan` to `selectionRevision(for: wsId)` captured at plan-build time.
5. **Guard at apply** (`WorkspaceManager.applySessionPatch`, `:1659`): after the gesture block, add:
```swift
if let planned = patch.plannedSelectionRevision,
   planned < selectionRevision(for: patch.workspaceId)
{
    let live = niriViewportState(for: patch.workspaceId)
    viewportState.selectedNodeId = live.selectedNodeId
    viewportState.activeColumnIndex = live.activeColumnIndex
    viewportState.selectionProgress = live.selectionProgress
    rememberedFocusToken = nil
}
```
   Narrower than the gesture guard: drop **only** the selection fields and `rememberedFocusToken`; preserve `viewOffsetPixels` to avoid regressing viewport scroll/animation. (Answers hiro-390 OQ-2.)
6. **Clear stale cross-workspace pending focus** (`WMController.reassignManagedWindow`, `:3630-3645`): if `focusBridge.activeManagedRequest?.token == token` and its `workspaceId != workspaceId`, cancel it (`focusBridge.cancelManagedRequest(matching:workspaceId:)` + `discardPendingFocus(token)`). The caller (`WorkspaceNavigationHandler`, `WindowActionHandler.summonWindowRightInNiri`) already reissues focus immediately, so cancel-and-reissue preserves intent.

## Suggested tests

- `WorkspaceManagerTests.staleSelectionRevisionDropsSelectionFields` — set `selectedNodeId = A`, bump revision, apply a patch with `selectedNodeId = B` and `plannedSelectionRevision` one less; assert selection stays `A`, `rememberedFocusToken` not written.
- `WorkspaceManagerTests.freshSelectionRevisionAppliesSelection` / `.nilPlannedSelectionRevisionAppliesSelection` (back-compat) / `.gesturePathStillReplacesEntireViewportState` (regression for the existing gesture guard).
- `LayoutRefreshControllerTests.staleRelayoutPatchDoesNotOverwriteNewerSelection` — drive a relayout, capture the plan, bump the revision (simulate a focus hotkey between build and apply), apply, assert newer selection survives.
- `WMControllerFocusTests.reassignManagedWindowClearsStalePendingFocus` — pending managed focus for token T in ws1; `reassignManagedWindow(T, to: ws2)`; assert `focusBridge.activeManagedRequest` is nil (or rekeyed to ws2).

## Suggested validation

```bash
swift build
swift test --filter WorkspaceManagerTests
swift test --filter LayoutRefreshControllerTests
swift test --filter AXEventHandlerTests
swift test --filter WMControllerFocusTests
```

## Risks

- **Missing a mutation site silently leaves a hole.** Mitigation: route all live writes through `mutateSelection` and grep-audit `selectedNodeId =` at the end.
- **Planning-copy vs live-state confusion** — the single most dangerous footgun. The wrapper helper makes the distinction structural, not convention-based.
- **Cross-workspace clear may regress summon-to-workspace flows** — `reassignManagedWindow` is followed by `commitSummonedWindowFocus`/`focusWindow`; verify the reissue fires so the moved window is not left momentarily unfocused. The `reassignManagedWindowClearsStalePendingFocus` test must cover the summon-then-focus sequence.
- **`applySessionPatch` has many non-relayout callers** (`WindowActionHandler`, `WorkspaceNavigationHandler`, `CommandHandler`, `AXEventHandler`) that pass `plannedSelectionRevision = nil`; they must continue to apply unconditionally. Confirm no caller accidentally stamps a stale revision.

## Open questions

1. Cross-workspace clear: **cancel or rekey** the pending request? Recommendation: cancel + reissue (callers already reissue). Confirm with maintainer.
2. Should `selectionRevision` live inside `ViewportState` (so snapshots naturally carry it) or in per-workspace session state? Recommendation: per-workspace session state — matches the `persistedWindowRestoreCatalogRevision` precedent and keeps `ViewportState` (already animation-coupled) from growing.
3. Relationship to A2/A3: this revision guard is the "real runtime" instance of the same revision-stamping idea A2 introduces in the pure `LayoutPlan`. Independent at the code level; sequence A4 (which enriches `ManagedFocusRequest`) before M6 task 6 if you want the cancel/rekey decision to consider origin.

## Relationship to other clusters

- **A3/A4:** M6 is the runtime-side manifestation of the revision-stamp idea, and benefits from M3's `ManagedFocusOrigin` on the cross-workspace clear decision. Sequence **M3 → M6**.
- **hiro-390 Bug 1** (persisted restore misses windows without `managedReplacementMetadata`) is explicitly **out of scope** for M6 — M6 fixes only Bug 2 + the cross-workspace clear.
