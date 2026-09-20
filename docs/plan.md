# Native macOS VPN client implementation plan

Date: 2026-09-20

Working name: GPClient

Target repository: `/Users/beeltec/workspace/beelte/gpclient`

Reference implementation: `/Users/beeltec/GlobalProtectNew`

Implementation rules: [coding guidelines](guidelines/README.md), routed through [AGENTS.md](../AGENTS.md).

## 1. Intended result

Build a native SwiftUI application that lives in the macOS menu bar.
Users can connect, finish browser login, inspect their connection, and disconnect without opening Terminal.
The application is a general GlobalProtect client, with a connection address supplied by each user.
No company portal is hardcoded, preselected, or required.
For our deployment, the user enters `vpn.example.com`.

Reuse OpenProtect for GlobalProtect authentication and OpenConnect for the tunnel.
A small Swift helper manages privileged operations and the backend process.
The SwiftUI application runs as the logged-in user.

The first release targets Apple Silicon and macOS 14 or newer.
Distribute a signed, notarized application with its runtime dependencies included.
Homebrew and Rust are development dependencies only.

This document proposes implementation work. No VPN connection, privileged installation, or application build was performed during planning.

## 2. What exists today

The destination repository is empty and has no existing application structure.
The reference repository is on `main`, at commit `01e6d13`.
Its README identifies the OpenProtect source baseline as `04d727620f0485d40e61bac1c243766b8e6b2230`.
Preserve the supplied source snapshot, including its macOS changes, rather than replacing it with upstream HEAD.

Paths below are relative to `/Users/beeltec/GlobalProtectNew`.

| Area | Evidence | Implication |
| --- | --- | --- |
| Current connection | `scripts/company-vpn` uses `sudo -E`, `--os mac`, `--hip auto`, and `--reconnect`. | Preserve these connection settings without requiring Terminal. |
| Reference portal | The wrapper uses `vpn.example.com`. | Treat SAML-enabled provider as a validation example. Replace the fixed address with user configuration. |
| Authentication | `crates/gp-auth/src/saml_paste.rs` opens a browser flow and accepts a `globalprotectcallback:` value. | Add a native sign-in window and structured callback delivery. |
| Root requirement | `bins/opc/src/main.rs` rejects unprivileged macOS connections. | Running the CLI with Foundation `Process` alone is insufficient. |
| Control interface | `crates/gp-ipc/src/lib.rs` provides JSON status and disconnect requests. | Existing IPC is useful reference code, but cannot support the full UI lifecycle. |
| IPC permissions | Root sessions use `/tmp/openprotect-0/<instance>.sock`, with private directory and socket permissions. | The normal user application cannot directly control root sessions. |
| Early state | `connect()` starts IPC after authentication and gateway login. | Login progress and cancellation require a new control path. |
| Status fields | IPC includes gateway, account, uptime, routes, interface, IPv4, and three session states. | It does not provide throughput, complete DNS state, or every UI state. |
| MFA | Gateway login can request an OTP through stdin. | Native integration must replace every interactive prompt, including reauthentication. |
| Binary linkage | `otool -L bin/openprotect` resolves `libopenconnect.5.dylib` under `/opt/homebrew`. | The supplied binary is not a standalone runtime. |
| Route setup | The wrapper supplies no `--only`, so it normally uses an autodetected `vpnc-script`. | Bundle a known script and pass its path explicitly. |
| DNS code | `gp-dns` contains `networksetup` and `/etc/resolver` paths for native route mode. | The macOS notes understate current source capabilities. Validate the actual selected path. |
| Recovery | The Unix `recover_platform()` implementation returns a no-op. | Do not present this command as macOS network recovery. |
| Existing GUI | `bins/opc-gui` and `bins/opc-tray` are separate, excluded GUI projects. | Reuse protocol knowledge, not their interface or process-control design. |
| Build fallback | `gp-openconnect-sys` can skip bindings when OpenConnect is missing. | A successful Rust build does not prove real tunnel support. |

The source locations for crate paths above are under `source/openprotect/`.
The local machine has Xcode 27.0 and Swift 6.4 installed.
This does not establish compatibility with the proposed macOS 14 deployment target.

## 3. First-release scope

### Included

- One configured portal and one active connection.
- User-entered connection address, editable during setup and later in settings.
- Optional connection display name; use the portal hostname when no name is supplied.
- Browser-based SAML login through the portal's identity provider and gateway OTP entry when requested.
- Saved browser choice: in-app browser by default, system default browser, or a specific installed browser application.
- Automatic handling of `globalprotectcallback:` to continue connection setup without another Connect action.
- Automatic closure of the owned sign-in window or external authentication tab, subject to verified browser capabilities.
- Masked callback paste only as a troubleshooting fallback.
- Connect, cancel, disconnect, and reconnect states.
- Connection details: portal, gateway, account, assigned IP, interface, and elapsed time.
- Helper setup, permission status, and repair guidance.
- Optional launch at login, disabled initially.
- Reconnection during an existing session, matching the current wrapper.
- Local, redacted diagnostics with a user-reviewed export.
- Disconnect and cleanup during normal quit.
- Bundled dependencies, signing, notarization, and removal instructions.

### Deferred

- Multiple simultaneous tunnels or a profile manager.
- Custom split-route and DNS editors.
- Password-based portals, direct Okta authentication, and certificate-management UI.
- Traffic graphs or byte counters without backend support.
- Starting a VPN connection automatically when the user signs into macOS or reboots, without clicking Connect.
- Automatic updates, cloud settings, analytics, and remote administration.
- Intel builds, App Store distribution, and a Network Extension implementation.
- Kill-switch behavior or claims that every application uses the tunnel.

Support user-configured GlobalProtect portals through the included authentication methods.
Use SAML-enabled provider as the first real compatibility check, not as a product restriction.
Portal configuration must drive authentication, gateway discovery, HIP, and connection setup without company-specific branches.
Show a clear unsupported-authentication message if a portal requires a deferred authentication method.
An editable address does not imply support for every GlobalProtect authentication policy.

