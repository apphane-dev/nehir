# Upstream test purge and Nehir's test direction — Discovery

Verified against the main Nehir source tree at `d88a5da2` and the upstream
OmniWM tree at `36e823a9` on 2026-07-12. This is a **direction** discovery: it
records a decision about how Nehir tests should evolve, not a runtime bug.

Companion: [`20260708-test-only-seams-can-make-tests-untruthful.md`](20260708-test-only-seams-can-make-tests-untruthful.md)
(plans-branch commit `7b291bce`). That audit diagnosed *why* the inherited
suite can lie; this document decides *what to do about the suite as a whole*,
prompted by upstream deleting theirs.

---

## TL;DR — the direction

Upstream (BarutSRB/OmniWM) deleted its entire ~60K-line test suite in one
commit and rebuilt a smaller, differently-shaped one. Their diagnosis was
right; their remedy does not fit Nehir.

**Decision: no purge. Keep the suite and the CI gate. Converge on upstream's
new test shape incrementally, using the seams audit as the quality bar.**

1. New regression tests go into **small, per-behavior files** (one concern per
   file), never appended to the legacy monoliths.
2. New tests must satisfy the seams rubric: **hooks observe, they do not
   decide** — no new `if testFlag { return }` branches in `Sources/`, no
   assertions against state that exists only on a test-disabled path.
3. **Per-file deletion is allowed and encouraged** when a legacy test file
   blocks a refactor or an upstream port *and* inspection shows it asserts
   mock choreography or internals rather than behavior. Judged, rolling
   deletion — not a one-commit purge.
4. When porting upstream work that ships its own post-purge test files, prefer
   **adapting upstream's new tests** over retrofitting the legacy suite.
5. The seams remediation order (issues 1–5 in the companion audit) is the
   truthfulness track; this direction is the shape track. Both proceed
   independently.

---

## What upstream did

### The purge

Upstream commit `deb4f247` ("Remove stale test harness", 2026-06-10) deleted
**77 files, 59,982 lines** — the whole `Tests/OmniWMTests` tree. It went
beyond deleting files:

- removed the `test` target and dropped `swift test` from `release-check` and
  `verify` in the Makefile;
- removed `-enable-testing` from the main target in `Package.swift`;
- rewrote CONTRIBUTING.md to replace "test it" / "testing notes" with
  "verify it" / "verification notes".

The deleted suite's hotspots match what Nehir inherited: a 10,894-line
`AXEventHandlerTests.swift`, an 8,355-line `NiriLayoutEngineTests.swift`, a
5,212-line `RefreshRoutingTests.swift`, and a shared mock harness
(`TestSharedStateSupport`, `MotionTestSupport`, `LayoutPlanTestSupport`,
`TokenCompatibilityTestSupport`).

### The motive

The purge immediately precedes a chain of architecture rewrites, starting the
same minute: `8baadb6c` "Consolidate runtime refresh and focus ownership"
(LayoutRefreshController largely rebuilt, new `AXFrameApplicationLedger`),
then `bcb3dff7` "Add IntentLedger and DeadlineWheel", `47106f8c` "Delete
FocusBridgeCoordinator; IntentLedger owns focus requests", "Refactor 6"
(`5f3883da`), IPC v7 (`c044f652`). A 60K-line suite `@testable`-coupled to
those internals would have made each rewrite cost enormous test churn. The
purge cleared the runway.

### The rebuild

As of upstream `36e823a9` (2026-07-11) the suite is back at **96 files,
~22K lines**, with a very different shape:

- files are added **per feature/fix, in the same commit** (e.g. the min-size
  work in `f4903f89` ships `DwindleMinimumSizeTests`, `NiriAxisSolverTests`,
  `NiriColumnMinWidthTests`, `NiriColumnTransferFeasibilityTests`,
  `OverflowCappedConstraintsTests` — five small focused files);
- files are small and named for one behavior (`HiddenBarAntiFlapTests`,
  `QuakeTerminalGeometryPolicyTests`, `CursorContainmentHandlerTests`);
- tests target pure-logic seams — geometry, animation math, solvers, policy
  decisions — and are almost mock-free (2 of 96 files mention mock/fake/stub,
  vs. the old dedicated mock-harness support files);
- still XCTest (all 94 test classes), while Nehir has migrated to Swift
  Testing.

Two caveats that temper the story:

- **Tests were never re-gated.** Upstream's Makefile `verify` today is
  `format-check lint build`; there is no `test` target. The rebuilt suite is
  advisory.
- **The riskiest window had zero coverage.** The purge landed immediately
  *before* the biggest rewrites, so the IntentLedger-era rework shipped with
  no regression net at all.

---

## Assessment of upstream's move

Mostly reasonable *for them*, with one real flaw.

The diagnosis was correct: a suite dominated by internals-coupled monoliths
and a heavy shared mock harness is a refactoring tax, and — as Nehir's own
seams audit independently confirmed — much of it validated mock choreography
on paths production never runs. The rebuilt suite's shape (small,
per-behavior, pure-seam, mock-light) is genuinely better.

The flaw: deleting coverage *before* the riskiest refactors and never
restoring the gate reveals the priority was velocity, not test truthfulness.
That is a defensible trade for a solo author in a domain (AX/window-server)
where the real acceptance signal is manual runtime behavior — and would be
reckless in a multi-contributor project.

---

## Nehir's situation is different

