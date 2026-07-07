# OmniWM issue #233 — "Center focused column 'on overflow' triggers with 2 50% sized windows" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/233>
Scope of this doc: determine whether nehir has the "center-on-overflow"
behavior at all, and if so whether it over-triggers on a normal two-column
layout where the focused column still fits on screen.

All file/line references were verified against the Nehir source tree
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace").
Re-verify before implementing; line numbers drift.

---

> **Filed under `discovery/noop/`** — nehir does not have this bug, and the reason
> is not luck: the entire OmniWM mechanism that produced it
> (`CenterFocusedColumn`/`centerFocusedColumn` + the `computeVisibleOffset` dispatch)
> was **deleted** and replaced with a visibility-state-based `RevealPartial` model
> (`completed/20260612-viewport-navigation-redesign.md`). The replacement
> structurally excludes the over-trigger and locks it in with a regression test that is
> the literal #233 scenario. There is no upstream diff to port (BarutSRB closed #233
> `not_planned` without a merged fix), and porting one would be a regression against a
> mechanism that no longer exists. This therefore owns **no new repo action**.

## TL;DR

- **The OmniWM setting that had this bug, `centerFocusedColumn = "onOverflow"`, does not
  exist in nehir — it was removed wholesale and migrated to `revealPartial = .default`.**
  Zero references to `centerFocusedColumn` / `onOverflow` survive in `Sources/` (all hits
  are in `.changeset/` and `` migration history).
- **The replacement design cannot over-trigger on a two-~50%-column layout.** A column
  that fits on screen is classified `.fullyVisible` (`ViewportState+Geometry.swift:623`),
  and `scrollToReveal` returns a no-op whenever the viewport is *filled*
  (`NiriLayoutEngine+ViewportCommands.swift:93-95`) — i.e. exactly the two-columns-fill-the
  -screen case. Centering only happens for a `fullyVisible` column when the viewport is
  *underfilled* (a lone/smaller column floating with margins), which is the intended
  "centering emerges naturally" behavior.
- **The OmniWM #233 scenario is an existing, passing regression test.**
  `scrollToRevealDoesNotMoveFullyVisibleWithDefaultWhenViewportFills`
  (`Tests/NehirTests/ViewportSnapContextTests.swift:555-588`) builds two 400px columns in an
  808px viewport (`400+8+400`, exact fit), sets `revealPartial = .default`, focuses the
  fully-visible second column, and asserts `scrollToReveal` does **not** scroll.
- **Verdict:** 🟢 **Fixed / not present.** This downgrades the catalog's `validate`
  (Med / High-meaningfulness) flag: the bug is not latent in nehir. Its host code was
  deleted and superseded by a design with a passing test for the exact reported case.

## Provenance: is this nehir's code?

**No.** The symbols #233 names — the `centerFocusedColumn`/`"onOverflow"` setting and the
"center focused column on overflow" UI option — **do not exist in nehir**:

- A repo-wide search for `centerFocusedColumn | CenterFocusedColumn | onOverflow |
  alwaysCenterSingleColumn | niriCenterFocused` returns **zero** hits in `Sources/`. The
  only hits are the migration table in
  `.changeset/20260612022904-focus-reveal-policy-and-settings-restructure.md:11-14` and
  the (completed) redesign plan `completed/20260612-viewport-navigation-redesign.md`.
- The redesign's Task 9 deleted them explicitly:
  "remove `CenterFocusedColumn` enum + `centerFocusedColumn` property from `NiriLayoutEngine`"
  (`completed/20260612-viewport-navigation-redesign.md:248`) and
  "delete `computeVisibleOffset` (now dead code)" (`:252`).

What replaced them is nehir's code, in nehir's files, and it is what this doc validates:

- `RevealPartial` enum (`.default`, `.off`, `.snapClosest`, `.snapCenter`) —
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:4`.
- `ColumnVisibility` (`.fullyVisible`, `.clipped(edge)`, `.parked(edge)`) —
  `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift:62`.
- `columnVisibility(for:…)` — `ViewportState+Geometry.swift:623`.
- `fillsViewport(at:in:)` — `ViewportState+Geometry.swift:136`.
- `scrollToReveal(columnIndex:isFFM:…)` —
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:62`.

## Upstream issue summary

Filed 2026-04-11 on OmniWM (≈0.4.7.x) by `Guria`. With **"Center Focused Column" set to
"overflow"**, focusing either of two windows whose widths sum to ~100% wrongly recenters
the focused window — even though it still fits on screen:

> "Now when I have 2 windows and their width sums up to close to 100% it starts centering
> focused window even if it still fits on screen."

**Reporter's workaround:** subtract 0.01 from each column-width preset so the sum never
reaches 100%:

```jsonc
"niriColumnWidthPresets": [ 0.39, 0.49, 0.59, 0.95 ]
```

…which the reporter notes also *suppressed* centering on genuinely overflowing windows
(a OmniWM-specific quirk, not the nehir behavior — see below).

**BarutSRB's own root-cause note (2026-04-11):**

> "the bug is because now overflow doesn't clamp the windows left side to the left edge
> instead it centers it."

