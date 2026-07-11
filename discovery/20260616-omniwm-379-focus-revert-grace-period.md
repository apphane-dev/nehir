# OmniWM PR BarutSRB/OmniWM#379 — "Fix focus reverting on rapid next/prev (→BarutSRB/OmniWM#317)" — Discovery

Groom 2026-07-07: still applicable — companion evaluation of upstream PR BarutSRB/OmniWM#379 (closed-unmerged); the underlying BarutSRB/OmniWM#317 race remains open in nehir, so this concept-port is still relevant (verified against main 7a025b78).

Source PR: https://github.com/BarutSRB/OmniWM/pull/379 — "Fix focus direction race on
rapid next/prev key presses", targets issue BarutSRB/OmniWM#317.
Companion issue doc: `discovery/20260616-omniwm-317-rapid-focus-revert-race.md`
(verdict 🔴 Open — owns the root-cause analysis; **this doc does not re-derive the race**).
Scope of this doc: evaluate **this PR specifically** — characterize the 300 ms
grace-period mechanism (what it guards, where in the focus-commit path), confirm it is
absent in nehir, assess portability, and record a verdict.

All file/line references were verified against the Nehir source tree at
`7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace"). **Re-verify
before implementing; line numbers drift** (the BarutSRB/OmniWM#317 doc was anchored at `98f2429`, where
the guard was at `:3553` and the five conflict sites were `:1411`/`:1490`/`:1558`/`:1651`/
`:3474`; `AXEventHandler.swift` has since gained +264/−29 lines, so those numbers are all
stale — see the mapping table below). The PR diff was fetched verbatim from
`github.com/BarutSRB/OmniWM/pull/379.diff` (HTTP 200); nehir symbols were re-read live.

> **Consolidation note.** This is the single authoritative discovery for PR BarutSRB/OmniWM#379. It
> supersedes two near-duplicate BarutSRB/OmniWM#379 drafts the discovery orchestrator emitted in the
> same run — `20260616-omniwm-379-focus-revert-300ms-grace-pr.md` and
> `20260616-omniwm-379-managed-request-grace-period.md` (same verdict, same HEAD, same
> analysis). Those two have been deleted; the line refs below were re-verified at
> `7f61cb3` and supersede any slightly-discrepant numbers in those drafts.

---

## TL;DR

- **PR BarutSRB/OmniWM#379 stamps the *pending* `ManagedFocusRequest` with a creation time and makes the
  revert guard reject any conflicting authoritative-external AX echo while that request
  is younger than 300 ms. The concept is exactly the missing half of nehir's own
  echo-recognition: nehir already has a `Date`-stamped + grace-windowed "is this a
  self-echo?" check, but only on the *confirmed* path; PR BarutSRB/OmniWM#379 adds the *pending*-path
  half. As shipped, though, the patch is not directly portable — it covers only **4 of
  nehir's 5** conflict sites, uses a non-idiomatic `CFAbsoluteTime` clock, and opens a
  0.3 s / 0.6 s dual-window gap — and it is closed-unmerged and superseded upstream by
  an `IntentLedger` design.**
- **Verdict:** 🟡 **Partial — port the *concept* adapted, never the diff verbatim.**
  nehir already implements the idea (timestamp + grace window that suppresses
  self-echoes) on the *confirmed* path; PR BarutSRB/OmniWM#379 adds the *pending*-path half that nehir
  lacks. The shipped patch needs adaptation (idiomatic `Date` clock, a single 0.6 s
  window, and coverage of the missed 5th site) before it is safe to land.

## Merge state — inherited from the BarutSRB/OmniWM#317 doc (API rate-limited at re-check)

The catalog triage note calls PR BarutSRB/OmniWM#379 **"open."** The BarutSRB/OmniWM#317 doc records a live GitHub
REST-API read (2026-06-15/16) of:

| Field | Value |
|---|---|
| PR BarutSRB/OmniWM#379 `state` / `merged` | closed / **false** |
| `merged_at` / `merge_commit_sha` | `null` / `null` |
| `closed_at` | `2026-06-15T23:35:07Z` (3 min after issue BarutSRB/OmniWM#317 was closed-completed) |
| `head.repo` / `head.ref` | `biswadip-paul/OmniWM` / `fix/focus-direction-race-on-rapid-keypress` |

I attempted to re-verify live; the unauthenticated `/repos/BarutSRB/OmniWM/pulls/379`
endpoint is currently rate-limited (returns no fields). I therefore **inherit the BarutSRB/OmniWM#317
doc's closed-without-merge finding** and flag the discrepancy with the catalog label.
**The verdict is unaffected either way:** there is no merge SHA, the diff survives only
in two contributor forks (the PR branch and a cherry-pick `8674850` into `bispaul/OmniWM`),
so it will never auto-flow into nehir through upstream diff-tracking. Cite the diff as
design provenance, not a SHA.

## Provenance: is this nehir's code?

Yes — the conflict machinery the PR touches is present and nehir-owned
(`Sources/Nehir/...`), but **the PR's fix is entirely absent**. The PR's two edited files
map 1:1 (`OmniWM`→`Nehir`):

- `Sources/Nehir/Core/Controller/AXEventHandler.swift`
- `Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift`

A repo-wide search for `managedRequestGracePeriod | CFAbsoluteTime | .age` across
`Sources/Nehir/Core/Controller` returns **zero** matches for the focus path (the only
`createdAt` hits are the unrelated `WindowCreatePlacementContext` placement cache at
`AXEventHandler.swift:93`/`:107`/`:3633`/`:3687` — placement, not focus).

## What the diff changes (verbatim, from `.diff`)

Two files, ~30 lines, three logical edits:

**1. Stamp + expose the pending request's age** (`KeyboardFocusLifecycleCoordinator.swift`):

```swift
 struct ManagedFocusRequest: Equatable {
     ...
     let requestId: UInt64
+    let createdAt: CFAbsoluteTime            // NEW: wall-clock creation stamp
     var token: WindowToken
     ...
+    var age: CFAbsoluteTime {                // NEW
+        CFAbsoluteTimeGetCurrent() - createdAt
+    }
 }
 ...
     let request = ManagedFocusRequest(
         requestId: nextRequestId,
+        createdAt: CFAbsoluteTimeGetCurrent(),   // NEW: stamp at construction
         token: token,
         workspaceId: workspaceId
     )
