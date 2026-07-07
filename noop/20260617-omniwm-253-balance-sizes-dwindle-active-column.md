# OmniWM issue #253 — "balance-sizes only affects active column (Dwindle)" — Discovery

Source issue: https://github.com/BarutSRB/OmniWM/issues/253
Scope of this doc: determine whether the `balance-sizes` "only rebalances the active column"
bug applies to nehir, and whether the same root cause exists in nehir's Niri layout engine.

All file/line references were verified against the Nehir source tree at `904df02`
("Add bunch of discoveries mapped to issues from OmniWM"). Line numbers drift — re-verify
before implementing.

> **Filed under `discovery/noop/`** — the verdict is ⚪ **Not applicable / don't port** for two
> independent, reinforcing reasons. (1) The bug is **Dwindle-specific**: #253 is triggered by
> `balance-sizes` in Dwindle mode, and nehir has **no Dwindle layout engine** — a recursive
> case-insensitive search for `dwindle` returns zero source/test hits (re-confirming the
> `#270` / PR `#401` noop siblings). (2) Even on the alternate path the triage notes flag —
> nehir *does* have a Niri `balanceSizes` — the root cause #253 describes **does not exist**:
> nehir's Niri `balanceSizes` already iterates over **all** columns in the workspace (not just
> the focused column's siblings) and resets every window in every column. The implementation
> already does what #253 says the fix should do, and a test locks in that all-columns behavior.
> Owns no new repo action; there is nothing to port. See sibling docs
> `noop/20260616-omniwm-270-dwindle-third-window-outside-grid-overlap.md` and
> `noop/20260616-omniwm-401-dwindle-per-monitor-split-orientation.md`.

---

## TL;DR

- **`balance-sizes` in #253 is a Dwindle-layout bug, and nehir has no Dwindle layout; and the
  same root cause does not exist in nehir's Niri `balanceSizes`, which already balances all
  columns.** A recursive grep for `dwindle` across `Sources/` and `Tests/` returns nothing;
  meanwhile nehir's Niri `balanceSizes` iterates `for column in columns(in: workspaceId)` —
  i.e. every column in the workspace — resetting each column's width and every window's
  `size` to `1.0`.
- **Verdict:** ⚪ **Not applicable / don't port.** The cited Dwindle code does not exist in
  nehir, and the equivalent Niri path already exhibits the *correct* (all-column) behavior the
  issue says is missing. The triage flag (`validate`, Med/Med) is resolved: the bug class has no
  analogue here. The issue is also **closed / not_planned** upstream.

## Provenance: is this nehir's code?

The issue's command
binding `LAlt + 0 → balance-sizes` maps to nehir's `balanceSizes` command, which *does* exist —
but as a **Niri** operation, never Dwindle:

- Command enum + dispatch (Niri path):
  `Sources/Nehir/Core/Input/HotkeyCommand.swift:64` (`case balanceSizes`),
  `Sources/Nehir/Core/Controller/CommandHandler.swift:163` (`case .balanceSizes: controller.niriLayoutHandler.balanceSizes()`),
  `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1476` (`func balanceSizes()`).
- Core implementation (Niri engine):
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift:246` (`func balanceSizes(in:motion:workingAreaWidth:gaps:)`).

There is no Dwindle layout engine, no Dwindle `balanceSizes`, and no layout-mode selector in
nehir (see the recursive-search evidence below). So the issue's *surface command* exists, but
its *buggy backend* (Dwindle) does not.

## The code in question

**The Dwindle backend does not exist.** Recursive searches return zero source/test hits:

```
$ grep -RIn --exclude='*.md' -i dwindle Sources Tests    # zero hits
$ find Sources -iname '*dwindle*'                         # zero hits
```

`ffgrep -i dwindle` matches only the sibling noop discovery docs (`#270`, `#401`) and this
doc — never `Sources/` or `Tests/`. nehir's only layout backend is the Niri column-scrolling
engine under `Sources/Nehir/Core/Layout/Niri/`. This re-confirms the findings of the `#270` and
`#401` noop siblings.

**nehir's Niri `balanceSizes` already balances all columns.** The implementation:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift:246
func balanceSizes(
    in workspaceId: WorkspaceDescriptor.ID,
    motion: MotionSnapshot,
    workingAreaWidth: CGFloat,
    gaps: CGFloat
) {
    let cols = columns(in: workspaceId)          // line 249 — ALL columns in the workspace
    guard !cols.isEmpty else { return }

    let resolvedWidth = resolvedColumnResetWidth(in: workspaceId)
    let targetPixels = ProportionalSize.resolveProportionalSpan(
        resolvedWidth.proportion,
        availableSpace: workingAreaWidth,
        gaps: gaps
    )

    for column in cols {                          // line 261 — iterates EVERY column, no focus filter
        column.width = .proportion(resolvedWidth.proportion)
        column.isFullWidth = false
        column.savedWidth = nil
        column.presetWidthIdx = resolvedWidth.presetWidthIdx
        column.hasManualSingleWindowWidthOverride = false

        column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate,
            animated: motion.animationsEnabled
        )

        for window in column.windowNodes {        // line 277 — resets EVERY window, every column
            window.size = 1.0
        }
    }
}
```

The "all columns" claim is verifiable end to end:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:247
func columns(in workspaceId: WorkspaceDescriptor.ID) -> [NiriContainer] {
    guard let root = roots[workspaceId] else { return [] }
    return root.columns                          // the workspace root's columns
}

// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:864
var columns: [NiriContainer] {
    if let cached = _cachedColumns { return cached }
    let result = children.compactMap { $0 as? NiriContainer }   // ALL children, no focus filter
    _cachedColumns = result
    return result
}
```

