# Cold-Start Wipe Recurs After the Liveness Fix — CGS Space Events, Not AX Destroys; Only the Focused Pid Is Re-Admitted

Groom 2026-07-07: still applicable — open recurrence; not merged in Nehir `main` as of `201ca607`. The current Nehir source still routes CGS `.destroyed` / `spaceWindowDestroyed` through `handleCGSWindowDestroyed`, which passes `verifyWindowServerLiveness: false`, so the path still bypasses the `7a025b78` liveness gate that closed the AX-destroy path (see `completed/20260707-cold-start-spurious-ax-destroy-wipes-managed-windows.md`). An upstream OmniWM-history commit, `c836fbb0` ("Fix tabbed columns splitting: don't reap windows that left a space"), contains the same core fix direction for the old `Sources/OmniWM/...` path, but that change is not present in current `Sources/Nehir/Core/Controller/AXEventHandler.swift`; no `completed/`/`planned/` doc yet.

Follow-up (2026-07-07, later the same day the fix landed) to
`completed/20260707-cold-start-spurious-ax-destroy-wipes-managed-windows.md`.
A fresh 21-second cold-start runtime capture was taken on a build of `main`
at `654337a0` — which **includes** the liveness fix `7a025b78` ("Verify window
liveness before honoring a spurious AX destroy on cold start"); the capture
header prints `nehir v654337` in both the start and end snapshots, so this is
not a stale-binary artifact.

The capture shows the same cold-start wipe recurring **despite the fix**, and
it contains the evidence the previous captures lacked: the always-on raw AX
notification ring proves **no AX destroy notification was ever delivered**.
The wipe therefore entered through the CGS event path
(`spaceWindowDestroyed`/`windowClosed`), which the fix deliberately left
unverified. It also shows a recovery mode *worse* than pre-fix: instead of a
re-admission thrash that eventually settles, this run re-admits **only the two
windows of the one pid the user subsequently focused**; the other three
windows remain visible-but-unmanaged through the end of the capture, one of
them stranded at its offscreen parking position.

File:line references are against `main` at `654337a0` and will drift —
re-verify before implementing. The latest status check against `main` at
`201ca607` found the key CGS destroy call still ungated.

**Verdict: actionable, three findings.**

1. The wipe came through `handleCGSWindowDestroyed`, which passes
   `verifyWindowServerLiveness: false` — the new liveness gate is bypassed by
   design on this path. The `.destroyed` CGS event decodes from
   **`spaceWindowDestroyed`** — a *space-membership* removal, not window
   death — and nehir had just relocated all five windows across
   displays/spaces at admission, so the wipe is plausibly self-inflicted
   feedback (admission → cross-space move → `spaceWindowDestroyed` → treated
   as window death → removal).
2. The prior discovery's attribution of the wipe to macOS AX
   `kAXUIElementDestroyed` bursts is now in doubt: its "CGS not involved"
   evidence (`decodedEvents: 0`) came from a snapshot whose timing does not
   cover the wipe, and this capture positively excludes AX for an identical
   pathology.
3. After a wrongful wipe, the only recovery that demonstrably works is
   focus-driven (user activates the app). The post-removal pid reevaluation
   re-armed by `handleRemoved(token:)` produced no re-admission, and all its
   failure modes are silent.

## Topology / initial state (from the capture snapshot)

Two displays: `ID(1)` Built-in Retina `frame=(0, 0, 2056, 1329)` (main, has
notch), `ID(2)` DELL P2423D `frame=(-222, 1329, 2560, 1440)`. Cold launch:
`no-managed-windows`, `windows total=0`, `startedServices=false`,
`persistedDirty=true`, `consumedPersistedEntries=0`, interaction monitor
`ID(1)`, `displaySpacesMode=enabled`, SpaceTopology `notCaptured` at start
(→ `activeSpaces=2 knownSpaces=2` by the end).

Five regular (`activationPolicy=0`) windows visible at capture start, all
physically on the DELL (Cocoa frames spanning `y=-1410..0`), all reported by
AX (`axWindowsResult=0`, `axContainsWindow=true`):

| token | owner | WindowServer frame at start |
| --- | --- | --- |
| `W(28651/10428)` | Helium (YouTube tab) | `{442, -1410, 710, 1410}` |
| `W(28651/215)` | Helium (Workflow runs tab) | `{899, -1410, 1357, 1371}` |
| `W(67387/14885)` | Agterm | `{0, -1410, 900, 1410}` |
| `W(89691/1573)` | Code - Insiders | `{0, -1410, 426, 1410}` |
| `W(55316/351)` | Telegram | `{899, -1410, 1011, 1251}` |

As in the pre-fix captures, all five were admitted into the single interaction
workspace `25C405A0-…` on **display 1** — the rescan relocated every DELL
window onto the built-in display (the niri layout trace shows tiled targets
like `cur=14,7,1011,1251` on display 1 against `replacement=0,-1410,900,1410`
still on the DELL). This cross-display relocation is both a placement defect
in its own right *and* the suspected stimulus for the CGS destroy events
below.

## Observed failure sequence

Reconcile-event stream (`event=…`), timestamps at 1-second resolution:

```
T+1s (:26)  #1–#5    window_admitted context=startup_full_rescan  (all 5, mode=tiling)
            #6–#8    hidden_state_changed hidden=true             (3 windows parked offscreen)
            #9–#11   managed_focus_requested/confirmed  W(67387/14885)  (Agterm)
            #17–#23  window_admitted context=pid_reevaluation     (all 5 re-admitted in place)
            #25–#26  managed_focus_cancelled + window_removed phase=destroyed  W(55316/351)
            #27–#28  same                                          W(28651/10428)
            #29–#31  managed_focus_cancelled, focus_lease_changed
                     owner=window_close_focus_recovery, window_removed  W(67387/14885)
T+2s (:27)  #34–#36  managed_focus_requested/confirmed  W(28651/215)   (survivor takes focus)
            #40–#42  managed_focus_cancelled + lease re-armed + window_removed  W(28651/215)
            #43–#44  managed_focus_cancelled + window_removed      W(89691/1573)
                     ← ALL FIVE GONE, focused=nil
:27–:36     — nine seconds of silence: no admissions, no AX windows queries —
T+11s (:36) AXFocusedWindowChanged pid=28651   (user activates Helium)
            ax_windows_query pid=28651 newContext=false count=2 windowIds=[215, 10428]
            #45,#47  window_admitted context=pid_reevaluation  W(28651/215), W(28651/10428)
                     ← ONLY HELIUM EVER COMES BACK
T+22s (:47) capture ends
```

End state (`Runtime state at end`): `windows total=2 tiled=2` (both Helium),
and three **Visible Unmanaged WindowServer Windows**:

- Agterm `W(67387/14885)` at `{14, 83, 1011, 1251}` — abandoned at the tiled
  slot nehir had moved it to on display 1;
- Code `W(89691/1573)` at `{1039, 83, 1011, 1251}` — same;
- Telegram `W(55316/351)` at `{2055, 90, 1011, 1251}` — abandoned at its
  **offscreen parking slot** (the layout trace shows its parked target as
  `cur=2055,7` with `hidden:right`; display 1 is 2056 pt wide, so the window
  is effectively invisible and unreachable without Mission Control).

So the user-visible damage: three of five windows silently dropped from
tiling, all five relocated off their original display, one window parked
offscreen and orphaned there.

## The removals went through `handleRemoved(token:)` — fingerprint

Same fingerprint as the prior discovery, plus a counter cross-check:

- The removals interleave with `managed_focus_cancelled` and twice arm
  `focus_lease_changed owner=window_close_focus_recovery`, set only by
  `beginWindowCloseFocusRecovery`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1685`), reached from
  `handleRemoved(token:)` (`AXEventHandler.swift:1621`, `:1639`).
- `LayoutRefreshController` end counters show
  `RefreshReason.windowDestroyed: 5` requested — and `requestWindowRemoval`
  (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:828`) has
  exactly one caller: `handleRemoved(token:)` (`AXEventHandler.swift:1675`).
  Five removals, five window-removal refreshes.
