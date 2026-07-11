# AGENTS.md

Instructions for AI agents working in this repository.

## Plans branch instructions

When working with planning documents in the dedicated plans-only worktree/branch,
read that worktree's `AGENTS.md` first and follow it. The plans branch has its
own document layout and stricter durable-doc rules (for example, no local
machine-specific paths in discovery/planning docs).

## Tests

Read `docs/TESTING.md` before adding, moving, or deleting tests. The hard
rules, in short:

- **Wait for the user-confirmed fix before editing tests.** When debugging a
  runtime bug, do not add, modify, or rewrite tests until the user has
  confirmed the fix works in their real repro. Runtime traces and the user's
  validation are the acceptance signal; touching tests before that wastes
  tokens and creates churn.
- **New tests go into small per-behavior files.** The legacy monoliths
  (`AXEventHandlerTests.swift`, `NiriLayoutEngineTests.swift`, and the others
  listed in `docs/TESTING.md`) are frozen — never append tests to them.
- **Test hooks observe; they do not decide.** Do not add `ForTests`
  conditionals in `Sources/` that change a Nehir-owned decision (skip
  reconciliation, lifecycle, scheduling, fallback, or cleanup). Fake the OS
  boundary, not the algorithm.
- Run the suite with `mise run test`; keep it gated in CI.

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

Reference **only the nehir repo's own ticket number** (e.g. `Fixes #nnn`) in
changesets and commit messages — a bare `#nnn` auto-links to this repository on
GitHub, so it must point at the nehir issue, not upstream. **Do not** cite
upstream tickets (e.g. `OmniWM #nnn`, `BarutSRB/OmniWM#nnn`) in changesets or
commit messages; track upstream provenance in the nehir ticket body instead,
where it belongs.

In places where upstream tickets *are* cited (issue bodies, discovery and
planning documents), always use the full cross-repo form `BarutSRB/OmniWM#nnn`
— never `OmniWM #nnn` or bare `#nnn`. Bare `#nnn` means this repo's own
tracker; the two trackers share overlapping number ranges, so only the
`owner/repo#nnn` form is unambiguous.

## Commit messages

Do not use Conventional Commits formatting (`fix:`, `feat:`, `chore:`, etc.).
Use concise plain-English commit subjects instead.

As with changesets, reference only the nehir repo's own ticket number (`#NN`)
never upstream tickets — upstream provenance lives in the ticket body.

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
