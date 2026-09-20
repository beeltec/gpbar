# Building GPBar

Supported build host: Apple Silicon, macOS 26 or newer.
Current build environment: Xcode 27.0, Swift 6.4, Rust 1.95.0, and XcodeGen 2.46.0.
Swift language mode is 6. The deployment target is macOS 26.0.

Install the development tools and native build dependencies before building.
Homebrew is used only during development, not by the installed application.
The initial native package inventory is in `runtime-inputs.json`.
The packaged runtime manifest records every copied Mach-O image and its hashes.

```sh
export GPBAR_SIGN_IDENTITY='Apple Development: Your Name (CERTIFICATE_ID)'
export GPBAR_TEAM='YOURTEAMID'
export GPBAR_OUTPUT="$PWD/build/development/GPBar.app"
scripts/build-app.sh
```

Choose a new output directory for each build. Existing output is never overwritten.
Use one signing team for the app, helper, engine, and libraries.
Development signing enables local verification; it does not produce a notarized distribution.

The build downloads OpenConnect 9.21 from its official source and verifies its SHA-256 checksum.
It applies the tracked private-HIP and reconnect patch, then builds the engine with real OpenConnect bindings.
The engine refuses a stock OpenConnect library in application mode.
XcodeGen generates the project from `project.yml`.
Packaging copies the runtime dependency closure, rewrites load paths, checks arm64 and macOS minimums, and signs nested code first.
The final bundle passes deep, strict signature verification before delivery.

The application cannot be distributed from the raw Xcode build directory.
Use `build-app.sh` so the engine, route worker, libraries, notices, and runtime manifest are included.

## Product identity

The application identifier is `com.beeltec.GPBar`.
The helper uses `com.beeltec.GPBar.helper`; the engine uses `com.beeltec.GPBar.engine`.
Application settings use the `com.beeltec.GPBar` preferences domain.

This development rename intentionally changes the bundle identity.
Before replacing an earlier development build, disconnect, remove its helper in Diagnostics, and turn off its launch-at-login setting.
Quit that build before opening GPBar. Keep unresolved recovery journals until the earlier helper completes cleanup.
GPBar requires its own helper registration and any macOS approval.
Enable launch at login again if needed. Choose callback ownership explicitly when using a specific browser.

For a local development upgrade, export the previous preferences domain with `defaults export` before removal.
Import that file into `com.beeltec.GPBar` with `defaults import` before first launch, or enter the settings again.
Keep this file outside the repository because it contains the saved portal address.
Future GPBar updates retain the new identifiers and existing preference keys.

## Release

Use a Developer ID Application identity for release signing.
After live validation, use `scripts/notarize-app.sh` with an existing notarytool keychain profile.
The release script requires Developer ID, submits a ZIP, staples the accepted ticket, and checks Gatekeeper.
It does not accept signing passwords or Apple account credentials as arguments.
Then use `scripts/package-dmg.sh` to create, sign, notarize, and staple the installation disk image.
Set `GPBAR_RELEASE_DMG` to a new absolute path and reuse the signing identity and notary profile.

Developer ID signing and notarization credentials were not available during initial implementation.
Notarization, clean-machine installation, and oldest-supported-version checks remain release gates.
Keep corresponding source and dependency notices with the release materials.

## Static checks

```sh
cd Vendor/openprotect
GPBAR_REQUIRE_OPENCONNECT=1 cargo check --locked --workspace --lib --bins
GPBAR_REQUIRE_OPENCONNECT=1 cargo clippy --locked --workspace --lib --bins
```

Set `PKG_CONFIG_PATH` to the project's `build/native/lib/pkgconfig` directory for the patched library.
Builds and static checks do not replace the live scenarios in `manual-validation.md`.
No new automated tests are part of this project workflow.