“Launch at login” starts the menu bar application when the user signs into macOS.
It does not start a VPN connection.
The normal flow is Connect → browser login → automatic callback handling → tunnel establishment and browser cleanup.
Automatic continuation after browser login is included in the first release.

## 4. Architecture decisions

### Process boundaries

```text
GPClient.app — logged-in user
  SwiftUI menu bar panel, sign-in window, settings, diagnostics
            |
            | authenticated XPC: typed commands and state events
            v
GPClientHelper — launchd daemon, root
  Client validation, session ownership, process supervision, recovery
            |
            | private inherited pipes: versioned JSON messages
            v
Bundled OpenProtect engine — root child process
  Portal authentication, HIP, reconnect loop, libopenconnect
            |
            v
utun + bundled route/DNS script + macOS networking
```

This is a native application interface with a reused Rust/C networking backend.
It is not a Swift rewrite of the VPN protocol.

Keep the engine out of the UI process.
This isolates blocking C calls, backend crashes, and elevated privileges from SwiftUI.
Keep one backend process per connection, supervised by the helper.

For version one, retain the backend's existing root execution model.
This also places authentication parsing in a privileged process and requires careful review.
Splitting authentication into another unprivileged process is a later hardening option, not an initial rewrite requirement.

### Why this approach

| Approach | Decision |
| --- | --- |
| SwiftUI around shell scripts and repeated `sudo` prompts | Reject. It leaves privilege handling and login tied to Terminal. |
| SwiftUI + helper + bundled engine | Choose. It preserves the supplied protocol implementation and gives the app explicit lifecycle control. |
| Swift/C/Rust library integration inside the UI | Reject. It mixes UI lifetime with blocking tunnel work and does not solve privilege separation. |
| Network Extension packet tunnel | Defer. It requires adapting the current tunnel and route ownership model. Validate separately if that becomes a requirement. |
| Full Swift protocol rewrite | Reject. It replaces working authentication and tunnel code without a current need. |

### Native application structure

Use `MenuBarExtra` with `.menuBarExtraStyle(.window)` and `LSUIElement = true`.
Add separate SwiftUI scenes for sign-in, settings, and diagnostics.
Apple documents this combination for menu bar utilities with custom controls. [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)

Use a single `@MainActor @Observable` connection model.
Move XPC work, message decoding, and process I/O away from the main actor.
Use Swift concurrency with explicit isolation and cancellation.
Keep the project on a supported Swift language mode and pin the actual build toolchain after the compatibility spike.

Use AppKit only for native behavior SwiftUI cannot provide cleanly.
Examples include application activation and URL delivery.
Do not introduce a third-party state framework or menu bar library initially.

### Helper registration

Use `SMAppService.daemon(plistName:)` and an embedded launch daemon property list.
Set `BundleProgram` to the helper's path inside the application.
Use a declared Mach service for XPC.
Check service status at launch and after returning from System Settings.
Treat registration, user approval, and a working XPC connection as separate states.
Apple documents this bundle structure and approval flow. [Helper registration](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)

Use `SMAppService.mainApp` for optional launch at login.
This setting is separate from permission to run the VPN helper. [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)

Ship outside the App Store with Hardened Runtime enabled.
Use a non-sandboxed application and helper for the initial implementation.
Keep entitlements minimal and document their purpose.

## 5. Interface and visual design

### Direction: a quiet connection instrument

The primary job is simple: show whether the work connection is ready and expose the next useful action.
Use native materials, careful spacing, and clear state labels.
Avoid dashboards, oversized shields, decorative charts, and promotional copy.

The signature element is a small connection path: `This Mac — Gateway`.
Its middle segment changes with actual connection state.
A solid line means connected; a broken line means disconnected; a restrained moving segment means work is underway.
The accompanying text always explains the state.

This makes the tunnel relationship visible without suggesting total device protection.
It uses one visual idea and keeps the rest of the interface conventional.

### Design tokens

| Token | Specification |
| --- | --- |
| Panel | About 360 points wide, with content-driven height and a scroll limit on smaller displays. |
| Spacing | 4, 8, 12, 16, and 24 points; 16-point outer padding. |
| Headings | SF Pro Rounded, semibold, about 18–20 points, used only for connection state. |
| Body | SF Pro system text, about 13 points; native button and form sizing. |
| Technical values | SF Mono or monospaced system text, about 11–12 points. |
| Surface | Native window/popover material and semantic foreground colors. |
| Corners | Native container shape; modest internal rounding only where it groups related controls. |
| Motion | Short transitions around 150–200 ms; animate only while connecting or reconnecting. |

Accent palette candidates are `routeBlue #2864DC`, `connectedTeal #087F72`, and `attentionAmber #A86200`.
Use `failureRed #B93845`, `ink #172333`, and `mist #EEF2F7` as supporting design references.
Create accessible light and dark variants in the asset catalog.
Use semantic system colors for body text and backgrounds.
Validate contrast before finalizing colors; these hex values are starting points, not acceptance evidence.

Native system type takes priority over adding custom fonts.
The connection path provides the visual identity.

### Connected panel

```text
┌──────────────────────────────────────┐
│ Work VPN                          ⚙  │
│                                      │
│   This Mac ─────────── Gateway        │
│                                      │
│ Connected                            │
│ Connected for 01:24:08                │
│                                      │
│ Gateway       <reported gateway>     │
│ VPN address   <assigned IP>           │
│                                      │
│ [            Disconnect            ] │
│                                      │
│ Connection details          Quit…    │
└──────────────────────────────────────┘
```

Use actual backend values. Omit unavailable fields instead of inventing placeholders in the shipped UI.
The panel title uses the configured display name or portal hostname; “Work VPN” above is an example name.
Put longer account names, portal addresses, routes, and interface information in expanded connection details.
Support text selection and deliberate copy actions for useful technical values.

