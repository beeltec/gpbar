# Authentication support

Research date: 2026-09-20. Scope: GPBar on macOS.

The credential changes require app, helper, and engine protocol version 2.
Update all three components together. Older components reject the version mismatch.
For development builds in different folders, disconnect and remove the old helper through the old app before launching the new build.
An old registered helper cannot process version 2 requests.

GPBar does not have full authentication parity with the official GlobalProtect app.
The available live provider uses SAML. Other methods below have no live compatibility evidence.

## Method comparison

| Method | GPBar implementation | Validation or remaining work |
| --- | --- | --- |
| Browser SAML and browser MFA | Existing embedded, default-browser, and selected-browser flow. | Previous SAML connection evidence exists. Provider policy can still reject embedded browsers. |
| Local accounts | Native username and password challenge. | New implementation; no live provider available. |
| LDAP, RADIUS, TACACS+, and password-based Kerberos server authentication | Standard GlobalProtect username and password exchange. The firewall contacts its configured authentication service. | New implementation; no live provider available. This does not implement Kerberos SSO. |
| Token or OTP as the initial password | Server-provided password label and masked credential field. | New implementation; no live provider available. |
| Portal and gateway MFA challenges | Bounded challenge exchange using `inputStr` and one `passwd` value. Supports XML and existing HTML challenge responses. | New portal support; corrected gateway submission. Push-only and provider-specific exchanges remain unverified. |
| Different portal and gateway authentication | Separate gateway prelogin and sign-in when portal cookies are absent or rejected. | New implementation; no live provider available. Passwords are not silently forwarded to another host. |
| Client certificates, including certificates combined with passwords or SAML | Not available in the native app. | Requires identity selection and signing across the user app, HTTP authentication, and tunnel boundaries. |
| Smart cards and CACs | Not available. | Requires non-exportable key operations, PIN handling, and supported middleware. File-based PEM support is not equivalent. |
| Kerberos SSO | Not available. | Requires user-session ticket access and the GlobalProtect Kerberos exchange. Root cannot assume the user's credentials. |
| OS-login SSO | Not available. | GPBar does not capture macOS login passwords or cache VPN passwords. |
| Cloud Identity Engine OIDC | Not established. | Existing Prisma callback parsing does not prove the OIDC discovery and token exchange are compatible. |
| MFA notifications for protected non-browser resources | Not available. | This is a separate post-connection notification and authentication protocol. |
| Authentication cookie persistence | Session memory only. | Persistent cookie storage and policy handling are not implemented. |
| Pre-logon and Windows Connect Before Logon | Outside this macOS on-demand client scope. | These are connection modes, not additional password form variants. |

The official client supports local, external, certificate, and multi-factor authentication.
Its portal and gateway can require different methods.
[Official authentication overview](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-user-authentication)

LDAP and similar services are configured on the firewall.
The client sends the GlobalProtect credentials rather than connecting directly to an LDAP server.
[Authentication-profile setup](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-quick-configs/remote-access-vpn-authentication-profile)

## Implementation details

Connect starts portal prelogin and shows the method requested by the server.
The native credential form displays the target hostname and server-provided field labels.
Credentials remain in session memory and travel through authenticated XPC and private inherited pipes.
Passwords are cleared from the UI after submission, cancellation, or challenge replacement.
They are not saved in preferences, logs, process arguments, or diagnostic exports.

Each challenge has an independent identifier and a five-minute response timeout.
The helper checks challenge ownership and type before accepting a response.
The engine bounds usernames to 1,024 bytes and passwords to 4,096 bytes.
Challenge replies are limited to 1,024 bytes. Authentication accepts at most three follow-up challenges per endpoint.
Cancellation and expired-session authentication use the same session control path.

Portal replies must contain a usable gateway list before authentication is treated as successful.
MFA replaces the password value and retains the challenge state.
It does not append another conflicting password field.
The implementation follows the established OpenConnect exchange.
[OpenConnect authentication source](https://gitlab.com/openconnect/openconnect/-/blob/master/auth-globalprotect.c)

## Remaining integration requirements

The official macOS app uses client certificates from Keychain.
GPBar's current HTTP backend accepts file-based PEM identities, while its app mode supplies no certificate identity.
Adding a certificate picker alone would leave authentication and tunnel setup incomplete.
[macOS certificate guide](https://docs.paloaltonetworks.com/globalprotect/user-guide/6-3/globalprotect-app-for-mac/enable-the-globalprotect-app-to-use-the-valid-client-certificate)

Smart-card support must preserve non-exportable keys.
OpenConnect provides PKCS#11 integration, but GPBar's private runtime currently disables automatic PKCS#11 module discovery.
A bounded, trusted middleware and signing interface is required before enabling it.
[OpenConnect PKCS#11 guide](https://www.infradead.org/openconnect/pkcs11.html)

Kerberos server password authentication and Kerberos SSO are separate capabilities.
The latter uses tickets from the user's login session and needs a dedicated implementation.
[Official Kerberos setup](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-user-authentication/set-up-external-authentication/set-up-kerberos-authentication)

Cloud Identity Engine documents SAML, certificates, and OIDC.
Its configuration guide does not provide a complete third-party wire protocol for OIDC.
Protocol evidence is required before claiming that an existing SAML callback also implements OIDC.
[Cloud Identity Engine guide](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-user-authentication/embedded-web-view-with-cie-for-force-authentication)

These gaps remain open. The password and challenge implementation does not close full authentication parity.

## Validation record

The final development build passed Swift/Rust builds, Clippy, and strict signature verification on macOS 26.6.2.
Parallel protocol and security reviews reported no remaining concrete findings after corrections.
Live SAML startup reached the identity provider in the embedded browser. Cancellation closed the window and restored Connect.
The native credential form and new MFA exchanges were not exercised against a live provider.
Full SAML callback completion and tunnel establishment were not repeated for this change.
No automated tests or test harnesses were added or run.
