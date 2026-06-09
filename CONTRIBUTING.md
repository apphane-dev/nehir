# Contributing

Bug fixes, performance improvements, and focused cleanups welcome.

## Setup

```bash
git clone <repo>
cd nehir
mise run build
mise run dev
```

## Code Style

- Swift 6 strict concurrency
- `@MainActor` for all UI and controller code
- SwiftLint rules in `.swiftlint.yml`

## Changesets

Add a changeset for every user-visible change while the context is fresh:

```bash
mise run changeset -- patch "Fixed window restoration after display changes."
```

Use:

- `patch` for fixes and small improvements.
- `minor` for new user-facing functionality.
- `major` for incompatible changes.
- `none` only for internal notes that should not drive a version bump.

Release notes preserve structured Markdown in changeset bodies. For breaking changes, start the body with `BREAKING:` / `BREAKING CHANGE:` or use a `major` bump; those entries render in a separate **Breaking changes** section. Keep unrelated non-breaking fixes in separate changesets.

CI checks that source/user-visible changes include a `.changeset/*.md` file. If a PR truly has no release-note impact, apply the `no release note` label.

## Releases

Normal releases are automated through GitHub Actions. Do not manually bump `Info.plist`, create release notes, tag a version, or update the Homebrew tap for a standard release.

Release maintainers run the `Release` workflow manually on `main`. The workflow calculates the next version from the latest stable tag plus pending changesets, stamps `Info.plist` and generated release notes in the workflow workspace only, creates the tag and GitHub Release after the signed/notarized build succeeds, updates the Homebrew tap, and clears consumed changesets after publishing succeeds.

See [docs/HOMEBREW.md](docs/HOMEBREW.md) for the full release setup and flow.
