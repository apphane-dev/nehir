# Method and rounds

## Goal

Classify every tracked Swift file in Nehir (335 files) by its upstream OmniWM
provenance, so that upstream lineage is explicit and auditable rather than
implicit. This underpins Nehir's source-attribution policy (see `NOTICE.md` on
`main`) and the generated SPDX file headers.

## Categories

| Cat | Meaning |
| --- | --- |
| 1 | near-identical to upstream at the fork base `ee9b4f0` (only OmniWM→Nehir rename + generated SPDX header differ) |
| 2 | originates from upstream at `ee9b4f0`, small later modifications |
| 3 | originates from upstream at `ee9b4f0`, later significantly rewritten |
| 4 | absent at `ee9b4f0`, borrowed from a later upstream commit |
| 5 | cleanly implemented in Nehir, no prior existence anywhere in OmniWM |

The fork base is `ee9b4f0707668d43f73e4af8c9a4f3581b8c11ce`
("Stabilize hotkeys, gestures, and window admission"), which is an ancestor of
`BarutSRB/OmniWM`'s `origin/main` (verified 2026-06-20).

## Round 1 — full classification

Five parallel subagents (model `zai/glm-5.2`), each owning a coherent slice of
the tree:

| Slice | Area | Files |
| --- | --- | --- |
| 01 | Config + App entry | 40 |
| 02 | Layout (Niri) + Controller | 54 |
| 03 | Core (rest): Ax, Animation, Border, Monitor, Overview, Reconcile, SkyLight, Workspace, IPC | 98 |
| 04 | UI + NehirCtl + NehirIPC | 65 |
| 05 | Tests | 78 |

Each agent received a per-file manifest with a crude similarity hint
(`sim%` from a header-stripped `git diff --no-index --numstat`) and a triage
suggestion, then classified each file into categories 1–5 by diffing the Nehir
file against its best basename match at `ee9b4f0`. For files with no basename
match it searched the full upstream clone for the file and for distinctive
tokens.

Round-1 result: 102 near-identical, 129 small-deriv, 35 significant, 4
borrowed-later, 65 clean-nehir.

## Round-1 self-reported weak points

Reading the agents' own transcripts surfaced five concrete risks:

1. **Remote contamination (biggest risk).** The working clone of
   `BarutSRB/OmniWM` carries three remotes: `origin` (BarutSRB upstream),
   `fork` (Guria/OmniWM, Nehir's own old fork), and `nehir` (guria/nehir).
   `git log --all` or unqualified `git grep` would surface Aleksei-authored
   commits as if they were upstream, producing false "found upstream" hits or,
   conversely, false "clean-nehir" calls if an agent trusted the wrong remote.
2. **Basename-only search misses inlined/renamed code.** Upstream
   `DisplaySpacesMode` lived as an enum *inside* `SkyLight.swift`; a filename
   search for `DisplaySpacesMode.swift` found nothing until a content-token
   search caught it.
3. **The module rename breaks basename matching.** Nehir renamed
   `OmniWM*` → `Nehir*` across modules (`OmniWMApp`→`NehirApp`,
   `OmniWMCtl`→`NehirCtl`, `OmniWMIPC`→`NehirIPC`, `OmniWMStoragePaths`→
   `NehirStoragePaths`). A naïve basename lookup would miss pure renames.
4. **The generated SPDX header inflated the change count.** Because the header
   block itself counts as changed lines, many header-only diffs registered a low
   `sim%` and were triaged as CAT 2 when they were really CAT 1.
5. **Manifest `(none)` was sometimes a rename, not genuinely Nehir-only.** A
   few round-1 CAT-5 guesses were actually pure OmniWM→Nehir renames.

## Round 2 — anti-false-negative revalidation

Round 2 rechecked only the hard cases: all CAT-4 and CAT-5 files (69 files),
five agents, ~14 files each. Each agent worked in an isolated working folder
with a full-history clone of upstream and a Nehir source copy, so no agent could
touch the real tree and every search was self-contained.

Strategy adjustments driven by the round-1 feedback:

- **Search `origin` only.** No `--all`, no `fork/*`, no `nehir/*`; Aleksei-authored
  commits are not upstream. Agents had to *prove* a negative by recording the
  exact empty commands.
- **Rename-aware basename search** (`OmniWM*` ↔ `Nehir*` module-prefix swap).
- **Multi-token content search.** Three to five distinctive tokens per file,
  via both `git log origin/main -S <token>` (full history) and
  `git grep <token> origin/main` (tip tree). Any distinctive-token hit in
  `origin` rules out CAT 5.
- **Adversarial framing:** assume each clean-nehir claim may be a false
  negative and try to prove it wrong.
- **CAT-4 re-confirmation:** the cited borrow commit must be reachable from
  `origin/main`, newer than `ee9b4f0`, and authored by Barut.

## Round-2 result

- **67 of 69 CONFIRMED. 2 RECLASSIFIED (5 → 3).**
- The two reclassifications are `Sources/Nehir/Core/Controller/FocusCoordinator.swift`
  and `Sources/Nehir/Core/Controller/LayoutCoordinator.swift`: the *protocol
  names* are Nehir-only, but their *method signatures*
  (`interactiveMoveCancel`, `clearInteractiveResize`, `focusedNode`,
  `consumeOrExpelWindow`, `cycleWindowWidth`, `focusWindowInColumn`,
  `expandColumnToAvailableWidth`) all exist upstream at `ee9b4f0`, so these are
  Nehir abstractions derived from the upstream Niri engine API — category 3,
  not 5.

## Final classification (after round 2)

| Cat | Count |
| --- | --- |
| 1 near-identical | 102 |
| 2 small-deriv | 129 |
| 3 significant | 37 |
| 4 borrowed-later | 4 |
| 5 clean-nehir | 63 |

The net effect of round 2 was a small but important tightening: 2 files moved
out of "clean-nehir" into "derived", and all four CAT-4 borrows were
independently confirmed against the maintainer's own upstream-port roadmap (see
`03-cross-check-upstream-port-roadmap.md`).

## Why this audit is trustworthy

- Two independent passes with different prompts and a different (stronger)
  methodology in round 2.
- The decisive CAT-4 evidence was re-derived by hand (direct
  `git diff --no-index` of Nehir vs upstream at the cited commit), not just
  trusted from agent transcripts. See `02-borrowed-later.md`.
- The full result was cross-checked against Nehir's own upstream-port roadmap,
  which is the maintainer's independent account of what Nehir ported (and
  rejected) from post-`ee9b4f0` upstream. The two agree on every new-file port.
  See `03-cross-check-upstream-port-roadmap.md`.
- Every CAT-5 file's own primary type name is absent from all of true upstream
  history (`origin/main`), spot-checked for a sample in
  `04-clean-nehir.md`.
