---
description: Inspect and guide the automated Nehir release flow
argument-hint: "[instructions]"
---
Help with Nehir's automated release process.

Important guardrail: do not push commits, create/move tags, cancel/rerun workflows, edit GitHub Releases, or push the Homebrew tap unless I explicitly ask for that exact remote action.

Current release model:

- Developers add pending `.changeset/*.md` files with official Changesets-style frontmatter.
- `Info.plist` version bumps are automated by the `Release` workflow.
- `docs/releases/vX.Y.Z.md` generation is automated by the `Release` workflow.
- Version tag creation is automated by the `Release` workflow.
- Homebrew tap updates are automated by the `Release` workflow.
- Consumed changeset cleanup is automated after all publishing steps succeed.

Use these local commands when needed:

- Create a changeset:
  `mise run changeset -- patch "Describe the user-visible change."`
- Check changeset coverage:
  `mise run changeset:check`
- Preview the next release plan:
  `mise run release:plan`
- Run tests:
  `mise run test`

When asked to prepare or inspect a release:

1. Check the working tree with `git status --short`.
2. Summarize unrelated dirty files and ask before touching them.
3. Inspect pending `.changeset/*.md` files, excluding `.changeset/README.md`.
4. Run `mise run release:plan` to preview the calculated bump/version when pending changesets exist.
5. Do not manually edit `Info.plist` or generate `docs/releases/vX.Y.Z.md` for the normal release path.
6. Remind me that the normal release action is: GitHub → Actions → Release → Run workflow on `main`.
7. If release automation fails, diagnose the failed step and propose the minimal repair, but wait for confirmation before any remote mutation.

The `Release` workflow will:

1. Read pending changesets.
2. Calculate the next version from the highest bump type and current `Info.plist` version.
3. Update `Info.plist`.
4. Generate `docs/releases/vX.Y.Z.md`.
5. Commit release prep to `main`.
6. Create tag `vX.Y.Z`.
7. Build `dist/Nehir-X.Y.Z.zip`.
8. Create the GitHub Release with generated notes.
9. Update `Guria/homebrew-tap/Casks/nehir.rb` using the GitHub App token.
10. Clear consumed `.changeset/*.md` files from `main` after publishing succeeds.

If the user asks for GitHub App setup, point them to `docs/HOMEBREW.md` and summarize the required secrets: `TAP_APP_ID` and `TAP_APP_PRIVATE_KEY`.