He promised a same-day fix tied to the newly-added side overscroll, but **no fix was
merged**. The issue was **closed as `not_planned`** on 2026-05-05 as part of a
"v0.4.8+ issue cleanup" because the conversation "predates the v0.4.8 release on
2026-04-21." A **related but distinct** issue, #345 ("Workspace bar window navigation
centers Niri column despite `centerFocusedColumn = never`"), was later linked — that one
is about the *workspace bar* navigation path, not the overflow-centering of #233.

## The code in question

### 1. The migration: `onOverflow` → `revealPartial = .default`

The removed OmniWM setting maps onto nehir's new model one-to-one:

```swift
// .changeset/20260612022904-focus-reveal-policy-and-settings-restructure.md:11-14
| centerFocusedColumn = "never"     | remove it, or set revealPartial = "off"      |
| centerFocusedColumn = "onOverflow"| revealPartial = "default" (closest equivalent) |  // ← #233's setting
| centerFocusedColumn = "always"    | revealPartial = "snapCenter"                 |
```

So the OmniWM user in #233 (on `onOverflow`) is, in nehir, a `revealPartial = .default`
user. That is the mode to validate.

### 2. Why `revealPartial = .default` cannot over-trigger on a filled viewport

`scrollToReveal` classifies the target column and branches on visibility
(`NiriLayoutEngine+ViewportCommands.swift:62`):

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:62, 92-104
func scrollToReveal(columnIndex: Int, isFFM: Bool, state: inout ViewportState,
                    context: ViewportSnapContext, motion: MotionSnapshot,
                    scale: CGFloat = 2.0, animationConfig: SpringConfig? = nil) -> Bool {
    guard !isFFM else { return false }
    ...
    let visibility = context.visibility(of: columnIndex, viewportOffset: viewStart, in: state)
    ...
    switch visibility {
    case .fullyVisible:
        if revealPartial != .default || context.fillsViewport(at: viewStart, in: state) {  // :94
            return false                                                                    // ← no-op
        }
        targetSnap = defaultSnap()        // center only when viewport is UNDER-filled
    case .parked:
        targetSnap = revealPartial == .default ? defaultSnap()
            : targetColumnSnapCandidates().closest(to: viewStart)
    case .clipped:
        switch revealPartial {
        case .default:  targetSnap = defaultSnap()
        case .off:      return false
        ...
        }
    }
    ...
}
```

The `.fullyVisible` branch at `:93-95` is the structural fix for #233. A column is
`.fullyVisible` when it lies entirely within the viewport
(`ViewportState+Geometry.swift:623`, `columnStart >= viewportStart - tol &&
columnEnd <= viewportEnd + tol`). With two ~50%-width columns side by side, **both**
columns are fully visible, and the viewport is filled — so `fillsViewport(at: viewStart)`
is `true` and `scrollToReveal` returns `false`. No centering.

`fillsViewport` measures real content coverage, not the old "did something nominally
overflow" heuristic, and it is gap-aware with a generous tolerance:

```swift
// Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift:136-160  (fillsViewport)
func fillsViewport(at viewportStart: CGFloat, in state: ViewportState,
                   pixelTolerance: CGFloat = 0.5) -> Bool {
    if intentionallyDoesNotFillViewport { return false }
    let viewportEnd = viewportStart + viewportWidth
    var fullColumnIndices: [Int] = []
    for index in columns.indices {
        let start = state.columnX(at: index, columns: columns, gap: gap)
        let end = start + max(0, columns[index].cachedWidth)
        if start >= viewportStart - pixelTolerance, end <= viewportEnd + pixelTolerance {
            fullColumnIndices.append(index)
        }
    }
    guard let first = fullColumnIndices.first, let last = fullColumnIndices.last else { return false }
    for index in first ... last where !fullColumnIndices.contains(index) { return false } // no gaps
    ...
    let tolerance = max(pixelTolerance, 2 * gap + pixelTolerance)   // ← absorbs inter-column gaps
    return abs(coveredWidth - viewportWidth) <= tolerance
}
```

The `2 * gap + pixelTolerance` tolerance is exactly what makes the OmniWM reporter's
`-0.01` workaround unnecessary: two columns that sum to ~100% plus a gap are still
recognized as "viewport filled," so the `fullyVisible` short-circuit fires and no
centering occurs.

### 3. Genuine overflow still centers — correctly

When a column is genuinely clipped (`case .clipped`, `:102-104`), `.default` calls
`defaultSnap()`, which prefers a closest target-column snap *only if that position fills
the viewport*, and otherwise centers (`:81-88`):

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:81-88  (defaultSnap)
func defaultSnap() -> SnapPoint? {
    let targetSnaps = targetColumnSnapCandidates()
    let closest = targetSnaps.closest(to: viewStart)
    if let closest, context.fillsViewport(at: closest.offset, in: state) {
        return closest                         // edge-clamp when it still fills
    }
    return targetSnaps.first { $0.kind == .center } ?? closest   // else center
}
```

