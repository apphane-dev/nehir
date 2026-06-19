# AGENTS.md

Instructions for AI agents working in this repository.

## Plans branch instructions

When working with planning documents in the dedicated plans-only worktree/branch,
read that worktree's `AGENTS.md` first and follow it. The plans branch has its
own document layout and stricter durable-doc rules (for example, no local
machine-specific paths in discovery/planning docs).

## Tests: wait for user-confirmed fix before editing

When debugging a runtime bug, **do not add, modify, or rewrite tests until the
user has confirmed the fix works in their real repro**. Runtime traces and the
user's validation are the acceptance signal. Touching tests before that
confirmation wastes tokens and creates churn. After the user confirms the fix,
then add or update regression tests if requested or clearly useful.

## Changesets

For user-visible changes, create a Changesets release-note fragment with:

```bash
mise run changeset <patch|minor|major|none> "User-facing summary"
```

Use `patch` for bug fixes, `minor` for new user-facing features, `major` for
breaking changes, and `none` for release-note-only changes. Add contributors
when needed with `--contributors handle1,handle2`. Issue reporters count as
contributors; include their GitHub handle when a change fixes a reported issue.
Mention the ticket/issue number in the changeset summary when one was involved.

## Commit messages

Do not use Conventional Commits formatting (`fix:`, `feat:`, `chore:`, etc.).
Use concise plain-English commit subjects instead.

## Discovery documents: do not reference trace log filenames

When writing discovery / investigation documents (under `docs/plans/discovery/`,
or anywhere that records a runtime bug), **do not reference trace log filenames**
(e.g. `runtime-trace-1781525802769-1781525820832.log`, line numbers inside a
log, "trace 1 / trace 2", or relative paths into `~/.local/state/nehir/traces/`).

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

Code citations (file + line, e.g. `AXEventHandler.swift:1790`) are fine and
encouraged — they point at durable source, not ephemeral runtime output.
