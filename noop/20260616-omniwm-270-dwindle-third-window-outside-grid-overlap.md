# BarutSRB/OmniWM#270 — "Dwindle window placement/sizing" — Discovery

Source issue: https://github.com/BarutSRB/OmniWM/issues/270
Related PR (assessed, not assumed as the fix): https://github.com/BarutSRB/OmniWM/pull/401
"Dwindle split orientation respects per-monitor settings" — **closed without merge**.
Scope of this doc: determine whether the Dwindle 3rd-window placement bug applies to nehir,
and whether the related per-monitor split-orientation fix is safe/needed to port.

All file/line references were verified against the Nehir source tree at
`7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace"). Line numbers
drift — re-verify before implementing.

> **Filed under `discovery/noop/`** — the verdict is ⚪ **Not applicable / don't port**: nehir has
> **no Dwindle layout engine at all**. Every symbol the issue and PR BarutSRB/OmniWM#401 hinge on
> (`DwindleLayoutEngine`, `DwindleNode`, `splitLeaf`, `planSplit`, `aspectOrientation`,
> `splitWidthMultiplier`, `smartSplit`, `defaultSplitRatio`, `reorientSplits`,
> `monitorDwindleOverrides`) is **absent** from nehir's Sources/Tests — a recursive
> case-insensitive `grep -rin dwindle` returns zero hits. nehir is a single-layout WM whose only
> engine is the Niri column-scrolling layout (`Sources/Nehir/Core/Layout/Niri/`); there is no
> layout-mode selector, and the reporter's trigger action ("swapping workspace 1 into dwindle
> mode") cannot be performed in nehir. The recursive binary-tree split geometry whose bug BarutSRB/OmniWM#270
> reports has no analogue here, so neither the symptom nor PR BarutSRB/OmniWM#401's fix can apply. Owns no new
> repo action; porting BarutSRB/OmniWM#401's diff would not compile (none of its target symbols exist).

---

## TL;DR

- **Issue BarutSRB/OmniWM#270 is a Dwindle binary-tree split bug, and nehir has no Dwindle layout — the entire
  feature is absent.** A recursive grep for `dwindle` (any case) across `Sources/` and `Tests/`
  returns nothing; none of the layout engine, its node type, its split-planning math, or its
  per-monitor override settings exist in nehir.
- **Verdict:** ⚪ **Not applicable / don't port.** The cited code does not exist in nehir; the
  premise (selecting a Dwindle workspace) is impossible, because nehir ships exactly one layout
  (Niri column scrolling) with no per-workspace/per-monitor layout-mode toggle. The triage flag
  ("Bug, open, Med/Med") is overridden by evidence: the issue is **closed** upstream, and the
  feature it concerns does not exist here.

## Triage-state correction (important)

Two upstream facts differ from the triage notes and are recorded so the catalog is accurate:

1. **The issue is closed, not open.** The GitHub API returns `state: closed` for BarutSRB/OmniWM#270. The
   maintainer (`@BarutSRB`) commented: *"this will be fixed for the next release."* The reporter's
   own title is **"Dwindle window placement/sizing."** (the catalog's
   "Dwindle: 3rd window placed outside grid / overlaps" is a paraphrase of the body).
2. **PR BarutSRB/OmniWM#401 is closed *without* merge.** The API returns `state: closed, merged: false,
   merge_commit_sha: null`. Its own description scopes it to **per-monitor split orientation**
   (making `splitWidthMultiplier`/`smartSplit`/`defaultSplitRatio` per-monitor via
   `effectiveSettings(for:)`, plus a `reorientSplits` hot-reload path) — which is a *different,
   narrower* concern than the reporter's "3rd window placed outside the grid / overlapping" symptom.
   Either way, both are inapplicable here (next section).

## Provenance: is this nehir's code?

No — not even partially. Unlike the sibling noop docs (e.g. BarutSRB/OmniWM#384), where the *call site* exists
under a renamed module and only the *buggy symbol* is absent, here the **entire layout family is
absent**:

- `fffind DwindleLayoutEngine` → **no files.**
- `fffind dwindle layout engine split` → only scattered fuzzy matches in unrelated discovery docs
  and config; no source.
- Recursive `grep -rin dwindle Sources Tests` (excluding `.md`) → **zero hits.**
- `grep -rn "monitorDwindleOverrides|dwindleSettings|DwindleSettings|splitWidthMultiplier|smartSplit|defaultSplitRatio"` under
  `Sources/Nehir` → **zero hits.**
- `find Sources -iname '*dwindle*'` → **zero hits.** There is no `Sources/Nehir/Core/Layout/Dwindle/`
  directory; the only layout subdirectory is `Sources/Nehir/Core/Layout/Niri/`.

BarutSRB/OmniWM#270 is genuinely upstream-of-nehir; it is simply that nehir never adopted (or has
already shed) the Dwindle layout. The Dwindle engine is OmniWM-specific surface area that nehir does
not carry.

## The code in question (what nehir *does* have, and why it can't host this bug)

nehir's sole layout engine is Niri — a horizontally-scrolling, column-based tree, conceptually
modelled on the niri Wayland compositor, **not** a recursive binary-space-partition (BSP/dwindle)
tree. Its node is a list of columns, not a left/right split pair:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNode.swift:242
private(set) var children: [NiriNode] = []      // a column is an ordered list of windows, not a binary split
```

The engine lives under `Sources/Nehir/Core/Layout/Niri/` (e.g. `NiriLayoutEngine.swift`,
`NiriLayoutEngine+ColumnOps.swift`, `NiriLayoutEngine+Sizing.swift`, `NiriNode.swift`,
`NiriConstraintSolver.swift`, `ViewportState.swift`). The controller-side handler is
`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift`. **There is no `DwindleLayoutHandler`, no
`DwindleLayoutEngine`, and no second layout backend.**

