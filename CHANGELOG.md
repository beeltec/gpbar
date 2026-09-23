# Changelog

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

[0.2.0]: https://github.com/beeltec/gpbar/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/beeltec/gpbar/releases/tag/v0.1.0
