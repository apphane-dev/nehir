# Finalize Destroy Liveness: Keep Cold-Start Protection, Remove Real AX-Closed Windows

Status: COMPLETED. Landed on `main` as `d4cc525c` ("Remove real AX-closed windows after liveness verification", 2026-07-08). The shipped change added a distinguishable AX enumeration result in `AXManager`, uses it in the deferred destroy-liveness check, and added focused `AXEventHandlerTests` coverage for AX-missing removal, both-oracles-alive retention, WindowServer-pid-mismatch removal, and AX-enumeration-failure retention. Changeset: `.changeset/20260708015201-remove-real-ax-closed-windows-without-reopening-.md`.

## Problem

PR #150 / `7a025b78` fixed the cold-start mass wipe by changing the AX destroy
callback path to call `handleWindowDestroyed(..., verifyWindowServerLiveness:
true)`. That prevents a spurious `AXUIElementDestroyed` from removing a live
tracked window during startup churn.

A newer real-close trace shows the opposite failure: the liveness gate can keep a
window that really closed, leaving an empty layout slot.

Self-contained evidence from the ChatGPT close trace:

- ChatGPT was admitted as `WindowToken(pid: 84435, windowId: 21728)` with
  `bundleId=com.openai.chat`, `context=focused_admission`, `mode=tiling`.
- Raw AX notifications later included
  `AXUIElementDestroyed pid=84435 window=21728`.
- A subsequent successful AX enumeration for the same pid returned no windows:
  `ax_windows_query pid=84435 newContext=false count=0 windowIds=[]`.
- Final runtime state still retained the closed window:
  `windows total=10 tiled=10`, with
  `WindowToken(pid: 84435, windowId: 21728) ... liveAXFrame=nil`.
- Final niri layout still contained the dead column:
  `w21728{... live=nil ... hidden:nil}`.

So the final fix must not simply revert PR #150. Reverting
`verifyWindowServerLiveness: true` on AX destroy would reopen the cold-start wipe
that PR #150 fixed. Instead, the deferred destroy check needs a second oracle:
when AX re-enumeration succeeds and no longer contains the window id, the close is
real even if the WindowServer surface was still briefly resolvable earlier.

## Shipped shape

Implemented files:

- `Sources/Nehir/Core/Ax/AXManager.swift` — added `PerAppWindowEnumeration`, `windowEnumerationForApp(_:)`, `windowEnumerationForPID(_:)`, and a test override so callers can distinguish successful empty enumeration from failed/timeout enumeration.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift` — kept the AX callback on `verifyWindowServerLiveness: true`; in `scheduleDestroyLivenessVerification(for:)`, removes when the WindowServer no longer resolves to the same pid or when a successful AX pid enumeration no longer includes the destroyed window id; keeps the entry when AX enumeration fails while WindowServer still says the pid/window is alive.
- `Tests/NehirTests/AXEventHandlerTests.swift` — added focused regression coverage for the dual-oracle behavior.
- `.changeset/20260708015201-remove-real-ax-closed-windows-without-reopening-.md` — patch release note.

This did not change the CGS `spaceWindowDestroyed` scope; that separate source hazard remains tracked in `discovery/20260707-cold-start-wipe-recurs-post-liveness-fix-only-focused-pid-readmitted.md`.

## Required behavior

For AX destroy callbacks:

1. If a destroy notification arrives and the window is still clearly alive, do
   not remove it immediately. Preserve PR #150's cold-start protection.
2. After the short deferred verification and AX warm-up, remove the tracked window
   when either:
   - `resolveWindowInfo(windowId) == nil`, or
   - AX enumeration for `token.pid` succeeds and does not include `token.windowId`.
3. Keep the window only when the deferred check still has positive liveness
   evidence, e.g. WindowServer still resolves it and AX still reports the same
   window id.
4. Do not change the CGS fix scope in this task except where necessary for shared
   helpers. The open CGS `spaceWindowDestroyed` recurrence remains tracked
   separately.

## Files to touch

Expected source files:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift`
- Tests under `Tests/NehirTests/` if existing seams support this without large
  harness churn.
