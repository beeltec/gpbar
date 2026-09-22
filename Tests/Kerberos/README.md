# Kerberos SSO checks

The owner requested this suite for issue #18 because no matching GlobalProtect server is available.
This overrides the repository and issue's earlier restrictions on automated tests.

Run `scripts/build-native.sh`, then `scripts/test-kerberos.sh` on Apple Silicon macOS with Xcode and the pinned Rust toolchain.
The suite also requires Homebrew `krb5`, Python 3, and OpenSSL with `req -addext` support.

The wrapper creates a temporary MIT Kerberos realm, database, keytabs, and FILE credential cache.
Its KDC listens only on loopback at a temporary port. Credentials never enter the user's normal ticket cache.
The wrapper removes its temporary files and stops its KDC and HTTPS server on exit.
It does not change system trust, networking, login rules, helper registration, or VPN settings.

The native checks use the production Apple GSS adapter and a real MIT GSS acceptor:

- Existing tickets for separate portal and gateway service principals.
- SPNEGO with Kerberos credentials, mutual authentication, and hostname binding.
- Missing tickets without password prompts.
- Cancelled operations, stale contexts, changed endpoints, and invalid requests.

The Rust checks use production OpenProtect request and credential code:

- HTTP Negotiate for portal and gateway prelogin, followed by endpoint-specific cookie submission.
- Production rejection of the fixture certificate; test-only trust for successful HTTPS checks.
- Missing credentials, ticket rejection, and policy-controlled fallback.
- Redirects, malformed challenges, unsolicited success, missing mutual authentication, and incomplete handoffs.
- Strict success parsing, duplicate fields, bounds, cookie redaction, and fail-closed fallback policy parsing.
- Engine challenge ownership, stale answers, unavailable tickets, cancellation, and separate endpoint handoffs.

The HTTPS fixture uses synthetic Negotiate tokens. Real cryptography is checked separately through the native adapter and temporary realm.
No matching GlobalProtect firewall or complete VPN tunnel is tested.
The successful firewall handoff still needs provider validation. See [protocol evidence and limits](../../AUTHENTICATION.md#kerberos-sso).
