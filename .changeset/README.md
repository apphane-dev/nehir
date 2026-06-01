# Changesets

Add a small changeset for every user-visible change while the context is fresh.

Format:

```markdown
---
type: added|changed|fixed|removed|security|internal
---

Short user-facing description of the change.
```

Use:

```bash
Scripts/add-changeset.sh fixed "Fixed window restoration after display changes."
```

Before tagging a release, generate release notes:

```bash
Scripts/prepare-release-notes.sh 0.2.1
```

This creates `docs/releases/v0.2.1.md` and archives consumed changesets under
`docs/releases/changesets/v0.2.1/`.
