# Authentication support

The app, helper, and engine must use matching protocol versions. Update them together.
For development builds in different folders, disconnect and remove the old helper through the old app before launching the new build.

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
| Smart cards and CACs | Uses identities exposed through macOS CryptoTokenKit and the existing delegated certificate signer. | Picker and SAML startup/cancellation checked live. Hardware and certificate-provider behavior remain unverified. |
| Kerberos SSO | User-session GSS tickets, HTTP Negotiate, and origin-bound prelogin-cookie handoff for portals and gateways. | Local KDC and synthetic HTTPS checks. No matching GlobalProtect provider is available. See the limits below. |
| OS-login SSO | Optional Authorization Services plug-in and one-use, session-bound portal credentials. | Synthetic checks only. System installation, login capture, FileVault, and provider behavior remain unverified. See [macOS login SSO](LOGIN-SSO.md). |
| Cloud Identity Engine OIDC | CAS browser handoff, completion capture, and portal/gateway token submission. CIE owns the OIDC exchange. | Synthetic HTTPS and native browser checks; no matching live provider. See the protocol evidence below. |
| MFA notifications for protected non-browser resources | Session-bound UDP notifications with trusted-origin and tunnel-ingress checks, followed by browser sign-in. | Synthetic protocol and native-window checks; no matching live firewall. See the restrictions below. |
| Authentication cookie persistence | Opt-in user Keychain storage, with portal policy checks and origin-bound reuse through OpenProtect. | Startup and helper refresh checked live. Cookie persistence and reuse remain unverified against a live provider. |
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
| Cloud Identity Engine | OpenProtect launch pages, HTTP client, and credential serialization. | CAS classification, strict completion validation, and native browser capture. |
| Resource MFA | Existing portal XML tree, authenticated tunnel, and native browser APIs. | Bounded notification parsing, source checks, session expiry, and isolated browser presentation. |
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

### Kerberos SSO

