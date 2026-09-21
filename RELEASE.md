# Tagged releases

The repository is public. GitHub Actions builds a notarized release only after a SemVer tag is pushed.
Branch pushes, pull requests, deleted tags, and manual dispatch do not run the release build.
The workflow first validates the full tag and requires its commit to be reachable from `main`.

Accepted examples: `v1.2.3`, `1.2.3`, `v1.2.3-rc.1`, and `v1.2.3+build.1`.
Invalid names that match GitHub's broad tag filter fail before the macOS signing job starts.

Stable versions must exceed every published stable version. Existing release tags cannot be overwritten.
Prereleases produce notarized ZIP files but never replace the stable appcast or GitHub's latest release.
The application display version uses the three numeric SemVer components. The GitHub release preserves the full tag.
The workflow run number supplies the increasing application build number.
Do not reset the workflow's run numbering after publishing releases.

## One-time credentials

Add these repository secrets under Settings → Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 of a Developer ID Application certificate export, including its private key. |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12` export. |
| `APPLE_NOTARY_KEY_P8` | Contents of an App Store Connect team API key file. |
| `SPARKLE_PRIVATE_KEY` | Existing GPBar Sparkle key exported by `generate_keys`; use the current 32-byte seed format. |

Add these repository variables:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer team identifier. |
| `APPLE_SIGN_IDENTITY` | Full `Developer ID Application: Name (TEAMID)` identity matching the certificate. |
| `APPLE_NOTARY_KEY_ID` | Identifier of the notarization API key. |
| `APPLE_NOTARY_ISSUER_ID` | Issuer identifier of that team API key. |

Use an App Store Connect team key with notarization access. Individual API keys do not support `notarytool`.
The API key handles notarization; the Developer ID certificate signs executable code.
Do not upload an Apple Development certificate as the release identity.

The Sparkle key must match the public key already embedded in `project.yml`.
Do not generate a different key for CI. Export the existing key through Sparkle into a private temporary file.
Use `gh secret set SPARKLE_PRIVATE_KEY < /private/path/to/exported-key` to upload it without printing it.
Remove the temporary export afterward. Never paste private keys into issues, PRs, or workflow files.

The pipeline creates an isolated temporary keychain and temporary key files on the hosted runner.
Credentials are passed only to the steps that need them. Cleanup runs after success or failure.
Sparkle uses its file-based signing mode to avoid interactive Keychain prompts on CI.
No credentials are copied into the application or uploaded as release assets.

## Build inputs

The job uses the Apple Silicon `macos-26` runner and Xcode 26.6 at `/Applications/Xcode_26.6.app`.
This stable hosted toolchain targets macOS 26. Local builds have also been validated with Xcode 27.
Rust 1.95.0, XcodeGen 2.46.0, Sparkle 2.10.0, and OpenConnect 9.21 remain pinned.
`Packaging/runtime-inputs.json` contains the required native dependency versions and route-script hash.
Homebrew installs build dependencies. CI refuses native versions that differ from the recorded inventory.
If Homebrew advances, review the dependency versions and licenses before updating the inventory.
The packaged application includes its runtime libraries and needs no Homebrew installation.

The pipeline calls the same build, runtime packaging, and notarization scripts used locally.
It signs nested code, verifies the full bundle, submits it to Apple, staples the ticket, and checks Gatekeeper.
A failed signing, notarization, stapling, or verification step prevents publication.

## Publish

Merge the release changes to `main`, configure the credentials, then push one release tag:

```sh
git switch main
git pull --ff-only
git tag v0.1.0
git push origin v0.1.0
```

The Actions page shows the `Release` workflow. Push tags individually and wait for each release to finish.
GitHub serializes release runs. Multiple queued pushes can replace an older pending run.

A stable release contains:

- `GPBar-<build>.zip`: the signed, notarized, stapled application.
- `appcast.xml`: signed archive metadata for Sparkle, including earlier stable entries.

The pipeline downloads the previous stable release's appcast before generating the next one.
Archive signatures use the existing Sparkle key. The script rejects public-key mismatches and non-increasing build numbers.
The new release stays a draft until its assets have uploaded. Publishing then marks a stable release as latest.
GPBar reads `https://github.com/beeltec/gpbar/releases/latest/download/appcast.xml`.
This endpoint becomes available with the first stable release. Until then, checks report an unavailable feed.

If publishing fails after draft creation, inspect the draft before retrying.
The workflow refuses to overwrite an existing release, including a draft.
Resolve or remove that failed draft, then rerun the same workflow. Do not move an already published tag.
A ZIP is the installation and update artifact; this pipeline does not create a DMG.

## Validation limits

A complete hosted notarization run requires the credentials above and a real release tag.

## Primary references

- [GitHub certificate installation](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub tag filters](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushbranchestagsbranches-ignoretags-ignore)
- [Hosted macOS 26 toolchain](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
- [Apple notarization](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [Apple API key types](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [Sparkle publishing](https://sparkle-project.org/documentation/publishing/)
