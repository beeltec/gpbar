# Live validation record

Date: 2026-09-20. Host: Apple Silicon, macOS 26.6.2, build 25G83.
Xcode 27.0 and Swift 6.4. Development signing used a matching personal Apple Development team.
All interactions below used computer-use controls against the running native application.
No automated tests were added or run.

## Observed

| Scenario | Result |
| --- | --- |
| Initial settings | Empty address, `vpn.example.com` placeholder, in-app browser default, launch at login off. |
| Save valid address | Whitespace was removed and HTTPS added. The valid address saved without a Save button. |
| Invalid replacement | An HTTP address with a path showed an error and did not replace the saved address. |
| Quit and relaunch | The valid address and selected browser remained saved. |
| Browser picker | All three modes were available. A specific installed browser could be selected. |
| Default browser launch | AuthenticationServices opened Microsoft login in Brave Origin's private authentication window. |
| Default browser cancellation | Build `live-v12` cancelled the attempt, closed GPBar's sign-in window, and restored Connect without crashing. |
| Quit during sign-in | Build `live-v14` displayed Disconnect and Quit, completed cancellation, and exited with no engine process remaining. |
| Final development build | Build `live-v15` registered its helper, reached Microsoft login during a helper-refresh check, and cancelled back to Connect. |
| Helper registration | The authorized development helper registered and passed signature, root, and console-user inspection. |
| Helper removal | Removing the idle helper made its status unverified and disabled removal. |
| Automatic helper startup | Build `helper-startup-v1` registered and verified the missing helper without clicking Set up or Check again. |
| Helper readiness after restart | Relaunching the same build showed Helper ready and enabled Connect without a helper action. |
| Removal and automatic startup | Check helper preserved removal during the current run. Relaunch registered the helper again, before any window opened. |
| Packaged helper | Registration and inspection also worked from the complete signed runtime bundle. |
| First engine start | Exposed a pipe-reader issue before authentication. The helper recovered and reported failure. |
| Corrected engine start | Reached the SAML-enabled provider's Microsoft sign-in page in the embedded browser. The current hostname was visible. |
| Close sign-in window | Cancelled authentication, closed the owned window, and restored Connect without an error. |
| Saved SAML-enabled provider address | The manually entered portal and in-app choice survived the next packaged build launch. |
| Diagnostics | Showed bounded event names and phases without portal or callback data in the export preview. |
| Dark appearance | Native settings and sign-in rendered with readable controls, scrolling, and visible keyboard focus. |

The user completed Microsoft sign-in and Authenticator approval in the embedded browser.
GPBar captured the callback automatically, fetched portal configuration, and completed gateway login.
The owned sign-in window closed automatically.

External browser cancellation exposed a Swift callback-isolation crash in an earlier build.
The callback now explicitly crosses to the main actor. Live cancellation passed after that correction.

Development build `live-v8` established the first confirmed tunnel to the reference SAML-enabled provider.
The native worker verified its configured routes and SystemConfiguration DNS values before publishing Connected.
Earlier attempts exposed the OpenConnect platform-name mapping and non-canonical worker-path defects; both were corrected.
The gateway accepted the observed HIP path, but individual posture-policy coverage remains unverified.

While connected, the requested public endpoint timed out in the browser and an independent HTTPS connection attempt.
After disconnect, the endpoint answered HTTPS again; its HEAD response was HTTP 403.
The browser initially reported a network transition, so a successful full-page render is not yet recorded.
The DNS snapshot matched the original snapshot exactly after disconnect.
Stable routes matched the baseline, and no routes remained on the former GPBar interface.
Dynamic neighbor-cache entries were excluded from the stable-route comparison.
A later final snapshot still matched the stable routes and DNS configuration, except for resolver order numbers assigned by the system.
Those later order values were preserved.

The user withdrew the proposed internal endpoints and requested only the public-site restriction check.
No successful internal-service access is claimed.
NetBird was already connected and was not disconnected or changed.
The official GlobalProtect client was checked only for connection status; it was disconnected.

The helper startup checks used the same macOS host and development signing team listed above.
The helper ran through launchd's Mach service activation after a background app launch.
Settings then showed verified identity and user access. Diagnostics remained Disconnected with no session events.
The existing macOS approval was reused. First approval and revoked approval were not repeated for this change.
Parallel lifecycle and ServiceManagement reviews found no concrete issues in the startup change.

## Globe icon update

Development builds `globe-icons-v1` and `globe-icons-v2` used the same host, toolchain, signing team, and backend as above.
The final build passed compilation and strict signature verification.

