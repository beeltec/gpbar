# macOS login SSO checks

The owner requested this suite for issue #19 because no matching GlobalProtect server is available.
This overrides the repository and issue's earlier rules against test suites.

Run `scripts/build-native.sh`, then `scripts/test-login-sso.sh` on Apple Silicon macOS with Xcode and the pinned Rust toolchain.
Python 3 and OpenSSL with `req -addext` support are required.
The wrapper removes its temporary certificates, executables, and HTTPS server after completion.

The suite checks production components with synthetic credentials:

- User, audit-session, portal, active-console, and current-consent ownership.
- Single-use credentials, five-minute expiry, cancellation, and malformed input.
- SAML, MFA, same-origin gateway, and late-prompt rejection.
- Login-rule insertion, idempotence, removal, later third-party edits, and unsupported layouts.
- Apple-host signature requirements and Swift IPC fields.
- The actual Authorization Services plug-in ABI, context decoding, fail-open invocation, and teardown.
- Engine eligibility for portal password prompts, gateway prompts, and token prompts.
- HTTPS password submission, password encoding, MFA replacement, and rejected credentials through OpenProtect.
- Production rejection of the fixture's certificate. Trust is added only to the test client.

No real password is requested. Nothing changes system trust, login rules, installed plug-ins, routes, DNS, or helper registration.
The plug-in runs under the fixture process, without privileged host integration.
The HTTPS fixture validates the password protocol, not a real directory service or complete VPN tunnel.
The ignored HTTPS test runs only through the wrapper.
Root installation failures, real administrator prompts, login-session propagation, helper downtime, and hardware behavior still require controlled live validation.
See [installation and recovery](../../LOGIN-SSO.md) before testing those paths.

Run `scripts/test-login-sso.sh --interactive` to inspect the actual SwiftUI SSO controls in a native fixture app.
Check Cancel, confirmed enable, the displayed portal, and Disable. These actions change fixture memory only.
The fixture does not run administrator authorization or install the plug-in.