```

**2. A 300 ms grace constant + a young-request gate in the revert guard**
(`AXEventHandler.swift`):

```swift
+    private static let managedRequestGracePeriod: CFAbsoluteTime = 0.3      // NEW

     private func shouldHonorObservedFocusOverPendingRequest(
         source: ActivationEventSource,
-        origin: ActivationCallOrigin
+        origin: ActivationCallOrigin,
+        pendingRequest: ManagedFocusRequest                                  // NEW required arg
     ) -> Bool {
-        source.isAuthoritative && origin == .external
+        guard source.isAuthoritative, origin == .external else { return false }
+        return pendingRequest.age > Self.managedRequestGracePeriod           // reject echo vs. a young request
     }
```

**3. Thread `pendingRequest: request` into four call sites** of the guard — the
`case let .conflictsWithPendingRequest(request):` blocks at upstream lines `1198`,
`1253`, `1292`, `2767`.

### What the grace guards, and where in the focus-commit path

The guard is the **single gate** that decides every `conflictsWithPendingRequest`
outcome: return `true` → `clearManagedFocusState(...)` **reverts** to the observed
window; return `false` → `continueManagedFocusRequest(...)` **re-asserts** the intended
window. Before the PR the gate is purely structural
(`source.isAuthoritative && origin == .external`) — it honors *any* conflicting
authoritative-external AX notification regardless of how recently the pending request was
issued, so a stale OS echo of a *previous* key press (arriving while the *new*
`activeManagedRequest` already points at the final target) reads as a conflict and
reverts. The PR adds one clause: **while the conflicting pending request is younger than
300 ms, the gate returns `false`** — the echo is treated as a self-echo, the revert is
skipped, and `continueManagedFocusRequest` re-asserts the intended window.

This is the *pending* path only. The age is measured from request **creation**
(`beginManagedRequest` → `createdAt`), not from confirmation — which is precisely the gap
the BarutSRB/OmniWM#317 doc identifies: a pending request is, by definition, not yet confirmed, so
nehir's existing *confirmed*-path echo recognition cannot classify the late echo.

## Coverage — the PR edits 4 of nehir's 5 sites (at HEAD `7f61cb3`)

nehir has **five** call sites of the guard (re-verified by `grep` + enclosing-function
read). All five still take only `source:`/`origin:` — i.e., the PR has not been applied:

| nehir line (HEAD `7f61cb3`) | Enclosing function | PR hunk (upstream line) | Patched by BarutSRB/OmniWM#379? |
|---|---|---|---|
| `AXEventHandler.swift:1554` | `handleAppActivation` region | `@@ -1198` | ✅ |
| `AXEventHandler.swift:1645` | `handleAppActivation` region | `@@ -1253` | ✅ |
| `AXEventHandler.swift:1713` | combined `.matchesActive`/`.conflicts` case | `@@ -1292` | ✅ |
| **`AXEventHandler.swift:1813`** | **`admitFocusedWindowBeforeNonManagedFallback` (def `:1751`)** | **—** | **❌ omitted** |
| `AXEventHandler.swift:3702` | `handleMissingFocusedWindow` (def `:3691`) | `@@ -2767` | ✅ |

The omitted site is reachable and mirrors the other four — read verbatim:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:1812  (inside admitFocusedWindowBeforeNonManagedFallback, def :1751)
case let .conflictsWithPendingRequest(request):
    if shouldHonorObservedFocusOverPendingRequest(
        source: source,
        origin: origin
    ) {
        clearManagedFocusState(
            matching: request.token,
        workspaceId: request.workspaceId
        )
        break
    }
    continueManagedFocusRequest(request, source: source, origin: origin, reason: .pendingFocusMismatch)
```

