# OmniWM issue #317 — "Rapid focus-next/prev snaps back to the wrong window" — Discovery

Groom 2026-07-07: still applicable — shouldHonorObservedFocusOverPendingRequest remains the time-blind boolean (source.isAuthoritative && origin == .external); no createdAt/grace window or IntentLedger exists in nehir (verified against main 7a025b78).

Source issue: https://github.com/BarutSRB/OmniWM/issues/317 — "When moving focus to
next/prev quickly, focus randomly goes in opposite direction"
Companion PR: https://github.com/BarutSRB/OmniWM/pull/379 — "Fix focus reverting on
rapid next/prev key presses (→#317)"
Scope: determine whether the
focus-revert race applies to nehir, and which fix is safe to port.

All file/line references were verified against the Nehir source tree
at `98f2429` ("Add more issue discoveries"). **Re-verify before implementing; line
numbers drift.** Verdict is by code inspection; nehir has no runtime trace for this
bug. Upstream quotes were fetched live from the GitHub web/API, not inferred from
titles.

> **Consolidation note.** This is the single authoritative discovery for #317. It
> merges eleven earlier redundant #317 discovery docs (rapid-focus-next-prev-*,
> rapid-focus-revert-stale-ax-echo, pr379-*, confirmation-echo-gap-deferral-queue,
> trigger-predicate-and-keypress-fronting-path, revert-clears-confirmedfocus-*,
> grace-period-fix-unported-applies, closed-unmerged-state-*) that a duplicate-run
> of the discovery orchestrator produced against the same ticket. Those files have
> been deleted; line refs below were re-verified at the current sha and supersede
> the slightly-discrepant numbers in the deleted drafts.

---

## TL;DR

- **Rapid focus-next/prev reverts to an intermediate window because a stale macOS
  Accessibility (AX) focus notification from an *earlier* key press overrides a
  brand-new, still-young `ManagedFocusRequest`. nehir's only defense is a single
  time-blind boolean, `shouldHonorObservedFocusOverPendingRequest`, which cannot
  distinguish "an AX echo of the window I fronted 5 ms ago" from "the user genuinely
  clicked a different window."**
- **Verdict:** 🔴 **Open / reproducible by inspection.** The vulnerable path is
  present verbatim. `ManagedFocusRequest` carries **no creation timestamp and no
  request-origin stamp**, and `grep` across `Sources/Nehir` for
  `intentLedger|classifyFocusObservation|echoOf|lateEcho|managedRequestGracePeriod`
  returns **zero matches** — no time-based or ledger-based defense exists. It will
  reproduce here.
- **The upstream fix is not directly portable.** PR #379 (300 ms grace period) was
  **closed without merge**; OmniWM `main` instead shipped a large architectural
  redesign — an `IntentLedger` + `DeadlineWheel` that *deletes*
  `FocusBridgeCoordinator` entirely. nehir is on the **old architecture** (it still
  has `FocusBridgeCoordinator`, and none of `IntentLedger`/`DeadlineWheel`/
  `ManagedFocusOrigin`). A full port is a rewrite, not a bug fix.

## Upstream state — corrects the catalog

The catalog flags #317 as `open` and PR #379 as `open`. A direct GitHub REST-API
read contradicts both:

| Fact (API) | Value |
|---|---|
| Issue #317 `state` / `state_reason` | **closed** / **completed** |
| Issue #317 `closed_at` / `closed_by` | `2026-06-15T23:32:00Z` / `BarutSRB` |
| Issue #317 close event `commit_id` | **`null`** → manual close, **no referencing commit** |
| PR #379 `state` / `merged` | closed / **false** |
| PR #379 `merged_at` / `merge_commit_sha` | `null` / `null` |
| PR #379 `closed_at` | `2026-06-15T23:35:07Z` (**3 min after** the issue) |
| PR #379 `head.repo` / `head.ref` | `biswadip-paul/OmniWM` / `fix/focus-direction-race-on-rapid-keypress` |

