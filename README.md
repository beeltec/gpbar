# GPBar

A native macOS menu bar client for GlobalProtect VPNs.
Enter your organization's portal address, sign in, and manage the connection from the menu bar.
GPBar is built with SwiftUI, [OpenProtect](https://github.com/kyaky/openprotect), and [OpenConnect](https://www.infradead.org/openconnect/).
No company portal is built in.

> [!WARNING]
> GPBar is under active development. SAML connections work in live use.
> Other sign-in methods, failure recovery, and wider portal support still need validation.
> See [Known limits](#known-limits).

## Features

- Connect, disconnect, and view connection details from the menu bar.
- Save multiple named connection profiles.
- Sign in with SAML, Cloud Identity Engine, Kerberos SSO, username and password, or a Keychain client certificate.
- Use the in-app browser, your default browser, or a specific browser for sign-in.
- Send only selected domains to VPN DNS with [split DNS](DNS.md).
- Reconnect interrupted sessions automatically.
- Restore network settings with **Recover network** in Settings.
- Optional launch at login, and optional [macOS login SSO](LOGIN-SSO.md).
- Signed [automatic updates](UPDATES.md) through Sparkle.

## Requirements

- An Apple Silicon Mac with macOS 26 or newer. Intel Macs are not supported.
- A GlobalProtect portal and a [supported sign-in method](AUTHENTICATION.md).
- Permission to approve GPBar's privileged VPN helper.

## Installation

Download the DMG or PKG from [Releases](https://github.com/beeltec/gpbar/releases).
Drag GPBar to Applications, or run the PKG installer.
See the [changelog](CHANGELOG.md) for changes in each release.

## Usage

1. Open GPBar and approve the VPN helper if macOS asks.
2. Enter your portal address, such as `vpn.example.com`. GPBar saves valid addresses automatically.
3. Keep authentication set to **Automatic**, or choose the method your organization uses.
4. Click **Connect** and sign in. GPBar continues after the browser returns.
5. Click **Disconnect** when you are done.

Open **Connections…** to add or edit profiles. Open **Settings…** for launch at login, updates, and helper tools.

### Remove GPBar

1. Disable [macOS login SSO](LOGIN-SSO.md#installation-removal-and-updates) if you enabled it.
2. Disconnect and wait for network cleanup to finish.
3. Open **Settings**, choose **Remove helper**, and quit GPBar.
4. Delete GPBar from Applications.

## Troubleshooting

### If the VPN helper cannot be reached

1. Check that GPBar is allowed in **System Settings → General → Login Items & Extensions**.
2. Choose **Check again** in GPBar Settings.
3. If the app and helper versions differ, quit GPBar and open the copy in Applications.
4. If the error stays, open **Preview diagnostic report…** in Settings and attach it to a bug report.

The report does not contain credentials, sign-in URLs, account names, or private network details.
You can still quit GPBar when the helper fails. Reopen GPBar and use **Recover network** if needed.

## Known limits

- One tunnel at a time. Disconnect before you switch profiles.
- No kill switch. Traffic routing depends on the gateway configuration.
- Password, certificate, smart-card, Cloud Identity Engine, and Kerberos sign-in need more live validation.
- macOS login SSO has only synthetic checks.
- Crash recovery, sleep and wake, long reconnects, and IPv6 need live validation.

See the [authentication support matrix](AUTHENTICATION.md) for details per method.

## Build from source

You need an Apple Silicon Mac, Xcode, Homebrew, rustup, and an Apple code-signing identity.

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

`GPBAR_OUTPUT` must be a new absolute path that ends in `.app`.
Development builds are not notarized. See [tagged releases](RELEASE.md) for distribution builds.

## How it works

The SwiftUI app runs as the logged-in user.
It talks over authenticated XPC to a privileged helper.
The helper runs the bundled OpenProtect engine, which handles GlobalProtect sign-in.
OpenConnect provides the tunnel. The helper also restores network settings on disconnect.

## Documentation

| Topic | Guide |
| --- | --- |
| Sign-in methods and browsers | [Authentication support](AUTHENTICATION.md) |
| Split DNS | [Split DNS](DNS.md) |
| macOS login SSO | [macOS login SSO](LOGIN-SSO.md) |
| Updates | [Automatic updates](UPDATES.md) |
| Releases and signing | [Tagged releases](RELEASE.md) |
| Dependencies and licenses | [Third-party notices](THIRD-PARTY-NOTICES.md) |

## Contributing

Report bugs and request features in [GitHub Issues](https://github.com/beeltec/gpbar/issues).
Include your macOS version, GPBar version, sign-in method, browser, and steps to reproduce.
Review diagnostic reports before you share them.

Keep changes focused, follow the existing code style, and use [Conventional Commits](https://www.conventionalcommits.org/).
The project validates behavior live on macOS and in real browsers. Do not add new automated tests.
Describe what you checked and any open limits in your pull request.

## License

GPBar's own code uses the [MIT License](LICENSE).
Third-party components keep their own licenses. See [third-party notices](THIRD-PARTY-NOTICES.md) and [bundled license texts](Packaging/Licenses).
