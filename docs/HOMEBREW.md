# Homebrew release flow

Nehir is published through the shared tap:

- Tap repository: <https://github.com/Guria/homebrew-tap>
- Cask file: `Casks/nehir.rb`
- User install command: `brew install --cask guria/tap/nehir`

## Required repository setup

The normal release flow is fully automated by `.github/workflows/release.yml` and is started manually from GitHub Actions.

The workflow needs write access to `Guria/homebrew-tap`. Nehir uses a GitHub App instead of a personal access token.

Configure these repository secrets in `Guria/nehir`:

- `TAP_APP_ID`: numeric GitHub App ID.
- `TAP_APP_PRIVATE_KEY`: full private key PEM for the GitHub App.

The GitHub App should be installed only on `Guria/homebrew-tap` and needs repository permissions:

- **Contents: Read and write**
- **Metadata: Read-only**

Also ensure `Guria/nehir` has Actions workflow permissions set to **Read and write permissions** so the workflow can commit release prep changes, create tags, and publish GitHub Releases.

For public Homebrew installs, the release asset URL must be publicly downloadable. That means the Nehir source repository should be public, or the release ZIP must be hosted somewhere public with corresponding GPL source access provided to recipients.

## Changesets

Every user-visible change should add a pending changeset:

```bash
mise run changeset -- patch "Fixed window restoration after display changes."
mise run changeset -- minor "Added a new workspace overview command."
mise run changeset -- major "Changed configuration format incompatibly."
```

Changesets use the official Changesets frontmatter shape:

```markdown
---
"nehir": patch
---

Short user-facing description of the change.
```

Supported bump types are:

- `patch`: bug fixes and small improvements.
- `minor`: new user-facing functionality.
- `major`: incompatible changes.
- `none`: internal note; does not create a versioned release by itself.

CI enforces changeset coverage for source/user-visible changes. If a PR truly has no release-note impact, apply the `no release note` label.

## Normal release steps

Do not manually bump `Info.plist`, generate release notes, create a version tag, or update the Homebrew tap for normal releases.

Instead:

1. Ensure pending changesets are committed on `main`.
2. Open `Guria/nehir` → **Actions** → **Release**.
3. Click **Run workflow** on `main`.
4. Leave prerelease inputs empty/disabled for a stable release.

The workflow will:

1. Read pending `.changeset/*.md` files.
2. Calculate the next app version from the highest bump type and current `Info.plist` version.
3. Update `CFBundleShortVersionString` in `Info.plist`.
4. Generate `docs/releases/vX.Y.Z.md`.
5. Commit release prep back to `main`.
6. Create tag `vX.Y.Z` on the release-prep commit.
7. Build `dist/Nehir-X.Y.Z.zip`.
8. Create the GitHub Release using the generated release notes.
9. Compute the release ZIP SHA-256.
10. Update `Guria/homebrew-tap/Casks/nehir.rb` with the new version and checksum.
11. Commit and push the tap update.
12. Clear consumed pending changesets from `main` after publishing succeeds.

If any publishing step fails before changeset cleanup, pending changesets remain in `.changeset/` so the release can be retried safely.

## Prereleases

Prereleases are also published to the RC cask in the Homebrew tap. Users can install the current preview build with:

```bash
brew install --cask guria/tap/nehir@rc
```

To publish a GitHub prerelease and update `nehir@rc`:

1. Open `Guria/nehir` → **Actions** → **Release**.
2. Click **Run workflow** on `main`.
3. Enable `prerelease`.
4. Set `prerelease_suffix`, for example `rc.1` or `beta.1`.

The workflow tags the release as `vX.Y.Z-<suffix>`, creates `dist/Nehir-X.Y.Z-<suffix>.zip`, marks the GitHub Release as a prerelease with notes showing only changes since the last RC, and updates `Guria/homebrew-tap/Casks/nehir@rc.rb`. It skips committing release prep and changeset cleanup so the same pending changesets remain available for the next stable release.

## Mise file tasks

Release helper commands are exposed as mise file tasks under `.config/mise/tasks/` so the task implementation remains ordinary shell script with editor syntax highlighting.

## Useful local checks

Preview the calculated next release:

```bash
mise run release:plan
```

Create a changeset:

```bash
mise run changeset -- patch "Fixed window restoration after display changes."
```

Run the changeset coverage check:

```bash
mise run changeset:check
```

Generate release notes manually only for debugging the release workflow:

```bash
mise run release:notes -- 0.2.2
```

Run tests:

```bash
mise run test
```

## Apple Developer ID signing and notarization

Releases are signed with a Developer ID Application certificate and notarized through Apple's notary service. The release workflow handles signing and notarization automatically.

### Required repository secrets

Configure these secrets in `Guria/nehir` → Settings → Secrets and variables → Actions:

| Secret | Description |
|---|---|
| `APPLE_DEVELOPER_ID_CERT_P12_BASE64` | Base64-encoded Developer ID Application `.p12` certificate |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | Password used when exporting the `.p12` from Keychain |
| `APPLE_SIGNING_IDENTITY` | Full codesigning identity string, e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID |
| `APPLE_NOTARY_KEY_P8` | Full contents of the App Store Connect API `.p8` private key |

The certificate is exported from Keychain Access as a `.p12` (Personal Information Exchange) containing the certificate and private key. The API key is created in App Store Connect → Users and Access → Integrations → App Store Connect API.
