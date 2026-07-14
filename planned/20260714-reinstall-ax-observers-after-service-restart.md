# Reinstall AX launch/termination observers after a service restart

Verified against main `3056bee8` on 2026-07-14. **Re-verify line numbers before
editing; they drift.**

**Status:** planned.
**Symptom:** After the runtime is stopped and started again **within the same
process**, Nehir stops noticing apps launching and quitting. New app launches are
not detected and terminated apps' window state / `AppAXContext` are not torn down
via the termination observer, until the whole app is relaunched. (Other admission
paths — focused-window admission, periodic rescan, CGS observers — can partially
mask the *launch* case, so termination is the cleaner visible symptom.)

**The concrete trigger is onboarding, and it fires on first run.** The one path
that does a same-process stop→start today is the onboarding gate
(`WMController.setOnboardingActive`, `Sources/Nehir/Core/Controller/WMController.swift:428-440`):
entering onboarding calls `serviceLifecycleManager.stop()` (→ `cleanup()`, which
nils the observers), leaving it calls `setEnabled(desiredEnabled)` →
`serviceLifecycleManager.start()` → `startServices()` (which does not reinstall
them). Because `AppDelegate` runs `setOnboardingActive(true)` whenever
`!hasCompletedOnboarding` (`Sources/Nehir/App/AppDelegate.swift:98-102`), **every
new user runs their entire first session with launch/quit detection broken** —
`AXManager.init()` installs the observers, onboarding-open nils them, and
onboarding-finish restarts services without reinstalling. A second launch skips
onboarding, so the init-installed observers survive and the bug hides.

Note: losing Accessibility permission does **not** trigger this — it only flips
`accessibilityPermissionGranted` and reconciles `isEnabled`
(`WMController.swift:448-451`); it never calls `stop()`/`cleanup()`. There is also
no UI "disable" path calling `setEnabled(false)` today. Onboarding (and any
*future* disable/enable or re-run-onboarding affordance) is the trigger.

**Desired behavior:** a stop→start cycle fully restores app launch/termination
detection, exactly as a fresh launch would.

**How to observe (for the implementer's own sanity check — the Step 3 test is the
real gate):** the deterministic signal is the unit test below. Live, you can
reset onboarding-completed state, launch Nehir, finish the wizard, then (without
quitting) quit a running app and watch its window state linger; or set an lldb
breakpoint in `setupTerminationObserver`/`setupLaunchObserver` (hit only at
launch, never again after onboarding) and in `cleanup` (hit on onboarding-open).

