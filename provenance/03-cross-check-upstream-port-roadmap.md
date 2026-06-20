# Cross-check against the upstream-port roadmap

The strongest independent revalidation of this audit is Nehir's own
[`discovery/20260618-upstream-port-roadmap.md`](../discovery/20260618-upstream-port-roadmap.md):
the maintainer's account of what Nehir intentionally ported — and what it
explicitly rejected — from `BarutSRB/OmniWM` after the fork base `ee9b4f0`.
This document compares the roadmap against the audit and records where they
agree, where the roadmap adds nuance, and the one place where a discovery
doc's stated intent and the landed code diverge.

The roadmap covers upstream changes observed on 2026-06-18, from just after
`ee9b4f0` through the then-current upstream `main`.

## Ports Nehir confirms (audit agrees)

| Roadmap ID | What Nehir ported | Lands as | Audit category |
| --- | --- | --- | --- |
| P1 | Two-miss rescan eviction hysteresis | edits to `LayoutRefreshController` / `WorkspaceManager` | 2 (existing files, small mods) |
| P2 | Same-kind refresh coalescing | edits to `LayoutRefreshController` | 2 |
| P3 | Preserve monitor orientation overrides + IPC effective orientation | edits to `NiriMonitor` / `IPCQueryRouter` | 2 |
| P4 | Suppress frame-change relayout after a recent AX write failure | one branch added to `AXManager` | 2 |
| M3 | Focus-request origin for FFM cursor-warp suppression | edits to `MouseWarpHandler` | 2 |
| **M4-S1** | Displays-have-separate-Spaces mode detection + diagnostics | **new file** `DisplaySpacesMode.swift` + edits | **4** ✓ caught |
| **M5** | Raw MultitouchSupport gesture source | **new files** `MultitouchBinding.swift`, `MultitouchGestureSource.swift` | **4** ✓ caught |

The only roadmap ports that produced **new files** are M4-S1 and M5. The audit
caught all three of those new files (`DisplaySpacesMode`, `MultitouchBinding`,
`MultitouchGestureSource`) as category 4. Every other port is a behavioural
edit inside a file that already existed at `ee9b4f0`, so it correctly registers
as category 2 in the audit, not category 4.

### Completeness check: no missed new-file ports

Cross-checking every roadmap port's target files against the audit's category-5
list finds **no overlap** — i.e. no file the roadmap says Nehir ported into was
wrongly classified as clean-nehir. Concretely, none of
`LayoutRefreshController.swift`, `WorkspaceManager.swift`, `NiriMonitor.swift`,
`IPCQueryRouter.swift`, `AXManager.swift`, `MouseWarpHandler.swift`, or
`SkyLight.swift` appear in category 5. So the audit has no false negatives
among the documented port work.

The fourth category-4 file, `MonitorGapSettings.swift` (upstream `dacccb8`),
is **not** a named roadmap item. It entered Nehir as part of monitor
arrangement/gap work. The audit catches it on commit evidence alone
(`dacccb8`, Barut, reachable from `origin/main`, newer than the fork base); see
`02-borrowed-later.md`.

## What Nehir explicitly rejected (audit must not credit upstream)

The roadmap records upstream candidates Nehir deliberately did **not** port.
The audit must not classify any Nehir file as derived from these, and it does
not:

- **M2 — learned per-window size quantum** (upstream `6eb9ba0`). Rejected
  (`noop/20260618-upstream-size-quantum-rejected.md`); Nehir's existing
  post-write quantization acceptance is kept instead. No Nehir file is
  classified as borrowed from `6eb9ba0`.
- **WorldStore / EventIntake / IntentLedger / DeadlineWheel /
  SurfaceReconciler** — upstream's replacement runtime cluster. The roadmap is
  explicit: "do **not** port … wholesale". Nehir instead has its own lighter
  reconcile vocabulary (`RuntimeStore`, `ReconcileTxn`, `Planner`,
  `StateReducer`, `InvariantChecks`, `FocusPolicyEngine`). Those Nehir files
  are Nehir-original re-expressions of the *principles* (single authoritative
  state, explicit commits, invariant validation) and are classified as
  category 3 (derived concept, rewritten) or 5 (new), never as borrowed
  WorldStore code.
- **`AXFrameApplicationLedger`** — not ported; Nehir's refused-frame feedback
  loop already existed (M1 was "not a port"). No Nehir file claims it.

This is an important negative result: the audit and the maintainer agree that
Nehir did **not** pull in upstream's big runtime rewrite, so the large body of
Nehir reconcile/layout code is genuinely Nehir-side, not hidden upstream
derivation.

## Where intent and landed code diverge (M5)

`discovery/20260618-raw-multitouch-gesture-source.md` (the M5 *discovery*,
dated 2026-06-18, before M5 landed) states that upstream `06eb42d` is "not
vendored anywhere in the tree" and that "any prototype must be designed from
documented intent, not ported line-for-line."

The *landed* M5 code (completed `20260620-m5-raw-multitouch-gesture-source.md`,
status `landed`) contradicts that: Nehir vendored `06eb42d` near-verbatim. The
diff is two lines for `MultitouchBinding.swift` (an `import Darwin` and a
rebranded error string) and a small set of Nehir concurrency/modifier deltas
for `MultitouchGestureSource.swift` on top of the intact upstream body. See
`02-borrowed-later.md` for the inlined diffs.

This does not change the classification — category 4 either way — but it is
recorded so future readers do not rely on the discovery doc's "not vendored"
premise when reasoning about the shipped multitouch files. GPL provenance
follows the landed code.

## Net

The audit and the upstream-port roadmap agree on every point that matters for
attribution:

- Every new-file port the roadmap records is caught by the audit as category 4.
- Every rejected upstream candidate is correctly absent from the audit's
  borrowed/derived set.
- The one documentation nuance (M5 vendored despite a "re-implement" discovery)
  is flagged rather than hidden.

This makes the roadmap an independent confirmation of the audit's hardest
claims, from the maintainer's own records.
