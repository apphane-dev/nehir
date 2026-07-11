# Challenge window width vs column width (and other column-vs-window semantics) — Discovery

Groom 2026-07-07: still applicable — naming/API-surface cleanup (collapse the window-width command family, rename `hasManualSingleWindowWidthOverride`, decide `NiriWindow.windowWidth`); sequenced behind the still-in-flight `BarutSRB/OmniWM#295`/`BarutSRB/OmniWM#283`/`BarutSRB/OmniWM#326` width plans, none of which have landed (verified against main 7a025b78).

Source: backlog item **#19** ("Challenge window width vs column width (and other
column-vs-window semantics)"), captured in `planned/20260621-backlog-brainstorm.md`.

Scope of this doc: audit Nehir's Niri width model for places where **"window
width"** and **"column width"** are conflated, duplicated, or misleadingly named,
and decide whether the distinction is worth tightening. This is a *semantics /
naming / API-surface* investigation, not a bug repro and not a new feature — the
related feature work (BarutSRB/OmniWM#283 / BarutSRB/OmniWM#295 / BarutSRB/OmniWM#326) is cited below, not duplicated.

All file/line references were verified against the main Nehir source tree
(`e7b246b6`) on 2026-06-21. Re-verify before acting; line numbers drift.

---

## TL;DR

Nehir's underlying ownership model is **sound and intentionally asymmetric**,
mirroring upstream niri: on a horizontal monitor the **primary axis (width) is a
column property** and the **secondary axis (height) is a per-window property**.
The real problems are in the *naming and command surface* layered on top of that
model, where three separate "window width" concepts none of which mean what a
user would guess:

1. **A vestigial "window width" command family that is behaviorally identical to
   the "column width" family.** `setWindowWidth`, `cycleWindowWidthForward/Backward`
   delegate directly to `setColumnWidth` / `toggleColumnWidth` and mutate
   `column.width`, **not** any per-window field. They exist in the hotkey catalog
   (`HotkeyCommand.swift:57-58,65`), the IPC wire format
   (`Sources/NehirIPC/IPCModels.swift:263-264,271` → `cycle-window-width-*` /
   `set-window-width`), and the command palette, but are unbound by default and
   behave exactly like their column-named twins. A user who sees "Set Window
   Width" next to "Set Window Height" (which *is* genuinely per-window) is
   invited to expect per-window horizontal sizing that does not exist.
2. **`NiriContainer.hasManualSingleWindowWidthOverride` is an overloaded
   catch-all flag whose name no longer describes its job.** It is a *column*
   field named after a *single-window* concept, set by **every** column resize
   (`applyColumnWidth` at `NiriLayoutEngine+Sizing.swift:238`), and its only
   runtime effect is to gate the **lone-window policy** (`.fill`/`.centered`) at
   `NiriLayout.swift:716`. Three planned features re-use the same flag for three
   more meanings (moved-window width, per-app rule width, >100% width).
3. **`NiriWindow.windowWidth` is a per-window width field that is effectively
   dead on the primary axis.** It is read **only** in the vertical-orientation
   branch of the axis solver (`NiriLayout.swift:1131`) and is written by **no**
   command and no resize path — only reset-to-default and workspace restore.
   Meanwhile the "window width" *commands* conspicuously do not touch it.

**Verdict:** 🟡 **Pursue as a naming/API-surface cleanup, sequenced as a
follow-up** after `BarutSRB/OmniWM#295` / `BarutSRB/OmniWM#283` / `BarutSRB/OmniWM#326` land (they all touch
`hasManualSingleWindowWidthOverride` and would otherwise compound the overload).
Do **not** treat it as a bug; treat it as debt reduction. The concrete,
shippable scope is: (a) collapse or justify the window-width command family,
(b) rename `hasManualSingleWindowWidthOverride` to describe its actual role,
(c) decide the fate of `NiriWindow.windowWidth`. Details and a cheaper
alternative are in §Recommendation.

---

## What the idea means for Nehir

"Challenge window width vs column width" is an open-ended prompt to question
whether the column-vs-window distinction in the width model is clear, consistent,
and honestly named. Concretely it asks: where the codebase says "window width",
does it mean the same thing each time, and does it mean what a user would expect?
The answer, after audit, is **no in three distinct places** — and the divergence
is invisible in normal use but becomes a live hazard for every feature that
touches width (the three planned discoveries below are already tripping over it).

This is distinct from the sibling feature discoveries, which each take the
existing model as given and extend it:

- `discovery/20260616-omniwm-295-niri-window-width-preservation.md` (+ planned
  `planned/20260621-omniwm-295-niri-window-width-preservation.md`) — preserve a
  moved window's width across workspaces by copying column-width state.
- `discovery/20260617-omniwm-283-per-app-initial-column-width.md` (+ planned
  `planned/20260621-omniwm-283-per-app-initial-column-width.md`) — per-app
  initial column width as an `AppRule` effect.
- `discovery/20260617-omniwm-326-niri-column-over-100-percent-width.md` (+ planned
  `planned/20260621-omniwm-326-niri-column-over-100-percent-width.md`) — allow a
  column wider than 100% of the working area.
- `noop/20260616-omniwm-384-respect-window-min-size-in-niri-column-width.md` —
  min-size floor; already implemented, flagged 🟢 don't-port.

All four treat `hasManualSingleWindowWidthOverride` and `column.width` as the
load-bearing width state. **This doc is about whether that state is well-named
and whether the command surface around it is honest**, not about changing the
solver or the ownership model.

---

## Current behavior (with source citations)

### 1. The ownership model is intentionally asymmetric (and correct)

Width is a **column** property; height is a **window** property. The width state
lives on the column:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:378-410  (class NiriContainer)
class NiriContainer: NiriNode {
    var displayMode: ColumnDisplay = .normal
    private(set) var activeTileIdx: Int = 0
    var width: ProportionalSize = .default
    var cachedWidth: CGFloat = 0
    var loneWindowLayoutWidthOverride: CGFloat?
    var presetWidthIdx: Int?
    var isFullWidth: Bool = false
    var savedWidth: ProportionalSize?
    var hasManualSingleWindowWidthOverride: Bool = false
    ...
    var widthAnimation: SpringAnimation?
    var targetWidth: CGFloat?
}
```

The height state lives on the window, and there is a *separate* per-window width
field used only when the monitor is rotated:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:699-708  (class NiriWindow)
class NiriWindow: NiriNode {
    var sizingMode: SizingMode = .normal
    var height: WeightedSize = .default
    var savedHeight: WeightedSize?
    var windowWidth: WeightedSize = .default     // ← per-window width, see §3
    var constraints: WindowSizeConstraints = .unconstrained
    ...
}
```

The lone-window policy layers a **transient render/viewport** width on top, but
the glossary is explicit that canonical width stays on the column:

> `LoneWindowPolicy.fill` / `.centered` does not replace canonical column width.
> It supplies a transient lone-window viewport/render width while the lone-window
> predicate holds.
> — `docs/glossary.md` ("default column width", "lone-window policy")

This matches upstream niri, where column width is the tiled width and a lone
window simply fills its column. **The model is not the problem.**

### 2. There are two parallel "width" command families that do the same thing

The hotkey enum models both:

```swift
// Sources/Nehir/Core/Input/HotkeyCommand.swift:55-65
case cycleColumnWidthForward
case cycleColumnWidthBackward
case cycleWindowWidthForward
case cycleWindowWidthBackward
...
case toggleColumnFullWidth
...
case setColumnWidth(NiriSizeChange)
case setWindowWidth(NiriSizeChange)
```

At the engine layer the "window" variants are thin delegates that mutate the
**column**:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:602-625
func setWindowWidth(
    _ window: NiriWindow,
    change: NiriSizeChange,
    in workspaceId: WorkspaceDescriptor.ID,
    motion: MotionSnapshot = .enabled,
    state: inout ViewportState,
    workingFrame: CGRect,
    gaps: CGFloat
) {
    guard let column = findColumn(containing: window, in: workspaceId) else { return }
    setColumnWidth(
        column,
        change: change,
        ...
        commandKind: "setWindowWidth",     // ← only difference: the trace label
        targetWindow: window               // ← and which window the trace is "about"
    )
}
```

`toggleWindowWidth` → `toggleColumnWidth` (`:523-543`) and `cycleWindowWidth`
(via `CommandHandler.swift:148-150` → `cycleWindowWidth(forward:)`) follow the
same pattern. The `targetWindow` parameter only matters for *tracing* and for the
lone-window preset-cycling heuristic inside `toggleColumnWidth`
(`NiriLayoutEngine+Sizing.swift:438`), and even there it only changes behavior
when the column has multiple windows **and** uses **fixed** presets; with the
default proportional presets `[0.35, 0.50, 0.65, 0.95]`
(`BuiltInSettingsDefaults.swift:10-14`) the two families are indistinguishable.

**The asymmetry that proves the point:** the **height** commands genuinely differ
because height is per-window — `setWindowHeight` writes `window.height`
(`NiriLayoutEngine+Sizing.swift:898,918,960`), there is no `setColumnHeight`, and
`cycleWindowHeight` is **bound by default** (Option+Shift+Minus/Equal). The
**width** "window" commands are unbound mirrors (`ActionCatalog.swift:579-586`
cycle, `:635-648` set) that live in `category: .column` alongside their column
twins. A user encountering "Set Window Width" and "Set Window Height" as siblings
reasonably expects both to be per-window; only the height one is.

Both families are also exposed on the IPC wire format:

```swift
// Sources/NehirIPC/IPCModels.swift:261-271
case cycleColumnWidthForward = "cycle-column-width-forward"
case cycleColumnWidthBackward = "cycle-column-width-backward"
case cycleWindowWidthForward  = "cycle-window-width-forward"
case cycleWindowWidthBackward = "cycle-window-width-backward"
...
case setColumnWidth = "set-column-width"
case setWindowWidth = "set-window-width"
```

…but `docs/IPC-CLI.md` only documents the column variants
(`cycle-column-width`, `toggle-column-full-width` at `docs/IPC-CLI.md:319-321`).
So `set-window-width` / `cycle-window-width-*` are reachable over IPC but
undocumented, and behave identically to the documented column commands.

### 3. `hasManualSingleWindowWidthOverride` is an overloaded flag with a misleading name

It is a **column** field whose name says **"single window"**. It is set by every
column resize and its sole runtime effect is to gate the lone-window policy:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:707-720
private func resolvedSingleWindowWidth(
    for context: SingleWindowLayoutContext,
    in workingFrame: CGRect,
    gaps: CGFloat
) -> CGFloat {
    if context.container.cachedWidth <= 0 {
        context.container.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
    }
    guard context.container.hasManualSingleWindowWidthOverride else {
        return workingFrame.width * CGFloat(context.maxWidthFraction.clamped(to: 0.0 ... 1.0))
    }
    return max(0, context.container.cachedWidth)
}
```

…and it is written in lockstep with `column.width` on every resize:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:217-238  (applyColumnWidth)
column.width = newWidth
column.presetWidthIdx = presetIndex
column.isFullWidth = false
column.savedWidth = nil
column.hasManualSingleWindowWidthOverride = true
```

…and at the full-width toggle (`:651` and `:662`). So the flag is really
**"this column's width has been explicitly set and should win over the lone-window
default policy"** — not specifically anything about a single window. Its name is a
relic of the moment it was introduced (the lone-window path), and three planned
discoveries propose to lean on the same flag for unrelated purposes:

- **BarutSRB/OmniWM#295** copies `hasManualSingleWindowWidthOverride` from the source column to
  the target column on a cross-workspace window move
  (`planned/20260621-omniwm-295-niri-window-width-preservation.md:75,109`).
- **BarutSRB/OmniWM#283** sets `hasManualSingleWindowWidthOverride = true` when an `AppRule`
  supplies an `initialColumnWidth` — and its plan **flags this as a semantic
  overload** ("Reusing `hasManualSingleWindowWidthOverride` for a rule-set width
  is a …", `planned/20260621-omniwm-283-per-app-initial-column-width.md:94,522`).
- **BarutSRB/OmniWM#326** sets `hasManualSingleWindowWidthOverride = true` for a deliberately
  over-100% lone window
  (`planned/20260621-omniwm-326-niri-column-over-100-percent-width.md:341,359`).

Each reuse is defensible in isolation; cumulatively they turn the flag into
"manual **or** moved **or** rule-set **or** over-width — i.e. anything that
should bypass the lone-window policy." The name will then describe exactly none
of those meanings.

### 4. `NiriWindow.windowWidth` is dormant on the primary axis

The per-window `windowWidth: WeightedSize` field is read in exactly one place,
the vertical-orientation branch of the secondary-axis solver:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:1128-1156  (resolveWindowSpans, .vertical case)
case .vertical:
    ...
    switch window.windowWidth {
    case let .fixed(w):      isFixed = true;  fixedValue = w
    case .auto:              isFixed = false; fixedValue = nil
    case let .preset(index): isFixed = true;  fixedValue = resolvePresetSpan(...)
    }
    return NiriAxisSolver.Input(weight: max(0.1, window.widthWeight), ...)
```

On a horizontal monitor the `.horizontal` branch (`:1108-1127`) is taken instead,
which reads `window.height`; `windowWidth` is never consulted. And **no command
writes it** — `grep` across `Sources/Nehir/Core/Layout/Niri/` and
`Sources/Nehir/Core/Controller/` shows the only writes are
`window.windowWidth = .default` (`NiriLayoutEngine+ColumnOps.swift:51`) and the
workspace save/restore pair (`NiriLayoutEngine+Restore.swift:37,142`). There is
no hotkey, IPC command, or interactive-resize path that sets it. So on the
primary axis it is always `.default`, and the "Set Window Width" command family —
which a user would expect to populate it — does not.

This is the sharpest expression of the conflation: there exists a per-window
width field, and there exist "window width" commands, and the two have nothing to
do with each other.

### 5. "Column width" is measured in window-pixels when fixed (tabbed mode)

In tabbed mode the column reserves a tab-indicator strip, so column width and
window content width differ by a constant:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:116-126
private func tabOffset(for column: NiriContainer) -> CGFloat {
    column.isEffectivelyTabbed ? renderStyle.tabIndicatorWidth : 0
}
private func columnWidth(forWindowWidth windowWidth: CGFloat, in column: NiriContainer) -> CGFloat {
    windowWidth + tabOffset(for: column)
}
private func windowWidth(forColumnWidth columnWidth: CGFloat, in column: NiriContainer) -> CGFloat {
    max(0, columnWidth - tabOffset(for: column))
}
```

The shared spec builder **always** interprets a fixed value as *window* pixels and
adds the tab offset — for both the column and window command families:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:184-199  (columnWidthSpec)
case let .setFixed(fixed):
    let windowWidth = fixed.clamped(to: 1 ... NiriSizeChange.maxPixels)
    return .fixed(columnWidth(forWindowWidth: windowWidth, in: column))
case let .setProportion(proportion):
    return .proportion((proportion / 100).clamped(to: 0 ... NiriSizeChange.maxProportion))
case let .adjustFixed(delta):
    return .fixed((currentPixels + delta).clamped(to: 1 ... NiriSizeChange.maxPixels))
```

Consequence: in a tabbed column, **"Set Column Width to 800 fixed" sets the
column to `800 + tabIndicatorWidth`**, not 800. The "column width" command is
secretly measured in window-content units whenever the input is fixed. Proportional
inputs (the default presets and the bound `adjustProportion` hotkeys) are
unaffected because they never touch `tabOffset`. This is a minor correctness wart
rather than a user-visible bug, but it is another place where "column width" and
"window width" silently swap meanings.

---

## Where / how it would be addressed (files, types, symbols)

There is no single fix; the cleanup has three independent lobes. Each is small
and local.

### Lobe A — collapse (or justify) the window-width command family

**Files:** `Sources/Nehir/Core/Input/HotkeyCommand.swift`,
`Sources/Nehir/Core/Input/ActionCatalog.swift`, `Sources/Nehir/Core/Controller/CommandHandler.swift`,
`Sources/Nehir/Core/Controller/LayoutCoordinator.swift` (or wherever
`cycleWindowWidth`/`setWindowWidth` are routed),
`Sources/NehirIPC/IPCModels.swift`, `docs/IPC-CLI.md`, plus the migration surface
(`docs/SETTINGS_MIGRATIONS.md`).

**Decision required first:** are the window-width commands meant to do something
the column commands do not? Two live possibilities:

1. **No distinct meaning (current reality).** Then remove the four width variants
   from the public surface: drop the enum cases, action specs, IPC cases and raw
   values, and the `CommandHandler` dispatch arms; document a migration so any
   user config that bound them re-maps to the column twin. This is the honest
   option and shrinks the surface.
2. **A distinct meaning is *wanted* (per-window width within a stacked column, or
   the vertical-orientation primary axis).** Then make `setWindowWidth` /
   `cycleWindowWidth` actually write `window.windowWidth` (and feed it through
   `resolveWindowSpans` on the primary axis), giving them real per-window
   semantics symmetric to `setWindowHeight`. This is a *feature*, not a cleanup,
   and must be designed against the constraint that horizontal-monitor primary
   width is column-owned today (changing that ripples through the viewport /
   snap / reveal model).

Until that decision is made, the command surface is lying. The default
recommendation is **option 1 (remove)**, because option 2 contradicts the
verified column-owns-primary-axis model and would duplicate niri's own design
without a stated user need.

### Lobe B — rename `hasManualSingleWindowWidthOverride`

**Files:** `Sources/Nehir/Core/Layout/Niri/NiriNode.swift` (declaration),
`NiriLayoutEngine+Sizing.swift` (all write sites),
`NiriLayoutEngine+ColumnOps.swift` (`copyColumnWidthState`),
`NiriLayout.swift` (the read site at `:716`),
`NiriLayoutEngine+WorkspaceOps.swift` and `+Windows.swift`
(`initializeNewColumnWidth` reset), and any tests referencing the field name.

**Suggested rename:** `bypassesLoneWindowPolicy` or `hasExplicitColumnWidth`
(reads as "this column carries an explicit width that should override the
lone-window default"). This must land **together with** whichever of BarutSRB/OmniWM#295/BarutSRB/OmniWM#283/
BarutSRB/OmniWM#326 touches the flag first, or be done immediately before them as a prep
commit — otherwise the overload documented in §3 accretes on a name that is
already wrong. The flag's *semantics* do not need to change, only its name and
the doc comment.

### Lobe C — decide the fate of `NiriWindow.windowWidth`

**Files:** `Sources/Nehir/Core/Layout/Niri/NiriNode.swift` (declaration + the
`widthWeight`/`size` accessors), `NiriLayout.swift:1131` (the one read site),
`NiriLayoutEngine+Restore.swift` (save/restore), `NiriLayoutEngine+ColumnOps.swift`
(the reset).

**Options:**

- **Keep, but document** that it is the per-window width *only on vertical-orientation
  monitors* and is intentionally not user-settable today. Add a doc comment and a
  glossary entry so the next reader does not assume it is dead.
- **Remove** if vertical-orientation per-window width is not a supported feature
  (verify against `discovery/20260618-upstream-monitor-orientation-override.md`
  and whether any vertical-monitor test exercises non-default `windowWidth`
  values — if none do, removal is safe).

Either is cheap; the point is to make the field's role explicit instead of
mysterious.

---

## Risks and unknowns

- **Migration cost of removing the window-width commands (Lobe A).** User configs
  that bound `cycleWindowWidthForward` etc. would reference a removed action id.
  `docs/SETTINGS_MIGRATIONS.md` already governs this kind of removal; the bound
  default set is unaffected (the width-window actions are `.unassigned`). Risk is
  low but non-zero for power users who assigned them — and those users are
  exactly the ones who would notice the commands did nothing distinct.
- **Sequencing hazard with BarutSRB/OmniWM#295 / BarutSRB/OmniWM#283 / BarutSRB/OmniWM#326 (Lobe B).** All three planned
  discoveries add a new meaning to `hasManualSingleWindowWidthOverride`. If the
  rename lands *after* them, three plans must be re-verified; if it lands *first*
  as a prep commit, they pick up the new name for free. The latter is strongly
  preferred.
- **Whether `windowWidth` (Lobe C) is reachable in practice on vertical monitors.**
  Unknown without checking the vertical-orientation test coverage and whether
  `discovery/20260618-upstream-monitor-orientation-override.md`'s planned
  orientation override would surface it. If the orientation-override feature
  ships, `windowWidth` may become load-bearing and Lobe C collapses to
  "document it."
- **Behavioral equivalence claim depends on default presets being proportional.**
  The §2 "indistinguishable" claim holds because
  `BuiltInSettingsDefaults.niriColumnWidthPresets = [0.35, 0.50, 0.65, 0.95]`
  (all proportional). A user who configures **fixed** presets (`PresetSize.Kind`
  `.fixed`) *can* observe a difference between the column and window cycle
  commands in a multi-window column (the `currentWindow` vs `currentTile`
  comparison at `NiriLayoutEngine+Sizing.swift:495-510`). That edge case is
  obscure and arguably itself a misfeature — worth noting but not worth
  preserving the duplicate surface for.
- **IPC stability.** Removing `cycle-window-width-*` / `set-window-width` wire
  names is an IPC break for any external client using them. Same migration
  discipline applies.

---

## Open questions

1. Is there a recorded user reason the window-width command family exists
   (upstream OmniWM heritage, a requested workflow), or is it a mirror that was
   never given distinct semantics? — Answering this settles Lobe A option 1 vs 2.
2. Does any test assert that `setWindowWidth` differs from `setColumnWidth`? If
   yes, that encodes an intent worth preserving; if no, removal is clean.
   (`grep` suggests no such test exists, but this should be confirmed during
   implementation.)
3. Should "Set Column Width to 800 fixed" (§5) mean 800 column pixels or 800
   window-content pixels in tabbed mode? Today it means the latter, silently.
   That is arguably a bug independent of this cleanup.
4. Does the planned vertical-monitor orientation override
   (`discovery/20260618-upstream-monitor-orientation-override.md`) intend to expose
   per-window width to the user? If yes, Lobe C becomes a prerequisite, not a
   cleanup.

---

## Recommendation

**🟡 Pursue as a follow-up cleanup, sequenced after — or as a prep commit before
— the first of BarutSRB/OmniWM#295 / BarutSRB/OmniWM#283 / BarutSRB/OmniWM#326.** The underlying model is correct; the debt is
in naming and a duplicated command surface. Concretely:

- **Do Lobe B first (rename `hasManualSingleWindowWidthOverride`),** ideally as a
  pure rename prep commit on `main`, so all three planned width features inherit
  an honest name instead of compounding the overload. Lowest risk, highest
  clarity payoff.
- **Do Lobe A (remove the window-width command family) next,** behind a settings
  migration, *unless* a stated user need for per-window horizontal sizing emerges
  (then it becomes feature work, option 2, and is deferred to its own discovery).
  The default — removal — shrinks the hotkey catalog, the IPC surface, and the
  palette, and removes the most user-visible lie in the model.
- **Do Lobe C (document or remove `NiriWindow.windowWidth`) last,** gated on the
  vertical-orientation question (open question 4).
- **File the §5 fixed-width-tab-offset wart as a separate, tiny bug** if it
  survives Lobe A — it is orthogonal to the naming cleanup.

**Cheaper alternative if the full cleanup is not worth a release:** do **only
Lobe B** (the rename) as a prep commit, and add a single glossary paragraph
clarifying that "window width" commands are column-width aliases and that
`windowWidth` is vertical-orientation-only. That removes the worst of the
confusion (the overloaded flag name) for the cost of a rename, without touching
the command or IPC surface.

Do **not** defer Lobe B indefinitely: every width feature shipped before the
rename makes the flag's name one meaning further from its behavior, and the rename
gets harder.
