# Changelog

## Unreleased

## [0.3.0] - 2026-09-25

### Added

- Save multiple named connection profiles, with separate authentication choices, browser preferences, and saved sign-ins.
- Manage profiles in Connections and select a profile from the menu bar before connecting.
- Use separate general Settings for launch at login, updates, helper management, and network recovery.
- Save split DNS domains per connection profile, with native macOS resolver selection and session-owned cleanup.

### Fixed

- Allow quitting when the VPN helper cannot be reached, including when no session ID is known.
- Bound disconnect-on-quit to 20 seconds and avoid quit confirmations during macOS logout, restart, and shutdown.
- Retry failed helper checks with a fresh authenticated connection and show guidance for signing and protocol failures.
- Require completed helper preparation at Sparkle's final install and relaunch check.

### Upgrade notes and limits

Existing connection settings and saved sign-in migrate to the first profile. GPBar still runs one tunnel at a time.
Split DNS is disabled by default. It controls DNS selection, while traffic routes still follow the gateway configuration.
Update the app, helper, and bundled engine together. Protocol version 11 requires matching components.
Disable macOS login SSO for every enrolled user before updating or removing the helper, if enabled.
Before reinstalling, disconnect, remove the helper in Settings, and quit GPBar.

Profile management, helper failure handling, and split DNS were checked live on macOS 26.6.2.
A real SAML connection resolved matching and unrelated public names. Disconnect restored the observed DNS state.
Cross-server profiles, internal-only split DNS names, IPv6, forced recovery, and split DNS during tunnel renewal remain unverified.
Actual macOS restart, stuck-helper timeout, and interrupted Sparkle installation still need live checks.
The [existing authentication limits](AUTHENTICATION.md) and [split DNS limits](DNS.md) still apply.

## [0.2.2] - 2026-09-24

### Fixed

- Show GPBar in the Dock and app switcher while windows are open, including minimized windows.
- Return to menu-bar mode after the last window closes, and restore existing windows when reopening GPBar.
- Preserve the gateway session during tunnel renewal instead of sending logout before reconnecting.
- Report sign-in timeouts with instructions to connect again, including during recovery.
- Reset tunnel recovery limits after a verified connection lasts one minute, so scheduled renewals cannot exhaust a lifetime retry budget.
- Show specific tunnel interruption codes, session rejection, and gateway termination instead of a generic setup error.
- Allow authentication failures during recovery to replace an earlier tunnel error.

### Upgrade notes and limits

Disable macOS login SSO for every enrolled user before updating or removing the helper, if enabled.
Before reinstalling, disconnect, remove the helper in Edit Connection, and quit GPBar.

Window handling and accelerated tunnel renewals were checked live on macOS 26.6.2.
Two accelerated renewals recovered without another sign-in request. Disconnect restored the observed DNS configuration.
Full-duration renewal, sleep/wake, and genuine gateway expiry still need live validation.
The [existing authentication limits](AUTHENTICATION.md) still apply.

## [0.2.1] - 2026-09-23

### Fixed

- Bring in-app sign-in windows and provider popups to the front, and close the menu bar panel when showing or reopening sign-in.
- Restore minimized sign-in windows and bring the latest open provider popup forward when choosing **Open sign-in window**.

### Upgrade notes and limits

Disable macOS login SSO for every enrolled user before updating or removing the helper, if enabled.
Before reinstalling, disconnect, remove the helper in Edit Connection, and quit GPBar.

Window focus, reopening, popup handling, and cancellation were checked live on macOS 26.6.2.
These checks did not complete SAML authentication. The [existing authentication limits](AUTHENTICATION.md) still apply.

## [0.2.0] - 2026-09-23

### Added

- Kerberos SSO using existing tickets from the logged-in user's session, with separate portal and gateway authentication.
- Optional macOS login SSO, with administrator approval and one-use portal credentials held briefly in helper memory.
- Cloud Identity Engine authentication through its browser handoff, including OIDC-backed sign-in.
- Protected-resource MFA notifications, with trusted-host checks and separate browser sign-in windows.
- Shared authentication validation covering Keychain signing, saved cookies, certificate authentication, credential prompts, and method-specific checks.
- A local distribution build command that signs, notarizes, and verifies the app, DMG, and PKG before publication.

### Fixed

- Dismiss the menu bar panel when opening separate windows.
- Use release versions in DMG and PKG filenames, including prerelease suffixes.

### Security and lifecycle

- Bind Kerberos exchanges and login credentials to their user, session, and destination.
- Require authenticated portal policy before Automatic mode can fall back after a Kerberos failure.
- Block helper removal and updates while macOS login SSO remains enabled.
- Keep resource MFA prompts separate from VPN connection state and reject notifications outside the supported trust policy.

### Upgrade notes and limits

Update the app, helper, and bundled engine together. Their protocol versions must match.
Disconnect, remove the old helper in Edit Connection, and quit GPBar before reinstalling.
Disable macOS login SSO for every enrolled user before future updates or helper removal.

The new authentication methods have synthetic validation but still need matching live providers.
Real macOS login capture, smart-card hardware, and complete VPN connections remain unverified for these methods.
See [authentication support](AUTHENTICATION.md) and [macOS login SSO](LOGIN-SSO.md) for specific limits.

## [0.1.0] - 2026-09-21

- Initial Apple Silicon release for macOS 26 or newer, with a menu bar interface and one saved connection.
- Embedded and external browser sign-in, automatic authentication selection, passwords, MFA, Keychain certificates, and smart-card integration.
- Optional policy-controlled sign-in cookies stored in Keychain.
- Privileged VPN helper, bundled OpenProtect and OpenConnect runtime, and recorded network recovery.
- Signed automatic updates through Sparkle, with confirmation and helper shutdown before installation.
- Notarized DMG and PKG installers, version information, and bundled dependency licenses.

Provider and hardware support was incomplete. A development build had live SAML connection and normal disconnect evidence.

[0.3.0]: https://github.com/beeltec/gpbar/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/beeltec/gpbar/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/beeltec/gpbar/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/beeltec/gpbar/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/beeltec/gpbar/releases/tag/v0.1.0
