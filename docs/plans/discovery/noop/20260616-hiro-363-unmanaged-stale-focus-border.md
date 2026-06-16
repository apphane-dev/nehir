# Hiro PR #363 — "Clear stale focus border for unmanaged windows" — Discovery

Source PR: <https://github.com/BarutSRB/Hiro/pull/363> (fixes Hiro issue #351)
Filed against: `BarutSRB/Hiro` (upstream of nehir — see `NOTICE.md`;
nehir is a fork of `BarutSRB/OmniWM`, which was renamed to Hiro).
Scope of this doc: determine whether the *concept* behind the PR applies to
nehir (clear stale focus borders when unmanaged/floating windows disappear
without a destroy event), and whether the narrow PR diff is safe to port.

All file/line references were verified against worktree `worktree-calm-meadow-6229`
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace").
Re-verify before implementing; line numbers drift.

> **Filed under `discovery/noop/`** — nehir already clears this stale-border
> class at stricter lifecycle boundaries: app hide/deactivation, miniaturize,
> remove, and post-create disappearance verification. Upstream #363 was closed
> without merge and later marked superseded by a broader Hiro fix; porting its
> narrow `renderEligibility` frame-probe gate would bypass nehir's existing
> lifecycle context and can clear valid unmanaged borders whose preferred/event
> frame is still usable. No new repo action is owned here.

---

## TL;DR

- **The stale Raycast/unmanaged focus border is already handled in nehir before
  the border renderer has to guess from a failed AX frame query.** NSWorkspace
  hide/deactivation notifications clear the current unmanaged or tracked-floating
  target, miniaturize/destroy paths clear by token, and transient floating
  creates are re-verified after AX warmup.
- **Verdict:** 🟢 **Fixed.** The exact upstream diff is not present in
  `FocusBorderController`, but nehir covers the root cause at earlier lifecycle
  layers and has tests for Raycast disappearance plus unmanaged deactivation,
  destroy, and miniaturize clears.

## PR context (merge state + what the diff does)

- **State:** closed without merge (per task triage and PR discussion). The final
  PR comment says it was superseded by upstream commit `cd775bc`, described as a
  broader fix for #351 with deactivation handling, warm AX contexts, and
  window-id collision coverage.
- **Symptom:** unmanaged/floating windows such as Raycast can hide or disappear
  without a destroy event, leaving the focus border rendered at the old frame.
- **PR diff:** one file, `Sources/OmniWM/Core/Border/FocusBorderController.swift`.
  The diff adds an unmanaged-target gate inside `renderEligibility(for:)`:

  ```swift
  // upstream PR #363, FocusBorderController.swift
  if !target.isManaged {
      guard observedFrame(for: target.axRef) != nil else {
          return .clear
      }
  }
  ```

  That makes a missing AX frame clear the current border target before the normal
  frame resolution path runs.

## Provenance: is this nehir's code?

Yes. The focus-border controller, keyboard-focus target, unmanaged/managed
eligibility split, and AX lifecycle handlers all exist in nehir:

- `Sources/Nehir/Core/Border/FocusBorderController.swift:236` calls
  `renderEligibility(for:)` before resolving and drawing the border.
- `Sources/Nehir/Core/Border/FocusBorderController.swift:263` contains nehir's
  `renderEligibility(for:)`; it does **not** include the upstream PR's unmanaged
  `observedFrame != nil` gate.
- `Sources/Nehir/Core/Border/FocusBorderController.swift:337` contains the
  separate `resolveFrame(...)` path used for managed and unmanaged border frames.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2485` and
  `Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:264` contain the
  lifecycle hooks that clear stale unmanaged/floating targets earlier.

## The code in question

**Renderer shape in nehir** — eligibility can clear/hide/update, then frame
resolution decides what to draw:

```swift
// Sources/Nehir/Core/Border/FocusBorderController.swift:236
switch renderEligibility(for: target) {
case .clear:
    clear()
    return false
case .hide:
    borderManager.hideBorder()
    return false
case .update:
    break
}

// Sources/Nehir/Core/Border/FocusBorderController.swift:247
guard let frame = resolveFrame(
    for: target,
    preferredFrame: preferredFrame,
    preferredFrameSource: preferredFrameSource
) else {
    borderManager.hideBorder()
    return false
}
```

**nehir's `renderEligibility`** — there is no unmanaged `observedFrame` probe;
managed disappearance and displayability are checked, then normal updates are
allowed:

```swift
// Sources/Nehir/Core/Border/FocusBorderController.swift:263
private func renderEligibility(for target: KeyboardFocusTarget) -> RenderEligibility {
    guard let controller else { return .clear }

    if controller.isOwnedWindow(windowNumber: target.windowId) {
        return .clear
    }

    if target.isManaged,
       controller.workspaceManager.entry(for: target.token) == nil
    {
        suppressedManagedTargets.remove(target.token)
        return .clear
    }
    ...
    return .update
}
```

**Unmanaged frame resolution deliberately accepts preferred/event frames** — a
blind port of #363 would clear before this fallback can run:

```swift
// Sources/Nehir/Core/Border/FocusBorderController.swift:389
if preferredFrameSource == .observed, let preferred {
    return preferred
}

