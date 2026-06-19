# M3 — Focus-request origin for FFM cursor-warp policy — Discovery

Source upstream commit: [`fce3a2c`](https://github.com/BarutSRB/OmniWM/commit/fce3a2c) — "Fix cursor warp for focus follows mouse" (0.4.9.7 line; thanks @m-hauck for the idea in issue #147).
Related: [`20260616-ffm-steals-focus-behind-overlay-on-stale-queued-mouse-moves.md`](20260616-ffm-steals-focus-behind-overlay-on-stale-queued-mouse-moves.md), [`20260616-omniwm-317-rapid-focus-revert-race.md`](20260616-omniwm-317-rapid-focus-revert-race.md).

Scope: determine whether the warp-on-hover defect applies to nehir, and scope a concept port (skip upstream's Dwindle hunks — Dwindle is intentionally absent from nehir).

---

## TL;DR

- **Applies: nehir's `ManagedFocusRequest` carries no origin and no creation timestamp.** `WMController.focusWindow` is the shared consumer for keyboard, command, restore, and FFM-driven activations; there is no way today to tell an FFM/hover confirmation from a keyboard confirmation, so "move mouse to focused window" warps on hover-driven focus.
- **Verdict:** 🟡 Open / Applies. Clean **concept port** (not a diff port — upstream's `fce3a2c` also touches `DwindleLayoutHandler`, which nehir does not have). Also serves as groundwork for the hiro-317 rapid-focus fix (A4).
- **Scope discipline:** M3 is *only* the FFM cursor-warp origin gate. The hiro-317 `createdAt`/grace-window work is explicitly **out of scope** and tracked separately.

## Provenance: is this nehir's code?

Yes. `ManagedFocusRequest` and the focus/warp path exist verbatim, minus an origin field:

```swift
// Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:26-38
struct ManagedFocusRequest: Equatable {
    enum Status: Equatable { case pending; case confirmed }

    let requestId: UInt64
    var token: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
    var retryCount: Int = 0
    var lastActivationSource: ActivationEventSource?
    var status: Status = .pending
}
```

A repo-wide `grep` for `intentLedger|classifyFocusObservation|echoOf|lateEcho|managedRequestGracePeriod` returns zero matches — no time-based or ledger-based focus defense exists.

## The code in question

### The warp gate fires on AX focus confirmation regardless of origin

`Sources/Nehir/Core/Controller/AXEventHandler.swift:2360-2376` — the `if shouldConfirmRequest, controller.moveMouseToFocusedWindowEnabled, ...` block ending with `controller.moveMouseToWindow(..., reason: "axFocusConfirmed")`. It consults `shouldSuppressMouseMoveToFocusedWindow(for:)` (token-based, `WMController.swift:710-721`) but not the *origin* of the request being confirmed.

### FFM activations route through the same `focusWindow`

- `MouseEventHandler.activateFocusFollowsMouseTarget` (`MouseEventHandler.swift:1374-1392`) calls `controller.suppressMouseMoveToFocusedWindow(for:)` then `niriLayoutHandler.activateNode(...)`; the actual `focusWindow` is driven later by the AX echo. The FFM signal already lives in `ViewportState` as `pendingFFMFocusToken`/`pendingFFMFocusTimestamp`.
- Keyboard focus-next/prev (`CommandHandler.swift:50`, `:237`), bar focus (`WindowActionHandler.swift:519-565`), and restore focus (`WMController.swift:3640-3730`) all funnel into `WMController.focusWindow` (`:3883`).

## Why it applies

With `moveMouseToFocusedWindowEnabled = true`, an FFM/hover confirmation reaches the warp gate indistinguishable from a keyboard confirmation and warps the cursor to the focused window — the exact annoyance upstream fixed in #147. Nehir has active FFM/warp work (`5ff991cb` multi-monitor warp, the FFM-overlay discovery) and the same blind spot.

## Recommendation

**Concept port.** Add a nehir-sized origin model and thread it to the warp gate.

1. Define `enum ManagedFocusOrigin: Equatable, Sendable { case keyboard; case command; case focusFollowsMouse; case programmatic; case restore }` above `ManagedFocusRequest` (no `String`/`Codable` raw value — keep it cheap and out of any persisted catalog).
2. Add `var origin: ManagedFocusOrigin = .programmatic` to `ManagedFocusRequest`.
3. Add `origin: ManagedFocusOrigin = .programmatic` to `FocusBridgeCoordinator.beginManagedRequest(token:workspaceId:)` (`:55-71`), stamped into the constructed request (`:67`).
4. Add `origin: ManagedFocusOrigin? = nil` to `WMController.focusWindow` (`:3883`). Resolve: if `nil`, default `.keyboard`; if an FFM marker is pending (`WorkspaceManager.isPendingFFMFocus(for:within:)` — new helper mirroring `recentlyConfirmedManagedRequest`), use `.focusFollowsMouse`. Pass the resolved origin into `beginManagedRequest`.
5. **Gate the warp** at confirm time (`AXEventHandler.swift:2360-2376`): add `&& confirmedOrigin != .focusFollowsMouse`. Keep the existing `!shouldSuppressMouseMoveToFocusedWindow(for:)` token-based gate as a backstop — it serves other suppression cases and must not be removed.

### What NOT to change / do not reintroduce

- Dwindle (`fce3a2c`'s `DwindleLayoutHandler` hunks) — nehir has no Dwindle.
- `suppressMouseMoveToFocusedWindow` — still used by floating interactions and `finalizeAnimation`; the origin gate is **additive**.
- Hiro-317 grace window / `createdAt` — separate (A4). M3 only adds `origin`.

## Suggested tests

1. `OptimizationCompletionTests.focusBridgeBeginManagedRequestCarriesOrigin` — `beginManagedRequest(token:workspaceId:origin:.keyboard).origin == .keyboard`; default is `.programmatic`.
2. `AXEventHandlerTests.ffmOriginConfirmationDoesNotWarpCursor` — `moveMouseToFocusedWindowEnabled = true`, drive an FFM activation, confirm via `handleAppActivation`; assert `controller.moveMouseToWindow` was **not** invoked (use the existing `warpMouseCursorPosition` injection point at `WMController.swift:190`).
3. `AXEventHandlerTests.keyboardOriginConfirmationWarpsCursorWhenEnabled` — same setup, origin `.keyboard`; assert warp **is** invoked.
4. `MouseEventHandlerTests` — extend an existing FFM test to assert the resulting `focusBridge.activeManagedRequest.origin == .focusFollowsMouse`.

Existing hiro-317-contract tests (`AXEventHandlerTests.swift:1616`, `:1698`, `:1769`) assert conflict resolution, not warp; they should remain green (M3 does not change conflict behavior). Verify with the build.

## Suggested validation

```bash
swift build
swift test --filter OptimizationCompletionTests
swift test --filter AXEventHandlerTests
swift test --filter MouseEventHandlerTests
```

Add a patch changeset: "Focus-follows-mouse activations no longer trigger cursor warp to the focused window when 'move mouse to focused window' is enabled."

## Risks

- **`WMController.focusWindow` signature change** has many call sites. Defaulting `origin: nil` keeps it source-compatible; the inferred origin for unqualified callers flips to `.keyboard`. Audit every `focusWindow(` call site to confirm `.keyboard` is correct or pass an explicit override; consult `isPendingFFMFocus` first so hover activations are tagged correctly.
- **FFM origin detection is heuristic** — the pending FFM marker is the only signal. If it has been cleared by the time `focusWindow` resolves origin, the request is mis-tagged `.keyboard` and warps. Backstop: the existing `pointerFocusWarpSuppressionInterval` window covers this race via `shouldSuppressMouseMoveToFocusedWindow`.
- **M3 is a strict subset of hiro-317 groundwork** but does not implement the grace-period fix. Call this out in the changeset/PR so reviewers do not expect the rapid-focus race to be fixed here.

## Open questions

1. Should M3 be folded into A4 (which also enriches `ManagedFocusRequest` with `createdAt`)? Same data model. Recommendation: ship M3 first as a narrow FFM-warp fix; A4 consumes the `origin` field later.
2. Does M3 need a new setting? No — `moveMouseToFocusedWindowEnabled` is the existing user-facing toggle; the origin gate is a correctness fix whenever it is on.
