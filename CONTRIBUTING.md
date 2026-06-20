# Contributing

Bug fixes, performance improvements, and focused cleanups welcome.

## Direction & maintenance principles

Nehir is an independent, opinionated fork with a deliberately narrow scope
(Niri-style scrolling columns). It is not affiliated with or endorsed by the
upstream OmniWM author; see [NOTICE.md](NOTICE.md) for origin and attribution.

### What to expect

- **Issues and PRs should receive an explicit response.** Not every feature
  request is accepted and not every PR is merged, but the goal is to make
  decisions clear rather than leave them hanging.
- **Attribution stays.** Nehir always credits the prior art and its author — the
  fork exists because that work was shared as open source.
- **Opinionated, but open to influence.** Contributors can affect the direction;
  the final call stays with the maintainer and is stated clearly.
- **Clear release channels.** Stable, RC, and experimental work are not mixed
  without warning.
- **Configuration changes are documented before release where possible.**
- **Issues are not closed just because internals changed.** User-facing behavior
  is checked against a current build where feasible before a report is treated
  as no longer relevant.
- **Low-effort or obviously AI-generated contributions** may be reviewed with
  automation or closed quickly. Using LLMs is fine; submitting unreviewed,
  low-quality output is not.

### What not to expect

- No sudden core rewrites in patch releases.
- No surprise project renaming, ownership transfers, or ground-up rewrites in
  another language.
- No mass issue cleanup without validating whether the reported behavior still
  reproduces on the latest release.
- No guarantee that every requested feature is accepted — a smaller scope is
  part of the design.

Plans can change, but if they do, it is said clearly and early.

### Open source is not ownership

Ideas and fixes are not personal property. If something introduced here later
shows up upstream or elsewhere, that is a good outcome — better software for
users is a win. The door works both ways: Nehir may also adopt ideas that land
upstream when they fit this fork's scope. It is independent, but not isolated.

## Reporting issues

A well-described issue or plan is often more valuable than a direct code change.
**Share the pain** — workflow, reproduction steps, setup, and expected behavior —
before jumping to an assumed solution. Testing, traces, and clear reports matter
as much as code. See the README's *Debugging & Tracing* section for how to
capture a clean trace.

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
- SwiftFormat rules in `.swiftformat`

### Lint and format

SwiftLint and SwiftFormat are enforced in CI on every push and pull request.
Both tools are pinned in `.config/mise/conf.d/tools.toml`, so `mise` delivers
the exact versions used in CI with no separate install step.

Swift itself is **not** managed by mise — on macOS it comes from Xcode
(selected via `.swift-version` / `xcrun`). The config marks this explicitly
with `disable_tools = ["swift"]`, so mise never tries to download a
swift.org toolchain.

```bash
mise run format        # apply SwiftFormat
mise run format:check  # fail if anything is unformatted (what CI runs)
mise run lint          # run SwiftLint
mise run check         # format:check + lint + build + test
```

SwiftFormat owns formatting; SwiftLint flags anything it would change in
`.swiftlint.yml` to avoid conflicts. CI runs `format:check` (any unformatted
file fails) and `lint` (error-level violations fail; warnings are reported but
non-blocking). Run `mise run format` before pushing.

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

Release maintainers run the `Release` workflow manually on `main`. The workflow calculates the next version from the latest stable tag plus pending changesets, stamps `Info.plist` in the workflow workspace only, renders the release notes directly into the GitHub Release description, creates the tag and GitHub Release after the signed/notarized build succeeds, updates the Homebrew tap, and clears consumed changesets after publishing succeeds.

See [docs/HOMEBREW.md](docs/HOMEBREW.md) for the full release setup and flow.
