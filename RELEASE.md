# Tagged releases

Disable [macOS login SSO](LOGIN-SSO.md) for every enrolled user before updating or reinstalling GPBar.
The app blocks helper removal and Sparkle preparation while its login mechanism is active.
The PKG installer also checks this rule. Re-enable the integration after updating.

The repository is public. GitHub Actions builds a notarized release only after a SemVer tag is pushed.
Branch pushes, pull requests, deleted tags, and manual dispatch do not run the release build.
The workflow first validates the full tag and requires its commit to be reachable from `main`.

Accepted examples: `v1.2.3`, `1.2.3`, `v1.2.3-rc.1`, and `v1.2.3+build.1`.
Invalid names that match GitHub's broad tag filter fail before the macOS signing job starts.

Stable versions must exceed every published stable version. Existing release tags cannot be overwritten.
Prereleases produce notarized DMG and PKG files but never replace the stable appcast or GitHub's latest release.
The application display version uses the three numeric SemVer components. The GitHub release preserves the full tag.
The workflow run number supplies the increasing application build number.
Do not reset the workflow's run numbering after publishing releases.

## One-time credentials

Add these repository secrets under Settings → Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 of a Developer ID Application certificate export, including its private key. |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12` export. |
| `APPLE_INSTALLER_CERTIFICATE_P12_BASE64` | Base64 of a Developer ID Installer certificate export, including its private key. |
| `APPLE_INSTALLER_CERTIFICATE_PASSWORD` | Password protecting the installer `.p12` export. |
| `APPLE_NOTARY_KEY_P8` | Contents of an App Store Connect team API key file. |
| `SPARKLE_PRIVATE_KEY` | Existing GPBar Sparkle key exported by `generate_keys`; use the current 32-byte seed format. |

Add these repository variables:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer team identifier. |
| `APPLE_SIGN_IDENTITY` | Full `Developer ID Application: Name (TEAMID)` identity matching the certificate. |
| `APPLE_INSTALLER_SIGN_IDENTITY` | Full `Developer ID Installer: Name (TEAMID)` identity matching the installer certificate. |
| `APPLE_NOTARY_KEY_ID` | Identifier of the notarization API key. |
| `APPLE_NOTARY_ISSUER_ID` | Issuer identifier of that team API key. |

Use an App Store Connect team key with notarization access. Individual API keys do not support `notarytool`.
The API key handles notarization. The Application certificate signs executable code and DMGs; the Installer certificate signs PKGs.
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

## Build and validate locally

Local distribution builds use the same signing, notarization, and packaging scripts as GitHub Actions.
They do not require a pushed tag or publish a release.

Import your Developer ID Application and Developer ID Installer certificate backups into your login Keychain using Keychain Access.
Both imports must include their private keys. Keep backup files and passwords outside the repository.
Use `security find-identity -v -p codesigning` to check the Application identity.
Use `security find-identity -v -p basic` to check the Installer identity.

Save notarization credentials once, using the existing App Store Connect team key:

```sh
xcrun notarytool store-credentials gpbar-release \
  --key /private/path/AuthKey_KEYID.p8 \
  --key-id KEYID --issuer ISSUER_UUID