There is also no way for a user to "swap a workspace into dwindle mode." nehir's layout-affecting
commands are all Niri-column operations:

```swift
// Sources/Nehir/Core/Controller/CommandHandler.swift
case .toggleFullscreen:               // :95
case .toggleColumnTabbed:             // :107
case .toggleColumnFullWidth:          // :149  → controller.niriLayoutHandler.toggleColumnFullWidth()
case .toggleFocusedWindowFloating:    // :180
```

The only `RefreshReason` that mentions "layout" toggling is `workspaceLayoutToggled`
(`RefreshReason.swift:60`), and it simply routes to `.relayout` (`:87`) — it is not a
layout-*mode* switch. The settings UI (`Sources/Nehir/UI/LayoutSettingsTab.swift`) exposes only
per-monitor **gap** and **Niri** settings (`settings.niriSettings(for:)`, `settings.gapSettings(for:)`);
there is no layout-kind picker, no `dwindleSettings`, no `monitorDwindleOverrides`.

In short: the geometric operation whose failure BarutSRB/OmniWM#270 reports — inserting a 3rd window by recursively
halving the active leaf of a BSP tree along a per-aspect-ratio orientation — has **no code path in
nehir** to be wrong. Windows join a column (`NiriNode.insert` at `NiriNode.swift:296`/`:301`/`:311`),
columns are laid out along a scrolling viewport, and width is resolved by
`widthBounds()`/`resolveSpan` clamped to min-size — there is no "split leaf into two halves and
orient it" step at all.

## Why it doesn't apply (and the PR can't be ported)

### 1. The bug's premise is unselectable in nehir

BarutSRB/OmniWM#270 is reported after the user explicitly switched a workspace *into Dwindle mode*. nehir has no
Dwindle mode: one layout engine (Niri), no layout-mode selector, no per-workspace layout-kind
setting. The reproduction's first step cannot be performed. This alone makes the issue ⚪ Not
applicable.

### 2. Every cited/pr-relevant symbol is absent

| Symbol (BarutSRB/OmniWM#401 / engine) | Present in nehir? |
|---|---|
| `DwindleLayoutEngine` / `Sources/.../Layout/Dwindle/` | ❌ no such type or directory |
| `DwindleNode` | ❌ absent (nehir's node is `NiriNode`, a column list) |
| `splitLeaf` / `planSplit` / `aspectOrientation` | ❌ absent (no split step) |
| `settings.splitWidthMultiplier` / `effectiveSettings(for:)` dwindle fields | ❌ absent |
| `smartSplit` / `defaultSplitRatio` | ❌ absent |
| `monitorDwindleOverrides` / `dwindleSettings` | ❌ absent |
| `reorientSplits(for:monitorId:)` / `updateMonitorDwindleSettings()` | ❌ absent |
| `summonWindowRight` (OmniWM Dwindle path) | ❌ absent in this form |

Porting PR BarutSRB/OmniWM#401's diff verbatim would not compile — its edits are to `DwindleLayoutEngine.swift`,
`DwindleLayoutHandler.swift`, and a Dwindle-path `summonWindowRight`, none of which exist. Adapting
the *concept* ("split orientation should read per-monitor settings") is vacuous here because there
is no split-orientation axis in a column-scrolling layout.

### 3. The reporter's symptom has a different geometry in nehir, governed elsewhere

The "3rd window placed outside the grid / overlapping" symptom is, in a Dwindle/BSP engine, a split
*geometry* or split-orientation bug (halving a leaf produces an off-frame or coincident rect). In
nehir's Niri model a new window is appended to the focused column (or a new column), and on-screen
placement is bounded by the viewport + per-window min-size clamping (`resolveSpan`/
`widthBounds`, `NiriNode.swift:526`/`:548`) — there is no "outside the grid" outcome for a standard
3rd window. Any *nehir-specific* placement concern (e.g. new-window column selection, overflow into
tabbed mode) is owned by the separate `completed/20260615-new-window-placement-*`
investigations and the Niri min-size discovery chain (BarutSRB/OmniWM#384/BarutSRB/OmniWM#403), not by a Dwindle bug.

## Recommendation

**Do not port issue BarutSRB/OmniWM#270's fix or PR BarutSRB/OmniWM#401.** Concretely:

1. There is no Dwindle engine in nehir; nothing to fix and nothing to port. If a Dwindle/BSP layout
   were ever added to nehir, BarutSRB/OmniWM#270 and BarutSRB/OmniWM#401 would become relevant inputs at *that* point — but
   neither motivates adding such a layout.
2. No action is owned by this discovery. The catalog should mark BarutSRB/OmniWM#270 and BarutSRB/OmniWM#401 as
   **not-applicable (feature absent)** for nehir.
3. (Cross-doc) If a future discovery reports a real nehir "3rd window mis-placed/overlapping"
   symptom, route it to the **Niri new-window placement** chain
   (`completed/20260615-new-window-placement-investigation.md`,
   `20260616-omniwm-384-…`, `20260616-omniwm-403-…`), **not** here — nehir's placement model is
   column-based and has nothing in common with the Dwindle split math this issue describes.

## Suggested tests

N/A — the feature under test does not exist in nehir, so no regression coverage is warranted. If a
Dwindle layout is ever introduced, the upstream PR BarutSRB/OmniWM#401 tests
(`perMonitorSplitOrientationUsesHighSplitWidthMultiplierForVerticalSplits`,
`reorientSplitsChangesExistingTreeWhenSplitWidthMultiplierUpdated`) would be the right starting
point, ported alongside the engine itself.
