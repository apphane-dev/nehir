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

Use `patch` for normal app changes. The release type is only validation metadata
for the changeset fragment; Nehir does not use Changesets to bump versions.

Before tagging a release, generate release notes:

```bash
Scripts/prepare-release-notes.sh 0.2.2
```

This creates `docs/releases/v0.2.2.md`. Pending changesets intentionally stay in
`.changeset/` until the release workflow succeeds. After the GitHub release and
Homebrew tap update succeed, the workflow clears consumed pending changesets from
`main` automatically.