if let observed = observedFrame(for: target.axRef) {
    return observed
}

return preferred
```

**Earlier lifecycle clears** — deactivation clears unmanaged targets and clears
tracked floating targets while suppressing re-render until focus returns:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:2485
func handleAppDeactivated(pid: pid_t) {
    guard let controller else { return }
    let clearedTarget = controller.focusBorderController.clearCurrentTarget(matching: pid) { target in
        if !target.isManaged {
            return true
        }
        guard let entry = controller.workspaceManager.entry(for: target.token) else {
            return false
        }
        return entry.mode == .floating
    }
    ...
    controller.focusBorderController.suppressManagedTarget(clearedTarget.token)
}
```

**Hide, remove, and miniaturize clear paths**:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:2470
if controller.currentBorderTarget()?.pid == pid {
    controller.clearKeyboardFocusTarget(pid: pid)
    _ = controller.workspaceManager.enterNonManagedFocus(
        appFullscreen: false,
        preserveFocusedToken: true
    )
    controller.focusBorderController.clear(pid: pid)
}

// Sources/Nehir/Core/Controller/AXEventHandler.swift:1210
controller.cleanupScratchpadWindowResourcesIfNeeded(for: token)
_ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
controller.clearManualWindowOverride(for: token)
controller.focusBorderController.clear(matching: token)

// Sources/Nehir/Core/Controller/AXEventHandler.swift:2119
func handleWindowMiniaturized(pid: pid_t, windowId: Int) {
    controller?.clearKeyboardFocusTarget(
        matching: WindowToken(pid: pid, windowId: windowId),
        pid: pid
    )
}
```

**Post-create disappearance verification** — Raycast-like transient floating
creates that vanish from WindowServer after creation are warmed and removed,
which reaches the remove/clear path above:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:1040
private func schedulePostCreateLifecycleVerification(for token: WindowToken) {
    pendingPostCreateLifecycleVerificationTasks[token]?.cancel()
    let task = Task { @MainActor [weak self] in
        ...
        await self.warmAXContextIfNeeded(for: token.pid)
        guard !Task.isCancelled,
              controller.workspaceManager.entry(for: token) != nil,
              self.resolveWindowInfo(windowId) == nil
        else {
            return
        }
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        self.cancelWindowStabilizationRetry(for: token)
        self.handleRemoved(token: token)
    }
}
```

## Why the stale-border bug is already fixed in nehir

1. **The PR's narrow renderer gate is absent, but the root cause is handled
   earlier.** `renderEligibility(for:)` lacks the upstream unmanaged
   `observedFrame` check (`FocusBorderController.swift:263`), yet app
   deactivation is observed from NSWorkspace and routed to
   `handleAppDeactivated(pid:)` (`ServiceLifecycleManager.swift:264`,
   `AXEventHandler.swift:2485`). That handler clears every unmanaged current
   border target (`AXEventHandler.swift:2487`) and also clears tracked floating
   targets (`AXEventHandler.swift:2491`).

2. **Raycast-like disappearance is covered explicitly.** The test fixture models
   `com.raycast-x.macos` as a floating `AXSystemDialog` with an authoritative
   WindowServer provider that later returns `nil` (`AXEventHandlerTests.swift:141`,
   `AXEventHandlerTests.swift:149`, `AXEventHandlerTests.swift:162`). The
   regression test then flips visibility off and expects the entry, current
   border target, and last applied border window id to be cleared
   (`AXEventHandlerTests.swift:8358`, `AXEventHandlerTests.swift:8389`,
   `AXEventHandlerTests.swift:8394`).

3. **Other no-destroy exits are covered.** Destroy/remove clears unmanaged
   focused borders (`AXEventHandlerTests.swift:9578`); app deactivation clears
   unmanaged focused borders (`AXEventHandlerTests.swift:9639`); miniaturize
   clears unmanaged focused borders (`AXEventHandlerTests.swift:10298`). These
   tests exercise the lifecycle handlers at `AXEventHandler.swift:1213`,
   `AXEventHandler.swift:2485`, and `AXEventHandler.swift:2119`.

4. **Porting #363 verbatim would be a regression risk.** nehir intentionally
   lets an unmanaged focused target render from a preferred/event frame before
   falling back to `observedFrame(for:)` (`FocusBorderController.swift:389` and
   `FocusBorderController.swift:393`). The PR's unconditional pre-render AX
   probe would clear before that path can use a still-valid preferred frame,
   conflating "AX frame query failed now" with "the focused unmanaged surface is
   gone." nehir's existing lifecycle clears have stronger evidence: NSWorkspace
   hide/deactivation, explicit miniaturize/destroy, or post-create WindowServer
   disappearance after AX warmup.

## Recommendation

**Do not port PR #363.** Keep nehir's lifecycle-based fix as the owner for this
bug class. If a future stale-border report survives these paths, investigate it
as a new lifecycle/identity hole with evidence of the missed notification, not by
adding the upstream `renderEligibility` AX-frame gate wholesale.
