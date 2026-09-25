# macOS login SSO

GPBar can optionally capture your next macOS login password through an Authorization Services plug-in.
It can submit that password once to your saved GlobalProtect portal when you click Connect.
The Mac and VPN must use the same username and password.
This is separate from Kerberos tickets, browser SSO, saved VPN passwords, and saved authentication cookies.

**Validation limit:** system login installation and real password-based GlobalProtect compatibility remain unverified.
Use a controlled Mac with a working administrator recovery path before enabling this integration.
Synthetic checks and a signed build do not establish login, FileVault, or provider compatibility.

## Enable

1. Install GPBar and approve its VPN helper.
2. Save the portal address under Connections.
3. Choose Automatic or Username and password.
4. Choose Enable macOS login SSO, read the confirmation, and approve the administrator prompt.
5. Sign out, then sign in with your password. Click Connect within five minutes.

Enabling applies only to your user and the exact saved HTTPS portal, including its port.
Profiles using that portal share its enrollment. Only one portal can be enrolled for each macOS user.
Other users must enable it separately. Changing or removing an enrolled portal requires disabling SSO first. Enable it again for a new address when needed.
No VPN connection starts at macOS login. Launch GPBar at login remains a separate setting.
No credentials are captured when the feature is disabled.

Only a fresh portal password prompt can consume the captured password.
The server's password label must be `Password`, ignoring case. Other labels use manual entry.
Gateway authentication, including a gateway at the same origin, always uses its existing authentication flow.
SAML, Cloud Identity Engine, and MFA prompts cannot consume the captured password.
Missing or expired credentials use manual entry. A rejected password ends that connection attempt; the next attempt uses manual entry.
Touch ID, smart cards, passwordless login, screen unlock, and FileVault password forwarding have no compatibility claim.

## Storage and trust

The plug-in reads Authorization Services username, password, and user-ID context after `builtin:login-success`.
It does not replace authentication mechanisms or grant access independently.
Its callback always allows macOS to continue, including missing credentials and helper failures.
Its helper wait has a 250-millisecond deadline. Plug-in loading and system APIs can add separate delays.
A missing or unloadable plug-in can still prevent login before its callback runs.

The helper accepts captures only from Apple's root `com.apple.authorizationhosthelper.arm64` process.
It exposes only credential capture to that caller, with no VPN or installation operations.
The plug-in authenticates GPBar's helper by identifier and signing team.
The helper binds credentials to the kernel-provided audit session, user ID, and enrolled portal.
Consumption requires a signed GPBar app in that same login session, running as the active console user.

Credentials remain in memory and private IPC. They are never written to preferences, Keychain, files, logs, or command arguments.
The cache holds one credential and expires it after five minutes using a monotonic clock.
Consumption, cancellation, consent changes, lost app contact, and helper restart clear it.
The helper also checks session lifetime and console switching once per second.
Swift strings and IPC can create copies; GPBar does not promise guaranteed memory zeroing.
GPBar never reads credentials belonging to the official GlobalProtect application.

## Installation, removal, and updates

The app bundles a signed `GPBarLogin.bundle`. Enabling requires administrator authorization through macOS.
The helper copies and validates it under root-owned storage before changing the login rule.
It installs the bundle at `/Library/Security/SecurityAgentPlugins/GPBarLogin.bundle`.
It inserts only `GPBarLogin:capture,privileged`, immediately after the existing login-success mechanism.
Unknown rule layouts are refused. Other mechanisms and rule fields remain in place.

Non-secret per-user portal consent lives in `/Library/Application Support/GPBar/LoginSSO/users.plist`.
The directory is root-only. The initial rule is recorded beside it as `login-rule-before.plist` for recovery reference.
Authorization Services has no public compare-and-swap operation for rules.
GPBar checks the current rule before writing and verifies the result. Avoid simultaneous changes by another login-management tool.

Choose Disable macOS login SSO to revoke your consent and clear the helper's credential cache.
Disabling the final enrolled user removes only GPBar's mechanism from the current rule.
Later changes made by other software remain intact.
The now-inactive bundle remains for login hosts that may still have the previous rule loaded.
It cannot capture credentials without an enrolled user.

Disable SSO for every enrolled user before removing the VPN helper, updating GPBar, or reinstalling it.
The application and PKG installer enforce this requirement. Manual file replacement cannot be protected by GPBar.
After updating, enabling SSO stages and verifies the new bundle before restoring the mechanism.
After final removal and a restart, an administrator may remove the inactive bundle and `LoginSSO` directory.
First confirm that `security authorizationdb read system.login.console` contains no `GPBarLogin:` mechanism.

## Recovery

Before testing login integration, arrange an independent administrator session or approved SSH access to the Mac.
Apple's own plug-in validation guide uses SSH because a broken login rule can prevent graphical login.
[Apple validation procedure](https://github.com/apple-oss-distributions/Security/blob/main/OSX/authd/QA/features/macos/3rd-party-plugins.feature)

If the app is unavailable, an administrator can disable all GPBar login capture from that session:

```sh
sudo /Applications/GPBar.app/Contents/MacOS/GPBarHelper --remove-login-sso
security authorizationdb read system.login.console
```

The command clears all GPBar consent and removes only GPBar's mechanism. It leaves the bundle in place.
It does not restore a historical rule over later changes or modify any other authorization right.
Restart after verifying removal. Do not delete an active plug-in bundle or the system authorization database.
If no administrator session is available, use your organization's macOS recovery procedure or restore a known-good system backup.
GPBar does not implement an offline authorization-database editor.

## Sources and library audit

The vendor documents macOS OS-login SSO separately from Kerberos fallback.
Its June 2025 training material identifies an Authorization Plugin as the macOS login integration.
[Agent settings](https://origin-docs.paloaltonetworks.com/ngfw/help/12-2/globalprotect/network-globalprotect-portals/globalprotect-portals-agent-configuration-tab/globalprotect-portals-agent-app-tab),
[Vendor training](https://live.paloaltonetworks.com/twzvq79624/attachments/twzvq79624/CommunityBlog/3648/1/Primsa%20Acess-%20GlobalProtect%20Training-Fuel-June%202025.pptx.pdf)

Apple documents the plug-in ABI, context callbacks, privileged hosting, bundle location, and `AuthorizationRightSet` registration.
Apple's source supplies the authorization session's audit port when creating its privileged host.
The installed macOS host's signature matches GPBar's requirement. Actual login-session propagation still needs live validation.
[Apple plug-in contract](https://developer.apple.com/documentation/security/extending-authorization-services-with-plug-ins),
[Apple host implementation](https://github.com/apple-oss-distributions/Security/blob/main/OSX/authd/agent.c)

The pinned OpenProtect password provider constructs standard credentials and otherwise uses terminal prompts.
Its existing request code handles portal passwords, MFA, gateway authentication, and TLS.
OpenConnect 9.21 likewise has password authentication but no macOS login capture integration.
GPBar reuses OpenProtect's credential submission through existing private IPC.
The new engine event flag identifies eligible portal prompts; it does not add a wire protocol.
The native plug-in, consent management, and credential ownership checks fill the verified macOS integration gap.

## Validation

The owner explicitly requested a server-free suite for issue #19, overriding its earlier live-only rule.
Run [the login SSO suite](Tests/LoginSSO/README.md).
It leaves the real login database, plug-in directory, user credentials, trust settings, and networking configuration unchanged.
Real login capture, administrator installation, recovery, FileVault, smart cards, provider acceptance, and successful VPN tunnels remain unverified.
