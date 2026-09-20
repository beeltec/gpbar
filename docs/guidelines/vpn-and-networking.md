# VPN, TLS, routes, and DNS guidelines

Research date: 2026-09-20. Scope: OpenProtect, GlobalProtect, OpenConnect, reqwest/rustls, XML, and macOS networking.

## Protocol ownership

Reuse the supplied OpenProtect implementation for portal authentication, gateway selection, HIP, and reconnect behavior.
Use libopenconnect for the tunnel.
Keep the configured portal address separate from the selected gateway address.
GlobalProtect has distinct portal and gateway interfaces, and the portal can return multiple gateways. [OpenConnect GlobalProtect documentation](https://www.infradead.org/openconnect/globalprotect.html)

The user-entered portal must drive every connection stage.
Do not add provider-specific branches, identity-provider domains, hardcoded gateways, or hidden portal fallbacks.
Retain `--os mac`, automatic HIP behavior, and the existing gateway-selection policy unless a concrete compatibility issue requires change.

The current OpenProtect snapshot is the implementation baseline.
Its local macOS documentation and actual source may differ; inspect the selected code path before relying on a description.
Use upstream documentation to understand behavior, not to replace the supplied snapshot with upstream HEAD.

## HTTP and TLS

Use a session-owned HTTP client and cookie store with explicit timeouts and redirect policy.
Keep browser state, portal credentials, and gateway credentials scoped to their intended host and session.
Configure corporate proxy behavior deliberately instead of inheriting arbitrary root-process environment settings.
Reqwest exposes timeout, redirect, proxy, cookie, and TLS configuration. [Reqwest ClientBuilder](https://docs.rs/reqwest/0.12.28/reqwest/struct.ClientBuilder.html)

- Preserve the existing rustls-backed reqwest configuration unless a demonstrated need requires change.
- Validate hostnames and certificate chains on both authentication and tunnel connections.
- Never enable invalid-certificate or invalid-hostname acceptance to make a portal work.
- Do not assume WebKit, rustls, and libopenconnect use identical trust stores or proxy settings.
- Verify enterprise certificate behavior through supported trust configuration.
- Review redirects before forwarding credentials; a valid certificate alone does not authorize receiving another host's secret.
- Bound connection time, response time, decompressed response bytes, and XML parsing work.
- Preserve actionable TLS errors while stripping cookies, tokens, and raw sensitive URLs.

Saving an address is local configuration only.
Do not contact the portal until the user starts the connection flow.

Keep rustls certificate verification and its safe protocol defaults enabled.
Configure required trust roots explicitly rather than installing a verifier that accepts every certificate.
Review changes to the cryptographic provider against the pinned dependency configuration. [Rustls configuration](https://docs.rs/rustls/latest/rustls/struct.ConfigBuilder.html)

## XML and HIP

Use the existing `quick-xml` models and parser instead of regular expressions or ad hoc tag searches for new protocol work.
Select parser options explicitly where correctness depends on them.
The library exposes configurable validation behavior. [quick-xml configuration](https://docs.rs/quick-xml/latest/quick_xml/reader/struct.Config.html)

Project parsing rules:

- Reject malformed encoding, excessive nesting, oversized fields, and missing required protocol values.
- Do not implement external entity retrieval or accept arbitrary network or file references from XML.
- Keep size and depth limits in the application layer; parser configuration alone does not define the project's resource budget.
- Escape generated XML values correctly and preserve required field names and encoding.
- Do not log full authentication or HIP documents.
- Report actual supported device facts. Do not fabricate compliance claims to satisfy a gateway.
- Submit HIP when the gateway requires it and repeat it for new tunnel sessions where the protocol requires that.

## Tunnel readiness and route ownership

Interface creation does not prove that routes or DNS are configured.
OpenConnect relies on a route/DNS script for platform configuration in the selected script-based mode. [vpnc-script documentation](https://www.infradead.org/openconnect/vpnc-script.html)

- Pass the bundled, pinned script path explicitly.
- Confirm required system utilities are present on every supported macOS version.
- Preserve gateway-provided routing behavior; do not add `--only` merely to simplify implementation.
- Do not configure the same routes or resolvers through both the script and the native Rust path.
- Publish connected state only after the required route and DNS setup succeeds.
- Keep tunnel readiness separate from optional application-level reachability diagnostics.
- Validate IPv4 and IPv6 independently. Do not describe observed IPv4 success as complete IPv6 support.
- Preserve the route needed to reach the VPN gateway outside its own tunnel where required.

## DNS and crash recovery

Record actual network mutations before applying them, including mutations performed inside the bundled script.
Use an atomic, root-owned session journal and a single owner for recovery.
Track prior values and the values this session installed.
After reconnect, update ownership records for the new interface and settings.

Restore only changes still owned by the session.
Preserve later DHCP, user, and other-VPN changes.
Do not delete all resolver files, flush all routes, or reset all network services.
On partial failure, restore completed changes and retain evidence of unresolved cleanup.
Do not rely on the existing Unix `recover` command; the supplied implementation is a no-op.

## Network changes and reconnect

Use `NWPathMonitor` as a signal to reconsider connection state.
It observes network path changes; it does not verify the VPN's internal services. [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor)

Keep retry and backoff policy in the engine.
Explicit disconnect cancels retries and pending authentication.
Reconcile state after wake, interface changes, helper restart, and UI reconnection.
Report uncertainty instead of inventing a successful connection or disconnection.

Use [live network validation](validation-and-workflow.md) for DNS restoration, IPv6, sleep, network loss, and forced engine exit.
