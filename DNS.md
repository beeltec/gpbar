# Split DNS

Split DNS selects a DNS server by domain.
For example, `server.corp.example.com` can use VPN DNS while `www.example.net` uses the Mac’s normal DNS selection.
This controls name resolution. IP routes still control application traffic and the path to each DNS server.

## Configure a profile

1. Open **Connections…** and select a profile.
2. Enable **Use split DNS**.
3. Enter **VPN DNS domains**, separated by commas or whitespace.
4. Connect normally.

Each entry matches that domain and its subdomains. Enter `corp.example.com`, without a wildcard.
Use full names when connecting to internal services, such as `server.corp.example.com`.
Split mode does not install VPN search suffixes. Your Mac’s existing search suffixes remain available.

GPBar accepts up to 128 ASCII DNS names, including punycode names.
It ignores duplicate entries, normalizes case, and accepts a final dot.
URLs, IP addresses, wildcards, empty labels, and invalid DNS labels are rejected.
The total input limit is 32 KiB. Labels can contain up to 63 bytes; names can contain up to 253 bytes.
Enabled split DNS requires at least one valid entry before connecting.

Choices save separately for each profile. Draft text remains intact across restarts.
Disconnect and complete cleanup before editing the active profile.
Disable **Use split DNS** to restore the existing gateway DNS behavior on the next connection.
Existing profiles start with split DNS disabled.

## Routing and limits

GPBar uses DNS servers supplied by the gateway. It does not provide a separate DNS server editor.
Enabled split DNS fails if the gateway supplies no DNS servers or incompatible resolver addresses.
IPv6 DNS servers require a tunnel IPv6 address. IPv6 behavior still needs live validation.

The helper ensures VPN resolver addresses route through the tunnel.
When needed, it adds session-owned host routes. Conflicting host routes stop setup instead of being replaced.
GPBar also refuses a new DNS host route that would redirect an existing system resolver into the tunnel.
This check includes file-based resolvers visible through `scutil --dns`.

Other domains keep their normal macOS resolver selection.
Their DNS packets still follow the gateway’s access routes; full tunneling can carry those packets through the VPN.
This setting does not implement domain-based application routing, DNS exclusions, or Palo Alto’s complete server-controlled split DNS policy.
More specific macOS resolver rules can take precedence.
Applications using their own resolver or encrypted DNS can bypass macOS DNS selection.
GPBar does not claim universal DNS leak prevention or a kill switch.

## Implementation and recovery

The helper validates the profile policy and writes it into the private session directory before launching the engine.
The network worker validates it again. Missing or corrupt session policy stops setup.
Reconnect keeps the session policy and uses fresh gateway DNS servers and tunnel information.

The existing network worker installs session-specific SystemConfiguration records using `SupplementalMatchDomains`.
Split mode has no empty catch-all match and uses numeric `SupplementalMatchDomainsNoSearch` to avoid adding search suffixes.
It leaves primary service DNS settings unchanged.
The existing journal records DNS and route mutations before applying them.
Disconnect and recovery remove only settings still owned by that session.
Recovery does not depend on the split DNS policy file.

Pinned OpenConnect 9.21 supplies GlobalProtect DNS servers and search suffixes, but does not populate its split DNS list.
GPBar supplies the user’s domains directly to its existing helper-owned network worker.
OpenProtect’s separate resolver-file implementation remains unused in application sessions, preserving one network owner.
Protocol version 11 requires matching app, helper, and engine versions.

## Validation

Use `scutil --dns` to inspect effective match domains, nameservers, and interfaces while connected.
Use macOS system resolver queries to check a matching full name and an unrelated name.
Direct `dig` or `nslookup` queries alone do not prove macOS resolver selection.
Inspect DNS server routes, disconnect, and compare the resolver state with the original state.
Builds and dictionary inspection alone do not prove successful DNS resolution.

## Sources

- [Palo Alto split DNS](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-gateways/split-tunnel-traffic-on-globalprotect-gateways/split-dns) explains resolver selection.
- [Palo Alto’s Windows and macOS policy](https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-gateways/split-tunnel-traffic-on-globalprotect-gateways/split-dns/configure-split-dns-for-globalprotect-app-on-windows-and-macos-endpoints) ties DNS rules to domain traffic rules.
- [Apple’s supplemental domain key](https://developer.apple.com/documentation/systemconfiguration/kscpropnetdnssupplementalmatchdomains-swift.var) defines the SystemConfiguration setting.
- [Apple’s resolver implementation](https://github.com/apple-oss-distributions/configd/blob/main/Plugins/IPMonitor/dns-configuration.c) shows supplemental matching and search-list handling.
- [OpenConnect’s network script interface](https://www.infradead.org/openconnect/vpnc-script.html) delegates routes and DNS to platform integration.
- [OpenConnect’s GlobalProtect guide](https://www.infradead.org/openconnect/globalprotect.html) describes the gateway configuration exchange.
