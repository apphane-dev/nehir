# Changesets

Add a small changeset for every user-visible change while the context is fresh.

Nehir uses the official Changesets frontmatter shape, but keeps app versioning
explicit in `Info.plist` and git tags.

Format:

```markdown
---
"nehir": patch
---

Short user-facing description of the change.
```

Use:

```bash
mise run changeset -- patch "Fixed window restoration after display changes."
mise run changeset -- minor "Added a new workspace overview command."
mise run changeset -- major "Changed configuration format incompatibly."
```

Supported bump types are `patch`, `minor`, `major`, and `none`. The release
workflow calculates the next app version from pending changesets and the current
`Info.plist` version.

To release, run the `Release` GitHub Actions workflow manually. It updates
`Info.plist`, generates `docs/releases/vX.Y.Z.md`, creates the version tag,
publishes the GitHub release, updates the Homebrew tap, and clears consumed
pending changesets after all publishing steps succeed (stable only; prereleases
update the `nehir@rc` cask, show only diffs from the previous RC, and skip
changeset cleanup).
