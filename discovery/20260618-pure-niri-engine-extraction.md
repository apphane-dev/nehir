# A1 — Extract pure Niri model shared by real runtime and onboarding (first spike) — Discovery

Source direction: upstream WorldStore/EventIntake/IntentLedger/SurfaceReconciler cluster (post-`ee9b4f0`).
Full architecture analysis: [`20260618-worldstore-pure-engine-reuse.md`](20260618-worldstore-pure-engine-reuse.md) (why not to port WorldStore wholesale; A1–A5 framing).
Scope of **this** doc: the first, safest architecture spike — extract a pure, AppKit/AX/SkyLight-free Niri model + reducer + invariants, shared by the SwiftUI onboarding demo and (initially) by tests. Do **not** refactor the real runtime in A1.

---

## TL;DR

- **Nehir today has two parallel implementations of Niri consume-or-expel/focus semantics:** the real `NiriLayoutEngine` (29 files under `Sources/Nehir/Core/Layout/Niri/`) and the onboarding `InteractiveMoveDemo.MoveDemoModel` (`Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift:11`). The onboarding doc comment says the demo "Mirrors Nehir's real gesture input path" and models real consume-or-expel — but it is a separate copy that can drift.
- **The two copies already disagree on three semantics** (verified): vertical index convention is **inverted**; consume-path insertion policy differs (demo appends to end; real inserts at storage-0/visual-bottom); edge wrapping differs (demo no-wrap; real honors `infiniteLoop`). A shared core forces these to a single authoritative answer.
- **Verdict:** 🟡 Architecture spike, not a bug fix. A1 = **pure addition + tests first**, no onboarding/runtime refactor until the three divergences are decided. Safest possible first move toward the A1–A5 pure-engine direction without porting upstream `WorldStore`.

## Ground-truth constraints (load-bearing)

- **The package has one WM-brain target, `Nehir`** (`Sources/Nehir`), which links `AppKit`/`Carbon`/`Metal`/`SkyLight`/`ApplicationServices`. A separate pure SwiftPM target cannot exist today without first extracting shared primitives (`WindowToken`, `WorkspaceDescriptor`, `Direction`, `NodeId`, `ViewportState`, …) that live inside the AppKit-linked target. That would explode A1's blast radius.
- **Therefore the pure core starts life as a subdirectory inside `Sources/Nehir/Core/PureLayout/`**, importing only `Foundation`/`CoreGraphics`, generic over `<ID: Hashable>`. Promotion to a real `NehirPureLayout` target is a later, opt-in refactor.

## What the pure core owns (A1 scope only)

For A1: move/focus left/right/up/down + workspace switch, for the demo's **current** scenario coverage. Nothing else.

- `CoreWindow<ID>`, `CoreColumn<ID>`, `CoreWorkspace<WSID, ID>`, `CoreWorld<WSID, ID>` — value types, generic over `ID`.
- `PureDirection { left, right, up, down }` — decoupled from `Sources/Nehir/Core/Controller/Direction.swift` (which is entangled with `Monitor.Orientation`).
- `PureLayoutReducer` — pure functions on value-type `CoreWorld`: `focus(_:)`, `moveFocusedWindow(_:)` (consume-or-expel left/right; vertical swap up/down), `switchWorkspace(by:)`, `focusWindow(columnIndex:windowIndex:)`. Each returns a new world. No animation, no scroll, no palette.
- `PureLayoutInvariants` — no empty columns (decide the empty-workspace case), focus indices in-bounds, unique window ids, no duplicate window-in-column.

## What stays OUT of the pure core (runtime adapter owns it)

AX handles, real monitor topology, macOS Space topology, frame writes/verification, animation clocks/springs/`displayRefreshRate`, the animation-coupled `ViewportState`, tabbed/overflow-tabbed mode, constraints/preset widths/balanced column count, native fullscreen, hotkeys/Hyper/scratchpad (already removed). A1's pure `SessionPatch` is a scalar selection + viewport-fraction that interpreters render into the real `ViewportState`.

