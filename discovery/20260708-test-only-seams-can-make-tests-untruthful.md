# Test-only seams can make tests untruthful — Discovery

Verified against the main Nehir source tree at `579f124d` on 2026-07-08.
Line numbers drift; identifiers and function names are included so code stays
findable.

This audit was prompted by concern that `*OverrideForTests` / `*ForTests`
hooks in production code may let tests pass on a path that production never
runs. The concern is valid: most `ForTests` helpers are harmless observability
or synchronization seams, but several production-source conditionals do more
than replace macOS I/O — they skip Nehir's own reconciliation, scheduling, or
fallback behavior.

Cross-link cluster: [`OT-1` in `20260708-cross-discovery-relevance-clusters.md`](20260708-cross-discovery-relevance-clusters.md#ot-1--observability-and-tests-can-hide-the-real-path) groups this with traceability/diagnostics work. Use both together when reviewing plans that propose regression tests for silent runtime guards.

---

## TL;DR

- The repo has a large test-seam surface: `*ForTests` appears **1,443** times
  across Swift sources/tests, with **144** unique identifiers. In production
  `Sources/`, there are **241** occurrences, **126** unique identifiers, and
  **138 declarations** in **31 files**.
- The exact `*OverrideForTests` subset is smaller: **6** unique identifiers,
  **89** occurrences repo-wide; in `Sources/`, **17** occurrences in **3
  files**. The problem is therefore not just names ending `OverrideForTests` —
  several risky behavior flags use other suffixes (`disables...ForTests`,
  `materializes...ForTests`, `...IsAuthoritativeForTests`).
- The highest-risk pattern is: **a test flag causes an early return or changes
  a runtime decision inside production logic**. That makes tests less truthful
  because they assert a simplified or impossible execution path.
- Top immediate issues:
  1. `NativeFullscreenPlaceholderManager.materializesWindowsForTests` commonly
     disables production placeholder window materialization in tests.
  2. `TabbedColumnOverlayManager.disablesWindowUpdatesForTests` skips real
     overlay window reconciliation and records a test-only filtered state.
  3. `AXEventHandler.scheduleFloatingCreateFrameApplication` treats a frame
     apply test override as equivalent to an available AX context.
  4. `windowInfoProviderIsAuthoritativeForTests` changes fallback policy for
     window-info resolution.
  5. Global mutable AX/SkyLight providers replace low-level operations across
     the process and can leak between tests.

---

## Inventory

A local source audit of Swift files found:

| Surface | Repo-wide occurrences | Unique identifiers | Notes |
|---|---:|---:|---|
| `*ForTests` | 1,443 | 144 | Broad category: includes read-only snapshots, waits, resets, direct drivers, providers, overrides. |
| `*ForTests` in `Sources/` | 241 | 126 | Production code exposes or consumes the hooks. |
| `*ForTests` declarations in `Sources/` | 138 declarations | 123 unique | Spread across 31 source files. |
| `*OverrideForTests` | 89 | 6 | Exact suffix only. |
| `*ProviderForTests` | 182 | 12 | Usually replaces OS/framework reads or writes. |
| `*HookForTests` | 21 | 4 | Usually timing/ordering observation, but can alter behavior depending on use. |

Production-source declaration hotspots:

| File | `ForTests` declarations | Character |
|---|---:|---|
| `Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift` | 20 | Mix of behavior suppression, hooks, snapshots, accessibility drivers. |
| `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift` | 11 | Mostly direct UI test drivers / inspectors. |
| `Sources/Nehir/Core/Ax/AXWindow.swift` | 10 | Global static providers for AX/SkyLight-style low-level operations. |
| `Sources/Nehir/Core/Controller/AXEventHandler.swift` | 8 | Behavior flags, time source, traces, flush helpers. |
| `Sources/Nehir/Core/Controller/WMController.swift` | 8 | Mostly wait/reset/read helpers plus one fallback-policy consumer. |

The exact `*OverrideForTests` production identifiers are:

- `AXManager.fullRescanEnumerationOverrideForTests`
- `AXManager.frameApplyOverrideForTests`
- `AXManager.frameApplyAsyncOverrideForTests`
- `AXManager.usesFrameApplyOverrideForTests`
- `SkyLight.displaySpacesModeOverrideForTests`
- `SkyLight.spacesForWindowOverrideForTests`

---

## Risk rubric

Not every `ForTests` hook is a problem. This audit uses four buckets:

1. **Safe / mostly safe observability** — read-only getters, snapshots, trace
   snapshots, status-button labels, selected-window getters.
2. **Safe / mostly safe synchronization** — `waitFor...ForTests`,
   `flushPending...ForTests`, `resetDebugStateForTests`; these can still hide
   races if overused, but they do not normally change app behavior unless a
   test calls them.
3. **Acceptable fake I/O seam** — a fake provider replaces macOS/AX/SkyLight
   at the boundary while Nehir's own logic still runs. These are necessary for
   deterministic unit tests, but should be scoped and reset reliably.
4. **Untruthful behavior seam** — a test-only flag causes production logic to
   skip reconciliation, skip lifecycle work, change scheduling decisions, or
   suppress fallback. These are the immediate issues below.

The dangerous shape is visible when production code says, in effect:

```swift
if testFlagIsSet {
    return // or take a different Nehir-owned decision
}
```

That tests a different product.

---

## Immediate issue 1 — native fullscreen placeholder tests skip real window materialization

`NativeFullscreenPlaceholderManager` owns placeholder snapshots and actual
placeholder `NSWindow` lifecycle. It has a global static test flag
(`Sources/Nehir/Core/Controller/NativeFullscreenPlaceholderManager.swift:27`):

```swift
static var materializesWindowsForTests = true
```

During `update(placeholders:in:)`, snapshots are updated first. Then the flag
can skip all materialization/update logic and destroy existing windows
(`NativeFullscreenPlaceholderManager.swift:53-57`):

```swift
guard Self.materializesWindowsForTests else {
    for token in desiredTokens {
        windowsByToken.removeValue(forKey: token)?.destroy()
    }
    return
}
```

The shared test reset forces the global default to the non-production mode
(`Tests/NehirTests/TestSharedStateSupport.swift:202-205`):

```swift
OwnedWindowRegistry.shared.resetForTests()
NativeFullscreenPlaceholderManager.materializesWindowsForTests = false
```

Several targeted tests temporarily re-enable it, but the default test state is
snapshot-only. That means many tests can pass while never exercising:

- placeholder `NSWindow` creation;
- frame/application updates;
- owned-window registration and unregistering;
- z-ordering / activation behavior;
- appearance and cleanup side effects.

### Why this makes tests untruthful

The test-only branch does not merely replace AppKit with a fake object. It
returns before the production reconciliation path. Tests that assert
`snapshotForTests()` are validating a bookkeeping subset, not the product path.

### Suggested direction

Replace `materializesWindowsForTests` with an injected placeholder-window
factory/materializer. Production injects real `NativeFullscreenPlaceholderWindow`;
tests inject a fake object that records lifecycle calls. The manager should run
one reconciliation path in both production and tests.

---

## Immediate issue 2 — tabbed overlay tests skip overlay reconciliation

`TabbedColumnOverlayManager` has a behavior flag
(`Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift:297`):

```swift
var disablesWindowUpdatesForTests = false
```

Both update entry points record test state and then can return before real
window reconciliation (`TabbedColumnOverlay.swift:309-331`):

```swift
recordUpdateForTests(infos: infos, scopedWorkspaceId: nil, forceOrdering: forceOrdering)
guard !disablesWindowUpdatesForTests else { return }
```

and:

```swift
recordUpdateForTests(infos: infos, scopedWorkspaceId: workspaceId, forceOrdering: forceOrdering)
guard !disablesWindowUpdatesForTests else { return }
```

The recorder only stores `lastUpdateInfosForTests` while the disabled path is
active, and filters out zero-tab infos (`TabbedColumnOverlay.swift:349-358`):

```swift
updateHookForTests?(scopedWorkspaceId, forceOrdering)
guard disablesWindowUpdatesForTests else { return }
lastUpdateInfosForTests = infos.filter { $0.tabCount > 0 }
lastScopedWorkspaceIdForTests = scopedWorkspaceId
lastForceOrderingForTests = forceOrdering
```

### Why this makes tests untruthful

Tests can validate the desired overlay data while skipping:

- stale overlay closure;
- overlay window creation/update;
- `orderFront` behavior;
- SkyLight ordering relative to the active app window;
- accessibility tree updates.

This is especially risky because the test-visible `lastUpdateInfosForTests`
state exists only on the disabled branch, so tests are incentivized to run the
non-production path.

### Suggested direction

Split pure planning from effectful reconciliation:

- a pure `makeTabbedOverlayPlan(infos:scope:)` function can be unit-tested
  directly;
- reconciliation should accept an injected overlay-window factory / fake window
  implementation and run the same stale-close/update/order flow in tests.

`frontHookForTests` and `orderingHookForTests` can become fake-window recorded
calls instead of hooks embedded in the production `NSWindow` subclass.

---

## Immediate issue 3 — frame-apply test override changes AX context scheduling

`AXManager` exposes frame application overrides
(`Sources/Nehir/Core/Ax/AXManager.swift:53-55`) and a helper
(`AXManager.swift:165-166`):

```swift
var usesFrameApplyOverrideForTests: Bool {
    frameApplyOverrideForTests != nil || frameApplyAsyncOverrideForTests != nil
}
```

`AXEventHandler.scheduleFloatingCreateFrameApplication` then treats the mere
presence of a write override as sufficient to apply synchronously
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:1816-1821`):

```swift
let canApplySynchronously = controller.axManager.hasContext(for: pid)
    || controller.axManager.usesFrameApplyOverrideForTests
```

The frame-apply override path consumes buffered requests directly in
`AXManager.applyFramesParallel` (`AXManager.swift:736-745`):

```swift
let requestsForTests = framesByPidBuffer.values.flatMap { $0 }
if let frameApplyAsyncOverrideForTests, !requestsForTests.isEmpty {
    frameApplyAsyncOverrideForTests(requestsForTests) { [weak self] results in
        self?.handleFrameApplyResults(results)
    }
    return
}
if let frameApplyOverrideForTests, !requestsForTests.isEmpty {
    handleFrameApplyResults(frameApplyOverrideForTests(requestsForTests))
    return
}
```

### Why this makes tests untruthful

In production, "no `AppAXContext` yet" is a real state with its own behavior:
warm context, defer, retry, or report `contextUnavailable`. In tests, setting a
frame-write spy can make the scheduler act as though context availability is
not required. The test hook changes a Nehir-owned decision, not just the final
AX write.

### Suggested direction

Do not let a write spy imply context availability. Options:

- provide a fake `AppAXContext` in tests that should exercise the synchronous
  path;
- add a separate explicit context-availability seam for tests that truly need
  it;
- add tests for the no-context delayed/retry path with no frame-write override
  affecting the scheduling decision.

---

## Immediate issue 4 — authoritative test window-info provider changes fallback policy

`AXEventHandler` has both a provider and a test-only authoritative flag
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:801-802`):

