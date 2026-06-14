# AX Frame-Write Verification Readback Race — Discovery

Deep discovery (2026-06-14) into finding #10 of `20260613-codebase-review-findings.md` ("AX frame write verification can race"). The finding's wording ("can race the window server's async update") is close but imprecise about *what* races what; this doc pins the mechanism, traces how a racy readback propagates through the dedup/learn caches (the part the finding calls "real desync can persist silently"), audits the mitigations, and lays out implementation options with evidence. File:line references were current as of the discovery date and will drift — re-verify before implementing.

This is a **"monitor, don't necessarily fix"** finding (per the review's Risk Hotspots header). The expected output is a characterized discovery with options, not a mandated implementation plan. Option selection is an explicit open question (§8).

## Scope

One item, one file:

- `Sources/Nehir/Core/Ax/AXWindow.swift` — `AXWindowService.setFrame(_:frame:currentFrameHint:)` writes size+position then reads the frame back to verify; the readback is the authoritative "did the write land?" oracle.

The race itself lives in `setFrame`, but its *consequences* are felt in three consumers that treat the readback-derived result as truth:

1. `AXManager.handleFrameApplyResults` (`Sources/Nehir/Core/Ax/AXManager.swift:794`) — caches `confirmedFrame` into the dedup map `lastAppliedFrames` and drives the retry budget.
2. `LayoutRefreshController` resize-minimum learner (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:~2980`, `:3091`) — turns a `.verificationMismatch` into a *pinned solver constraint*.
3. The general frame-application hot path (every relayout, every animation tick).

## 1. Mechanism — what the readback actually is

```swift
// AXWindow.swift — setFrame, the write + verify (lines 378–428, abridged)
let writeOrder = frameWriteOrder(currentFrame: currentFrameHint ?? (try? frame(window)),
                                 targetFrame: frame)
// ... AXValueCreate size + position ...
switch writeOrder {
case .sizeThenPosition:
    sizeError     = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute,     sizeValue)     // :402
    positionError = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute, positionValue) // :403
case .positionThenSize:
    positionError = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute, positionValue) // :409
    sizeError     = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute,     sizeValue)     // :414
}

let observedFrame = try? self.frame(window)   // :417 — the verification oracle (AX CopyMultipleAttributeValues)

let failureReason: AXFrameWriteFailureReason? = if sizeError != .success     { mapFrameWriteFailure(sizeError,     .size)     }
    else if positionError != .success                                          { mapFrameWriteFailure(positionError, .position) }
    else if let observedFrame { observedFrame.approximatelyEqual(to: frame, tolerance: 1.0) ? nil : .verificationMismatch } // :424
    else                                                                       { .readbackFailed }
