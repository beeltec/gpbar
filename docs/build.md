# Building GPClient

Supported build host: Apple Silicon, macOS 26 or newer.
Current build environment: Xcode 27.0, Swift 6.4, Rust 1.95.0, and XcodeGen 2.46.0.
Swift language mode is 6. The deployment target is macOS 26.0.

Install the development tools and native build dependencies before building.
Homebrew is used only during development, not by the installed application.
The initial native package inventory is in `runtime-inputs.json`.
The packaged runtime manifest records every copied Mach-O image and its hashes.

```sh
export GPCLIENT_SIGN_IDENTITY='Apple Development: Your Name (CERTIFICATE_ID)'
export GPCLIENT_TEAM='YOURTEAMID'
export GPCLIENT_OUTPUT="$PWD/build/development/GPClient.app"
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

## Release

Use a Developer ID Application identity for release signing.
After live validation, use `scripts/notarize-app.sh` with an existing notarytool keychain profile.
The release script requires Developer ID, submits a ZIP, staples the accepted ticket, and checks Gatekeeper.
It does not accept signing passwords or Apple account credentials as arguments.
Then use `scripts/package-dmg.sh` to create, sign, notarize, and staple the installation disk image.
Set `GPCLIENT_RELEASE_DMG` to a new absolute path and reuse the signing identity and notary profile.

Developer ID signing and notarization credentials were not available during initial implementation.
Notarization, clean-machine installation, and oldest-supported-version checks remain release gates.
Keep corresponding source and dependency notices with the release materials.

## Static checks

```sh
cd Vendor/openprotect
GPCLIENT_REQUIRE_OPENCONNECT=1 cargo check --locked --workspace --lib --bins
GPCLIENT_REQUIRE_OPENCONNECT=1 cargo clippy --locked --workspace --lib --bins
```

Set `PKG_CONFIG_PATH` to the project's `build/native/lib/pkgconfig` directory for the patched library.
Builds and static checks do not replace the live scenarios in `manual-validation.md`.
No new automated tests are part of this project workflow.