- The rule-reevaluation un-manage branch
  (`Sources/Nehir/Core/Controller/WMController.swift:2970`) and app
  termination (`removeWindowsForApp`,
  `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3214`) bypass both the
  lease and `requestWindowRemoval`; all five pids were alive at capture end.

## AX destroy notifications are positively excluded this time

The raw AX notification ring records **every** window-observer notification
*before* the destroyed/miniaturized filter — the window-observer C callback's
first action is
`AppAXContext.recordRawNotification(name:pid:windowId:)`
(`Sources/Nehir/Core/Ax/AppAXContext.swift:936-941`), and the recorder is
always-on with a 256-entry cap
(`Sources/Nehir/Core/Ax/RawAXNotificationTrace.swift:41-47`).

The five windows *were* subscribed to destroy notifications: subscription
happens inside `getWindowsAsync` (`AppAXContext.swift:472-476` via
`addWindowNotifications`, which registers `kAXUIElementDestroyedNotification`,
`:353`), and the query recorder shows every pid's first query succeeding at
`T+1s`:

```
ax_windows_query pid=67387 newContext=true count=1 windowIds=[14885]
ax_windows_query pid=89691 newContext=true count=1 windowIds=[1573]
ax_windows_query pid=55316 newContext=true count=1 windowIds=[351]
ax_windows_query pid=28651 newContext=true count=2 windowIds=[215, 10428]
ax_window_count_mismatch pid=28651 ax=2 windowServer=3
```