- The native window title and heading read “Edit Connection”. The previous subtitle was absent.
- Native screen captures showed the larger gray globe while disconnected.
- A connection to `vpn.invalid` failed and showed an upper-right exclamation mark. The saved SAML-enabled provider address was restored afterward.
- SAML-enabled provider sign-in showed the upper-right `<...>` badge. Two native screen captures showed different illuminated dots with fixed globe geometry.
- Cancelling sign-in restored Connect and stopped the engine.
- Two parallel review rounds checked drawing, accessibility, state mapping, and animation lifetime.
- Review identified low white-stroke contrast on light backgrounds. A narrow dark outline was added; the second round found no concrete issues.

The connected white globe and checkmark were not observed during a live tunnel in these builds; user sign-in was not completed.
Reduce Motion, VoiceOver, and light-menu-bar appearance still need live checks for these icons.
Screenshot artifacts remain under ignored build output. No automated tests were added or run.

## Connection layout update

Development build `connection-layout-v1` used the same macOS host, toolchain, signing team, and backend listed above.
The complete app built and passed strict signature verification.

- Live settings showed the application icon beside the vertically centered “Edit Connection” heading.
- The user completed SAML-enabled provider sign-in and opened the connected menu bar panel.
- Gateway and VPN address labels shared a left edge. Their values shared a separate left-aligned column.
- The long gateway name wrapped inside the panel without clipping.
- The footer contained Diagnostics and Quit. The duplicate Edit connection action was absent.
- Clicking the gear opened Edit Connection and preserved the active connection.
- The validation connection was disconnected after the visual checks.
- Both parallel reviews found no concrete layout or navigation regressions. No automated tests were created or run.

## Globe centering fix

Development build `globe-centering-v1` used the same host, toolchain, signing team, and bundled backend as `connection-layout-v1`.
The Swift app built successfully. The complete development bundle passed strict signature verification.

- The rebuilt app launched and showed Helper ready with Connect available.
- The user confirmed that the live icon looked correct after launch.
- The UI tool captured settings but could not capture the menu bar for independent visual confirmation.
- Two parallel `codex review` checks found no concrete drawing, state, animation, or accessibility regressions.
- No automated tests were added or run. Connected and animated badges were not rechecked live for this position-only change.

## GPBar rename

Development build `rename-v1` used the same macOS host and toolchain listed above.
The app, helper, and engine used one matching Apple Development signing identity.

- A clean build rebuilt the patched OpenConnect library, Rust engine, Swift app, and privileged helper.
- The complete bundle passed deep, strict signature verification.
- Signed identifiers were `com.beeltec.GPBar`, `com.beeltec.GPBar.helper`, and `com.beeltec.GPBar.engine`.
- The packaged engine reported application-session support, network journaling, protocol 1, and OpenConnect `v9.21-gpbar1`.
- The previous idle helper was removed before replacing the development app.
- A local preferences export and import preserved the saved portal and in-app browser choice under the new domain.
- Settings, menu names, sign-in text, and the launch-at-login label used GPBar.
- The user approved the renamed helper in macOS settings. GPBar then verified its identity and user access.
- Connect reached the Microsoft sign-in host through the renamed helper and packaged engine.
- Cancel closed the owned sign-in window and restored Connect with the helper ready.
- Cargo check and Clippy passed for the production workspace targets.
- Shell syntax and property-list checks passed. Tracked paths and content passed the product-name audit.
- Rustfmt reported existing vendor formatting differences. Comparison against the baseline confirmed no new formatting differences after the rename.
- Two parallel `codex review` reports found no concrete identity, lifecycle, build, or runtime-contract regressions.

Full tunnel establishment and disconnect cleanup have not yet been repeated for this build.
No automated tests were added or run.

## Still required

- Extend route and DNS restoration checks to forced failures and helper restart.
- Check IPv6 separately; no IPv6 compatibility claim is established.
- Exercise reconnect, reauthentication, sleep/wake, UI loss, helper restart, and forced engine exit on a controlled connection.
- Complete default-browser and specific-browser login, including each browser's supported cleanup behavior.
- Inspect the actual menu bar popover, light appearance, VoiceOver, reduced motion, and increased contrast.
- Check another approved portal when one is available.
- Validate Developer ID signing, notarization, clean installation, updates, and removal.
- Run on macOS 26.0 as the oldest supported version.

## Static evidence

The Swift app and helper have built with macOS 26.0 deployment settings.
The engine has built against patched OpenConnect 9.21 with real bindings.
The packaged development bundle passed deep, strict code-signature validation.
Its executable and dylib load paths were relocated into the bundle.
These are build checks, not live network validation.

Parallel code reviews found defects in cancellation, recovery, observer ownership, reconnect state, and input parsing.
The final security and lifecycle review reports found no remaining concrete issues after the fixes.
These reviews and clean Clippy results do not replace the pending live scenarios above.
