# AGENTS.md

Instructions for AI agents working on this orphan planning branch.

This branch is **documentation-only by design** (see `README.md`). Planning
folders live at the repo root here — `planned/`, `completed/`, `discovery/`,
`noop/` — rather than under `docs/plans/`. File paths that point to source
(`Sources/Nehir/...`, `Tests/NehirTests/...`) still refer to the main Nehir
repository.

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