The issue was closed *as completed* yet the close event carries **no commit**, and
the fix PR was closed-unmerged **after** the issue. The fix text survives only in
two **contributor forks** (not `BarutSRB/OmniWM`): the unmerged PR #379 branch above,
and a cherry-pick (commit `8674850`) into a *different* fork, `bispaul/OmniWM`,
whose message notes the original PR "missed" the callsite inside
`admitFocusedWindowBeforeNonManagedFallback` and patches that fifth site.

**Practical consequences:** (1) the closure changes nothing for nehir — nehir has
none of the fix, so the bug reproduces regardless of upstream labels; (2) there is
**no merge SHA** to cite or sync from — cite PR #379's diff + the `bispaul/OmniWM`
cherry-pick note as design provenance only; (3) the fix will not reappear in
nehir's upstream diff-tracking.

## Provenance: is this nehir's code?

Yes — the entire focus-conflict machinery is present and nehir-owned (module renamed
`OmniWM` → `Nehir`, `Sources/Nehir/`). Every symbol the issue/PR names resolves:

- `struct ManagedFocusRequest` — `Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:26`.
- `FocusBridgeCoordinator.beginManagedRequest` (sole construction site) — same file, `:55`; request built at `:67`.
- `enum ActivationRequestDisposition` cases `.matchesActiveRequest(ManagedFocusRequest)` / `.conflictsWithPendingRequest(ManagedFocusRequest)` — `Sources/Nehir/Core/Controller/AXEventHandler.swift:12-13`.
- `func shouldHonorObservedFocusOverPendingRequest(source:origin:)` — `Sources/Nehir/Core/Controller/AXEventHandler.swift:3553`.
- `func clearManagedFocusState` (the revert action) — `AXEventHandler.swift:3583`.
- `func performWindowFronting` — `Sources/Nehir/Core/Controller/WMController.swift:3570`.

## The bug

### The trigger predicate, fully expanded

The revert decision collapses to one boolean. Tracing both operands to their
definitions:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:3553
private func shouldHonorObservedFocusOverPendingRequest(
    source: ActivationEventSource,
    origin: ActivationCallOrigin
) -> Bool {
    source.isAuthoritative && origin == .external        // :3557
}

// Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:9
var isAuthoritative: Bool { self == .focusedWindowChanged }

// Sources/Nehir/Core/Controller/AXEventHandler.swift:31
enum ActivationCallOrigin: String { case external; case probe; case retry }
```

So the predicate is exactly **`source == .focusedWindowChanged && origin == .external`**.
It receives **neither** the conflicting `ManagedFocusRequest` **nor** any notion of
*when* that pending request was issued — so it cannot tell a self-echo of a prior
command from a genuine external focus change (a click).

`activationRequestDisposition` (`AXEventHandler.swift:3520`) has **two** conflict
sub-cases, both routing to the same blind boolean — a cross-app echo (different pid,
`:3523`) and a same-app-different-window echo (same pid, different token, `:3529`).
A 4-window workspace repro can hit either.

### The request carries no age / no origin

```swift
// Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:26
struct ManagedFocusRequest: Equatable {
    enum Status: Equatable { case pending; case confirmed }

    let requestId: UInt64          // :32
    var token: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
    var retryCount: Int = 0
    var lastActivationSource: ActivationEventSource?
    var status: Status = .pending
}                                // ← no createdAt, no origin, no age  (PR #379 / main add one of these)
```

Built without a timestamp at `:67` (no `createdAt:` argument).

> **Misleading-code warning.** `createdAt: Date` *does* appear at
> `AXEventHandler.swift:87`/`:98`/`:3405`/`:3459` — but it belongs to the unrelated
> `WindowCreatePlacementContext` placement-context cache, **not** to
> `ManagedFocusRequest`. Do not mistake it for the fix already being present.

### The keypress → fronting path

```swift
// Sources/Nehir/Core/Input/HotkeyCommand.swift          case .focusPrevious
// Sources/Nehir/Core/Controller/CommandHandler.swift:49   case let .focus(direction):
// Sources/Nehir/Core/Controller/CommandHandler.swift:50     → niriLayoutHandler.focusNeighbor(direction:)
// Sources/Nehir/Core/Controller/CommandHandler.swift:51   case .focusPrevious:
// Sources/Nehir/Core/Controller/CommandHandler.swift:52     → focusPreviousInNiri()
//   … target window selected via engine.focusPrevious (CommandHandler.swift:248) …
//   … ultimately controller.focusWindow(target) …