## The three existing divergences (must be decided, not papered over)

1. **Vertical index convention is inverted.**
   - Demo: `focusUp()` → `col.windows[i - 1]` (`InteractiveMoveDemo.swift:225-232`); tiles render top-to-bottom by array index ⇒ lower index = visually higher = "up."
   - Real engine: `moveWindowVertical(.up)` → `node.nextSibling()` (higher storage index) (`NiriLayoutEngine+WindowOps.swift:40`); `NiriNode.swift:635` documents "Storage index 0 is the visual bottom of a column." So higher storage index = visually higher = "up."
   - **Decision (recommended):** adopt the real engine's convention — storage 0 = visual bottom, `.up` = higher index. Flip the demo's render layer (`windowIds.reversed()`) so the visible result is byte-identical.
2. **Consume-path insertion policy differs.**
   - Demo: `cols[resolvedTarget].windows.append(window)` ⇒ end of the list.
   - Real: `consumeOrExpelWindow → moveWindowToColumn(..., targetInsertionPolicy: .visualBottom)` → `visualBottomInsertionIndex` returns `0` (`NiriLayoutEngine+ColumnOps.swift:25-30`).
   - **Decision (recommended):** storage index 0 (visual bottom), matching the real engine. Demo render layer adapts.
3. **Edge wrapping differs.**
   - Demo: guards `cols.indices.contains(target)` and returns silently at the edge — no wrap.
   - Real: `consumeOrExpelWindow(allowEdgeWrap: true)` honors `effectiveInfiniteLoop` config; default `false` ⇒ no wrap, but the API allows it.
   - **Decision (recommended):** the pure reducer takes a `PureConfig { var infiniteLoop: Bool }`, default `false` for A1 (matches demo default and real default). Both sides can exercise either.

A1's job is to make these visible as **failing agreement tests**, then resolve them with a written decision.

## Recommendation

### Step 1 — Pure addition only (no call-site changes)

1. Create `Sources/Nehir/Core/PureLayout/PureLayoutModels.swift`, `PureDirection.swift`, `PureLayoutReducer.swift`, `PureLayoutInvariants.swift` as above. Import only `Foundation`/`CoreGraphics`.
2. Add a **CI/grep guard** that fails if any file under `Sources/Nehir/Core/PureLayout/` references `AppKit|ApplicationServices|AXUIElement|SkyLight|WindowToken|NiriNode|ViewportState`.

### Step 2 — Agreement tests (the load-bearing artifact)

1. `Tests/NehirTests/PureLayoutReducerTests.swift` — reducer invariants; consume-or-expel both branches; focus-neighbor edge behavior; workspace switch.
2. `Tests/NehirTests/PureLayoutAgreementTests.swift` — drive both `MoveDemoModel` and a real-`NiriLayoutEngine` adapter harness through **identical command scripts**; assert identical resulting structure (column count, window-id order per column, focused id). Reuse the existing test helpers in `NiriLayoutEngineTests.swift` (`makeTestHandle`, neighboring-monitor fixtures). The harness asserts only on structure, not animation/scroll.

   Initially, mark the three divergences as failing/`.expectedFailure` — this turns the debt into demand for the decisions in Step 3.

### Step 3 — Decide the three divergences

Short written addendum (in this doc or a sibling) recording which side won and why (recommendations above). Update the reducer accordingly.

### Step 4 — Refactor the demo to delegate (only after Step 3)

Refactor `MoveDemoModel` to back itself with `CoreWorld<Int, Int>`. The `@Published` `workspaces`/`focusedColumnId`/`focusedWindowId` become **derived** computed properties; operations delegate to `PureLayoutReducer`. The model **keeps** scroll/drag/palette/geometry state and render helpers (`resolveHit`, `scrollCentering`, …) — those are not pure semantics. Flip the demo's render convention so storage-0 = visual-bottom holds and the visible layout is unchanged. Then unskip the agreement tests; they should pass.

### Do not proceed to A2 until A1 agreement tests are green and the demo is visually unchanged.