Yet the ring's **entire content** for the 21-second capture is three
app-level entries and nothing else:

```
ax=AXFocusedWindowChanged pid=67387 window=nil   (:26)
ax=AXFocusedWindowChanged pid=28651 window=nil   (:36)
ax=AXFocusedWindowChanged pid=28651 window=nil   (:40)
```

Three entries in a 256-slot ring — no eviction, no reset. If macOS had
delivered `kAXUIElementDestroyed` for any of the five windows, it would be
here. It is not. `AppAXContext.onWindowDestroyed` →
`handleRemoved(pid:winId:)` (`ServiceLifecycleManager.swift:89-91`) — the
path the liveness fix guards — **never fired**.

## By elimination: the CGS destroy path, which bypasses the gate by design

`handleRemoved(token:)` is reachable from exactly four places:

1. `processPreparedDestroy` (`AXEventHandler.swift:4269`) — terminal step of
   `handleWindowDestroyed`, fed by either the AX destroy callback
   (`verifyWindowServerLiveness: true`, `:1618`) or
   `handleCGSWindowDestroyed` (`verifyWindowServerLiveness: false`, `:1226`).
2. The deferred destroy-liveness task (`:1516`) — only exists after an AX
   destroy was gated.
3. The post-create lifecycle verification task (`:1485`) — only scheduled
   from the windowCreate admission path for candidates with
   `requiresPostCreateLifecycleVerification` (floating-only); these windows
   were admitted via `startup_full_rescan`/`pid_reevaluation` as `tiling`.

With the AX callback excluded by the ring, (2) and (3) are unreachable and
(1) can only have been fed by **`handleCGSWindowDestroyed`** — where the
liveness gate inserted by `7a025b78` is explicitly disabled:

```swift
// AXEventHandler.swift:1221-1227
private func handleCGSWindowDestroyed(windowId: UInt32) {
    ...
    handleWindowDestroyed(windowId: windowId, pidHint: nil, verifyWindowServerLiveness: false)
}
```

### What those CGS events actually are

`cgsEventObserver(_:didReceive:)` routes two raw event types here
(`AXEventHandler.swift:642-648`):

- `.destroyed` ← **`spaceWindowDestroyed`**
  (`Sources/Nehir/Core/SkyLight/CGSEventObserver.swift:321-327`) — the window
  was removed **from a space**. This fires when a window moves between
  spaces; it does not mean the window ceased to exist. The handler discards
  the `spaceId` payload entirely (`case let .destroyed(windowId, _)`).