// Sources/Nehir/Core/Controller/WMController.swift:3612   func focusWindow(_ token:)
_ = workspaceManager.beginManagedFocusRequest(token, in: wsId, …)          // :3622
let request = focusBridge.beginManagedRequest(token: token, workspaceId: wsId) // :3627  ← activeManagedRequest now = NEW target
…
focusBridge.focusWindow(token, performFocus: { … performWindowFronting(…) … // :3643  ← actual fronting (dedupe + deferral queue)
    self.axEventHandler.probeFocusedWindowAfterFronting(expectedToken: token, …) },  // :3648
    onDeferredFocus: { … self.focusWindow(deferred) })
```

**Note the ordering** (`:3627` then `:3643`): each rapid press **replaces
`activeManagedRequest` with a fresh request for the new target before its own
fronting — and any still-prior fronting — completes.** This is what lets
bookkeeping and the in-flight focus operation disagree.

### The five conflict sites (all unguarded)

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:1410   (mirrored at :1490, :1558, :1651, :3474)
case let .conflictsWithPendingRequest(request):
    if shouldHonorObservedFocusOverPendingRequest(
        source: source,
        origin: origin
    ) {
        clearManagedFocusState(matching: request.token, workspaceId: request.workspaceId)   // ← snap back
        break
    }
    continueManagedFocusRequest(request, source: source, origin: origin, reason: .pendingFocusMismatch)   // ← NOT reached on revert
    return
```

The five call sites of the guard (re-confirmed by direct read):

| Line | Context |
|---|---|
| `:1411` | `.conflictsWithPendingRequest` case |
| `:1490` | `.conflictsWithPendingRequest` case |
| `:1558` | combined `.matchesActiveRequest` / `.conflictsWithPendingRequest` case |
| **`:1651`** | **inside `admitFocusedWindowBeforeNonManagedFallback` (def `:1596`)** — the site PR #379 missed |
| `:3474` | combined case in `handleMissingFocusedWindow` (def `:3463`) |

### What actually reverts (mechanics correction)

The visible "snap-back" is **not** `selectedNodeId` reverting.
`clearManagedFocusState` (`AXEventHandler.swift:3583`) **never writes
`selectedNodeId`** — it discards the pending focus, cancels the managed request, and
clears the keyboard-focus target / focus *border*
(`clearKeyboardFocusTarget`, `WMController.swift:3773`):

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:3583
private func clearManagedFocusState(matching token: WindowToken, workspaceId: WorkspaceDescriptor.ID?) {
    guard let controller else { return }
    controller.focusBridge.discardPendingFocus(token)
    let canceledRequest = controller.focusBridge.cancelManagedRequest(matching: token, workspaceId: workspaceId)
    _ = controller.workspaceManager.cancelManagedFocusRequest(matching: token, workspaceId: workspaceId)
    if let canceledRequest { cancelActivationRetry(requestId: canceledRequest.requestId) }
    controller.clearKeyboardFocusTarget(matching: token, restoreCurrentBorder: false)
}
```

`selectedNodeId` (the niri selection) is advanced **proactively at keypress time**
(`CommandHandler.swift:450`/`:455`, `NiriLayoutHandler.swift:529`/`:647`) and is left
untouched on the revert path. What moves instead is the focus *model*
(`confirmedManagedFocusToken`) and the *request ledger* (`activeManagedRequest`):
the site `break`s after clearing, so `continueManagedFocusRequest` (the only branch
that would re-assert the intended window) never runs, and the OS's late fronting of
the intermediate window is left as the on-screen focus.

**This matters for the fix and its tests:** the guard's job is to **keep
`continueManagedFocusRequest` reachable for a young/self-echo conflict** so the
intended window is re-asserted — not to protect `selectedNodeId`. Tests must assert
on `confirmedManagedFocusToken` / `activeManagedRequest`.

## Root cause — three reinforcing gaps

### 1. The probe-vs-echo asymmetry (the exact shape of the bug)

nehir **does** re-observe focus itself, right after fronting, and **already**
recognizes and drops a stale self-observation:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:506
func probeFocusedWindowAfterFronting(expectedToken: WindowToken, workspaceId _: WorkspaceDescriptor.ID) {
    let requestId = controller?.focusBridge.activeManagedRequest(for: expectedToken)?.requestId
    Task { @MainActor [weak self] in
        guard let self else { return }
        if let requestId,
           self.controller?.focusBridge.activeManagedRequest(requestId: requestId) == nil {
            return                              // ← bail if OUR request was superseded by a newer one
        }
        self.handleAppActivation(pid: expectedToken.pid, source: .focusedWindowChanged, origin: .probe)
    }
}
```