| Axis | Upstream at purge time | Nehir now |
|---|---|---|
| Suite | ~60K lines, 77 files, XCTest, stagnant relative to the rewrite plans | 60,805 lines, 87 files, fully migrated to Swift Testing (83 test files import `Testing`, zero `XCTest`) |
| Maintenance | Blocking planned architecture rewrites | Actively curated: 119 test-touching commits since 2026-04 |
| Gating | Removed from `verify`/`release-check` | Gated in CI (`mise run test` in the test job of `.github/workflows/ci.yml`), with a deliberate split running `IPCServerTests` in its own helper process first (see `.config/mise/conf.d/tasks-test.toml`) |
| Motive for purge | Clear runway for IntentLedger-scale rework | No equivalent rework planned; Nehir does targeted fixes and selective upstream ports |
| What tests encode | Largely pre-rewrite internals | Curated regression repros for user-confirmed fixes (Gecko transient dialog floating, focus-follows-mouse Dock regressions, quick-terminal refocus, viewport stability) — per the repo workflow, tests are written *after* the user confirms a fix, so they document real repros |

Deleting Nehir's suite would erase encoded knowledge of dozens of confirmed
regressions and remove a gate that is actually enforced. The purge motive
does not transfer.

But upstream's diagnosis *partially* applies to Nehir:

- `Tests/NehirTests/AXEventHandlerTests.swift` is **11,354 lines** — already
  larger than the 10,894-line file upstream deleted. `NiriLayoutEngineTests.swift`
  is 7,831 lines, `RefreshRoutingTests.swift` 4,712, `MouseEventHandlerTests.swift`
  3,832. The monolith pattern is growing, not shrinking.
- The shared harness (`Tests/NehirTests/TestSharedStateSupport.swift` and
  friends) is exactly what the seams audit flagged: it forces
  `NativeFullscreenPlaceholderManager.materializesWindowsForTests = false` as
  the *default* test state, so much of the suite runs a non-production path by
  default.
- The seams audit's headline risk — tests passing on paths production never
  runs — is the same property that made upstream's suite "stale" in practice.
  Upstream escaped it by deletion; Nehir should escape it by remediation
  (the audit's candidate implementation order) plus a shape change for new
  tests.

### A new ongoing cost created by upstream's purge

Since `deb4f247`, upstream commits no longer touch the suite lineage Nehir
maintains. Every upstream port now carries extra test-adaptation work on
Nehir's side — the legacy files no longer have upstream counterparts to diff
against. Conversely, upstream features now arrive *with* small new-style test
files, which are usually cheaper to adapt (Swift Testing conversion is
mechanical) than to re-express in the legacy monolith style. Direction point 4
follows from this.

---

## The direction, in full

1. **No purge; keep the CI gate.** The suite stays, `mise run test` stays
   required in CI. Nehir explicitly does not copy upstream's un-gating.
2. **Freeze the monoliths.** New tests never land in
   `AXEventHandlerTests.swift`, `NiriLayoutEngineTests.swift`,
   `RefreshRoutingTests.swift`, `MouseEventHandlerTests.swift`,
   `LayoutRefreshControllerTests.swift`, or `WorkspaceManagerTests.swift`.
   New regression tests go into small per-behavior files named for the
   behavior (upstream's post-purge convention), e.g.
   `Tests/NehirTests/QuickTerminalRefocusTests.swift`, not "the handler's
   file".
3. **Seams rubric is the acceptance bar for new tests.** From the companion
   audit: pure planners tested directly; effectful reconcilers run one path in
   production and tests; OS boundaries injected as scoped dependencies; fakes
   record calls instead of causing early returns; hooks observe, never decide.
   A new test that requires a new `ForTests` conditional in `Sources/` that
   changes a Nehir-owned decision is rejected at review.
4. **Rolling, judged deletion of legacy tests.** When a legacy test file (or
   test) blocks a refactor or an upstream port, inspect it: if it asserts mock
   choreography, `ForTests`-only state, or internals with no behavioral
   contract, delete or rewrite it in the new shape as part of that change.
   Cite this discovery in the commit body when doing so. This is the judged
   version of what upstream did indiscriminately.
5. **Opportunistic monolith splitting.** When a fix touches a behavior whose
   tests live in a monolith, moving the relevant tests out into a
   per-behavior file is in scope for that change. No dedicated big-bang
   splitting project.
6. **Prefer upstream's new test files when porting.** For upstream work that
   ships post-purge tests, adapt those files (XCTest → Swift Testing, upstream
   names → Nehir names) instead of extending legacy files.
7. **Seams remediation proceeds per the companion audit's candidate order**
   (placeholder materializer fake, tabbed-overlay plan extraction, frame-apply
   override removed from scheduling decisions, explicit window-info resolver
   policies, scoped AX/SkyLight providers). Each step deletes a production
   `ForTests` decision point and is a natural trigger for direction points
   4–5 on the affected test files.

## Non-goals

- Bulk deletion of `Tests/NehirTests` or any single-commit purge.
- Removing tests from `verify`/CI, or making the suite advisory.
- Migrating the suite's framework again (Swift Testing migration is done and
  is an advantage over upstream's XCTest rebuild, not churn to revisit).
- A dedicated "split all monoliths" project with no functional driver.

## Follow-ups

- Turn seams-audit issue 1 (placeholder materializer) into a plan in
  `planned/`; it is the smallest self-contained step that also removes the
  suite-wide non-production default in `TestSharedStateSupport.swift`.
- When the next upstream port lands, trial direction point 6 and record how
  much adaptation the post-purge test files actually needed.