- `.closed` ← `windowClosed` (`CGSEventObserver.swift:329-333`).

And nehir had, in the same second, relocated all five windows from the DELL's
space to display 1's space (`displaySpacesMode=enabled`; every admitted
window's frame moved from `y=-1410..0` on the DELL to display-1 coordinates).
A `spaceWindowDestroyed` for the *old* space is the expected WindowServer
reaction to nehir's own move — making the cold-start wipe self-inflicted:
**admit → move across spaces → receive `spaceWindowDestroyed` → treat as
window death (unverified) → remove**. Steady-state cross-space moves
presumably survive because other machinery masks the event
(`isTransferringWindow`, own-frame-write suppression), but nothing masks the
startup rescan's bulk relocation.

The capture cannot show the individual CGS events (only cumulative counters:
`decodedEvents: 422, malformedPayloadDrops: 24` after 21 s including heavy
gesture traffic), so the space-move stimulus is a mechanism-level hypothesis;
the *path* (CGS, unverified) is established by elimination.

### Consequence for the prior discovery

`completed/20260707-cold-start-spurious-ax-destroy-wipes-managed-windows.md`
excluded CGS because "the capture shows `CGSEventObserver … decodedEvents:
0`" — but the start-snapshot counters are always zero (the observer starts
with services, after the snapshot), so that exclusion was untimed. Its
captures pre-date the raw-ring check performed here. Given this capture shows
an identical pathology with AX positively excluded, the pre-fix wipes were
plausibly CGS-driven all along — which would also explain why gating only the
AX path did not eliminate the symptom.

## Why recovery was focus-only this time

`handleRemoved(token:)` ends by re-arming a pid-scoped rule reevaluation
(`AXEventHandler.swift:1682`):

```swift
scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
```

In the pre-fix captures this produced a visible re-admit/destroy thrash. In
this capture it produced **nothing**: the AX windows-query recorder — which
logs every *completed* `getWindowsAsync()` call
(`AppAXContext.swift:505-511`, no dedupe) — shows no query for pids 55316,
89691, or 67387 after their windows were removed, for the remaining ~20
seconds of the capture.

Every failure mode on this path is silent, so the trace cannot say which one
hit:

- `scheduleWindowRuleReevaluationIfNeeded` (`AXEventHandler.swift:666-674`)
  no-ops without trace when `windowRuleEngine.needsWindowReevaluation` is
  false (it was evidently true — pid_reevaluation admissions occurred — but
  nothing records the gate decision).
- The coalescing task cancels its predecessor on every schedule
  (`AXEventHandler.swift:676-684`) and its body never re-checks
  `Task.isCancelled` after the sleep, so cancelled instances still consume
  `pendingWindowRuleReevaluationTargets`; races here are invisible.
- `reevaluateWindowRules`'s `.pid` branch (`WMController.swift:2898-2921`)
  relies entirely on `axManager.windowsForApp(app)` once the pid has no
  managed entries left (post-wipe it has none). `windowsForApp`
  (`Sources/Nehir/Core/Ax/AXManager.swift:429-441`) swallows every failure —
  `shouldTrack` false, `AppAXContext.getOrCreate` nil/throw, and notably a
  `withTimeoutOrNil(seconds: perAppTimeout)` **timeout** — into a bare `[]`
  with no trace record, because the query recorder is appended only at the
  successful tail of `getWindowsAsync()`; a timed-out or thrown query logs
  nothing.
- An empty `tokensToReevaluate` returns `.none` silently
  (`WMController.swift:2922-2929`).

The one recovery that worked required the user: `AXFocusedWindowChanged
pid=28651` at `:36` drove a pid-28651 reevaluation whose `getWindowsAsync`
succeeded (`newContext=false` — Helium's `AppAXContext` survived the wipe, so
context teardown does not explain the other pids' silence). Both Helium
windows were re-admitted within the same second. Agterm, Code, and Telegram
were never activated during the capture and never came back.

## Is the trace sufficient?

**Sufficient for:** proving the fixed build still wipes (build id in header +
removal fingerprint), positively excluding the AX-observer origin (raw ring),
and therefore implicating the CGS path by elimination; and demonstrating the
focus-only recovery and the offscreen-stranded Telegram window.

**Insufficient for:** directly observing the CGS events (type, windowId,
spaceId, timing) that drove the wipe, and for explaining the silent failure
of post-removal pid reevaluation. Concrete gaps, prioritized:

1. **Per-event CGS decode trace.** Record each decoded
   `created/destroyed/closed` event (type, windowId, spaceId, timestamp) in a
   bounded ring alongside the existing counters
   (`CGSEventObserver.swift:304-333`). This alone would have made this
   capture decisive and would confirm or kill the space-move-stimulus
   hypothesis.
2. **Destroy-source and gate-decision emission.** `handleWindowDestroyed`
   (`AXEventHandler.swift:4180`) should emit per event: origin (AX vs CGS
   `.destroyed` vs CGS `.closed`), `verifyWindowServerLiveness`, and the raw
   `resolveWindowInfo(windowId)` outcome at gate time.
3. **AX windows-query failure records.** Add a `queryFailed(pid:, reason:)`
   record where `windowsForApp` swallows errors (`AXManager.swift:433-440`)
   and where `getWindowsAsync` bails before its success-tail logging (thread
   gone `AppAXContext.swift:402`, timeout/cancellation unwind). Without this,
   "no query logged" is forever ambiguous between "never scheduled" and "ran
   and failed silently".
4. **Reevaluation-scheduling visibility.** Emit when
   `scheduleWindowRuleReevaluationIfNeeded` accepts/drops targets and when
   `reevaluateWindowRules` resolves zero tokens for a `.pid` target.
5. **Removal reason on `window_removed`.** The event's source field is
   dropped from the summary (`Sources/Nehir/Core/Reconcile/WMEvent.swift:208-209`)
   and is `.workspaceManager` for every caller
   (`WorkspaceManager.swift:3231-3241`); thread a real reason (ax-destroy /
   cgs-space-destroy / cgs-closed / liveness-confirmed / rule-unmanage /
   rescan-missing) through `removeWindow`.
6. **Deferred-verification outcome emission** in
   `scheduleDestroyLivenessVerification` (`AXEventHandler.swift:1495`):
   cancelled / entry-gone / alive-kept / confirmed-dead-removed. (Unused in
   this capture, but needed the day AX destroys really do fire.)

## Fix directions (for the plan stage)

1. **Verify liveness on the CGS destroy path too.** Flip
   `handleCGSWindowDestroyed` to `verifyWindowServerLiveness: true` (or a
   CGS-specific equivalent). A `spaceWindowDestroyed` whose window still
   exists in the WindowServer must not tear the window down. The gate and the
   deferred re-check machinery from `7a025b78` already exist; this is
   plumbing, not new mechanism.
2. **Respect `spaceWindowDestroyed` semantics.** The event means "left this
   space", and the handler throws the `spaceId` away
   (`AXEventHandler.swift:642-644`). At minimum, a window that nehir itself
   is relocating (startup rescan bulk move, workspace transfer) should have
   its space-destroy events suppressed the same way own frame writes are.
3. **Harden the nil-oracle branch of the existing gate.** When
   `resolveWindowInfo` returns nil during startup churn, defer + re-check
   instead of falling through to immediate removal
   (`AXEventHandler.swift:4225` — the comparison is false on a nil oracle,
   and control proceeds to removal).
4. **Make post-wipe recovery not depend on user focus.** On removal of the
   last managed window of a pid whose `NSRunningApplication` is still alive,
   schedule a bounded re-enumeration retry (cf. the stabilization-retry
   machinery at `AXEventHandler.swift:5122-5140`) instead of relying on the
   silent one-shot reevaluation re-arm.
5. **Re-examine the admission placement defect** (all DELL windows admitted
   into display 1's workspace on cold start): it multiplies the blast radius
   of any wipe (windows end up moved *and* dropped) and is likely the
   stimulus for the destroy events themselves.
