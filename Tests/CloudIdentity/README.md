# Cloud Identity Engine checks

The owner requested this suite for issue #20 because no matching GlobalProtect server is available.
This overrides the repository and issue's earlier rule against automated tests.

Run `scripts/build-native.sh`, then `scripts/test-cie-oidc.sh` on Apple Silicon macOS with the pinned Rust toolchain and Xcode.
The script creates a temporary HTTPS fixture and removes its certificate and key afterward.
Nothing is added to system trust, and production certificate verification remains enabled.
It requires Python 3 and an OpenSSL version supporting `req -addext`.

The HTTPS exchange test is ignored during ordinary Cargo runs. The wrapper enables it after starting its fixture.

The Rust checks cover:

- CAS prelogin classification, ambiguous fields, launch payload preservation, and HTTPS redirect restrictions.
- Callback success status, encoding, duplicate fields, size limits, and opaque token serialization.
- Actual HTTPS portal and gateway requests through the existing OpenProtect request code.
- Production rejection of the fixture certificate, plus fixture-only trust for the successful request checks.
- Endpoint token rejection, method mismatches, challenge ownership, cancellation, and loopback listener cleanup.

The Swift runner opens real AppKit windows through the production authentication coordinator.
It checks WebKit completion extraction, URI interception, isolated browser storage, saved preference preservation, stale events, cancellation, and cleanup.
Its HTML pages are synthetic and use `loadHTMLString`; they do not establish browser TLS or provider compatibility.
Preferences belong to the fixture app's bundle identifier. The runner does not start the VPN helper or change routes or DNS.

Use `scripts/test-cie-oidc.sh --interactive` to inspect the native sign-in window and click its synthetic completion link.
Completing or cancelling the interactive attempt exits the runner and removes its temporary HTTPS server.
No real account, OIDC provider, GlobalProtect server, or hardware token is involved.
The suite validates the CAS handoff supported by the evidence in [Authentication support](../../AUTHENTICATION.md#cloud-identity-engine-including-oidc).
CIE owns the OIDC client exchange. This suite does not implement or test an OIDC provider.