There is **no** `selectedColumn` / `activeColumn` / `focusedColumn` gate anywhere in this path.
`root.columns` returns every child column of the workspace root, and `balanceSizes` loops over
all of them.

## Why the bug does not apply

The issue's own root-cause hypothesis is, verbatim:

> "This appears to be a logic error in the `balance-sizes` implementation — it likely queries
> only the currently focused container's siblings rather than iterating across all columns in
> the workspace."

nehir's Niri `balanceSizes` does exactly what #253 says the *fix* should do: it iterates across
all columns (`for column in columns(in: workspaceId)`) rather than the focused container's
siblings. The buggy query pattern ("focused container's siblings") has no analogue in the Niri
engine — the Niri `columns(in:)` path is workspace-scoped, not focus-scoped. Two independent
reasons the bug cannot apply:

1. **No Dwindle backend.** The reported bug is in Dwindle-mode `balance-sizes`; nehir has no
   Dwindle engine at all (recursive `grep -i dwindle` → zero source/test hits), so the
   Dwindle-specific sibling-iteration code path simply does not exist.
2. **The Niri path is already correct.** nehir's own `balanceSizes` balances all columns. The
   "only active column" symptom cannot reproduce because the implementation never filters to a
   single column.

**Test evidence that the all-columns behavior is locked in.**
`Tests/NehirTests/NiriLayoutEngineTests.swift:5866`
(`balanceSizesUsesExplicitDefaultWidthAndResetsManualState`) builds a workspace with **three**
columns, mangles each column with a distinct width/preset/fullWidth/savedWidth/override and
distinct window sizes, then runs `engine.balanceSizes(...)`, then asserts on `for column in
columns` that **every** column is reset:

```swift
// Tests/NehirTests/NiriLayoutEngineTests.swift:5889 (mangle all three columns)
for (index, column) in columns.enumerated() {
    column.width = index == 0 ? .fixed(900) : .proportion(0.4 + CGFloat(index) * 0.1)
    column.presetWidthIdx = index
    column.isFullWidth = true
    column.savedWidth = .fixed(700 + CGFloat(index) * 25)
    column.hasManualSingleWindowWidthOverride = true
    for window in column.windowNodes { window.size = CGFloat(index + 2) }
}

// Tests/NehirTests/NiriLayoutEngineTests.swift:5900 (assert all three reset)
for column in columns {
    #expect(column.width == .proportion(0.85))
    #expect(column.presetWidthIdx == 0)
    #expect(!column.isFullWidth)
    #expect(column.savedWidth == nil)
    #expect(!column.hasManualSingleWindowWidthOverride)
    for window in column.windowNodes { #expect(window.size == 1.0) }
}
```

If the #253 "only active column" bug existed here, two of the three columns would retain their
mangled state and these expectations would fail. The sibling tests
`balanceSizesFallsBackToAutoWidthWhenDefaultWidthIsAuto` (`:5944`) and
`balanceSizesUsesExplicitDefaultWidthWithoutPresetMatch` (`:5977`) likewise build three columns
and assert all three are rebalanced. This is direct, executable proof that nehir's
`balanceSizes` already operates across all columns.

Note: the two other balance-related names found in nehir —
`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:89` (`balancedColumnCount`) and
`Sources/Nehir/Core/Config/SettingsStore.swift:123` (`.balanced(columns:)`) — are the Niri
"balanced" default-column-width mode, not the `balance-sizes` action, and are unrelated to this
bug.

## Recommendation

**Do not port.** No action is owned here:

- There is no Dwindle `balance-sizes` to patch (engine absent — re-confirms `#270`/`#401`).
- The Niri `balanceSizes` already balances all columns correctly, with multi-column test
  coverage; porting a Dwindle "iterate all columns" fix would be a no-op against code that
  already does this. Doing so would risk regressing the tested Niri behavior.

If a Dwindle/BSP layout is ever introduced into nehir, re-open this item and ensure that
engine's `balance-sizes` iterates the whole workspace (the pattern nehir's Niri engine already
follows), not the focused node's siblings.

## Suggested tests

N/A for current nehir: the all-columns behavior is already covered by the three
`balanceSizes…` tests in `Tests/NehirTests/NiriLayoutEngineTests.swift` (lines `5866`, `5944`,
`5977`), each of which builds a multi-column workspace and asserts every column is rebalanced.
