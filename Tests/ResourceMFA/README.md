# Resource MFA checks

The owner requested this suite for issue #21 because no matching GlobalProtect server is available.
This is an explicit exception to the repository's usual rule against automated tests.

Run `scripts/build-native.sh`, then `scripts/test-resource-mfa.sh` on an Apple Silicon Mac with the pinned Rust toolchain and Xcode.
The suite checks portal policy, binary framing, malformed input, trusted origins, source addresses, socket ingress, truncation, expiry, and browser cleanup.
It uses the production parsing and socket code with a loopback UDP peer.
The Swift runner opens real AppKit windows and uses the production WebKit coordinator.
It never starts the VPN helper or changes routes, DNS, or saved connection preferences.

Run `scripts/test-resource-mfa.sh --interactive` to inspect the real resource sign-in window.
The fixture supplies an approved event directly to the coordinator, bypassing the unavailable VPN server.
Clicking Open sign-in loads a public example.com address. That page is not an MFA provider.
Dismiss or close the window to check cleanup. The prompt also expires after two minutes.

The binary fixtures are synthetic. They follow the observed one-byte type, two-byte big-endian length, and type-3 URL format.
They are not firewall captures and cannot establish provider compatibility or cryptographic UDP sender authentication.
See [the protocol evidence and trust limits](../../AUTHENTICATION.md#protected-resource-mfa).
