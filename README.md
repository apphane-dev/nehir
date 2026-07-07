# Nehir plans

This orphan branch contains Nehir planning documents only. It is intentionally
detached from the main source tree so `main` can drop `docs/plans/` without losing
planning history or implementation context.

## Layout

- `planned/` — active plans that have not been completed or superseded.
- `completed/` — plans that shipped, were completed, or were explicitly superseded.
- `discovery/` — investigation notes and applicability studies that may still own
  follow-up work.
- `noop/` — discovery notes whose verdict is no-op, already fixed, duplicate,
  not applicable, or not worth porting.

## Notes

- File paths inside documents that point to source files (for example
  `Sources/Nehir/...`, `Tests/NehirTests/...`, or `docs/...`) refer to paths in the
  main Nehir repository, not to files on this branch.
- Internal planning links use the root-level folders above rather than
  `docs/plans/...`.
- High-confidence discovery cross-links are collected in
  `discovery/20260708-cross-discovery-relevance-clusters.md`.
- This branch is documentation-only by design; no source code is expected here.