This matches the redesign's stated decision table: *"closest target-column snap only
when the resulting viewport is a proportional fit; center otherwise."* It is the
behavior BarutSRB said he wanted but shipped broken in the OmniWM `onOverflow` mode ("clamp
the window's left side to the left edge instead of centering"). nehir already does it.

## Why it does not apply to nehir

The #233 over-trigger required two ingredients, **both of which are absent in nehir**:

| #233 ingredient (OmniWM) | nehir state |
|---|---|
| The `centerFocusedColumn = "onOverflow"` setting / "center on overflow" UI option | **Deleted.** No references in `Sources/`; migrated to `revealPartial = .default` (`.changeset:12`). |
| An overflow heuristic that fires centering without checking whether content actually overflows the *viewport* | **Absent.** `scrollToReveal` branches on geometric `columnVisibility` (`fullyVisible`/`clipped`/`parked`) and returns a no-op for `fullyVisible` + viewport-filled (`NiriLayoutEngine+ViewportCommands.swift:93-95`). |
| No "viewport already filled" guard | **Present.** `fillsViewport` (`ViewportState+Geometry.swift:136`) is the explicit guard, gap-tolerant at `2*gap+pixelTolerance`. |

The OmniWM reporter's secondary observation — that the `-0.01` workaround *also* suppressed
centering on genuinely overflowing windows — is a OmniWM-only artifact of how that build
computed "overflow." nehir's clipped path (`:102-104`) centers real overflow regardless of
column-width tuning, so the workaround neither helps nor is needed.

### The bug is locked out by a regression test

`scrollToRevealDoesNotMoveFullyVisibleWithDefaultWhenViewportFills`
(`Tests/NehirTests/ViewportSnapContextTests.swift:555-588`) is the literal #233 scenario:

```swift
// Tests/NehirTests/ViewportSnapContextTests.swift:555-588
@Test func scrollToRevealDoesNotMoveFullyVisibleWithDefaultWhenViewportFills() {
    let engine = NiriLayoutEngine()
    engine.revealPartial = .default                              // ← the onOverflow equivalent
    ...
    let first  = engine.addWindow(handle: makeTestHandle(pid: 511), to: wsId, afterSelection: nil)
    let second = engine.addWindow(handle: makeTestHandle(pid: 512), to: wsId, afterSelection: first.id)
    let columns = engine.columns(in: wsId)
    assignWidths(columns, widths: [400, 400])                    // two equal columns
    let workingFrame = CGRect(x: 0, y: 0, width: 808, height: 600) // exact fit: 400+8+400  (:567)
    ...
    // Column 1 is fully visible and fills viewport             // (:579)
    let revealed = engine.scrollToReveal(columnIndex: 1, isFFM: false,
                                         state: &state, context: context, motion: .disabled)
    #expect(!revealed)                                           // (:588) — no centering
}
```

Two 400px columns in an 808px viewport (exact fit) with `revealPartial = .default`,
focus the fully-visible second column → **no scroll.** This is #233 verbatim, asserted as
the desired behavior.

## Recommendation

**Do not port, and file no action.** Three independent reasons:

1. **Nothing to port.** Upstream never merged a fix; #233 was closed `not_planed` as a
   stale-sweep. There is no diff.
2. **Nothing to port against.** The host mechanism (`centerFocusedColumn` +
   `computeVisibleOffset`) was deleted in the viewport-navigation redesign
   (`completed/20260612-viewport-navigation-redesign.md:248,252`). A direct
   port would resurrect a removed code path and conflict with the snap-grid /
   `RevealPartial` model that replaced it.
3. **Already guarded + tested.** nehir's `scrollToReveal` `.fullyVisible` + `fillsViewport`
   short-circuit (`NiriLayoutEngine+ViewportCommands.swift:93-95`) is a stricter, earlier
   layer than the OmniWM "onOverflow" heuristic, and the regression test above locks it in.

The only follow-up worth noting (not an action for *this* item) is the **related** upstream
issue #345, which is a *different* path — workspace-bar window navigation centering a column
even with `centerFocusedColumn = never`. That path is out of scope for #233 (overflow
centering) and has no nehir discovery yet; if #345 is triaged, it should be discovered on
its own against nehir's workspace-bar focus projection (`20260615-workspace-bar-focus-projection-routing.md`
is the adjacent nehir doc) rather than under #233.

## Suggested tests

None required — the governing test already exists and passes
(`ViewportSnapContextTests.swift:555`). If one wanted belt-and-suspenders coverage of the
gap-tolerance that makes the OmniWM `-0.01` workaround unnecessary, a parametrized variant is
straightforward:

1. **Two columns slightly over 50% still don't center under `.default`.** Reuse the
   `scrollToRevealDoesNotMoveFullyVisibleWithDefaultWhenViewportFills` harness but set
   widths `[404, 404]` in an 808px viewport (each column 50% + half-gap, summing to
   `808 + gap` — a touch over 100%, the realistic "close to 100%" case). Assert both
   columns classify `.fullyVisible` and `scrollToReveal` returns `false`. This pins the
   `2*gap + pixelTolerance` tolerance in `fillsViewport` against the exact #233
   "widths sum to close to 100%" phrasing.
