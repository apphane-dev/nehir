# NiriConstraintSolver Axis-Solve Loop — Discovery

Verdict: no-op — the reported O(n^3) complexity claim is wrong (the loop is O(n^2)) and the upstream Set-based fix should NOT be ported. Kept as a reusable analysis reference; the optional benchmark was never landed. Moved to noop/ on 2026-07-07 (verified against main 7a025b78).

Reported issue: **[BarutSRB/OmniWM#393](https://github.com/BarutSRB/OmniWM/issues/393)** — claims
`NiriConstraintSolver.swift` lines 93–120 contain an **O(n³)** worst-case constraint-solving
loop driven by an O(n) `removeAll { $0 == pinnedIndex }` inside an O(n)-iteration `while`
loop, causing "measurable" layout jank with 20+ windows and "directly visible" jank during
animated resizing.

This discovery verifies the issue against the nehir codebase and **corrects the complexity
model**. The short version: the code the issue points at **exists in nehir essentially as
described** (the `removeAll`-inside-`while` pattern is real), but the **O(n³) severity and
the "measurable per-frame jank" impact claims are both unsupported** — the loop is
**O(n²)**, and for realistic window counts it is unlikely to be the hot path without further
measurement. The suggested `Set<Int>` fix may be a reasonable cleanup if implemented
carefully, but it changes constants, not the asymptotic bound.

All file references should be re-verified before implementing; line numbers drift. Re-verified
against nehir at commit `e6adda2` ("Add more issues dicoveries", 2026-06-15).

---

## TL;DR

- **Issue is actual for nehir.** The exact code pattern exists in
  `Sources/Nehir/Core/Layout/Niri/NiriConstraintSolver.swift` at lines **92–120** (issue
  cited 93–120; off by one, essentially identical). The `NiriAxisSolver.solve` function is
  `@inlinable`, reached on every layout pass, and confirmed to run **per animation frame**
  during scroll/resize via `NiriLayoutHandler.tickScrollAnimation` → `applyFramesOnDemand`
  → `NiriLayout.layoutContainer` → `resolveWindowSpans` → `NiriAxisSolver.solve`.
  The specific O(n²) `pendingAutoIndices` loop is skipped for effectively tabbed containers,
  because `solve` returns through `solveTabbed` before reaching it.
- **The O(n³) claim is incorrect.** A precise recount gives **O(n²)**, not O(n³). The issue
  multiplies three independent O(n) operations that run *sequentially inside a single
  iteration* (`reduce` + linear scan + `removeAll`) as if they were *nested* — they are not.
  Per iteration the cost is O(k) where k = remaining auto indices; k shrinks each iteration;
  the sum is O(n²). See [Complexity recount](#complexity-recount-on³--on²).
- **The fix's stated benefit is also off.** The issue says the `Set<Int>` rewrite "drops the
  complexity to **O(n²)** (outer loop × weight reduce), which is the theoretical minimum."
  The loop is *already* O(n²). A carefully implemented rewrite can only change constant
  factors; a naive `Set` rewrite that scans or filters the original full index list each
  iteration can be neutral or slower than the current shrinking-array worklist.
- **Real-world impact is unverified and likely negligible.** The issue's "20+ windows"
  threshold and "directly visible jank" are asserted without measurement. For realistic
  workspace sizes (single Niri column rarely exceeds ~10–20 stacked windows; even an extreme
  50 gives n² = 2,500 simple array/float operations), the cost is likely small but should not
  be asserted without measurement. nehir has **no performance benchmark** (confirmed: no
  `measure`/`XCTMetric`/`@Benchmark` usage in `Tests/`)
  and **no cap on window/column count**, so the claim cannot be confirmed or refuted from
  existing evidence. A benchmark is the prerequisite for deciding whether to touch this.
- **Recommendation:** treat as a low-priority cleanup, not a proven perf fix. A rewrite may
  be fine for readability if it preserves or improves the shrinking-worklist behavior, but do
  **not** frame it as fixing a jank hotspot or an O(n³) bug, and gate it behind a benchmark
  that demonstrates a real cost at realistic n before/after.

---

## The code under scrutiny (inlined, exact)

`Sources/Nehir/Core/Layout/Niri/NiriConstraintSolver.swift`, the `while` loop inside
`NiriAxisSolver.solve` (lines 90–120):

```swift
var pendingAutoIndices = nonFixedIndices                       // :90
var pinnedMinimumSum: CGFloat = 0                              // :91
while !pendingAutoIndices.isEmpty {                            // :92   ← outer loop, ≤ n iterations
    let distributableSpace = max(0, remainingSpace - pinnedMinimumSum)  // :93  O(1)
    let totalWeight = pendingAutoIndices.reduce(CGFloat.zero) { partialResult, index in   // :94  O(k)
        partialResult + max(weights[index], epsilon)
    }
    guard totalWeight > epsilon else { break }                 // :96   O(1)

    var pinnedIndex: Int?
    for index in pendingAutoIndices {                          // :100  O(k), breaks on 1st violation
        let share = distributableSpace * (max(weights[index], epsilon) / totalWeight)
        if share + epsilon < minConstraints[index] {
            pinnedIndex = index
            break
        }
    }

    if let pinnedIndex {
        values[pinnedIndex] = minConstraints[pinnedIndex]      // :108  O(1)
        pinnedMinimumSum += minConstraints[pinnedIndex]        // :110  O(1)
        pendingAutoIndices.removeAll { $0 == pinnedIndex }     // :111  O(k)  ← flagged in the issue
        continue
    }

    for index in pendingAutoIndices {                          // :115  O(k), runs ONCE then breaks
        values[index] = distributableSpace * (max(weights[index], epsilon) / totalWeight)
    }
    break
}
```

`k` = `pendingAutoIndices.count` at the start of each iteration. It starts at the number of
non-fixed windows (`nonFixedIndices.count`, ≤ n) and **decreases by exactly 1** on every
pinning iteration (a single `pinnedIndex` is inserted, never more). The final-distribution
`for` loop at `:115` runs on exactly one iteration — the last one — and is followed by
`break`, so it does not introduce an additional outer-loop factor.

---

## Complexity recount: O(n³) → O(n²)

The issue's accounting (quoted):

> The while loop pins one column per iteration (up to n iterations). Each iteration performs:
> O(n) reduce … O(n) linear scan … O(n) removeAll … Total: O(n³).

The error: the three O(n) operations execute **sequentially within one iteration**, so the
per-iteration cost is their **sum** O(n), not their **product** O(n³). An outer loop of n
iterations times O(n) work per iteration is O(n²).

Precise per-iteration cost (k = remaining count that iteration):

| operation | line | cost |
|---|---|---|
| `reduce` over `pendingAutoIndices` | :94 | O(k) |
| linear scan for next min-violation | :100–105 | O(k) worst case (breaks on first hit) |
| `removeAll { $0 == pinnedIndex }` | :111 | O(k) |
| `for index in pendingAutoIndices` final distribute | :115 | O(k), **once total** (last iteration only) |

Per pinning-iteration: O(k) + O(k) + O(k) = **O(k)**.

Over the full run, k descends n → n−1 → … → 1 (one pin per iteration):

$$ \sum_{k=1}^{n} O(k) = O(n^2) $$

There is no fourth nested loop over `pendingAutoIndices` inside any iteration, so there is no
basis for an O(n³) bound. The theoretical minimum for "pin one of n candidates, recompute
weights among the survivors, repeat" is indeed O(n²) — and **the current code is already
there**. The issue's framing of the rewrite as "drops to O(n²), the theoretical minimum"
double-counts: it compares the imagined O(n³) to the rewritten O(n²), but the starting point
was O(n²) all along.

**What the `Set<Int>` rewrite actually changes.** Replacing
`pendingAutoIndices.removeAll { $0 == pinnedIndex }` (O(k)) with a `Set` insert (O(1), or
O(log k) for a sorted set) can remove one pass over the current worklist, but only if the
rewrite still iterates a shrinking worklist or otherwise avoids scanning the original full
`nonFixedIndices` array every time. A naive set-based rewrite that does
`nonFixedIndices.filter { !pinnedIndices.contains($0) }` each iteration adds an O(n)
allocation/pass and can be neutral or worse than the current array removal.

The safe statement is therefore narrower: a well-implemented cleanup may improve constants,
but it does **not** change the O(n²) asymptotic class. The outer reduce + scan remain linear
in the candidate set each iteration. A *true* asymptotic drop below O(n²) would require a
different algorithmic invariant, not just swapping `removeAll` for `Set.insert`.

> Note: the issue's suggested snippet comments `// ... compute weights excluding
> pinnedIndices ...` and `findNextPinnedIndex(...)`, implying the reduce still runs over all
> non-fixed indices each iteration (just skipping pinned ones) — that is still O(n) per
> iteration, still O(n²) overall. Same conclusion.

---

## How the solver is reached (call path, per-frame during animation)

The solver is `@inlinable` and lives on the layout hot path. Traced end to end:

1. **Per-frame animation driver** — `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:66`
   `tickScrollAnimation(targetTime:displayId:)`. This is the callback the refresh controller
   invokes per frame during animated viewport scroll / column resize. It calls
   `engine.tickAllWindowAnimations` / `tickAllColumnAnimations` (`:89`–`:90`) and
   `state.advanceAnimations(at: targetTime)` (`:91`), then `applyFramesOnDemand(...)`
   (`:97`) with the frame's `animationTime: targetTime`.
2. **Frame application** — `applyFramesOnDemand(wsId:state:engine:monitor:animationTime:)`
   drives the engine to produce frames for the current animation time.
3. **Layout pass** — `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:943`
   `layoutContainer(... animationTime: TimeInterval? = nil ...)` is invoked for every
   container on the pass; at `:984` it calls `resolveWindowSpans(windows:availableSpace:gap:isTabbed:orientation:)`.
4. **Span resolution** — `NiriLayout.swift:1072` `resolveWindowSpans` builds the
   `[NiriAxisSolver.Input]` array (one entry per window in the container; `:1081`–`:1140`)
   and calls `NiriAxisSolver.solve(...)` at `:1142`.

So **the solver runs once per container, per layout pass, per animation frame**, and the
specific **O(n²) loop runs for each non-tabbed/effectively non-tabbed container**. The issue's
"runs per frame" premise is directionally correct; the severity is not.

The solver input dimension `n` is **the number of windows in a single container on a single
axis** — for Niri that is windows stacked vertically within one column (horizontal monitor
orientation) or horizontally within one row (vertical orientation). It is *not* the total
window count across the workspace, and *not* the number of columns.

---

## Real-world impact: claimed vs. verifiable

The issue asserts, without measurement:

- "Becomes measurable with 20+ windows in a single column"
- "Directly visible jank" during animated resizing
- "Layout calculation stalls with many-column workspaces (50+ windows)"

None of these are backed by a profile or benchmark in the issue, and nehir's tree provides no
way to confirm them today:

- **No performance benchmarks exist.** `Tests/` contains no `measure { }` blocks,
  `XCTMetric` usage, or `@Benchmark` suites — confirmed by grep. (The grep hits on
  `Suite`/`Service` are false positives from unrelated test names.)
- **No cap on container window count.** There is no `maxColumns` / `maxWindows` /
  `columnLimit` guard anywhere under `Sources/Nehir/Core/Layout/Niri/`, so n is bounded only
  by how many windows the user actually stacks in one container.

Back-of-envelope scale for the O(n²) loop at realistic n:

| n (windows in one container) | n² scale proxy |
|---|---:|
| 10 | 100 |
| 20 (issue's "measurable" threshold) | 400 |
| 50 (issue's "stall" threshold) | 2,500 |
| 100 (pathological for a single Niri column/row) | 10,000 |

These are small counts for simple array and floating-point work, so the claim is unlikely on
first principles, but the actual wall-clock cost must be measured rather than asserted. For
context, the related `20260614-ax-frame-write-verification-race` discovery identifies AX
frame writes and verification readbacks as synchronous per-window round trips on the frame
application path; those integration costs are a more plausible frame-budget consumer than
this pure in-process loop. This strongly suggests the loop is **not** the first place to look
for animation jank, and the "per-frame = directly visible" chain in the issue skips the
comparison that matters (solver cost vs. AX cost vs. frame budget).

**Honest conclusion on impact:** unverified, and the evidence available (small realistic n,
no benchmark, and heavier-looking AX integration work on the same frame path) makes the
"measurable/stalls" claims unlikely. A benchmark is the prerequisite for resolving this
either way — and it is cheap to write since `NiriAxisSolver.solve` is a pure function with
direct unit tests.

---

## Existing test coverage

`Sources/Nehir/Core/Layout/Niri/NiriConstraintSolver.swift` is directly unit-tested in
`Tests/NehirTests/NiriLayoutEngineTests.swift`:

- `solverRedistributesSpaceAfterMaxCapsWithoutReviolatingThem` (`:1956`) — three windows
  with max-constraint fields populated. Despite the test name, current solver behavior and
  assertions do **not** prove max-cap redistribution: the first input has `maxConstraint:
  100`, but the expected output for it is `400`. Treat this as generic solver coverage, not
  evidence that max caps are enforced for auto windows.
- `solverFixedOverflowClampsFixedWindowAndPreservesAutoMinimum` (`:1997`) — fixed-overflow
  clamping preserves the auto-tile minimum.

Both exercise correctness, not scale. There is **no test that drives the min-constraint
pinning path through a high-iteration cascade**, which is exactly the branch the `while`
loop's iteration count depends on. A scale/correctness test should construct many windows
whose constraints force repeated pinning, and a benchmark should include both easy cases
(first remaining index violates immediately) and harder scan-order cases (the next violating
index appears late in the pending order).

---

## Fix direction

Two directions are possible; neither is required without measurement.

### A. Constant-factor cleanup (the issue's proposal, bounded accurately)

A cleanup can keep the current shrinking worklist and remove the matched element more
explicitly, or use a different pending representation if benchmarks show it helps. The key
constraint is that the rewrite must not replace an O(k) shrinking-array pass with an O(n)
full-list scan/allocation each iteration.

Examples of neutral-or-bad rewrites to avoid:

```swift
let pendingAutoIndices = nonFixedIndices.filter { !pinnedIndices.contains($0) }
```

That line materializes a fresh array from the original full index list every iteration. It is
still O(n²), and may have worse constants than the current code.

A safe cleanup should be framed only as **O(n²) → O(n²)** with possible constant-factor or
readability improvement. Benchmark it before claiming any speedup.

### B. True asymptotic improvement would require a different algorithm

A simple "running `remainingWeight` plus one forward scan" is **not obviously correct**. If a
later item gets pinned, the remaining distributable share per unit weight can decrease, so an
earlier item that passed before the pin can become a violation afterward. The current solver
handles that by restarting the scan after each pin.

A real sub-quadratic or O(n log n) / O(n) improvement would likely need a water-filling-style
algorithm: sort candidates by their minimum/weight breakpoints (or otherwise prove an order
that makes single-pass pinning valid), then distribute after identifying the pinned prefix.
That is a larger correctness-sensitive rewrite, not the issue's proposed fix, and should not
be attempted unless a benchmark shows the current O(n²) loop matters.

### Guard regardless of choice

1. Add a **benchmark** (`measure { }` in a `solverScaleBenchmark` test) measuring current vs.
   post-fix. Include both:
   - easy cascade cases where the first remaining index violates immediately, and
   - harder scan-order cases where the next violating index appears late in the pending list.
   If the delta is sub-millisecond at realistic n, the change is cosmetic and should be
   framed as such in the PR.
2. Add a **correctness test** for a high-iteration min-violation cascade, asserting final
   values and `wasConstrained` results. Avoid asserting "pins exactly n times" unless the
   solver is instrumented for tests; externally visible outputs are the stable contract.
3. Update the issue / PR description to state **O(n²) → O(n²) (constant factor, if any)**
   rather than "O(n³) → O(n²)". Mislabeling an asymptotic fix that isn't one is worse than
   the original over-claim, because it sets the wrong expectation for reviewers.

---

## Open questions

1. **Is there any observed jank that traces back to this loop?** No profile or trace in the
   issue; none in nehir's history. AX frame writes and verification readbacks are a more
   plausible frame-budget consumer than this pure solver loop, but the right answer is a
   trace. If a real repro exists, capture an Instruments time-profile of `tickScrollAnimation`
   at high n before acting.
2. **What is the realistic ceiling on n?** A Niri column stacks windows on one axis. How
   many windows do real users put in one column before it becomes unusable UX regardless of
   perf? If the honest answer is ~15–20, this loop is a non-issue for cost and only the
   readability argument for [A] remains.
3. **Should there be a cap on container window count at all?** Independent of this loop,
   `Sources/Nehir/Core/Layout/Niri/` has no upper bound. Whether one is wanted is a product
   question, not a perf one.
4. **Is the issue's author conflating "windows" and "columns"?** The issue says "20+ windows
   in a single column" but also "many-column workspaces (50+ windows)." The solver's n is
   windows-per-container-on-one-axis, not column count. If the reporter's 50-window scenario
   is 50 *columns* (one window each), the loop runs with n=1 fifty times — trivially cheap —
   and the "50+ windows" framing is measuring the wrong dimension. Worth clarifying with the
   reporter before treating this as a scale problem.

---

## Linked documents

- **Issue:** [BarutSRB/OmniWM#393](https://github.com/BarutSRB/OmniWM/issues/393)
- **Related discovery (a more plausible frame-budget consumer):**
  `discovery/20260614-ax-frame-write-verification-race.md` — the AX frame-write
  and verification-readback path on frame application; a more realistic candidate for any
  observed jank than this pure solver loop.
- **Related finding (test gap):** `discovery/20260613-codebase-review-findings.md`
  §Testing Gaps — "No stress/scale tests: 100+ windows, 10+ monitors, rapid monitor churn"
  and "No coverage measurement in CI." Both directly relevant to why this issue cannot be
  confirmed or refuted from existing evidence.
