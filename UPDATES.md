# Automatic updates

Disable [macOS login SSO](LOGIN-SSO.md) for every enrolled user before updating or reinstalling GPBar.
The app blocks helper removal and Sparkle preparation while its login mechanism is active.
The PKG installer also checks this rule. Re-enable the integration after updating.

GPBar uses Sparkle 2.10.0, pinned through Swift Package Manager.
It checks daily by default. Users can disable checks in Settings → Updates.
The same section and application menu provide Check for Updates.
Sparkle stores the preference; GPBar does not keep a second copy.

Updates require user confirmation. Unattended downloads and installation are disabled.
Disconnect before installing. GPBar reserves the idle helper, then unregisters it before allowing Sparkle to download the update.
The helper rejects new sessions during this reservation. Active sessions and unresolved recovery block installation.
Launch Services rejects additional app instances to avoid competing update and helper owners.
A resumed prepared update repeats helper preparation before showing its window. Failed preparation requests cancellation and blocks new connections.
The app blocks Connect, helper setup, and recovery while updating.
Helper setup and confirmed cleanup are required even when no service is currently registered.
Cancelling before extraction restores the helper. Once extraction starts, the helper stays stopped until GPBar exits.
An installer error does not prove cancellation. Finish the update or restart GPBar before connecting again.
A lost reservation connection leaves the helper blocked. Remove it in Settings and set it up again if preparation fails.
Relaunch registers the bundled helper through the normal launch flow. macOS may require approval again.
Updating never starts a VPN connection. Existing preferences and Keychain entries remain in place.

## Why Sparkle

Sparkle supplies native windows, scheduling, archive verification, replacement, and relaunch.
A custom updater would duplicate this security-sensitive work.
App Store updates do not match the current Developer ID distribution and privileged helper design.

The small standard-user-driver subclass delays the Install response until helper shutdown succeeds.
Sparkle's relaunch callback alone is insufficient: an already prepared update can install when the app exits.
Automatic installation stays disabled so every download passes through that safety gate.

Primary references:

- [Sparkle setup and signing](https://sparkle-project.org/documentation/)
- [Programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/)
- [User driver contract](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html)
- [Updater delegate contract](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
- [Publishing updates](https://sparkle-project.org/documentation/publishing/)

## Signing and hosting

The repository and release downloads are public.
The default feed is `https://github.com/beeltec/gpbar/releases/latest/download/appcast.xml`.
Stable releases publish their appcast at this endpoint.
`GPBAR_UPDATE_FEED_URL` can override the feed for a local build.
The tracked empty `updates/appcast.xml` bootstraps the first release. Later releases use the previous published appcast.
See [tagged releases](RELEASE.md) for the CI workflow and credential setup.
The initial updater-enabled app must be installed manually. Earlier builds cannot discover updates.

Every archive requires an Ed25519 signature before extraction, plus normal application code-signing validation.
Production builds require Developer ID signing and notarization. Development certificates cannot replace that requirement.
Feeds and release downloads use HTTPS. System profiling is disabled, and GPBar supplies no custom request parameters.

The public key is recorded in `project.yml` and embedded as `SUPublicEDKey`.
Local signing uses the macOS login Keychain under Sparkle account `com.beeltec.GPBar.updates`.
CI uses the same key through a GitHub secret and a temporary file.
Back up that key using Sparkle's documented secure export process before distributing the first release.
Never commit or print the private key. Do not generate a replacement key for each release.

## Prepare a release

For a complete local app, DMG, and PKG build, follow [local distribution builds](RELEASE.md#build-and-validate-locally).
The steps below also prepare a Sparkle feed when publication is intended.

Use the existing native build and notarization prerequisites.
Choose the distribution signing team before shipping; this repository does not prescribe a team.
Increase `GPBAR_BUILD` for every release. Use a positive integer greater than all published build numbers.
Set `GPBAR_VERSION` to the user-visible version.

```sh
GPBAR_VERSION=0.1.1 GPBAR_BUILD=2 \
GPBAR_UPDATE_FEED_URL='https://github.com/beeltec/gpbar/releases/latest/download/appcast.xml' \
GPBAR_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
GPBAR_TEAM=TEAMID GPBAR_OUTPUT="$PWD/build/release-2/GPBar.app" \
scripts/build-app.sh

GPBAR_APP="$PWD/build/release-2/GPBar.app" \
GPBAR_NOTARY_PROFILE=your-notary-profile \
GPBAR_RELEASE_ZIP="$PWD/build/notarized-2.zip" \
scripts/notarize-app.sh

GPBAR_APP="$PWD/build/release-2/GPBar.app" \
GPBAR_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
GPBAR_INSTALLER_SIGN_IDENTITY='Developer ID Installer: Your Name (TEAMID)' \
GPBAR_NOTARY_PROFILE=your-notary-profile \
GPBAR_RELEASE_OUTPUT="$PWD/build/packages-2" \
scripts/package-release.sh

GPBAR_APP="$PWD/build/release-2/GPBar.app" \
GPBAR_UPDATE_DMG="$PWD/build/packages-2/GPBar-0.1.1.dmg" \
GPBAR_UPDATE_OUTPUT="$PWD/build/update-2" \
GPBAR_UPDATE_DOWNLOAD_URL='https://github.com/beeltec/gpbar/releases/download/v0.1.1/' \
scripts/prepare-update.sh
```

The update script validates signing, notarization, public-key agreement, HTTPS configuration, and increasing build numbers.
It copies the verified `GPBar-0.1.1.dmg` and an updated `appcast.xml` in a new output directory.
The DMG keeps its versioned filename. Sparkle still uses the internal build number to order updates.
It uses the pinned Sparkle tools from `build/app-derived` by default.
`GPBAR_SPARKLE_BIN` can select another resolved copy of the same pinned tools.
Existing feed entries are preserved by Sparkle, subject to its retention policy. Delta generation is disabled initially.

Upload the exact generated DMG and the signed PKG to the chosen public release directory.
Publish the generated feed at the embedded feed URL.
For local publishing, set `GPBAR_UPDATE_PREVIOUS_FEED` to the previous release’s downloaded appcast.
CI selects it automatically. Preserve published version history in each release asset.
Do not alter the signed DMG afterward. Verify both public URLs before announcing the release.
Publish no development-signed build to the production feed.

Before each release, verify an upgrade from the previous shipped build on a supported Mac.
Check signature rejection, cancellation, preferences, helper re-registration, and a real connection after relaunch.

Debug builds also accept an HTTP feed on `127.0.0.1` for manual local validation.
Release builds require HTTPS. Local validation archives and feeds stay under ignored `build/` paths.

## Validation limits

A local development-signed upgrade completed on macOS 26.6.2, with helper relaunch and preference preservation.
Invalid archive signatures and installation during authentication were rejected.
Public release publishing, Gatekeeper acceptance, and notarized upgrades on another Mac remain unverified.
Installer crashes, helper failures, and resumed installation still need live checks.