- A patch changeset under `.changeset/`.

Do not keep the unsafe broad revert that changes
`handleRemoved(pid:winId:)` back to `verifyWindowServerLiveness: false`.

## Suggested implementation shape

In `scheduleDestroyLivenessVerification(for:)`, after the sleep and before
returning early:

1. Warm AX context as today.
2. Compute the WindowServer oracle:
   - `let windowServerAlive = resolveWindowInfo(windowId) != nil`
3. Compute an AX pid-enumeration oracle:
   - ask `controller.axManager.windowsForApp(app)` for the pid's running app
     (or an equivalent existing helper), and determine whether the returned
     windows include `token.windowId`.
   - Treat a successful empty list as evidence that the window is gone.
   - Be careful not to turn a failed/timeout enumeration swallowed as `[]` into
     false death evidence unless the API can distinguish success from failure. If
     it cannot distinguish, prefer adding a narrow helper or a diagnostic seam
     that can report success vs failure.
4. Remove when `!windowServerAlive || axEnumerationSucceededAndMissingToken`.
5. Otherwise keep the window.

If the existing AX API cannot distinguish successful empty enumeration from a
swallowed timeout/error, do **not** use a bare `[]` as proof. Add the minimum seam
needed to express `success(windowIds)` vs `failed/timeout` for this verification
path.

## Tests / validation

Shipped automated validation in `d4cc525c` includes these new tests:

- `axDestroyDeferredVerificationRemovesWhenAXEnumerationMissesWindow`
- `axDestroyDeferredVerificationKeepsWindowWhenBothOraclesStillAlive`
- `axDestroyDeferredVerificationRemovesWhenWindowServerPidNoLongerMatches`
- `axDestroyDeferredVerificationKeepsWindowWhenAXEnumerationFailsAndWindowServerAlive`

Manual runtime validation still useful after release: reproduce a real app close and a `dev:clean -- --trace` cold start to confirm no ghost slot and no mass wipe in live conditions.


Fast automated gates:

```bash
mise run test --filter AXEventHandlerTests/destroyRemovesInactiveWorkspaceEntryImmediately
mise run test:compile
```

Add focused tests if feasible:

1. **Real AX close removes stale slot**
   - Given a tracked tiling window.
   - AX destroy arrives.
   - Deferred verification sees AX enumeration success with no matching window id.
   - Expect `window_removed` / tracked entry removed.

2. **Cold-start spurious AX destroy stays protected**
   - Given a tracked tiling window.
   - AX destroy arrives.
   - Deferred verification still sees WindowServer alive and AX enumeration still
     includes the window id.
   - Expect the tracked entry remains.

Manual/runtime validation after automated gates:

1. Reproduce the ChatGPT close case:
   - Close ChatGPT window `21728`-like real app window.
   - Capture a trace.
   - Confirm raw AX has `AXUIElementDestroyed` and final layout no longer contains
     the closed window id.
   - Confirm there is a `window_removed` event and no empty layout slot.
2. Cold-start regression check:
   - Run `mise run dev:clean -- --trace`.
   - Confirm there is no startup mass wipe: no immediate all-window
     `window_removed` burst after `startup_full_rescan`, and final managed count
     matches expected windows.
3. Normal close check:
   - Close an ordinary managed window.
   - Confirm it disappears from layout within the verification delay and no ghost
     column remains.

## Changeset

Create a patch changeset summarizing the real user-visible behavior, for example:

```bash
mise run changeset patch "Remove real AX-closed windows without reopening cold-start destroy protection"
```

## Commit message

Use a plain-English subject, not Conventional Commits. Example:

```text
Remove real AX-closed windows after liveness verification
```
