# App activation with a nil AX focused window never reveals the app's managed window

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned.
**Symptom:** Clicking a notification (observed with Telegram, `ru.keepcoder.Telegram`)
activates the app but does **not** reveal/scroll its managed window into view.
The window stays parked off-screen; keyboard focus stays on the previously
focused window (a browser). No `reveal_decision` / `focus_reality` trace is
emitted for the target window, because the managed focus path is never entered.
**Desired behavior:** a genuine user app-switch (Dock, notification click,
launcher `activate()`, Cmd-Tab) that lands on an app whose macOS focused-window
is momentarily `nil` should still reveal that app's managed window when there is
a single unambiguous candidate, instead of silently dropping to non-managed
focus.

All source references were verified against the main Nehir source tree (HEAD
`de23c80c`, "Add reference to AGENTS.md in CLAUDE.md"; behavior introduced by
`06c0bf4e`, "Reveal a same-app focus switch that lands on a window on an inactive
workspace") on 2026-07-06. Re-verify before editing; line numbers drift.

## Evidence (inlined, machine-independent)

Topology at capture: two displays. Workspace `8D4FDA7D…` is active on display 1
and holds the Telegram window. The Telegram app is `pid 55316`, managed window
`windowId 351`, currently **parked off-screen right** — the reconcile snapshot
shows it as:

```
WindowToken(pid: 55316, windowId: 351) ... mode=tiling phase=offscreen
    hidden=layoutTransient(right) liveAXFrame={{2055.0, 7.0}, {1011.0, 1251.0}}
    observedVisible=false observedFocused=false
```

i.e. it is a managed tiling window on the *active* workspace, scrolled out of
the viewport (column `c6`, `x=2055`, off the right edge of the 2056-wide
display).

The user clicks a Telegram notification. macOS activates the app. The runtime
observes both activation signals for `pid 55316`:

```
activation_source_observed pid=55316 source=workspaceDidActivateApplication
activation_source_observed pid=55316 source=focusedWindowChanged
```

but the AX focused-window notification carries **no window**:

```
ax=AXFocusedWindowChanged pid=55316 window=nil
```

After this, **no `reveal_decision` and no `focus_reality`** record is emitted for
token `55316:351` (every working focus in the same session emits a paired
`reveal_decision` + `focus_reality`; Telegram's activation produces only
`activation_source_observed` and stops). The end state confirms nothing was
revealed: focus is still on the browser window (`focused=WindowToken(pid: 28651,
windowId: 6730)`, `focus-lease=native_app_switch`, `non-managed-focus=true`) and
`55316:351` is still `phase=offscreen hidden=layoutTransient(right)`.

## TL;DR (root cause, inline)

The activation entry point is `handleAppActivation(pid:source:origin:)`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:1983`). It records
`activationSourceObserved`, then resolves the app's focused AX window:

```swift
let axRef = resolveFocusedAXWindowRef(pid: pid)          // :2029
...
guard let axRef else {
    handleMissingFocusedWindow(                          // :2052
        pid: pid, source: source, origin: origin,
        requestDisposition: requestDisposition
    )
    return
}
```

`resolveFocusedAXWindowRef(pid:)` (`:5201`) → `resolveFocusedWindowValue(pid:)`
(`:5189`) is just:

```swift
let appElement = AXUIElementCreateApplication(pid)
var focusedWindow: CFTypeRef?
let result = AXUIElementCopyAttributeValue(
    appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
guard result == .success else { return nil }
```

When an app is activated via a notification (or before it has surfaced/keyed a
window), `kAXFocusedWindowAttribute` returns no window — exactly the observed
`AXFocusedWindowChanged pid=55316 window=nil`. So `axRef == nil` and control goes
to `handleMissingFocusedWindow`.

`handleMissingFocusedWindow(pid:source:origin:requestDisposition:)`
(`:4835-4894`) only does something useful when there is a **Nehir-initiated
pending managed request** for this pid:

```swift
switch requestDisposition {
case let .matchesActiveRequest(request),
     let .conflictsWithPendingRequest(request):
    ... continueManagedFocusRequest(...) / clearManagedFocusState(...)
    return
case .unrelatedNoRequest:
    break                                                // <-- Telegram lands here
}
// ... falls straight through to:
armWindowCloseFocusRecoveryForFocusedWindowLossIfNeeded(...)
cancelActivationRetry()                                  // :4877 — no retry armed
_ = controller.workspaceManager.enterNonManagedFocus(
    appFullscreen: fallbackFullscreen,
    preserveFocusedToken: false)                         // :4881
recordNiriCreateFocusTrace(.init(kind: .nonManagedFallbackEntered(...)))
```

For an external app switch there is no pending managed request, so
`requestDisposition == .unrelatedNoRequest`
(`activationRequestDisposition(for:token:activeRequest:)`, `:4907-4920`, returns
`.unrelatedNoRequest` when `activeRequest == nil`). The function then:

1. **never consults `workspaceManager.entries(forPid:)`** to discover that this
   app *does* own a managed window (`55316:351`), and
2. **cancels rather than schedules** an activation retry (`:4877`), so even
   though Telegram will populate its `AXFocusedWindow` a beat later, nothing
   re-drives the activation.

The reveal itself only ever happens on the branch where a window token *is*
resolved: `handleAppActivation` → `if let entry = ...entry(for: token)` →
`handleManagedAppActivation(entry:isWorkspaceActive:...)` (`:2166`, and again at
`:2263`), and that path is what emits `reveal_decision` / `focus_reality`. With a
nil focused window we never reach it, so the off-screen managed window is never
scrolled into view.

**In one line:** an app-level activation whose `kAXFocusedWindowAttribute` is
transiently `nil` and has no pending managed request falls into the
non-managed-focus fallback without ever checking whether the activated app owns a
single managed window to reveal.

## Fix shape

In `handleMissingFocusedWindow`, for the `.unrelatedNoRequest` case on a genuine
user app switch, resolve a **single unambiguous managed candidate** for `pid` and
route it into the existing managed reveal path
(`handleManagedAppActivation(entry:isWorkspaceActive:appFullscreen:source:confirmRequest:origin:)`,
`:2482`) before falling back to non-managed focus. If no unambiguous candidate
exists, keep today's non-managed fallback unchanged.

The candidate resolver already exists in spirit: `nativeFullscreenOriginCandidate(for:activeWorkspaceId:)`
(`:2990-3027`) resolves exactly one eligible managed window for a pid using an
`eligible(_:)` filter (`entry.mode == .tiling`, active-workspace match,
non-scratchpad, `layoutReason == .standard`, no native-fullscreen record), a
prioritized `focusedCandidates` list (`confirmedManagedFocusToken`,
`preferredWorkspaceFocusToken`, `rememberedTiledFocusToken`), then a
single-`samePidEntries` fallback (`guard samePidEntries.count == 1`). The new
resolver should mirror this shape but key off `pid` alone (there is no incoming
token to exclude).

Gating (deliberately conservative — only act on real user intent):

- Only when `source == .workspaceDidActivateApplication` (a genuine app switch;
  `.focusedWindowChanged` is window-level churn and must stay in the fallback).
- Only when `origin == .external` (the OS-observed activation, not an internal
  probe/retry re-entry).
- Only when exactly one eligible candidate resolves. Multiple candidates → do
  **not** guess; keep non-managed fallback. (Matches the `count == 1` discipline
  already used at `:3025`.)

This reuses the existing reveal/scroll machinery, so both the "off-screen on the
active workspace" case (the Telegram capture) and the "on an inactive workspace"
case are handled by whatever `handleManagedAppActivation` already does for a
resolved token — no new reveal logic.

## Scope

### Files to change

1. `Sources/Nehir/Core/Controller/AXEventHandler.swift`
   - **Add** a private resolver, e.g.
     `singleManagedRevealCandidate(forPid pid: pid_t) -> WindowModel.Entry?`,
     modeled on `nativeFullscreenOriginCandidate(for:activeWorkspaceId:)`
     (`:2990-3027`) but keyed on `pid` with no token to exclude. Compute
     `activeWorkspaceId` from the interaction workspace
     (`controller.interactionWorkspace()?.id`, as used elsewhere in this file),
     reuse the same `eligible(_:)` predicate (`entry.mode == .tiling`,
     `activeWorkspaceId.map { entry.workspaceId == $0 } ?? true`, non-scratchpad,
     `hiddenState?.isScratchpad != true`, `layoutReason == .standard`,
     `nativeFullscreenRecord == nil`), the same prioritized `focusedCandidates`,
     and the same `samePidEntries.count == 1` single-window fallback.
   - **`handleMissingFocusedWindow(pid:source:origin:requestDisposition:)`
     (`:4835`).** In the `case .unrelatedNoRequest:` arm (currently a bare
     `break`, `:4863-4864`), before the fall-through to close-recovery +
     `enterNonManagedFocus`, attempt the managed reveal:
     ```swift
     case .unrelatedNoRequest:
         if source == .workspaceDidActivateApplication,
            origin == .external,
            let entry = singleManagedRevealCandidate(forPid: pid) {
             let targetMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)
             let isWorkspaceActive = targetMonitor.map { monitor in
                 controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
             } ?? false
             endWindowCloseFocusRecovery(matching: entry.workspaceId)
             handleManagedAppActivation(
                 entry: entry,
                 isWorkspaceActive: isWorkspaceActive,
                 appFullscreen: false,
                 source: source,
                 confirmRequest: true,
                 origin: origin
             )
             return
         }
     ```
     Compute `isWorkspaceActive` exactly as the resolved-token branch does
     (`:2222-2225` / `:2186-2189`). Fall through to the existing non-managed
     fallback unchanged when the guard fails.

### Non-goals / do-not-touch fences

- **Do not touch the `.matchesActiveRequest` / `.conflictsWithPendingRequest`
  arms** of `handleMissingFocusedWindow` (`:4843-4862`). Pending-request recovery
  is a separate contract (dropdown / quick-terminal close paths) and is out of
  scope. Only the `.unrelatedNoRequest` arm gains behavior.
- **Do not change `resolveFocusedAXWindowRef` / `resolveFocusedWindowValue`**
  (`:5189-5213`). The nil result is legitimate (the app genuinely has no keyed
  window yet); the fix is in how the caller reacts, not in forcing a window out
  of AX.
- **Do not act on `.focusedWindowChanged`.** Window-level focus churn with a nil
  window must keep dropping to the existing fallback; only a
  `workspaceDidActivateApplication` app switch is treated as reveal intent.
- **Do not add a new reveal/scroll primitive.** Route through the existing
  `handleManagedAppActivation` so the reveal, focus-confirm, and
  `reveal_decision` / `focus_reality` tracing are identical to the resolved-token
  path.
- **Do not guess among multiple candidates.** If `entries(forPid:)` yields more
  than one eligible managed window, keep the non-managed fallback (a nil focused
  window gives us no way to disambiguate which window the user meant).
- **Do not change `recordRecentAppActivation` / lease handling** in
  `handleAppActivation` (`:2007-2044`); those already run before the nil-window
  branch and are unaffected.

## Exact implementation plan

Phased; each phase is independently buildable.

### Phase 1 — Add the candidate resolver (no behavior change)

1. Add `singleManagedRevealCandidate(forPid:)` to `AXEventHandler.swift`, modeled
   on `nativeFullscreenOriginCandidate` (`:2990`). It is not yet called from
   anywhere, so runtime behavior is unchanged.
2. **Gate:** `swift build` green; add the resolver's unit tests (below) and run
   them green.

### Phase 2 — Reveal on nil-focused-window app switch (behavior change)

1. Wire the resolver into the `.unrelatedNoRequest` arm of
   `handleMissingFocusedWindow` as specified above.
2. Confirm the fallback path is unchanged when the guard fails (source is
   `.focusedWindowChanged`, origin is not `.external`, or the resolver returns
   nil / multiple).
3. **Gate:** the AXEventHandler focus tests below green; existing focus tests
   green.

## Tests

Prefer the existing focus/activation suite. Grep first:
`rg -l "handleAppActivation|handleMissingFocusedWindow|nonManagedFallback" Tests/`.
`Tests/NehirTests/AXEventHandlerTests.swift` and
`Tests/NehirTests/WMControllerFocusTests.swift` already exercise activation with
the provider seams (`focusedWindowRefProvider`, `focusedWindowValueProvider`,
`bundleIdProvider`) — reuse those to synthesize a nil focused window (no live
AX/SkyLight).

### `Tests/NehirTests/AXEventHandlerTests.swift` (add)

1. `appActivationWithNilFocusedWindowRevealsSingleManagedWindow` — set up one
   managed tiling window `W` for `pid P` on the **active** workspace, off-screen
   (parked). Configure the focused-window provider to return nil for `P`. Call
   `handleAppActivation(pid: P, source: .workspaceDidActivateApplication,
   origin: .external)`. Assert the managed reveal path runs for `W`
   (`confirmedManagedFocusToken == W.token` / a `focusConfirmed` +
   `reveal_decision` trace for `W`), **not** `nonManagedFallbackEntered`.
2. `appActivationWithNilFocusedWindowFallsBackWhenMultipleManagedWindows` — two
   eligible managed windows for `pid P` on the active workspace; nil focused
   window. Assert the resolver returns nil (ambiguous) and the existing
   `nonManagedFallbackEntered` fallback runs (regression guard against guessing).
3. `focusedWindowChangedWithNilWindowStillFallsBack` — same single-window setup
   as #1 but `source: .focusedWindowChanged`. Assert the reveal path does **not**
   run and `nonManagedFallbackEntered` fires (window-level churn must not reveal).
4. `appActivationWithNilFocusedWindowNoManagedWindowFallsBack` — `pid P` owns no
   managed window; nil focused window; `workspaceDidActivateApplication`. Assert
   the existing non-managed fallback is unchanged (no crash, no spurious reveal).
5. `pendingManagedRequestNilWindowUnchanged` — regression guard: with a pending
   managed request for `P` and a nil focused window, assert the
   `.matchesActiveRequest` arm still runs `continueManagedFocusRequest` and the
   new `.unrelatedNoRequest` reveal code is not reached.

### Resolver unit coverage (same file or a focused helper test)

6. `singleManagedRevealCandidatePrefersConfirmedFocusThenPreferredThenRemembered`
   — mirror the priority test that likely exists for
   `nativeFullscreenOriginCandidate` (grep `nativeFullscreenOriginCandidate` in
   `Tests/`); assert the `focusedCandidates` ordering and the
   `samePidEntries.count == 1` fallback, and that scratchpad / non-standard
   layout / native-fullscreen entries are filtered out.

## Validation

```bash
swift build
swift test --filter AXEventHandlerTests
swift test --filter WMControllerFocusTests
# Optional full sweep if the above are green:
swift test
```

Manual validation (requires the runtime + a parked window):

1. On the active workspace, scroll a Telegram (or any tiling app) window
   off-screen so it is parked (`phase=offscreen`). Focus a different window.
2. Trigger an app-level activation of the parked app **without** it keying a
   window first — click one of its notifications (banner), or activate it from
   the Dock. Confirm its window scrolls into view and gains focus.
3. Confirm the runtime trace now emits `reveal_decision` + `focus_reality` for
   the revealed window (instead of only `activation_source_observed` +
   `nonManagedFallbackEntered`).
4. Regression: with two windows of the same app both parked on the active
   workspace, do the same notification-activate and confirm behavior is
   unchanged from today (no arbitrary window yanked into view).
5. Regression: normal focus changes (clicking directly on a visible window of
   another app) still work and still emit their `reveal_decision` as before.

Changeset (patch; confirm release policy): "Reveal an activated app's managed
window when macOS reports a nil focused window (e.g. notification-triggered
activation) and the app owns a single managed window."

## Risks and mitigations

- **Over-eager reveal on spurious app activations.** Mitigated by three gates:
  `source == .workspaceDidActivateApplication`, `origin == .external`, and a
  single unambiguous candidate. `.focusedWindowChanged` and internal
  probe/retry origins are excluded, matching the existing intent split at
  `:2005-2044`.
- **Ambiguity with multiple windows.** Deliberately bail to the current fallback
  when `entries(forPid:).count != 1` after filtering — never guess. Test #2 pins
  this.
- **Interaction with non-managed focus anchoring.** `handleManagedAppActivation`
  already runs its own suppression checks
  (`shouldSuppressManagedActivationWhileNonManagedFocusAnchored`, `:2417`, and
  siblings), so routing through it inherits the same guards the resolved-token
  path uses; we do not bypass them.
- **Double-handling if AX later delivers the real focused window.** The later
  `focusedWindowChanged` with a concrete window re-enters `handleAppActivation`
  and resolves to the same entry via the normal path; `handleManagedAppActivation`
  is idempotent for an already-confirmed focus (it is invoked repeatedly in the
  captured session for the same token without ill effect). Confirm during
  implementation that a redundant confirm is a no-op.
- **Inactive-workspace target.** If the single candidate lives on an inactive
  workspace, `isWorkspaceActive` is false and `handleManagedAppActivation`
  decides whether to switch — same policy as commit `06c0bf4e`'s same-app
  inactive-workspace reveal. This plan does not add new inactive-workspace
  policy; it only feeds the existing decision.

## Follow-ups (out of scope)

- Consider a bounded activation retry for the nil-focused-window case so that an
  app which *will* key a window shortly (but owns multiple managed windows now)
  gets picked up by the normal resolved-token path once AX populates
  `kAXFocusedWindowAttribute`. Today `handleMissingFocusedWindow` cancels the
  retry (`:4877`); a retry would need to be decoupled from `ManagedFocusRequest`
  (retries are currently request-scoped, `scheduleActivationRetryIfNeeded`,
  `:5019`). Evaluate separately — larger blast radius than this change.
