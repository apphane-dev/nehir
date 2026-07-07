# OmniWM PR #388 — "Admit focused untracked standard windows before non-managed fallback (activation race)" — Discovery

Source PR: <https://github.com/BarutSRB/OmniWM/pull/388> (fixes OmniWM issue #387)
Scope of this doc: determine whether the *concept* this PR introduces
(admitting a transiently-untracked but genuinely-focused standard window before
falling back to the non-managed focus path) exists in nehir, and whether adapting
it is warranted.

All file/line references were verified against the Nehir source tree
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace").
Re-verify before implementing; line numbers drift.

---

> **Filed under `discovery/noop/`** — nehir already implements this exact
> concept, adapted and **substantially more complete** than the PR, in
> `admitFocusedWindowBeforeNonManagedFallback`. The PR was **closed without
> merge** upstream, so this is not a port of an accepted fix; nehir arrived at
> the same mechanism independently (and first) and has since extended it across
> five focused-admission tests plus sibling discoveries
> (`20260616-omniwm-379-focus-revert-grace-period.md`,
> `20260616-omniwm-317-rapid-focus-revert-race.md`). Applying the PR's diff would
> **regress** nehir — it omits the disposition handling, retry scheduling, and
> create-placement-context synthesis nehir relies on. No new repo action is
> owned here.

## TL;DR

- **nehir already admits a focused untracked standard window before the non-managed fallback, and the PR's own test name is verbatim in nehir.** The PR's `admitFocusedUntrackedWindowIfNeeded` ↔ nehir's `admitFocusedWindowBeforeNonManagedFallback` (`AXEventHandler.swift:1751`), wired into `handleAppActivation` at `AXEventHandler.swift:1682` — **ahead of** the non-managed fallback at `AXEventHandler.swift:1734`. nehir even ships the PR's test under the identical name `focusedUntrackedStandardWindowIsAdmittedBeforeNonManagedFallback` (`AXEventHandlerTests.swift:9829`).
- **Verdict:** 🟢 **Fixed.** The activation race the PR targets is already closed in nehir at a stricter, earlier layer; the PR is a strict subset and must not be ported verbatim.

## PR context (merge state + what the diff does)

