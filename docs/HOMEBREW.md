# Homebrew release flow

Nehir is published through the shared tap:

- Tap repository: <https://github.com/Guria/homebrew-tap>
- Cask file: `Casks/nehir.rb`
- User install command: `brew install --cask guria/tap/nehir`

## Required repository setup

The release workflow in this repository updates the tap repository after building a release ZIP. Configure this secret in the `guria/nehir` repository:

- `TAP_GITHUB_TOKEN`: a GitHub token with write access to `Guria/homebrew-tap` contents.

A fine-grained token scoped only to `Guria/homebrew-tap` with **Contents: Read and write** is sufficient.

For public Homebrew installs, the release asset URL must be publicly downloadable. That means the Nehir source repository should be public, or the release ZIP must be hosted somewhere public with corresponding GPL source access provided to recipients.

## Release steps

1. Update `CFBundleShortVersionString` in `Info.plist`.
2. Commit and push to `main`.
3. Create and push a matching tag:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

4. GitHub Actions runs `.github/workflows/release.yml`, which:
   - verifies the tag version matches `Info.plist`,
   - runs `swift test`,
   - builds `dist/Nehir-<version>.zip`,
   - creates or updates the GitHub release,
   - computes the SHA-256,
   - updates `Guria/homebrew-tap/Casks/nehir.rb`,
   - commits and pushes the tap update.

## Current signing status

Releases are unsigned until Apple Developer ID signing and notarization are configured. Users may see Gatekeeper warnings and must grant Accessibility permission manually.
