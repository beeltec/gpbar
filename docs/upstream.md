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

No local source changes at the import commit.