The omission is **self-attested by the PR's author**: the cherry-pick `8674850` into
`bispaul/OmniWM` notes verbatim — *"Fixed one additional callsite in
`admitFocusedWindowBeforeNonManagedFallback` that the cherry-pick missed."* And because
edit #2 makes `pendingRequest:` a **required** argument, a verbatim port also **fails to
compile** at `:1813` until it is fixed — so "apply the patch" is not a literal option;
any port must touch all five sites regardless.

## The nehir pre-image matches the PR's "before" byte-for-byte

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:3786
private func shouldHonorObservedFocusOverPendingRequest(
    source: ActivationEventSource,
    origin: ActivationCallOrigin
) -> Bool {
    source.isAuthoritative && origin == .external            // :3790 — time-blind; the whole race
}
```

```swift
// Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:26
struct ManagedFocusRequest: Equatable {
    enum Status: Equatable { case pending; case confirmed }   // :27-30
    let requestId: UInt64                                     // :32
    var token: WindowToken                                    // :33
    var workspaceId: WorkspaceDescriptor.ID                   // :34
    var retryCount: Int = 0                                   // :35
    var lastActivationSource: ActivationEventSource?          // :36
    var status: Status = .pending                             // :37
}                                                            // :38 — no createdAt, no age
// built without a timestamp at KeyboardFocusLifecycleCoordinator.swift:66
//   let request = ManagedFocusRequest(requestId: nextRequestId, token: token, workspaceId: workspaceId)  (:66-70)
```

The PR would apply cleanly *mechanically*; the objections below are design, not syntax.

## Why the verdict is 🟡 Partial — nehir already has *half* of this mechanism

The decisive fact for the verdict: **nehir already implements the PR's core idea — a
timestamped record plus a grace window that rejects self-echoes — but only on the
*confirmed* path.** PR BarutSRB/OmniWM#379 adds the missing *pending*-path half.

```swift
// Sources/Nehir/Core/Controller/KeyboardFocusLifecycleCoordinator.swift:47  (existing — confirmed-path echo record)
private struct ConfirmedManagedRequest {
    var token: WindowToken
    var confirmedAt: Date                                   // :49
}
// :129-131  recentlyConfirmedManagedRequestsByPID[token.pid] = ConfirmedManagedRequest(token: token, confirmedAt: Date())
// :169  func recentlyConfirmedManagedRequest(for token:, within interval:) -> Bool
// :175      Date().timeIntervalSince(confirmation.confirmedAt) <= interval   // echo test
```

Consumed against a grace window on the *confirmed* path:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:314
private static let nativeAppSwitchLeaseRequestConfirmationGrace: TimeInterval = 0.6
// :1469-1471  … recentlyConfirmedManagedRequest(for: token, within: Self.nativeAppSwitchLeaseRequestConfirmationGrace)
```

So nehir already answers "is this activation an echo of our own recent confirm?" — the
exact question the PR answers for the *pending* path. The BarutSRB/OmniWM#317 race lives entirely on
the pending path, where `ManagedFocusRequest` has no timestamp; that is the gap PR BarutSRB/OmniWM#379
fills. **The fix is partly built in nehir; the gap is narrow and local** → 🟡 Partial,
not ⚪ (code present) and not 🟢 (the pending half is absent).

### Four concrete reasons a verbatim port is wrong

1. **Under-coverage.** 4 of 5 sites; the `:1813`
   (`admitFocusedWindowBeforeNonManagedFallback`) branch stays blind, so the race remains
   reachable there. The required-arg signature change also breaks compilation at `:1813`
   until it is fixed — a verbatim port cannot even build.

2. **Foreign clock type.** The PR uses `CFAbsoluteTime`/`CFAbsoluteTimeGetCurrent()`,
   which is **the only occurrence of that type** in nehir's focus code. The codebase's
   echo idiom is uniformly `Date` + `Date().timeIntervalSince(...)` (`:49`/`:131`/`:175`).
   Importing `CFAbsoluteTime` creates a parallel, non-unifiable timestamp system next to
   the existing one, which complicates the eventual `IntentLedger` port. (Both clocks are
   wall-clock, so this does not make monotonicity worse — but a port is a chance to use a
   monotonic clock via an injectable clock.)