```

`self.frame(window)` (`AXWindow.swift:296`) is a single `AXUIElementCopyMultipleAttributeValues` for `kAXPositionAttribute` + `kAXSizeAttribute`. The verification oracle is therefore a **second AX round-trip issued synchronously, on the per-PID AX thread, immediately after the two writes**.

`confirmedFrame` (the value the rest of the system trusts) is then derived from that oracle:

```swift
// AXWindow.swift:122–130
var confirmedFrame: CGRect? {
    if let observedFrame = writeResult.observedFrame,
       observedFrame.approximatelyEqual(to: targetFrame, tolerance: 1.0)
    {
        return observedFrame                      // ← returns the OBSERVED frame, not the target
    }
    guard writeResult.isVerifiedSuccess else { return nil }
    return writeResult.observedFrame ?? targetFrame
}
```

Two design facts to carry forward:

- **`confirmedFrame` returns the *observed* frame, not the *target*, on a verified-success pass.** Intentional (record where the window actually landed), but it means the dedup cache can hold sub-target values sourced from a racy readback.
- **Verification tolerance is 1.0 pt; dedup tolerance is 0.5 pt** (see §4). This asymmetry matters.

## 2. What actually races (correcting the finding's wording)

The finding says the readback "can race the window server's async update." The precise mechanism is slightly different and worth stating correctly, because it changes which options are viable:

- `AXUIElementSetAttributeValue` for `kAXSizeAttribute`/`kAXPositionAttribute` returns `.success` once the **target application's accessibility implementation has accepted the request**. For a window this routes through the app's `NSWindow`; `NSWindow.setFrame` does its geometry work in-process, then the app posts the change toward the window server (WindowServer) for compositing.
- `AXUIElementCopyMultipleAttributeValues` for the same attributes does **not** read a global truth. For most apps the AX server **proxies the attribute read back to the application**, which answers from its `NSWindow`/AppKit accessibility state.
- There is therefore **no happens-before guarantee** between the `SetAttributeValue` return and a subsequent `CopyAttributeValue` reflecting the *settled* frame. What the readback observes is whatever the app's AppKit layer reports at that instant, which can be:
  1. the **pre-write** frame (the set hasn't flushed through the app's run loop yet),
  2. a **transient mid-settlement** frame (min/max size clamp, aspect ratio, animation, or cell quantization still in flight),
  3. a frame **disturbed by a concurrent writer** — a user drag, another layout pass, `AXManager.applyPositionsViaSkyLight` (`AXManager.swift:742`), or the app reflowing itself.

So it is the *app's AX-attribute state propagation*, not strictly the window server, that the readback can race. The net effect the finding describes (a stale/mismatched readback treated as authoritative) is correct; only the named subsystem is loose. (Finding #8's discovery did the same mental-model correction for its area; this is the analogous fix here.)

## 3. How a racy readback propagates (the "silent desync" claim, traced)

The oracle is lossy in **both directions**, and the two failure modes have very different blast radii.

### 3a. False mismatch (readback reads old/transient frame ≠ target) → `.verificationMismatch`

Flow: `setFrame` → `.verificationMismatch` → `AXManager.handleFrameApplyResults` (`AXManager.swift:836`) records `recentFrameWriteFailures[id] = .verificationMismatch`, no `confirmedFrame`. Then:

- **Retry budget mitigates the common case.** `retryBudgetByWindowId[id]` is seeded to `1` on enqueue (`AXManager.swift:622`); `shouldRetryFrameWrite` returns true for any reason except `.cancelled`/`.suppressed` (`AXManager.swift:884–892`); a retry is scheduled with `forceApplyWindowIds.insert` (`AXManager.swift:852–864`). A transient race that resolves on the second write is self-healing.
- **The dangerous side effect is the resize-minimum learner.** `LayoutRefreshController` routes `.verificationMismatch` through `inferredResizeMinimumSize` (`LayoutRefreshController.swift:3091`): if `targetSizeIsSmallerThanObservedSize` (target more than 0.5 pt smaller on either axis, `LayoutRefreshController.swift:3132`), the **observed (oversized) frame is learned as a resize minimum**, merged into the prior minimum (`mergedInferredResizeMinimumSize`), **pinned into the solver** via `engine.updateWindowConstraints` (`LayoutRefreshController.swift:~3066`), and then `forceApplyNextFrame` is called for **every tiled sibling in the workspace** + `requestRefresh(reason: .layoutCommand)` (`LayoutRefreshController.swift:~3074–3082`).

  **A single racy oversized readback can therefore cascade: poison the solver constraints for a window and force a workspace-wide relayout.** This is strictly worse than the "wasteful retry" the retry budget covers, and it is the strongest argument for action even though the finding is framed as monitor-only.

- Two guards narrow (but do not close) this cascade:
  - `liveFrameMatchesTarget` (`LayoutRefreshController.swift:3126`) re-checks the target against `fastFrame` (SkyLight `getWindowBounds` — WindowServer-direct, see §5) and **confirms the write before the learner runs** if the live frame already matches. This rescues the case where the AX readback was stale but the window actually settled correctly.
  - `isCellQuantizationOvershoot` (`LayoutRefreshController.swift:~3015`, threshold 32 pt at `:3146`) accepts terminal cell-snapping as benign instead of learning a minimum.
  - Neither guard covers a transient frame that is oversized **beyond** the 32 pt quantization threshold **and** not rescued by the live-frame check (e.g. the readback caught a mid-animation frame, or a concurrent `batchMoveWindows` hadn't landed). That residual flows straight into the learner.

### 3b. False success (readback reads a transient/sibling frame within 1.0 pt of target) → verification passes

Flow: `observedFrame ≈ target` (tol 1.0) → `confirmedFrame = observedFrame` (the racy value) → `AXManager` caches `lastAppliedFrames[id] = confirmedFrame` (`AXManager.swift:823`) and clears failure/retry state. Now:

- The dedup map holds a frame **sourced from a racy readback**, not from the target and not from the settled reality.
- If the real window then drifts (user drag, app reflow, in-flight layout pass, monitor reconfiguration), the cache and reality **diverge silently**.
- Future layout passes compute targets and consult dedup (`skip-dedup`, `AXManager.swift:547`, tolerance 0.5). A stale cache value within 0.5 pt of a computed target **suppresses the corrective write**. The window stays wrong; the system believes it is right.

This is the "real desync can persist silently" the finding names. It is narrow (see the tolerance analysis in §4 for why steady-state same-target drift is partly self-correcting) but real for drifting windows and near-adjacent targets.

### 3c. Why high-frequency layout amplifies both

During a drag / animation / multi-monitor attach, `LayoutRefreshController` fires `immediateRelayout` many times per second and writes frames each pass. The window server is under the most write traffic exactly when the probability of reading a transient/in-flight frame is highest — so the oracle is least reliable precisely when it is queried most. `shouldSuppressFrameChangeRelayout` (`AXManager.swift:162`) suppresses the app's own frame-change AX notifications while `pendingFrameWrites[id] != nil`, which prevents the system from fighting itself *during* the pending window — but that suppression ends the moment the result is processed, so a late-arriving notification from a racy write can still trigger a follow-on relayout.

## 4. Tolerance map (load-bearing for §3b)

All frame comparisons in this pipeline, with the tolerance actually in effect:

| Comparison | Site | Tolerance | Direction |
|---|---|---|---|
| Verification (observed vs target) | `AXWindow.swift:424` | **1.0** | decides `.verificationMismatch` |
| `confirmedFrame` eligibility (observed vs target) | `AXWindow.swift:124` | **1.0** | decides if observed is cached |
| `liveFrameMatchesTarget` (fast vs target) | `LayoutRefreshController.swift:3128` | 1.0 | learner rescue check |
| Dedup `skip-dedup` (cached vs target) | `AXManager.swift:547` | **0.5** | decides if a write is suppressed |
| Dedup pending-equal (pending vs target) | `AXManager.swift:541`, `:599`, `:607` | 0.5 | coalesce identical in-flight writes |
| `shouldSuppressFrameChangeRelayout` | `AXManager.swift:171` | 0.5 | suppress app frame-change notifications |
| `targetSizeIsSmallerThanObservedSize` | `LayoutRefreshController.swift:3132` | 0.5 | gates resize-minimum learning |
| `approximatelyEqual` default | `CGGeometry+Extensions.swift:15` | 10 | (not used in this pipeline) |

**The asymmetry that matters:** verification (1.0) is *looser* than dedup (0.5). A readback 0.9 pt off target passes verification and is cached; the next pass with the same target compares that 0.9-off cache against the target with tolerance 0.5 → 0.9 > 0.5 → **not** deduped → re-write. So steady-state same-target drift is partly self-correcting (it re-writes rather than desyncs). The silent-desync window opens for **drifting** windows (cache holds a value the window has since left) and **near-adjacent** targets (a stale cache within 0.5 of a *new* computed target suppresses the write).

## 5. The unused stronger oracle (SkyLight)

`AXWindowService.fastFrame` / `framePreferFast` (`AXWindow.swift:349–360`) read window bounds via `SkyLight.shared.getWindowBounds(windowId)` — a private-framework call that reads the **WindowServer's authoritative backing bounds directly**, the same source `applyPositionsViaSkyLight` (`AXManager.swift:742`, `SkyLight.shared.batchMoveWindows`) writes through. By construction this is a **stronger, less racy oracle** than the AX attribute readback, because it bypasses the app-proxy hop described in §2.

Two facts about it that shape the options:

- It is `@MainActor`. The verification readback runs on the **per-PID AX thread** (inside `applyFrameWriteRequest`, `AppAXContext.swift:786`), so `fastFrame` cannot simply replace `self.frame(window)` at `AXWindow.swift:417` without either a MainActor hop (which serializes frame writes and defeats the per-app parallelism documented in `docs/ARCHITECTURE.md` §4.9) or a nonisolated SkyLight read (the private-framework C call is callable off-main; the `@MainActor` annotation needs an audit to confirm it is protective rather than incidental).
- It is **already wired into exactly one consumer**: `liveFrameMatchesTarget` (`LayoutRefreshController.swift:3126`) uses it as the rescue check before the resize-minimum learner runs. The general apply path (`AXManager.handleFrameApplyResults`) does not consult it at all. So today the stronger oracle is a *fallback in one branch*, not the primary verifier.

## 6. Latent landmines discovery surfaced (independent of any option)

1. **The resize-minimum learner cascade (§3a).** A racy oversized readback pins a constraint into the solver and force-relayouts the whole workspace. This is the highest-impact consequence of the racy oracle and exists *today*; it is not conditional on choosing to "fix" the race itself.
2. **`confirmedFrame` returns observed, not target (`AXWindow.swift:127`).** Combined with the §4 tolerance asymmetry, this is the root mechanism that lets a racy readback poison the dedup cache. Changing it to return the *target* on a verified pass (and treating observed purely as telemetry) would remove the cache-poisoning vector at the cost of losing "where did it actually land?" information that `recordFrameApplyTrace` and `confirmFrameWrite` currently rely on.
3. **The stronger oracle exists but is under-used (§5).** `fastFrame`/SkyLight is a WindowServer-direct read that sidesteps the app-proxy race, yet the hot verification path uses the weaker AX readback. The asymmetry (strong oracle in one branch, weak oracle everywhere else) is itself a smell.
4. **The race is structurally untestable in CI.** Every verification test injects a synthetic result via `AXWindowService.setFrameResultProviderForTests` (`AppAXContextTests.swift:181/251`, `RefreshRoutingTests.swift:1899`, `AXManagerTests.swift`) and so **bypasses the real `self.frame(window)` readback**. There is no test — and no deterministic way to write one without the live window server — that exercises the actual read-back ordering. This is the same shape of gap as finding #8's "zero tests for the guard": the *contract* the code depends on (readback reflects settled state) is neither enforced nor tested.
5. **`shouldSuppressFrameChangeRelayout` ends with the pending window.** Once `handleFrameApplyResults` clears `pendingFrameWrites[id]`, suppression ends, so a frame-change AX notification arriving *just after* processing (from the racy write itself) can still trigger a follow-on relayout — a self-induced refresh during the exact high-frequency window where the oracle is least reliable.

## 7. Implementation options

### Option A — Defer the readback by one run-loop tick

Insert a tiny yield on the AX thread between the writes and the readback (e.g. run the current run loop for a few ms, or schedule the readback for the next iteration) so the app has a chance to flush before verification.

- **Effort:** ~1–2 tasks (yield + re-baseline existing tests).
- **Latency cost:** adds per-write latency to the hottest path in the app (hundreds–thousands of frame writes/sec across PIDs during drag/animation). Likely small per-call but **unmeasured** (no benchmark target — same gap as finding #8 §5.2).
- **Correctness:** does not *deterministically* fix the race; only widens the window in which the app is likely to have flushed. A busy app or a concurrent writer can still lose.
- **Fits finding:** weak — it is a probabilistic mitigation, not a fix.

### Option B — Verify against the SkyLight (WindowServer-direct) oracle

Use `fastFrame`/`getWindowBounds` instead of, or in addition to, the AX readback in `setFrame`.

- **Effort:** ~3–5 tasks (audit `@MainActor` necessity → decide B1 hop vs B2 nonisolated → wire into `setFrame` → tests → measure).
- **Threading-model cost (the crux):**
  - **B1 — MainActor hop for the readback:** clean, but serializes verification across PIDs and erodes the per-app-parallel frame-application design (`docs/ARCHITECTURE.md` §4.9). Likely unacceptable for the hot path.
  - **B2 — nonisolated SkyLight read:** the underlying call is a C-function private-framework call and is plausibly safe off-main, but the existing `@MainActor` annotation must be audited (is it protective, or incidental?). If safe, this is the strongest primary-verifier option with no serialization cost.
- **Correctness:** strongest — reads the authoritative bounds, sidesteps the app-proxy race in §2.
- **Fits finding:** yes, if B2 audits clean. B1 trades one problem (race) for another (serialization).

### Option C — Make verification advisory; reconcile via a slower control loop

Stop treating the racy readback as authoritative. On a verified-success pass where observed ≠ target within a *tight* tolerance, cache the **target** (not the observed) in `lastAppliedFrames` and record observed purely as telemetry. Add a background reconciliation (e.g. cadenced on `LayoutRefreshController` ticks, or a low-frequency timer) that cross-checks `lastAppliedFrames` against `fastFrame` (SkyLight) for drift and calls `forceApplyNextFrame` on divergence.

- **Effort:** ~3–4 tasks (decouple `confirmedFrame` semantics → background reconciler → tests → tune cadence).
- **Correctness:** decouples the hot path from the racy oracle entirely; catches silent desync (§3b) via a slower, SkyLight-backed control loop instead of the per-write readback.
- **Threading-model cost:** the reconciler runs on MainActor (where `fastFrame` lives) at low frequency, so no hot-path serialization.
- **Fits finding:** this is the principled "monitor" answer to a "monitor, don't necessarily fix" finding — it stops *trusting* the racy oracle on the hot path and moves trust to a slower, stronger loop. Largest design change; highest robustness.

### Option D — Narrow the cascade (targeted hardening of §3a/§6.1)

Do not touch the verification oracle. Instead: (1) require the resize-minimum learner to ignore a `.verificationMismatch` whose observed frame is rescued by `liveFrameMatchesTarget` (currently the rescue *confirms* but the learner can still run on a *different* subsequent mismatch — close that gap); (2) require **two consecutive** oversized mismatches before pinning a minimum, so a single transient readback cannot poison solver constraints; (3) document the readback-race invariant in `AXWindow.swift` and `docs/ARCHITECTURE.md` (analogous to finding #8's §5.4 doc gap).

- **Effort:** ~2–3 tasks (learner hardening + tests → doc/comments).
- **Correctness:** does **not** address silent desync (§3b) or the false-mismatch retry churn — only stops the constraint-poisoning cascade.
- **Threading-model cost:** none.
- **Fits finding:** best value-per-effort under the "monitor" framing. Explicitly accepts the racy oracle on the hot path and hardens its most dangerous side effect. Pairs naturally with C or B later.

## 8. Cross-option scorecard

| Criterion | A (defer tick) | B (SkyLight oracle) | C (advisory + reconcile) | D (narrow cascade) |
|---|---|---|---|---|
| Addresses silent desync (§3b) | probabilistic | ✅ (if B2) | ✅ | ❌ |
| Addresses constraint-poisoning cascade (§3a/§6.1) | partial | ✅ | ✅ | ✅ |
| Hot-path latency / serialization risk | adds latency | B1 serializes; B2 none | none | none |
| Effort | low | medium-high | medium-high | low |
| New infra / threading-model change | none | maybe (nonisolated SkyLight) | background reconciler | none |
| Deterministically testable | ❌ | partially (oracle is mockable via `fastFrameProviderForTests`) | ✅ (reconciler is testable) | ✅ |
| Fits "monitor, don't fix" framing | weak | partial | strong (the "monitor" answer) | strong |
| Reversible | high | medium | medium | high |

**Combinability:** options are not exclusive. The lowest-regret sequencing is **D now** (stops the worst side effect, low effort, fully reversible) → decide between **B2** (strong primary oracle, if the `@MainActor` audit is clean) and **C** (decouple + reconcile, the principled long-term shape) based on the open questions below. **A** is not recommended as a standalone fix.

## 9. Open questions

1. **Has the cascade (§3a) ever fired in the wild?** Has a window ever acquired a spurious, sticky resize minimum during drag/animation/multi-monitor churn, or has a workspace ever force-relayouted itself for no obvious reason? If yes → D is urgent and B/C warranted. If no → the existing `liveFrameMatchesTarget` + cell-quantization guards may be sufficient and D is cheap insurance. Worth checking git history, the issue tracker, and `recentFrameApplyTrace` (`AXManager.swift:740`, captured in `windowStateDebugDump`) for `resizeMin.learn` entries with transient-looking observed frames.
2. **Is the SkyLight `@MainActor` annotation protective or incidental?** This decides B1 vs B2. If `getWindowBounds`/`batchMoveWindows` are safe off-main (private-framework C calls usually are), B2 unlocks the strongest primary verifier with no serialization cost. If the annotation protects shared state, B is weaker and C becomes more attractive.
3. **Appetite for a background reconciliation loop (C)?** It is the largest design change but the only option that makes the hot path *not* trust the racy oracle. Is there appetite for a new low-frequency control loop, or is the team preferring to keep verification synchronous and per-write?
4. **Scope of D?** Should the "two consecutive oversized mismatches before pinning" rule in D also apply to `.sizeWriteFailed` (not just `.verificationMismatch`), since both flow through `inferredResizeMinimumSize` (`LayoutRefreshController.swift:~3100`)? The finding names only the verification race, but the learner's input surface is wider.
5. **Should `confirmedFrame` return target or observed (§6.2)?** This is a load-bearing decision for C and independently worth a call: caching the target removes the cache-poisoning vector but loses "where did it actually land?" telemetry that traces and `confirmFrameWrite` rely on. Is that telemetry load-bearing for debugging, or replaceable from `observedFrame` kept separately?