Upstream reference: `BarutSRB/OmniWM` commit `6808e44c` ("Stabilize event intake
and service restarts"), which introduced an idempotent `installWorkspaceObservers()`
and calls it from both `init()` and `startServices()`. Root cause and evidence:
see [`discovery/20260714-upstream-post-roadmap-candidates.md`](../discovery/20260714-upstream-post-roadmap-candidates.md).

## Root cause (inline recap — confirmed in source)

`AXManager` installs its two `NSWorkspace` notification observers **only from the
initializer**:

```swift
// Sources/Nehir/Core/Ax/AXManager.swift:87-90
init() {
    setupTerminationObserver()   // registers appTerminationObserver
    setupLaunchObserver()        // registers appLaunchObserver
}
```

`AXManager.cleanup()` removes and **nils** both observers:

```swift
// Sources/Nehir/Core/Ax/AXManager.swift:418-427 (approx)
func cleanup() {
    if let observer = appTerminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer); appTerminationObserver = nil }
    if let observer = appLaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer); appLaunchObserver = nil }
    ...
}
```

`cleanup()` is called from `ServiceLifecycleManager.stop()`
(`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:580`), which also
sets `hasStartedServices = false` (`:556`). On the next enable,
`startServices()` (`:77-82`) re-wires the `onAppLaunched` / `onAppTerminated`
**closures** but never re-registers the underlying `NSWorkspace` observers that
*invoke* those closures. `setupTerminationObserver` / `setupLaunchObserver` have
no caller other than `init()`. Result: after a stop→start cycle the closures
exist but are never fired, so launch/termination detection is silently dead.

## Fix — idempotent `installWorkspaceObservers()`, called from init and startServices

Mirror the upstream shape (`6808e44c`), Nehir-native.

### Step 1 — add an idempotent installer to `AXManager`

File: `Sources/Nehir/Core/Ax/AXManager.swift`.

Replace the two direct calls in `init()` with a single call to a new
**non-private** method that installs each observer only when absent:

```swift
init() {
    installWorkspaceObservers()
}

/// Install the app launch/termination NSWorkspace observers if they are not
/// already registered. Idempotent so it can be called again after a service
/// restart (stop() → cleanup() nils them). See ServiceLifecycleManager.startServices().
func installWorkspaceObservers() {
    if appTerminationObserver == nil {
        setupTerminationObserver()
    }
    if appLaunchObserver == nil {
        setupLaunchObserver()
    }
}
```

Keep `setupTerminationObserver()` / `setupLaunchObserver()` private and
unchanged. The `== nil` guards make repeated calls safe (no double
registration).

### Step 2 — reinstall on service start

File: `Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift`, function
`startServices()` (~`:77-95`).

Immediately after `controller.axEventHandler.setup()` (`:82`) and before the
`controller.axManager.onAppLaunched = …` closure assignment (`:83`), add:

```swift
controller.axManager.installWorkspaceObservers()
```

This restores the observers on every start; on the first (fresh-launch) start
they are already present from `init()`, so the idempotent guards make this a
no-op there.

Do **not** port upstream's sibling changes in `6808e44c`
(`AppAXContext.shutdownAll()`, `clearPendingManagedFocus`, RunLoopJob
serialization, event-intake ordering). Those are separate concerns tracked as
distinct 🟡 items in the sweep discovery; this plan is the confirmed observer
bug only.

### Step 3 — regression test

File: `Tests/NehirTests/` — add `AXManagerObserverReinstallTests.swift` (or
extend an existing `AXManager*Tests` file if one already covers lifecycle).

To make the invariant observable without a behavior-faking seam, add a plain
read-only accessor to `AXManager` reflecting real state:

```swift
// AXManager.swift — observability only, not a behavior override
var workspaceObserversInstalled: Bool {
    appTerminationObserver != nil && appLaunchObserver != nil
}
```

Then assert, on a directly constructed `AXManager` (no full controller needed):

1. **Fresh init installs both.** After `AXManager()`,
   `workspaceObserversInstalled == true`.
2. **cleanup() tears them down.** After `cleanup()`,
   `workspaceObserversInstalled == false`.
3. **Reinstall restores them.** After a subsequent `installWorkspaceObservers()`,
   `workspaceObserversInstalled == true` again — this is the exact
   stop→start sequence and is the assertion that fails on today's `main`.
4. **Idempotent.** Calling `installWorkspaceObservers()` twice in a row leaves
   `workspaceObserversInstalled == true` and does not throw / does not require
   removing a prior registration (the `== nil` guards cover this).

Note in the test file why the accessor exists (observability of a private
lifecycle invariant), consistent with the caution in
`discovery/20260708-test-only-seams-can-make-tests-untruthful.md`: it exposes
real state, it does not stub the observers.

## Do-not-touch fences

- Do **not** modify `setupTerminationObserver` / `setupLaunchObserver` bodies,
  the observer closures, or `AppAXContext` teardown. Only add the idempotent
  installer and its single call site.
- Do **not** port the other `6808e44c` changes (AppAXContext generations /
  `shutdownAll`, RunLoopJob mutex serialization, event-intake coalescing,
  trace AX-ref stripping). Out of scope; separate items.
- Do **not** change `stop()` / `cleanup()` ordering or `hasStartedServices`
  gating.
- Do **not** touch any other file. This change is two source files plus one
  test file (and a changeset).

## Gate

- **Between steps (fast):** `mise run build`. Optionally `mise run format:check`
  + `mise run lint`.
- **Once at the end (full):** `mise run check` (format + lint + build + test).
  The new `AXManagerObserverReinstallTests` must pass and existing `AXManager*`
  / `ServiceLifecycleManager*` tests must stay green.

## Changeset (required — user-visible bug fix)

```bash
mise run changeset patch "Restore app launch and quit detection after completing onboarding, so a first-run session no longer loses app tracking until the app is relaunched"
```

## Commit message shape

Plain-English subject, no Conventional-Commits prefix:

```
Reinstall app launch/termination observers after a restart

AXManager registered its NSWorkspace launch/termination observers only in
init(), while stop() → cleanup() removed and nilled them. The onboarding gate
does a same-process stop→start (and runs on first launch), so after finishing
onboarding the onAppLaunched/onAppTerminated closures were wired but never
fired — every new user's first session lost app launch/quit detection until a
full relaunch. Add an idempotent installWorkspaceObservers() and call it from
both init() and ServiceLifecycleManager.startServices().

Ports the observer-reinstall portion of BarutSRB/OmniWM@6808e44c.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

(No known Nehir issue number for this at plan time. Reference upstream only as
`BarutSRB/OmniWM@6808e44c`; do not write a bare `#nnn`.)

## Completion token

On success, after the full gate is green, print exactly:

`PLAN_DONE_ax_observer_reinstall_fixed`
