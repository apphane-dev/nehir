# AGENTS.md

Instructions for AI agents working on this orphan planning branch.

This branch is **documentation-only by design** (see `README.md`). Planning
folders live at the repo root here — `planned/`, `completed/`, `discovery/`,
`noop/` — rather than under `docs/plans/`. File paths that point to source
(`Sources/Nehir/...`, `Tests/NehirTests/...`) still refer to the main Nehir
repository.

## Workflow lifecycle

Planning work moves through a fixed lifecycle. Each stage has a home and a
discipline; keep documents in sync with where the work actually is.

1. **Discovery** (`discovery/`) — investigate a bug or opportunity and write a
   self-contained, source-backed root-cause note. Trace logs to a hypothesis,
   then **confirm the arming/gating condition in actual source** (cite file +
   line) before writing anything down. If source contradicts the hypothesis,
   discard it and re-investigate — do not ship repro steps inferred from traces
   alone. A discovery whose verdict is no-op / already-fixed / duplicate / not
   applicable moves to `noop/` with the verdict stated up front.
2. **Plan** (`planned/`) — turn an actionable discovery into a self-contained
   plan: exact files to touch (repo-relative source paths), explicit
   do-not-touch fences naming what parallel work owns, the fast gate to run
   between steps and the full suite once at the end, and the required commit
   message shape.
3. **Delegate & implement** (happens on `main`, not here) — hand the plan to a
   worker agent in an isolated worktree using an approved model. Do not make the
   spec'd edits directly; delegate, then supervise.
4. **Review & verify** — read the worker's diff yourself and re-run the gate in
   a fresh pane. Merge only on green gates. Never trust an agent's "all green".
5. **Housekeep** — once shipped or superseded, move the plan/discovery to
   `completed/` (or `noop/`), keep it consistent with merged `main` state and
   git history, and record follow-up work as a new discovery. Commit
   per-action with the branch's message conventions.

Every document must stay durable and machine-independent (see the two sections
below): no trace log filenames, no machine-specific paths.

## Discovery documents: do not reference trace log filenames

When writing discovery / investigation documents (under `discovery/`, `completed/`,
`noop/`, `planned/`, or anywhere that records a runtime bug), **do not reference
trace log filenames** (e.g. `runtime-trace-1781525802769-1781525820832.log`, line
numbers inside a log, "trace 1 / trace 2", or relative paths into
`~/.local/state/nehir/traces/`).

**Why:** trace logs are machine-local and ephemeral. They will not exist later,
on another machine, or in CI — so any finding that depends on re-opening one
becomes unverifiable and effectively useless.

**Do instead — inline the evidence into the document itself.** A discovery must
be self-contained. Copy the specific values, events, or fields that prove the
finding directly into the prose:

- Relevant log lines / events, quoted as text (not as a file reference).
- The concrete numeric state that demonstrates the bug — e.g.
  `currentViewStart=3186.1 → targetViewStart=1259.5`,
  `isWorkspaceActive=false`, `interactionMonitor=display 2`, `didReveal=true`.
- Window tokens, pids, workspace/monitor identifiers needed to follow the
  reasoning, restated where they matter (not "see the log").
- The topology/initial state required to reproduce (which app on which monitor,
  which workspace was focused, etc.).

The goal is that the document can be read and acted on with no access to any
captured log. If a detail is worth citing from a trace, it is worth copying into
the document.

A durable link to the **original** captured trace (e.g. a GitHub user-attachment
URL pasted from the source issue) is acceptable as a pointer to the full raw
capture, but is not a substitute for inlining the evidence — the document must
still stand on its own without opening the link.

Code citations (file + line, e.g. `AXEventHandler.swift:1790`) are fine and
encouraged — they point at durable source, not ephemeral runtime output.

## Discovery documents: do not encode machine-specific paths

When writing durable planning or discovery documents, **do not include local
machine-specific filesystem paths** such as `/Users/...`, worktree checkout paths,
`~/.herdr/...`, `~/.local/...`, or absolute paths to the main source checkout.

Use repository-relative source paths instead, for example:

- `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift`
- `Tests/NehirTests/WorkspaceNavigationHandlerTests.swift`
- `discovery/20260618-stale-session-selection-revision-guard.md`

For verification/provenance wording, say "verified against the main Nehir source
tree" or "verified against `main` on YYYY-MM-DD" rather than naming the local
checkout path. Durable docs must remain useful on another machine, in another
worktree, and after local trace/worktree cleanup.
