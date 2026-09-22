# Authentication checks

The owner requested this suite for issue #14 because matching GlobalProtect servers are unavailable.
This is an explicit exception to the repository's normal live-only validation rule.
All seven method tickets already have merged implementations. This suite adds shared regression coverage and one entry point for their checks.

## Run

Use Apple Silicon macOS 26, Xcode, the pinned Rust toolchain, Python 3, OpenSSL, and Homebrew `krb5`.
Run from a logged-in desktop session with an unlocked user Keychain.

```sh
scripts/build-native.sh
scripts/test-authentication.sh
```

Use `scripts/test-authentication.sh --core` for only the shared certificate, cookie, signing, password, and MFA checks.
Use `scripts/test-authentication.sh --interactive` to also operate the production password and MFA windows manually.
The window displays synthetic credentials. Enter those values, continue with the displayed code, or cancel.
Neither action contacts a real provider.

The full command runs these suites sequentially and stops on failure:

| Suite | Coverage |
| --- | --- |
| Shared checks | Native certificate signing, mutual TLS, cookie policy and storage, delegated signing, and password/MFA controls. |
| [Resource MFA](../ResourceMFA/README.md) | Portal policy, UDP framing and ingress, trusted origins, expiry, and browser isolation. |
| [Cloud Identity Engine](../CloudIdentity/README.md) | CAS parsing, HTTPS token submission, native WebKit completion, callback ownership, and cancellation. |
| [macOS login SSO](../LoginSSO/README.md) | Credential ownership, expiry, login-rule updates, plug-in ABI, and HTTPS password/MFA submission. |
| [Kerberos](../Kerberos/README.md) | Real Apple GSS tickets and mutual authentication through an isolated KDC, plus synthetic HTTPS exchanges. |

The new Rust tests use the `authentication_` filter. The HTTPS test is ignored outside its wrapper.
No new dependency or Xcode test target is required.

## Shared checks

The native runner imports generated RSA, P-256, P-384, and P-521 identities into disposable file-based Keychains.
Production Keychain code loads the public chain and signs messages and digests. Apple's public-key API verifies each signature.
The suite checks unsupported algorithms, input bounds, deleted identities, and distinct identities for different token identifiers.
These token identifiers are synthetic. They do not simulate CryptoTokenKit hardware or PIN handling.

The HTTPS fixture requires a client certificate.
OpenProtect uses its production rustls identity adapter, with signing delegated to the native runner over private pipes.
Checks cover certificate-only login, encoded portal cookies, rejected cookies, gateway MFA, and separate gateway and tunnel cookie fields.
The production client must reject the fixture's server certificate. Only the test client trusts that certificate.

Engine checks cover signing request ownership, malformed signatures, cancellation, cookie binding, expiry, and retention that never increases during reuse.
Policy checks reject missing, duplicated, malformed, or unsupported cookie permission and lifetime fields.
Native cookie checks exercise production Keychain storage, replacement, forgetting, origin binding, device mismatch, unsupported versions, malformed records, and expiry.
AppKit checks exercise the production credential and MFA controls, clearing secrets, stale completion, duplicate submission, and cancellation.

## Local effects and cleanup

The certificate runner temporarily appends each private fixture Keychain to the user's search list.
It removes only its own Keychain afterward and never changes the default Keychain or existing identities.
Cookie storage uses one generated `https://gpbar-fixture-<UUID>.invalid` account under GPBar's production Keychain service.
Only synthetic values are stored. The runner and wrapper remove that account afterward.

The wrapper removes certificates, private keys, executables, and its HTTPS listener when successful.
On failure, it attempts credential cleanup and retains the private fixture directory for diagnosis.
Its path is printed locally. Remove that directory after resolving the failure; it contains generated test keys.
An uncatchable process kill may require removing the fixture Keychain and synthetic cookie account manually.

Nothing installs a helper, edits login rules, adds trusted roots, or changes routes or DNS.
The native window runner uses its own bundle identifier and preferences.
The four existing suites retain their documented fixture behavior.
Each phase has an owned process group. Interrupting the wrapper stops that phase and its children before credential cleanup.

## Limits

Synthetic endpoints validate the implemented exchange, not compatibility with a real firewall or identity provider.
The suite does not establish a VPN tunnel or exercise OpenConnect's complete certificate handshake and networking path.
Smart-card removal, native PIN prompts, real macOS login capture, and provider-specific policy still need controlled live checks.
Real saved-cookie rejection and fallback, source-IP restrictions, and helper reconnection also remain provider or integration checks.
See [authentication support](../../AUTHENTICATION.md) for the complete support limits.

## Recorded validation

On September 22, 2026, the full command passed on Apple Silicon macOS 26.6.2 with Xcode 27 and Rust 1.95.0.
The signed Release build and strict nested signature verification also passed.

Live checks used an isolated copy of that build with separate preferences and its helper descriptor disabled.
They covered address saving, invalid-address rejection, relaunch persistence, certificate picker refresh/cancel, and authentication method selection.
The browser choice survived CIE, Kerberos, Automatic, and relaunch. Kerberos hid browser controls as expected.
The interactive production password and MFA windows accepted the displayed synthetic values and closed after completion.

Sending SIGTERM only to the interactive wrapper stopped its UI, HTTPS listener, and owned children.
The synthetic cookie record was removed, and the Keychain search list matched its starting state.

The installed production app's helper was already unreachable. No helper was installed or replaced during these checks.
No full VPN connection was attempted, and the existing installation and connection preferences were preserved.