3. **Dual-window gap (0.3 s vs 0.6 s).** nehir gates the confirmed-path echo recognition
   on **0.6 s** (`nativeAppSwitchLeaseRequestConfirmationGrace`, `:314`). PR BarutSRB/OmniWM#379
   introduces a **second, 0.3 s** window for the pending path. A self-echo arriving
   between 0.3 s and 0.6 s is then *rejected* on the confirmed path but *honored* on the
   pending path — a residual revert window the two disagree on. The BarutSRB/OmniWM#317 doc: *"use 0.6 s
   so both windows agree."*

4. **Time heuristic, not echo classification (why upstream abandoned it).** The gate's new
   return `pendingRequest.age > 0.3` cannot tell a stale self-echo from a genuine user
   click that lands inside 300 ms (a real click is suppressed for up to 300 ms), and a
   stale echo arriving **after** 300 ms still reverts. OmniWM `main` replaced the timer with
   `IntentLedger.classifyFocusObservation → .echoOf/.lateEcho/.external` (verified in
   `main` at `AXEventHandler.swift:3680`, quoted in the BarutSRB/OmniWM#317 doc) and deleted
   `FocusBridgeCoordinator`. `main` has **no** `managedRequestGracePeriod`/`createdAt`/
   `age`. PR BarutSRB/OmniWM#379 is the *rejected* branch, not the shipped fix.

## Recommendation

🟡 **Do not apply PR BarutSRB/OmniWM#379 verbatim — use it as design provenance, and port the *concept*
adapted.** That adaptation is exactly "Option B" in the BarutSRB/OmniWM#317 doc:

1. Stamp the request at creation with **`let createdAt: Date`** + **`var age: TimeInterval
   { Date().timeIntervalSince(createdAt) }`**, mirroring `ConfirmedManagedRequest.confirmedAt`
   (`KeyboardFocusLifecycleCoordinator.swift:49`) — **not** `CFAbsoluteTime`. Optionally
   back it by a monotonic clock via an injectable clock for testability.
2. **Reuse `nativeAppSwitchLeaseRequestConfirmationGrace` (0.6 s, `AXEventHandler.swift:314`)**
   for the pending-path grace window — do **not** add a second 0.3 s
   `managedRequestGracePeriod`. One window for both echo paths removes the gap risk.
3. Widen `shouldHonorObservedFocusOverPendingRequest` (`:3786`) to take
   `pendingRequest: ManagedFocusRequest` (the PR's signature is fine), and thread it into
   **all five** sites — `:1554`, `:1645`, `:1713`, `:3702`, **and `:1813`** (the site the
   PR omits, inside `admitFocusedWindowBeforeNonManagedFallback` def `:1751`). Each site
   already binds `request` under its `.conflictsWithPendingRequest(request)` case, so this
   is additive — no call-graph surgery.
4. Inject a clock in tests, never call `Date()` inline.

**Long-term:** plan the `IntentLedger` rewrite (the BarutSRB/OmniWM#317 doc's Option C) — the unifying
primitive for this race and the structurally-parallel FFM focus race
(`discovery/20260616-ffm-steals-focus-behind-overlay-on-stale-queued-mouse-moves.md`).
PR BarutSRB/OmniWM#379's timer is a fast stopgap; it should not be the terminal design.

## Suggested tests

The full regression set lives in the BarutSRB/OmniWM#317 doc (rapid focus-next settles on the final
window; stale `.external` echo rejected while `.probe` still bails; both conflict
sub-cases; genuine post-window external change still honored; assert on
`confirmedManagedFocusToken` / `activeManagedRequest`, **not** `selectedNodeId`). Two are
specific to *this PR's* defects and must be added:

- **The omitted site is covered.** Drive a conflict through
  `admitFocusedWindowBeforeNonManagedFallback` (the `:1813` site) — an observed managed
  window conflicting with a young pending request via that path — and assert the request
  is *not* cleared within the grace window. A port that copies the PR's 4-site diff and
  forgets `:1813` fails this test (and fails to compile, which is the first signal).
- **Single-window invariant.** If the grace constant is unified with the 0.6 s confirmed
  window (recommendation 2), assert that an echo arriving in the overlap is rejected on
  **both** the pending and confirmed paths — so no echo-arrival-time falls into a gap
  between the two windows and reverts.

Note (per BarutSRB/OmniWM#317 doc): three existing tests encode the *pre-fix* contract and will flip red
against any fix unless their fixtures deliver the conflicting observation outside the
grace/echo window — `AXEventHandlerTests.swift:1616`/`:1698`/`:1769` (line refs from the
BarutSRB/OmniWM#317 doc; **re-verify at HEAD**). A port is not "just add tests"; these must be qualified.
