# OmniWM PR #318 — "fix(rules): resolve popup-induced floating bug (#306)" — Discovery

Source PR: https://github.com/BarutSRB/OmniWM/pull/318
Merge state: **closed without merge** — closed by maintainer `@BarutSRB` on
2026-06-15 (`state: closed`, `merged: false`, `closed_at: 2026-06-15T23:35:05Z`).
The triage note "open" is **stale**; the PR was closed the day before this
discovery. Targets issue #306, which upstream closed as `completed`.
Scope of this doc: determine whether #318's proposed fix applies to nehir and
whether it owns any repo action not already covered by the sibling #323 discovery.

All file/line references were verified against worktree `worktree-calm-meadow-6229`
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Line numbers
drift — re-verify before implementing.

> **Filed under discovery/noop/** — #318 is the superseded, internally-broken **first
> iteration** of the #306 (popup-induced floating) fix. Its successor, sibling
> discovery `discovery/20260616-omniwm-323-floating-panel-bar-filter.md`
> (PR #323, same author `@Paranjayy`, same root cause, verdict 🟡 Partial), owns every
> repo action that is actually applicable here. The remainder of #318 is either already
> present in nehir in broader form, or a regressive deletion that would reintroduce the
> bug. Porting #318 would duplicate and regress; no new action is owned.

---

## TL;DR

- **PR #318 is a broken first draft of the #306 fix: its own regression test references a `childWindowStructuralAnchor` rule that the diff never implements, and it deletes the very heuristic and top-level guard (#323 re-adds them) plus drops `parentWindowId` storage. nehir already has the correct versions of everything #318 gets right.**
- **Verdict:** ⚪ **Won't port / not applicable** — duplicate of sibling #323 for the genuinely-applicable parts; the rest is already-fixed-in-nehir or regressive.

## Provenance: is this nehir's code?

Yes. The paths the PR
touches all exist in nehir under the `Sources/Nehir/...` rename:

- Top-level AX admission + heuristic: `Sources/Nehir/Core/Ax/AppAXContext.swift:434`, `Sources/Nehir/Core/Ax/AXWindow.swift:312`, `Sources/Nehir/Core/Ax/AXWindow.swift:666`.
- Automatic reevaluation mode preservation: `Sources/Nehir/Core/Controller/WMController.swift:1920`.
- CleanShot-gated window-server resolution (a path #318 alone broadens): `Sources/Nehir/Core/Controller/WMController.swift:2047`.
- Managed-replacement `parentWindowId` persistence: `Sources/Nehir/Core/Controller/WMController.swift:3086`.

## What the PR's diff changes (6 files)

The diff is small and, critically, **internally inconsistent**:

1. **`AXWindow.swift` (−12): deletes `shouldTreatAsTopLevelWindow` AND deletes the
   `.nonStandardSubrole → .floating` heuristic block** in `heuristicDisposition`. nehir
   **keeps both** (`Sources/Nehir/Core/Ax/AXWindow.swift:312` and `:666`-`:673`).
2. **`AppAXContext.swift` (+18): replaces** the `shouldTreatAsTopLevelWindow` guard with
   inline logic admitting `AXWindow` role, OR (`AXDialog`/`AXPanel`) with a title.
   nehir lacks this admission (it still calls `shouldTreatAsTopLevelWindow` at
   `Sources/Nehir/Core/Ax/AppAXContext.swift:434`) — **but this exact gap is already
   owned by sibling #323**, which re-adds the same admission while keeping the heuristic.
3. **`WMController.swift`: broadens the mode-preservation guard** from
   `decision.source == .heuristic` to `source == .heuristic || layoutDecisionKind == .fallbackLayout`,
   and makes the method `internal`. nehir already has the **broader, source-agnostic**
   equivalent (`trackedModePreservingAutomaticFallbackState` at
   `Sources/Nehir/Core/Controller/WMController.swift:1920`, guarding purely on
   `decision.layoutDecisionKind == .fallbackLayout` — covers heuristic, user-rule, and
   any other source).
4. **`WMController.swift`: drops the `bundleId == cleanShotBundleId` restriction** in
   window-server-info resolution (so `parentId` is resolvable for all apps), AND **removes
   the `parentWindowId` write** from managed-replacement metadata. nehir **keeps** the
   CleanShot gate (`Sources/Nehir/Core/Controller/WMController.swift:2047`) and **keeps**
   writing `parentWindowId` (`Sources/Nehir/Core/Controller/WMController.swift:3086`).
5. **`WindowRuleEngineTests.swift` (+20): adds `childWindowStructuralAnchorRuleFloatsWindowsWithParent`**
   expecting a `builtInRule("childWindowStructuralAnchor")` source and
   `layoutDecisionKind == .explicitLayout` for a window with `parentId != 0`.
   **The rule this test asserts is never added** — `WindowRuleEngine.swift` is absent
   from the 6 changed files. `ffgrep childWindowStructuralAnchor Sources` returns no
   matches in nehir (and none in the PR diff). The test cannot pass against the PR as
   submitted; this is almost certainly why it was closed without merge.
6. **`WMControllerReevaluationRegressionTests.swift` (+123): mode-preservation tests.**
   nehir's equivalent behavior is already covered (sibling #323 cites the nehir
   heuristic/reevaluation tests).

## Why this doesn't apply (it is a duplicate + partly regressive)

Mapping every #318 element to its nehir disposition:

| #318 change | nehir status | Owned by |
|---|---|---|
| Delete `shouldTreatAsTopLevelWindow` | 🟢 present (`AXWindow.swift:312`); deletion = **regression** | n/a — don't delete |
| Delete `.nonStandardSubrole` floating heuristic | 🟢 present (`AXWindow.swift:666`); deletion = **regression** | n/a — don't delete |
| Admit titled `AXDialog`/`AXPanel` in `AppAXContext` | ⚪ gap exists (`AppAXContext.swift:434`) | **sibling #323** (already owns the eval) |
| Broaden mode-preservation to `fallbackLayout` | 🟢 already broader (`WMController.swift:1920`, source-agnostic) | n/a — already in nehir |
| Drop CleanShot gate on window-server resolution | only consumer (`childWindowStructuralAnchor`) absent from #318's own diff | **sibling #323** (structural-parent eval) |
| Remove `parentWindowId` from metadata | 🟢 nehir keeps it (`WMController.swift:3086`); removal = **regression** | n/a — don't remove |
| `childWindowStructuralAnchor` structural rule | absent in nehir; **also absent from #318's diff** (test-only) | **sibling #323** (as design input) |
| `WMControllerReevaluationRegressionTests` | 🟢 equivalent behavior covered | n/a — already in nehir |

The decisive points:

- **The applicable gaps are #323's, not #318's.** The two genuinely-missing pieces in
  nehir — titled dialog/panel admission (`AppAXContext.swift:434`) and any structural
  `parentId` handling — are owned end-to-end by sibling
  `20260616-omniwm-323-floating-panel-bar-filter.md`, which is the **corrected successor**
  to this PR (it re-adds the heuristic and guard that #318 wrongly deletes, and it
  actually implements the structural rule #318 only tests for).
- **#318's unique edit (dropping the CleanShot gate, `WMController.swift:2047`) has no
  consumer in #318.** Its only purpose is to feed `parentId` to a `childWindowStructuralAnchor`
  rule that the diff never adds. The successor #323 deliberately omits this broadening,
  and the #323 discovery advises against adopting a blanket `parentId != 0 → floating`
  rule (nehir deliberately narrows parent inheritance to AX-child/transient evidence).
  nehir already captures `parentId` whenever `evaluation.facts.windowServer` is non-nil
  (`WMController.swift:3086`), so no separate broadening action is owed here.
- **Three of #318's edits are outright regressive** in nehir (deleting
  `shouldTreatAsTopLevelWindow`, deleting the `.nonStandardSubrole` heuristic, removing
  `parentWindowId` storage). Porting #318 would reintroduce classification gaps and lose
  parent metadata — the opposite of the stated fix.
- **The PR is internally broken** (test references an unimplemented rule), consistent
  with its close-without-merge; it should not be treated as a working reference patch.

## Recommendation

**Do not port #318.** It is superseded by the sibling #323 discovery, which already owns
the only applicable nehir actions (titled dialog/panel admission evaluation + structural
parent rule as design input). nehir already has the broader/correct versions of
#318's mode-preservation, heuristic, top-level guard, and `parentWindowId` storage. Treat
#318 solely as historical context for #306; route any implementation work to the #323
discovery.

## Suggested tests

None owned here — see sibling `20260616-omniwm-323-floating-panel-bar-filter.md` for the
test cases that lock in the genuinely-applicable behavior.
