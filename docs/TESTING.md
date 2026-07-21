# Testing

How to run the Nehir test suite, where new tests go, and the policy that
governs the suite's evolution. Applies to human contributors and AI agents
alike.

## Running tests

```bash
mise run test          # full suite (requires Xcode, not just CommandLineTools)
mise run test:compile  # fast check that the test target builds
```

`mise run test` kills any running Nehir instance first, then runs
`IPCServerTests` in its own helper process before the rest of the suite.
Xcode's `swiftpm-testing-helper` can SIGTRAP when the socket-backed
`IPCServerTests` run after AppKit-heavy suites; the split keeps the coverage
without the flake. Don't collapse the two invocations back into one.

Tests are gated in CI (`.github/workflows/ci.yml`, `mise run test` on
`macos-26`). Keep them gated: the suite is a required check, not advisory.

The suite uses **Swift Testing** (`import Testing`), not XCTest. New tests use
Swift Testing.

## When to write tests

**Do not add, modify, rewrite, or delete tests until the user has confirmed the
implementation or fix works in their real repro.** This applies to all work —
new features, refactors, and bug fixes alike. The trigger is *unconfirmed
behavior*, not *bug vs feature*: "this is a new feature, not a bug fix" is
explicitly **not** an exception, and reverting or removing existing tests counts
as editing them.

A plan, spec, or delegated task that includes a "write tests" step does **not**
authorize writing tests before runtime confirmation. The runtime-confirmation
gate overrides any plan's test phase; when they conflict, wait for the user's
confirmation.

The underlying principle: the user's real-repro validation is the acceptance
signal. Runtime traces and that validation are what confirm the behavior; tests
written before it waste effort and create churn. After confirmation, add a
regression test if requested or clearly useful. This makes the suite a curated
record of real, confirmed repros.

## Where new tests go

**New tests land in small, per-behavior files** named for the behavior under
test — e.g. `Tests/NehirTests/QuickTerminalRefocusTests.swift` — not in the
file named after the handler or engine that happens to contain the code.

The legacy monoliths are **frozen**: do not add tests to

- `Tests/NehirTests/AXEventHandlerTests.swift`
- `Tests/NehirTests/NiriLayoutEngineTests.swift`
- `Tests/NehirTests/RefreshRoutingTests.swift`
- `Tests/NehirTests/MouseEventHandlerTests.swift`
- `Tests/NehirTests/LayoutRefreshControllerTests.swift`
- `Tests/NehirTests/WorkspaceManagerTests.swift`

When a change touches behavior whose existing tests live in a monolith, moving
those tests out into a per-behavior file is in scope for that change.
There is no big-bang splitting project; the monoliths shrink opportunistically.

## Truthfulness rules for new tests

The bar, in one line: **test hooks observe; they do not decide.** Concretely:

1. **No new `ForTests` conditionals in `Sources/` that change a Nehir-owned
   decision.** A test flag must never cause production logic to skip
   reconciliation, lifecycle work, scheduling, fallback, or cleanup
   (`if testFlag { return }` tests a different product).
2. **Fake the OS boundary, not the algorithm.** AX / SkyLight / AppKit
   boundaries are injected as scoped dependencies; Nehir's own logic runs the
   same path in production and tests. Fakes record calls instead of causing
   early returns.
3. **Prefer pure seams.** Where a behavior can be expressed as a pure planner
   (input model → desired operations), test the planner directly and keep the
   effectful reconciler on a single shared path.
4. **Never assert against state that only exists on a test-disabled path.**
   If the observable you want to assert is only recorded when a
   `disables...ForTests` flag is set, the test is validating bookkeeping, not
   the product.
5. **Scope and reset any global provider.** Global mutable `...ForTests`
   statics leak between tests and break parallelism; use scoped isolation
   helpers, and treat direct assignment without a `defer` reset as a review
   defect.

Background and the audited inventory of existing violations live in the
plans branch: `discovery/20260708-test-only-seams-can-make-tests-untruthful.md`.
Existing seams that violate these rules are being removed in that audit's
candidate order; new code must not add more.

## Deleting legacy tests

Rolling, judged deletion is allowed and encouraged. When a legacy test file
(or individual test) blocks a refactor or an upstream port, inspect it before
adapting it: if it asserts mock choreography, `ForTests`-only state, or
internals with no behavioral contract, **delete or rewrite it in the
per-behavior shape as part of that change**, and say so in the commit body.

What is not allowed: bulk deletion of the suite, removing tests from CI, or
deleting a test that encodes a confirmed user repro without replacing the
coverage.

## Tests when porting upstream work

Upstream (BarutSRB/OmniWM) deleted its pre-2026-06 test suite and now ships
small per-behavior XCTest files alongside each feature. When porting upstream
work, **prefer adapting upstream's new test files** (XCTest → Swift Testing,
upstream names → Nehir names) over retrofitting Nehir's legacy files. The
legacy suite no longer has upstream counterparts to diff against.

The full evaluation of upstream's test purge and the rationale for this
policy live in the plans branch:
`discovery/20260712-upstream-test-purge-and-nehir-test-direction.md`.
