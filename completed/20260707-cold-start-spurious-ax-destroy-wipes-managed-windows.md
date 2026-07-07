# Cold-Start Spurious AX-Destroy Wipes All Managed Windows — Discovery

Deep discovery (2026-07-07) into "`dev:clean` starts in a very broken state, not
able to properly enumerate all windows on start." Two fresh-launch runtime
captures were taken via `mise run dev:clean -- --trace` (which deletes
`runtime-state.json` before launch, so every pre-existing window is admitted
cold). Both show the identical pathology: within ~1 second of admitting the
five pre-existing windows, Nehir **removes all of them as if destroyed**, then
thrashes (re-admit → destroy → re-admit) for many seconds before the window set
finally settles.

This document pins the mechanism to source and confirms the arming/gating
condition. File:line references were current at the discovery date and will
drift — re-verify before implementing.

**Status: RESOLVED.** Fix landed on `main` as `7a025b78` ("Verify window
liveness before honoring a spurious AX destroy on cold start", 2026-07-07). The
destroy path now verifies WindowServer liveness (defer + warm AX + re-check)
before honoring an AX-observer destroy. See the completed plan
`completed/20260707-verify-liveness-before-honoring-ax-destroy.md` for the shipped
shape and deviations. Runtime confirmation via a real `dev:clean` repro and
regression tests are still outstanding (tracked in that plan's follow-ups).

**Verdict: actionable.** Root cause is a real macOS AX `kAXUIElementDestroyed`
burst against freshly-connected app AX contexts, which Nehir's destroy path
trusted **without any liveness re-check for tiling windows** — even though it
already fetched the WindowServer liveness fact it would need, and already had a
liveness-verification precedent for floating windows.

## Topology / initial state (from the capture snapshot)

Two displays; cold launch with no persisted runtime state (`persistedDirty=true`,
`consumedPersistedEntries=0`, `no-managed-windows`, `windows total=0`). Five
regular (`activationPolicy=0`) windows exist and are visible to AX at capture
start — each reported with `axWindowsResult=0` (AX success) and
`axContainsWindow=true`:

| token | owner | note |
| --- | --- | --- |
| `W(pid 55316 / win 351)` | Telegram | becomes first managed focus |
| `W(pid 28651 / win 10428)` | Helium | "Pull requests …" |
| `W(pid 28651 / win 215)` | Helium | second Helium window (same pid) |
| `W(pid 89691 / win 1573)` | Code - Insiders | |
| `W(pid 72005 / win 7619)` | Microsoft Teams | |

All five are placed into the same active workspace `13BC75D5-…` on display 1.

The per-pid AX enumeration **succeeds on the first try and keeps succeeding** —
this is not an AX-can't-see-the-windows problem. The query recorder shows, at
capture start (`newContext=true` = the `AppAXContext` was created fresh for that
pid this run):

```
ax_windows_query pid=89691 newContext=true  count=1 windowIds=[1573]
ax_windows_query pid=72005 newContext=true  count=1 windowIds=[7619]
ax_windows_query pid=28651 newContext=true  count=2 windowIds=[10428, 215]
ax_windows_query pid=55316 newContext=true  count=1 windowIds=[351]
```

and, throughout the thrash that follows, the same ids keep coming back alive,
e.g. `ax_windows_query pid=28651 newContext=false count=2 windowIds=[10428, 215]`
repeated six times in one second. **The windows never leave AX or the
WindowServer.** They are only ever removed from Nehir's own model.

## The observed failure sequence (both captures, identical shape)

Numbered events are the trace's reconcile-event stream (`event=…`):

```
#1–#5    window_admitted   context=startup_full_rescan   (all 5 windows)   T+0.0s
#6–#8    hidden_state_changed hidden=true phase=offscreen (3 non-focused windows)
#9–#11   managed_focus_requested/confirmed  W(55316/351)  (Telegram takes focus)
#16–#25  window_admitted   context=pid_reevaluation       (all 5 re-admitted)
         + managed_replacement_metadata_changed for each  T+~1.0s
#26      managed_focus_cancelled W(89691/1573)
#27      window_removed          W(89691/1573)   phase=destroyed
#28–#32  managed_focus_cancelled + window_removed  W(28651/10428), W(28651/215)
#33      focus_lease_changed owner=window_close_focus_recovery
#34      window_removed          W(55316/351)   phase=destroyed   ← the focused window
#35–#36  managed_focus_cancelled + window_removed  W(72005/7619)
                                    ← ALL FIVE WINDOWS NOW GONE, focused=nil
#37–#70  window_admitted context=pid_reevaluation, W(28651/215) & W(28651/10428)
         re-admitted over and over (churn loop)            T+~5s
#71+     window_admitted context=startup_full_rescan (all 5 again); settles      T+~10s
```

In the second capture the recovery is even slower: after the wipe, the next
admission is `window_admitted … context=focused_admission W(55316/351)` a full
**18 seconds later**. So the user-visible symptom is: launch Nehir, and for
~10–18 seconds it has zero (or a thrashing subset of) managed windows.

## Two facts that pin the cause

### Fact 1 — the removals go through the **AX-destroy path**, not rule reevaluation

There are two code paths that emit `window_removed`:

- `WMController.reevaluateWindowRules(...)` calls `workspaceManager.removeWindow`
  directly when a window should be un-managed
  (`Sources/Nehir/Core/Controller/WMController.swift:2970`).
- The AX-destroy path: `handleRemoved(token:)`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1569`), reached only from
  a real destroy notification.

Both funnel into `WorkspaceManager.removeTrackedWindow`
(`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3231`), which records
`.windowRemoved(source: .workspaceManager)` — so `window_removed` alone does not
distinguish them. **But `focus_lease_changed owner=window_close_focus_recovery`
(event #33) does.** That lease is armed exclusively by
`beginWindowCloseFocusRecovery` (`AXEventHandler.swift:1586`), which is only ever
called from the AX-destroy handlers — never from the reevaluate/un-manage path.
Its appearance immediately before `window_removed W(55316/351)` (the focused
window, #34) proves the focused window was torn down via `handleRemoved(token:)`,
i.e. in response to a destroy notification, not a rule decision.

### Fact 2 — the destroy notifications are **spurious**; the windows are alive

`AppAXContext.onWindowDestroyed` is wired once at startup to
`handleRemoved(pid:winId:)`
(`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:89-91`) and is
invoked only from the AX observer C-callback
`AppAXContext.handleWindowDestroyedCallback`
(`Sources/Nehir/Core/Ax/AppAXContext.swift:306`), which fires when macOS delivers
`kAXUIElementDestroyedNotification` for a window element that was subscribed in
`addWindowNotifications` (`AppAXContext.swift:344-363`). The CGS-side destroy path
is not involved here — the capture shows `CGSEventObserver … decodedEvents: 0`.

So macOS genuinely delivered destroy notifications for all five windows ~1s after
launch. The corroborating detail: every affected pid's `AppAXContext` was created
**this run** (`newContext=true` for all four pids at T+0), and the destroy burst
lands ~1s later. This is the well-known macOS behavior where the *first*
`AXUIElement` window handles obtained over a freshly-established app AX connection
get invalidated (and fire `kAXUIElementDestroyedNotification`) once the app's real
accessibility connection settles — and a cold `dev:clean` launch establishes AX
connections to **every already-running app at once**, so the invalidation burst
hits every window simultaneously. AX re-queries immediately afterward return the
same window ids, confirming the windows themselves never went away.

## Root cause — the destroy path never checks liveness for tiling windows

`handleRemoved(pid:winId:)` (`AXEventHandler.swift:1561`) →
`handleWindowDestroyed(windowId:pidHint:)` (`AXEventHandler.swift:4127`) →
`prepareDestroyCandidate` (`AXEventHandler.swift:4072`) →
`processPreparedDestroy` (`:4200`) → `handleRemoved(token:)` (`:1569`).

`prepareDestroyCandidate` **already fetches the liveness oracle** it would need:

```swift
// AXEventHandler.swift:4092-4093
let bundleId = resolveBundleId(token.pid) ?? entry.managedReplacementMetadata?.bundleId
let windowInfo = resolveWindowInfo(windowId)          // ← WindowServer liveness fact
```

`resolveWindowInfo` (`AXEventHandler.swift:5632`) returns the live
`WindowServerInfo` via `SkyLight.shared.queryWindowInfo(windowId)` — non-nil when
the window still exists. But `windowInfo` here is used **only to enrich managed-
replacement metadata** (`:4094-4119`); it is never consulted to decide *whether
to destroy at all*. `prepareDestroyCandidate` returns a non-nil candidate as long
as a tracked entry exists, so the destroy proceeds even though the window is
demonstrably still on screen.

There is already a liveness-verification precedent — but it is gated to floating
windows only:

- `requiresPostCreateLifecycleVerification` (`AXEventHandler.swift:4027`) returns
  `false` unless `trackedMode == .floating` (`:4031`).
- When it is true, `schedulePostCreateLifecycleVerification`
  (`AXEventHandler.swift:1445`) waits `postCreateLifecycleVerificationDelay`
  (75 ms, `:517`), warms the AX context, and **only** calls `handleRemoved` if
  `resolveWindowInfo(windowId) == nil` on a re-check (`:1455`, `:1462`) — i.e. it
  refuses to remove a window that is still present in the WindowServer.

The windows in the trace are all `mode=tiling`, so they get **none** of that
protection: a single spurious `kAXUIElementDestroyed` immediately removes them.

## Why the wipe becomes a multi-second thrash (not a one-shot glitch)

`handleRemoved(token:)` ends by re-arming reevaluation for the same pid:

```swift
// AXEventHandler.swift:1629
scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
```

`reevaluateWindowRules` then re-queries the pid's live windows
(`WMController.swift:2898-2914`, via `windowsForApp`), finds them still alive, and
re-admits them under `context=pid_reevaluation` — which is exactly the
`#37–#70` Helium churn. Reevaluation runs at all because `needsWindowReevaluation`
is true whenever any dynamic (e.g. title-dependent) rule exists
(`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:427-429`). Each re-admission
re-subscribes the destroy notification, macOS may fire another spurious destroy,
and the loop repeats until the AX connections stop invalidating handles (~10–18 s
in these captures).

## Why `dev:clean` specifically

`nehir-dev-run clean` removes `runtime-state.json` before launch
(`.config/mise/scripts/nehir-dev-run`, `clean` case). With no persisted state,
**all** windows are admitted cold in the same startup window during which AX
connections are freshly established and their first handles are most likely to be
invalidated — maximizing the spurious-destroy burst. A warm launch (persisted
state present) is plausibly less exposed because fewer windows are admitted
brand-new in that fragile window; this warm-vs-cold difference is stated as a
hypothesis, not confirmed here (both captures are cold).

## Fix options (for the plan stage)

1. **Liveness-gate the destroy path (recommended).** In `handleWindowDestroyed` /
   `prepareDestroyCandidate`, if `resolveWindowInfo(windowId) != nil` (the window
   is still in the WindowServer), do **not** destroy immediately; instead treat it
   like the floating post-create path — defer, warm the AX context, re-check
   liveness, and only remove if it is genuinely gone. This reuses the existing
   `schedulePostCreateLifecycleVerification` precedent and the fact already
   fetched at `:4093`. Risk: a genuine close where the WindowServer surface
   lingers briefly would be removed a beat later (the same tradeoff the floating
   path already accepts).

2. **Extend `requiresPostCreateLifecycleVerification` to tiling windows during a
   startup grace window.** Narrower blast radius (only newly-admitted windows,
   only shortly after launch), but needs a startup-elapsed timestamp — note
   `hasStartedServices` (`WMController.swift:232`,
   `ServiceLifecycleManager.swift:76`) flips true at service start, not after
   settling, so a `Date` captured at that point would be the gate.

3. **Debounce/verify destroy notifications globally** (small delay + AX re-query
   before honoring any `kAXUIElementDestroyed`). Most general, but changes
   steady-state close latency for every window and is the riskiest.

Option 1 is the tightest fit to the evidence: the destroy path already has the
liveness fact in hand and already has a floating-only verification pattern to
mirror.

## Open questions

- Confirm the warm-launch hypothesis (does a run *with* `runtime-state.json`
  present avoid or merely reduce the wipe?).
- Decide whether the liveness gate should apply to *all* destroy notifications or
  only within a startup grace window — the trace only proves the pathology at
  cold start, and steady-state close latency should not regress.
- Miniaturize shares the same refcon/callback plumbing
  (`AppAXContext.swift:325`); confirm the gate does not accidentally swallow real
  minimize-driven removals.
