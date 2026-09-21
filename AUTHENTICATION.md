# Authentication support

Research date: 2026-09-20. Scope: GPBar on macOS.

The saved sign-in changes require app, helper, and engine protocol version 5.
Update all three components together. Older components reject the version mismatch.
For development builds in different folders, disconnect and remove the old helper through the old app before launching the new build.
An old registered helper cannot process version 5 requests.

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
| Client certificates, including certificates combined with passwords or SAML | Selected Keychain identity, with signing delegated to the user app for OpenProtect and OpenConnect TLS. | Certificate picker and unchanged SAML startup/cancellation checked live. No certificate-enabled provider is available. |
| Smart cards and CACs | Uses identities exposed through macOS CryptoTokenKit and the existing delegated certificate signer. | Builds and parallel reviews passed. Picker and SAML startup/cancellation checked live. Hardware and certificate-provider behavior remain unverified. |
| Kerberos SSO | Not available. | Requires user-session ticket access and the GlobalProtect Kerberos exchange. Root cannot assume the user's credentials. |
| OS-login SSO | Not available. | GPBar does not capture macOS login passwords or cache VPN passwords. |
| Cloud Identity Engine OIDC | Not established. | Existing Prisma callback parsing does not prove the OIDC discovery and token exchange are compatible. |
| MFA notifications for protected non-browser resources | Not available. | This is a separate post-connection notification and authentication protocol. |
| Authentication cookie persistence | Opt-in user Keychain storage, with portal policy checks and origin-bound reuse through OpenProtect. | Builds and branch-wide reviews passed. Startup and helper refresh checked live. Cookie persistence and reuse remain unverified against a live provider. |
| Pre-logon and Windows Connect Before Logon | Outside this macOS on-demand client scope. | These are connection modes, not additional password form variants. |

The official client supports local, external, certificate, and multi-factor authentication.
Its portal and gateway can require different methods.
[Official authentication overview](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-user-authentication)

LDAP and similar services are configured on the firewall.
The client sends the GlobalProtect credentials rather than connecting directly to an LDAP server.
[Authentication-profile setup](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-quick-configs/remote-access-vpn-authentication-profile)

## Implementation details

### Library reuse audit

Prefer existing OpenProtect and OpenConnect functionality before adding authentication code.
This rule also applies to features already implemented in GPBar.
Inspect the pinned source, not only upstream feature lists, before replacing a working path.

| Existing feature | Reused implementation | GPBar-specific code that remains |
| --- | --- | --- |
| Password login | OpenProtect credential serialization, prelogin parser, and HTTP client. | Native credential entry and private IPC replace terminal prompts. |
| SAML | OpenProtect launch-page generation and callback parsing. | Native browser ownership, callback transport, cancellation, and response limits. |
| Portal configuration | One OpenProtect HTTP request path shared by CLI and app mode. | App mode also recognizes challenges and rejects replies without usable gateways. |
| MFA | OpenProtect challenge representation and gateway request code. | Native prompts, portal challenge handling, bounded retries, and session ownership. |
| Gateway selection | OpenProtect's existing selection function. | Origin validation before using returned gateways. |
| HIP and tunnel | OpenProtect reporting and OpenConnect's HIP submission and tunnel APIs. | Observed macOS facts, private HIP inputs, and network recovery. |

The password provider in the pinned OpenProtect source combines credential construction with optional terminal prompts.
The app already uses the same credential type and request methods without invoking those prompts.
Adding a provider call merely to construct that value would add secret copies without removing protocol code.