```swift
var windowInfoProvider: ((UInt32) -> WindowServerInfo?)?
var windowInfoProviderIsAuthoritativeForTests = false
```

Resolution first asks the provider, but if the provider returns `nil`, the flag
can suppress fallback to real SkyLight (`AXEventHandler.swift:6570-6578`):

```swift
if let windowInfoProvider {
    if let info = windowInfoProvider(windowId) {
        return info
    }
    if windowInfoProviderIsAuthoritativeForTests {
        return nil
    }
}
return SkyLight.shared.queryWindowInfo(windowId)
```

`WMController` has the same consumer pattern when resolving window server info
for a token (`Sources/Nehir/Core/Controller/WMController.swift:2515-2520`).

### Why this makes tests untruthful

Production fallback policy is "provider miss falls through to SkyLight".
Tests can opt into "provider miss means no window". That is sometimes useful
for deterministic unit tests, but it is a different resolver contract. Any test
that asserts behavior after an authoritative `nil` is not necessarily proving
production behavior.

### Suggested direction

Make the policy explicit in an injected `WindowInfoResolver`:

- production resolver: provider/cache if present, then SkyLight fallback;
- test resolver: map-only resolver for deterministic missing-window scenarios;
- tests name which resolver policy they are asserting.

This removes a `ForTests` conditional from the production decision point.

