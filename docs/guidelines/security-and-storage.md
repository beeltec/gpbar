# Security, preferences, and diagnostics guidelines

Research date: 2026-09-20. Scope: local persistence, credentials, logs, privacy, and diagnostic export.

## Data ownership

| Data | Owner and storage |
| --- | --- |
| Portal address, display name, browser choice, launch preference | User application, `UserDefaults`. |
| SAML callback, OTP, authentication cookies | Active session memory and private IPC only. |
| Future persistent credential, if explicitly required | User Keychain with narrowly scoped access. |
| Connection snapshots | Memory; contain no authentication secret. |
| Recovery journal | Root helper, private root-owned storage, without credentials. |
| Diagnostics | Bounded, sanitized records; export only after user review. |

Hostnames and connection metadata may reveal organization details even though they are not authentication secrets.
Do not include them in public logs or committed evidence by default.

## UserDefaults and automatic saving

Use `UserDefaults` for the non-secret configuration required by the plan.
Use stable keys with one owner and register defaults without overwriting saved values.
Use the API rather than editing its backing files.
Apple describes defaults as an unencrypted settings store with asynchronous disk persistence. [UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults)

- Save a valid address when the user submits or leaves its field, and before Connect uses a pending edit.
- Keep draft input separate from the saved configuration.
- Invalid input must not replace the saved address or cause a silent connection to an older address.
- Preserve the address across disconnect, cancellation, failure, relaunch, reboot, and normal updates.
- Preserve bundle identity and preference keys across releases; migrate intentionally when a key changes.
- Do not save passwords, callbacks, cookies, or OTP values in preferences.
- Do not add a database for one connection and a small set of settings.
- Do not promise crash-proof synchronous persistence merely because `UserDefaults.set` returned.

## Keychain and secrets

Do not add persistent credential caching without a requirement.
If that requirement arrives, use Keychain Services and choose an explicit access policy for each item.
Do not make a root helper read another user's Keychain implicitly.
Apple provides encrypted storage for small secrets through [Keychain Services](https://developer.apple.com/documentation/security/keychain-services).

Keep secrets out of process arguments, environment variables, crash attachments, clipboard polling, and error strings.
Clear credential references when a challenge or session ends.
Minimize copies across Swift, Rust, and C boundaries.
Do not claim guaranteed memory zeroing for ordinary Swift strings or Rust strings.
Review the backend's HIP wrapper arguments and library callbacks as part of this rule, not just Swift logging.

## OSLog and Rust tracing

Use Swift `Logger` with stable subsystem and category names.
Log state transitions, error categories, session correlation IDs, and cleanup results.
Use privacy-aware interpolation for values containing user or organization information.
Apple documents the distinction between public and private dynamic data. [Generating log messages](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)

The project has a stricter secret rule: never send authentication secrets into a logger, even as private values.
Apply this rule to Rust tracing, C progress callbacks, and subprocess stderr before forwarding them.
Do not derive unrestricted debug output for credential containers.
Avoid logging whole errors when their nested messages may include request URLs or server response bodies.

Keep diagnostics bounded in memory and disk usage.
Do not let a verbose backend block state delivery or consume unbounded storage.
Use stable error codes for UI decisions rather than parsing human-readable log text.

## Privacy manifests

Inventory use of required-reason APIs, including `UserDefaults`, in the application and bundled code.
Maintain a truthful `PrivacyInfo.xcprivacy` when the implementation uses those APIs.
Select the reason that matches actual use; do not copy another application's reason codes blindly.
Apple documents the API categories and permitted reasons. [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)

The documented App Store Connect submission requirement is distinct from this project's Developer ID distribution path.
Do not claim that passing notarization proves the privacy inventory is complete.
Do not add fingerprinting, analytics, or unrelated device collection.

## Diagnostic export

Show the user what will be exported and let them choose the destination.
Strip secrets and unnecessary account, hostname, address, and path details before export.
Include app version, backend revision, OS version, safe error categories, and relevant state transitions.
Do not export browser history, page contents, cookie databases, complete HIP payloads, or unrestricted system logs.

Run the privacy checks in [the validation guide](validation-and-workflow.md) before completing authentication or diagnostic changes.