OpenConnect also provides `openconnect_obtain_cookie` and an authentication-form callback.
Its GlobalProtect login implementation covers portal and gateway exchanges, including challenges.
However, version 9.21 can replay the portal password after redirecting to a gateway.
GPBar requires separate entry before sending that password to another host.
A replacement must preserve this rule, browser callbacks, gateway selection, cancellation, and response limits.
The callback API is a reuse candidate, not a drop-in replacement for the current application flow.
[OpenConnect GlobalProtect source](https://gitlab.com/openconnect/openconnect/-/blob/v9.21/auth-globalprotect.c)

For certificates, OpenConnect already accepts PEM files, PKCS#12 files, and supported PKCS#11 URLs.
OpenProtect's pinned HTTP client accepts PEM identities but explicitly rejects PKCS#12 with its rustls backend.
Neither fact establishes native macOS Keychain support across the whole connection.
Any Keychain bridge must keep private keys in the user's session and reuse the TLS libraries' signing interfaces.
[OpenConnect certificate guide](https://www.infradead.org/openconnect/connecting.html)

Kerberos, OIDC, cookie policy, and resource MFA require separate checks of their actual GlobalProtect exchanges.
A general library feature does not prove support for that feature under every VPN protocol.
The remaining work is tracked in [the authentication tickets](https://github.com/beeltec/gpbar/issues/14).

### Native application flow

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

### Saved sign-in

Remember sign-in when allowed is off by default. It does not store passwords or browser cookies.
OpenProtect still sends the authentication requests. Existing credential serialization carries the saved authentication-override cookie.
The gateway parser reads the optional user-authentication cookie from JNLP argument 16, matching OpenConnect's existing field mapping.
The separate tunnel `authcookie` is never persisted.
[OpenConnect field mapping](https://gitlab.com/openconnect/openconnect/-/blob/v9.21/auth-globalprotect.c)

Storage requires explicit portal permission to save credentials, accept cookies, and generate cookies, plus a recognized cookie lifetime.
Missing, duplicate, unsupported, and invalid policy values disable persistence.
The current parser recognizes minute, hour, and day lifetime fields. Unsupported policy forms use fresh authentication.
The portal lifetime limits local retention. Each server separately enforces its own cookie lifetime and source-IP restrictions.
A cached cookie never establishes authentication by itself; the server must accept it.
Rejected cookies are removed before fresh sign-in. Challenge responses still use the existing native authentication flow.
[Official cookie behavior](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-user-authentication/how-does-the-app-know-what-credentials-to-supply),
[Captured portal policy](https://gitlab.com/openconnect/openconnect/-/issues/387)

Records bind the portal, account, endpoint origin, and engine computer identifier.
Gateway cookies are sent only to their recorded gateway after the portal returns that gateway again.
Cookies with retained timestamps do not receive a later local expiry during reuse, MFA, or fallback.
A shorter returned retention policy also shortens their local expiry.
Cookie expiry is checked again before each portal or gateway authentication request, including requests after MFA waits.
Expiry during authentication clears the cache and allows one fresh authentication attempt.
After an expired record is removed, fresh authentication can create a new local record. Server-side cookie expiry remains authoritative.
macOS Keychain encrypts the stored record. GPBar uses a private service name and its signed application's access control.
Replacement deletes the previous item and creates a new item with private access. A conflicting insertion fails without writing new secrets.
The current distribution uses the user's non-synchronizing, file-based Keychain without adding restricted provisioning entitlements.
A local hash of the Mac's host UUID rejects records moved to another Mac. This value is never sent to the VPN or diagnostics.
Keychain access runs on a serial queue and does not request interactive unlock during connection setup.
Cookie operations temporarily disable legacy Keychain interaction and restore its previous setting before returning.
Certificate operations use the same queue, so this process-wide setting cannot suppress an overlapping GPBar signing prompt.
Unavailable storage falls back to fresh sign-in and displays a storage message.
The helper tracks unconfirmed Keychain updates by user, portal, and revision. It retains no cookie in this tracking state.
The app acknowledges successful storage updates. After XPC reconnection, it removes unconfirmed records before allowing their reuse.
Tracking survives session completion while the helper remains running. It is not persisted across helper restarts.
Legacy Keychain access-control and interaction APIs produce SDK deprecation warnings. The data-protection alternative needs separately provisioned entitlements.
[Apple Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)

Forget saved sign-in removes GPBar's cookie record for the configured portal. It does not sign out external browser accounts.
Turning off Remember sign-in or changing the portal also requests removal. Removal failures remain visible so the user can retry.
Disconnect does not mean sign out. It preserves allowed cookies for a later user-started connection.
Expired records are not used, and fully expired records are removed when accessed.
The official client likewise distinguishes disconnecting from clearing authentication cookies through sign-out.
[Official sign-out behavior](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA14u0000004M5MCAU)

## Remaining integration requirements

The official macOS app uses client certificates from Keychain.
GPBar supplies the selected public chain and delegates private-key operations to Apple's Security framework in the user app.
OpenProtect uses rustls's client-certificate signer. OpenConnect uses GnuTLS's custom-key URL interface through its existing certificate API.
HIP submission remains on OpenConnect's authenticated TLS session.
No private key is exported or passed to the root helper.
[macOS certificate guide](https://docs.paloaltonetworks.com/globalprotect/user-guide/6-3/globalprotect-app-for-mac/enable-the-globalprotect-app-to-use-the-valid-client-certificate)

Select an identity under Client certificate in Edit Connection. The selection is bound to the saved portal and cleared when that address changes.
Keychain filters identities using Apple's TLS client policy. Code-signing-only certificates are not offered.
Certificate-only login sends an empty password and uses the server's certificate username, or the optional configured username.
Server-required SAML and MFA still run. Combined certificate and password login keeps the standard credential prompt.
RSA keys from 2,048 to 8,192 bits and P-256, P-384, and P-521 EC keys are supported.
Signing is limited to supported SHA-256, SHA-384, and SHA-512 TLS schemes. SHA-1 and raw RSA operations are rejected.
Each signing request has a session-bound identifier and a 120-second deadline. Inputs and signatures have separate size limits.
Certificate-enabled HTTP connections allow 130 seconds for connection setup and 150 seconds per request, including Keychain approval.
Disconnect invalidates the native authentication context and cancels engine-side signing waits.
Removing the selection does not delete the Keychain identity.

The native adapter reuses Apple's key operations instead of adding another PKCS#11 provider and user-side token service.
Existing PKCS#11 providers remain candidates for the separate smart-card ticket.
[Apple signature API](https://developer.apple.com/documentation/security/seckeycreatesignature(_:_:_:_:)),
[GnuTLS abstract-key API](https://www.gnutls.org/manual/html_node/Abstract-key-API.html)

The bundled OpenConnect patch uses GnuTLS's existing certificate-chain URL importer for this adapter.
GnuTLS also decodes PKCS#1 DigestInfo before the adapter requests a supported hash signature. The adapter does not implement ASN.1 parsing.
[GnuTLS chain import](https://gnutls.org/reference/gnutls-x509.html#gnutls-x509-crt-list-import-url),
[GnuTLS DigestInfo decoding](https://gnutls.org/reference/gnutls-crypto.html#gnutls-decode-ber-digest-info)

Smart cards use the same OpenProtect and OpenConnect certificate path as Keychain identities.
macOS exposes supported token identities through Keychain Services and performs the private-key operations on the token.
GPBar does not implement card commands, collect PINs, or export keys.
Native PIN cancellation or signing failure stops the attempt, without an automatic GPBar PIN retry.
Removing the selected token stops its active connection and invalidates pending signing approval.
Insert the token, open the certificate picker, and choose Refresh before selecting its client-authentication identity.
The picker distinguishes token identities from software Keychain identities, including duplicate public certificates.
The selected token must be present before Connect. Reinsertion never starts a connection automatically.
Persistent references are resolved again for every signing operation; missing identities fail safely.
Saved selections from earlier builds have their token metadata resolved before use. Unavailable selections require reinsertion or reselection.
Token metadata uses attributes-only Keychain queries. Algorithm inspection uses certificate public keys, not private-key attribute copying.
[Apple token integration](https://developer.apple.com/documentation/cryptotokenkit/using-cryptographic-assets-stored-on-a-smart-card)

Support depends on macOS exposing the card through its built-in driver or an installed CryptoTokenKit driver.
This does not establish support for every CAC applet or proprietary reader.
OpenConnect also provides PKCS#11 integration, but GPBar does not load external PKCS#11 modules into its root engine.
Using the existing native adapter preserves user-session PIN handling across both TLS libraries without adding another token service.
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

The library-reuse cleanup also passed the signed build, Clippy, signature verification, and parallel protocol and security reviews.
Its live check reached the SAML provider and returned to idle after cancellation.
That check did not exercise the consolidated portal request, which runs after successful sign-in.

The cookie development build completed the available provider's embedded SAML flow on macOS 26.6.2.
Tunnel setup then failed with `tunnel_openconnect_setup_tun_device_-5`; the app later returned to an idle failed state.
The saved-sign-in status reported removal. Cookie persistence, reuse, expiry, and policy changes remain unverified against a live provider.
The protocol 5 reconciliation build passed Clippy, signed packaging, and strict signature verification.
Live startup preserved settings and verified the matching helper. Ordinary refresh succeeded without starting a VPN session.
Cookie-update acknowledgement remains unverified live. A later shortened-policy expiry correction is not included in that live build.
The corrected `cookies-v8` package passed the signed build and strict signature verification.
Both branch-wide review axes reported no concrete defects after that correction.

## Authentication selection and detection

Automatic detection reuses the pinned OpenProtect `PreloginResponse::parse` and `GpBar::prelogin` implementations.
The response advertises SAML through `saml-auth-method` and `saml-request`; other responses use the existing standard credential path.
OpenConnect also handles these fields in its GlobalProtect implementation. No new endpoint probe or parser is needed.
See the [OpenConnect protocol notes](https://github.com/dlenski/openconnect/blob/master/PAN_GlobalProtect_protocol_doc.md).

Detection runs after Connect, never from the hostname or while saving settings.
The dropdown offers Automatic, SAML, Username and password, and Client certificate.
Explicit SAML and password choices validate the portal response before submitting credentials or saved cookies.
A mismatch stops with guidance to change the selection. Gateway requirements remain independent.
The app-mode selection check is the integration gap; upstream prelogin already supplies the required classification.

Certificate requirements can occur during TLS, before a prelogin response exists.
The response cannot choose the correct Keychain identity or reliably establish certificate-only policy.
Client certificate mode requires an explicit identity and retains the existing certificate-only toggle and combined authentication.
Browser settings appear only under SAML; certificate settings appear only under Client certificate.
Hidden browser settings remain saved and serve Automatic, gateway, and certificate flows that require SAML.
Hidden certificates are retained but are not used outside Client certificate mode.
Existing certificate configurations migrate to Client certificate. Other configurations default to Automatic.

## Authentication selection live validation — 2026-09-21

Build: `auth-selection-v1`, source `833bbdb`, GPBar 0.1.0, protocol 6, arm64, macOS 26.6.2 (25G83).
The bundled engine uses the pinned OpenProtect snapshot with this branch's app-mode changes and patched OpenConnect 9.21.
Browser: in-app WebKit 21624.5.1.11.3.

Computer use verified these behaviors:

- All four authentication choices appear in the native dropdown.
- SAML shows browser controls; specific-browser mode also shows the saved application.
- Automatic and password modes hide browser and certificate controls.
- Client certificate shows certificate controls and rejects Connect when no identity is selected.
- The selected authentication method survives app restart, including certificate mode without an identity.
- Hidden browser preferences survive method changes and app restart.
- Password selection against the available SAML portal stops with the expected method-mismatch message.
- Explicit SAML and Automatic each reach the real identity-provider page in the embedded browser.
- Connection settings lock during both attempts. Cancel closes the login window and restores Connect.
- Diagnostics report protocol 6, a verified helper, Disconnected, and no required network recovery.
- Diagnostic text contains event names and states without portal, account, callback, or other sign-in secrets.

The app was left disconnected with Automatic selected and the original in-app browser restored.
Signed Swift/Rust packaging, workspace Cargo check and Clippy, changed-file rustfmt, and strict signature verification passed.
Parallel protocol/security and UI/persistence reviews reported no remaining findings after fixing migration persistence.
No automated tests or test harnesses were created or run.

No live password-only portal or client-authentication identity was available for this check.
Certificate migration with an existing identity, successful password/certificate login, and separate gateway authentication remain unverified live.
Full SAML login, callback completion, external-browser login, and tunnel establishment were not repeated for this change.
