# Runtime security and recovery

The UI runs as the signed-in user. The launchd helper and its engine run as root.
The helper exposes fixed session operations. Callers cannot supply executable paths, script paths, or environment variables.

Before execution, the helper copies its application into a root-owned, private staging directory.
It validates the bundle seal, nested signatures, exact identifiers, and signing team. It rejects symlinks.
It then moves the complete bundle into a private session directory.
Interrupted staging copies can be removed without touching network state.
The launched process record includes PID, start time, and boot identity.

The engine uses a controlled environment and fixed system utilities.
GnuTLS uses `/etc/ssl/cert.pem`, without Homebrew trust-file or automatic PKCS#11 module discovery.
`GNUTLS_SYSTEM_PRIORITY_FILE=/dev/null` selects library defaults without loading a user-writable Homebrew configuration.
GnuTLS documents this configuration override. [System configuration](https://www.gnutls.org/manual/html_node/System_002dwide-configuration-of-the-library.html)
Authentication uses rustls. Embedded sign-in uses WebKit's trust handling.
Enterprise certificate behavior needs separate compatibility validation across these three trust paths.
There is no invalid-certificate option in the application.

## Network ownership

The bundled `Packaging/vpnc-script` invokes a fixed native helper mode.
The imported upstream route script is retained for provenance but is not executed by application sessions.
The native worker implements the selected macOS route and DNS path.
It does not run `/etc/vpnc` hooks, write `/etc/resolv.conf`, or reset network service DNS preferences.

The worker records intent before each mutation in a root-owned atomic journal.
It flushes the file and parent directory before applying the change.
It adds gateway-provided routes without replacing exact existing routes.
Full-tunnel routes use two half-default routes, preserving the original default route.
The public gateway receives an outside-tunnel route when needed.
Conflicts fail setup and trigger rollback.

DNS uses session-specific SystemConfiguration keys.
Cleanup removes a value only when it still matches the installed dictionary.
Route cleanup checks destination, mask, gateway, interface, and the tunnel interface index.
Boot identity prevents old journals from modifying a new boot's network state.
Ambiguous or failed cleanup retains its journal and blocks another session.
A recorded child that still exists blocks recovery; an unrelated reused PID does not.

## Sensitive data

Preferences contain only connection settings and browser choice.
Callbacks, SAML content, cookies, passwords, and OTP values are not saved.
In-app browser storage is ephemeral. External browsers retain their own storage policies.
There is no clipboard polling or password-manager extraction.

The app retains at most 100 event names, phases, and bounded error codes in memory.
Diagnostic exports omit portal, gateway, account, interface addresses, and sign-in material.
Users see the export text before choosing a file location.
No analytics or remote diagnostic upload is implemented.

The application HIP path reports only observed OS, firewall, and FileVault information.
Unknown product inventory and patch status are omitted instead of using the supplied CLI's template claims.
Compatibility with gateways requiring additional posture information remains unverified.

Network workers check a root-owned cancellation marker and the engine's recorded process identity before configuration commands.
A worker stops its owned command when cancellation occurs or the engine exits.
Each network command has a five-second kill deadline. Cleanup finishes before the helper reports a stopped session.