Two facts follow:

- This self-probe uses `origin: .probe`, so it **does not trip the guard** (which
  requires `.external`) — it routes to `continueManagedFocusRequest`, not the revert.
- The `requestId` bail (`:512-514`) answers *exactly* the question "is this an echo
  of a now-stale intent I issued myself?" — correctly, **but only for `.probe`**.

**The bug is the asymmetry:** the pending request can recognize and drop a stale
*self-probe* but honors a stale *OS* `.external` echo unconditionally, even though
both are echoes of the same prior fronting. Closing this asymmetry is the whole fix.

### 2. nehir already has echo recognition — on the *confirmed* path only

`FocusBridgeCoordinator` already keeps a timestamped record of recently-confirmed
managed requests and answers "is this activation an echo of our own recent confirm?":

```swift
// Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:47
private struct ConfirmedManagedRequest {
    var token: WindowToken
    var confirmedAt: Date          // :49
}
// :169   func recentlyConfirmedManagedRequest(for token:, within interval:) -> Bool
//        … Date().timeIntervalSince(confirmation.confirmedAt) <= interval …   (echo test)
```

Populated in `confirmManagedRequest` (`:119`, writing `confirmedAt: Date()`) and
consumed at `AXEventHandler.swift:1338`-`:1340` to recognize a self-echo, gated by:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:302
private static let nativeAppSwitchLeaseRequestConfirmationGrace: TimeInterval = 0.6
```

But the #317 race is entirely on the **pending** path, where `ManagedFocusRequest`
has no timestamp — a pending request is, by definition, not yet confirmed, so
`recentlyConfirmedManagedRequest` cannot classify the late echo. **The fix is
already half-built in nehir; the gap is narrow and local.**

### 3. The deferral queue widens the bookkeeping/operation desync

`FocusBridgeCoordinator.focusWindow` coalesces and defers (`:206`): a 16 ms dedupe
(`:213`) plus an `isFocusOperationPending` deferral queue (`:217`/`:219`) that queues
a later target while an earlier focus is mid-flight (`onDeferredFocus` replays it,
`:231`). Combined with the `beginManagedRequest`-then-`focusWindow` ordering in
`WMController` (`:3627` → `:3643`), the deferral queue **increases the window** in
which `activeManagedRequest` already points at the new target while an older fronting
is still in flight — exactly when a late echo for the older window reads as a
conflict.

## Why the upstream fix isn't a clean port

Three candidate fixes exist. Pick one; **all three must touch all five conflict
sites** (`:1411`, `:1490`, `:1558`, `:1651`, `:3474`) or the race stays reachable
through the missed branch.

| Option | What | Scope / risk | Caveat |
|---|---|---|---|
| **A — PR #379 grace (stopgap)** | `createdAt: CFAbsoluteTime` + `var age` on `ManagedFocusRequest`; 300 ms grace in the guard | Small, additive, surgical | Closed-unmerged; can wrongly suppress a genuine change made within 300 ms, and a stale echo arriving after 300 ms still reverts — **why upstream abandoned it.** |
| **B — codebase-faithful (recommended)** | Extend nehir's *existing* echo recognition to the pending path: a `recentlyIssuedManagedRequest` (token + `issuedAt: Date`) recorded in `beginManagedRequest`, mirroring `ConfirmedManagedRequest`; reuse the **0.6 s** `nativeAppSwitchLeaseRequestConfirmationGrace` | Medium; reuses concepts nehir already understands; local to the pending path | A 0.3 s window (option A) + 0.6 s confirmed window would let a self-echo fall through the gap — **use 0.6 s so both windows agree.** |
| **C — OmniWM `main` ledger (principled, rewrite)** | New `IntentLedger` with `classifyFocusObservation(token:) -> .echoOf/.lateEcho/.external`, threaded into all five sites with an `observedToken:` param | Large — `main`'s ledger is the backbone of `AXEventHandler` (25+ call sites), deletes `FocusBridgeCoordinator`, adds a `ManagedFocusOrigin` enum, and moves the live request from `controller.focusBridge.activeManagedRequest` to `controller.intentLedger.activeManagedRequest` | The axis upstream settled on after rejecting the timer; avoids re-litigating the trade-off |

**OmniWM `main`'s guard** (verified verbatim at `AXEventHandler.swift:3680` in `main`):

```swift
private func shouldHonorObservedFocusOverPendingRequest(
    observedToken: WindowToken?, source: ActivationEventSource, origin: ActivationCallOrigin
) -> Bool {
    guard source.isAuthoritative, origin == .external else { return false }
    guard let controller, let observedToken else { return true }
    switch controller.intentLedger.classifyFocusObservation(token: observedToken) {
    case .echoOf, .lateEcho: return false      // self-echo of our own recent intent → reject
    case .external: return true
    }
}
```

`main` has **no** `managedRequestGracePeriod`/`createdAt`/`age` — the time heuristic
was dropped entirely in favor of classifying *which* managed intent the observation
echoes (commits `bcb3dff` "Add IntentLedger and DeadlineWheel…" and `47106f8`
"Delete FocusBridgeCoordinator; IntentLedger owns focus requests").

**Do not** copy PR #379's diff verbatim: closed-not-merged, superseded, and it
under-covers the call sites (its cherry-pick had to add the
`admitFocusedWindowBeforeNonManagedFallback` site at `:1651`).

## Recommendation

🟢 **Fix here — default to option B, the codebase-faithful port.** It directly closes
the probe-vs-echo asymmetry by giving the *pending* path the echo recognition the
*confirmed* path already has, with minimal surface area. Concrete steps:

1. In `ManagedFocusRequest` (`KeyboardFocusLifecycleCoordinator.swift:26`), add a
   creation stamp — match the local idiom (`let createdAt: Date` + `var age:
   TimeInterval { Date().timeIntervalSince(createdAt) }`, mirroring
   `ConfirmedManagedRequest.confirmedAt` `:49` and the `:175` expiry check), **not**
   `CFAbsoluteTime`, which would be the only occurrence of that type here.
2. Stamp `createdAt: Date()` at the construction site (`:67`, inside
   `beginManagedRequest` `:55`), mirroring the `confirmedAt: Date()` stamp at `:119`/`:131`.
3. Widen `shouldHonorObservedFocusOverPendingRequest` (`:3553`) to take
   `pendingRequest: ManagedFocusRequest`, and reject a conflicting
   authoritative-external observation while the request is younger than the grace
   window. **Reuse `nativeAppSwitchLeaseRequestConfirmationGrace` (0.6 s, `:302`)**
   — or a sibling constant — so the two echo windows agree; do **not** introduce a
   second 0.3 s window.
4. Thread `pendingRequest: request` into **all five** sites — `:1411`, `:1490`,
   `:1558`, `:3474`, **and `:1651`** (inside `admitFocusedWindowBeforeNonManagedFallback`).
   The `request` value is already bound at every site (each sits under a
   `.conflictsWithPendingRequest(request)` case), so this is additive — no
   call-graph surgery.
5. Inject a clock in tests rather than calling `Date()` inline, so the window is
   deterministic.

If a fuller rewrite is wanted later, plan the transition to option C (the
`IntentLedger`), which is the unifying primitive for this **and** the FFM focus race
(see below). Option A (PR #379's 300 ms grace) is an acceptable fast stopgap only.

## Existing tests encode the buggy contract (must be qualified)

nehir already has **dedicated tests for this exact conflict path** that assert the
pre-fix behavior is correct — they will **fail against the fix** unless their
fixtures are updated:

```swift
// Tests/NehirTests/AXEventHandlerTests.swift:1616
@Test @MainActor func externalFocusedWindowChangeCancelsConflictingPendingRequestAndAdoptsObservedManagedWindow() {
    // … focusedWindowRefProvider returns a *different* observedToken (conflicts with pending) …
    controller.axEventHandler.handleAppActivation(pid: getpid(), source: .focusedWindowChanged)
    #expect(controller.focusBridge.activeManagedRequest == nil)                       // :1676 — pending request CLEARED
    #expect(controller.workspaceManager.confirmedManagedFocusToken == observedToken)  // :1678 — external observation WINS
}
// :1698  externalFocusedWindowChangeWithNoObservedWindowCancelsPendingRequestAndFallsBackToNonManaged
//        → #expect(activeManagedRequest == nil); #expect(isNonManagedFocusActive)
// :1769  externalFocusedWindowChangeWithObservedUnmanagedWindowCancelsPendingRequestAndFallsBackToNonManaged
//        → #expect(activeManagedRequest == nil); confirmedManagedFocus == observedToken
```

These three (`:1616`, `:1698`, `:1769`) fire a `.focusedWindowChanged`/`.external`
observation that **conflicts** with a pending request and assert the request is
cancelled and the observation adopted — regression guards for the very behavior the
fix changes, with **no notion of request age or echo identity** (confirmed: `grep`
for `rapid|grace|createdAt|echoOf|lateEcho` across `AXEventHandlerTests.swift` /
`WMControllerFocusTests.swift` hits only the unrelated structural-replacement
"grace" windows). A port is not just "add tests" — these must be qualified to
deliver the conflicting observation *outside* the grace/echo window (or as a
non-echo token), or they flip red and block the build.

## Suggested tests

In `Tests/NehirTests/`, against a 4-window workspace:

- **Rapid focus-next settles on the final window.** Fire focus-next ×3 within
  < 100 ms; assert `confirmedManagedFocusToken` ends on window 4 and no
  `clearManagedFocusState` fires for the final `ManagedFocusRequest` while it is
  young. Direct regression for the reported symptom.
- **Stale OS `.external` echo is rejected; self-`.probe` still bails.** With an
  active *pending* `ManagedFocusRequest` for window 4, inject an
  authoritative-`focusedWindowChanged`/`.external` activation for window 3 within
  the echo window; assert the request is *not* cleared and focus stays on window 4
  (`shouldHonorObservedFocusOverPendingRequest` returns `false`, and
  `continueManagedFocusRequest` / `.activationDeferred(.pendingFocusMismatch)` fires
  for window 4). Separately assert the self-`probe` path still bails on supersession
  (locks the asymmetry fix without regressing the probe bail).
- **Both conflict sub-cases covered.** Drive the revert through a cross-pid echo
  *and* a same-pid-different-window echo (`activationRequestDisposition` `:3523`
  and `:3529`).
- **Genuine external focus after the echo window is honored.** Same setup, deliver
  the `.external` observation after the window expires (or a genuinely external
  non-echo token); assert focus *does* move (clicking a window must still win —
  guards against over-suppression).
- **All five call sites covered**, including the combined `:3473` case and the
  `admitFocusedWindowBeforeNonManagedFallback` site at `:1651` — so a port that
  misses one fails its test.
- **Assert on the right fields.** Use `confirmedManagedFocusToken` /
  `activeManagedRequest`, **not** `selectedNodeId` (which is not on the revert path).

## Relationship to the FFM focus race (unifying primitive)

Structurally parallel to
`discovery/20260616-ffm-steals-focus-behind-overlay-on-stale-queued-mouse-moves.md`
(FFM / `MouseEventHandler` / stale queued mouse-move). Same shape — "the handler
cannot tell a stale echo of its own prior action from a genuine new event" — on a
different actor and path. OmniWM `main`'s `IntentLedger` was built to solve exactly
this, which is why option C is the natural long-term target for both.