### State-specific behavior

| State | Visible message | Primary action |
| --- | --- | --- |
| Setup required | “Set up VPN access” | Set up |
| Approval required | “Allow the VPN helper in System Settings” | Open System Settings |
| Disconnected | “Disconnected” | Connect |
| Preparing | “Contacting your VPN” | Cancel |
| Browser authentication | “Finish signing in” | Open sign-in window |
| OTP challenge | “Enter your verification code” | Open sign-in window |
| Connecting | “Starting your connection” | Cancel |
| Connected | “Connected” | Disconnect |
| Reconnecting | “Reconnecting” with the current attempt | Disconnect |
| Disconnecting | “Disconnecting” | Disabled until cleanup completes |
| Status unavailable | “Checking connection” | Retry status |
| Failed | Specific cause and recovery action | Retry or open settings |
| Cleanup failed | “Connection stopped. Network cleanup needs attention.” | Open diagnostics |

The menu bar symbol must remain legible in light and dark menu bars.
Use a monochrome template symbol with distinct shapes or badges for disconnected, connected, busy, and attention states.
Do not depend on color or animation alone.
Build the accessibility label from the actual connection name, such as “GPClient, connected to Work VPN”.

### Sign-in, settings, and accessibility

Use a persistent sign-in window because the menu bar panel closes when users switch to the browser.
Default to an in-app browser in that window, with the current login hostname visible and a Cancel action.
Offer “In-app browser”, “Default browser”, and “Choose browser…” in the browser setting.
For external browsers, show login progress and actions to reopen the authentication page or cancel.
Keep callback paste under a troubleshooting disclosure; normal login must not require copying a link or pressing Continue.
Show OTP entry only when requested by the engine.
Closing the owned sign-in window before authentication completes cancels that login attempt.

Settings contain the portal, display name, browser choice, launch-at-login toggle, reconnection preference, and helper status.
Persist browser choice with the other non-secret preferences.
Lock connection settings while a session is active.
Changing launch-at-login must not connect the VPN.

### Connection address setup and editing

First launch shows an empty “Connection address” field with `vpn.example.com` as its placeholder.
Explain that users should enter the GlobalProtect portal address supplied by their organization.
Do not prefill SAML-enabled provider or provide a company-specific preset.
Keep Connect disabled until a valid address has been saved and the helper is ready.

Accept a hostname or HTTPS origin, including an optional port and trailing slash.
Trim surrounding whitespace and normalize the value with a URL parser.
Require a valid host and port; reject plain HTTP, embedded credentials, query strings, fragments, and unsupported paths.
Use HTTPS when the user enters only a hostname.
Apply normal certificate validation to the configured host.
Do not offer an insecure certificate bypass in the initial UI.

Automatically save a valid address when the user submits the field or leaves it; no separate Save action is required.
Store the address and optional display name in `UserDefaults` for the current macOS user.
Connect must validate and save any pending address edit before starting the session.
Incomplete or invalid edits must not overwrite the last saved address or silently connect to it.
Restore the saved values after app restarts, Mac reboots, and application updates.
Show address setup only when no saved address exists; otherwise open with the saved connection ready to use.
Keep the address until the user changes it, including after disconnect, cancelled login, or connection failure.
Saving an address must not start a connection or contact that portal.
Pass the saved address through the helper to the backend for each new session.

Make “Edit connection…” accessible from the menu bar panel and settings.
While connected or connecting, explain that the user must disconnect before changing the address.
After an address change, clear old connection details, errors, and authentication state.
Late responses from the previous portal must never populate or authenticate the new connection.
The first release stores one connection; changing its address replaces that configuration.

Provide keyboard navigation, visible focus, VoiceOver labels, and selectable error details.
Respect Reduce Motion, Reduce Transparency, and increased contrast.
Use text that wraps without clipping at larger accessibility sizes.
Keep focus stable when status changes.
Avoid announcing the elapsed timer repeatedly through VoiceOver.

## 6. Backend integration contract

### Add a dedicated application mode

Extend the vendored engine with a mode such as `opc app-session`.
The exact command name can follow the existing CLI style.
Do not use `--json` as if it already supplies a complete event stream.
Keep existing CLI behavior available for development and compatibility checks.

Use private pipes inherited from the helper for commands and events.
Reserve stdout for newline-delimited JSON in this mode.
Keep stderr separate, bounded, and redacted.
No terminal prompts, formatted banners, or secret-bearing logs may enter the event stream.

Disable legacy public control sockets in application mode.
This avoids root-session discovery collisions and predictable `/tmp` paths.
Retain existing CLI sockets only for ordinary CLI mode.

### Message rules

- Start with a protocol version and capability handshake.
- Include a session ID, command ID where applicable, and increasing event sequence number.
- Give each authentication challenge its own ID.
- Define maximum message sizes; begin with a 256 KiB ceiling and validate against real callback sizes.
- Reject oversized, malformed, unexpected, and out-of-order messages safely.
- Use bounded buffers and continuously drain both output streams.
- Reject incompatible protocol versions with an actionable upgrade message.
- Keep raw credentials outside state snapshots and diagnostic events.

### Commands and events

| Direction | Message | Purpose |
| --- | --- | --- |
| Helper → engine | `start` | Supply validated portal settings and the owned session ID. |
| Helper → engine | `submit_callback` | Answer the matching browser authentication challenge. |
| Helper → engine | `submit_otp` | Answer a gateway challenge. |
| Helper → engine | `cancel` / `disconnect` | Stop login or an active tunnel through the same cancellation mechanism. |
| Helper → engine | `get_snapshot` | Reconcile state after UI reconnect or a missed event. |
| Engine → helper | `ready` | Report protocol and real tunnel capabilities. |
| Engine → helper | `phase_changed` | Report preparation, login, tunnel setup, reconnect, or shutdown. |
| Engine → helper | `authentication_required` | Provide challenge ID and approved local browser launch URL. |
| Engine → helper | `authentication_completed` | Confirm successful credential exchange for the challenge so its browser can close. |
| Engine → helper | `otp_required` | Provide challenge ID and a sanitized user prompt. |
| Engine → helper | `snapshot` | Provide confirmed session details and readiness. |
| Engine → helper | `failure` | Provide stable error code, safe message, and retry classification. |
| Engine → helper | `stopped` | Confirm termination and network cleanup result. |

