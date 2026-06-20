# Nehir ↔ OmniWM provenance audit

This folder records a file-by-file provenance audit of Nehir's Swift sources
relative to its upstream origin, [BarutSRB/OmniWM](https://github.com/BarutSRB/OmniWM).
It exists to make the OmniWM lineage of every shipped Nehir file explicit and
auditable, independent of any one contributor's memory.

## What is here

- [`files.tsv`](files.tsv) — the full per-file classification: one row per
  tracked Swift file (335 files) with columns
  `rel  final_cat  source  evidence`. `rel` is a Nehir-repo-relative path.
- [`01-method-and-rounds.md`](01-method-and-rounds.md) — how the audit was
  produced: the two-round subagent fanout, the false-negative strategy, and how
  round 2 corrected round 1.
- [`02-borrowed-later.md`](02-borrowed-later.md) — the four CAT-4 files
  (absent at the fork base, borrowed from a later upstream commit), with the
  decisive diff evidence inlined. This is the most legally sensitive category.
- [`03-cross-check-upstream-port-roadmap.md`](03-cross-check-upstream-port-roadmap.md)
  — revalidation of the audit against Nehir's own upstream-port roadmap
  (`discovery/20260618-upstream-port-roadmap.md`): which ports Nehir confirms,
  which it rejected, and the one place where a discovery doc's intent and the
  landed code diverge.
- [`04-clean-nehir.md`](04-clean-nehir.md) — the 63 CAT-5 files (cleanly
  implemented in Nehir, no prior existence in OmniWM).

## Categories

| Cat | Meaning |
| --- | --- |
| 1 | near-identical to upstream at the fork base (only OmniWM→Nehir rename + generated SPDX header differ) |
| 2 | originates from upstream at the fork base, small later modifications |
| 3 | originates from upstream at the fork base, later significantly rewritten |
| 4 | absent at the fork base, borrowed from a later upstream commit |
| 5 | cleanly implemented in Nehir, no prior existence anywhere in OmniWM |

## Headline result (335 files)

| Cat | Count |
| --- | --- |
| 1 near-identical | 102 |
| 2 small-deriv | 129 |
| 3 significant | 37 |
| 4 borrowed-later | 4 |
| 5 clean-nehir | 63 |

**268 of 335 files (80%) originate from OmniWM** (categories 1–4). The
63 CAT-5 files are genuinely new Nehir work, concentrated in the PureLayout
subsystem, the split TOML codecs and migration/onboarding stores, the entire
Onboarding/WhatsNew UI, and Nehir-specific settings tabs.

This audit directly informs the generated SPDX file headers on `main`: derived
files (cat 1–4) carry the upstream `2026 BarutSRB` copyright **in addition to**
Nehir's (`Provenance=upstream-derived`), while the 63 CAT-5 files carry
Nehir-only copyright (`Provenance=nehir-original`). Exact commit hashes for the
four CAT-4 files are audit metadata in `.provenance.json` and this folder, not
rendered into headers. See `02-borrowed-later.md` and `NOTICE.md` on `main`.

## How to reproduce

The audit was produced by a two-round subagent fanout (model `zai/glm-5.2`),
each round with up to five parallel agents. Round 1 classified all 335 files
against the fork base `ee9b4f0`. Round 2 revalidated every CAT-4 and CAT-5
claim against an isolated full-history clone of `BarutSRB/OmniWM`, restricted to
the `origin` remote (true upstream), using rename-aware basename search plus
multi-token content search (`git log origin/main -S <token>` and
`git grep <token> origin/main`). See `01-method-and-rounds.md`.

### Reference points (durable)

- Upstream repo: `BarutSRB/OmniWM`, ref `origin/main`.
- Nehir fork base: `ee9b4f0707668d43f73e4af8c9a4f3581b8c11ce`
  ("Stabilize hotkeys, gestures, and window admission").
- Audit date: 2026-06-20. Verified against `origin/main` of `BarutSRB/OmniWM`
  on that date.

### A note on paths

This folder uses Nehir-repo-relative source paths (`Sources/Nehir/...`,
`Tests/NehirTests/...`) and upstream-repo-relative paths
(`Sources/OmniWM/...`). No local machine paths are recorded, so the findings
remain verifiable from any clone of either repo.
