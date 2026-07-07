# Release-Mode AX Thread-Affinity Checking — Discovery

Groom 2026-07-07: still applicable — monitor-class finding; no Release-mode affinity guard, benchmark target, or ThreadGuardedValue tests have landed (verified against main 7a025b78).

Deep discovery (2026-06-14) into finding #8 of `20260613-codebase-review-findings.md` ("Release builds lose thread-safety checking in the AX layer"). The review finding's wording is imprecise; this doc corrects the mental model, characterizes the hot path, audits the "related" `MouseWarpHandler._instance` item, and lays out implementation options with evidence. File:line references were current as of the discovery date and will drift — re-verify before implementing.

## Scope

Two items named in the finding:

1. `Sources/Nehir/Core/Ax/ThreadGuardedValue.swift` — DEBUG-only affinity guard, no-op in Release.
2. `Sources/Nehir/Core/Controller/MouseWarpHandler.swift` — `nonisolated(unsafe) weak static var _instance` read from a `CGEventTapCallBack`.

Both live in the AX/input layer; both concern ownership invariants enforced "by discipline." They are **different shapes of problem** (see §4–§5) and are separable as tasks.

## 1. Mechanism — what the guard actually protects

The guard is **not** a concurrency / data-race guard and **not** a main-thread check. It is a **single-owner / thread-affinity invariant** scoped to the per-PID AX thread.

- `AppAXContext` spawns one dedicated `Thread` per PID (`Nehir-AX-<bundleId>`) in `createContext` (`AppAXContext.swift:177`).
- At thread start it binds `$appThreadToken.withValue(AppThreadToken(pid:)) { CFRunLoopRun() }` (`AppAXContext.swift:178`).
- `ThreadGuardedValue` captures `appThreadToken` at `init` (`ThreadGuardedValue.swift:9`) and, on every accessor, asserts the *current* `appThreadToken` still equals the captured one (`ThreadGuardedValue.swift:23,34,43,50,63,69,78,86,95,105`).
- `AppThreadToken.checkEquals` uses `precondition(self == other)` (`AppThreadToken.swift:23`). `precondition` is never optimized out — **but the entire `#if DEBUG` block is** (§2).
- All access is funneled through `Thread.runInLoop` / `runInLoopAsync` (`Thread+RunLoop.swift:57,68,98`), which uses `NSObject.perform(_:on:)` to run the body **synchronously on the AX thread's RunLoop**, still nested inside the `withValue` scope.