Add these types close to the existing IPC definitions where practical.
Keep protocol knowledge in one Rust module and a small Swift transport model.
Use `Codable` payloads over XPC `Data`, with explicit version checks and size limits.
Avoid a generic RPC framework or plugin interface.

### Required engine changes

1. Start command handling before portal prelogin.
2. Route initial login, gateway OTP, and reconnect authentication through the same challenge mechanism.
3. Make every waiting stage cancellable, including HTTP requests, browser waits, OTP input, and retry backoff.
4. Publish readiness only after required route and DNS setup succeeds.
5. Preserve gateway selection, `--os mac`, automatic HIP submission, and existing reconnect behavior.
6. Expose the selected gateway without displaying a gateway picker in version one.
7. Report runtime support for OpenConnect and refuse the stub backend in release builds.
8. Convert internal failures into stable categories before passing them to SwiftUI.

Review both `connect()` and `run_reauth()`.
Replacing only the first SAML prompt will leave reconnect sessions waiting on invisible stdin.

## 7. Authentication flow

1. The user selects Connect.
2. The app checks helper readiness and sends validated settings.
3. The helper reserves the single session and starts the bundled engine.
4. The engine performs portal prelogin and emits an authentication challenge.
5. The app opens the authentication page in the user's saved browser choice, defaulting to the in-app browser.
6. The user completes their organization's identity-provider login and any browser MFA.
7. The browser follows `globalprotectcallback:` and the app captures it automatically for the active challenge.
8. The engine validates the callback and exchanges the credential through the existing portal flow.
9. After authentication succeeds, the app closes its in-app browser or requests closure of the owned external authentication tab.
10. Connection setup continues automatically; the app handles any separate gateway OTP challenge.
11. The engine establishes the tunnel, applies network settings, and reports readiness.

The user clicks Connect once and completes the required login steps.
No manual token transfer or second Connect action belongs to the normal flow.
Browser cleanup must not delay tunnel establishment or make a successful authentication fail.

### Browser implementation and saved selection

Use one user-process authentication coordinator to own browser presentation, the active challenge, callback delivery, and cleanup.
Keep browser-specific code behind this small interface.
The root helper must never open browsers or control other applications.

| Choice | Implementation | Callback and cleanup |
| --- | --- | --- |
| In-app browser, default | SwiftUI window hosting `WKWebView` through `NSViewRepresentable`. | Intercept the callback navigation, deliver it to the active challenge, and close the owned window after authentication succeeds. |
| Default browser | Prefer `ASWebAuthenticationSession` when the selected browser and portal support it. Otherwise use explicit external launch. | Use session-scoped callback delivery where available; verify the browser's authentication-page cleanup behavior. |
| Specific browser application | Resolve the saved browser application and open the launch URL in that application. | Use native callback delivery and a verified browser-specific mechanism to close only the owned authentication tab. |

For the in-app browser, inspect navigation with `WKNavigationDelegate` and cancel navigation to `globalprotectcallback:` after capture.
Handle new-window requests through `WKUIDelegate`, including callback links using `target="_blank"`.
Use the same coordinator for popups belonging to the login attempt.
Apple exposes navigation decisions and new-window handling through these delegates. [Navigation delegate](https://developer.apple.com/documentation/webkit/wknavigationdelegate), [UI delegate](https://developer.apple.com/documentation/webkit/wkuidelegate)

Keep WebKit's normal TLS validation and show the current hostname throughout login.
Use an isolated, nonpersistent website data store initially; do not copy external-browser cookies into the app.
The user signs into the identity provider directly; do not inspect password fields or inject credential-capture scripts.
Validate redirects, form posts, popups, MFA, passkeys, and the tenant's device-access requirements in the browser compatibility spike.
If the tenant rejects embedded login, explain the failure and offer a fresh attempt in the user's chosen external browser.
Do not silently change their saved preference.

On macOS, `ASWebAuthenticationSession` uses a compatible default browser, or Safari as a fallback.
It is not an embedded browser and cannot select an arbitrary browser application.
Its callback delivery is scoped to the requesting session, including when applications share a callback scheme. [Web authentication sessions](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
Validate its initializer availability against macOS 14 and its handling of the actual GlobalProtect callback format.
Explain any system browser fallback instead of claiming that it used the selected default browser.

Populate the specific-browser picker from installed applications that can handle web URLs.
Save the browser's bundle identifier and resolve its current installation when starting a session.
If it is unavailable, offer browser selection rather than launching a different browser silently.
Apple supports opening a URL in a specified application through `NSWorkspace`. [Opening URLs in a chosen application](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:))

### External tab closure and capability limits

The requested outcome is automatic closure of the authentication tab after successful login.
Treat callback capture and tab closure as separate capabilities in the browser compatibility record.
Opening a URL with `NSWorkspace` returns an application reference, not an owned tab handle.
Therefore, generic URL launch alone cannot implement reliable tab closure. [NSWorkspace return value](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:))

First verify cleanup through browser-managed authentication sessions.
For explicit browser applications, investigate narrow browser adapters that create and track only the authentication tab or a dedicated authentication window.
Use browser-supported automation only where a stable reference and its ownership can be verified.
Request macOS Automation access only if that browser adapter requires it, and explain its purpose.
Do not close the active tab by position, send a global close shortcut, or quit the browser.
Do not scan unrelated tabs or include their content in diagnostics.

