# Discovery: ChatGPT activation not tiled — recent-app-activation exemption expires before the first real admission attempt

Status: confirmed — runtime evidence and source mechanism both verified against
the build that produced the capture (`nehir vd953d4`, i.e. main at `d953d4d3`
"Float zero-frame Gecko transient dialogs that the first #142 fix still tiled",
which contains both the user-activation exemption `151f4e3a` and the admission
diagnostics `0f785212`).

This is a **recurrence of the Slack trap**
(`discovery/20260703-user-activated-slack-suppressed-as-stale-under-nonmanaged-focus.md`)
**with the shipped fix present and working as coded**. The exemption landed in
`151f4e3a` records user intent in `recentAppActivationByPid` with a **10 s
TTL** — but in this capture the first (and only) focused-admission attempt for
the activated window happened **more than 10 s after** the
`workspaceDidActivateApplication` event, so `hasRecentAppActivation` was
already false and the guard suppressed the window as a stale surface again.
The exemption assumes the admission attempt follows the activation promptly;
this capture shows a concrete, reproducible path where it does not.

## Summary of the failure

Runtime capture from 2026-07-07, single built-in display
(`frame=(0,0,2056,1329)`, notch, Dock on the **right** edge —
`Dock Edge Shield monitor=1 edge=right frame=(1977,7 79x1251)`), one visible
workspace `36F43FE3-AF1E-44D6-B065-F2332CB49B90` with nine managed tiling
windows (Helium 215/10428, Telegram 351, Agterm 14885, pid 72005 window 7619,
VS Code Insiders 18055/19034/19045/19099).

ChatGPT (pid 41491, bundleId `com.openai.chat`, windowId 1815 — a long-lived
pre-existing window, its id is far below the session's current ids around
19100+) is running but **untracked** for the whole capture. The user activates
it; nehir decides to manage it, then vetoes its own decision:

```text
activation_source_observed pid=41491 source=workspaceDidActivateApplication
non_managed_fallback_entered pid=41491 source=workspaceDidActivateApplication
activation_source_observed pid=41491 source=focusedWindowChanged
window_decision token=WindowToken(pid: 41491, windowId: 1815) context=focused_admission
  existingMode=nil disposition=managed source=heuristic outcome=trackedTiling
  layout=fallbackLayout bundleId=com.openai.chat axRole=AXWindow
  axSubrole=AXStandardWindow wsLevel=0 wsFrame=(873.0,106.0,1011.0,1251.0)
create_placement_resolved token=WindowToken(pid: 41491, windowId: 1815)
  workspace=36F43FE3-AF1E-44D6-B065-F2332CB49B90
  frame_monitor=Optional(Nehir.Monitor.ID(displayId: 1))
  context_source=ax_focused_admission_synthesized recent_pid_workspace=nil
unrequested_admission_nonmanaged_focus_decision token=WindowToken(pid: 41491, windowId: 1815)
  suppressed=true reason=stale_unrequested_nonmanaged_focus
  context_source=ax_focused_admission_synthesized recent_pid_workspace=nil
  explicit_workspace_assignment=false active_managed_request_token=nil
window_decision_suppressed token=WindowToken(pid: 41491, windowId: 1815)
  reason=stale_unrequested_nonmanaged_focus
focused_admission_guard token=WindowToken(pid: 41491, windowId: 1815)
  workspace=36F43FE3-AF1E-44D6-B065-F2332CB49B90 source=focusedWindowChanged
  outcome=suppressed reason=unrequested_nonmanaged_focus_guard
  suppressedByUnrequestedGuard=true structuralWorkspaceMatch=false mode=tiling
  context_source=ax_focused_admission_synthesized recent_pid_workspace=nil
```

These are the **last entries in the create-focus trace** before the capture
ended at `09:20:23Z`. End state: the nine managed windows are unchanged and
ChatGPT sits in "Visible Unmanaged WindowServer Windows", healthy and fully
AX-resolvable, floating over the layout:

```text
windowId=1815 pid=41491 owner=ChatGPT bundleId=com.openai.chat title=ChatGPT
  frame={{873.0, 106.0}, {1011.0, 1251.0}} axWindowsResult=0 axWindowsCount=1
  axContainsWindow=true
```

Non-managed focus was active continuously through the tail of the capture
(`non_managed=true` on every focus-plan record from `09:19:25Z` to the final
`focus_lease_changed … focused=nil,non_managed=true` at `09:20:23Z`), so the
guard was armed the whole time.

## Why the shipped exemption did not fire