```

The command validates the credentials with Apple and stores them in Keychain.
Do not put certificate passwords or private keys in shell configuration files.
Save only these non-secret values in `~/.config/gpbar/release.env`:

```sh
export GPBAR_TEAM=TEAMID
export GPBAR_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export GPBAR_INSTALLER_SIGN_IDENTITY='Developer ID Installer: Your Name (TEAMID)'
export GPBAR_NOTARY_PROFILE=gpbar-release
```

Load that configuration and choose a new output directory:

```sh
. "$HOME/.config/gpbar/release.env"
GPBAR_VERSION=0.2.0 GPBAR_BUILD=3 \
GPBAR_RELEASE_ROOT="$PWD/build/v0.2.0-distribution" \
scripts/build-local-release.sh
```

Use a positive build number above the last published build. CI still assigns its own build number when publishing.
The command checks signing identities, notarization access, and the same native dependency pins enforced by CI.
Local builds support Xcode 27. Tagged CI releases use Xcode 26.6.
It builds and signs the app, then notarizes and verifies the app, DMG, and PKG.
Keychain may request permission for signing tools to use the imported keys.
Existing output directories are refused. Failed output remains available for inspection; choose a new directory before retrying.

The output contains `GPBar.app`, `packages/GPBar-<version>.dmg`, and `packages/GPBar-<version>.pkg`.
The `notarized.zip` file is an internal app archive, not a release download.
No tag, GitHub release, or Sparkle feed is created.

Before running another build, disconnect and remove the current helper, then quit GPBar.
Disable macOS login SSO for every enrolled user first, if enabled.
Install the notarized app and verify helper startup, browser sign-in, connection, and disconnect on a controlled Mac.
Check saved preferences, cancellation, update behavior, and route/DNS restoration.
Record actual results separately from build and notarization checks. Unavailable providers and hardware remain validation limits.

## Publish

Merge the release changes to `main`, configure the credentials, then push one release tag:

```sh
git switch main
git pull --ff-only
git tag v0.2.0
git push origin v0.2.0
```

The Actions page shows the `Release` workflow. Push tags individually and wait for each release to finish.
GitHub serializes release runs. Multiple queued pushes can replace an older pending run.

A stable release contains:

- `GPBar-<version>.dmg`: the signed, notarized disk image containing the stapled application and an Applications shortcut.
- `GPBar-<version>.pkg`: the signed, notarized installer for `/Applications/GPBar.app`.
- `appcast.xml`: signed archive metadata for Sparkle, including earlier stable entries.

Download names use the release version, such as `GPBar-0.2.0.pkg`, rather than the workflow build number.
Prerelease names retain their suffix, such as `GPBar-0.2.0-rc.1.pkg`.
Names omit the tag's leading `v` and optional `+` build metadata. The full tag remains on the GitHub release.
This follows the [name-and-version convention](https://www.gnu.org/prep/standards/html_node/Releases.html) and avoids characters GitHub may rename during upload.
See [GitHub asset naming](https://docs.github.com/en/rest/releases/assets#upload-a-release-asset).
Local packaging defaults to the app version. Set `GPBAR_RELEASE_VERSION` to include a matching prerelease suffix.
The application and Sparkle still use increasing internal build numbers. The PKG receipt version still includes both version and build.
The update script preserves the DMG filename when generating its download URL.

The pipeline downloads the previous stable release's appcast before generating the next one.
Archive signatures use the existing Sparkle key. The script rejects public-key mismatches and non-increasing build numbers.
The new release stays a draft until its assets have uploaded. Publishing then marks a stable release as latest.
GPBar reads `https://github.com/beeltec/gpbar/releases/latest/download/appcast.xml`.
This endpoint becomes available with the first stable release. Until then, checks report an unavailable feed.

If publishing fails after draft creation, inspect the draft before retrying.
The workflow refuses to overwrite an existing release, including a draft.
Resolve or remove that failed draft, then rerun the same workflow. Do not move an already published tag.
Sparkle uses the DMG. ZIP files are used only for internal application notarization and are not published.
The PKG requires Apple Silicon and macOS 26 or newer. It does not register or launch the privileged helper.
The installer refuses to replace running GPBar, helper, or OpenProtect processes.
Before reinstalling, disconnect, remove the helper in Edit Connection, and quit GPBar.

## Authorized v0.1.0 correction

The initial v0.1.0 shipped a ZIP, a development label, and diagnostic controls.
The owner requested deletion and recreation after the fixes pass review and validation.
Back up the original release metadata, assets, and tag before deleting them.
Move v0.1.0 to the reviewed merge commit and publish with a higher workflow build number.
This is an explicit exception to the published-tag rule above, not the normal release process.
Existing installations discover the replacement through its higher Sparkle build number.

## Validation limits

A complete hosted notarization run requires the credentials above and a real release tag.

### Local v0.2.0 candidate, 2026-09-23

Version 0.2.0, build 3 was built on Apple Silicon with macOS 26.6.2 and Xcode 27.0.
The candidate remains unpublished.

- The app, DMG, and PKG passed Developer ID signing, notarization, stapling, and Gatekeeper checks.
- The native dependency pins passed. Bundled binaries had no external build dependencies or development debugging entitlements.
- The PKG upgraded the local installation successfully. The installed app, helper, and engine matched the signed build.
- Helper startup, removal, and setup passed. Saved settings survived installation and relaunch.
- Invalid portal input, authentication selection, sign-in cancellation, and the update feed check passed.
- Embedded SAML login completed, opened a tunnel, and closed its sign-in window automatically.
- The configured VPN DNS server answered through the tunnel. Public HTTPS worked during and after connection.
- Disconnect stopped the engine, removed the tunnel, and restored non-neighbor-cache routes and DNS configuration.

macOS regenerated numeric DNS order values after disconnect. Resolver contents and relative priority matched the original configuration.
No internal application endpoint was supplied. New authentication providers, smart-card hardware, and real macOS login capture remain unverified.
Clean-machine installation, macOS 26.0, sleep/wake, crash recovery, and a Sparkle installation still need live checks.

### Versioned filenames, 2026-09-23

The same local candidate produced `GPBar-0.2.0.dmg` and `GPBar-0.2.0.pkg` through the updated packaging script.
Both passed signing, notarization, stapling, and Gatekeeper checks.
Sparkle generated the versioned DMG URL with internal build 3 and preserved the previous release's build-based URL.
The copied update DMG matched the packaged file byte for byte. These checks did not publish a GitHub release or install an update.

## Primary references

- [GitHub certificate installation](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub tag filters](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushbranchestagsbranches-ignoretags-ignore)
- [Hosted macOS 26 toolchain](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
- [Apple notarization](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [Apple API key types](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [Sparkle publishing](https://sparkle-project.org/documentation/publishing/)