Do not assume a launch page can always close an external tab with JavaScript.
Browsers restrict `window.close()` based on how the window was opened. [Browser window-closing rules](https://developer.mozilla.org/en-US/docs/Web/API/Window/close)
If closure is unavailable or permission is denied, finish connecting and explain that the user can close the authentication tab.
Record that browser as lacking automatic cleanup; do not mark the requested behavior as fully implemented for that browser.
Resolve the supported browser matrix during Phase 0 and carry unresolved closure gaps into the release criteria.

### Browser launch and callback handling

Preserve support for both SAML redirect and form-post launch responses.
In application mode, bind any launch server only to loopback on an ephemeral port.
Remove Tailscale listeners and public-IP discovery from this mode.
Use an unpredictable, short-lived launch path and close the server after completion or cancellation.
Deliver the callback through authenticated XPC and private pipes, rather than an unauthenticated HTTP callback endpoint.

Automatic `globalprotectcallback:` handling is required, starting with interception inside the in-app browser.
For external launch without a managed authentication session, register native URL handling and route events into the active coordinator.
The scheme may already belong to the official GlobalProtect application.
A custom replacement scheme cannot be assumed to work with the identity provider.

Treat scheme registration as a compatibility decision during the initial spike.
Do not change the default handler silently.
Prefer in-app interception or session-scoped callback delivery when those avoid a handler conflict.
If a chosen external browser needs a handler change, explain that requirement and provide a clear setup action.
An unresolved external callback conflict is a compatibility gap; manual paste does not satisfy the primary flow.
Document how both clients can remain installed.

Only accept callbacks while the matching session is waiting for authentication.
Clear the field after submission and reject duplicate or expired challenge responses.
Use the existing Rust callback parser for Prisma tokens and classic callbacks.
Harden malformed input handling and redact `SamlCapture` debug output in the app path.

An internal challenge ID cannot prove that an externally supplied token belongs to the browser request.
Use protocol-supported correlation where available and let the portal validate the credential.
Do not describe JWT parsing or a three-part token check as signature validation.

Never place callbacks, cookies, passwords, OTP values, or SAML form contents in arguments, preferences, logs, or exports.
Keep session credentials in memory and release them when the session ends.
Do not add a credential cache initially.
Use macOS Keychain only if later requirements introduce persistent secrets.
Read the clipboard only through an explicit user action.

## 8. Privilege and session ownership

The helper API must expose specific VPN operations, not arbitrary command execution.
Accept only known settings and reject arbitrary executable paths, script paths, environment variables, and raw CLI flags.
Launch the backend directly with fixed executable paths and argument arrays.
Use a controlled environment and explicit bundled resource paths.

Authenticate both XPC peers using code-signing requirements tied to the application's identity and Team ID.
Set requirements before resuming the connection.
Apple provides peer enforcement through `setCodeSigningRequirement(_:)`. [XPC peer validation](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))

Validate the caller's OS-provided user identity separately from its signature.
Bind the session to that user and prevent another login session from controlling it.
Restrict new sessions to the active console user for version one.
Handle fast user switching explicitly; disconnect before transferring ownership.

Verify bundled executable signatures and resource integrity before privileged execution.
Reject modified dependencies, substituted scripts, and paths writable by unrelated users.
Protect against symlink replacement and path changes during validation and launch.
Avoid loading Homebrew libraries or user configuration from a root process in release builds.

Store helper state in a private, root-owned application support directory.
Do not relax permissions on the existing `/tmp/openprotect-0` directory.
Check installed-helper and app protocol versions before starting a session.

Use only the owned child process for cancellation or escalation.
Never use `pkill`, `killall`, or a broad search for OpenProtect processes.
Detect existing CLI sessions or conflicting VPN state and explain the conflict.
Do not adopt or disconnect another client's session automatically.

HIP reporting must follow the selected portal and gateway requirements.
Inspect the bundled HIP wrapper, its execution user, and any invoked utilities.
Report actual supported device facts; do not invent compliance data.

## 9. State, reconnection, and cleanup

### Single source of connection state

The engine owns tunnel state; the helper owns process state and session ownership.
The UI displays their confirmed state through one connection model.
Keep helper availability separate from VPN state.

Use explicit states: `disconnected`, `preparing`, `authenticating`, `connecting`, `connected`, `reconnecting`, `disconnecting`, `failed`, and `unknown`.
Represent cleanup failure separately from whether the process has stopped.
Treat authentication challenges as associated state, not independent booleans.

Disable duplicate actions while a command is pending.
Make cancel and disconnect idempotent.
Ignore events belonging to earlier sessions.
On XPC interruption, show unknown status until a fresh snapshot arrives.
A timeout or missing socket does not prove disconnection.

Stream events during normal operation.
Fetch a fresh snapshot when the panel opens, the app resumes, or XPC reconnects.
Update elapsed time locally from backend timestamps.
Distinguish total session duration from the start of the current tunnel attempt.

### Reconnection ownership

Keep retry policy in the engine; do not add a second retry loop in Swift.
Use the backend's existing backoff where it is suitable, with a bound and visible failure state.
Stop retries immediately after explicit disconnect.
Pause retries when the network is unavailable and resume through the same engine controller.
Use network-path changes as hints, not proof that the VPN works.

Request user authentication again when the credential expires.
Keep the sign-in window available across menu bar dismissal and sleep.
Validate behavior during Wi-Fi changes, Ethernet changes, sleep, wake, and gateway loss.

### Lifetime policy

- Closing the menu bar panel or settings leaves the connection active.
- Quit while connected offers “Disconnect and Quit” and “Cancel”.
- Cancel during login closes authentication listeners and terminates the pending session.
- Cancel or timeout closes owned in-app browser windows and requests cleanup of the owned external authentication page.
- A UI crash leaves an established tunnel active under helper supervision.
- Relaunching the app reconnects to the owned session and retrieves its state.
- Losing the UI during authentication cancels the challenge after a bounded grace period.
- Logout, user switching, or helper removal disconnects and cleans up.
- A helper restart reconciles recorded state before allowing another connection.

