---
description: Prepare and verify a Nehir release
argument-hint: "<version> [notes]"
---
Prepare a Nehir release for version `$1`.

Use this repo's release process:

1. Verify the working tree and current version state:
   - `git status --short`
   - read `Info.plist` and confirm `CFBundleShortVersionString` should become `$1`
   - inspect pending `.changeset/*.md` files, excluding `.changeset/README.md`

2. If `$1` is missing, stop and ask for the target version.

3. If there are no pending changesets, stop and ask whether to create one. Do not invent user-visible changes.

4. Update release metadata as needed:
   - set `CFBundleShortVersionString` in `Info.plist` to `$1` if it differs
   - do not change bundle identifiers or unrelated plist keys

5. Generate release notes from changesets:
   - run `Scripts/prepare-release-notes.sh $1`
   - inspect `docs/releases/v$1.md`
   - if extra notes were provided in the prompt (`${@:2}`), incorporate them carefully into the generated release notes without deleting generated entries

6. Validate before tagging:
   - run `swift test --no-parallel`
   - run `ruby -c .github/workflows/release.yml` only if Ruby syntax is relevant; otherwise do not treat YAML as Ruby
   - check that `docs/releases/v$1.md` exists and is non-empty
   - check that consumed changesets were archived under `docs/releases/changesets/v$1/`

7. Show me the exact final commands to commit and tag, but do not run them unless I explicitly ask:
   - `git add Info.plist docs/releases .changeset`
   - `git commit -m "Prepare release $1"`
   - `git tag v$1`
   - `git push origin main`
   - `git push origin v$1`

8. Remind me what GitHub Actions will do after the tag is pushed:
   - verify `Info.plist` version matches the tag
   - require `docs/releases/v$1.md`
   - build `dist/Nehir-$1.zip`
   - create/update the GitHub Release using that notes file
   - update the Homebrew cask checksum in `Guria/homebrew-tap`

Be careful and conservative. If the repository is dirty in unrelated ways, summarize the dirty files and ask before proceeding.