## Acceptance

- `MoveDemoModel` no longer contains consume-or-expel, focus-neighbor, vertical-swap, or workspace-switch logic; it delegates to `PureLayoutReducer`.
- Pure reducer files import only `Foundation`/`CoreGraphics` (grep guard green).
- `PureLayoutAgreementTests` green for focus left/right/up/down; move left/right (both expel and consume branches); move up/down; switchWorkspace forward/backward.
- The three divergences resolved with a written decision.
- No AX frame-write path touched. Real runtime behavior unchanged (reducer consumed only by onboarding + tests in A1).

## Suggested validation

```bash
swift build
swift test --filter PureLayoutReducerTests
swift test --filter PureLayoutAgreementTests
swift test --filter NiriLayoutEngineTests            # real engine unchanged — stays green
# Boundary guard:
rg -n 'import AppKit|import ApplicationServices|AXUIElement|SkyLight|WindowToken|NiriNode|ViewportState' Sources/Nehir/Core/PureLayout
```

## Risks

- **R-A1.1 (HIGH)** — The vertical-convention flip could subtly change what users see in onboarding. Mitigation: render `windowIds.reversed()` so the visual layout is byte-identical; add a screenshot/scene check if one exists.
- **R-A1.2 (MED)** — The pure reducer may need more than the demo currently uses for the real-engine agreement tests. Scope creep risk. Mitigation: A1 covers only what the demo's palette/keyboard bindings expose; other focus ops stay engine-only until A2.
- **R-A1.3 (MED)** — Edge-wrap policy. Mitigation: `PureConfig.infiniteLoop`, default `false` for A1.
- **R-A1.4 (LOW)** — The real engine's `consumeOrExpelWindow` also writes `selectedNodeId`, animation displacement, `ensureSelectionVisible`. The A1 adapter harness must ignore those (not structure) — assert only on the resulting tree shape.
- **If Step 4 is awkward** (the demo needs more from the reducer than expected, or the render flip breaks visible behavior), **that is the signal** the analysis doc warns about — real Niri semantics are too coupled to runtime state to extract cleanly, and the plan should pause before A2.

## Non-goals

- Do **not** port upstream `WorldStore.swift`/`EventIntake`/`IntentLedger`/`DeadlineWheel`/`SurfaceReconciler` wholesale. (See the analysis doc's explicit "what NOT to port" table.)
- Do **not** promote the pure core to a separate SwiftPM target in A1 — land in-place under `Sources/Nehir/Core/PureLayout/` with a grep guard.
- Do **not** refactor the real runtime's focus/move path in A1 — that is A2 (one command end-to-end via a real interpreter).
- Do **not** couple onboarding to AX or real windows. The pure core is the only shared boundary.
- Do **not** silently reconcile the three divergences — make them visible failing tests, then resolve with a written decision.

## Open questions

1. **Vertical convention:** adopt the real engine's (storage-0 = visual bottom — **recommended**) vs. an abstract `Direction`-only model with storage/visual mapping pushed to interpreters. The latter is more flexible but adds indirection A1 does not need.
2. **Empty-workspace invariant:** does the pure core own the "exactly one empty column in an empty workspace" invariant (real engine's `claimEmptyColumnIfWorkspaceEmpty`), or allow zero-column workspaces? Affects the reducer on "remove the last window."
3. **Where the agreement-test adapter harness snapshots the live engine** — reuse the existing `NiriLayoutEngineTests` fixtures; assert only on structure; deliberately avoid tabbed/constraint scenarios (out of A1 scope).

## Relationship to other clusters

- **A2** (effect-plan boundary, one command end-to-end) depends on A1's `CoreWorld`. Do not start A2 until A1's agreement tests are green.
- **A3** (revision stamps) and **A4** (focus intent ledger) are the runtime-side instances of the same ideas; independent of A1 at the code level but conceptually aligned. **A5** (Space topology) is a runtime-adapter concern and must stay out of the pure core — enforced by the grep guard.