The suppression reason proves the timing. In
`shouldSuppressUnrequestedAdmissionDuringNonManagedFocus`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:1080`) the exemption
chain is: explicit workspace assignment → active managed request →
`cgs_created` context → `recentPidWorkspaceId` → **`hasRecentAppActivation`**
(`AXEventHandler.swift:1149`) → only then `stale_unrequested_nonmanaged_focus`
(`AXEventHandler.swift:1164`). And `recordRecentAppActivation` is called
unconditionally right after the `activation_source_observed` emit whenever
`source == .workspaceDidActivateApplication`
(`AXEventHandler.swift:2687-2691`). The trace contains that emit for
pid 41491, so the intent **was recorded**. The only way the decision can still
read `stale_unrequested_nonmanaged_focus` is that the entry was pruned:
`recentAppActivationTTL = 10` seconds (`AXEventHandler.swift:738`, prune on
read at `:5200-5205`; the only other removal paths are app termination and
full handler cleanup, neither of which occurred — ChatGPT is alive at capture
end).

**Therefore the `focusedWindowChanged` admission attempt ran more than 10
seconds after the `workspaceDidActivateApplication` for the same pid.** The
user's switch to ChatGPT was real and was recorded; it just aged out before
anything consumed it.

## Why nothing attempted admission within the TTL

Three independent gaps compound:

1. **The activation itself never reached the admission pipeline.** The
   `workspaceDidActivateApplication` handling produced
   `non_managed_fallback_entered` with **no** `window_decision` and **no**
   `prepare_create_rejected` for pid 41491 — meaning
   `resolveFocusedAXWindowRef(pid:)` returned nil and `handleAppActivation`
   took the `handleMissingFocusedWindow` branch
   (`AXEventHandler.swift:2733-2741`, body at `:5861`). That branch enters
   non-managed fallback, **cancels** any activation retry
   (`cancelActivationRetry()` at `:5904`), schedules nothing, and does not
   warm the app's AX context. The nil focused window at activation time is
   expected for a window being revealed from a hidden/minimized state — the
   direct `kAXFocusedWindowAttribute` query (`AXEventHandler.swift:6208-6217`)
   races the app's own unhide.

2. **No `AXFocusedWindowChanged` ever arrives for a never-tracked app.** The
   focus observer is registered only when an `AppAXContext` exists for the
   pid (`Sources/Nehir/Core/Ax/AppAXContext.swift:209-220`), and contexts are
   created lazily — via full-rescan enumeration or via
   `scheduleAXContextWarmup`, whose only call sites are the create-candidate
   tracking paths (`AXEventHandler.swift:1606`, `:1669`). ChatGPT was never
   tracked this session, so no context, no observer: the capture's AX
   notification trace contains **zero** entries for pid 41491 while showing
   normal traffic for every tracked pid (28651, 82494, 89691, …). In the
   original Slack captures this was the retry channel that produced the
   admission attempt "moments" after activation; here that channel simply
   does not exist.

3. **The eventual admission attempt was command-driven, minutes-to-tens-of-
   seconds later.** The suppressed `focused_admission` was synthesized by the
   frontmost-probe in `managedCommandTarget()`
   (`Sources/Nehir/Core/Controller/WMController.swift:1917-1930`): during
   non-managed focus, resolving a WM command target for an untracked
   frontmost pid calls
   `handleAppActivation(pid:, source: .focusedWindowChanged, origin: .probe)`.
   That is the only remaining path that could produce this admission (no AX
   notification existed per point 2, and the ring shows exactly one
   `focusedWindowChanged` activation for the pid). So the window sat
   frontmost-but-unmanaged until the user issued some WM command — plausibly
   the trace-capture stop itself at `09:20:23Z` — and by then the 10 s intent
   window had lapsed.

Supporting timeline from the timestamped ring buffers: full rescans triggered
by Dock-reveal topology churn re-admitted exactly the nine managed windows at
`09:19:25Z`–`09:19:28Z` (`window_admitted … context=startup_full_rescan`,
interleaved with `topology_changed displays=1` and the visible frame narrowing
from 2056 to 1978 as the right-edge Dock shield appeared) — ChatGPT was not
enumerated by any of them, so its window was still not AX-visible then. The
ghostty quick-terminal events that immediately precede the ChatGPT sequence in
the create-focus ring correlate with `AXUIElementDestroyed pid=82494
window=5915` at `09:19:26Z`/`09:19:28Z`. The ChatGPT activation therefore
happened in the window `09:19:28Z`–`09:20:12Z`, and the suppressed probe
admission at ≈`09:20:22Z`, right before the capture ended.

## How the window became untracked in the first place

Same "ingredient 1" as the Slack discovery: a long-lived window (stable
windowId 1815) that is not AX-enumerable at rescan time — hidden, minimized,
or in the app's window-kept-alive-on-close state — enters the session with no
entry. The rescans at `09:19:25Z`–`09:19:28Z` demonstrably skipped it, and it
was visible on screen by capture end, i.e. the user's activation revealed it.
The exact hide mechanism is not recoverable from this capture
(`hiddenAppPIDs=0` at both snapshots only proves it was not Cmd-H hidden *at
snapshot time*).

## Relationship to prior findings

- `discovery/20260703-user-activated-slack-suppressed-as-stale-under-nonmanaged-focus.md`
  — the original trap. Marked resolved by the `151f4e3a` exemption. This
  capture shows the exemption is **necessary but not sufficient**: it bridges
  activation → admission only when the admission attempt happens within 10 s,
  which held in all five Slack/Teams captures (AX focus-change notifications
  retried the admission within a second) but fails whenever the app has no AX
  context and the activation-time focused-window query returns nil.
- `discovery/20260703-unrequested-admission-guard-anatomy-and-hazards.md` —
  hazard 1 predicted a *missing* recording (focus-lease denial); hazard 4
  noted there is no re-evaluation on disarm. This capture is a **new hazard**
  in the same family: the intent is recorded but **expires unconsumed**
  because no admission attempt exists inside the TTL. The structural loop
  from the anatomy doc then closes as before — the suppressed window's own
  focus keeps `isNonManagedFocusActive` true, so later probes keep failing.

## Fix options

**A. Close the missing-focused-window gap (recommended).** In
`handleMissingFocusedWindow` (`AXEventHandler.swift:5861`), when the pid has a
recent app activation and no tracked entry, do not silently give up: warm the
AX context (`scheduleAXContextWarmup`) and schedule a short admission retry
for the pid (the activation-retry machinery at `AXEventHandler.swift:2522`,
`:2573` already exists for managed requests). The retry re-runs
`handleAppActivation`; once the focused window resolves — typically a few
hundred ms after unhide — the admission lands inside the existing 10 s TTL and
the shipped exemption works as designed. This fixes the cause (no attempt
within the TTL) without widening the guard at all.

**B. Consume-on-attempt instead of wall-clock-only expiry.** Keep the 10 s TTL
for the anti-"random app pulled in" property, but make the intent durable
until *consumed*: if `non_managed_fallback_entered` for pid P follows a
recorded activation of P and **no focused-admission attempt for P has run
yet**, refresh or retain the entry. The signal "we entered non-managed
fallback because of this very activation and never even evaluated the window"
is exactly the case the exemption was built for. Slightly widens the window
for programmatic `activate()` calls whose windows appear late; the guard's
other conditions (heuristic must want to manage, AX must report a standard
window) still apply.

**C. Treat command-probe admissions as user intent.** The probe in
`managedCommandTarget()` (`WMController.swift:1917-1930`) only runs while the
user is issuing an explicit WM command at the frontmost app. An admission
synthesized by that probe (`origin == .probe` reaching
`admitFocusedWindowBeforeNonManagedFallback`) is arguably never "a random
stale surface discovered while unmanaged focus is active" — the user is
actively commanding that app. Exempting probe-origin admissions (new traced
reason, e.g. `user_command_probe`) would also give users a self-service
recovery: any WM command aimed at the stuck window would admit it. Needs care
that background/automation callers of `managedCommandTarget()` don't ride the
same exemption.

A alone fixes this capture's sequence; C additionally converts the current
dead-end ("every command on the stuck window silently no-ops") into recovery.
B is the most principled but touches the guard's trust model.

## Validation sketch

1. Reproduce ingredient 1: have the target app (ChatGPT or any app that keeps
   its window alive when closed/hidden) managed, hide it, restart nehir so the
   rescan skips it. Confirm no entry (`Visible Unmanaged` after reveal).
2. Arm the guard (ghostty quick-terminal recipe from the Slack discovery) and
   activate the target app from the Dock. **Wait more than 10 seconds without
   touching anything**, then issue any WM command (or stop a trace capture)
   with the window frontmost.
   - Before fix: `window_decision … outcome=trackedTiling` +
     `unrequested_admission_nonmanaged_focus_decision suppressed=true
     reason=stale_unrequested_nonmanaged_focus`, window stays unmanaged.
   - After fix A: an admission retry fires within seconds of the activation
     itself; the decision records `reason=recent_app_activation
     suppressed=false` and the token appears under Managed Windows.
3. Regression: with the guard armed, a background app programmatically
   surfacing a window without user activation must still be suppressed with
   `stale_unrequested_nonmanaged_focus`.
4. Regression: the fast path from the Slack fix (activation whose AX focused
   window resolves immediately) must keep admitting via
   `reason=recent_app_activation`.