Automatic authentication advertises Kerberos support when starting portal and gateway prelogin.
HTTP Negotiate uses Apple GSS in the logged-in user app. The root engine cannot read the user's ticket cache.
GPBar acquires existing Kerberos credentials with UI disabled. It does not request a password, acquire a new TGT, or enable NTLM.
SPNEGO uses a credential containing only the Kerberos mechanism. Credential delegation is disabled.
Each exchange targets `HTTP/<endpoint hostname>`. The resulting GSS target must match that hostname before any token leaves the app.
Portal and gateway exchanges use separate contexts, including when they share a hostname.
Mutual authentication must complete before GPBar accepts the prelogin response.
[Apple GSS](https://developer.apple.com/documentation/gss), [HTTP Negotiate](https://www.rfc-editor.org/rfc/rfc4559),
[Official service principal setup](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000boBiCAI&lang=en_US)

Successful prelogin requires `krb-auth-status=1`, a nonempty `krb-norm-username`, and a nonempty `prelogin-cookie`.
The existing OpenProtect credential serializer submits the returned username and cookie to the same endpoint's login request.
The password remains empty. Tickets and HTTP Authorization headers are never reused for another endpoint or login request.
A response claiming success without completed GSS negotiation is rejected.
Servers using another successful handoff are unsupported until their exchange is verified.

**Fallback policy:** Automatic may retry the server's default authentication only after an authenticated portal policy explicitly permits fallback.
The policy comes from `policy/agent-config/krb-auth-fail-fallback=yes`.
The app retains this non-secret policy for the same portal and user for up to 24 hours.
The engine checks the deadline at each fallback decision, including reconnects.
Changing the portal clears that permission. A missing, malformed, duplicated, or negative policy disables fallback.
The latest authenticated portal policy governs subsequent gateway authentication and reconnects.
The helper retains each portal-bound update until the app acknowledges it, keeping its original expiry.
Pending updates override older preferences when another session starts.
Before GPBar learns a policy, Kerberos failure stops the attempt. An administrator can confirm another explicit authentication choice for initial setup.
Selecting **Kerberos SSO** disables fallback for the entire connection.
Fallback uses a fresh prelogin with Kerberos disabled, then the existing password, SAML, or CIE flow.
TLS errors, redirects, invalid handoffs, and failed mutual authentication never trigger fallback.
[Official failure policy](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-user-authentication/set-up-external-authentication/set-up-kerberos-authentication)

IPC binds each operation to the session, request, context, endpoint, active user, and originating audit session.
Exchanges allow four rounds, 48 KiB tokens, and 30 seconds per user-process response.
Cancellation stops the engine wait and suppresses late native replies. GSS resources are released when an in-flight operating-system call returns.
Tickets, tokens, and handoff cookies remain in memory and private IPC. They are excluded from logs and snapshots.
A fresh Kerberos handoff replaces saved authentication, so an older cookie cannot switch the account.

**Reuse and protocol evidence:** The pinned OpenProtect code has no ticket SSO provider.
OpenConnect 9.21 implements generic HTTP Negotiate in `gssapi.c`, inside its own process.
Its GlobalProtect parser does not consume `krb-auth-status` or `krb-norm-username`.
GPBar therefore reuses Apple GSS, OpenProtect's HTTP client and credential serializer, and the existing OpenConnect tunnel.
It adds the missing prelogin negotiation and user-process bridge.
[OpenConnect 9.21](https://gitlab.com/openconnect/openconnect/-/blob/v9.21/gssapi.c)

Protocol research also inspected Palo Alto's signed GlobalProtect 6.2.8-263 macOS package without installing or executing it.
The vendor implementation advertises `kerberos-support=yes`, recognizes status `1`, and selects the normalized username for automatic submission.
Its portal and gateway prelogin parsers retain `prelogin-cookie`; their login serializers submit that field.
This establishes the implemented client handoff, but does not prove that every Kerberos-enabled firewall supplies that cookie.
The package SHA-256 is `e392b79ff9efdc6830b39231380f1056afafd498f82361edd8b47e260cde873c`.
No vendor binary or source is redistributed.
[Vendor package](https://pan-gp-client.s3.amazonaws.com/6.2.8-263/GlobalProtect.pkg),
[Vendor connection flow](https://live.paloaltonetworks.com/twzvq79624/attachments/twzvq79624/CommunityBlog/3903/2/GlobalProtect%20Presentation.pdf)

The owner explicitly requested [a Kerberos suite](Tests/Kerberos/README.md), overriding the issue's earlier no-tests instruction.
It exercises real Apple GSS tickets against an isolated MIT KDC and acceptor, plus synthetic GlobalProtect HTTPS responses.
A real Kerberos-enabled GlobalProtect portal, gateway, corporate realm, and hardware-backed ticket source remain unverified.
The suite does not establish live provider compatibility or a working VPN tunnel.

### macOS login SSO

An optional, administrator-approved plug-in captures the next password-based macOS login for an enrolled user and portal.
The helper keeps one credential in memory for five minutes and uses the existing OpenProtect password submission.
It requires the same user, audit session, active console, and exact portal. Gateway, browser, and MFA prompts cannot consume it.
This does not implement Kerberos ticket SSO or read another application’s Keychain entries.
See [installation, removal, recovery, library evidence, and validation limits](LOGIN-SSO.md).

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

### Cloud Identity Engine, including OIDC

Choose Automatic or Cloud Identity Engine in Edit Connection. Browser settings are available under either choice and under SAML.
The same saved browser choice applies to portal and independent gateway sign-in.
Explicit Cloud Identity Engine requires `cas-auth=yes` from the portal. It does not fall back to password entry.
Explicit SAML and password choices reject a CAS portal before sending credentials or saved cookies.

CIE is the OIDC client. Its configuration contains the identity provider's client ID, client secret, and issuer.
The provider redirects to the CIE instance's `oidc/callback` endpoint.
GPBar opens the portal's browser handoff and returns the resulting CAS credential to that VPN endpoint.
It does not exchange an OIDC authorization code, verify an OIDC ID token, or hold the provider's client secret.
[Vendor OIDC setup](https://docs.paloaltonetworks.com/identity/cloud-identity-engine/authenticate-users-with-the-cloud-identity-engine/set-up-oidc-authentication)

The library audit considered [AppAuth for macOS](https://github.com/openid/AppAuth-iOS) and [openidconnect for Rust](https://docs.rs/openidconnect/4.0.1/openidconnect/).
Both implement OIDC client exchanges. Neither replaces this GlobalProtect CAS handoff, whose OIDC client runs on CIE.
No new OIDC client or dependency is implemented in GPBar.
OpenProtect already advertises `cas-support=yes` and supports launch-page rendering and `token` credential submission.
Its previous callback parser ignored CAS failure status and chose the credential field using a JWT shape check.
GPBar now requires CAS success and preserves even an opaque CAS token in the `token` field.
OpenConnect 9.21 has no CIE-specific OIDC discovery or code-exchange path to reuse.

#### Protocol evidence

Vendor configuration guides establish OIDC support, but omit the native wire exchange.
Inspection used the same signed GlobalProtect 6.3.3-h8 macOS package referenced under resource MFA below.
The package was inspected only. Its code and binaries are not included in this repository.

The inspected `CPanMSService::PreloginPortal` reads `cas-auth` alongside `saml-auth-method` and `saml-request`.
The native browser path accepts a base64 POST document or redirect through that existing handoff.
`handleCASResponse` accepts status `cas-as=1`, username `un`, and `token` from `globalprotectcallback:`.
Its embedded browser also reads `cas-as`, `un`, and `token` completion tags, including HTML comments.
Portal configuration and gateway login submit the credential as `token` to their existing GlobalProtect endpoints.
These observations, combined with CIE's documented OIDC callback, support using the CAS path for CIE-backed OIDC.
That conclusion remains an integration inference until a matching provider is available.
[GlobalProtect CIE support](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-user-authentication/embedded-web-view-with-cie-for-force-authentication)

GPBar preserves the server's signed launch payload and any state inside it without decoding or rewriting it.
Callbacks require the current session and challenge, and can be consumed only once.
Cancellation closes owned windows and the private launch listener. TLS verification remains enabled.
Missing, failed, duplicate, malformed, and oversized CAS completion fields are rejected.
Embedded completion reads only the three named result fields from a bounded HTTPS page in the owned browser.
It does not read login form values, save browser cookies, or grant pages a native message bridge.

The observed CAS callback has no client-generated state value that GPBar can verify independently.
Session and challenge ownership prevent stale application events; they do not cryptographically bind an externally supplied token to the launch request.
The VPN endpoint must validate the CAS token and its server-side binding. GPBar does not treat its contents as verified identity.
External callback-scheme routing retains the existing browser limitations. Selected-browser tabs must be closed manually.

The owner explicitly requested a server-free suite for issue #20, overriding its earlier live-only validation rule.
Run [the CIE suite](Tests/CloudIdentity/README.md) for synthetic HTTPS, callback, session, and native WebKit checks.
Real OIDC providers, MFA, passkeys, hardware, and VPN connection success remain unverified for this method.

### Protected-resource MFA

Resource MFA runs after tunnel setup. It does not reuse portal or gateway password challenges.
The firewall supplies an authentication page. Users finish its web forms, then retry the protected resource.
Opening or closing that page does not prove that authentication succeeded.
[Vendor configuration guide](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-user-authentication/configure-globalprotect-to-facilitate-multi-factor-authentication-notifications)

The authenticated portal must enable `mfa-enabled` and supply `mfa-trusted-host-list` members in its `agent-config`.
The listener uses `mfa-listening-port`, defaulting to 4501. Invalid, duplicate, missing, or excessive trust settings disable it.
Only the current verified tunnel's IPv4 address and interface can receive notifications.
The receiver checks kernel-supplied ingress metadata and the sender against addresses resolved from the matching trusted hostname.
Resolution happens once per tunnel attempt. Hostname or address changes require reconnecting.
A separate sending interface that does not resolve from the redirect hostname is unsupported.
IPv6 notifications and internal gateways without tunnels are unsupported.

The tunnel authenticates the VPN gateway. UDP notifications themselves contain no verified signature or session identifier.
These checks rely on the gateway preventing spoofed source addresses inside its network.
They do not prove the identity of an individual firewall behind the gateway or prevent every replay inside a new tunnel.
GPBar never treats a notification as proof of authentication or resource authorization.

Notifications must contain one bounded type-3 URL using HTTPS and an exact trusted host and port.
Supported paths are `/php/uid.php` and `/php/browser_challenge.php`, with numeric `vsys` and `rule` parameters.
HTTP, user information, fragments, duplicate parameters, alternate paths, and extra query parameters are rejected.
These restrictions cover the observed vendor examples. Other page formats need protocol evidence before support is added.
[Vendor packet example](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA1Ki000000fyHiKAI&lang=en_US),
[Vendor URL example](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA14u000000wljdCAA&lang=en_US)

A prompt displays the portal's plain-text message and the destination hostname before opening a browser.
It needs an explicit Open sign-in action. The saved browser choice remains in use.
In-app sign-in has a fresh, nonpersistent WebKit data store and normal TLS validation.
HTTP authentication, client-certificate requests, custom URL schemes, and VPN callback handling are unavailable in this resource window.
GPBar does not supply VPN passwords, authentication cookies, or selected certificate keys to the resource page.
External browsers retain their own cookies and certificate behavior. Their tabs must be closed manually.

Prompts expire after two minutes. Disconnect, session replacement, and lost helper contact close owned resource windows.
Dismissal leaves the VPN connected. At most one prompt appears during each two-minute interval.
Longer portal suppression settings, up to three minutes, are honored.
Pending prompts are not replayed after UI reconnection. A later firewall notification can create another prompt.
Listener failures leave the VPN connected and display a notification-unavailable message in the panel.

#### Protocol evidence and validation

The pinned OpenProtect snapshot and OpenConnect 9.21 have no resource-notification listener or acknowledgement implementation.
Their existing MFA code handles login-time challenges only. Custom integration is required for this separate UDP exchange.

Protocol inspection used the signed, notarized GlobalProtect 6.3.3-h8 macOS package from a public university distribution endpoint.
The package was extracted for inspection, never installed or executed.
Its receive path reads TLVs with a one-byte type and a two-byte big-endian value length.
Type 3 carries the authentication URL. Unknown TLVs are skipped; GPBar additionally validates all framing and rejects duplicate URLs.
The inspected receive path forwards the accepted notification to its UI, without sending a UDP reply.
GPBar likewise adds no invented network acknowledgement or authentication-success callback.
Package SHA-256: `648b07892553bf7b5733d5f3ba56398ace25cf73944335578678f2a42df6dc1f`.
The package and extracted code are not distributed with GPBar.
[Inspected package endpoint](https://vpn.upenn.edu/global-protect/getmsi.esp?platform=mac&version=none)

The owner explicitly requested automated tests for issue #21 despite the repository's normal live-only policy.
Run [the resource MFA suite](Tests/ResourceMFA/README.md) for synthetic protocol, socket, session, and native browser checks.
These checks do not establish compatibility with a real MFA firewall, provider, hardware token, or IPv6 deployment.

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
The latter uses existing tickets from the user's login session through the dedicated adapter described above.
[Official Kerberos setup](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-user-authentication/set-up-external-authentication/set-up-kerberos-authentication)

CIE implementation evidence and remaining provider checks are listed [above](#cloud-identity-engine-including-oidc).

The unverified provider and hardware gaps remain open. The password and challenge implementation does not close full authentication parity.

## Authentication selection and detection

Automatic detection reuses the pinned OpenProtect `PreloginResponse::parse` and `GpBar::prelogin` implementations.
The response advertises browser login through `saml-auth-method` and `saml-request`. The `cas-auth=yes` flag identifies Cloud Identity Engine.
OpenConnect also handles these fields in its GlobalProtect implementation. CAS adds validation to the existing parser without a new endpoint probe.
See the [OpenConnect protocol notes](https://github.com/dlenski/openconnect/blob/master/PAN_GlobalProtect_protocol_doc.md).

Detection runs after Connect, never from the hostname or while saving settings.
The dropdown offers Automatic, SAML, Cloud Identity Engine, Kerberos SSO, Username and password, and Client certificate.
Explicit SAML and password choices validate the portal response before submitting credentials or saved cookies.
A mismatch stops with guidance to change the selection. Gateway requirements remain independent.
The app-mode selection check is the integration gap; upstream prelogin already supplies the required classification.

Certificate requirements can occur during TLS, before a prelogin response exists.
The response cannot choose the correct Keychain identity or reliably establish certificate-only policy.
Client certificate mode requires an explicit identity and retains the existing certificate-only toggle and combined authentication.
Browser settings appear under Automatic, SAML, and Cloud Identity Engine. Certificate settings appear only under Client certificate.
Hidden browser settings remain saved and serve Automatic, gateway, and certificate flows that require SAML.
Hidden certificates are retained but are not used outside Client certificate mode.
Existing certificate configurations migrate to Client certificate. Other configurations default to Automatic.

## Validation limits

Live checks on macOS 26.6.2 covered authentication selection, saved preferences, certificate selection controls, SAML startup, and cancellation.
A development build completed embedded SAML login and established a tunnel.
Later authentication changes have not all repeated the full connection flow.

Successful password login, client-certificate login, smart-card hardware, and separate gateway authentication remain unverified against a live provider.
Saved-cookie persistence, reuse, expiry, and policy changes also need live validation.
Full external-browser callback handling and page cleanup remain unverified.
Builds and source reviews do not establish compatibility with a provider.