- **State:** closed without merge (per triage / task spec). Upstream never took it.
- **Symptom (from PR body / fixes #387):** when OmniWM/OmniWM receives an app
  activation event *before* the window has been tracked (i.e. the AX
  `focusedWindowChanged`/`workspaceDidActivateApplication` arrives before the
  CGS `.created` event), the focus path falls through to the non-managed
  fallback. A transiently-untracked but genuinely-focused standard window is
  skipped and a wrong window gets activated.

- **The diff** (`AXEventHandler.swift`): inserts a new branch in
  `handleAppActivation`, immediately before the `keyboardFocusTarget(for:)` +
  `appFullscreenForFallbackLifecyclePreservation` + `enterNonManagedFocus(...)`
  block. The new branch:

  ```swift
  // upstream PR #388, AXEventHandler.swift (appx. :1369)
  if let windowId = UInt32(exactly: axRef.windowId),
     let admittedEntry = admitFocusedUntrackedWindowIfNeeded(
         token: token, windowId: windowId
     )
  {
      let wsId = admittedEntry.workspaceId
      let targetMonitor = controller.workspaceManager.monitor(for: wsId)
      let isWorkspaceActive = targetMonitor.map { ... } ?? false
      handleManagedAppActivation(
          entry: admittedEntry, isWorkspaceActive: ..., appFullscreen: ...,
          source: source, confirmRequest: true, origin: origin
      )
      return
  }

  let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
  let fallbackFullscreen = appFullscreenForFallbackLifecyclePreservation(
      observedAppFullscreen: appFullscreen
  )
  // ... enterNonManagedFocus(appFullscreen: fallbackFullscreen)   ← the fallback
  ```

  `admitFocusedUntrackedWindowIfNeeded(token:windowId:)` (PR's new helper):
  returns the existing entry if already tracked; otherwise resolves window
  info, prepares a create candidate, asserts `candidate.token == token`, defers
  via `enqueueManagedReplacementCreate` if `shouldDelayManagedReplacementCreate`,
  else `trackPreparedCreate`s and returns the freshly-tracked entry. The caller
  then routes to `handleManagedAppActivation` with `confirmRequest: true`,
  bypassing the non-managed fallback.

## Provenance: is this nehir's code?

Yes. The activation-handling structure the PR touches is present in nehir and
was independently generalized. nehir renames the helper to
`admitFocusedWindowBeforeNonManagedFallback` and folds the disposition logic the
PR leaves to the caller *into* the helper.

## The code in question

**Call site** — `handleAppActivation` admits the focused window *before* the
non-managed fallback (same relative position the PR patches):

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:1682
if admitFocusedWindowBeforeNonManagedFallback(
    token: token,
    axRef: axRef,
    source: source,
    origin: origin,
    requestDisposition: requestDisposition,
    appFullscreen: appFullscreen
) {
    return
}
```

…followed (after a window-close-recovery guard and a disposition switch) by the
fallback nehir avoids:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:1734
let target = controller.keyboardFocusTarget(for: token, axRef: axRef)
let fallbackFullscreen = appFullscreenForFallbackLifecyclePreservation(
    observedAppFullscreen: appFullscreen
)
_ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: fallbackFullscreen)
// ... recordNiriCreateFocusTrace(.nonManagedFallbackEntered(pid: pid, source: source))
```

**Helper** — nehir's adapted, richer version of the PR's
`admitFocusedUntrackedWindowIfNeeded`:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:1751
private func admitFocusedWindowBeforeNonManagedFallback(
    token: WindowToken, axRef: AXWindowRef,
    source: ActivationEventSource, origin: ActivationCallOrigin,
    requestDisposition: ActivationRequestDisposition, appFullscreen: Bool
) -> Bool {
    ...
    let createPlacementContext = ensureCreatePlacementContextForFocusedAdmission(
        windowId: windowId, pid: token.pid
    )
    guard let candidate = prepareCreateCandidate(
        windowId: windowId, windowInfo: windowInfo,
        fallbackToken: token, fallbackAXRef: axRef,
        createPlacementContext: createPlacementContext
    ) else { /* retry scheduling */ return false }
    guard candidate.token == token else { return false }

    cancelCreatedWindowRetry(windowId: windowId)
    if shouldDelayManagedReplacementCreate(candidate) {
        enqueueManagedReplacementCreate(candidate)
        return true
    }
    trackPreparedCreate(candidate)
    guard let entry = controller.workspaceManager.entry(for: candidate.token) else { return true }
    ... // requestDisposition switch (.matchesActiveRequest / .conflictsWithPendingRequest / .unrelatedNoRequest)
    handleManagedAppActivation(entry: entry, isWorkspaceActive: ..., appFullscreen: appFullscreen,
                               source: source, confirmRequest: true, origin: origin)
    return true
}
```

**Test coverage** — nehir locks in the PR's exact behavior and four more
edge cases the PR's single test does not cover:

- `AXEventHandlerTests.swift:9829` — `focusedUntrackedStandardWindowIsAdmittedBeforeNonManagedFallback` *(the PR's verbatim test name)*: asserts the focused untracked window is admitted, `confirmedManagedFocusToken == admittedToken`, `isNonManagedFocusActive == false`, and **no** `nonManagedFallbackEntered` event for that pid/source.
- `AXEventHandlerTests.swift:9930` — admission uses a captured create-placement context.
- `AXEventHandlerTests.swift:10039` — admission *synthesizes* a create-placement context when the CGS create event has not arrived yet.
- `AXEventHandlerTests.swift:10135` — admission uses the recent same-pid workspace when focus was cleared.
- `AXEventHandlerTests.swift:10229` — admission uses the focused AX ref when window info is unavailable.

## Why the fix is already present and the PR is unsafe to port

1. **Same mechanism, earlier hook.** nehir admits the focused untracked window
   at `AXEventHandler.swift:1682`, *before* it reaches the non-managed fallback
   at `:1734` — exactly the ordering the PR introduces. The race window the PR
   targets (AX focus arriving before the CGS `.created` event) is the case
   `ensureCreatePlacementContextForFocusedAdmission` + the synthesized-context
   test at `:10039` were written for.

2. **nehir's helper is a strict superset of the PR's.** Relative to
   `admitFocusedUntrackedWindowIfNeeded`, nehir additionally:
   - folds in `requestDisposition` handling
     (`.matchesActiveRequest` / `.conflictsWithPendingRequest` /
     `.unrelatedNoRequest`) so a pending managed request is not clobbered by the
     admission — the PR's caller-side path calls `handleManagedAppActivation`
     with `confirmRequest: true` unconditionally;
   - schedules a `createdWindow`/`windowInfo` retry when the candidate cannot be
     prepared yet (the PR only `return nil` drops the admission);
   - synthesizes a create-placement context so placement keeps create-time
     focus/interaction inputs instead of falling back to live frame state
     (`AXEventHandler.swift:1773`-region).

   Porting the PR's diff verbatim would **remove** those guards — a regression,
   not a fix.

3. **Independently derived, not a cherry-pick.** The PR was closed without
   merge upstream, so it was never an accepted upstream fix. nehir's
   `admitFocusedWindowBeforeNonManagedFallback` predates / parallels it and is
   referenced as the *baseline* by two sibling discoveries
   (`20260616-omniwm-379-focus-revert-grace-period.md`,
   `20260616-omniwm-317-rapid-focus-revert-race.md`), which extend this same
   admission site for the rapid-focus-revert and focus-revert-grace races.

## Recommendation

**Do not port.** The activation race is already closed in nehir by
`admitFocusedWindowBeforeNonManagedFallback` (`AXEventHandler.swift:1751`,
called at `:1682`), with stronger guarantees than the PR. Treat #388 as
already-resolved evidence: its single test is subsumed by nehir's five
focused-admission tests. No new repo action.

## Cross-references

- Sibling discoveries that build on this same admission path:
  - `discovery/20260616-omniwm-379-focus-revert-grace-period.md`
  - `discovery/20260616-omniwm-317-rapid-focus-revert-race.md`
- Completed investigation referencing the admission helper:
  - `completed/20260615-new-window-placement-investigation.md`
  - `completed/20260615-quick-terminal-close-switches-workspace.md`