**Why the TaskLocal is visible inside the performSelector callback** (the load-bearing assumption, verified against Apple's `TaskLocal` docs and `swiftlang/swift` stdlib `TaskLocal.swift`): when `@TaskLocal.withValue` is called with **no current Swift Task** (a plain `Thread` started outside concurrency), the runtime falls back to a **thread-local** for the scope of the closure. `CFRunLoopRun()` and its performSelector callbacks run synchronously inside that closure, so they observe the value.

**Net invariant enforced (DEBUG only):** *"this access is happening on the per-PID AX thread that owns this value."* A violation means a caller bypassed `runInLoop` and touched `nonisolated(unsafe) var _value` (`ThreadGuardedValue.swift:5`) from the main thread or a callback thread — the actual hazard (silent corruption or a real data race on `_value`).

The `@TaskLocal` declaration is `appThreadToken` in `AppThreadToken.swift:5`; it is keyed on `pid_t` (`AppThreadToken.swift:8`).

## 2. Release reality — what actually ships today

```swift
// ThreadGuardedValue.swift — `value` getter
#if DEBUG
    threadToken.checkEquals(appThreadToken)   // precondition — but compiled out
    guard let v = _value else { fatalError(...) }
    return v
#else
    return _value.unsafelyUnwrapped           // zero check
#endif
```

- The DEBUG branch contributes **literally zero instructions** to Release: no TaskLocal read, no comparison, no precondition.
- Every *other* accessor (`valueIfExists`, `set`, `destroy`, subscripts, `contains`/`insert`/`remove`, `forEachKey`) has **no `#else` branch** — the guard simply disappears unconditionally in Release.
- `unsafelyUnwrapped` (`ThreadGuardedValue.swift:30`) on a destroyed value would crash, but that path is also unreachable by construction (the `deinit` asserts `_value == nil`, `ThreadGuardedValue.swift:55`).

**Conclusion:** today's Release build has **no runtime protection** if the affinity invariant is violated. Misuse → silent corruption or data race, exactly as the review finding states.

## 3. Hot-path characterization (the perf question)

`ThreadGuardedValue` is used in **exactly one file**: `AppAXContext.swift` — 5 instances: `axApp`, `windows`, `axObserver`, `focusedWindowObserver`, `subscribedWindows` (`AppAXContext.swift:96,97,102,103,104`). 43 accessor call sites across that file. The hot operations:

| Operation | Definition site | When it fires | Guarded accesses per invocation |
|---|---|---|---|
| `setFramesBatch` | `AppAXContext.swift:607` | Per layout relayout, batched per PID | `axApp.value` ×2 (enhanced-UI toggle, lines ~610, 622) + `windows[id]` subscript **once per window in the batch** (`applyFrameWriteRequest`) |
| `getWindowsAsync` | `AppAXContext.swift:348` | Window-list rescan | `axApp.value` + per-window `subscribedWindows[id]` / `axObserver.value` + one `windows.value =` write + `forEachKey` |
| `rekeyWindow` | `AppAXContext.swift:467` | Window lifecycle (re-ID) | a handful of subscripts |
| `removeWindowState` | `AppAXContext.swift:495` | Window destroy | `windows[id]` + `subscribedWindows[id]` |

Frame writes are the hottest path: **per window, per relayout, per PID**. On a busy layout (drag, animation, multi-monitor attach) this is hundreds-to-thousands of guarded accesses per second across all PIDs. The frame-application pipeline is documented in `docs/ARCHITECTURE.md:706` (§4.9): requests are grouped by PID and dispatched to per-app contexts in parallel, each with a 0.5s timeout.

**Per-access cost if enabled in Release (estimate):**

1. Read `appThreadToken` → on the AX thread (plain `Thread`, no Swift Task) this resolves via the **thread-local fallback** ≈ a `pthread_key`-style deref (tens of ns).
2. `pid_t` equality compare ≈ 1 cycle.
3. `precondition` frame setup — cheap on the happy path (branch-not-taken), but not free; a real function call with a failure block.

Conservative estimate: **~20–80 ns per guarded access**, dominated by the TaskLocal/thread-local lookup. At thousands of accesses/sec that is well under 1 ms/sec of aggregate overhead — *almost certainly* negligible, **but it has never been measured in this codebase**. There is no benchmark target in `Package.swift` and no perf task in `.config/mise/conf.d/`. The DEBUG build already pays this cost and runs fine for development — weak evidence it is cheap, but Debug builds skip optimizations, so this is not a reliable Release proxy.

**Dominating-cost argument (discovery finding):** every guarded access in the hot paths is colocated with **far** more expensive work in the same loop iteration — `AXUIElementCopyAttributeValue`, `AXUIElementSetAttributeValue`, `_AXUIElementGetWindow` are each a Mach IPC round-trip (µs-to-ms). Against that, tens of ns of guard overhead is rounding error; the batch's own AX calls dominate so completely that the guard cost is plausibly unmeasurable in an end-to-end frame-write benchmark. This makes "always-on, no benchmark" (Option D below) defensible by argument — though not by measurement.

## 4. `MouseWarpHandler._instance` — the "related" item

```swift
nonisolated(unsafe) weak static var _instance: MouseWarpHandler?
```

- Written on MainActor in `setup()` / `cleanup()` (`MouseWarpHandler.swift`).
- Read inside the `CGEventTapCallBack` C closure (`MouseWarpHandler.swift` callback block) and in `processTapCallback`.
- The tap source is added to `CFRunLoopGetMain()` (`MouseWarpHandler.swift` setup), so the callback fires **on the main thread**.
- `processTapCallback` already does `guard isMainThread else { return false }` then `MainActor.assumeIsolated { _instance?.receiveTapMouseWarpMoved(...) }` (`MouseWarpHandler.swift` processTapCallback).
- The main-thread guard is **already Release-active** — it is a plain `guard`, not `#if DEBUG`.

**So in practice this is safe-by-discipline, not racy.** The only callback thread is the main thread, and that thread check already runs in shipping builds. The residual risk is narrow:

- `_instance` is `weak` → a torn read is benign (becomes `nil`, event dropped).
- The real risk is a future refactor moving the tap to a non-main run loop, or the CGEvent tap firing on an exception/secondary thread during teardown — in which case `MainActor.assumeIsolated` would be UB.

This is a **different shape of problem** from the AX guard: here the discipline is already enforced at runtime in Release; the improvement is *documenting* the invariant and turning the `guard isMainThread` into a `precondition` (loud crash on the impossible case) plus an invariant comment.

## 5. Latent landmines discovery surfaced (independent of any option)

1. **The `Task {}`-inside-`runInLoop` trap.** Per Swift Forums evidence and SE-0311: if anyone refactors `runInLoopAsync` to spawn a new `Task { }` inside the performSelector callback (e.g., "make it async"), that Task will **NOT** inherit the thread-local-fallback `appThreadToken` — Tasks only inherit TaskLocals from a parent *Task*, and the AX thread has none. The DEBUG guard would then start failing spuriously, or (worse) someone would "fix" it by weakening the guard. This invariant is undocumented and worth a comment regardless of which option is chosen. Same hazard applies to `RunLoopAction._action` (`Thread+RunLoop.swift`) and `nonisolated(unsafe) var thread: Thread?` (`AppAXContext.swift:100`), which use the same escape hatch.

2. **No benchmark harness.** Any option that claims "negligible perf cost" is currently unmeasurable in-repo. `Package.swift` has no benchmark target; `.config/mise/conf.d/` has no perf task. Introducing one (Option A) is a new repo pattern — possibly reusable for benchmarking the pure-state-machine layout engine (`docs/ARCHITECTURE.md:363`, §3.5).

3. **Zero tests for `ThreadGuardedValue`.** No coverage of the guard itself — neither the happy path (matching token passes) nor the violation path (mismatch traps). `Tests/NehirTests/` has no `ThreadGuardedValueTests.swift`; grep for `ThreadGuardedValue|ThreadGuard` in `Tests/` returns nothing. Whatever option is chosen, tests are net-new.

4. **Documented threading model is high-level.** `docs/ARCHITECTURE.md:376` (§3.6 Thread Safety Model) mentions per-app AX threads and callbacks posting back to the main actor, but does **not** document the `appThreadToken` affinity invariant, the `runInLoop` discipline, or the DEBUG-only guard. A reader of ARCHITECTURE.md would not know the invariant exists. This is a documentation gap either way.

## 6. Implementation options

### Option A — Always-on guard, gated by a perf benchmark

Remove the `#if DEBUG`/`#else` split so `checkEquals` runs in all builds. Task 1 = a microbenchmark to measure per-access overhead in Debug + Release; record go/no-go in the plan. If go: add violation-trap test + rationale comment + harden `_instance`. If no-go: fall back to B or C.

- **Effort:** ~4–6 tasks (benchmark → decide → edit guard → tests → `_instance` hardening → docs).
- **Perf risk:** unknown until measured (estimated <1 ms/sec aggregate; the point of A is to convert a guess into data).
- **Safety gained:** strongest — shipped Release crashes loudly on any affinity violation, exactly the finding's ask.
- **Reversibility:** high — pure `#if` flip.
- **New infra:** first benchmark target in `Package.swift` (new repo pattern).
- **Failure mode:** if perf is bad, the benchmark task is spent but you ship B/C — low waste.
- **Fits finding:** yes — directly answers "consider whether worth it" with a measurement.

### Option B — Opt-in guard behind a build flag

`#if DEBUG || NEHIR_AX_THREAD_GUARDS`. Default OFF in shipping Release, ON in DEBUG + diagnostic/beta builds. Wire the flag into `Package.swift` `define` and the release-packaging mise task.

- **Effort:** ~3–4 tasks (add flag + conditional → tests → `_instance` hardening → docs).
- **Perf risk:** **zero** for shipping Release (unchanged from today).
- **Safety gained:** none for end users by default; only devs/QA/diagnostic builds get the loud crash.
- **Reversibility:** high.
- **New infra:** compilation condition in `Package.swift` + packager awareness.
- **Failure mode:** real-world misuse still corrupts silently in shipped builds (the original concern stays unaddressed for users).
- **Fits finding:** partial — gives a safety net but does not satisfy "is a cheap Release assertion worth it?" for shipping builds.

### Option C — Minimal: document + harden `_instance` only

Conclude the per-access Release guard is not worth it on hot AX paths. Add invariant comments to `ThreadGuardedValue` + `Thread+RunLoop` (including the §5.1 `Task{}` trap). Tighten `MouseWarpHandler._instance`: make the main-thread guard a `precondition` + invariant comment.

- **Effort:** ~2 tasks (comments/docs → `_instance` hardening + test).
- **Perf risk:** zero.
- **Safety gained:** marginal — `_instance` becomes loud-on-misuse; AX layer unchanged.
- **Reversibility:** trivial.
- **New infra:** none.
- **Failure mode:** the AX-layer concern from the finding is explicitly *not* addressed.
- **Fits finding:** interprets the "monitor, don't necessarily fix" framing as "decide no."

### Option D — Always-on guard, no benchmark gate (discovery-made-viable)

Discovery made this viable: the guard is a single `pid_t` compare + a thread-local deref, and the hottest callers are wrapped in batches that do far more expensive work per iteration (`AXUIElementCopyAttributeValue`/`SetAttributeValue` — Mach IPC, µs-to-ms). Against that, tens of ns of guard overhead is rounding error (see §3 dominating-cost argument).

Like A but skip the standalone benchmark task; add an inline `// perf: negligible vs AX IPC in same loop` rationale comment + the violation-trap test, and ship the always-on guard directly.

- **Effort:** ~3 tasks (edit guard + comment → violation/happy-path tests → `_instance` hardening).
- **Perf risk:** very low *by argument* (AX IPC dominates), but **not measured**.
- **Safety gained:** equal to A's "go" branch.
- **Reversibility:** high.
- **New infra:** none.
- **Failure mode:** if the argument is wrong, you ship a regression you did not measure — but it is a one-line revert.
- **Fits finding:** yes, but resolves the "consider" question by reasoning rather than evidence.

## 7. Cross-option scorecard

| Criterion | A (benchmark) | B (flag) | C (minimal) | D (always-on, no bench) |
|---|---|---|---|---|
| Addresses AX-layer concern for **shipping** users | ✅ (if go) | ❌ | ❌ | ✅ |
| Perf risk to shipping | measured → known | none | none | low (argued, unmeasured) |
| Effort | high | medium | low | low-medium |
| Adds repo infra (benchmark target) | ✅ new pattern | minor (flag) | none | none |
| Evidence-based decision | ✅ | n/a | n/a | ❌ (argument only) |
| Hardens `_instance` | ✅ | ✅ | ✅ | ✅ |

## 8. Open questions

1. **Past incidents?** Has there been a real user-facing affinity violation (a silent-corruption bug traced to wrong-thread AX access)? If yes → the guard has demonstrated production value → favors A/D. If no → it is pure insurance → C/B more defensible. The review findings doc does not say; worth checking git history and the issue tracker.
2. **Appetite for a benchmark target?** Is there interest in introducing a benchmark target to `Package.swift` (Option A) — possibly reusable for the pure-state-machine layout engine — given the repo currently has none?
3. **Scope of `_instance` work?** Is it in-scope to also re-examine `nonisolated(unsafe) var thread` (`AppAXContext.swift:100`) and `RunLoopAction._action` (`Thread+RunLoop.swift`), which use the same escape hatch — or strictly the two items the finding names?
4. **Blends?** Options are not exclusive — e.g., "D but add the benchmark as task 1 anyway" or "B now, flip to always-on (A/D) once a benchmark exists."