---

## Immediate issue 5 — global static AX/SkyLight providers are broad process-wide overrides

`AXWindowService` has global mutable static providers
(`Sources/Nehir/Core/Ax/AXWindow.swift:221-232`):

```swift
nonisolated(unsafe) static var axWindowRefProviderForTests: ((UInt32, pid_t) -> AXWindowRef?)?
nonisolated(unsafe) static var setFrameResultProviderForTests: ((AXWindowRef, CGRect, CGRect?) -> AXFrameWriteResult)?
nonisolated(unsafe) static var pinnedWindowIdProviderForTests: ((UInt32) -> CGWindowID?)?
@MainActor static var fastFrameProviderForTests: ((AXWindowRef) -> CGRect?)?
nonisolated(unsafe) static var frameProviderForTests: ((AXWindowRef) throws(AXErrorWrapper) -> CGRect)?
@MainActor static var titleLookupProviderForTests: ((UInt32) -> String?)?
@MainActor static var timeSourceForTests: (() -> TimeInterval)?
```

They replace core operations at their call sites:

- pinned element lookup (`AXWindow.swift:272`);
- title/time cache inputs (`AXWindow.swift:293-312`);
- slow frame read (`AXWindow.swift:361-363`);
- fast frame read (`AXWindow.swift:393-396`);
- frame write result (`AXWindow.swift:420-422`);
- AX window ref lookup (`AXWindow.swift:898-900`).

`SkyLight` has analogous process-wide providers for ordered state and Spaces
queries (`Sources/Nehir/Core/SkyLight/SkyLight.swift:157-162`, used at
`SkyLight.swift:320`, `SkyLight.swift:368`, and `SkyLight.swift:459`).

