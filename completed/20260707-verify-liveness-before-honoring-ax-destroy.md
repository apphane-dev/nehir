# Verify window liveness before honoring an AX destroy notification

**Status:** completed — landed on `main` as `7a025b78` ("Verify window liveness
before honoring a spurious AX destroy on cold start"), 2026-07-07.
**Symptom:** On a cold `mise run dev:clean` launch, Nehir admits the pre-existing
windows and then, ~1 s later, removes **all** of them as if destroyed, thrashing
(re-admit → destroy → re-admit) for 10–18 s before the window set settles. For
that whole interval the WM has zero or a flickering subset of managed windows.
**Root cause:** freshly-established per-app AX connections fire a spurious
`kAXUIElementDestroyed` burst against the first window handles; Nehir's destroy
path removed tiling windows on that notification **without any liveness check**,
even though the window was still present in the WindowServer.
**Fix shipped:** a destroy notification arriving over the AX-observer path is now
verified (defer + warm AX + re-check) before the window is torn down, so a
spurious cold-start destroy is ignored while a genuine close still removes the
window promptly.

Full evidence and the two-fact proof are in
`completed/20260707-cold-start-spurious-ax-destroy-wipes-managed-windows.md`
(discovery, also moved to completed).

## Resolution — what actually shipped (verified against `main` `7a025b78`)

The planned approach (Option 1: defer-and-verify only when the window is still in
the WindowServer, reusing the floating verification pattern) shipped, with two
refinements and one caveat:

- **Path-gated instead of unconditional.** `handleWindowDestroyed` gained a
  `verifyWindowServerLiveness: Bool` parameter
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:4183`). Only the
  AX-observer destroy path passes `true`
  (`handleRemoved(pid:winId:)` → `:1618`); the CGS destroy path passes `false`
  (`handleCGSWindowDestroyed` → `:1226`), so CGS-sourced destroys keep their
  prior immediate behavior. This is tighter than the plan's "verify every
  still-live destroy" and matches the evidence (the cold-start burst is
  AX-observer-sourced).
- **Liveness predicate is pid-matched**, not just non-nil: the verify branch
  defers only when `resolveWindowInfo(windowId)?.pid == candidate.token.pid`
  (`:4225`) — i.e. the WindowServer still reports *this app's* window for that id.
  A native-fullscreen destroy is still handled first inside the branch
  (`:4221-4224`).
- **Verification task** `scheduleDestroyLivenessVerification(for:)`
  (`:1495-1519`) mirrors `schedulePostCreateLifecycleVerification`: sleeps the
  shared `postCreateLifecycleVerificationDelay` (75 ms, `:517`), calls
  `warmAXContextIfNeeded` to re-resolve the stale AX handle, and only calls
  `handleRemoved(token:)` if `resolveWindowInfo(windowId) == nil` on re-check —
  otherwise the spurious destroy is dropped and the window stays managed.
  `cancelDestroyLivenessVerification(for:)` (`:1521`) is called at the top of
  `handleRemoved(token:)` (`:1628`) so an authoritative removal supersedes an
  in-flight verification. The former `resetPostCreateLifecycleVerificationState`
  was renamed `resetLifecycleVerificationState` (`:1526`) and now cancels both
  the post-create and destroy-liveness task maps
  (`pendingDestroyLivenessVerificationTasks`, `:574`).
- **Small refactor rode along:** the two `>= 50 % visible` frame checks in
  `AXEventHandler` were extracted to `Monitor.isFrameOnScreen(_:across:)` /
  `Monitor.visibleOverlapArea` (`Sources/Nehir/Core/Monitor/Monitor.swift:114`).
  Behavior-preserving.
- **Caveat — unrelated tracing bundled in the same commit.** `7a025b78` also
  carries a separate diagnostics feature ("Trace WindowModel/niri column desync
  on cross-display move"): `recordWindowModelNiriDesyncIfNeeded`,
  `pendingWindowRemovalPayload`, `recordWindowRemovalSeedCheck`, and readmit
  pending-removal trace emissions in
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:851,1179` plus a
  trace hook in the readmit path. This was **outside the plan's do-not-touch
  fence** (which named `AXEventHandler.swift` as the only file to touch). It is
  additive runtime-trace instrumentation, not a behavior change to the fix, but
  it is tracked here for provenance and belongs to a separate concern
  (WindowModel/niri desync on cross-display move) worth its own discovery.

Changeset shipped: `.changeset/20260707023920-stop-wiping-all-managed-windows-on-a-cold-start-.md`
(`patch`, "Stop wiping all managed windows on a cold start when macOS fires
spurious AX destroy notifications").

## Follow-ups

- **Runtime confirmation still owed.** The fix must be confirmed in a real
  `mise run dev:clean -- --trace` repro (no `managed_focus_cancelled` +
  `window_removed phase=destroyed` burst for live windows on startup, no
  `focus_lease_changed owner=window_close_focus_recovery` during startup,
  managed window count reaching the full set on the first admission pass and
  staying there). Regression tests should be added only after that confirmation
  (per repo AGENTS.md) — none were added in `7a025b78`. Candidate test: a destroy
  notification for a token whose `windowInfoProvider` still returns matching info
  must not remove the window until a re-check reports it gone, drivable via the
  `windowInfoProviderIsAuthoritativeForTests` / `axContextWarmupHandlerForTests`
  seams.
- **Bundled desync tracing** deserves its own discovery note (why was
  WindowModel/niri membership drifting on cross-display move; is the new
  `window_removal_seed_check` / `windowmodel_niri_desync` instrumentation meant
  to be permanent or a temporary probe?).

---

_Original plan preserved below for reference._

## Approach (as planned)

Reuse the liveness-verification pattern that already exists for floating windows
(`schedulePostCreateLifecycleVerification`) and apply it to the destroy path,
self-limited by the fact `prepareDestroyCandidate` already fetches: only
defer-and-verify when the window is still present in the WindowServer
(`resolveWindowInfo(windowId) != nil`). A genuine close reports nil window info
and is removed immediately as before — so steady-state close latency does not
regress; only a destroy that contradicts a still-live WindowServer surface pays
the verification delay.

## Files planned to touch

- `Sources/Nehir/Core/Controller/AXEventHandler.swift` — the destroy entry point
  and a new destroy-liveness verification task. (Shipped change also touched
  `Monitor.swift` for a behavior-preserving extraction and, out of fence,
  `LayoutRefreshController.swift` for unrelated tracing — see Resolution.)

## Gate (as planned)

- Fast gate between steps: `hk check`. Build once at the end: `swift build`.
- Tests deferred until user-confirmed runtime repro (repo AGENTS.md).
