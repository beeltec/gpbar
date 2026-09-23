# GPBar

A native macOS menu bar client for GlobalProtect VPNs, built with SwiftUI, OpenProtect, and OpenConnect.
Enter the portal address supplied by your organization, sign in, and manage your connection from the menu bar.
No company portal is built in.

**Development status:** GPBar is under active development.
A development build established a real SAML connection, and normal disconnect restored the observed routes and DNS settings.
Failure recovery, wider portal compatibility, and release validation remain incomplete.

## Requirements

- An Apple Silicon Mac running macOS 26 or newer. Intel Macs are not supported.
- Access to a GlobalProtect portal and the sign-in method required by your organization.
- Permission to approve GPBar's privileged VPN helper in macOS.

Live checks have used macOS 26.6.2. Compatibility with macOS 26.0 still needs live validation.
GPBar does not support every authentication policy available in the official GlobalProtect app.
Check the [authentication support matrix](AUTHENTICATION.md) before trying your portal.

## Features

- Connect, cancel sign-in, disconnect, and view connection details from the menu bar.
- Save one portal address and an optional connection name across launches.
- Sign in through an in-app browser, the default browser, or a selected browser.
- Continue connection setup automatically after the browser returns the authentication callback.
- Choose automatic authentication, SAML, Cloud Identity Engine, Kerberos SSO, username and password, or a Keychain client certificate.
- Receive protected-resource sign-in prompts through a connected IPv4 tunnel under the portal’s trusted-host policy.
- Recover recorded network changes and remove the VPN helper from connection settings.
- Debug builds include local diagnostics and export.
- Optionally launch GPBar at login. This opens the app without connecting the VPN.
- Optionally reuse your next macOS login password through a separately approved system plug-in.

SAML has live connection evidence. Password, certificate, smart-card, and saved-sign-in flows still need broader live validation.
Cloud Identity Engine OIDC has synthetic checks but no live provider evidence.
External browser callback handling and automatic tab closure also need further validation.

## Get started

Download a DMG or PKG from [Releases](https://github.com/beeltec/gpbar/releases).
Both contain the app and its runtime dependencies.
See [the changelog](CHANGELOG.md) for changes and release-specific limits.
Open the DMG and drag GPBar to Applications, or run the PKG installer.
Before reinstalling, disconnect, remove the helper in Edit Connection, and quit GPBar.

1. Place the built or downloaded `GPBar.app` in Applications and open it.
2. Follow the app's guidance to approve the VPN helper if macOS requests it.
3. Enter your organization's portal address, such as `vpn.example.com`. Valid addresses save automatically.
4. Leave authentication set to **Automatic**, or choose the method required by your organization.
5. Click **Connect** and complete sign-in. Browser callbacks continue connection setup automatically.
6. Use **Disconnect** in the menu bar panel when finished.

The in-app browser is the default for browser sign-in.
Change the browser under **Automatic**, **SAML**, or **Cloud Identity Engine** in **Edit Connection**.
That choice remains saved when you return to **Automatic**.

GPBar includes Sparkle update checks. Installation requires confirmation and a disconnected VPN.
Stable releases provide the update feed. See [automatic updates](UPDATES.md) for details.

### Remove GPBar

Disable macOS login SSO for every enrolled user first, if enabled. See [removal and recovery](LOGIN-SSO.md).
Disconnect and wait for network cleanup to finish.
Open **Edit Connection**, choose **Remove helper**, then quit GPBar and remove the app from Applications.
Launching GPBar again registers the helper again.

## Known limits

- GPBar stores one connection and runs one tunnel at a time.
- Kerberos SSO has local KDC and synthetic HTTPS checks, but no matching GlobalProtect provider validation.
- Optional [macOS login SSO](LOGIN-SSO.md) has synthetic checks. Real login capture and provider compatibility remain unverified.
- Crash recovery, sleep/wake, reconnect, and IPv6 behavior still need live validation.
- GPBar has no kill switch. Traffic routing depends on the gateway's configuration.
- Clean installation and notarized updates still need release validation.

See the [authentication matrix](AUTHENTICATION.md) for method-specific support and validation limits.

## Build from source

Development requires an Apple Silicon Mac, Xcode, Homebrew, Rust through rustup, and an Apple code-signing identity.
Local builds have used Xcode 27.0. The release workflow uses Xcode 26.6.
The repository pins Rust 1.95.0 and requires XcodeGen 2.46.0 or newer.

```sh
git clone https://github.com/beeltec/gpbar.git
cd gpbar

brew install lz4 json-c gnutls gettext gmp nettle p11-kit stoken pkgconf xcodegen
rustup toolchain install 1.95.0 --profile minimal --target aarch64-apple-darwin

GPBAR_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' \
GPBAR_TEAM=TEAMID \
GPBAR_OUTPUT="$PWD/build/local/GPBar.app" \
scripts/build-app.sh
```

Replace the signing identity and team with values from your local signing setup.
The output must be a new absolute path ending in `.app`; the script refuses to overwrite an existing app.
The script builds patched OpenConnect and the Rust engine, generates the Xcode project, bundles dependencies, and signs the app.
Development signing does not produce a notarized distribution build.

See [release publishing](RELEASE.md) for dependency pins, signing, and notarization.
Use [local distribution builds](RELEASE.md#build-and-validate-locally) to test a signed, notarized app before publishing.
Release builds enforce the exact native dependency versions in [runtime-inputs.json](Packaging/runtime-inputs.json).

## How it works

The SwiftUI app runs as the logged-in user.
It talks over authenticated XPC to a privileged helper, which manages a bundled OpenProtect engine through private pipes.
OpenProtect handles GlobalProtect authentication, and OpenConnect provides the tunnel.
The helper manages privileged operations and network cleanup.

## Contributing and reporting problems

Use [GitHub Issues](https://github.com/beeltec/gpbar/issues) for bug reports and feature requests.
Include your macOS version, GPBar build, authentication method, browser choice, and steps to reproduce the problem.
Debug builds can export diagnostics. Review them before sharing. Remove credentials, callback URLs, account details, and private network information.

Keep changes focused and follow the existing code style. Use Conventional Commits for commit messages.
The project uses live macOS and browser validation, alongside builds and static checks.
Do not add automated tests or test targets unless explicitly requested. Preserve existing upstream tests.
Issue #21 includes an explicitly requested [resource MFA suite](Tests/ResourceMFA/README.md), since no matching live server is available.
Issue #20 includes an explicitly requested [CIE suite](Tests/CloudIdentity/README.md) for the same reason.
Issue #19 includes an explicitly requested [macOS login SSO suite](Tests/LoginSSO/README.md).
Issue #18 includes an explicitly requested [Kerberos SSO suite](Tests/Kerberos/README.md).
Issue #14 adds [shared authentication checks and a full-suite command](Tests/Authentication/README.md).
Run `scripts/test-authentication.sh` after building the native dependencies.
These synthetic checks do not establish real provider or smart-card compatibility.
Record what you checked and any remaining limits in your pull request.

## Third-party software and licensing

GPBar builds on OpenProtect, OpenConnect, vpnc-script, and Sparkle.
See [third-party notices](THIRD-PARTY-NOTICES.md) and [bundled license texts](Packaging/Licenses) for dependency licensing.
Sparkle's license is included in [Sparkle.txt](Packaging/Licenses/Sparkle.txt).

GPBar's original code is licensed under the [MIT License](LICENSE).
Third-party components and changes derived from them remain subject to their respective licenses.