### Why this is risky

Boundary fakes are necessary, but these are global mutable statics. They can:

- leak between tests if a `defer` reset is missed;
- make parallel tests unsafe;
- bypass low-level failure modes, coordinate conversions, and cache behavior;
- make unrelated tests depend on ambient hook state.

### Suggested direction

Move these behind scoped dependencies, ideally owned by the controller/test
fixture. If a global is unavoidable for OS boundary code, wrap it in a scoped
isolation helper and make direct assignment rare. Existing helpers like
`withAXFrameProviderIsolationForTests` are a good direction, but the production
surface should not require many unrelated tests to mutate global state.

---

## Medium-risk seams worth follow-up

These are not the first fixes, but they share the same shape.

### Focus border suppression hooks

`FocusBorderController` can suppress the next frame-hint update or render
(`Sources/Nehir/Core/Border/FocusBorderController.swift:31-34`, used at
`FocusBorderController.swift:103-104` and `FocusBorderController.swift:237-238`):

```swift
if suppressNextFrameHintForTests?(token) == true {
    suppressNextFrameHintForTests = nil
    return false
}
```

and:

```swift
if suppressNextRenderForTests?(target) == true {
    suppressNextRenderForTests = nil
    return false
}
```

This is behavior-changing, though narrowly scoped and one-shot. Prefer testing
eligibility/pure render plans or using a fake border renderer rather than a
skip-next flag.

### Window close interception

`WindowActionHandler.closeWindowForTests` intercepts close behavior
(`Sources/Nehir/Core/Controller/WindowActionHandler.swift:154`, used at
`WindowActionHandler.swift:163-164`). If tests assert close behavior through
this hook, they are not exercising the production close path. Prefer a fake AX
window action backend.

### Service lifecycle permission providers

`ServiceLifecycleManager` replaces accessibility permission stream/state/request
handling via providers (`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:36-38`,
used at `ServiceLifecycleManager.swift:505-515`). This is a reasonable OS
boundary seam, but it should be instance-scoped and exercised with realistic
state transitions so tests do not miss permission prompt/request ordering bugs.

### IPC/AppDelegate factory hooks

`AppDelegate.ipcServerFactoryForTests` swaps IPC server creation
(`Sources/Nehir/App/AppDelegate.swift:19`, used at `AppDelegate.swift:233`).
This is acceptable for app bootstrap tests, but it is another global static and
should be reset by a scoped helper.

---

## Mostly safe categories

These hooks are lower concern because they expose state or let tests wait for
asynchronous work without changing ordinary runtime branches:

- read-only snapshots/getters: `snapshotForTests`, `statusButtonTitleForTests`,
  `selectedOverviewWindowForTests`, `activeWorkspaceBarCountForTests`,
  `persistedWindowRestoreCatalogForTests`;
- trace/debug snapshots: `reconcileTraceSnapshotForTests`,
  `managedReplacementTraceSnapshotForTests`, `runtimeMouseTraceRecordsForTests`;
- synchronization helpers: `waitForRefreshWorkForTests`,
  `waitForWorkspaceBarRefreshForTests`, `flushPendingCGSEventsForTests`,
  `resetDebugStateForTests`;
- direct UI test drivers that invoke the same public-ish UI behavior, provided
  they do not skip internal branches.

These should still avoid becoming assertions against state that only exists in
a disabled/test-only path, as happened with `TabbedColumnOverlayManager`.

---

## Refactoring principle

A useful target architecture is:

1. **Pure planners** are tested directly: input model -> desired operations.
2. **Effectful reconcilers** run one path in production and tests.
3. **OS/AppKit/AX/SkyLight boundaries** are injected as scoped dependencies.
4. **Fake implementations record calls** instead of causing early returns.
5. **Test hooks observe; they do not decide.** A hook named `ForTests` should not
   change whether Nehir performs lifecycle, scheduling, fallback, or cleanup.

In short: replace `if test flag { return }` with `real algorithm + fake backend`.

---

## Candidate implementation order

1. Replace `NativeFullscreenPlaceholderManager.materializesWindowsForTests`
   with a placeholder-window factory/materializer fake.
2. Extract tabbed overlay planning and replace `disablesWindowUpdatesForTests`
   with fake overlay windows that record close/update/order operations.
3. Remove `usesFrameApplyOverrideForTests` from the AX context scheduling
   decision; tests that need synchronous writes should install a fake context.
4. Replace `windowInfoProviderIsAuthoritativeForTests` with explicit resolver
   policies.
5. Gradually move global AX/SkyLight providers into scoped test fixtures or
   mandatory isolation helpers.

Each step should include a grep gate for the removed conditional/flag and a
focused test that fails if the production reconciliation path is skipped.
