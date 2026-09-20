# Source provenance

## OpenProtect

The source snapshot comes from the supplied `GlobalProtectNew` repository.
Its reference commit is `01e6d13ac44629d3a965147659a3a1e2cc3e97a5`.
The supplied README identifies upstream commit `04d727620f0485d40e61bac1c243766b8e6b2230`.
Upstream is <https://github.com/kyaky/openprotect>.

`Vendor/openprotect` preserves the supplied tree, including macOS changes and upstream tests.
It does not include the prebuilt binary or company-specific connection wrappers.
`upstream-files.json` records SHA-256 hashes before GPClient changes.
The reference tree was clean when captured on 2026-09-20.
The reference repository does not identify its individual patches against upstream.
Do not treat its upstream revision claim as evidence that the supplied files equal upstream.

Original MIT and Apache 2.0 notices remain in the source tree and `Packaging/Licenses`.
Changes after import are recorded in Git and below.

## Route script

`Vendor/vpnc-script/vpnc-script` comes from the installed OpenConnect 9.21 package.
It retains its GPL 2.0-or-later notice.
The complete script and its hash are pinned in `runtime-inputs.json`.
Its upstream source is <https://gitlab.com/openconnect/vpnc-scripts>.
This is a supplied package snapshot, not a claim about an upstream commit.

## Native dependencies

OpenConnect 9.21 was installed through Homebrew.
The initial library targets macOS 26.0 and links to additional Homebrew libraries.
The package inventory is recorded in `runtime-inputs.json`.
Bundling must inspect the actual dependency closure and preserve its notices.
The installed package alone is not a redistributable GPClient release.

## Local changes

The import commit contains no local source changes. Later commits add:

- A bounded, versioned application session protocol over inherited pipes.
- Cancellable SAML and OTP challenges for initial authentication and reauthentication.
- Bounded HTTP/XML parsing and strict callback handling.
- Actual runtime capability reporting and a required patched OpenConnect build.
- Observed macOS HIP facts instead of template posture claims in application mode.
- Native macOS route/DNS journaling, verification, and conditional cleanup.

OpenConnect 9.21 source is downloaded from its [official release directory](https://www.infradead.org/openconnect/download/).
Its SHA-256 is pinned in `runtime-inputs.json` and the native build script.
`Packaging/Patches/openconnect-private-hip.patch` carries the local C changes.
Application mode moves HIP inputs into a private pipe and assigns reconnect ownership to the engine.
It also disables automatic PKCS#11 discovery for application sessions.
The patched runtime identifies itself as `v9.21-gpclient1`.

`Packaging/vpnc-script` calls the native journal worker.
The imported upstream script remains unchanged as a reference and is not the application's mutation path.
Native library license files are included under `Packaging/Licenses/Native`.

The application path maps GlobalProtect's macOS identifier to OpenConnect's `mac-intel` platform value.
The native patch propagates route-worker failures instead of ignoring them during tunnel setup.
Unix cancellation handles duplicate the command descriptor to prevent descriptor reuse during teardown.