Handle menu bar item removal as an application-lifetime edge case.
Apple notes that a menu-bar-only application can terminate when its item is removed. [MenuBarExtra lifetime](https://developer.apple.com/documentation/swiftui/menubarextra)
Attempt normal disconnect on termination; the documented crash policy covers termination that prevents cleanup.

### Network restoration

Preserve the current gateway-provided routing behavior for the first release.
Do not switch to `--only` or native route mode merely to simplify packaging.
Pass the bundled `vpnc-script` explicitly and verify every utility it invokes exists on supported macOS versions.

Record network changes before applying them, using an atomic, root-owned session journal.
Cover DNS service settings, resolver files where applicable, route changes, and tunnel identity.
Connect the journal to the actual mutation path, including the bundled route/DNS script.
A helper snapshot alone is insufficient if the script makes additional changes later.

On disconnect, request cooperative engine shutdown and wait for cleanup confirmation.
Use a bounded grace period before terminating a stuck owned process.
After forced termination, run targeted recovery using the journal.
Never rely on destructors after a crash or `SIGKILL`.

Restore only values this session changed and still owns.
Preserve later user changes, DHCP updates, and settings belonging to another VPN.
Keep the journal when recovery fails and show a useful error.
Do not offer a broad “reset networking” action.

Validate DNS and routes separately from interface creation.
Inspect IPv4 and IPv6 behavior, including traffic outside the configured tunnel.
Do not claim a kill switch, full-tunnel coverage, or DNS leak prevention without a separate implemented requirement.

## 10. Source layout and dependencies

Proposed structure:

```text
GPClient.xcodeproj/
GPClient/
  App/
  Connection/
  Views/
  Services/
  Resources/Assets.xcassets/
GPClientHelper/
  HelperMain.swift
  SessionController.swift
  EngineProcess.swift
  NetworkRecovery.swift
Shared/
  HelperProtocol.swift
  ConnectionSnapshot.swift
  EngineMessages.swift
Vendor/
  openprotect/
  vpnc-script/
Packaging/
  LaunchDaemons/
  Entitlements/
  Licenses/
scripts/
  build-engine.sh
  bundle-runtime.sh
  package-release.sh
docs/
  plan.md
  backend-protocol.md
  manual-validation.md
  upstream.md
```

Create an Xcode project with application and helper targets.
Share only transport types and required connection models between targets.
Keep implementation details inside their owning target.
Do not create separate packages for every service or view.

Vendor the supplied OpenProtect snapshot into this repository.
Record its upstream baseline, reference repository commit, local differences, and license files in `docs/upstream.md`.
Avoid a runtime dependency on `/Users/beeltec/GlobalProtectNew`.
Keep backend changes focused on application integration and macOS reliability.

Pin Rust, OpenConnect, the route/DNS script, and native dependency versions.
Preserve `Cargo.lock`; the current `stable` toolchain channel alone is not a reproducible build definition.
Keep preferences small: use `UserDefaults` for non-secret application settings.
Do not add a database.

### Runtime bundle

- Place the engine and helper in established executable locations inside the app bundle.
- Place non-system dynamic libraries in `Contents/Frameworks`.
- Include the route/DNS script and required HIP resources as sealed bundle resources.
- Rewrite library install names and runpaths before signing.
- Inspect transitive dependencies with `otool -L`; include every required non-system library.
- Build every bundled component for Apple Silicon and the declared minimum macOS version.
- Refuse release packaging if paths still reference Homebrew or the developer workspace.
- Refuse release packaging if the engine reports stub tunnel support.

Preserve OpenProtect's supplied MIT/Apache license notices.
OpenConnect identifies its license as LGPL 2.1. [OpenConnect license](https://www.infradead.org/openconnect/licence.html)
Inventory the exact bundled versions and their notices, source availability, and redistribution requirements before release.
Include the route/DNS script and transitive libraries in that review.

## 11. Delivery phases

Work through these phases in order.
Each phase ends with a working artifact and a clear exit condition.
Commit completed units using Conventional Commits.
Use one Conventional Branch, such as `feat/native-macos-client`, for the implementation unit.
Do not create extra branches for each phase.

### Phase 0 — Compatibility and packaging spike

Tasks:

- Capture the supplied source baseline and dependency inventory.
- Build the existing engine with real OpenConnect support.
- Confirm macOS 14 build compatibility for Swift, Rust, and native libraries.
- Exercise the existing SAML-enabled provider flow on an approved real Mac and account.
- Validate another GlobalProtect portal when an approved environment is available; record any compatibility limits if it is unavailable.
- Record gateway login, HIP, route setup, DNS, disconnect, and reconnect behavior.
- Verify callback ownership with the official client installed.
- Prove the full callback flow in an in-app WebKit window, a default browser, and a specifically selected browser application.
- Record callback capture, tab closure, permissions, and tenant compatibility for each supported browser.
- Resolve external tab ownership before promising automatic closure for a browser.
- Prove a signed helper can register, require approval, and accept authenticated XPC.
- Prove a minimal packaged engine runs without resolving Homebrew runtime paths.
- Choose the bundle identifier, signing team, and initial supported OS matrix.

Deliverable: `docs/upstream.md`, a compatibility record, and a minimal working helper/engine spike.

Exit condition: no unresolved blocker in root access, automatic authentication callbacks, browser selection, runtime packaging, or minimum OS support.
Document browser cleanup gaps explicitly; a successful callback alone does not complete the requested browser lifecycle.
If macOS 14 cannot be supported, document the exact dependency before changing the target.

### Phase 1 — Native application shell

Tasks:

- Create the application and helper targets with shared build settings.
- Implement the menu bar scene, settings, and persistent sign-in window.
- Add the in-app WebKit host and persisted browser picker.
- Implement empty first-run connection setup, address validation, saved configuration, and Edit connection.
- Implement the design tokens and connection path component.
- Create the typed connection state model.
- Use SwiftUI preview data for visual development only.
- Add launch-at-login control and helper setup presentation.
- Verify keyboard operation, focus, light mode, dark mode, and accessibility settings on macOS.

Deliverable: a running native interface covering every planned state.

Exit condition: the interface is usable from the menu bar and remains coherent while users switch to another application.

### Phase 2 — Structured engine mode

Tasks:

- Add the versioned command and event contract.
- Add application-mode SAML and OTP challenge handling.
- Remove terminal dependencies from all application-mode paths.
- Make initial login, retries, and reauthentication cancellable.
- Add readiness and cleanup events.
- Add bounded message parsing and safe error codes.
- Disable application-mode Tailscale discovery, public-IP lookup, and legacy control sockets.
- Document the contract in `docs/backend-protocol.md`.

Deliverable: a real engine session controlled through private pipes.

Exit condition: complete a real login, connect, disconnect, and cancelled login without terminal input or log scraping.

### Phase 3 — Privileged integration

Tasks:

- Finish helper registration, permission state handling, and XPC peer checks.
- Add ownership checks and the single-session controller.
- Launch only verified bundled code with a controlled environment.
- Bridge typed app commands to the engine and forward sanitized state.
- Pass the saved portal address through every connection stage; remove the reference wrapper's fixed company address.
- Implement child supervision, timeouts, and protocol-version mismatch handling.
- Reject conflicting sessions and unsafe settings.
- Reattach the application to an existing owned session after relaunch.

Deliverable: Connect and Disconnect work from SwiftUI through the helper.

Exit condition: daily operation needs no Terminal, no `sudo` prompt, and no root UI process.
Initial macOS helper approval remains part of setup.

### Phase 4 — Complete authentication and connection experience

Tasks:

- Implement the authentication coordinator with in-app, default-browser, and specific-browser modes.
- Capture callbacks automatically in each supported mode and continue connection setup without another user action.
- Close the owned in-app browser after successful authentication and implement verified external authentication-page cleanup.
- Handle denied automation access, missing browsers, and callback-handler conflicts with clear recovery actions.
- Keep masked callback paste available only for troubleshooting.
- Implement OTP and expired-session flows.
- Bind real state, gateway details, and elapsed time to the interface.
- Handle repeat clicks, cancellations, delayed replies, and stale events.
- Add actionable errors and bounded, redacted local diagnostics.
- Review the interface with actual long portal names, accounts, and error messages.

Deliverable: the complete daily connection flow.

Exit condition: Connect opens the chosen browser, callback capture continues automatically, and the owned authentication page closes on supported browsers.
The user can recover from failed attempts and understand every visible connection state.

### Phase 5 — Network lifecycle and recovery

Tasks:

- Instrument the actual route/DNS mutation path with session journaling.
- Implement cooperative shutdown and targeted crash recovery.
- Verify reconnection after network changes and sleep.
- Handle UI crashes, engine crashes, helper restarts, logout, and user switching.
- Implement Disconnect and Quit, helper removal, and settings restoration.
- Confirm behavior while another VPN or the official client is installed.

Deliverable: a connection that can stop and recover without leaving stale network settings.

Exit condition: the live failure matrix below passes, including DNS and route restoration.

### Phase 6 — Release packaging

Tasks:

- Build and bundle the pinned native dependency closure.
- Finalize notices, icons, version metadata, and removal instructions.
- Sign libraries, engine, helper, and application in the correct order.
- Enable Hardened Runtime and verify release entitlements.
- Submit with `notarytool`, inspect the result, and staple the ticket.
- Package a disk image with clear installation instructions.
- Verify installation, helper approval, upgrade, and removal on a clean Mac.

Apple requires valid Developer ID signatures and Hardened Runtime for this notarization workflow. [Notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Deliverable: a signed, notarized installation artifact and matching source/version record.

Exit condition: a clean supported Mac can run the full flow without Homebrew, Rust, Xcode, or the reference folder.

## 12. Live validation plan

Do not create automated tests or test targets.
Use builds, static compiler checks, and live validation on macOS, following the repository instructions.
SwiftUI previews are development aids, not evidence that real networking works.

Record the OS version, app build, backend revision, actions, result, and redacted evidence in `docs/manual-validation.md`.
Keep real callback tokens and company network details out of committed screenshots and logs.

| Scenario | Required result |
| --- | --- |
| First launch | Setup requests a connection address, explains the helper, and accurately shows registration and approval status. |
| Address entry | A hostname or HTTPS origin is accepted; invalid or unsupported input produces a clear inline error. |
| Address persistence | Valid entry saves automatically. App restart, reboot, and updates retain it without repeating address setup. |
| Invalid address edit | The saved address remains intact; Connect shows validation errors instead of using an older address silently. |
| Session ends or fails | Disconnect, cancelled login, and connection failure retain the saved address; saving never connects automatically. |
| Address change | The next session uses the new portal throughout authentication and gateway discovery, with no stale account or session data. |
| Active-session editing | Address changes remain disabled until disconnect and cleanup finish. |
| Approval declined or later revoked | Connection remains unavailable with a working route to System Settings. |
| Browser login | The configured portal's identity-provider flow completes; Microsoft login works for the SAML-enabled provider reference deployment. |
| In-app browser | It is the initial choice, captures callback redirects and popup links, and closes after successful authentication. |
| Browser preference | In-app, default-browser, and specific-browser choices persist across app restart. |
| Specific browser | The selected installed application receives the login URL; an unavailable application prompts browser selection. |
| Automatic continuation | One Connect action starts login; callback capture automatically continues tunnel setup without paste or another Connect action. |
| External page cleanup | Supported browser modes close only their owned authentication page; unrelated tabs remain open and untouched. |
| Cleanup unavailable | Denied permissions or unsupported browsers do not block connection; the remaining tab and capability limit are explained. |
| Embedded login rejected | The user can restart in an external browser without changing the saved preference silently. |
| Browser closed early | Closing the in-app login window cancels the pending attempt; external cancellation or timeout clears pending state. |
| Another portal | An approved second portal works through supported authentication, or its specific unsupported requirement is documented. |
| Paste callback | Long valid callbacks work; malformed input produces a useful error without exposing the value. |
| Callback conflicts | In-app or managed-session capture reaches GPClient; ordinary external launch explains any required handler selection. |
| OTP challenge | The challenge appears once, accepts input, and supports cancellation. |
| Cancel at each stage | Portal lookup, browser wait, OTP, tunnel setup, and retry backoff stop promptly. |
| Repeated Connect clicks | Only one engine process and one session exist. |
| Real connectivity | An approved internal hostname resolves and its service is reachable. |
| Public connectivity | Expected public traffic and DNS remain usable according to the gateway's routing policy. |
| IPv6 | Observed routing and resolution match the documented support limits. |
| Disconnect | Owned routes and DNS changes are removed or restored; unrelated settings remain intact. |
| Network loss and return | One retry controller recovers or shows a clear failure. |
| Sleep and wake | State reconciles and a working connection resumes or requests login. |
| Credential expiry | Reauthentication uses the native flow without waiting on stdin. |
| UI crash and relaunch | The active tunnel remains owned and the UI recovers its real state. |
| Engine crash | The helper detects exit and restores owned network changes. |
| Helper crash and restart | Orphaned session state is reconciled before another connection starts. |
| Cleanup interruption | The journal survives and enables targeted recovery without deleting unrelated settings. |
| Another login session | Another user cannot inspect secrets or control the first user's session. |
| Untrusted XPC caller | Requests are rejected without starting an engine. |
| Missing or altered runtime | Startup fails clearly before privileged execution. |
| Protocol mismatch | The app explains the version issue without misreporting connection state. |
| Large or malformed messages | The relevant session fails safely without unbounded memory use. |
| Quit, logout, and removal | The intended lifetime policy runs and restores network state. |
| Accessibility | Keyboard, VoiceOver, increased contrast, reduced motion, and reduced transparency remain usable. |
| Clean installation | The notarized artifact works without developer dependencies. |
| Upgrade | An active session ends cleanly before backend replacement; helper and app versions stay compatible. |

Use `scutil --dns`, route inspection, and interface inspection to compare network state before and after sessions.
Use approved internal endpoints for real connectivity checks.
Check signing with `codesign`, Gatekeeper assessment with `spctl`, and the stapled ticket with `stapler validate`.
Run live networking checks on a controlled Mac where connection changes will not interrupt unrelated work.

## 13. Risks and decisions to resolve during implementation

| Risk or decision | Planned response |
| --- | --- |
| Callback scheme belongs to the official client | Use in-app interception or session-scoped capture; resolve explicit-browser handler conflicts before claiming support. |
| Identity provider rejects embedded login | Offer the selected external browser and record the tenant-specific limitation. |
| External browser cannot close its login tab reliably | Verify browser-specific ownership and cleanup; disclose the gap without blocking a successful connection. |
| Source snapshot differs from upstream | Preserve the supplied tree and document the differences before upgrading. |
| Native libraries require a newer OS | Rebuild compatible versions or present the exact blocker before raising the deployment target. |
| Tunnel builds with a stub | Enforce real backend capability during packaging and live validation. |
| Root backend parses remote input | Restrict the execution surface, patch input handling, and keep dependencies pinned and reviewed. |
| DNS restoration after crashes | Journal actual mutations and require live forced-exit validation before release. |
| HIP differs under a launch daemon | Verify execution identity and report generation with the real gateway. |
| App bundle is moved or replaced | Validate service state and code identity; require an orderly reconnect or helper repair. |
| Portal policy changes | Surface authentication or HIP failure clearly and retain the existing client as a fallback. |
| Signing credentials are unavailable | Continue local implementation; external distribution remains blocked until valid credentials exist. |
| Final product name or Team ID is undecided | Use GPClient as a working name; settle identifiers before signing and callback registration. |

Do not estimate delivery from UI work alone.
Authentication integration, privileged execution, runtime packaging, and crash recovery determine the schedule.
Size the remaining phases after Phase 0 has produced real evidence.

## 14. Completion criteria

The first release is complete when all of these conditions hold:

- The app is accessible from the macOS menu bar and uses native SwiftUI views.
- Users can enter, save, and later edit their GlobalProtect connection address.
- A valid entered address saves automatically and remains available across restarts until the user changes it.
- The configured address drives every connection stage; the application contains no fixed company portal or provider-specific behavior.
- The real SAML-enabled provider reference connection works through user configuration without Terminal or developer tools.
- Supported authentication methods and observed portal compatibility limits are documented.
- The user can finish browser login and any gateway challenge inside the intended flow.
- Browser choice persists and supports in-app, system default, and a specific installed browser application.
- Clicking Connect opens the chosen browser; `globalprotectcallback:` automatically continues tunnel establishment.
- The in-app browser closes after authentication; supported external browsers close only the owned authentication page.
- Any external browser cleanup limitation is documented explicitly, with full browser-lifecycle support tracked separately from connection success.
- The helper accepts only the intended signed application and owning user.
- Connection status reflects confirmed backend state, including uncertainty and cleanup failure.
- Disconnect, quit, crashes, sleep, and network changes pass live validation.
- Network restoration preserves unrelated user and system settings.
- Secrets are absent from persistent settings, arguments, logs, and exported diagnostics.
- The runtime is self-contained and has no Homebrew or workspace references.
- The installation artifact passes signing, notarization, installation, upgrade, and removal checks.
- The interface passes live visual and accessibility review on the declared supported macOS versions.
- Source provenance, dependency notices, protocol documentation, and live validation evidence are included.
