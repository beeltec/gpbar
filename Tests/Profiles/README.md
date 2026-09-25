# Connection profile suites

The owner explicitly requested these suites for issue #67 because only one real GlobalProtect server is available.
They supplement native UI checks and do not establish compatibility with another provider.

Run from the repository root on Apple Silicon macOS 26 or newer with Xcode installed:

```sh
scripts/test-profiles.sh
```

## Coverage

- Existing preference migration, stable IDs, selected profile restoration, and app-wide preference preservation.
- Separate browser, authentication, certificate, reconnect, saved-sign-in, and Kerberos policy behavior.
- Same-server profiles, duplicate-name labels, invalid drafts, profile deletion, and durable cleanup records.
- Production connection-model guards during setup, authentication, reconnection, disconnection, unknown status, cleanup, updates, and helper inspection.
- Cancellation during asynchronous cookie loading, stale callbacks, helper reconciliation, SSO enrollment, and session reattachment.
- Real Keychain storage with two profile namespaces and the legacy namespace at the same synthetic portal.

The lifecycle binary compiles production connection code with a helper, service, and cookie-storage fixture from this folder.
It drives delayed replies and failures without using XPC or modifying the installed helper.
The Keychain binary separately exercises the real storage implementation.
No production simulation mode, test target, or package dependency is added.

## Local effects

Each storage suite uses a unique UserDefaults domain and removes it afterward.
Keychain checks write synthetic cookies under a unique `.invalid` portal and random profile UUIDs.
The wrapper removes those records after success or failure. It retains the fixture directory if checks or cleanup fail.
No real credentials, certificate identities, login rules, routes, DNS settings, or running VPN sessions are changed.
After an uncatchable process kill, remove only the retained fixture records with:

```sh
/path/to/retained/fixture/keychain /path/to/retained/fixture --cleanup
```

## Design sources

The profile sidebar follows [Tunnelblick's configuration list](https://www.tunnelblick.net/czUsing.html).
The general settings separation follows [Viscosity's app settings](https://www.sparklabs.com/support/kb/article/using-viscosity/).
[Apple's settings guidance](https://developer.apple.com/design/human-interface-guidelines/settings) informs the native window and Command-comma shortcut.

## Limits

Fixtures do not establish real helper reconnection, server authentication, browser cleanup, smart-card behavior, or working tunnel traffic.
Only one live GlobalProtect server is available. Cross-server switching still needs validation against another approved server.
